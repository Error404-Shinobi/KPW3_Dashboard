#!/bin/sh
# KPW3 看板 —— 手动退出入口
#
# 用法：Kindle 搜索框输入   ;log stopdash
#
# 和 dashboard.sh 的 stop 分支做同一件事，但这里做成独立小脚本，
# 好处是**名字短、单独一个文件**，不容易和别的东西混。
#
# ── ★ 前提：只在「看板没有运行」时可用 ──────────────────────
#
# ⚠️ 看板跑起来之后，**搜索框是用不了的** —— 它是 `lab126_gui` 提供的，
#    而看板为了独占屏幕正是把它停掉了。
#    （`;log` 命令的执行确实是系统级的，但**输入它需要搜索框**。）
#
#    所以本脚本**不是退出运行中看板的手段**，而是：
#       看板已经停了之后，用来清理残留、把原生界面还回来。
#
# ── 退出运行中的看板：只剩「强制重启」一条路 ────────────────
#
#    长按电源键 10 秒以上 → 强制重启（不需要网络，永远可用）
#
#    （看板运行时按电源键不会弹菜单 —— 设备大多在深度休眠，
#      长按的语义是"唤醒"；但按得够久仍会强制重启。）
#
# 网页遥控按钮为什么也不算数：
#    它依赖网络，而看板多连手机热点，热点一断设备就离线 ——
#    实测断网时「点按钮 + 按电源键唤醒」依然退不出来。
#
# 搜索框在看板运行时还能用吗？
#   不能。搜索框是 lab126_gui 提供的，看板为了独占屏幕把它停了 ——
#   所以本脚本只适合"看板已经停了"的场景（那时 lab126_gui 是活的）。
#   要退出运行中的看板，见上面的两条路（网页按钮 / 强制重启）。

DASH_DIR=/mnt/us/dashboard
# 日志统一写到 dashboard.log，跟看板主脚本共用一个文件，方便一次看全
LOG=$DASH_DIR/dashboard.log
PIDFILE=$DASH_DIR/dashboard.pid

mkdir -p "$DASH_DIR"

log() {
    echo "$(date '+%F %T') [stopdash] $*" >> "$LOG"
}

log "--- 收到手动退出请求 ---"

# 0) 清掉历史遗留的看门狗（旧版本会起一个 watch.pid，现已废弃）
LEGACY_WATCH_PID=$DASH_DIR/watch.pid
if [ -f "$LEGACY_WATCH_PID" ]; then
    _w=$(cat "$LEGACY_WATCH_PID" 2>/dev/null)
    case "$_w" in
        ''|*[!0-9]*) : ;;
        *)
            if kill -0 "$_w" 2>/dev/null; then
                log "清掉遗留的看门狗 PID $_w（该机制已移除）"
                kill "$_w" 2>/dev/null
            fi
            ;;
    esac
    rm -f "$LEGACY_WATCH_PID"
fi
# 兜底：旧版 exitdash.sh 万一还在跑
if command -v pkill >/dev/null 2>&1; then
    pkill -f 'exitdash[.]sh' 2>/dev/null
fi

# 1) 停看板守护
if [ -f "$PIDFILE" ]; then
    _p=$(cat "$PIDFILE" 2>/dev/null)
    case "$_p" in
        ''|*[!0-9]*) : ;;
        *)
            if kill -0 "$_p" 2>/dev/null; then
                log "停掉看板守护 PID $_p"
                kill "$_p" 2>/dev/null
                sleep 2
                kill -9 "$_p" 2>/dev/null
            fi
            ;;
    esac
    rm -f "$PIDFILE"
fi

# 2) 兜底：把可能残留的同名脚本进程也清掉
for pat in 'dashboard.sh' 'dashboard2.sh'; do
    if command -v pkill >/dev/null 2>&1; then
        pkill -f "$pat" 2>/dev/null
    fi
done

# 3) 还回原生 UI
lipc-set-prop com.lab126.powerd preventScreenSaver 0 >/dev/null 2>&1
echo ondemand > /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null
/etc/init.d/framework start >/dev/null 2>&1
initctl start framework >/dev/null 2>&1
initctl start lab126_gui >/dev/null 2>&1
initctl start webreader >/dev/null 2>&1

# 4) 清掉看板残影
for c in /usr/sbin/eips /usr/bin/eips; do
    if [ -x "$c" ]; then "$c" -c 2>/dev/null; break; fi
done

log "--- 已退出，回到原生界面 ---"
