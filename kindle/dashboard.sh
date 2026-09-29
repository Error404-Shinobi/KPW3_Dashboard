#!/bin/sh
# KPW3 墨水屏看板 - 设备端刷新守护
#
# 用法（SSH 进 Kindle 后用 root 跑）：
#   /mnt/us/dashboard/dashboard.sh once    拉一次图并刷屏，用来验收
#   /mnt/us/dashboard/dashboard.sh start   后台常驻
#   /mnt/us/dashboard/dashboard.sh stop    停止
#   /mnt/us/dashboard/dashboard.sh status  看日志尾部
#
# 环境变量可覆盖：
#   DASH_SERVER     服务端地址，如 http://192.168.1.10:8787
#   DASH_INTERVAL   刷新间隔秒数，默认 600
#   DASH_FULL_EVERY 每多少轮做一次全清屏（压残影），默认 12
#   DASH_CONTROL    设 0 关掉「问服务端要不要退出」（省一次网络请求）
#   DASH_WIFI_TOGGLE 设 1 只在拉图时开 WiFi（电池供电用）
#   DASH_WIFI_TEST_IP  网络探测目标，默认 1.1.1.1（公共 DNS）
#   DASH_WIFI_WAIT_MAX 等网络就绪的上限秒数，默认 30
#   DASH_WIFI_RESTART_AFTER 连续失败几轮后 toggle 无线，默认 3；设 0 关闭
#   DASH_FETCH_TIMEOUT 拉图 HTTP 超时秒数，默认 15
#
# ★ 电源键行为（2026-09-28 起，真机实测校正）：
#   **电源键交还给系统**，看板不再自己监听按键（原因见下面那段说明）。
#
#   但要注意：**看板运行时，长按电源键不会弹重启菜单**。
#   这不是我们抢了按键，而是**深度休眠的必然结果** ——
#   看板大部分时间躺在 `echo mem` 里，此时长按电源键的语义是
#   「唤醒」，不是「弹菜单」。真机现象：长按约 8 秒 →
#   整屏闪一下 → 全黑（那是休眠流程被触发，不是菜单被压掉）。
#
#   想主动重启 / 弹菜单：先退出看板（见下），回到原生界面再长按。
#
#   ★ 退出看板只有两条路（**别指望搜索框** —— 看板跑起来后
#     lab126_gui 被停了，搜索框用不了，敲不出任何命令）：
#       ① 网页点「退出看板」→ 按一下电源键唤醒设备 → 立刻退
#       ② 长按电源键 10 秒以上强制重启

DIR=/mnt/us/dashboard
IMG=$DIR/dashboard.png
LOG=$DIR/dashboard.log
PID=$DIR/dashboard.pid

# 看板服务器地址。**改成你自己的**，或用环境变量 DASH_SERVER 覆盖。
# （开源版本这里放占位符，免得把真实地址提交上去）
SERVER="${DASH_SERVER:-http://PUT_YOUR_SERVER_IP:8787}"
INTERVAL="${DASH_INTERVAL:-600}"
FULL_EVERY="${DASH_FULL_EVERY:-12}"
# 服务端设了 DASH_ACCESS_TOKEN 时，这里要填一样的
TOKEN="${DASH_ACCESS_TOKEN:-}"
# 省电模式：只在拉图时开 WiFi，拉完关掉。默认 0（保持常连）。
# 插电常显不用开；要用电池供电时设成 1。
WIFI_TOGGLE="${DASH_WIFI_TOGGLE:-0}"

# ── WiFi 就绪等待（★ 2026-09-29 新增，替代原来无条件的 `sleep 8`）──────
# 唤醒后 WiFi 需要几秒才真正可用，直接拉图会 Network unreachable。
# 原来写死 `sleep 8`：不管好没好都等满 8 秒 —— 快的时候白等，
# 慢的时候（十几秒）又不够。现在改成 ping 探测：
#   **通了立刻往下走（快则 1 秒），不通最多等 WIFI_WAIT_MAX 秒。**
# 参考 pascalw/kindle-dash 的 src/wait-for-wifi.sh。
#
# 探测目标是公共 IP 而不是我们自己的服务端 —— 这样可以区分
# 「本机没网」和「网是通的、只是服务端有问题」两种故障，
# 日志里能直接看出来是哪种。
WIFI_TEST_IP="${DASH_WIFI_TEST_IP:-1.1.1.1}"
WIFI_WAIT_MAX="${DASH_WIFI_WAIT_MAX:-30}"

