#!/bin/sh
# KPW3 看板「无 SSH」快捷执行入口。
#
# 原理：Kindle 越狱后，搜索框输 `;log runme` 会执行根目录的 /mnt/us/runme.sh。
# 这样连 SSH 都不用，把文件拷进去就能跑。
#
# 用法：
#   1. 把 dashboard.sh 放进 Kindle 的 /mnt/us/dashboard/ 目录（USB 存储模式直接拷）
#   2. 把这个 runme.sh 放到 Kindle 根目录 /mnt/us/
#   3. 首次还要建一个 config.env（见下）
#   4. Kindle 搜索框输入   ;log runme   回车
#
# 它会先测一次能不能拉到看板图，成功就启动常驻守护。
# 全过程日志写在 /mnt/us/dashboard/runme.log，拷出来看就知道卡在哪。
#
# 地址说明：用 IP 直连，不要用域名。
#   实测「域名+端口」会被中间层拦截（302 到 ISP 的 webblock 页），
#   请求根本到不了服务器，Kindle 端表现为 Connection reset by peer。

DASH_DIR=/mnt/us/dashboard
LOG=$DASH_DIR/runme.log
PIDFILE=$DASH_DIR/dashboard.pid

# ── 配置：token 只需要填一次 ────────────────────────────────────
#
# ★ 为什么要有这个文件（很重要的一个坑）：
#   服务端设了 DASH_ACCESS_TOKEN 之后，设备端也必须带同一个值。
#   但从搜索框跑 `;log runme` 时，**你不是在一个 shell 里** ——
#   没有地方 export 环境变量，所以「在 runme.sh 里 export」这条路根本走不通。
#
#   而且 dashboard.sh 的 start 分支是这么拉后台的：
#       ( trap '' HUP; "$0" _loop ) &
#   环境变量必须**显式转发**才能带进这个子进程。
#   只在 runme.sh 里 export 而不转发 = 后台守护收不到 → 退出按钮永远 401。
#   表现极具迷惑性：**图能正常拉（/dashboard.png 的 token 走 URL query），
#   只有遥控退出不工作** —— 很难联想到是 token 没传进去。
#
#   所以：把 token 写进这个文件，一次性。之后每次 `;log runme` 自动读，
#   不用再碰。
#
# 建法（在电脑上 USB 拷的时候顺手做，文件名 config.env 放 F:\dashboard\）：
#     DASH_ACCESS_TOKEN=你的token
#
# 格式：每行 KEY=VALUE，支持 # 注释。
# 服务器上跑 deploy_control.sh 会打印出 token 值。
CONF=$DASH_DIR/config.env

# 依次尝试读取 token：
#   1) 已经 export 进来的（SSH 手动跑的场景）
#   2) $DASH_DIR/config.env  ← 正常情况走这条，填一次永久生效
#   3) $DASH_DIR/token       ← 只放一行的简写，懒得写 KEY= 时用
#   4) /mnt/us/token         ← Kindle 根目录，方便拷贝
TOKEN="${DASH_ACCESS_TOKEN:-}"
if [ -z "$TOKEN" ] && [ -f "$CONF" ]; then
    TOKEN=$(sed -n 's/^[[:space:]]*DASH_ACCESS_TOKEN[[:space:]]*=[[:space:]]*\(.*[^[:space:]]\)[[:space:]]*$/\1/p' "$CONF" | tail -n 1)
    # 去掉可能包裹的引号（有人习惯写 DASH_ACCESS_TOKEN="xxx"）
    case "$TOKEN" in
        \"*\") TOKEN=$(printf '%s' "$TOKEN" | sed 's/^"//; s/"$//') ;;
        \'*\') TOKEN=$(printf '%s' "$TOKEN" | sed "s/^'//; s/'$//") ;;
    esac
fi
if [ -z "$TOKEN" ] && [ -f "$DASH_DIR/token" ]; then
    TOKEN=$(tr -d ' \t\r\n' < "$DASH_DIR/token")
fi
if [ -z "$TOKEN" ] && [ -f /mnt/us/token ]; then
    TOKEN=$(tr -d ' \t\r\n' < /mnt/us/token)
fi

# ★ 拦住"模板没改就拷进来"这种情况。
#   config.env 模板里放的是 <PUT_TOKEN_HERE> 这种尖括号占位符。
#   如果照抄不改，它会被当成一个真 token 发出去 —— 服务端收到一串
#   尖括号字符串，直接 401，而日志里只会写"长度 15"，
#   看不出是哪来的。这里提前识别出来并当成"未配置"处理。
#
#   顺带拦中文：给用户的模板**绝不能用中文占位符**——
#   HTTP header 里塞非 ASCII 会编码失败，报错误导得离谱。
case "$TOKEN" in
    *'<'*|*'>'*)
        TOKEN_WARN="配置里的 token 还是占位符（含 < >），没真的填 —— 当成未配置处理"
        TOKEN=""
        ;;
