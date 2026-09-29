#!/bin/bash
# 服务端遥控退出 —— 端到端集成测试
#
# 覆盖：
#   A. /control/status 语义（无人请求 / 请求后 / ack 复位）
#   B. check_quit_request 的真实提取逻辑（从 dashboard.sh 里抠出来跑）
#   C. exit_dashboard 的状态机（复刻 loop() 里的顺序）
#   D. 服务重启后状态保留（.control 落盘）
#   E. 安全：无 token 时写操作必须被拒
#
# 用法：bash tests/test_control_e2e.sh
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
SERVER_DIR="$ROOT/server"

# ★ 必须用项目自带的 venv：系统/托管 python 没装 flask + yaml + Pillow，
#   直接用会 ModuleNotFoundError: No module named 'yaml'。
#   Git Bash 的 /usr/bin 要挂进 PATH，否则出图时找不到字体/工具。
GITBASH_BIN="/c/Users/W/.workbuddy/binaries/PortableGit/versions/1.2.0/bin"
PY="$ROOT/.venv/Scripts/python.exe"
if [ ! -f "$PY" ]; then
    echo "找不到 $PY —— 先跑：python -m venv .venv && .venv/Scripts/pip install -r server/requirements.txt"
    exit 1
fi
DASH="$ROOT/kindle/dashboard.sh"

PORT=8799
TOKEN="testtoken-$$"
BASE="http://127.0.0.1:$PORT"
CTRL_FILE="$SERVER_DIR/.control"

PASS=0
FAIL=0
ok()   { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }
chk()  { if [ "$2" = "$3" ]; then ok "$1 ($2)"; else bad "$1 — 期望[$3] 实际[$2]"; fi; }

# ★ 停服务不能只 kill 父 PID / 也不能靠 pkill -f main.py。
#   Windows 上 venv 的 python 是 launcher，真正的服务进程是它的**子进程**，
#   父进程死了子进程照样占着端口（WIN 没有进程组信号传播）。
#   踩过这个坑：4 个野进程叠在端口上，请求打到持有旧 token 的旧进程 → 满屏 401。
#   所以统一走 taskkill 按镜像名清，再轮询端口确认真空。
stop_server() {
    if [ -n "${srv_pid:-}" ]; then
        kill "$srv_pid" 2>/dev/null
        wait "$srv_pid" 2>/dev/null
    fi
    taskkill //F //IM python.exe >/dev/null 2>&1
    local i
    for i in $(seq 1 20); do
        netstat -ano 2>/dev/null | grep -q ":$PORT .*LISTENING" || return 0
        sleep 0.5
    done
    return 1
}

port_busy() { netstat -ano 2>/dev/null | grep -q ":$PORT .*LISTENING"; }

srv_pid=""
cleanup() {
    stop_server
    rm -f "$CTRL_FILE" "$CTRL_FILE".*.tmp 2>/dev/null
    [ -n "${RUN_CFG:-}" ] && rm -rf "$(dirname "$RUN_CFG")" 2>/dev/null
    return 0
}
trap cleanup EXIT

echo "=== 起测试服务 (port $PORT, token $TOKEN) ==="

# ★ 起服务前必须先清场。
#   踩过的坑：上一次测试没退干净的 flask 进程还占着端口，
#   新起的进程 start 失败但 curl /health 是**旧进程**应答的 → 服务"看起来就绪"，
#   于是所有请求都打到持有旧 token 的旧进程上，满屏 401。
#   表现是"这次跑挂了一半、上次全过"，非常容易误判成代码问题。
stop_server
if port_busy; then
    echo "!! 端口 $PORT 清不掉，测试无法可靠进行。先手动处理："
    netstat -ano | grep ":$PORT .*LISTENING"
    exit 1
fi

# ★ 端口不能只用环境变量糊弄：config.yaml 里的 server.port 会被 main.py 的
#   __main__ 分支读走，环境变量根本没有对应入口。所以现造一份临时配置，
#   改掉 port（顺带把 weather / token 两个外部源关掉，测试不该依赖外网）。
#
# ★ TMPDIR=/tmp 的原因见下面 B 段开头那段说明（Windows 路径污染 PATH）。
RUN_CFG="$(TMPDIR=/tmp mktemp -d)/config.yaml"
"$PY" - "$SERVER_DIR/config.yaml" "$RUN_CFG" "$PORT" <<'PYEOF'
import sys, yaml
src, dst, port = sys.argv[1], sys.argv[2], int(sys.argv[3])
cfg = yaml.safe_load(open(src, encoding="utf-8"))
cfg.setdefault("server", {})["port"] = port
cfg["server"]["host"] = "127.0.0.1"
# 关掉外部依赖：测试只验证遥控通道，不该被天气/MiniMax 的网络状况左右
if isinstance(cfg.get("weather"), dict):
    cfg["weather"]["enabled"] = False
