"""KPW3 看板服务端。

在 Linux 服务器上常驻，暴露两个东西：
  GET /dashboard.png  Kindle 每隔 N 分钟来拉这张图
  GET /              浏览器里直接预览（调布局时比刷墨水屏快得多）

用法：
  cd server && pip install -r requirements.txt
  python main.py
"""

from __future__ import annotations

import datetime as dt
import io
import logging
import os
import threading
import time

import yaml
from flask import Flask, Response, jsonify, request

import fontutil
import control
from envutil import load_dotenv
from render import Payload, Renderer
from sources.token_usage import TokenSource
from sources.weather import WeatherSource

logging.basicConfig(
    level=os.environ.get("LOG_LEVEL", "INFO"),
    format="%(asctime)s %(levelname)s %(name)s: %(message)s",
)
log = logging.getLogger("dashboard")

CONFIG_PATH = os.environ.get("CONFIG_PATH", "config.yaml")


def load_config() -> dict:
    path = CONFIG_PATH
    if not os.path.exists(path):
        raise FileNotFoundError(
            f"找不到配置文件 {path}。先执行：cp config.yaml.example config.yaml"
        )
    with open(path, "r", encoding="utf-8") as fh:
        return yaml.safe_load(fh) or {}


# 有 .env 就先读进来，免去在每个 shell 里 export
load_dotenv()

cfg = load_config()
renderer = Renderer(cfg)
weather_src = WeatherSource(cfg.get("weather") or {}, cfg.get("location") or {})
token_src = TokenSource(cfg.get("token") or {})

# 启动自检：把画布渲染一次，确认输出尺寸/色深符合 eips 要求。
# 渲染代码出错时服务会直接起不来（nginx 表现为 502），
# 与其让你面对一个 502 猜原因，不如启动时就把问题喊出来。
try:
    _size = "unknown"
    _probe = renderer.render(Payload(now=renderer.now()))
    _size = f"{_probe.size[0]}x{_probe.size[1]} {_probe.mode}"
    if renderer.rotate and _probe.size != (1072, 1448):
        log.warning("自检异常：旋转后应为 1072x1448，实际 %s", _probe.size)
    else:
        log.info("渲染自检通过: %s", _size)
    del _probe
except Exception:
    log.exception("渲染自检失败 —— 服务无法正常出图，请检查 render.py / Pillow 版本")
    raise

cache_secs = int((cfg.get("server") or {}).get("cache_secs", 120))
_png_cache: bytes | None = None
_png_stamp = 0.0
# 缓存对应的电量分桶；电量变了必须让缓存失效，否则电量会被冻住
_png_batt_key: int | None = None
# 预览页（横图）单独一份缓存 —— 它不走电量分桶，
# 和 Kindle 那份共用会被互相冲掉，导致"浏览器看到竖图"或"Kindle 没图"
_png_rot_cache: bytes | None = None
_png_rot_stamp = 0.0
_lock = threading.Lock()

app = Flask(__name__)

# 可选访问控制：服务器如果有公网 IP，不设这个的话任何人都能看到你的额度。
# 设了 DASH_ACCESS_TOKEN 之后，请求必须带 ?token=xxx。
ACCESS_TOKEN = os.environ.get("DASH_ACCESS_TOKEN", "")


@app.before_request
def check_token():
    if not ACCESS_TOKEN or request.path == "/health":
        return None
    # 浏览器表单提交（POST）拿不到 query string 里的 token，
    # 所以 form 字段也算。设备端（wget）用 query string。
    supplied = request.args.get("token") or request.form.get("token")
    if supplied != ACCESS_TOKEN:
        return jsonify(error="unauthorized"), 401
    return None


def _check_control_auth():
    """写操作（退出/取消）的额外校验。

    ★ 为什么单独加一道：
    /dashboard.png 是只读的，被陌生人看到无非是隐私问题；
    而 /control/quit 是**写操作**，一旦暴露，任何人都能远程关掉你的看板。
    所以即使 DASH_ACCESS_TOKEN 没设（服务器在内网/无 token 模式），
    也强制要求写操作必须带 token —— 没设就一律拒绝，宁可不给按钮用。

    返回 None 表示放行，否则返回 (response, status)。
    """
    if not ACCESS_TOKEN:
        return (
            jsonify(
                error="拒绝执行：服务端未设置 DASH_ACCESS_TOKEN，"
                "出于安全考虑，写操作（退出看板）一律禁用。\n"
                "想用这个功能，请在 server/.env 里设一个 DASH_ACCESS_TOKEN 再重启。"
            ),
            403,
        )
    if request.args.get("token") != ACCESS_TOKEN and request.form.get("token") != ACCESS_TOKEN:
        return jsonify(error="unauthorized"), 401
    return None


