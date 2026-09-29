#!/bin/sh
# 把设备端脚本推到 KPW3 上。
#
# 前置：Kindle 已越狱并装好 USBNet，能 SSH 上去。
#   - USB 线连接时，Kindle 地址通常是 192.168.15.244
#   - 走 WiFi 的话填它的局域网 IP
#
# 用法：
#   KINDLE_HOST=root@192.168.15.244 sh install.sh

set -e

KINDLE_HOST="${KINDLE_HOST:-root@192.168.15.244}"
SRC=$(cd "$(dirname "$0")" && pwd)

echo "推送到 $KINDLE_HOST ..."
ssh "$KINDLE_HOST" "mkdir -p /mnt/us/dashboard"
scp "$SRC/dashboard.sh" "$KINDLE_HOST:/mnt/us/dashboard/dashboard.sh"
ssh "$KINDLE_HOST" "chmod +x /mnt/us/dashboard/dashboard.sh"

echo
echo "推送完成。下一步在 Kindle 上跑一次验收："
echo "  ssh $KINDLE_HOST"
echo "  DASH_SERVER=http://你的服务器IP:8787 /mnt/us/dashboard/dashboard.sh once"
