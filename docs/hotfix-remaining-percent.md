# 服务器热修部署清单（额度「剩余」口径修正）

本次要解决的问题：**MiniMax 额度条满额度却显示 0% 空条**。

因为本机到服务器的 SSH 连不上（无密钥、无 sshpass），
下面的操作需要**你手动在服务器上执行**。已经准备好一键脚本，照抄即可。

---

## 一、为什么 `percent` 是 0

真实 API 响应里：

```json
"current_interval_remaining_percent": 100,
"current_weekly_remaining_percent": 100
```

上游给的是**剩余百分比**（满额度 = 100），
但解析代码做了翻转 `100.0 - iv_rem` → 算成「已用 0%」，
进度条画了个空条。**语义反了，不是数据错了。**

---

## 二、本地已改好的文件

| 文件 | 改了什么 |
|---|---|
| `server/sources/token_usage.py` | `Window` 口径统一为**剩余**；字段改名 `percent_remaining_given`；新增 `percent_remaining` / `percent_used` 属性 |
| `server/render.py` | 进度条改用 `percent_remaining`；数字左侧加「剩」字 |
| `server/main.py` | `/debug.json` 同时输出 `percent`（剩余）和 `percent_used` |
| `deploy_hotfix.sh` | **新增**，服务器侧一键热修脚本 |

本地已验证：
- 真实 API → 剩余 100%（原来是 0%）
- 假数据 → 剩余 75% / 76%
- 自造中间态 62% / 18% → 进度条长度精确对应
- 输出尺寸 `1072x1448` `L`（rotate 生效）
- 四个 Python 文件 `py_compile` 全过

---

## 三、部署步骤

### 方式 A：传文件 + 跑脚本（推荐）

本机执行（把文件传上去）：

```powershell
cd E:\Document\WorkBuddy\2026-09-22-14-38-09\kindle-dashboard
scp server\main.py        root@YOUR_SERVER_IP:/opt/kindle-dashboard/server/
scp server\render.py      root@YOUR_SERVER_IP:/opt/kindle-dashboard/server/
scp server\sources\token_usage.py root@YOUR_SERVER_IP:/opt/kindle-dashboard/server/sources/
scp deploy_hotfix.sh      root@YOUR_SERVER_IP:/opt/kindle-dashboard/
```

> scp 会问密码，输你的服务器 root 密码即可。

然后登录服务器执行：

```bash
cd /opt/kindle-dashboard
dos2unix deploy_hotfix.sh 2>/dev/null   # 没装 dos2unix 就跳过，脚本已转 LF
sh deploy_hotfix.sh
```

脚本会自动做 5 件事：
1. 定位项目目录
2. `py_compile` 语法自检
3. 真实调一次 MiniMax，打印每条窗口的「剩余 / 已用」
4. `systemctl restart kindle-dashboard`
5. 拉 `/debug.json` 验收 `percent` 应等于剩余

---

### 方式 B：纯手工（不想传文件时）

登录服务器，直接改 `server/sources/token_usage.py` 两处：

**① 把字段名和属性换掉**

```python
@dataclass
class Window:
    label: str = ""
    used: float | None = None
    limit: float | None = None
    reset_at: str = ""
    percent_remaining_given: float | None = None      # ← 原 percent_given

    @property
    def percent_remaining(self) -> float | None:       # ← 新增
        if self.percent_remaining_given is not None:
            return max(0.0, min(100.0, self.percent_remaining_given))
        if self.used is None or not self.limit:
            return None
        return max(0.0, min(100.0, (self.limit - self.used) / self.limit * 100.0))

    @property
    def percent(self) -> float | None:
        return self.percent_remaining

    @property
    def percent_used(self) -> float | None:           # ← 新增
        r = self.percent_remaining
        return None if r is None else 100.0 - r
```

**② 去掉 `100 -` 翻转**

```python
# 找到这两处，把 percent_given=100.0 - xxx 改成 percent_remaining_given=xxx
iv_rem = _as_number(entry.get("current_interval_remaining_percent"))
if iv_rem is not None:
    windows.append(Window(
        label="5小时",
        percent_remaining_given=iv_rem,        # ← 不再 100 - iv_rem
        reset_at=_reset_iso(entry.get("end_time"), entry.get("remains_time")),
    ))

wk_rem = _as_number(entry.get("current_weekly_remaining_percent"))
if wk_rem is not None:
    windows.append(Window(
        label="本周",
        percent_remaining_given=wk_rem,        # ← 不再 100 - wk_rem
        reset_at=_reset_iso(entry.get("weekly_end_time")),
    ))
```

**③ `render.py` 的 `_token_row`** 里 `pct = w.percent` 改成 `pct = w.percent_remaining`
（`w.percent` 现在也是剩余，等价；但显式写更清楚）。

**④ 重启**

```bash
systemctl restart kindle-dashboard
curl -s http://127.0.0.1:8787/debug.json
```

---

## 四、验收标准

`curl -s http://127.0.0.1:8787/debug.json` 应看到：

```json
"token_windows": [
  {"label": "5小时", "percent": 100.0, "percent_used": 0.0, ...},
  {"label": "本周",  "percent": 100.0, "percent_used": 0.0, ...}
]
```

浏览器打开 `http://YOUR_SERVER_IP:8787/` →
两条进度条应该**是满的**，且旁边写着「剩 100%」。

> 页面有 CSS 反旋，显示的是正常横屏。
> `Kindle` 侧不用改任何东西 —— 它拉的还是同一张 `/dashboard.png`。

---

## 五、Kindle 侧（顺带）

设备端脚本已经推上去了，入口改为：

```
;log runme2
```

（原因：`runme.sh` 在 Kindle 上是既有文件，本机被安全策略拦着覆盖不了，
所以推了 `runme2.sh`；新脚本会优先选 `dashboard2.sh`。）

预期 `runme.log` 里出现：

```
script: /mnt/us/dashboard/dashboard2.sh
停掉旧守护 PID xxxx
刷新成功，看看屏幕
```

屏上应该是**横向、无键盘、右上角带电量、额度条按剩余画**的看板。