def build_png(battery: int | None, rotate: bool | None = None) -> bytes:
    """出图。rotate=None 用配置值（给 Kindle）；True/False 可强制覆盖（给浏览器）。

    ★ 为什么预览页要服务端转、而不是靠 CSS：
      /dashboard.png 输出的是竖图（1072×1448，因为 eips 不认旋转、只贴图）。
      浏览器要看横的，原本用 CSS transform 反旋 90° —— **实测不可靠**：
      图片每 60 秒换一次 src，重排时旋转会失效，截图就是躺倒的。
      与其和浏览器渲染时序较劲，不如让服务端直接给一张摆正的图：
      预览页请求 ?rot=0 拿横图，Kindle 不传（拿竖图）。
      代价是同一帧渲染两次（各有一份缓存），几十毫秒，可以接受。
    """
    payload = Payload(
        weather=weather_src.get(),
        token=token_src.get(),
        battery=battery,
        city=(cfg.get("location") or {}).get("name", ""),
        now=renderer.now(),
    )
    img = renderer.render(payload, rotate=rotate)
    buf = io.BytesIO()
    img.save(buf, format="PNG", optimize=True)
    return buf.getvalue()


@app.get("/dashboard.png")
def dashboard_png():
    batt_raw = request.args.get("batt")
    battery = None
    if batt_raw:
        try:
            battery = int(float(batt_raw))
        except ValueError:
            battery = None

    # 给浏览器预览用：?rot=0 关旋转（拿横图）。不传则按配置（Kindle 拿竖图）。
    rot_raw = request.args.get("rot")
    rotate = None
    if rot_raw is not None:
        rotate = rot_raw not in ("0", "false", "no")

    # ★ 缓存必须按电量分桶，否则电量会被"冻住"。
    #
    # 之前这里只按时间判断，导致 cache_secs（默认 120 秒）内
    # 无论手机（Kindle）上报什么电量，都直接返回上一张旧图 ——
    # 表现就是"电量不刷新"，甚至一直空白。
    #
    # 做法：把电量并进缓存键。电量没变就复用缓存（省渲染），
    # 变了就重渲染。用 //5 分桶，避免 1% 的抖动都触发重渲染。
    batt_key = -1 if battery is None else battery // 5

    global _png_cache, _png_stamp, _png_batt_key, _png_rot_cache, _png_rot_stamp
    with _lock:
        if rotate is False:
            # 预览页（横图）：单独一份缓存，别和 Kindle 那份互相冲掉
            fresh = (
                _png_rot_cache is not None
                and (time.time() - _png_rot_stamp) < cache_secs
            )
            if fresh:
                return Response(_png_rot_cache, mimetype="image/png")
            png = build_png(battery, rotate=False)
            _png_rot_cache = png
            _png_rot_stamp = time.time()
            return Response(png, mimetype="image/png")

        fresh = (
            _png_cache is not None
            and (time.time() - _png_stamp) < cache_secs
            and _png_batt_key == batt_key
        )
        if fresh:
            return Response(_png_cache, mimetype="image/png")
        png = build_png(battery)
        _png_cache = png
        _png_stamp = time.time()
        _png_batt_key = batt_key
    return Response(png, mimetype="image/png")


