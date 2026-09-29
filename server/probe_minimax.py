"""探测 MiniMax Token Plan 接口的真实返回结构。

官方没有公开这个 endpoint 的完整响应 schema，社区调研文档里的字段名是推测的。
所以第一次接入先跑这个脚本，把真实返回打出来，确认字段名一致再上屏。

用法：
    export MINIMAX_SUBSCRIPTION_KEY=你的Subscription Key
    python probe_minimax.py

如果返回 401/403，说明你用的是 pay-as-you-go 的 API Key，不是 Subscription Key。
"""

from __future__ import annotations

import json
import os
import sys

import requests

from envutil import load_dotenv

# 两个域名路由到同一后端，哪个能通就用哪个（国内机器经常只有一个通）。
# 想只测某一个就设 MINIMAX_REMAINS_URL。
_ENDPOINTS = [
    os.environ.get("MINIMAX_REMAINS_URL") or "https://api.minimax.io/v1/token_plan/remains",
    "https://api.minimaxi.com/v1/token_plan/remains",
]
URLS = list(dict.fromkeys(_ENDPOINTS))


def _report_key_hint(key: str) -> None:
    """只看前缀给提示，绝不打印 key 本身。"""
    if key.startswith("sk-cp-"):
        print("key 前缀 sk-cp- → 是 Subscription Key，类型正确")
    elif key.startswith("sk-api-"):
        print("key 前缀 sk-api- → 这是 pay-as-you-go 的 Key，不是 Subscription Key，"
              "这个接口不认")
    else:
        print(f"key 前缀不是常见的 sk-cp- / sk-api-（长度 {len(key)}），请确认类型")
    if key != key.strip():
        print("警告：key 首尾有空白字符，复制时可能混进了空格")
    print()


def _report_region_hint() -> None:
    print("""
最常见的两个原因：

1) 区域不匹配（最常见）
   MiniMax 国际站和国内站是两套独立系统，凭证完全不互通：
     国际：platform.minimax.io   ->  api.minimax.io
     国内：platform.minimaxi.com ->  api.minimaxi.com
   在哪个平台拿的 key，就必须打那个区域的域名，跨区必定 invalid api key。
   确认你登录的是哪个域名，然后把 config.yaml 的 token.url 改成对应区域。

2) key 类型不对
   这个接口只认 Subscription Key（Billing / Token Plan 页面里那个），
   pay-as-you-go 的 API Key 不行。
""")


def main() -> None:
    load_dotenv()

    key = os.environ.get("MINIMAX_SUBSCRIPTION_KEY", "")
    if not key:
        print("没找到 key，两种方式任选其一：")
        print("  1) 在 server/.env 里写一行：MINIMAX_SUBSCRIPTION_KEY=你的key")
        print("  2) 设环境变量：export MINIMAX_SUBSCRIPTION_KEY=你的key"
              "（PowerShell 用 $env:MINIMAX_SUBSCRIPTION_KEY=\"...\"）")
        sys.exit(1)

    _report_key_hint(key)

    headers = {
        "Authorization": f"Bearer {key}",
        "Content-Type": "application/json",
    }
    js = None
    used_url = ""
    attempts: list[tuple[str, str]] = []

    for url in URLS:
        print(f"尝试 {url} ...")
        try:
            r = requests.get(url, headers=headers, timeout=15)
        except Exception as exc:  # noqa: BLE001
            print(f"  不通（{type(exc).__name__}），换下一个\n")
            attempts.append((url, "网络不通"))
            continue
        print(f"  HTTP {r.status_code}")
        try:
            js = r.json()
        except Exception:  # noqa: BLE001
            print(f"  响应不是 JSON：{r.text[:200]}\n")
            attempts.append((url, "非 JSON 响应"))
            continue

        # 业务错误也要换域名重试 —— 跨区错误的表现就是 HTTP 200 + invalid api key
        base = js.get("base_resp") or {}
        code = base.get("status_code", js.get("code", 0))
        msg = base.get("status_msg") or js.get("message") or js.get("msg") or ""
        if code not in (0, None, "0"):
            print(f"  业务错误 {code}：{msg}，换下一个域名再试\n")
            attempts.append((url, f"{code} {msg}"))
            js = None
            continue

        used_url = url
        break

    if js is None:
        print("=== 所有域名都没拿到成功响应 ===")
        for u, why in attempts:
            print(f"  {u}\n    -> {why}")
        _report_region_hint()
        sys.exit(2)

    print("\n=== 原始响应 ===")
    print(json.dumps(js, ensure_ascii=False, indent=2))

    # 看一眼是不是业务错误
    base = js.get("base_resp") or {}
    code = base.get("status_code", js.get("code", 0))
    if code not in (0, None, "0"):
        print("\n=== 这是业务错误，不是成功响应 ===")
        print(f"status_code = {code}")
        print(f"status_msg  = {base.get('status_msg') or js.get('message') or js.get('msg')}")
        print("\n常见原因：用了 pay-as-you-go 的 API Key，"
              "而这个接口只认 Subscription Key。")
        sys.exit(2)

    # 真实结构：额度按模型拆在 model_remains[] 里，
    # total/usage_count 恒为 0，能用的是 remaining_percent
    models = js.get("model_remains") or []
    print("\n=== 解析结果 ===")

    if not models:
        print("  响应里没有 model_remains 数组，和已知结构不符。")
        print("  实际拿到的顶层字段：", list(js.keys()))
        print("  把这段响应发给维护者更新解析逻辑。")
        sys.exit(3)

    for m in models:
        print(
            f"  {m.get('model_name')}: "
            f"5小时剩余 {m.get('current_interval_remaining_percent')}% | "
            f"周剩余 {m.get('current_weekly_remaining_percent')}%"
        )

    names = [m.get("model_name") for m in models]
    print(f"\n可用模型: {names}")
    print("确认 config.yaml 的 token.model 是其中之一（默认 general）")
    print(f"确认 config.yaml 的 token.url 是这次实际连通的: {used_url}")


if __name__ == "__main__":
    main()