esac
case "$TOKEN" in
    *[!\ -~]*)   # 含非 ASCII（比如中文）
        TOKEN_WARN="配置里的 token 含非 ASCII 字符（可能是没改的中文占位符）—— 当成未配置处理"
        TOKEN=""
        ;;
esac

# ★ 服务端地址：优先环境变量，其次从 config.env 读，最后落到占位符。
#
#   为什么放 config.env（而不是写死在这里）：
#     1. 跟 token 共用一个文件，换服务器只改一处
#     2. **脚本本身不含任何真实地址** —— 方便开源/分享
#
#   config.env 里加这么一行即可：
#       DASH_SERVER=http://你的服务器:8787
SERVER="${DASH_SERVER:-}"
if [ -z "$SERVER" ] && [ -f "$CONF" ]; then
    SERVER=$(sed -n 's/^[[:space:]]*DASH_SERVER[[:space:]]*=[[:space:]]*\(.*[^[:space:]]\)[[:space:]]*$/\1/p' "$CONF" | tail -n 1)
    # 去掉可能包裹的引号
    case "$SERVER" in
        \"*\") SERVER=$(printf '%s' "$SERVER" | sed 's/^"//; s/"$//') ;;
        \'*\') SERVER=$(printf '%s' "$SERVER" | sed "s/^'//; s/'$//") ;;
    esac
fi
# 都没有就留个明显的占位符（不写真实地址）
: "${SERVER:=http://PUT_YOUR_SERVER_IP:8787}"

# ── 把 config.env 里的可调参数也读出来，转发给 dashboard.sh ──────
#
# ★ 为什么必须在这里读：
#   从搜索框跑 `;log runme` 时**没有 shell 可以 export 环境变量**，
#   所以设备端的配置只有 config.env 这一个通道。
#   而 dashboard.sh 的 start 分支是 `( trap '' HUP; "$0" _loop ) &` ——
#   环境变量必须**显式转发**才能带进那个后台进程。
#
# ★ 只取**纯数字**：一是这些参数本来就都是数值，二是避免
#   config.env 里出现奇怪内容时被当成命令执行。
#   取不到就留空，dashboard.sh 那边会用内置默认值。
_cfg_num() {
    [ -f "$CONF" ] || return 0
    sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p" "$CONF" | tail -n 1
}
CFG_INTERVAL=$(_cfg_num DASH_INTERVAL)
CFG_FULL_EVERY=$(_cfg_num DASH_FULL_EVERY)
CFG_CONTROL=$(_cfg_num DASH_CONTROL)
CFG_WIFI_TOGGLE=$(_cfg_num DASH_WIFI_TOGGLE)
CFG_WIFI_WAIT=$(_cfg_num DASH_WIFI_WAIT_MAX)
CFG_WIFI_RESTART=$(_cfg_num DASH_WIFI_RESTART_AFTER)
CFG_FETCH_TIMEOUT=$(_cfg_num DASH_FETCH_TIMEOUT)

# 统一转发（once / start 两处共用，免得参数列表抄两遍、抄漏一个）
run_dash() {
    DASH_SERVER="$SERVER" \
    DASH_ACCESS_TOKEN="$TOKEN" \
    DASH_INTERVAL="$CFG_INTERVAL" \
    DASH_FULL_EVERY="$CFG_FULL_EVERY" \
    DASH_CONTROL="$CFG_CONTROL" \
    DASH_WIFI_TOGGLE="$CFG_WIFI_TOGGLE" \
    DASH_WIFI_WAIT_MAX="$CFG_WIFI_WAIT" \
    DASH_WIFI_RESTART_AFTER="$CFG_WIFI_RESTART" \
    DASH_FETCH_TIMEOUT="$CFG_FETCH_TIMEOUT" \
        sh "$DASH_SH" "$@"
}

# 选脚本：用 /mnt/us/dashboard/dashboard.sh
#
# ★ 为什么不再优先 dashboard2.sh（历史遗留，2026-09-28 去掉）：
#   "2 优先"是当初为了绕开「本机推不进 Kindle、覆盖既有文件会失败」而加的
#   兜底 —— 把新版存成 dashboard2.sh，脚本再去捞它。
#   但那个前提已经不存在了：
#     1. 交付方式改成**手动拷贝**了，可以先删目标文件再拷，覆盖必然成功
#     2. token 也从"临时 export"改成 config.env 文件了，与文件名无关
#   留着这条规则反而有害：F 盘上如果还残留旧的 dashboard2.sh
#   （竖屏 + 会弹键盘那一版），它会**优先于新 dashboard.sh 被选中**，
#   表现就是"明明拷了新版却还是旧界面"，很难联想到是脚本挑错了文件。
#
#   所以现在只认 dashboard.sh 一个名字。F 盘上的 dashboard2.sh / runme2.sh
#   都可以删掉了。
DASH_SH="$DASH_DIR/dashboard.sh"

