#!/bin/bash
# WiFi 就绪等待 + 自愈逻辑 —— 单元测试
#
# 覆盖：
#   A. wait_for_wifi：通了立刻走 / 等几次才通 / 一直不通超时
#   B. 自愈状态机：连续失败到阈值才 toggle、成功即归零、阈值 0 关闭
#   C. wifi_on 的返回语义 + restart_wifi 的结构
#
# 用法：bash tests/test_wifi_logic.sh
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
DASH="$ROOT/kindle/dashboard.sh"

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }
chk() { if [ "$2" = "$3" ]; then ok "$1 ($2)"; else bad "$1 — 期望[$3] 实际[$2]"; fi; }

# ★ TMPDIR=/tmp 不能省：MSYS/git-bash 下裸 `mktemp -d` 会返回
#   Windows 风格路径（C:\Users\...\Temp/tmp.XXX），一旦 export PATH 进去，
#   反斜杠被当转义符啃掉 → PATH 里多一条无效项 → 假命令找不到，
#   测试会静默落到真实命令上。踩过一次，见 MEMORY.md。
RUN=$(TMPDIR=/tmp mktemp -d)
trap 'rm -rf "$RUN"' EXIT

mkdir -p "$RUN/bin"

# ── 假 ping：按计数决定"第几次开始成功" ──────────────────────────
# FAKE_PING_STATE 指向计数文件，FAKE_PING_OK_AT 指定从第几次起返回成功
cat > "$RUN/bin/ping" <<'EOS'
#!/bin/sh
n=$(cat "$FAKE_PING_STATE" 2>/dev/null || echo 0)
n=$((n + 1))
echo "$n" > "$FAKE_PING_STATE"
[ "$n" -ge "$FAKE_PING_OK_AT" ] && exit 0
# FAKE_PING_MSG 非空时把它写到 stderr，模拟内核的 unreachable 报错
[ -n "${FAKE_PING_MSG:-}" ] && echo "$FAKE_PING_MSG" >&2
exit 1
EOS
chmod +x "$RUN/bin/ping"

# ── 从 dashboard.sh 抠出真实函数（不重写一份，保证测的是会跑的那份）──
{
    awk '/^wait_for_wifi\(\)/,/^}/' "$DASH"
    awk '/^wifi_on\(\)/,/^}/'      "$DASH"
    # 覆盖真实 log（它要写设备上的路径），只回显
    echo 'log() { echo "[LOG] $*"; }'
} > "$RUN/lib.sh"

for fn in wait_for_wifi wifi_on; do
    grep -q "^$fn()" "$RUN/lib.sh" || {
        echo "!! 没能从 dashboard.sh 抠出 $fn —— 函数名或写法变了？"
        exit 1
    }
done

export PATH="$RUN/bin:$PATH"
export WIFI_TEST_IP=1.1.1.1
PING_OPTS="-c 1"
export PING_OPTS

# 用子 shell 跑，避免函数定义/变量互相污染。
#
# ★ 断言用「ping 被调用了几次」而不是「花了多少秒」——
#   git-bash 下每 fork 一个进程要几百毫秒（假 ping 本身是个脚本），
#   测时间会假失败。调用次数才是行为的本质：通了就走 = 只调 1 次。
LAST_RC=0
LAST_CALLS=0
LAST_OUT=""
run_wait() {
    echo 0 > "$RUN/state"
    LAST_OUT=$(FAKE_PING_STATE="$RUN/state" FAKE_PING_OK_AT="$1" \
        FAKE_PING_MSG="${FAKE_PING_MSG:-}" \
        sh -c ". '$RUN/lib.sh'; WIFI_WAIT_MAX='$2'; wait_for_wifi" 2>&1)
    LAST_RC=$?
    LAST_CALLS=$(tr -d ' \r\n' < "$RUN/state" 2>/dev/null)
    [ -n "$LAST_CALLS" ] || LAST_CALLS=0
}

echo "=== A. wait_for_wifi 行为 ==="

