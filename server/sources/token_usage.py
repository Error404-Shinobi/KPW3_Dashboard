"""Token / 额度数据源。

支持两类 provider：

  minimax  MiniMax Token Plan，官方 endpoint GET /v1/token_plan/remains
           注意它是双窗口制（5 小时滚动窗口 + 周窗口），会返回两个窗口
           注意必须用 Subscription Key，pay-as-you-go 的 API Key 会 401/403

  generic  任意 HTTP 接口 + 取值路径，改配置就能接，不用改代码
"""

from __future__ import annotations

import datetime as dt
import json
import logging
import os
import re
import time
from dataclasses import dataclass, field

from envutil import looks_like_placeholder

import requests

log = logging.getLogger(__name__)

_ENV_PATTERN = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}")


def expand_env(value):
    """把字符串里的 ${VAR} 替换成环境变量。"""
    if not isinstance(value, str):
        return value
    return _ENV_PATTERN.sub(lambda m: os.environ.get(m.group(1), ""), value)


def get_path(data, path: str):
    """按 a.b[0].c 这样的路径从嵌套 dict/list 里取值。"""
    if not path:
        return None
    cur = data
    for token in path.split("."):
        if not token:
            continue
        name, *idx = re.split(r"\[(\d+)\]", token)
        if name:
            if not isinstance(cur, dict):
                return None
            cur = cur.get(name)
        for i in idx:
            if i == "":
                continue
            if not isinstance(cur, list):
                return None
            n = int(i)
            if n >= len(cur):
                return None
            cur = cur[n]
        if cur is None:
            return None
    return cur


def _pick(data: dict, *names):
    """字段别名兜底：官方字段名万一和文档不一致，多试几个。"""
    for n in names:
        if isinstance(data, dict) and data.get(n) is not None:
            return data[n]
    return None


def _as_number(value):
    if value is None:
        return None
    if isinstance(value, (int, float)):
        return float(value)
    if isinstance(value, str):
        s = value.replace(",", "").strip()
        try:
            return float(s)
        except ValueError:
            return None
    return None


@dataclass
class Window:
    """一个配额窗口。MiniMax 有 5 小时和周两个，别的服务通常只有一个。

    两种给值方式：
      - 有具体用量：填 used / limit，百分比自动算
      - 只有百分比（MiniMax 就是这样）：填 percent_remaining_given

    ★ 统一口径：percent 表示「还可用的百分比」（剩余），不是「已用」。
    为什么这么定：这是额度看板，用户最想知道的是"我还能用多少"。
    读 MiniMax 的 current_interval_remaining_percent（本来就是剩余量）
    直接填进来即可，不必再翻成已用。
    """

    label: str = ""
    used: float | None = None
    limit: float | None = None
    reset_at: str = ""
    # 上游直接给的「剩余百分比」。名字写全，避免又和"已用"搞混。
    percent_remaining_given: float | None = None

    @property
    def remaining(self) -> float | None:
        if self.used is None or self.limit is None:
            return None
        return max(0.0, self.limit - self.used)

    @property
    def percent_remaining(self) -> float | None:
        """剩余百分比：进度条和右侧大字都用这个。"""
        if self.percent_remaining_given is not None:
            return max(0.0, min(100.0, self.percent_remaining_given))
        if self.used is None or not self.limit:
            return None
        return max(0.0, min(100.0, (self.limit - self.used) / self.limit * 100.0))

    @property
    def percent(self) -> float | None:
        """保留旧名，语义等同于 percent_remaining（剩余）。"""
        return self.percent_remaining

    @property
    def percent_used(self) -> float | None:
        """已用百分比，仅调试/备用。"""
        r = self.percent_remaining
        return None if r is None else 100.0 - r


def _reset_iso(end_ms, remains_ms=None) -> str:
    """MiniMax 给的是毫秒时间戳，优先用窗口结束时间，退而用剩余时长推算。"""
    if end_ms:
        try:
            return dt.datetime.fromtimestamp(float(end_ms) / 1000).isoformat()
        except (TypeError, ValueError, OSError):
            pass
    if remains_ms:
        try:
            delta = dt.timedelta(milliseconds=float(remains_ms))
            return (dt.datetime.now() + delta).isoformat()
        except (TypeError, ValueError):
            pass
    return ""


@dataclass
class TokenUsage:
    ok: bool = False
    error: str = ""
    label: str = "Token Plan"
    unit: str = "tokens"
    windows: list[Window] = field(default_factory=list)


