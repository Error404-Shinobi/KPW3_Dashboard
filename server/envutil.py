"""从 .env 文件加载环境变量。

不想在每个 shell 里记 export / $env: / set 的写法差异时，把变量写进 .env 就行，
Windows、Linux、任何 shell 都一样。

优先级：真实环境变量 > .env。这样 systemd 里配的 Environment 依然说了算。
"""

from __future__ import annotations

import os
import pathlib


def load_dotenv(path: str | None = None) -> None:
    p = pathlib.Path(path) if path else pathlib.Path(__file__).parent / ".env"
    if not p.exists():
        return

    for line in p.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        key = key.strip()
        # 去掉成对引号，值里的 # 不当注释
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in ("'", '"'):
            value = value[1:-1]
        if key and key not in os.environ:
            os.environ[key] = value