mkdir -p "$DASH_DIR"

log() {
    echo "$1" >> "$LOG"
}

{
    echo "=== runme $(date) ==="
    echo "server: $SERVER"
    echo "script: ${DASH_SH:-未找到}"
    # 只报有没有，不报值 —— 万一日志要发给别人排查，别把凭证带出去
    if [ -n "$TOKEN" ]; then
        echo "token: 已配置（长度 ${#TOKEN}）"
    else
        echo "token: 未配置 —— 看板能显示，但网页遥控退出会 401"
    fi
    [ -n "${TOKEN_WARN:-}" ] && echo "token 提示: $TOKEN_WARN"
} > "$LOG"

if [ ! -f "$DASH_SH" ]; then
    log "找不到 $DASH_SH —— 先把 dashboard.sh 拷进 /mnt/us/dashboard/"
    exit 1
fi

if [ -z "$TOKEN" ]; then
    log "提示：没读到 token。想用「网页点按钮退出看板」，请新建 $CONF，"
    log "      内容一行：DASH_ACCESS_TOKEN=服务器上的那个值"
    log "      （服务端 deploy_control.sh 会打印这个值）"
    log "      然后重新跑一次 ;log runme 即可。"
fi

# ★ 先停掉旧的守护进程。
# 否则旧进程会一直占着脚本文件，没法覆盖更新，
# 而且新旧两个守护同时刷屏会互相打架。
if [ -f "$PIDFILE" ]; then
    OLD=$(cat "$PIDFILE" 2>/dev/null)
    case "$OLD" in
        ''|*[!0-9]*) : ;;
        *)
            if kill -0 "$OLD" 2>/dev/null; then
                log "停掉旧守护 PID $OLD"
                kill "$OLD" 2>/dev/null
                sleep 2
                kill -9 "$OLD" 2>/dev/null
            fi
            ;;
    esac
    rm -f "$PIDFILE"
fi

chmod +x "$DASH_SH" 2>/dev/null

# ★ 两处调用都要显式带上 DASH_ACCESS_TOKEN 和 DASH_SERVER。
#   只 export 不传参 = 后台 _loop 子进程拿不到（见文件开头那段说明）。
#   TOKEN 为空时传空串是安全的：dashboard.sh 里 TOKEN="" 就不拼 token 参数，
#   行为和以前完全一致。
log "--- 第 1 步：测试拉图 ---"
if run_dash once >> "$LOG" 2>&1; then
    log "--- 测试通过，第 2 步：启动常驻守护 ---"
    run_dash start >> "$LOG" 2>&1
    log "--- 完成。屏幕应该已经刷成看板了 ---"
else
    log "--- 拉图失败 ---"
    log "多半是 Kindle 访问不到 $SERVER，检查 Kindle 的 WiFi 和服务器端口 8787"
    exit 1
fi

# ── 顺手自检一下遥控通道 ────────────────────────────────────────
#
# ★ 为什么值得多做这一步：
#   token 配错时的症状是「看板一切正常，只有网页退出按钮没反应」——
#   因为拉图（/dashboard.png）和退出查询（/control/status）是两条独立的请求，
#   前者只要 URL 带 token 就行，后者还要环境变量正确转发。
#   不主动测一次的话，你只有等真正想退出时才发现，那会儿人可能不在设备旁。
#
#   在启动的这一刻就测：通不通立刻知道，日志里直接写明白。
_ctrl_url="$SERVER/control/status"
if [ -n "$TOKEN" ]; then
    _ctrl_url="$_ctrl_url?token=$TOKEN"
fi

_ctrl=""
if command -v wget >/dev/null 2>&1; then
    _ctrl=$(wget -q -O - --timeout=10 "$_ctrl_url" 2>/dev/null)
elif command -v curl >/dev/null 2>&1; then
    _ctrl=$(curl -s --max-time 10 "$_ctrl_url" 2>/dev/null)
fi

case "$_ctrl" in
    *'"quit"'*)
        log "遥控通道自检：OK（网页「退出看板」按钮可用）"
        ;;
    *unauthorized*)
        log "!! 遥控通道自检：401 —— token 不对"
        log "   设备端读到的 token 长度 ${#TOKEN}，和服务端 deploy_control.sh 打印的对比一下"
        log "   注意别把两端的空格/引号带进去"
        ;;
    '')
        log "遥控通道自检：没响应（网络问题，或服务端没起）"
        log "   不影响看板显示，但遥控退出暂时用不了"
        ;;
    *)
        log "遥控通道自检：返回了意外内容 -> $_ctrl"
        ;;
esac
