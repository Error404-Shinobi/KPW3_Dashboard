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


def looks_like_placeholder(value: str | None) -> bool:
    """这个配置值是不是"还没填的占位符"？

    ★ 为什么需要这个函数
      给用户的模板里放的是占位符（`<YOUR_API_KEY>` 这种）。用户忘了改
      就直接用的话，程序会拿这串东西去发 HTTP 请求 —— 而报错信息
      **非常误导**：HTTP 头里塞了非 ASCII 会报编码错误
      （`latin-1 codec can't encode...`），看起来像代码 bug，
      完全联想不到"密钥忘了填"。

      这个项目已经在 config.yaml 和 config.env 上各踩过一次，
      所以把识别逻辑收在一个地方，两个数据源共用。

    判定规则（**宁可误报也不要漏报** —— 误报只是让用户去检查一下，
    漏报则是给人一个看不懂的报错）：
      - 空 / 只有空白
      - 含 `<` 或 `>`    ← 尖括号占位符的典型特征，正常密钥不会有
      - 含非 ASCII       ← 旧模板留下的中文占位符
    """
    v = (value or "").strip()
    if not v:
        return True
    if "<" in v or ">" in v:
        return True
    try:
        v.encode("ascii")
    except UnicodeEncodeError:
        return True
    return False