if isinstance(cfg.get("token"), dict):
    cfg["token"]["enabled"] = False
yaml.safe_dump(cfg, open(dst, "w", encoding="utf-8"), allow_unicode=True)
PYEOF
if [ ! -f "$RUN_CFG" ]; then echo "生成临时配置失败"; exit 1; fi

rm -f "$CTRL_FILE"
(
  cd "$SERVER_DIR" || exit 1
  export DASH_ACCESS_TOKEN="$TOKEN"
  export CONFIG_PATH="$RUN_CFG"
  export PATH="$GITBASH_BIN:$PATH"
  "$PY" main.py >/tmp/srv_e2e.log 2>&1
) &
srv_pid=$!

# 等服务起来
for i in $(seq 1 40); do
    if curl -s -o /dev/null "$BASE/health" 2>/dev/null; then break; fi
    sleep 0.5
done
if ! curl -s -o /dev/null "$BASE/health" 2>/dev/null; then
    echo "服务没起来，日志："; tail -n 30 /tmp/srv_e2e.log; exit 1
fi
echo "服务已就绪"
echo

# ── 从 dashboard.sh 抽出真实函数 ────────────────────────────────
# 不重写一份逻辑：直接抠源码，保证测的就是真正会跑的那份。
extract_fn() {
    local name="$1"
    awk -v fn="$name" '
        $0 ~ "^"fn"\\(\\)" { inside=1 }
        inside { print }
        inside && /^}/ { exit }
    ' "$DASH"
}

# 环境变量：让函数只依赖这几个
cn() { :; }   # 占位

echo "=== A. /control/status 语义 ==="
r=$(curl -s "$BASE/control/status?token=$TOKEN")
chk "初始应未请求退出" "$(echo "$r" | grep -o '"quit": *[a-z]*' | grep -o '[a-z]*$')" "false"

curl -s -X POST "$BASE/control/quit?token=$TOKEN" >/dev/null
r=$(curl -s "$BASE/control/status?token=$TOKEN")
chk "POST quit 后应为 true" "$(echo "$r" | grep -o '"quit": *[a-z]*' | grep -o '[a-z]*$')" "true"

curl -s -X POST "$BASE/control/ack?token=$TOKEN" >/dev/null
r=$(curl -s "$BASE/control/status?token=$TOKEN")
chk "ack 后应复位为 false" "$(echo "$r" | grep -o '"quit": *[a-z]*' | grep -o '[a-z]*$')" "false"
echo

echo "=== B. check_quit_request 真实逻辑（12 种 JSON 形态）==="
# 用 _body 直接喂给函数：把函数体里取 URL 的部分替换掉不方便，
# 所以改成「函数 + 桩」的方式 —— 造一个假 wget 输出指定 body。
#
# ★★ 这里必须显式指定 TMPDIR=/tmp，不能裸用 mktemp -d。
#   踩过的坑：在 Windows/git-bash（MSYS）下，裸 `mktemp -d` 会返回
#   **Windows 风格**的路径，形如
#       C:\Users\W\AppData\Local\Temp/tmp.XXXX
#   看着能当路径用，但把它 `export PATH="$RUN:$PATH"` 之后 ——
#   MSYS 会把反斜杠当转义符处理，路径被啃成
#       \Users\W\AppData\Local\Temp/tmp.XXXX
#   PATH 里就多了一条**无效项**，于是 `command -v wget` 找不到那个假 wget，
#   函数里 `if command -v wget ... elif command -v curl ...` 的分支
#   就**落到真实的 curl 上**，去请求真服务端（如果 A 段的服务还在跑，
#   就会拿到真实的 `{"quit": false}`）→ 用例误判。
#
#   表现极具迷惑性：单独跑这三个用例**全过**，整套一起跑就挂，
#   因为单跑时 A 段的服务没起来，curl 拿不到东西，恰好"蒙对"了
#   （失败方向是不退出，正好等于期望值）。
#
#   修法：`TMPDIR=/tmp mktemp -d` 强制拿到 POSIX 路径（/tmp/...）。
RUN=$(TMPDIR=/tmp mktemp -d)
cat > "$RUN/wget" <<'WEOF'
#!/bin/bash
# 假 wget：不管参数是什么，都输出 $FAKE_BODY
printf '%s' "$FAKE_BODY"
exit "${FAKE_RC:-0}"
WEOF
chmod +x "$RUN/wget"

{
    echo 'LOG=/dev/null'
    echo 'log() { :; }'
    echo 'CONTROL=1'
    echo 'SERVER=http://x'
    echo 'TOKEN=t'
    extract_fn check_quit_request
} > "$RUN/fn.sh"

# 逐个喂 body，检查函数返回码
feed() {
    local body="$1"
    local expect="$2"   # 0=退出 1=不退出
    (
        export PATH="$RUN:$PATH"
        export FAKE_BODY="$body"
        # shellcheck disable=SC1090
        . "$RUN/fn.sh"
        check_quit_request
        echo "rc=$?"
    ) | sed -n 's/^rc=//p'
}

