#!/bin/sh
# ─────────────────────────────────────────────────────────────
# 服务器侧热修脚本（额度百分比语义修正）
#
# 修的是：MiniMax 额度进度条把「剩余」当「已用」画，导致满额度显示 0% 空条。
#
# 用法（在服务器上，以 root）：
#   cd /opt/kindle-dashboard
#   sh deploy_hotfix.sh
#
# 前提：新版 server/sources/token_usage.py、server/render.py、
#       server/main.py 已经 scp 上来了。
# ─────────────────────────────────────────────────────────────

set -e

DIR=$(cd "$(dirname "$0")" && pwd)
cd "$DIR"

echo "=== 1. 定位项目 ==="
if [ ! -d server ]; then
    echo "错误：当前目录 $DIR 下没有 server/，请先 cd 到项目根目录"
    exit 1
fi
echo "项目目录：$DIR"

echo ""
echo "=== 2. 语法自检 ==="
PY="server/.venv/bin/python"
[ -x "$PY" ] || PY="python3"
"$PY" -m py_compile \
    server/main.py \
    server/render.py \
    server/sources/token_usage.py \
    server/sources/weather.py
echo "语法检查通过（$PY）"

echo ""
echo "=== 3. 单测：真实调一次 MiniMax，看剩余百分比 ==="
cd server
"../$PY" - <<'PYEOF'
import sys
sys.path.insert(0, '.')
import yaml
from envutil import load_dotenv
load_dotenv()
from sources.token_usage import TokenSource

cfg = yaml.safe_load(open('config.yaml', encoding='utf-8'))
t = TokenSource(cfg.get('token') or {}).get()
print('ok =', t.ok, '| error =', t.error or '(无)')
for w in t.windows:
    print(f'  {w.label}: 剩余={w.percent_remaining}%  已用={w.percent_used}%  '
          f'reset={w.reset_at}')
if not t.ok:
    print('!! 数据源不可用，先查 server/.env 的 MINIMAX_SUBSCRIPTION_KEY')
    sys.exit(1)
PYEOF
cd "$DIR"

echo ""
echo "=== 4. 重启服务 ==="
systemctl restart kindle-dashboard
sleep 3
systemctl is-active kindle-dashboard && echo "服务已启动"

echo ""
echo "=== 5. 验收：debug.json 里的 percent 应等于「剩余」 ==="
curl -s --max-time 20 http://127.0.0.1:8787/debug.json \
    | "$PY" -c "import sys,json; d=json.load(sys.stdin); \
print('token_ok =', d['token_ok']); \
[print(f\"  {w['label']}: 剩余={w['percent']}%  已用={w['percent_used']}%\") for w in d['token_windows']]"

echo ""
echo "=== 完成 ==="
echo "浏览器打开 http://<服务器IP>:8787/ 看效果（页面会自动反旋显示）。"
echo "Kindle 侧下一次拉图就会变成「剩余」口径，不用改设备脚本。"
