#!/bin/sh
# 把项目推到 Linux 服务器。
#
# 只传代码和配置，不传本机 .venv（几十 MB，没用）和密钥文件 .env。
# .env 建议直接在服务器上手工建，密钥少走一趟网络。
#
# 用法（在本机跑）：
#   sh deploy.sh user@服务器IP
#   sh deploy.sh user@服务器IP /opt/kindle-dashboard
#
# 用位置参数而不是环境变量，是为了避开 bash / PowerShell / CMD 的赋值语法差异。

set -e

SERVER="${1:-${SERVER:-}}"
REMOTE_DIR_ARG="${2:-}"

if [ -z "$SERVER" ]; then
    echo "用法：sh deploy.sh user@服务器IP [远端目录]"
    echo "示例：sh deploy.sh root@1.2.3.4"
    exit 1
fi

REMOTE_DIR="${REMOTE_DIR_ARG:-${REMOTE_DIR:-/opt/kindle-dashboard}}"

# 用参数展开取脚本所在目录，不依赖 dirname（某些精简 shell 里没有）
SRC=$(cd "${0%/*}" 2>/dev/null && pwd)
if [ -z "$SRC" ]; then
    SRC=$(pwd)
fi

if ! command -v rsync >/dev/null 2>&1; then
    echo "本机没有 rsync。装一个，或者手动 scp："
    echo "  scp -r $SRC/server $SRC/kindle $SERVER:$REMOTE_DIR/"
    exit 1
fi

echo "上传 $SRC -> $SERVER:$REMOTE_DIR"
rsync -av \
    --exclude '.venv/' \
    --exclude '__pycache__/' \
    --exclude '*.pyc' \
    --exclude 'preview.png' \
    --exclude '.env' \
    --exclude '.git/' \
    "$SRC/" "$SERVER:$REMOTE_DIR/"

echo
echo "传完了。接着在服务器上做这几步："
echo
echo "  ssh $SERVER"
echo "  cd $REMOTE_DIR/server"
echo
echo "  # 1) 密钥（.env 没传，在这台机器上建）"
echo "  cp .env.example .env && vi .env"
echo
echo "  # 2) 依赖和字体"
echo "  python3 -m venv .venv"
echo "  .venv/bin/pip install -r requirements.txt"
echo "  sudo apt install fonts-noto-cjk        # 没有中文字体会全是方块"
echo
echo "  # 3) 先确认服务器这边也能连上 MiniMax"
echo "  .venv/bin/python probe_minimax.py"
echo
echo "  # 4) 出图看看"
echo "  .venv/bin/python preview_cli.py /tmp/preview.png"
