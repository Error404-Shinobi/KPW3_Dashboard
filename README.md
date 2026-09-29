# KPW3 墨水屏看板

**中文** | [English](README.en.md)

把闲置的 Kindle Paperwhite 3 改成常显信息面板：日期时间、天气、
**MiniMax Token Plan 额度消耗**，顺便还能当 KOReader 笔记阅读器用。

> 部署过程中踩过的坑都记在 [`docs/pitfalls.md`](docs/pitfalls.md) 里 ——
> 跨区认证、CentOS 7 老环境、CA 证书静默失败、systemd 优先级等。
> **动工前建议先扫一眼，能省不少时间。**

```
┌─────────────────┐   HTTP GET     ┌──────────────┐
│ Linux 服务器     │ ─────────────▶ │ KPW3（越狱）  │
│ Python + Pillow │  dashboard.png │ eips 刷屏     │
│ 拉天气 + 查额度  │ ◀── ?batt=85   │ RTC 唤醒休眠  │
└─────────────────┘                └──────────────┘
```

渲染放在服务器，Kindle 只干三件事：拉图 → `eips` 刷屏 → 深度休眠。
休眠时 CPU 断电但画面保留，所以一次充电能撑很久。

**屏幕参数（别搞错）**：KPW3 是 **1448 × 1072**、300ppi、16 级灰度。
网上很多教程写 758×1024，那是 Paperwhite 1/2 的，照抄会导致画面错位。

**★ 注意「画布尺寸」和「framebuffer 尺寸」不是一回事。** 实测 `eips -i`：

```
xres: 1072    yres: 1448    bits_per_pixel: 8    grayscale: 1
```

即显存本身是 **1072×1448 的竖屏**，而 `eips -g` 只会把图片原样贴上去，
**不做旋转、不转色深**（官方 wiki 上全部选项只有 `-g -b -w -f -x -y -v`）。

所以服务端必须自己完成两步变换，配置里的 `display.rotate: true` 就是干这个的：

```python
img.transpose(2)      # 1448×1072 → 1072×1448（逆时针！2 == ROTATE_90）
img.convert("L")      # 8 位灰度，跟 framebuffer 对齐
```

> 用 `transpose(2)` 而不是 `Image.Transpose.ROTATE_90`，
> 是因为后者要 Pillow ≥ 9.1，而我们的依赖下限是 8.0 —— 否则服务会启动即崩。

漏了会怎样：图片右边被切、内容错位（看起来像"竖屏版"），
**而且会惊动 framework 弹出软键盘把画面盖住**。
想在浏览器里直观看横屏布局时，把 `rotate` 临时设成 `false` 即可。

**★ 端口分工（搞错必踩坑）**：

| 角色 | 监听 | 说明 |
|---|---|---|
| nginx | `0.0.0.0:8787` | 对公网，Kindle 访问的就是它 |
| Flask | `127.0.0.1:8789` | 仅本机，由 nginx 反代进来 |

两边**必须错开端口**。Flask 也去听 8787 的话，会和 nginx 抢端口，
报 `Address already in use` 且 `pkill main.py` 杀不掉（占用者其实是 nginx）。
详见 [`docs/nginx.md`](docs/nginx.md)。

---

## 目录

| 路径 | 作用 |
|---|---|
| `server/` | Linux 服务器上跑的渲染服务 |
| `server/config.yaml.example` | 配置文件模板，复制成 `config.yaml` 再改 |
| `kindle/dashboard.sh` | Kindle 上的刷新守护脚本 |
| `kindle/config.env.example` | **设备端配置模板**，复制成 `config.env` 放 Kindle 上 |
| `kindle/runme.sh` | 免 SSH 入口，从原生界面用搜索框 `;log runme` 启动看板 |
| `kindle/stopdash.sh` | 看板**已停止**后清理残留、恢复原生界面（**不能退出运行中的看板**，见下文） |
| `kindle/install.sh` | 从电脑把脚本推到 Kindle |
| `docs/PROJECT-LOG.md` | **完整工程记录**（架构决策 + 踩坑 + 速查） |
| `docs/pitfalls.md` | **踩坑记录**，部署前先看这个 |
| `docs/nginx.md` | nginx 反代配置 + 端口分工（**装 nginx 必看**） |
| `deploy.sh` / `deploy.ps1` | 可选，rsync / scp 上传脚本 |

