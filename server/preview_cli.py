"""不启 HTTP 服务，直接生成一张 PNG 到文件。

调布局时比起服务再刷墨水屏快得多：
    python preview_cli.py preview.png
    DASH_FAKE_DATA=1 python preview_cli.py preview.png   # token 用假数
"""

from __future__ import annotations

import datetime as dt
import os
import sys

import yaml

from envutil import load_dotenv
from render import Payload, Renderer
from sources.token_usage import TokenSource
from sources.weather import WeatherSource


def main() -> None:
    load_dotenv()
    out = sys.argv[1] if len(sys.argv) > 1 else "preview.png"

    path = os.environ.get("CONFIG_PATH", "config.yaml")
    if not os.path.exists(path):
        print(f"缺少 {path}，先 cp config.yaml.example config.yaml")
        sys.exit(1)

    with open(path, "r", encoding="utf-8") as fh:
        cfg = yaml.safe_load(fh) or {}

    renderer = Renderer(cfg)
    weather = WeatherSource(cfg.get("weather") or {}, cfg.get("location") or {})
    token = TokenSource(cfg.get("token") or {})

    batt = os.environ.get("DASH_BATT")
    payload = Payload(
        weather=weather.get(),
        token=token.get(),
        battery=int(batt) if batt else 85,
        city=(cfg.get("location") or {}).get("name", ""),
        now=renderer.now(),
    )

    renderer.render(payload).save(out)
    w = payload.weather
    t = payload.token
    print(f"已生成 {out}")
    print(f"  天气: {'OK' if w.ok else '失败 ' + w.error} "
          f"{w.current.temp}° {w.current.desc}")
    print(f"  额度: {'OK' if t.ok else '失败 ' + t.error}")
    for x in t.windows:
        pct = "n/a" if x.percent is None else f"{x.percent:.0f}%"
        print(f"    {x.label}: {x.used}/{x.limit} ({pct}) 重置 {x.reset_at}")


if __name__ == "__main__":
    main()
