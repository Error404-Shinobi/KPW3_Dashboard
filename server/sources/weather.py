"""天气数据源：Open-Meteo（免费，无需 API key）。"""

from __future__ import annotations

import logging
import time
from dataclasses import dataclass, field

import requests

log = logging.getLogger(__name__)

# WMO weather interpretation codes -> 中文
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

WEEKDAY_ZH = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]


@dataclass
class Current:
    temp: float | None = None
    code: int | None = None
    humidity: int | None = None
    wind: float | None = None
    feels_like: float | None = None

    @property
    def desc(self) -> str:
        return WMO_ZH.get(self.code, "未知") if self.code is not None else "--"


@dataclass
class Daily:
    date: str = ""
    weekday: str = ""
    code: int | None = None
    t_min: float | None = None
    t_max: float | None = None

    @property
    def desc(self) -> str:
        return WMO_ZH.get(self.code, "未知") if self.code is not None else "--"


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
        url = self.cfg.get("url") or "https://api.open-meteo.com/v1/forecast"
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
            wd = "--"
            try:
                import datetime as _dt

                y, m, dd = (int(x) for x in dates[i].split("-"))
                wd = WEEKDAY_ZH[_dt.date(y, m, dd).weekday()]
            except Exception:  # noqa: BLE001
                pass
            daily.append(
                Daily(
                    date=dates[i] if i < len(dates) else "",
                    weekday=wd,
                    code=codes[i] if i < len(codes) else None,
                    t_max=tmax[i] if i < len(tmax) else None,
                    t_min=tmin[i] if i < len(tmin) else None,
                )
            )

        return Weather(ok=True, current=current, daily=daily)