@app.get("/")
def preview():
    # 浏览器预览页：每 60 秒自动换一次图（加时间戳绕过浏览器缓存）。
    # 只是给人看的，Kindle 走的是 /dashboard.png，跟这个页面无关。
    #
    # ★ 反旋交给**服务端**（?rot=0），不再用 CSS transform。
    #   原因：CSS 反旋实测不可靠 —— 图片每 60 秒换一次 src，
    #   重排后 transform 会失效，页面就是躺倒的。
    #   服务端直接出横图最稳，也不跟浏览器渲染时序较劲。
    qs = request.args.get("token") or ACCESS_TOKEN or ""
    img_style = (
        "image-rendering:pixelated;"
        "max-width:100%;max-height:100vh;display:block;"
    )

    snap = control.state.snapshot()
    pending = snap["quit"]

    # 右上角浮动的「退出看板」按钮。
    # 没设 DASH_ACCESS_TOKEN 时服务端会拒绝写操作，这里如实提示，
    # 免得用户点了没反应还以为是坏的。
    if not ACCESS_TOKEN:
        quit_box = """
<button class="qbtn disabled" title="服务端未设置 DASH_ACCESS_TOKEN，
写操作已禁用" onclick="alert('服务端没设 DASH_ACCESS_TOKEN，\\n出于安全考虑写操作（退出看板）被禁用。\\n\\n想用这个功能：在 server/.env 里设一个 DASH_ACCESS_TOKEN 然后重启服务。')">
  退出看板（未启用）
</button>"""
    elif pending:
        quit_box = f"""
<div class="qwrap">
  <span class="qbadge">已请求退出，等设备醒来</span>
  <form method="post" action="/control/cancel" style="display:inline">
    <input type="hidden" name="token" value="{qs}">
    <button class="qbtn cancel">取消</button>
  </form>
</div>"""
    else:
        quit_box = f"""
<form method="post" action="/control/quit" style="display:inline">
  <input type="hidden" name="token" value="{qs}">
  <button class="qbtn" onclick="return confirm('确认让 Kindle 退出看板、回到原生界面？\\n\\n注意：设备大部分时间在深度休眠，\\n点了之后需要\\u0020按一下电源键\\u0020唤醒它才会生效。')">
    退出看板
  </button>
</form>"""

    return f"""<!doctype html><meta charset="utf-8">
<title>KPW3 看板预览</title>
<body style="margin:0;background:#333;display:flex;justify-content:center;
align-items:center;height:100vh;overflow:hidden">
<img id="dash" src="/dashboard.png?t=0&rot=0&token={qs}"
     style="{img_style}">
<style>
#quitbar{{position:fixed;top:14px;right:14px;z-index:9;display:flex;
align-items:center;gap:8px;font-family:system-ui,sans-serif}}
.qbtn{{padding:9px 16px;font-size:14px;cursor:pointer;border:none;
border-radius:7px;background:#c0392b;color:#fff;opacity:.85}}
.qbtn:hover{{opacity:1}}
.qbtn.cancel{{background:#666}}
.qbtn.disabled{{background:#888;cursor:not-allowed}}
.qwrap{{display:flex;align-items:center;gap:8px;background:rgba(255,255,255,.92);
padding:6px 10px;border-radius:8px}}
.qbadge{{font-size:13px;color:#b00}}
</style>
<div id="quitbar">{quit_box}</div>
<script>
setInterval(function () {{
    var img = document.getElementById('dash');
    img.src = '/dashboard.png?t=' + Date.now() + '&rot=0&token={qs}';
}}, 60000);
</script>
</body>"""


@app.get("/health")
def health():
    return jsonify(status="ok")


# ── 退出看板（服务端遥控） ────────────────────────────────────────
#
# 原理：Kindle 每轮醒来拉图前，先问一次 /control/quit。
#       看到 "quit": true 就自己退出看板、把原生界面还回来。
#
# 为什么不能"点了立刻退"：设备大部分时间在深度休眠（sleep mem），
# 那会儿它收不到任何指令。只能等它下次醒。
# 所以正确用法是：**点按钮 → 按一下电源键唤醒 → 立刻退出**。
# （按电源键唤醒是硬件行为，不需要任何软件支持）

@app.get("/control/status")
def control_status():
    """查询当前是否有待执行的退出请求。"""
    return jsonify(control.state.snapshot())


@app.post("/control/quit")
def control_quit():
    """请求退出看板。设备下次来拉图时生效。"""
    denied = _check_control_auth()
    if denied:
        return denied
    control.state.request_quit(note=request.form.get("note", "web"))
    return jsonify(ok=True, **control.state.snapshot())


@app.post("/control/cancel")
def control_cancel():
    """取消退出请求（点错了可以撤）。"""
    denied = _check_control_auth()
    if denied:
        return denied
    control.state.cancel_quit()
    return jsonify(ok=True, **control.state.snapshot())


@app.post("/control/ack")
def control_ack():
    """设备端确认已经退出后调用，把 quit 复位。
    否则下次启动看板，它一问就发现 quit=true，立刻又退出去。
    """
    denied = _check_control_auth()
    if denied:
        return denied
    control.state.clear_quit()
    return jsonify(ok=True, **control.state.snapshot())