# ── WiFi 自愈（★ 2026-09-29 新增）──────────────────────────────────
# 连续失败这么多轮后，toggle 一次无线（关 5 秒 → 开 5 秒）。
# 治的是「WiFi 卡在坏状态」：网络抖动（ISP 挂了 / 路由器重启）之后，
# wifid 可能自己出不来，需要外力踢一脚。
# 参考 terminalbytes.com 那篇 KPW7 看板文章里的 restart_wifi()。
# 设成 0 可关掉自愈。
WIFI_RESTART_AFTER="${DASH_WIFI_RESTART_AFTER:-3}"

# 拉图的 HTTP 超时（秒）。网络不通时会卡很久，这个值决定"多久放弃"。
FETCH_TIMEOUT="${DASH_FETCH_TIMEOUT:-15}"

# ★ 「长按电源键退出」那套自定义按键监听**已移除**（2026-09-28）。
#
# 原因（真机日志证实）：KPW3 的电源键设备是 `max77696-onkey`，
# 它的 capabilities/key 位图里**没有声明 KEY_POWER(116)** ——
# 也就是说这个按键事件在用户态**根本看不见**。
# 按名字匹配和按位图匹配两条路都堵死，方案在这台机器上不可行。
#
# 现在的设计：**电源键交还给系统**（不再自建监听）。
#   - 看板未运行时：短按 = 休眠/唤醒，长按 = 弹重启菜单（原生行为）
#   - 看板运行时：  device 大部分时间在 `echo mem` 深度休眠里，
#                  此时长按电源键 = 「唤醒」，**弹不出重启菜单**
#                  （真机实测：长按 8s → 整屏闪一下 → 全黑）
#   - 所以**想重启就先退出看板**，回到原生界面再长按。
#     退出看板 → 网页「退出看板」按钮，或长按电源键强制重启（见文件头）
#
# ★ 关于「为什么长按不弹菜单」的完整分析，见 docs/pitfalls.md 坑 21.8。
#   一句话：深度休眠（续航关键）与「长按弹 UI 菜单」在语义上互斥，
#   前者要求尽快 suspend，后者要求系统保持活动。
#   我们选了休眠 —— 看板是放着看的，不需要频繁重启。

# 服务端遥控退出：每轮醒来先问一次服务端「要不要退」。
# 网页上点「退出看板」→ 设备下次醒来就自己退出。
# 设成 0 可关掉（省一次网络请求）。
CONTROL="${DASH_CONTROL:-1}"

# eips 不在 PATH 里，且不同机型位置不同（KPW3 常见 /usr/sbin/eips）
EIPS=""
for c in /usr/sbin/eips /usr/bin/eips; do
    [ -x "$c" ] && EIPS="$c" && break
done
[ -n "$EIPS" ] || EIPS=$(command -v eips)
if [ -z "$EIPS" ]; then
    echo "找不到 eips，USBNet 装全了吗？"
    exit 1
fi

mkdir -p "$DIR"

log() {
    echo "$(date '+%F %T') $*" >> "$LOG"
}