# A1: 第一次就通 —— 通了就走，只 ping 一次
run_wait 1 10
chk "A1 ping 立刻通 → 返回码" "$LAST_RC" "0"
chk "A1 只 ping 1 次（通了就走，不空等）" "$LAST_CALLS" "1"

# A2: 第 3 次才通 —— 恰好 ping 3 次，不等到上限，并报出等待秒数
run_wait 3 10
chk "A2 第 3 次才通 → 返回码" "$LAST_RC" "0"
chk "A2 恰好 ping 3 次（不是死等到上限）" "$LAST_CALLS" "3"
case "$LAST_OUT" in
    *"网络就绪（等了 2 秒）"*) ok "A2 日志报了等待秒数" ;;
    *) bad "A2 日志缺等待秒数：$LAST_OUT" ;;
esac

# A3: 一直不通（没有 unreachable 报错）—— ping 满上限才放弃，返回超时码 2
run_wait 999 3
chk "A3 一直不通 → 超时码 2" "$LAST_RC" "2"
chk "A3 ping 满 3 次才放弃" "$LAST_CALLS" "3"
case "$LAST_OUT" in
    *"网络等待超时"*) ok "A3 日志报了超时" ;;
    *) bad "A3 日志缺超时提示：$LAST_OUT" ;;
esac

# A5: ★ 内核报 unreachable（手机热点关了）→ 立刻放弃，不空等
FAKE_PING_MSG="ping: sendto: Network is unreachable"
run_wait 999 10
chk "A5 网络不可达 → 返回码 1（区别于超时的 2）" "$LAST_RC" "1"
chk "A5 只 ping 1 次就放弃（不空等满 10 秒）" "$LAST_CALLS" "1"
case "$LAST_OUT" in
    *"不可达"*) ok "A5 日志报了「不可达」" ;;
    *) bad "A5 日志缺提示：$LAST_OUT" ;;
esac

# A6: 另一种常见措辞也要能识别
FAKE_PING_MSG="connect: Network is unreachable"
run_wait 999 5
chk "A6 另一种 unreachable 措辞同样识别" "$LAST_RC" "1"
chk "A6 同样只 ping 1 次" "$LAST_CALLS" "1"
FAKE_PING_MSG=""

# A4: 探测目标可配置
echo 0 > "$RUN/state"
out=$(FAKE_PING_STATE="$RUN/state" FAKE_PING_OK_AT=1 WIFI_TEST_IP=9.9.9.9 \
      sh -c ". '$RUN/lib.sh'; WIFI_WAIT_MAX=5; wait_for_wifi" 2>&1)
chk "A4 自定义探测 IP 时仍返回 0" "$?" "0"

echo
echo "=== B. 自愈状态机（复刻 loop() 里的 _fail_streak 逻辑）==="

# ★ 注意：这段是**复刻**，不是从 dashboard.sh 抠出来的 —— 该逻辑嵌在
#   loop() 里无法单独调用。**改动 loop 的那段时，请同步这里。**
# 每项含义：
#   1 = 拉图成功（清零）
#   2 = 网络层故障（rc=1 没连网 / rc=2 连上但不通）→ 计数
#   3 = 网络是通的、但拉图失败（服务端问题）→ 清零，不 toggle
simulate() {
    _streak=0
    _toggles=0
    _thr="$2"
    for r in $1; do
        if [ "$r" = "2" ]; then
            _streak=$((_streak + 1))
            if [ "$_thr" -gt 0 ] 2>/dev/null; then
                if [ "$_streak" -ge "$_thr" ]; then
                    _toggles=$((_toggles + 1))
                    _streak=0
                fi
            fi
        else
            _streak=0
        fi
    done
    echo "$_toggles"
}