---

## 阶段一：给 KPW3 越狱

> 📋 **详细的分步操作清单见 [`docs/jailbreak.md`](docs/jailbreak.md)**
> —— 五个阶段、每阶段带验证点，末尾有"卡住怎么查"对照表。建议对着它做。

> 有风险，操作前先把 `documents` 整个备份到电脑。软砖的救法（串口 + u-boot）
> 见 `zzwcoding/weread-kpw3` 仓库的 `docs/04`。

### 前置检查

1. **固件 ≤ 5.16.2.1.1**。看：菜单 → Settings → 菜单 → Device Info。
   KPW3 官方最终版就是 5.16.2.1.1，已停更，所以基本都满足。低于它先升到它。
2. **开启飞行模式**，整个越狱过程不连 WiFi。
3. **关掉设备密码**（有密码的话，密码框输入 `111222777` 可重置，但会清空数据）。
4. 连接电脑，**删掉根目录所有 `.bin` 文件和 `update.bin.tmp.partial`**。
5. 备份 `documents` 文件夹 —— LanguageBreak 会清空内容。

### 用 LanguageBreak 越狱

KPW3 上**优先选 LanguageBreak**，别选 WinterBreak（有反馈 WinterBreak 跑完重启报错）。

主干流程：

1. 设备重置：设置 → 设备选项 → 重置
2. 搜索框输入 `;enter_demo` 回车 → **手动重启**（不会自动重启，别等）
3. 重启后：跳过 WiFi → 注册信息随意填 → Skip → Standard → Done
   （中间会白屏一会儿，耐心等进入循环播放图片的状态）
4. **神秘手势**进图书馆：两根手指同时轻点屏幕右下角，紧接着一指从右向左横滑。
   不成功就多试几次，每次间隔 1-2 秒
5. 搜索框输入 `;demo` 进演示菜单 → 点「导入内容 / Sideload Content」→ 连电脑
6. 拷入 LanguageBreak 文件 → 按提示运行
7. 装 **hotfix**：注意要用 **KindleModding 通用 hotfix（2.5.0）**，
   **不是** LanguageBreak 自带的那个 —— 用错会导致后续插件装不上
8. 搜索框输入 `;uzb` 连电脑，退出演示模式回正常系统
9. 装 **MRPI**（选 FOR MODERN DEVICES，别下 PRE-K5 版）和 **KUAL**
10. 装 **USBNet**，后面全程靠 SSH 操作