battery_level() {
    # 电量百分比，传给服务端画进图片右上角。
    #
    # ★ 属性名各机型不一样，要依次尝试，别只用一种：
    #   1) lipc-get-prop com.lab126.powerd battLevel  —— 部分固件有
    #   2) gasgauge-info -c                            —— KPW3 上更常见可靠
    #   3) 读 sysfs 的 capacity                        —— 兜底
    # 取不到就返回空，服务端会隐藏电量区（不要返回 0，那会画成 0% 误导人）。
    _b=""

    _b=$(lipc-get-prop com.lab126.powerd battLevel 2>/dev/null)
    case "$_b" in
        ''|*[!0-9]*) _b="" ;;   # 非纯数字就丢弃
    esac

    if [ -z "$_b" ]; then
        # gasgauge-info 输出形如 "85%" 或 "85"，剥掉非数字
        _b=$(gasgauge-info -c 2>/dev/null | tr -cd '0-9')
    fi

    if [ -z "$_b" ]; then
        for p in /sys/class/power_supply/*/capacity; do
            [ -r "$p" ] && _b=$(cat "$p" 2>/dev/null | tr -cd '0-9') && [ -n "$_b" ] && break
        done
    fi

    # 合法性检查：必须落在 0-100
    case "$_b" in
        ''|*[!0-9]*) echo "" ; return ;;
    esac
    if [ "$_b" -gt 100 ] 2>/dev/null; then
        echo ""; return
    fi
    echo "$_b"
}

hold_screen() {
    # 接管屏幕：压住原生 UI，别让主页/屏保/输入法盖掉看板。
    #
    # ★★ 关键取舍（2026-09-28 改）：**不动 framework**。
    #
    #   背景：最初的做法是停掉 framework / lab126_gui / webreader 三件套
    #   （参考 pascalw/kindle-dash 的 init()），理由是 framework 还活着时
    #   它检测到触摸会弹输入框 + 软键盘盖住看板。
    #
    #   但那有个设计上的必然代价：**电源键短按事件正是 framework 处理的**。
    #   停掉它 → 按键全失灵 → 想退出只能靠长按电源键强制重启
    #   （真机实测：不跑脚本时长按约 10 秒会直接重启，跳过菜单），
    #   而且**连"主动重启"都做不到**。我们后来想用「自定义监听电源键」
    #   把按键抢回来，结果发现 KPW3 那个设备在用户态本来就看不见按键事件
    #   （见文件头说明），方案彻底不可行。
    #
    #   所以现在改成：**只停 lab126_gui + webreader，framework 留着**。
    #   - lab126_gui 是主页/界面层 → 停掉它，主页就不会盖看板
    #   - webreader 是浏览器组件 → 停掉少一个抢屏的
    #   - framework 留着 → 短按电源键（休眠/唤醒）由它正常处理
    #
    #   ★ 实测校正（2026-09-28 下午）：**光留 framework 不等于长按能弹菜单**。
    #     真机现象是：看板跑起来后长按 8 秒 → 整屏闪一下 → 全黑，
    #     没有菜单。原因不在这几行，而在 loop() 里的 `echo mem`：
    #     设备大部分时间处于 suspend，长按的语义被 powerd 解释成
    #     「唤醒」而非「弹 UI 菜单」。详见文件头与 pitfalls 坑 21.8。
    #
    #   代价：framework 活着，触摸屏幕时它仍可能弹输入框/软键盘。
    #   但看板是放着看的、不会天天去戳它，这个代价可以接受 ——
    #   换来的是短按电源键（休眠/唤醒）正常。
    #   （真嫌键盘碍事，退出看板（网页按钮 / 强制重启）再戳屏幕。）

    # 压屏保，否则原生屏保会盖掉看板
    lipc-set-prop com.lab126.powerd preventScreenSaver 1 >/dev/null 2>&1

    # 关软键盘（framework 留着时，键盘可能被唤起，先关一次）
    lipc-set-prop -s com.lab126.keyboard close :: >/dev/null 2>&1

    # 只停抢屏的那两个，**不停 framework**（停它就等于废掉电源键）
    initctl stop lab126_gui >/dev/null 2>&1
    initctl stop webreader >/dev/null 2>&1

    # 省电：把 CPU 调频调到 powersave
    echo powersave > /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null

    # 等 UI 真正退干净再刷图，否则可能刷完被最后残留的一帧盖掉
    sleep 3
    return 0
}

release_screen() {
    lipc-set-prop com.lab126.powerd preventScreenSaver 0 >/dev/null 2>&1
    echo ondemand > /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null
    initctl start framework >/dev/null 2>&1
    initctl start lab126_gui >/dev/null 2>&1
    initctl start webreader >/dev/null 2>&1
    /etc/init.d/framework start >/dev/null 2>&1
    return 0
}

# 探测 ping 是否支持 -W（busybox 版本差异大，不支持就退回不带 -W）。
# 127.0.0.1 一定通，用它试一下这个选项能不能被接受。
PING_OPTS="-c 1"
if ping -c 1 -W 1 127.0.0.1 >/dev/null 2>&1; then
    PING_OPTS="-c 1 -W 2"
fi

wait_for_wifi() {
    # 等网络真的通。返回值区分**两种不同的「不通」**：
    #   0 = 通了
    #   1 = 本机压根没连上网络（内核直接报 unreachable）
    #   2 = 等满了上限（连上了但不通，或探测目标不可达）
    #
    # ★ 为什么要区分 1 和 2（2026-09-29，用户告知网络源是手机热点）：
    #   这台设备的网络源是**手机热点**。热点一关，链路就没了，
    #   内核会立刻返回 "Network is unreachable"：
    #     a) 这种情况再等满 30 秒纯属浪费电 —— 立刻返回（返回 1）；
    #     b) 但它**照样算网络层故障、要计入自愈**：
    #        实测发现热点回来时设备**不一定会自己重连**
    #        （用户观察到必须插拔一次 USB 才恢复），
    #        toggle 无线就是等效的「踢一脚」。
    #   「连上了但不通」（返回 2）同样计入自愈。
    #
    # ★ 为什么不直接 sleep：就绪时间是不确定的（有时 1 秒，有时十几秒）。
    #   死等固定秒数要么白等、要么不够 —— 正是「拉图失败率约 1/3」的根源。
    #
    # 注意：调用方**不应**因为返回非 0 就跳过拉图 —— 探测目标不等价于
    # 真实服务端，返回值只用来做分类和自愈判断。
    if ! command -v ping >/dev/null 2>&1; then
        # 这台机器没有 ping，退回原来的死等策略
        sleep 8
        return 0
    fi

    _i=0
    while [ "$_i" -lt "$WIFI_WAIT_MAX" ]; do
        # 注意 $PING_OPTS 故意不加引号：它承载多个参数（-c 1 -W 2），
        # 需要让 shell 分词。内容由本脚本控制，无注入风险。
        # stderr 也一起收进来，用来识别「不可达」这种立刻能判的情况。
        _err=$(ping $PING_OPTS "$WIFI_TEST_IP" 2>&1)
        if [ $? -eq 0 ]; then
            [ "$_i" -gt 0 ] && log "网络就绪（等了 ${_i} 秒）"
            return 0
        fi
        # ★ 快速失败：内核说 unreachable = 本机没连上网络（热点关了）。
        #   再等下去毫无意义，立刻返回 1，也免得白白耗电。
        case "$_err" in
            *[Uu]nreachable*)
                log "本机未连接网络（$WIFI_TEST_IP 不可达），不再等待"
                return 1
                ;;
        esac
        _i=$((_i + 1))
        sleep 1
    done

    log "网络等待超时（${WIFI_WAIT_MAX} 秒内 ping 不通 $WIFI_TEST_IP）"
    return 2
}

wifi_on() {
    if [ "$WIFI_TOGGLE" = "1" ]; then
        lipc-set-prop com.lab126.wifid enable 1 >/dev/null 2>&1
    fi
    # 不管 WIFI_TOGGLE 是多少，都等一次「网络真的通」。
    # 返回值透给 loop 用（区分「没网」还是「服务端问题」）。
    wait_for_wifi
}

wifi_off() {
    [ "$WIFI_TOGGLE" = "1" ] || return 0
    lipc-set-prop com.lab126.wifid enable 0 >/dev/null 2>&1
}

restart_wifi() {
    # WiFi 自愈：把无线关掉再打开，给 wifid 一个重新初始化的机会。
    # 只在连续多轮拉图失败后才调用（见 loop）。
    #
    # ★ 注意这里主动 toggle 是有意的，哪怕 WIFI_TOGGLE=0（平时不碰 WiFi）。
    #   因为走到这里说明**已经连续失败好几轮**了，网络明显不正常，
    #   这时候"踢一脚"比继续干等有价值。toggle 完回到 enable 状态，
    #   跟平时的「系统自己管、无线是开的」状态一致，没有持久副作用。
    log "WiFi 自愈：toggle 无线（关 5 秒 → 开 5 秒）"
    lipc-set-prop com.lab126.wifid enable 0 >/dev/null 2>&1
    sleep 5
    lipc-set-prop com.lab126.wifid enable 1 >/dev/null 2>&1
    sleep 5
    # toggle 之后等网络真的回来（等不到也没关系，下一轮照常跑）
    wait_for_wifi
}

# ★ 这里原本有 start_watchdog() / stop_watchdog()，
#   用于拉起 exitdash.sh 监听长按电源键。整套已移除（原因见文件头）。
#   电源键由系统处理：短按休眠/唤醒；长按的语义受休眠状态影响，
#   详见文件头「电源键行为」段与 setup_alarm() 上方注释。

fetch_image() {
    BATT=$(battery_level)
    URL="$SERVER/dashboard.png"
    # 取到电量才带上参数；取不到就不传，让服务端隐藏电量区，
    # 而不是传 batt=0（那会画成一个误导人的 0% 电池）。
    if [ -n "$BATT" ]; then
        URL="$URL?batt=$BATT"
    fi
    if [ -n "$TOKEN" ]; then
        case "$URL" in
            *\?*) URL="$URL&token=$TOKEN" ;;
            *)    URL="$URL?token=$TOKEN" ;;
        esac
    fi
    log "电量=$BATT URL=$URL"

    if command -v wget >/dev/null 2>&1; then
        # ★ 必须带超时！原来没写，网络不通时 wget 会用默认超时
        #   （connect 60s / read 更久），实测出现过「唤醒 → 128 秒后才拉图」
        #   的卡顿 —— 白耗电，而且这段时间 USB 也一直断着。
        #   图片几百 KB，15 秒足够；--timeout 对 dns/connect/read 都生效。
        wget -q -O "$IMG.tmp" --timeout="$FETCH_TIMEOUT" "$URL" || return 1
    elif command -v curl >/dev/null 2>&1; then
        curl -s -o "$IMG.tmp" --max-time "$FETCH_TIMEOUT" "$URL" || return 1
    else
        log "既没有 wget 也没有 curl"
        return 1
    fi

    # 空文件说明服务端没返回图片，别把上一帧覆盖掉
    if [ ! -s "$IMG.tmp" ]; then
        rm -f "$IMG.tmp"
        return 1
    fi
    mv "$IMG.tmp" "$IMG"
    return 0
}

draw_image() {
    [ -f "$IMG" ] || return 1
    "$EIPS" -f -g "$IMG"
}

draw_clock() {
    # 在屏幕角落叠一行**本地时间**（不依赖网络）。
    #
    # ★ 为什么需要：看板图是服务端渲染的**静态图**。离线时它一直显示的是
    #   最后一次成功拉到的那张，图上的时间也是那一刻的 —— 光看图不容易
    #   发现"数据已经过期很久了"。叠一行本地时间上去，跟图上的时间一对比
    #   就知道数据有多旧。
    #
    # ★ eips 写字的语法和坐标系（**真机实测得出，别再猜**）：
    #     eips <列> <行> "文字"     ← 第一个参数是「列」(横向)
    #                                 第二个是「行」(纵向)
    #   实测依据：`eips 30 0` / `eips 60 0` 都落在顶部同一行、且向右排开
    #             （→ 第一个参数是列）；`eips 0 30` 落在左侧偏下
    #             （→ 第二个是行）；而 `eips 0 60` **画不出来**
    #             （→ 行上限 60 格，有效 0~59）。
    #
    #   字符格约 16×24 像素；竖屏 1072×1448 → 约 67 列 × 60 行。
    #   正好对上：1072 ÷ 16 = 67，1448 ÷ 24 = 60.3。
    #
    # ★ 位置选在「行 59」而不是 58：
    #   行 59 的文字占竖屏 Y 1416~1440，对应横屏 x = 1447-1416 ≈ 7~31 ——
    #   完全落在服务端留的 72px 边距里，不会压到图上的内容。
    #   行 58 会占到横屏 x 55~79，就压到日期了。
    #
    # ★ 这行字会被下一次 draw_image（全屏贴图）盖掉，
    #   所以必须**每次刷图后都重写一次**（见 loop 里的调用顺序）。
    [ -n "$EIPS" ] || return 0
    "$EIPS" 0 59 "NOW $(date '+%m-%d %H:%M')" 2>/dev/null
    return 0
}

check_quit_request() {
    # 问服务端「要不要退出看板」。服务端 /control/status 返回 JSON，
    # 里面 "quit":true 就表示有人在网页上点了退出按钮。
    #
    # ★ 通信失败一律当成「不要退出」—— 绝不能因为网络抖一下就
    #   把看板退掉，那也太脆弱了。只有明确读到 quit=true 才退。
    #   但失败会重试一次：刚唤醒时 WiFi 常还没就绪，
    #   单次失败会让用户的退出请求白等一整个周期。
    #
    # 返回 0 = 要求退出，1 = 不退出（含各种失败情况）。
    [ -n "$CONTROL" ] || return 1

    _url="$SERVER/control/status"
    if [ -n "$TOKEN" ]; then
        _url="$_url?token=$TOKEN"
    fi

    _try=1
    while [ "$_try" -le 2 ]; do
        if command -v wget >/dev/null 2>&1; then
            _body=$(wget -q -O - --timeout=10 "$_url" 2>/dev/null)
            _rc=$?
        elif command -v curl >/dev/null 2>&1; then
            _body=$(curl -s --max-time 10 "$_url" 2>/dev/null)
            _rc=$?
        else
            return 1
        fi

        # 拿到内容就跳出重试
        if [ -n "$_body" ]; then
            break
        fi
        if [ "$_try" -lt 2 ]; then
            log "查询退出状态失败（第 $_try 次），2 秒后重试"
            sleep 2
        fi
        _try=$((_try + 1))
    done

    [ -n "$_body" ] || return 1

    # 解析出 "quit" 字段的值。
    #
    # ★ 不能只用 case 做粗糙的字符串包含匹配！
    #   实测这种写法会误判：
    #     {"quit": false, "note": "true"}   →  含 "quit" 也含 "true"，误判为要退出
    #   所以必须**先定位到 quit 字段本身**，再单独看它的值。
    #
    # 做法：用 sed 把 "quit" 后面跟的那个值抽出来，只认它。
    _tail=$(printf '%s' "$_body" | sed -n 's/.*"quit"[[:space:]]*:[[:space:]]*\([a-z]*\).*/\1/p')
    # sed 没匹配到会输出空（-n + p 的语义），此时 _tail 为空 → 不退出
    case "$_tail" in
        true)
            log "服务端要求退出看板（quit=true）"
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