chk "B1 网络故障 2 次（阈值 3）→ 不该 toggle" "$(simulate '2 2' 3)" "0"
chk "B2 网络故障 3 次（阈值 3）→ toggle 1 次" "$(simulate '2 2 2' 3)" "1"
chk "B3 故障2 + 成功 + 故障2 → 不该 toggle" "$(simulate '2 2 1 2 2' 3)" "0"
chk "B4 连续故障 6 次（阈值 3）→ toggle 2 次" "$(simulate '2 2 2 2 2 2' 3)" "2"
chk "B5 阈值设 0 → 自愈关闭" "$(simulate '2 2 2 2 2 2 2' 0)" "0"
chk "B6 一直成功 → 不该 toggle" "$(simulate '1 1 1 1' 3)" "0"
chk "B7 ★ 服务端问题（网络是通的）→ 不该 toggle" "$(simulate '3 3 3 3' 3)" "0"
chk "B8 ★ 服务端问题会打断连续计数" "$(simulate '2 2 3 2 2' 3)" "0"
chk "B9 阈值 3 但连续 4 次 → 只 toggle 1 次（不重复）" "$(simulate '2 2 2 2' 3)" "1"

echo
echo "=== C. wifi_on 返回语义 + restart_wifi 结构 ==="

# C1: WIFI_TOGGLE=0（默认，平时不碰 WiFi）时，wifi_on 仍然会等网络
echo 0 > "$RUN/state"
FAKE_PING_STATE="$RUN/state" FAKE_PING_OK_AT=1 \
  sh -c ". '$RUN/lib.sh'; WIFI_TOGGLE=0; WIFI_WAIT_MAX=5; wifi_on" >/dev/null 2>&1
chk "C1 WIFI_TOGGLE=0 时 wifi_on 也等网络（通 → 0）" "$?" "0"

# C2: 网络超时（有连接但不通）时 wifi_on 返回 2
echo 0 > "$RUN/state"
FAKE_PING_STATE="$RUN/state" FAKE_PING_OK_AT=999 \
  sh -c ". '$RUN/lib.sh'; WIFI_TOGGLE=0; WIFI_WAIT_MAX=2; wifi_on" >/dev/null 2>&1
chk "C2 网络超时时 wifi_on 返回 2" "$?" "2"

# C5: ★ 本机没连网（unreachable）时 wifi_on 返回 1
#     —— 这条返回值决定了 loop **不会**触发自愈（热点关了 toggle 没意义）
echo 0 > "$RUN/state"
FAKE_PING_STATE="$RUN/state" FAKE_PING_OK_AT=999 \
  FAKE_PING_MSG="connect: Network is unreachable" \
  sh -c ". '$RUN/lib.sh'; WIFI_TOGGLE=0; WIFI_WAIT_MAX=5; wifi_on" >/dev/null 2>&1
chk "C5 本机没连网时 wifi_on 返回 1" "$?" "1"

# C3: restart_wifi 的结构（不实际调用 —— 里面有两个 sleep 5，跑一次要 10 秒）
awk '/^restart_wifi\(\)/,/^}/' "$DASH" > "$RUN/rw.sh"
if [ -s "$RUN/rw.sh" ]; then
    ok "C3 restart_wifi 存在"
else
    bad "C3 找不到 restart_wifi"
fi
grep -q 'com.lab126.wifid enable 0' "$RUN/rw.sh" && ok "C3 有「关闭无线」步骤" || bad "C3 缺关闭步骤"
grep -q 'com.lab126.wifid enable 1' "$RUN/rw.sh" && ok "C3 有「打开无线」步骤" || bad "C3 缺打开步骤"

# C4: 两个新变量都有默认值
grep -q 'WIFI_WAIT_MAX="\${DASH_WIFI_WAIT_MAX:-30}"' "$DASH" && ok "C4 WIFI_WAIT_MAX 默认 30" || bad "C4 WIFI_WAIT_MAX 默认值不对"
grep -q 'WIFI_RESTART_AFTER="\${DASH_WIFI_RESTART_AFTER:-3}"' "$DASH" && ok "C4 WIFI_RESTART_AFTER 默认 3" || bad "C4 WIFI_RESTART_AFTER 默认值不对"

echo
echo "════════════════════════════════"
echo "通过 $PASS / 失败 $FAIL"
if [ "$FAIL" -eq 0 ]; then
    echo "全部通过 ✅"
    exit 0
else
    echo "有失败 ❌"
    exit 1
fi
