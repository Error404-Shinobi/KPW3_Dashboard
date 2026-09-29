"""中文字体探测。

KPW3 面板要显示中文，服务器上有 CJK 字体是硬前提。这里按平台扫描常见路径，
找不到就报错而不是静默画出豆腐块。
"""

from __future__ import annotations

import os
import sys
from functools import lru_cache

from PIL import ImageFont

CANDIDATES = [
    # Debian / Ubuntu
    "/usr/share/fonts/opentype/noto/NotoSansCJKsc-Regular.otf",
    "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc",
    "/usr/share/fonts/truetype/noto/NotoSansCJK-Regular.ttc",
    "/usr/share/fonts/truetype/wqy/wqy-zenhei.ttc",
    "/usr/share/fonts/wqy-zenhei/wqy-zenhei.ttc",
    "/usr/share/fonts/truetype/wqy/wqy-microhei.ttc",
    "/usr/share/fonts/truetype/arphic/uming.ttc",
    # RHEL / CentOS / Arch
    "/usr/share/fonts/google-noto-cjk/NotoSansCJKsc-Regular.otf",
    "/usr/share/fonts/google-noto-cjk/NotoSansCJK-Regular.ttc",
    "/usr/share/fonts/noto-cjk/NotoSansCJKsc-Regular.otf",
    # CentOS 7 装 wqy-zenhei-fonts 后是这两个路径
    "/usr/share/fonts/wqy-zenhei/wqy-zenhei.ttc",
    "/usr/share/fonts/wqy-microhei/wqy-microhei.ttc",
    "/usr/share/fonts/wenquanyi/wqy-zenhei/wqy-zenhei.ttc",
    # macOS
    "/System/Library/Fonts/PingFang.ttc",
    "/System/Library/Fonts/STHeiti Light.ttc",
    "/Library/Fonts/Arial Unicode.ttf",
    # Windows（本地预览用）
    "C:/Windows/Fonts/msyh.ttc",
    "C:/Windows/Fonts/msyhl.ttc",
    "C:/Windows/Fonts/simhei.ttf",
    "C:/Windows/Fonts/simsun.ttc",
]


def list_available() -> list[str]:
    return [p for p in CANDIDATES if os.path.exists(p)]


def resolve(configured: str = "") -> str:
    """返回可用的字体路径，找不到就抛异常。"""
    if configured:
        if not os.path.exists(configured):
            raise FileNotFoundError(f"fonts 配置的字体不存在: {configured}")
        return configured

    found = list_available()
    if found:
        return found[0]

    hint = "apt install fonts-noto-cjk" if sys.platform.startswith("linux") else ""
    raise FileNotFoundError(
        "没找到中文字体。请安装 CJK 字体"
        + (f"（{hint}）" if hint else "")
        + "，或在 config.yaml 的 fonts.regular 里指定字体文件绝对路径。"
        + f"已扫描: {CANDIDATES[:4]} ..."
    )


@lru_cache(maxsize=64)
def load(path: str, size: int) -> ImageFont.FreeTypeFont:
    # TTC/OTC 集合字体默认取第 0 个 face，对 CJK 通常够用
    return ImageFont.truetype(path, size)


def main() -> None:
    """自检：列出本机找到的中文字体。"""
    found = list_available()
    if found:
        print("找到中文字体：")
        for p in found:
            print("  -", p)
    else:
        print("未找到任何已知的中文字体，请安装 fonts-noto-cjk。")


if __name__ == "__main__":
    main()