ack_quit() {
    # 告诉服务端「已退出」，把 quit 复位。
    # 不 ack 的话，下次启动看板一问又是 quit:true，会立刻又退出去。
    [ -n "$CONTROL" ] || return 0
    _url="$SERVER/control/ack"
    if [ -n "$TOKEN" ]; then
        _url="$_url?token=$TOKEN"
    fi
    if command -v wget >/dev/null 2>&1; then
        wget -q -O - --timeout=10 --post-data="" "$_url" >/dev/null 2>&1
    elif command -v curl >/dev/null 2>&1; then
        curl -s --max-time 10 -X POST "$_url" >/dev/null 2>&1
    fi
    log "已向服务端确认退出（quit 复位）"
}

exit_dashboard() {
    # 收到退出请求后的收尾：还回原生界面、清残影。
    log "--- 执行退出看板 ---"
    release_screen
    for c in /usr/sbin/eips /usr/bin/eips; do
        if [ -x "$c" ]; then "$c" -c 2>/dev/null; break; fi
    done
    ack_quit
    log "--- 已退出看板 ---"
}

setup_alarm() {
    # 找 RTC 设备并设定相对唤醒时间，然后 echo mem 进入深度休眠。
    # 休眠期间屏幕保持画面、几乎不耗电，这是续航能撑很久的关键。
    #
    # ★★ 这里就是「长按电源键弹不出重启菜单」的真正原因（2026-09-28 实测）。
    #   设备进 `mem` 之后，powerd 对电源键的解释变成「唤醒」，
    #   而不是「长按 → 弹 UI 菜单」。真机现象：
    #       长按约 8 秒 → 整屏闪一下 → 全黑 → 无任何后续
    #   （屏幕全黑 = 确实执行了 suspend，不是菜单被谁压住）
    #
    #   这是**取舍**，不是 bug：深度休眠（续航几个月）与
    #   「长按弹 UI 菜单」（要求系统保持活动）在语义上互斥。
    #   我们选休眠。想重启就先退出看板，回原生界面再长按。
    #
    #   别试图「修」这个：把 mem 换成普通 sleep 后菜单是有了，
    #   但设备不再 suspend，续航会从几个月掉到几天。
    for r in /sys/class/rtc/rtc0 /sys/class/rtc/rtc1 /sys/class/rtc/rtc2; do
        if [ -e "$r/wakealarm" ]; then
            echo 0 > "$r/wakealarm" 2>/dev/null
            if echo "+$INTERVAL" > "$r/wakealarm" 2>/dev/null; then
                return 0
            fi
        fi
    done
    return 1
}

