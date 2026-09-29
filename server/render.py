"""把数据画成 KPW3 能直接刷屏的 PNG。

★ 方向与格式（实测 + 官方 wiki 双重确认，别乱改）：

KPW3 的 framebuffer 是 **1072 × 1448 竖屏**，`eips -i` 的输出是：

    xres: 1072      yres: 1448
    bits_per_pixel: 8   grayscale: 1   rotate: 3

而 `eips -g` 只做一件事：把图片按**行优先**原样贴到 framebuffer 的内存起点，
**它没有任何旋转参数**（wiki 上全部选项只有 -g -b -w -f -x -y -v）。

所以如果直接送一张 1448×1072 的图，会被解释成"宽度只有 1072"，
于是：图被切掉右边、错位、看起来像竖屏版本，还会干扰 framework 弹出键盘。

正确做法：按横屏布局画画（画着舒服），最后 `rotate(90)` 转成 1072×1448，
并转成 8 位灰度 PNG。这样 Kindle 上看起来才是正的横屏。

layout 里的坐标全部是「转之前」的横屏坐标系，改尺寸只动 Layout 一处。
"""

from __future__ import annotations

import datetime as dt
import logging
from dataclasses import dataclass
from typing import Any

from PIL import Image, ImageDraw, ImageOps

from fontutil import load, resolve

log = logging.getLogger(__name__)

BLACK = 0
DARK = 60
GRAY = 128
LIGHT = 200
BG = 255

WEEKDAY_ZH = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]


def _fmt_reset(value: str) -> str:
    """ISO 时间压成短格式：今天显示 21:00，跨天显示 09-28。"""
    if not value:
        return ""
    try:
        t = dt.datetime.fromisoformat(value)
    except ValueError:
        return value[:10]
    if t.date() == dt.datetime.now().date():
        return f"{t.hour:02d}:{t.minute:02d}"
    return t.strftime("%m-%d")


@dataclass
class Layout:
    """横屏画布尺寸（转 90° 之前）。

    1448×1072 是「横着用」的尺寸；rotate(90) 之后正好是 KPW3 framebuffer
    要求的 1072×1448 竖屏。
    """

    width: int = 1448
    height: int = 1072
    margin: int = 72

    y_date: int = 64
    y_weekday: int = 150
    y_rule1: int = 225

    y_city: int = 258
    y_temp: int = 300
    y_desc: int = 478
    y_meta: int = 548

    y_forecast_top: int = 600
    y_fc_weekday: int = 620
    y_fc_desc: int = 678
    y_fc_temp: int = 732
    y_forecast_bottom: int = 780

    y_rule2: int = 815
    y_token_title: int = 845
    # 最多两个配额窗口（MiniMax 的 5 小时 + 周）
    y_token_row1: int = 903
    y_token_bar1: int = 928
    y_token_row2: int = 985
    y_token_bar2: int = 1010
    bar_h: int = 32
    # 只有一个窗口时，下面补明细和重置时间
    y_token_extra: int = 985
    y_token_reset: int = 1028
    y_token_err: int = 950


@dataclass
class Payload:
    # 类型必须是注解过的，否则 dataclass 不把它当字段
    weather: Any = None
    token: Any = None
    battery: int | None = None
    city: str = ""
    now: dt.datetime | None = None


