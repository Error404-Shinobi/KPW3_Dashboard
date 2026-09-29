"""天气数据源。

支持两家，由 config 里的 `weather.provider` 选：

  - `open-meteo`（默认）：免费、不需要 API key
  - `caiyun`：彩云天气，需要 token（免费额度每天 1000 次）

两家返回的"天气现象"表达方式完全不同：
  - Open-Meteo 给的是 **WMO 数字码**（0/1/2/…）
  - 彩云给的是 **skycon 字符串枚举**（CLEAR_DAY / LIGHT_RAIN / …）

所以在 Current / Daily 里各留一个字段，`desc` 属性按哪个有值取哪个 ——
调用方（render.py）不用关心底层是哪家。
"""

from __future__ import annotations

import datetime as dt
import logging
import os
import time
from dataclasses import dataclass, field

import requests

log = logging.getLogger(__name__)

WEEKDAY_ZH = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]

# Open-Meteo 的 WMO weather interpretation codes -> 中文
# https://open-meteo.com/en/docs
WMO_ZH = {
    0: "晴",
    1: "晴间多云",
    2: "多云",
    3: "阴",
    45: "雾",
    48: "冻雾",
    51: "毛毛雨",
    53: "小雨",
    55: "中雨",
    56: "冻雨",
    57: "冻雨",
    61: "小雨",
    63: "中雨",
    65: "大雨",
    66: "冻雨",
    67: "冻雨",
    71: "小雪",
    73: "中雪",
    75: "大雪",
    77: "米雪",
    80: "阵雨",
    81: "强阵雨",
    82: "暴雨",
    85: "阵雪",
    86: "强阵雪",
    95: "雷阵雨",
    96: "雷阵雨伴冰雹",
    99: "强雷暴",
}

# 彩云的 skycon 枚举 -> 中文
# 官方对照表：https://docs.caiyunapp.com/weather-api/v2/v2.6/tables/skycon.html
# ★ 注意它是**字符串**不是数字码，而且晴/多云区分白天和夜间
SKYCON_ZH = {
    "CLEAR_DAY": "晴",
    "CLEAR_NIGHT": "晴",
    "PARTLY_CLOUDY_DAY": "多云",
    "PARTLY_CLOUDY_NIGHT": "多云",
    "CLOUDY": "阴",
    "LIGHT_HAZE": "轻度雾霾",
    "MODERATE_HAZE": "中度雾霾",
    "HEAVY_HAZE": "重度雾霾",
    "LIGHT_RAIN": "小雨",
    "MODERATE_RAIN": "中雨",
    "HEAVY_RAIN": "大雨",
    "STORM_RAIN": "暴雨",
    "FOG": "雾",
    "LIGHT_SNOW": "小雪",
    "MODERATE_SNOW": "中雪",
    "HEAVY_SNOW": "大雪",
    "STORM_SNOW": "暴雪",
    "DUST": "浮尘",
    "SAND": "沙尘",
    "WIND": "大风",
}

# Open-Meteo 的默认端点（混合模式下也要用它拿预报）
OM_DEFAULT_URL = "https://api.open-meteo.com/v1/forecast"
# 彩云的默认端点
CAIYUN_DEFAULT_URL = "https://api.caiyunapp.com/v2.6"


def _num(v) -> float | None:
    """安全转 float；转不了就返回 None（上游偶尔给 null 或字符串）。"""
    try:
        return float(v)
    except (TypeError, ValueError):
        return None


def _weekday_of(date_str: str) -> str:
    """'2026-09-29' 或 '2026-09-29T00:00+08:00' → '周二'。"""
    try:
        y, m, d = (int(x) for x in str(date_str)[:10].split("-"))
        return WEEKDAY_ZH[dt.date(y, m, d).weekday()]
    except Exception:  # noqa: BLE001 - 日期格式异常不该拖垮天气
        return "--"


@dataclass
class Current:
    temp: float | None = None
    # WMO 数字码 —— Open-Meteo 用这个
    code: int | None = None
    # 彩云的字符串枚举。这两个字段只会有一个被填。
    skycon: str = ""
    humidity: int | None = None
    wind: float | None = None
    feels_like: float | None = None

    @property
    def desc(self) -> str:
        if self.skycon:
            return SKYCON_ZH.get(self.skycon, self.skycon)
        if self.code is not None:
            return WMO_ZH.get(self.code, "未知")
        return "--"