loop() {
    hold_screen
    n=0
    # 连续拉图失败次数，达到阈值就触发一次 WiFi 自愈（见下面的失败分支）
    _fail_streak=0
    while true; do
        n=$((n + 1))

        # 每轮重新压一次 lab126_gui / webreader：休眠唤醒后它们有可能
        # 被系统重新拉起，一旦活过来主页就会盖住看板。开销可忽略，图个稳。
        # ★ 注意这里**不碰 framework**（保留电源键功能，见 hold_screen 说明）。
        hold_screen

        # 醒来先等网络真的通（原来是无条件 `sleep 8`，快慢都不管）。
        # _net_rc 语义见 wait_for_wifi：0=通 1=本机没连网 2=连上但不通
        wifi_on
        _net_rc=$?

        # ★ 先问服务端要不要退出，再决定刷不刷图。
        #   放在最前面：用户点了网页按钮后，设备一醒来就能立刻退，
        #   不用先白刷一帧再退（白刷一帧要十几秒，还费一次全屏刷新）。
        #
        #   代价是每轮多一次 HTTP 请求（几百字节）。
        #   相比 INTERVAL（默认 600 秒）的间隔，这点开销可忽略。
        #
        #   和拉图一样加一次重试：刚唤醒时 WiFi 可能还没就绪，
        #   单次失败会让用户的退出请求白等一个周期。
        if check_quit_request; then
            exit_dashboard
            exit 0
        fi

        if fetch_image; then
            # 定期整屏清白再画，避免墨水屏残影累积
            if [ $((n % FULL_EVERY)) -eq 0 ]; then
                "$EIPS" -c 2>/dev/null
            fi
            draw_image
            # ★ 贴完图再叠本地时间 —— draw_image 是全屏贴图，
            #   会把上一次叠的字盖掉，所以顺序必须是「先贴图、后写字」。
            draw_clock
            log "第 $n 帧刷新成功"
            _fail_streak=0
        else
            # ★ 拉图失败时不刷图，但**本地时间照样重写** ——
            #   这样屏幕上的 NOW 一直在走，而图上的时间停在旧的，
            #   两者一对比就知道数据过期多久了。
            draw_clock
            # ★ 只有 rc=2（连上了但不通）才累计自愈计数。
            #   rc=1 是「本机压根没连网」—— 这台设备的网络源是**手机热点**，
            #   热点一关就是这个状态。此时 toggle 无线毫无意义（热点不在，
            #   toggle 也连不上；热点回来设备自己会重连）。
            #   所以 rc=1 不累计、不触发自愈，只记一条日志。
            # ★ 计入自愈的条件（2026-09-29 二次修正）：
            #   rc=1（没连网）和 rc=2（连上但不通）**都算网络层故障 → 计数**。
            #
            #   为什么 rc=1 也要计数？因为实测发现：**热点回来时设备
            #   不一定会自己重连** —— 用户观察到必须插拔一次 USB 才恢复。
            #   而 toggle 无线就是等效的「踢一脚」，是唯一的自动恢复手段。
            #   （toggle 的代价只是 10 秒无线关开，比"一直连不上"划算得多。）
            #
            #   rc=0 说明网络是通的、问题在服务端 —— 这时 toggle 无线毫无意义。
            case "$_net_rc" in
                1|2) _fail_streak=$((_fail_streak + 1)) ;;
                *)   _fail_streak=0 ;;
            esac
            case "$_net_rc" in
                2) log "第 $n 帧拉取失败（连上网络但不通）· 连续 $_fail_streak 次" ;;
                1) log "第 $n 帧拉取失败（本机未连网，如热点已关）· 连续 $_fail_streak 次" ;;
                *) log "第 $n 帧拉取失败（网络通，可能是服务端问题）" ;;
            esac
            # ★ 连续「连上但不通」到阈值才 toggle，治真正的「WiFi 卡在坏状态」
            if [ "$WIFI_RESTART_AFTER" -gt 0 ] 2>/dev/null; then
                if [ "$_fail_streak" -ge "$WIFI_RESTART_AFTER" ]; then
                    restart_wifi
                    _fail_streak=0
                fi
            fi
        fi
        wifi_off

        if setup_alarm; then
            # 刷屏后必须等画面写完再休眠，睡早了会留下残缺/半刷新的屏幕
            sleep 5
            echo mem > /sys/power/state
            log "被 RTC 唤醒"
        else
            log "这台机器没有可用的 wakealarm，退化为普通 sleep"
            sleep "$INTERVAL"
        fi
    done
}