class Renderer:
    def __init__(self, cfg: dict):
        d = cfg.get("display") or {}
        self.layout = Layout(
            width=int(d.get("width", 1448)),
            height=int(d.get("height", 1072)),
        )
        self.gray_levels = int(d.get("grayscale_levels", 16))
        # 是否输出「旋转 90° 的竖屏灰度图」。Kindle 端用 eips 刷屏必须开。
        # 想在浏览器里直观看横屏渲染效果时可以临时关掉。
        self.rotate = bool(d.get("rotate", True))

        self.cfg = cfg
        fonts = cfg.get("fonts") or {}
        regular_path = resolve(fonts.get("regular", "") or "")
        display_path = resolve(fonts.get("display", "") or regular_path)
        self.regular = regular_path
        self.display = display_path
        log.info("字体: regular=%s display=%s", regular_path, display_path)

    def now(self) -> dt.datetime:
        """按配置时区取当前时间。

        服务器时区经常是 UTC，直接用 datetime.now() 会差 8 小时，
        所以按 location.timezone 取。取不到就退回服务器本地时间。
        """
        tzname = ((self.cfg or {}).get("location") or {}).get("timezone") or "Asia/Shanghai"
        try:
            from zoneinfo import ZoneInfo

            return dt.datetime.now(ZoneInfo(tzname))
        except Exception:  # noqa: BLE001
            return dt.datetime.now()

    # --- helpers -------------------------------------------------------
    def _f(self, size: int, display: bool = False):
        return load(self.display if display else self.regular, size)

    def render(self, p: Payload, rotate: bool | None = None) -> Image.Image:
        """画一张图。

        先在横屏画布（1448×1072）上布局，再按 Kindle 要求变换：
        rotate 90° 逆时针 + 8 位灰度 L 模式 → 1072×1448。

        rotate 参数（默认 None = 用配置里的 self.rotate）：
          - None：跟着配置走，**Kindle 走这条**（要竖图，eips 不认旋转）
          - False：跳过旋转，输出 1448×1072 横图 —— **浏览器预览页走这条**
          - True：强制旋转

        ★ 为什么要开这个口子：
          预览页原本靠 CSS `transform: rotate(-90deg)` 把竖图摆正，
          实测不可靠（图片每 60 秒换 src，重排后旋转会丢，页面就是躺倒的）。
          与其跟浏览器渲染时序较劲，不如让服务端直接给一张摆正的图。
          反正渲染只要几十毫秒，两份各留一份缓存，互不干扰。
        """
        if rotate is None:
            rotate = self.rotate

        L = self.layout
        img = Image.new("L", (L.width, L.height), BG)
        d = ImageDraw.Draw(img)
        M = L.margin
        now = p.now or dt.datetime.now()

        self._header(d, now, p.battery, L, M)
        d.line([(M, L.y_rule1), (L.width - M, L.y_rule1)], fill=LIGHT, width=2)

        self._weather(d, p, L, M)
        self._forecast(d, p, L, M)

        d.line([(M, L.y_rule2), (L.width - M, L.y_rule2)], fill=LIGHT, width=2)
        self._token(d, p, L, M)

        if self.gray_levels and self.gray_levels < 256:
            # posterize(4) -> 每通道 4bit，正好 16 级灰
            img = ImageOps.posterize(img, 4)

        if rotate:
            # ★ 关键：旋转后才能喂给 eips。
            # 横屏图转 90° 逆时针 → 宽高变成 1072×1448，正好贴合 framebuffer。
            # 顺时针会上下颠倒，别改这个方向。
            #
            # 用 transpose(2) 而不是 Image.Transpose.ROTATE_90：
            # 后者要 Pillow >= 9.1 才有，requirements 放的是 >= 8.0，
            # 老版本上会直接 AttributeError 让服务起不来。
            # 2 就是 ROTATE_90 的固定常量值，所有版本都认。
            img = img.transpose(2)  # 2 = Image.ROTATE_90（逆时针）
            # 转完仍是 L 模式（8 位单通道），但显式声明一次更保险
            if img.mode != "L":
                img = img.convert("L")
        return img

    # --- sections ------------------------------------------------------
    def _header(self, d, now, battery, L, M):
        # 左：日期 + 星期
        date_str = f"{now.year}年{now.month}月{now.day}日"
        d.text((M, L.y_date), date_str, font=self._f(60), fill=BLACK, anchor="la")

        week = WEEKDAY_ZH[now.weekday()]
        d.text((M, L.y_weekday), week, font=self._f(34), fill=DARK, anchor="la")

        # 右：时间（大字，显示到分钟）+ 电量
        d.text(
            (L.width - M, L.y_date - 6),
            f"{now.hour:02d}:{now.minute:02d}",
            font=self._f(72, display=True),
            fill=BLACK,
            anchor="ra",
        )

        if battery is not None:
            self._battery(d, L.width - M, L.y_weekday + 2, battery)

    def _battery(self, d, right_x, top_y, pct):
        w, h = 66, 32
        x0 = right_x - w
        y0 = top_y
        d.rectangle([x0, y0, x0 + w, y0 + h], outline=BLACK, width=2)
        d.rectangle([x0 + w + 3, y0 + h * 0.28, x0 + w + 8, y0 + h * 0.72], fill=BLACK)

        pct = max(0, min(100, int(pct)))
        inner_pad = 4
        avail = w - inner_pad * 2 - 2
        fill_w = int(avail * pct / 100)
        d.rectangle(
            [x0 + inner_pad, y0 + inner_pad, x0 + inner_pad + avail, y0 + h - inner_pad],
            fill=235,
        )
        if fill_w > 0:
            d.rectangle(
                [x0 + inner_pad, y0 + inner_pad, x0 + inner_pad + fill_w, y0 + h - inner_pad],
                fill=BLACK,
            )

        d.text(
            (x0 - 14, y0 + h // 2),
            f"{pct}%",
            font=self._f(28),
            fill=BLACK,
            anchor="rm",
        )

    def _weather(self, d, p, L, M):
        w = p.weather
        d.text((M, L.y_city), p.city or "--", font=self._f(30), fill=GRAY, anchor="la")

        if not w or not w.ok:
            d.text((M, L.y_temp), "--", font=self._f(150, display=True), fill=BLACK, anchor="la")
            d.text(
                (M, L.y_desc),
                (w.error if w else "天气未启用")[:28] or "天气不可用",
                font=self._f(30),
                fill=GRAY,
                anchor="la",
            )
            return

        c = w.current
        temp = "--" if c.temp is None else f"{round(c.temp)}°"
        d.text((M, L.y_temp), temp, font=self._f(150, display=True), fill=BLACK, anchor="la")

        # 描述放在温度右边，避免大字号把布局撑爆
        d.text((M + 260, L.y_temp + 96), c.desc, font=self._f(46), fill=BLACK, anchor="la")

        bits = []
        if c.humidity is not None:
            bits.append(f"湿度 {round(c.humidity)}%")
        if c.feels_like is not None:
            bits.append(f"体感 {round(c.feels_like)}°")
        if c.wind is not None:
            bits.append(f"风 {round(c.wind)} km/h")
        if bits:
            d.text((M, L.y_meta), " · ".join(bits), font=self._f(28), fill=DARK, anchor="la")

    def _forecast(self, d, p, L, M):
        w = p.weather
        if not w or not w.ok or not w.daily:
            return

        cols = min(5, len(w.daily))
        col_w = (L.width - M * 2) / cols
        for i in range(cols):
            day = w.daily[i]
            cx = M + col_w * i + col_w / 2
            d.text((cx, L.y_fc_weekday), day.weekday, font=self._f(30), fill=BLACK, anchor="ma")
            d.text((cx, L.y_fc_desc), day.desc, font=self._f(28), fill=DARK, anchor="ma")
            hi = "--" if day.t_max is None else f"{round(day.t_max)}°"
            lo = "--" if day.t_min is None else f"{round(day.t_min)}°"
            d.text((cx, L.y_fc_temp), f"{lo} / {hi}", font=self._f(32), fill=BLACK, anchor="ma")

            if i > 0:
                x = M + col_w * i
                d.line([(x, L.y_forecast_top), (x, L.y_forecast_bottom)], fill=225, width=2)

    def _token(self, d, p, L, M):
        t = p.token
        if not t:
            return

        d.text((M, L.y_token_title), t.label, font=self._f(32), fill=DARK, anchor="la")

        if not t.ok:
            d.text(
                (M, L.y_token_err),
                t.error[:44] or "额度数据源不可用",
                font=self._f(28),
                fill=GRAY,
                anchor="la",
            )
            return

        rows = t.windows[:2]

        for i, w in enumerate(rows):
            y_label = L.y_token_row1 if i == 0 else L.y_token_row2
            y_bar = L.y_token_bar1 if i == 0 else L.y_token_bar2
            self._token_row(d, L, M, w, y_label, y_bar)

        # 只有一个窗口时，下面还有空间，补一行具体数字
        if len(rows) == 1:
            w = rows[0]

            def fmt(v):
                return f"{v:,.0f}" if v is not None else "--"

            line = f"已用 {fmt(w.used)} / {fmt(w.limit)} {t.unit}"
            d.text((M, L.y_token_extra), line, font=self._f(30), fill=BLACK, anchor="la")
            if w.reset_at:
                d.text(
                    (M, L.y_token_reset),
                    f"剩余 {fmt(w.remaining)} · 重置 {w.reset_at[:16]}",
                    font=self._f(24),
                    fill=DARK,
                    anchor="la",
                )

    def _token_row(self, d, L, M, w, y_label, y_bar):
        # 标签 + 重置时间 | 进度条 | 百分比，横向三段，避免文字压到条上
        label_w = 270
        pct_w = 158
        x0 = M + label_w
        x1 = L.width - M - pct_w
        h = L.bar_h

        d.text((M, y_label), w.label, font=self._f(30), fill=BLACK, anchor="la")
        if w.reset_at:
            d.text(
                (M + 108, y_label + 4),
                f"重置 {_fmt_reset(w.reset_at)}",
                font=self._f(22),
                fill=GRAY,
                anchor="la",
            )

        # ★ 口径：条上画的是「已消耗」—— 空白 = 还能用，黑条 = 用掉了。
        #
        #   数据层给的仍然是「剩余」（见 Window 的注释），这里翻一下再画。
        #   历史：最早画的是剩余（满额 = 满黑条），后来按实际使用习惯改成
        #   已消耗 —— 「还剩多少」看右边的数字，「用掉多少」看条的长度。
        pct_remaining = w.percent_remaining
        pct_used = None if pct_remaining is None else max(0.0, 100.0 - pct_remaining)

        right = L.width - M
        pct_text = "--" if pct_used is None else f"{pct_used:.0f}%"
        d.text(
            (right, y_label + 6),
            pct_text,
            font=self._f(38, display=True),
            fill=BLACK,
            anchor="ra",
        )
        if pct_used is not None:
            # 「用」放在数字左侧，免得被读成"剩余"。按实际文字宽度定位，不含糊估。
            try:
                tw = d.textlength(pct_text, font=self._f(38, display=True))
            except Exception:
                tw = len(pct_text) * 22
            d.text(
                (right - tw - 10, y_label + 14),
                "用",
                font=self._f(24),
                fill=GRAY,
                anchor="ra",
            )

        # 底：浅灰 —— 代表"还能用"的那段空间，视觉上接近空白
        d.rectangle([x0, y_bar, x1, y_bar + h], fill=232)
        # 已消耗的部分：填黑（从左边开始长）
        if pct_used is not None:
            fw = int((x1 - x0) * pct_used / 100)
            d.rectangle([x0, y_bar, x0 + fw, y_bar + h], fill=BLACK)
        d.rectangle([x0, y_bar, x1, y_bar + h], outline=BLACK, width=2)
