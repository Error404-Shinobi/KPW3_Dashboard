#!/bin/sh
# KPW3 看板 —— 手动退出入口
#
# 用法：Kindle 搜索框输入   ;log stopdash
#
# 和 dashboard.sh 的 stop 分支做同一件事，但这里做成独立小脚本，
# 好处是**名字短、单独一个文件**，不容易和别的东西混。
#
# ── 为什么需要「手动退出」这条路 ────────────────────────────────
# 看板跑起来后，原生界面被压住（lab126_gui 停了），屏幕上就是看板。
# 想回到原生界面（比如去书库、改设置、联网），需要一条明确的退出路径。
#
# 现在有**两条**，都验证过：
#   ① 网页上点「退出看板」← 推荐，设备下轮醒来就自己退
#   ② 搜索框 `;log stopdash` ← 保底，不依赖网络
#
# ── 关于电源键（2026-09-28 实测校正）───────────────────────────
# 电源键**不再被看板抢走**（自定义监听那套已移除）。
#   短按 = 系统正常休眠 / 唤醒（这个好用：网页点了退出后，
#          按一下电源键把它叫醒，它立刻就退，不用等下个周期）
#   长按 = ⚠️ **看板运行时弹不出重启菜单** —— 设备在 `echo mem`
#          深度休眠，suspend 状态下长按的语义是「唤醒」而非「弹菜单」。
#          想看菜单（重启/取消/熄屏）→ 先退出看板回原生界面再长按。
#
# 早先试过「自定义监听长按电源键退出」，但 KPW3 的电源键设备
# (`max77696-onkey`) 在用户态看不到按键事件，方案不可行，已移除。
# 所以退出看板请用上面那两条路，别再指望电源键。
# 深度休眠与长按菜单互斥的完整分析见 docs/pitfalls.md 坑 21.8。
#
# 搜索框在原生界面被压住时还能用吗？
#   能。搜索框属于系统的输入处理，`;log xxx` 是 lab126 的日志钩子，
#   它不依赖 lab126_gui —— 这也是本项目一直用 `;log runme`
#   启动看板的原因，同一条通道自然也能用来退出。

DASH_DIR=/mnt/us/dashboard
LOG=$DASH_DIR/watch.log
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