case "$1" in
    once)
        hold_screen
        # 手动刷新时也等一次网络就绪：刚开机 / 刚插上电时 WiFi 可能还没连上，
        # 等到了再拉，免得用户手动点一次却看到「拉取失败」。
        wifi_on || log "网络似乎不通，仍尝试拉一次"
        if fetch_image; then
            draw_image
            draw_clock
            log "手动刷新成功"
            echo "刷新成功，看看屏幕"
            echo "退出看板：网页点「退出看板」再按一下电源键唤醒；或长按电源键 10 秒强制重启"
        else
            log "手动刷新失败"
            echo "拉取失败，检查服务端地址和网络：$LOG"
            exit 1
        fi
        ;;
    start)
        if [ -f "$PID" ] && kill -0 "$(cat "$PID")" 2>/dev/null; then
            echo "已经在跑，PID $(cat "$PID")"
            exit 0
        fi
        # Kindly 的 busybox 里可能没有 nohup / setsid，
        # 后台进程会在 SSH 断开时被 SIGHUP 杀掉，所以用 trap 忽略挂断信号
        ( trap '' HUP; "$0" _loop ) >/dev/null 2>&1 &
        echo $! > "$PID"
        echo "已启动，PID $(cat "$PID")"
        ;;
    _loop)
        loop
        ;;
    stop)
        release_screen
        if [ -f "$PID" ]; then
            kill "$(cat "$PID")" 2>/dev/null
            rm -f "$PID"
            echo "已停止"
        else
            echo "没有 PID 文件，可能没在跑"
        fi
        ;;
    status)
        if [ -f "$PID" ] && kill -0 "$(cat "$PID")" 2>/dev/null; then
            echo "运行中，PID $(cat "$PID")"
        else
            echo "未运行"
        fi
        echo "--- 日志尾部 ---"
        tail -n 15 "$LOG" 2>/dev/null
        ;;
    *)
        echo "用法: $0 {once|start|stop|status}"
        exit 1
        ;;
esac
