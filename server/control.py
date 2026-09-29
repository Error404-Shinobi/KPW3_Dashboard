"""看板「遥控」状态。

为什么需要这个：
    看板把 framework 停了，Kindle 端按键失灵，人在里面出不来。
    除了设备端自己听电源键（exitdash.sh），再给一条**服务端下行通道**：
    浏览器点一下「退出看板」，设备下次来拉图时收到指令就自己退出去。

为什么不用内存变量：
    服务重启（改配置、systemd restart）会把内存状态清掉。
    用户点了「退出」结果因为服务重启没生效，会很难理解。
    所以落盘成一个状态文件，重启也在。

文件格式（三行 KV，手改也方便）：
    quit=0
    set_at=1695798000
    note=

用法：
    ctrl.request_quit()     请求退出（浏览器按钮调）
    ctrl.cancel_quit()      取消退出请求
    ctrl.is_quit_requested() 查询（设备端来问）
    ctrl.clear_quit()       设备端确认退出后清掉，避免下次启动又立刻退出
"""

from __future__ import annotations

import logging
import os
import tempfile
import threading
import time

log = logging.getLogger(__name__)

# 状态文件路径。放 server/ 目录下，和 config.yaml 平级。
_DEFAULT_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), ".control")


class ControlState:
    """看板遥控状态。线程安全（Flask 是多线程的）。"""

    def __init__(self, path: str = _DEFAULT_PATH):
        self.path = path
        self._lock = threading.Lock()

    # --- 读写底层 ---------------------------------------------------

    def _read(self) -> dict:
        data = {"quit": "0", "set_at": "0", "note": ""}
        try:
            with open(self.path, "r", encoding="utf-8") as fh:
                for line in fh:
                    line = line.strip()
                    if not line or "=" not in line:
                        continue
                    k, _, v = line.partition("=")
                    data[k.strip()] = v.strip()
        except FileNotFoundError:
            pass
        except OSError as exc:
            log.warning("读控制状态失败: %s", exc)
        return data

    def _write(self, data: dict) -> None:
        # 先写临时文件再原子替换：避免设备端正好读到写了一半的文件。
        d = os.path.dirname(self.path) or "."
        try:
            os.makedirs(d, exist_ok=True)
            fd, tmp = tempfile.mkstemp(dir=d, prefix=".control.", suffix=".tmp")
            try:
                with os.fdopen(fd, "w", encoding="utf-8") as fh:
                    for k in ("quit", "set_at", "note"):
                        fh.write(f"{k}={data.get(k, '')}\n")
                os.replace(tmp, self.path)
            except Exception:
                # 替换失败要清掉临时文件，别在 server/ 里堆垃圾
                try:
                    os.unlink(tmp)
                except OSError:
                    pass
                raise
        except OSError as exc:
            log.warning("写控制状态失败: %s", exc)

    # --- 对外接口 ---------------------------------------------------

    def request_quit(self, note: str = "") -> None:
        with self._lock:
            self._write(
                {"quit": "1", "set_at": str(int(time.time())), "note": note}
            )
        log.info("收到「退出看板」请求 note=%r", note)

    def cancel_quit(self) -> None:
        with self._lock:
            self._write({"quit": "0", "set_at": str(int(time.time())), "note": ""})
        log.info("已取消「退出看板」请求")

    def clear_quit(self) -> None:
        """设备端确认退出后调用：把 quit 复位，避免下次启动立刻又退出。"""
        with self._lock:
            self._write({"quit": "0", "set_at": str(int(time.time())), "note": ""})

    def is_quit_requested(self) -> bool:
        with self._lock:
            return self._read().get("quit") == "1"

    def snapshot(self) -> dict:
        with self._lock:
            d = self._read()
        return {
            "quit": d.get("quit") == "1",
            "set_at": self._safe_int(d.get("set_at")),
            "note": d.get("note", ""),
        }

    @staticmethod
    def _safe_int(v) -> int:
        try:
            return int(v or 0)
        except (TypeError, ValueError):
            return 0


# 模块级单例，main.py 直接用这个
state = ControlState()