t() {
    local body="$1" expect="$2" desc="$3"
    got=$(feed "$body" "$expect")
    chk "$desc" "$got" "$expect"
}

t '{"quit": true, "set_at": 123, "note": "web"}'            0 '正常 true'
t '{"quit": false, "set_at": 0, "note": ""}'                1 '正常 false'
t '{"quit": false, "note": "true"}'                         1 '★ trap: false+note含true'
t '{"quit": true, "note": "false"}'                         0 '★ trap: true+note含false'
t '{"note": "quit true", "quit": false}'                    1 'note 里出现 quit true'
t '{"quit":false}'                                          1 '紧凑无空格 false'
t '{"quit":true}'                                           0 '紧凑无空格 true'
t '{"quit": true, "quit": false}'                           1 '重复字段取后者（sed 贪婪）'
# ★ 值为带引号的字符串 "true"：sed 提取失败 → 当成不退出。
#   这是**故意保留**的行为，不是 bug：
#     - 服务端用 jsonify()，布尔永远是裸的 true/false，不会带引号；
#     - 万一某天格式变了，失败方向是「不退出」（安全）而不是「乱退出」。
#   所以不为此加"宽松匹配"，宽松了反而会把 note 里的 true 认进来（见上面那个 trap）。
t '{"quit": "true"}'                                        1 '值是字符串"true" → 保守不退出'
t '{}'                                                      1 '空对象'
t 'garbage not json'                                        1 '非 JSON'
t ''                                                        1 '空响应'
echo

echo "=== C. loop() 状态机复刻 ==="
st() { curl -s "$BASE/control/status?token=$TOKEN" | grep -o '"quit": *[a-z]*' | grep -o '[a-z]*$'; }
run_cycle() {
    # 复刻 loop()：查 quit → 若退则 ack 后结束，否则"刷图"
    if [ "$(st)" = "true" ]; then
        curl -s -X POST "$BASE/control/ack?token=$TOKEN" >/dev/null
        echo "EXIT"
    else
        echo "REFRESH"
    fi
}

curl -s -X POST "$BASE/control/cancel?token=$TOKEN" >/dev/null
chk "无人请求 → 第1轮" "$(run_cycle)" "REFRESH"
chk "无人请求 → 第2轮" "$(run_cycle)" "REFRESH"

curl -s -X POST "$BASE/control/quit?token=$TOKEN" >/dev/null
chk "点按钮后 → 应退出" "$(run_cycle)" "EXIT"
chk "退出后 quit 已复位" "$(st)" "false"
chk "重启看板 → 不会再立刻退" "$(run_cycle)" "REFRESH"
echo

echo "=== D. 服务重启后状态保留 ==="
curl -s -X POST "$BASE/control/quit?token=$TOKEN" >/dev/null
chk "重启前 quit 已置位" "$(st)" "true"

kill "$srv_pid" 2>/dev/null
wait "$srv_pid" 2>/dev/null
if ! stop_server; then
    echo "!! 旧进程没死透，端口 $PORT 仍被占用"; exit 1
fi

(
  cd "$SERVER_DIR" || exit 1
  export DASH_ACCESS_TOKEN="$TOKEN"
  export CONFIG_PATH="$RUN_CFG"
  export PATH="$GITBASH_BIN:$PATH"
  "$PY" main.py >/tmp/srv_e2e2.log 2>&1
) &
srv_pid=$!
for i in $(seq 1 40); do
    curl -s -o /dev/null "$BASE/health" 2>/dev/null && break
    sleep 0.5
done
chk "重启后 quit 仍为 true（状态落盘）" "$(st)" "true"
curl -s -X POST "$BASE/control/ack?token=$TOKEN" >/dev/null
echo

echo "=== E. 安全：写操作必须带 token ==="
c=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/control/quit")
chk "无 token POST quit → 401" "$c" "401"
c=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/control/quit?token=wrong")
chk "错 token POST quit → 401" "$c" "401"
c=$(curl -s -o /dev/null -w '%{http_code}' "$BASE/control/status")
chk "无 token GET status → 401" "$c" "401"
c=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/control/quit?token=$TOKEN")
chk "对 token POST quit → 200" "$c" "200"
c=$(curl -s -o /dev/null -w '%{http_code}' "$BASE/health")
chk "/health 免 token → 200" "$c" "200"
c=$(curl -s -o /dev/null -w '%{http_code}' "$BASE/control/quit?token=$TOKEN")
chk "GET /control/quit → 405" "$c" "405"

rm -rf "$RUN"
echo
echo "════════════════════════════════"
printf '通过 %d / 失败 %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] && echo "全部通过 ✅" || echo "有失败项 ❌"
exit "$FAIL"