@app.get("/control")
def control_page():
    """给浏览器用的遥控页（也可从预览页点进来）。"""
    qs = request.args.get("token") or ACCESS_TOKEN or ""
    snap = control.state.snapshot()
    pending = snap["quit"]
    badge = (
        '<span style="color:#b00">● 已请求退出，等设备醒来生效</span>'
        if pending
        else '<span style="color:#070">● 正常运行中</span>'
    )
    return f"""<!doctype html><meta charset="utf-8">
<title>KPW3 看板遥控</title>
<body style="margin:0;background:#f5f5f5;font-family:system-ui,sans-serif;
display:flex;justify-content:center;padding:40px">
<div style="background:#fff;border-radius:12px;padding:32px 40px;
box-shadow:0 2px 16px rgba(0,0,0,.1);max-width:520px">
  <h2 style="margin:0 0 8px">KPW3 看板遥控</h2>
  <p style="margin:0 0 24px;color:#666;font-size:14px">{badge}</p>

  <form method="post" action="/control/quit" style="margin-bottom:12px">
    <input type="hidden" name="token" value="{qs}">
    <button style="width:100%;padding:14px;font-size:16px;cursor:pointer;
    border:none;border-radius:8px;background:#c0392b;color:#fff">
      退出看板（让 Kindle 回到原生界面）
    </button>
  </form>

  <form method="post" action="/control/cancel">
    <input type="hidden" name="token" value="{qs}">
    <button style="width:100%;padding:12px;font-size:15px;cursor:pointer;
    border:1px solid #bbb;border-radius:8px;background:#fff;color:#333">
      取消退出请求
    </button>
  </form>

  <div style="margin-top:24px;padding:14px;background:#fffbe6;
  border-left:3px solid #e6b800;font-size:13px;color:#555;line-height:1.7">
    <b>点了之后设备不会立刻退</b> —— 它大部分时间在深度休眠，收不到指令。<br>
    正确用法：点上面的按钮，然后<b>按一下 Kindle 的电源键唤醒</b>它，
    它醒来第一件事就是查这个请求，立刻退出。
  </div>

  <p style="margin-top:20px;font-size:13px">
    <a href="/?token={qs}" style="color:#06c">← 回看板预览</a>
  </p>
</div>
</body>"""


@app.get("/debug.json")
def debug():
    w = weather_src.get()
    t = token_src.get()
    return jsonify(
        weather_ok=w.ok,
        weather_error=w.error,
        current_temp=w.current.temp,
        current_desc=w.current.desc,
        forecast=[(d.weekday, d.desc, d.t_min, d.t_max) for d in w.daily],
        token_ok=t.ok,
        token_error=t.error,
        token_windows=[
            {
                "label": x.label,
                "used": x.used,
                "limit": x.limit,
                "remaining": x.remaining,
                # percent 是「剩余百分比」（看板画的也是这个）
                "percent": x.percent_remaining,
                "percent_used": x.percent_used,
                "reset_at": x.reset_at,
            }
            for x in t.windows
        ],
        battery_supported=True,
    )


@app.get("/fonts")
def fonts():
    return jsonify(found=fontutil.list_available(), using=renderer.regular)


@app.get("/control/quit")
def control_quit_help():
    """GET 直接访问时给个提示，避免误以为接口坏了。
    真正的退出要走 POST（浏览器表单），这是故意设计的：
    GET 容易被浏览器预取、也可能被误触，写操作不该用 GET。
    """
    qs = request.args.get("token") or ACCESS_TOKEN or ""
    return (
        f'<meta charset="utf-8">退出请求请用 POST。<a href="/control?token={qs}">'
        f"点这里打开遥控页</a>",
        405,
    )


if __name__ == "__main__":
    srv = cfg.get("server") or {}
    host = srv.get("host", "0.0.0.0")
    port = int(srv.get("port", 8787))

    # 端口占用是这个项目的高频故障：手动 nohup 起的野进程会一直占着端口，
    # 让 systemd 反复失败，而且 systemd 只报 "status=1/FAILURE"，
    # 看不出真正原因。这里主动检查一次，把话说清楚。
    import socket as _socket

    _probe = _socket.socket(_socket.AF_INET, _socket.SOCK_STREAM)
    try:
        if _probe.connect_ex(("127.0.0.1", port)) == 0:
            log.error(
                "端口 %d 已被占用，服务无法启动。\n"
                "  多半是有个手动启动的旧进程没退干净，先清掉它：\n"
                "    ss -lntp | grep %d        # 看是谁占着\n"
                "    pkill -f main.py          # 杀掉野进程\n"
                "    systemctl reset-failed kindle-dashboard   # 解除 systemd 熔断\n"
                "    systemctl restart kindle-dashboard",
                port,
                port,
            )
    finally:
        _probe.close()

    log.info("监听 http://%s:%d", host, port)
    app.run(host=host, port=port, threaded=True)