class TokenSource:
    def __init__(self, cfg: dict):
        self.cfg = cfg or {}
        self.provider = (self.cfg.get("provider") or "generic").lower()
        self._cache: TokenUsage | None = None
        self._stamp = 0.0

    def enabled(self) -> bool:
        if not self.cfg.get("enabled", False):
            return False
        return bool(self.cfg.get("url") or self.provider == "minimax")

    def _ttl(self) -> int:
        try:
            return int(self.cfg.get("update_secs", 300))
        except (TypeError, ValueError):
            return 300

    def get(self) -> TokenUsage:
        label = self.cfg.get("label") or "Token Plan"
        unit = self.cfg.get("unit") or "tokens"

        if os.environ.get("DASH_FAKE_DATA"):
            # 关键字传参：Window 的字段以后可能调整，位置参数容易错位。
            return TokenUsage(
                ok=True,
                label=label,
                unit=unit,
                windows=[
                    Window(
                        label="5小时",
                        used=1_245_300,
                        limit=5_000_000,
                        reset_at="2026-09-23T21:00:00+08:00",
                    ),
                    Window(
                        label="本周",
                        used=8_420_000,
                        limit=35_000_000,
                        reset_at="2026-09-28T00:00:00+08:00",
                    ),
                ],
            )

        if not self.enabled():
            return TokenUsage(ok=False, error="未启用", label=label, unit=unit)

        if self._cache and (time.time() - self._stamp) < self._ttl():
            return self._cache

        try:
            if self.provider == "minimax":
                t = self._fetch_minimax(label, unit)
            else:
                t = self._fetch_generic(label, unit)
        except Exception as exc:  # noqa: BLE001
            log.warning("token fetch failed: %s", exc)
            t = TokenUsage(ok=False, error=str(exc), label=label, unit=unit)
            # 上游挂了沿用旧数据，屏幕不至于变空白
            if self._cache:
                return self._cache

        self._cache = t
        self._stamp = time.time()
        return t

    # --- MiniMax -------------------------------------------------------
    def _fetch_minimax(self, label: str, unit: str) -> TokenUsage:
        key_env = self.cfg.get("api_key_env") or "MINIMAX_SUBSCRIPTION_KEY"
        key = os.environ.get(key_env, "")
        if not key:
            raise ValueError(f"环境变量 {key_env} 没设置（注意要放 Subscription Key）")
        if looks_like_placeholder(key):
            # ★ 拦住"模板没改就用了"：占位符原样发出去，报错会是
            #   HTTP 头编码失败之类的怪东西，完全看不出是没填密钥。
            raise ValueError(
                f"{key_env} 的值看起来还是模板里的占位符（{key[:24]!r}）—— "
                f"请填真实密钥，别把 .env.example 里的示例原样抄过来"
            )

        url = self.cfg.get("url") or "https://api.minimax.io/v1/token_plan/remains"
        r = requests.get(
            url,
            headers={
                "Authorization": f"Bearer {key}",
                "Content-Type": "application/json",
            },
            timeout=self.cfg.get("timeout") or 15,
        )
        r.raise_for_status()
        try:
            js = r.json()
        except json.JSONDecodeError as exc:
            raise ValueError(f"响应不是合法 JSON: {exc}") from exc

        # MiniMax 的错误放在 base_resp 里，也有版本放顶层 code，两种都看
        base = js.get("base_resp") or {}
        code = base.get("status_code", js.get("code", 0))
        if code not in (0, None, "0"):
            msg = base.get("status_msg") or js.get("message") or js.get("msg") or ""
            raise ValueError(f"MiniMax 返回 {code}: {msg}")

        # 真实响应没有 data 层，额度按模型拆在 model_remains[] 里；
        # 而且 total/usage 恒为 0，能用的是 remaining_percent 和 end_time。
        data = js.get("data") or js
        models = data.get("model_remains") or []
        if not models:
            raise ValueError("响应里没有 model_remains 数组")

        wanted = self.cfg.get("model") or "general"
        entry = next((m for m in models if m.get("model_name") == wanted), None)
        if entry is None:
            names = [m.get("model_name") for m in models]
            raise ValueError(
                f"没找到模型 {wanted}，响应里有的是：{names}。"
                f"改 config.yaml 的 token.model"
            )

        windows: list[Window] = []

        # MiniMax 给的 current_*_remaining_percent 就是「剩余百分比」
        # （实测满额度时返回 100），直接填，不做 100-x 翻转。
        # 之前翻了，导致满额度画成 0% 空条，一眼看过去像是没额度了。
        iv_rem = _as_number(entry.get("current_interval_remaining_percent"))
        if iv_rem is not None:
            windows.append(
                Window(
                    label="5小时",
                    percent_remaining_given=iv_rem,
                    reset_at=_reset_iso(
                        entry.get("end_time"), entry.get("remains_time")
                    ),
                )
            )

        wk_rem = _as_number(entry.get("current_weekly_remaining_percent"))
        if wk_rem is not None:
            windows.append(
                Window(
                    label="本周",
                    percent_remaining_given=wk_rem,
                    reset_at=_reset_iso(entry.get("weekly_end_time")),
                )
            )

        if not windows:
            raise ValueError(
                "响应里没找到 remaining_percent 字段，"
                "跑一下 python probe_minimax.py 看真实返回结构"
            )

        return TokenUsage(ok=True, label=label, unit="%", windows=windows)

    # --- 通用 HTTP -----------------------------------------------------
    def _fetch_generic(self, label: str, unit: str) -> TokenUsage:
        method = (self.cfg.get("method") or "GET").upper()
        headers = {k: expand_env(v) for k, v in (self.cfg.get("headers") or {}).items()}
        timeout = self.cfg.get("timeout") or 15

        if method == "POST":
            r = requests.post(
                self.cfg["url"],
                data=expand_env(self.cfg.get("body") or ""),
                headers=headers,
                timeout=timeout,
            )
        else:
            r = requests.get(self.cfg["url"], headers=headers, timeout=timeout)
        r.raise_for_status()
        try:
            js = r.json()
        except json.JSONDecodeError as exc:
            raise ValueError(f"响应不是合法 JSON: {exc}") from exc

        ex = self.cfg.get("extract") or {}
        used = _as_number(get_path(js, ex.get("used", "")))
        limit = _as_number(get_path(js, ex.get("limit", "")))
        reset = get_path(js, ex.get("reset_at", "")) or ""

        if self.cfg.get("extract_is_remaining"):
            remaining = used
            used = None if (remaining is None or limit is None) else limit - remaining

        return TokenUsage(
            ok=True,
            label=label,
            unit=unit,
            windows=[Window(label="已用", used=used, limit=limit, reset_at=str(reset))],
        )