@dataclass
class Daily:
    date: str = ""
    weekday: str = ""
    code: int | None = None
    skycon: str = ""
    t_min: float | None = None
    t_max: float | None = None

    @property
    def desc(self) -> str:
        if self.skycon:
            return SKYCON_ZH.get(self.skycon, self.skycon)
        if self.code is not None:
            return WMO_ZH.get(self.code, "未知")
        return "--"


@dataclass
class Weather:
    ok: bool = False
    error: str = ""
    current: Current = field(default_factory=Current)
    daily: list[Daily] = field(default_factory=list)


class WeatherSource:
    def __init__(self, cfg: dict, loc: dict):
        self.cfg = cfg or {}
        self.loc = loc or {}
        self._cache: Weather | None = None
        self._stamp = 0.0
        self.provider = str(self.cfg.get("provider") or "open-meteo").strip().lower()

    def enabled(self) -> bool:
        return bool(self.cfg.get("enabled", True))

    def _ttl(self) -> int:
        try:
            return int(self.cfg.get("update_secs", 1800))
        except (TypeError, ValueError):
            return 1800

    def get(self) -> Weather:
        if not self.enabled():
            return Weather(ok=False, error="disabled")
        if self._cache and (time.time() - self._stamp) < self._ttl():
            return self._cache

        try:
            w = self._fetch()
        except Exception as exc:  # noqa: BLE001 - 上游失败不应拖垮整个看板
            log.warning("weather fetch failed: %s", exc)
            w = Weather(ok=False, error=str(exc))
            # 上游挂了就沿用旧数据，屏幕不至于变空白
            if self._cache:
                return self._cache

        self._cache = w
        self._stamp = time.time()
        return w

    def _fetch(self) -> Weather:
        if self.provider in ("caiyun", "caiyunapp", "彩云"):
            # ★ 彩云免费版只给 3 天逐日预报（去掉今天就剩 2 天），
            #   而它的强项是**实况**（1km 分辨率）。
            #   所以实况用彩云、逐日预报用 Open-Meteo（免费给 5 天）——
            #   两家的强弱正好互补。
            return self._fetch_caiyun_with_om_forecast()
        return self._fetch_openmeteo()

    def _om_url(self) -> str:
        """Open-Meteo 的地址。

        ★ 混合模式下 `weather.url` 是彩云的地址，不能直接拿它去打 Open-Meteo
        （会 404/400）。所以要分开：优先用专门的 `forecast_url`，
        只有在 provider 本身就是 open-meteo 时才回落到 `url`。
        """
        if self.provider in ("caiyun", "caiyunapp", "彩云"):
            return self.cfg.get("forecast_url") or OM_DEFAULT_URL
        return self.cfg.get("url") or OM_DEFAULT_URL

    # ── Open-Meteo（免费，无需 key）────────────────────────────────
    def _fetch_openmeteo(self) -> Weather:
        url = self._om_url()
        params = {
            "latitude": self.loc.get("latitude"),
            "longitude": self.loc.get("longitude"),
            "current": "temperature_2m,relative_humidity_2m,apparent_temperature,"
            "weather_code,wind_speed_10m",
            "daily": "weather_code,temperature_2m_max,temperature_2m_min",
            "timezone": self.loc.get("timezone") or "auto",
            "forecast_days": 6,
        }
        r = requests.get(url, params=params, timeout=15)
        r.raise_for_status()
        js = r.json()

        cur = js.get("current") or {}
        current = Current(
            temp=cur.get("temperature_2m"),
            code=cur.get("weather_code"),
            humidity=cur.get("relative_humidity_2m"),
            wind=cur.get("wind_speed_10m"),
            feels_like=cur.get("apparent_temperature"),
        )

        d = js.get("daily") or {}
        dates = d.get("time") or []
        codes = d.get("weather_code") or []
        tmax = d.get("temperature_2m_max") or []
        tmin = d.get("temperature_2m_min") or []

        # 第 0 天是今天，预报从明天开始取 5 天
        daily: list[Daily] = []
        for i in range(1, min(6, len(dates))):
            daily.append(
                Daily(
                    date=dates[i] if i < len(dates) else "",
                    weekday=_weekday_of(dates[i] if i < len(dates) else ""),
                    code=codes[i] if i < len(codes) else None,
                    t_max=tmax[i] if i < len(tmax) else None,
                    t_min=tmin[i] if i < len(tmin) else None,
                )
            )

        return Weather(ok=True, current=current, daily=daily)

    # ── 彩云天气（需要 token）──────────────────────────────────────
    def _fetch_caiyun(self) -> Weather:
        env_name = self.cfg.get("token_env") or "CAIYUN_TOKEN"
        token = (os.environ.get(env_name) or "").strip()
        if not token:
            return Weather(ok=False, error=f"未配置 {env_name}")

        lon = self.loc.get("longitude")
        lat = self.loc.get("latitude")
        if lon is None or lat is None:
            return Weather(ok=False, error="location 里缺经纬度")

        base = (self.cfg.get("url") or CAIYUN_DEFAULT_URL).rstrip("/")
        # ★ 路径里是「经度,纬度」—— 顺序和很多人的直觉相反，别搞反。
        #   （响应里的 location 字段反过来是 [纬度, 经度]，也不一样）
        url = f"{base}/{token}/{lon},{lat}/weather"
        params = {
            "lang": "zh_CN",
            "unit": "metric",
            "dailysteps": 6,      # 今天 + 未来 5 天
            # 不要逐小时数据，省流量（默认会给 48 小时）
            "hourlysteps": 1,
        }
        r = requests.get(url, params=params, timeout=15)
        r.raise_for_status()
        js = r.json()

        status = js.get("status")
        if status != "ok":
            err = js.get("error") or js.get("message") or ""
            return Weather(ok=False, error=f"caiyun {status} {err}".strip())

        result = js.get("result") or {}
        rt = result.get("realtime") or {}

        # ★ 彩云的湿度是 0~1 的比例，不是百分数 —— 要 ×100
        humidity = _num(rt.get("humidity"))
        humidity = None if humidity is None else int(round(humidity * 100))

        current = Current(
            temp=_num(rt.get("temperature")),
            skycon=str(rt.get("skycon") or ""),
            humidity=humidity,
            wind=_num((rt.get("wind") or {}).get("speed")),
            feels_like=_num(rt.get("apparent_temperature")),
        )

        # daily 是「并列数组」结构（不是按天嵌套的对象）：
        #   temperature: [{date, max, min, avg}, ...]
        #   skycon:      [{date, value}, ...]
        daily_raw = result.get("daily") or {}
        temps = daily_raw.get("temperature") or []
        skycons = daily_raw.get("skycon") or []

        daily: list[Daily] = []
        for i in range(1, min(6, len(temps))):
            t = temps[i] or {}
            sc = skycons[i] if i < len(skycons) else {}
            date = str(t.get("date") or "")[:10]
            daily.append(
                Daily(
                    date=date,
                    weekday=_weekday_of(date),
                    skycon=str((sc or {}).get("value") or ""),
                    t_max=_num(t.get("max")),
                    t_min=_num(t.get("min")),
                )
            )

        return Weather(ok=True, current=current, daily=daily)

    def _fetch_caiyun_with_om_forecast(self) -> Weather:
        """混合模式：实况走彩云，逐日预报走 Open-Meteo。

        为什么这么分（实测得出的结论）：
          - 彩云的强项是**实况**（1km 分辨率、分钟级降水）；
            但免费版**只给 3 天逐日预报**（去掉今天就剩 2 天），
            看板的预报区会空一半。
          - Open-Meteo 免费给 **5 天**预报，但实况精细度不如彩云。
        两边各取所长，而且都不花钱。

        容错策略（失败方向选安全的那一侧）：
          - 彩云挂了 → 整体失败，让上层沿用旧缓存，屏幕不会变空白
          - 预报挂了 → **保留彩云那 2 天**，不整体失败（聊胜于无）
        """
        w = self._fetch_caiyun()
        if not w.ok:
            return w

        try:
            om = self._fetch_openmeteo()
        except Exception as exc:  # noqa: BLE001 - 预报拿不到不该拖垮实况
            log.warning("forecast fallback (open-meteo) failed: %s", exc)
            return w

        if om.ok and om.daily:
            w.daily = om.daily
        else:
            log.warning("open-meteo forecast unavailable: %s", om.error)
        return w