> 每一步的确切文件名和命令以官方源为准：
> MobileRead 的 [LanguageBreak 帖子](https://www.mobileread.com/forums/showthread.php?t=356872)，
> 以及 `github.com/zzwcoding/weread-kpw3` 的 `docs/02-越狱与部署.md`（中文，写得很细）。

### 越狱后立刻做一件事：封死自动升级

**越狱成功 ≠ 阻止升级。** 联网前先在 KUAL 里执行 **Rename OTA Binaries**
（Helper 菜单下），否则亚马逊推一个官方固件过来，越狱就没了。

---

## 阶段二：服务端（Linux 服务器）

> **Python 需要 3.7+**（代码用了 dataclasses）。CentOS 7 自带的 3.6 不行，
> 见下面的"老服务器装新 Python"。

```bash
cd server
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt

# 中文字体是硬前提，没有的话画面全是豆腐块
apt install fonts-noto-cjk          # Debian/Ubuntu
# yum install google-noto-sans-cjk-fonts    # CentOS
# 验证：.venv/bin/python fontutil.py 应该能列出字体路径

cp config.yaml.example config.yaml
$EDITOR config.yaml
```

先不接 API，用假数据把布局和链路跑通：

```bash
DASH_FAKE_DATA=1 python main.py
```

然后浏览器打开 `http://服务器IP:8787/` —— 这是个等比预览页，
**调布局在这里看，别一遍遍刷墨水屏**，速度差几十倍。

确认没问题再配真实数据源（见下节），最后用 systemd 常驻：

```ini
# /etc/systemd/system/kindle-dashboard.service
[Unit]
Description=KPW3 dashboard
After=network.target

[Service]
WorkingDirectory=/opt/kindle-dashboard/server
# 密钥放 server/.env 就够了，这里不重复写 —— 写了会覆盖 .env。
# 真要在这里写，等号右边必须是纯 ASCII 的真实值：
# 占位符原样留下会导致 HTTP header 编码失败（latin-1 codec 错误）。
# 可选：设了之后请求要带 ?token=xxx（服务器有公网 IP 时建议开）
Environment=DASH_ACCESS_TOKEN=
ExecStart=/opt/kindle-dashboard/server/.venv/bin/python main.py
Restart=always

[Install]
WantedBy=multi-user.target
```

> `ExecStart` 要指向你的虚拟环境里的 python，别用 `/usr/bin/python3`
> —— 老系统上那是 3.6，跑不起来。

```bash
systemctl daemon-reload
systemctl enable --now kindle-dashboard
systemctl is-active kindle-dashboard      # 应返回 active
```

如果启动失败是 `Address already in use`，说明之前手动起的进程还占着端口：

```bash
pkill -f "main.py" && systemctl start kindle-dashboard
```

浏览器打不开时，排查顺序是 **云厂商安全组 → 系统防火墙 → 服务本身**。
云服务器最容易漏的是安全组（控制台里放行 TCP 8787），系统里敲命令没用。

```bash
systemctl enable --now kindle-dashboard
curl -s http://127.0.0.1:8787/debug.json | head   # 看数据源状态
```

---

### 老服务器装新 Python（CentOS 7 常踩）

系统自带的常常是 Python 3.6 + pip 9，装不上现代依赖（会报
`No matching distribution found for Flask>=3.0.0`）。3.6 不能用，因为项目依赖
`from __future__ import annotations` 和 `dataclasses`，都要 3.7+。

```bash
python3 --version          # 先确认

# 3.7 及以上：只是 pip 太老，升级一下就行
.venv/bin/pip install --upgrade pip
.venv/bin/pip install -r requirements.txt

# 3.6 及以下：装个新 Python
yum install -y epel-release
yum install -y python39 python39-pip     # 没有就试 python38
rm -rf .venv                              # 旧的删掉重建
python3.9 -m venv .venv
.venv/bin/pip install -r requirements.txt
```

腾讯/CentOS 镜像里如果找不到 `python39` 包，换个思路：
`yum install -y centos-release-scl && yum install -y rh-python38 && scl enable rh-python38 bash`

---

## 阶段三：接入 MiniMax Token Plan

MiniMax 的 Token Plan 有官方查询接口，`config.yaml` 里已经配好，只差你的 key：

```yaml
token:
  provider: minimax
  enabled: true
  label: MiniMax Token Plan
  # 国内账号用 minimaxi.com，国际账号用 minimax.io —— 跨区必定 invalid api key
  url: https://api.minimaxi.com/v1/token_plan/remains
  # 额度按模型拆分，一般关心 general（响应里还可能有 video 等）
  model: general
  api_key_env: MINIMAX_SUBSCRIPTION_KEY
```

放 key 有两种方式，选一个就行：

```bash
# 方式一（推荐）：写进 .env，跟 shell 无关，Windows / Linux 都一样
cd server
cp .env.example .env
$EDITOR .env          # 填 MINIMAX_SUBSCRIPTION_KEY=<YOUR_MINIMAX_KEY>

# 方式二：设环境变量
export MINIMAX_SUBSCRIPTION_KEY=<YOUR_MINIMAX_KEY>
# PowerShell 是 $env:MINIMAX_SUBSCRIPTION_KEY="<YOUR_MINIMAX_KEY>"
# CMD 是 set MINIMAX_SUBSCRIPTION_KEY=<YOUR_MINIMAX_KEY>
```

然后跑探测：

```bash
python probe_minimax.py        # 第一次务必跑，校准字段名
```

`.env` 已在 `.gitignore` 里不会被提交。

注意优先级是 **真实环境变量 > `.env`** —— systemd 里如果写了同名变量，
会以 systemd 的为准，`.env` 里那份再正确也读不到（这点坑过我一次）。
**二选一即可，推荐只用 `.env`。**

### 三个必须知道的点（前两个是实打实排过的大坑）

1. **区域必须匹配**。MiniMax 国际站（`platform.minimax.io` → `api.minimax.io`）和
   国内站（`platform.minimaxi.com` → `api.minimaxi.com`）是**两套独立系统，
   凭证不互通**。在哪个平台拿的 key 就必须打哪个域名，跨区必定报
   `2049 invalid api key` —— 哪怕你拿的确实是 Subscription Key。
2. **key 类型看前缀**：`sk-cp-` 开头是 Subscription Key，`sk-api-` 开头是
   pay-as-you-go 的 API Key（这个接口不认）。probe 会自动提示。
3. **它是双窗口制**：5 小时**滚动**窗口 + 周窗口，各自独立计算。面板上画成两条
   进度条。滚动窗口的意思是过去 5 小时内用掉的量逐步归还，不是整点重置。

### 真实响应结构（社区文档推测的字段名是错的）

实测（2026-09）返回和网上流传的结构差异很大：

```json
{
  "model_remains": [
    {
      "model_name": "general",
      "current_interval_total_count": 0,         // 恒为 0，别用
      "current_interval_usage_count": 0,         // 恒为 0，别用
      "current_interval_remaining_percent": 100, // ← 5小时窗口剩余百分比，用这个
      "end_time": 1790146800000,                 // ← 5小时窗口结束（毫秒时间戳）
      "current_weekly_remaining_percent": 99,    // ← 周窗口剩余百分比
      "weekly_end_time": 1790524800000
    },
    { "model_name": "video", "...": "..." }
  ],
  "base_resp": { "status_code": 0, "status_msg": "success" }
}
```

要点：**没有 `data` 层**；额度按模型拆在 `model_remains[]` 里；`total/usage_count`
恒为 0，**真正有效的是 `remaining_percent`**（面板上的已用百分比 = 100 − 剩余）。
默认显示 `general`，想看别的模型改 `token.model`。

`probe_minimax.py` 会自动做三件事：两个域名挨个试（**业务错误也换**，就是为跨区
这种 HTTP 200 但 key 无效的情况）、提示 key 前缀类型、打印完整响应。
换区域、换套餐之后重跑一次最稳。

---

## 阶段三 B：换成其他 API（通用模式）

`config.yaml` 的 `token` 段改成 `provider: generic`，给一个 HTTP 接口 +
取值路径，不用改代码：

```yaml
token:
  provider: generic
  enabled: true
  label: Token Plan
  url: https://api.example.com/v1/usage
  method: GET
  headers:
    Authorization: "Bearer ${TOKEN_API_KEY}"
  extract:
    used: data.used_tokens
    limit: data.limit_tokens
    reset_at: data.reset_at
  unit: tokens
```

- `${TOKEN_API_KEY}` 会从环境变量展开 —— **密钥别写进配置文件**
- 取值路径支持 `a.b[0].c` 这种嵌套和数组下标
- 接口只返回**剩余量**时，把 `extract_is_remaining: true` 打开

天气用 Open-Meteo，免费无需 key。国内访问慢的话把 `weather.url` 换成
wttr.in 或和风天气（要 key，解析代码在 `sources/weather.py` 里改）。

---

## 阶段四：Kindle 端

```bash
cd kindle
KINDLE_HOST=root@192.168.15.244 sh install.sh
```

USB 线直连时 USBNet 的地址通常是 `192.168.15.244`，走 WiFi 就填局域网 IP。

```bash
ssh root@192.168.15.244

# 先跑一次，验收画面
DASH_SERVER=http://192.168.1.10:8787 /mnt/us/dashboard/dashboard.sh once

# 没问题就常驻
DASH_SERVER=http://192.168.1.10:8787 /mnt/us/dashboard/dashboard.sh start
```

`DASH_INTERVAL` 控制刷新间隔（默认 600 秒），`DASH_FULL_EVERY` 控制
每几轮做一次整屏清白（默认 12，用来压残影）。

想让开机自动跑，把 `start` 挂到 Kindle 的 upstart job 里，或者在
`/etc/upstart/` 下加一个 conf（需要 root 且文件系统可写）。

---

## 面板上显示什么

- 左上：日期 + 星期
- 右上：**当前时间 HH:MM** + 电量
  （时间按 `location.timezone` 取，服务器时区是 UTC 也不会差 8 小时）
- 中部：天气（温度、描述、湿度/体感/风速）+ 未来 5 天预报
- 下部：MiniMax 双窗口进度条（5 小时滚动窗口 / 周窗口）

## 刷新间隔怎么定

`DASH_INTERVAL` 控制 Kindle 多久拉一次图（默认 600 秒）。

先澄清一点：**墨水屏刷新本身不慢**，全刷一次 1–2 秒。真正要考虑的是
**每次刷新都要唤醒 WiFi 连服务器**，这才是耗电大头。

| 场景 | `DASH_INTERVAL` | 时间误差 |
|---|---|---|
| 插着 USB 供电（桌面看板，推荐） | `300`（5 分钟） | 最多 5 分钟 |
| 靠电池 | `600`（默认） | 最多 10 分钟 |
| 靠电池且只关心日期天气 | `1800`（30 分钟） | 时间基本没意义 |

残影由 `DASH_FULL_EVERY`（默认 12 轮做一次整屏清白）控制，一般不用动。

```bash
DASH_INTERVAL=300 DASH_SERVER=http://服务器IP:8787 /mnt/us/dashboard/dashboard.sh start
```

## ★ 怎么退出看板（先看这节）

**结论：唯一可靠的办法是长按电源键强制重启。**

### 为什么只有这一条路

看板跑起来之后，**Kindle 上输入不了任何命令** —— 搜索框是 `lab126_gui`
提供的，而看板为了独占屏幕**恰好把它停掉了**。
（`;log` 命令的执行确实是系统级的，但**输入它需要搜索框**，所以实际用不了。）

那"网页遥控退出"呢？**它依赖网络，而看板的网络并不可靠**
（比如连的是手机热点，热点一关设备就离线）。

> **实测记录**：热点关着的时候，在网页上点「退出看板」，
> 再按电源键唤醒设备 —— **依然退不出来**。
> 因为设备唤醒后那个查退出状态的请求也失败了（日志里是
> `本机未连接网络（1.1.1.1 不可达）`）。
>
> 换句话说：**你越需要它工作的时候（断网、出问题），它越是用不了。**

### 所以就一个办法

| 操作 | 说明 |
|---|---|
| **长按电源键 10 秒以上，直到设备重启** | 不需要网络，永远可用 |

**几个必须知道的点**：

- **看板运行时，长按电源键不会弹出「重启 / 取消 / 熄屏」菜单。**
  因为设备大部分时间在深度休眠，此时长按的语义是「唤醒」而不是「弹 UI 菜单」。
  **但按得够久（10 秒以上）依然会强制重启** —— 这是唯一可靠的退出方式。
- 想要那个菜单？**得在看板没跑的时候长按**（比如刚重启完、还没启动看板时）。
- `stopdash.sh` / `;log stopdash` **不是退出手段** ——
  它是在**看板已经停了之后**，用来清理残留、把原生界面还回来的。
- （网页遥控功能代码还留着，网络正常时理论上可用，但**别把它当作退出方案**。）

---

## 已知坑

| 现象 | 原因 / 处理 |
|---|---|
| 画面被 Kindle 主页或屏保盖掉 | `hold_screen` 停的是 **`lab126_gui` + `webreader`**（**不碰 `framework`** —— 停了电源键会失灵）。如果你的固件上这两个服务名不同，SSH 后手动 `initctl stop <名字>` 试，把管用的那行留下 |
| 拉取失败，屏幕一直空白 | 服务端 IP 不通，或 Kindle 连不上 WiFi。看 `/mnt/us/dashboard/dashboard.log` |
| 有残影、越用越脏 | 把 `DASH_FULL_EVERY` 调小，比如 4 |
| 电量掉得快 | RTC 唤醒没生效，退化成了 `sleep`（CPU 一直醒着）。日志里会写「没有可用的 wakealarm」 |
| 中文是方块 | 服务器没装 CJK 字体，见阶段二 |
| 越狱后联网就没了 | 忘了执行 Rename OTA Binaries |

电量显示的原理：脚本每次拉图时读 `lipc-get-prop com.lab126.powerd battLevel`
塞进 URL，服务端画进图片右上角。所以**电量是上一帧的值**，差一个刷新周期，
无所谓。

---

## 兼顾笔记阅读

看板和阅读不用二选一：

- **想看书**：先按上面「怎么退出看板」那节的办法退出（**长按电源键 10 秒重启**），
  然后正常用 KOReader
- **想回看板**：回到原生界面后，搜索框输入 `;log runme`

KOReader 装在 Kindle 上后可以直接读 `.md`，把 Obsidian 库拷进 `documents`
就能在墨水屏上看笔记。注意 `[[双链]]` 不会变成可点击链接，Dataview、插件
全部失效 —— 它适合读整理好的长文，不适合当第二大脑用。
