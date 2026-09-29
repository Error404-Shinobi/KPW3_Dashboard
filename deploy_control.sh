#!/bin/sh
# ─────────────────────────────────────────────────────────────
# 服务器侧热修脚本（服务端遥控退出看板）
#
# 新增：网页上点「退出看板」→ 设备下次醒来自己退出、回原生界面。
#
# 用法（在服务器上，以 root）：
#   cd /opt/kindle-dashboard
#   sh deploy_control.sh
#
# 前提：新版 server/control.py（**新文件**）、server/main.py、
#       server/render.py、server/sources/token_usage.py 已 scp 上来。
#
# 只想跑本次新增的功能，不想动额度修正的话，
# 把下面第 3 步的单测当参考即可（两边代码是兼容的）。
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
echo "=== 2. 语法自检（含新文件 control.py）==="
PY="server/.venv/bin/python"
[ -x "$PY" ] || PY="python3"
for f in server/control.py server/main.py server/render.py \
         server/sources/token_usage.py server/sources/weather.py; do
    if [ ! -f "$f" ]; then
        echo "!! 缺文件：$f —— 先把新版 scp 上来再跑本脚本"
        exit 1
    fi
done
"$PY" -m py_compile \
    server/control.py \
    server/main.py \
    server/render.py \
    server/sources/token_usage.py \
    server/sources/weather.py
echo "语法检查通过（$PY）"

echo ""
echo "=== 3. 检查 DASH_ACCESS_TOKEN ==="
# ★ 退出是写操作，必须要有 token 才允许。
#   没设的话服务端会拒绝所有写请求（返回 403），按钮点了没反应。
if grep -q '^DASH_ACCESS_TOKEN=..*' server/.env 2>/dev/null; then
    echo "已设置 DASH_ACCESS_TOKEN（值不回显）"
else
    echo "!! server/.env 里没有 DASH_ACCESS_TOKEN"
    echo "   遥控退出需要它。现在给你生成一个随机值并写入："
    _tk=$(head -c 18 /dev/urandom | od -An -tx1 | tr -d ' \n')
    printf '\n# 看板访问令牌 + 遥控退出写操作鉴权（设备端要填同一个值）\nDASH_ACCESS_TOKEN=%s\n' "$_tk" >> server/.env
    echo ""
    echo "   ★★ 记下这个 token，设备端 dashboard.sh 要用："
    echo ""
    echo "        DASH_ACCESS_TOKEN=$_tk"
    echo ""
    echo "   服务器本地测试用：curl -s 'http://127.0.0.1:8787/control/status?token=$_tk'"
fi

# 把 token 取出来给下面几步用（只在本脚本进程里用，不落盘不回显）
TOKEN=$(sed -n 's/^DASH_ACCESS_TOKEN=\(.*\)$/\1/p' server/.env | tail -n 1)

echo ""
echo "=== 4. 重启服务 ==="
# 端口占用是这个项目的高频故障，先清野进程再重启，否则 systemd 会反复失败
if ss -lntp 2>/dev/null | grep -q ':8789'; then
    echo "发现 8789 端口被占，清掉野进程"
    pkill -f 'main.py' 2>/dev/null || true
    sleep 2
fi
systemctl restart kindle-dashboard
sleep 3
systemctl is-active kindle-dashboard >/dev/null && echo "服务已启动"

echo ""
echo "=== 5. 验收：遥控接口 ==="
_s=$(curl -s --max-time 10 "http://127.0.0.1:8787/control/status?token=$TOKEN")
case "$_s" in
    *'"quit"'*) echo "  GET /control/status  ->  $_s" ;;
    *) echo "  !! /control/status 异常：$_s" ;;
esac

# 无 token 必须被拒
_code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
        -X POST http://127.0.0.1:8787/control/quit)
echo "  POST /control/quit (无 token) -> HTTP $_code  [应为 401]"

# 带头请求退出，再用 cancel 撤销（避免留个待执行请求）
_q=$(curl -s --max-time 10 -X POST \
     "http://127.0.0.1:8787/control/quit?token=$TOKEN")
echo "  POST /control/quit (带 token) -> $_q"
_c=$(curl -s --max-time 10 -X POST \
     "http://127.0.0.1:8787/control/cancel?token=$TOKEN")
echo "  POST /control/cancel          -> $_c"

echo ""
echo "=== 6. 公网入口自检（nginx 8787）==="
_g=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 \
     "http://127.0.0.1:8787/?token=$TOKEN")
echo "  GET / -> HTTP $_g  [应为 200]"

echo ""
echo "=== 完成 ==="
echo "浏览器打开："
echo "  预览页（右上角有退出按钮）：http://<服务器IP>:8787/?token=$TOKEN"
echo "  遥控页：                    http://<服务器IP>:8787/control?token=$TOKEN"
echo ""
echo "★ 点按钮后设备不会立刻退 —— 它在深度休眠，收不到指令。"
echo "  正确用法：点按钮 → 按一下 Kindle 电源键唤醒 → 立刻退出。"
echo ""
echo "★ 设备端 dashboard.sh 里的 DASH_ACCESS_TOKEN 必须填上面那个值，"
echo "  否则设备读不到退出请求（会一直 401）。"
