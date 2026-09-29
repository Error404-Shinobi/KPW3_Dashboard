# KPW3 越狱操作清单

对着这份做，每阶段末尾有**验证点**，过不了别往下走。

> ⚠️ 有风险。操作前把 `documents` 整个文件夹备份到电脑。
> 万一变软砖，救砖方法见 `zzwcoding/weread-kpw3` 仓库的 `docs/04`（串口 + u-boot）。

---

## 需要的文件（先全部下载好）

| 文件 | 下载地址 | 具体下哪个 |
|---|---|---|
| **LanguageBreak** | https://github.com/notmarek/LanguageBreak/releases | 最新 release 的 `LanguageBreak*.tar.gz` |
| **hotfix 2.5.0** | https://github.com/KindleModding/Hotfix/releases/tag/2.5.0 | `Update_hotfix_universal.bin` |
| **MRPI** | https://www.mobileread.com/forums/showthread.php?t=225030 | `kual-mrinstaller-1.7.N-r19303.tar.xz` |
| **KUAL** | 同上（NiLuJe snapshots 帖） | `KUAL-c6ac782-20250419.tar.xz`（coplate 版） |
| **USBNetwork** | 同上（NiLuJe snapshots 帖） | `kindle-usbnet-0.22.N-r19297.tar.xz` |

`t=225030` 是 NiLuJe 的官方 snapshots 汇总帖（"Snapshots of NiLuJe's hacks"），
里面包很多，按设备分类，**KPW3 属于「Packages targeting the Kindle 5」那一组**
（原文写的设备列表是 `Touch/PW1/PW2/KT2/KV/PW3/KOA/KT3/KOA2/PW4/KT4/KOA3/PW5`）。

### 两个特别容易下错的地方

1. **USBNetwork 别拿错分类**。帖子里有两个同名包：
   - `kindle-usbnet-0.22.N-*.tar.xz` ← **PW3 用这个**（Kindle 5 分类）
   - `kindle-usbnetwork-0.57.N-*.tar.xz` ← 那是 K2/DX/3/4 老机型的，装了没用

2. **hotfix 用 KindleModding 的，不是 NiLuJe 的**。LanguageBreak / WinterBreak 这类
   新式越狱配 `Update_hotfix_universal.bin`；NiLuJe 帖里的
   `JailBreak-1.16.N-FW-5.x-hotfix.zip` 是配传统 jailbreak 的，别混用。

越狱相关的包在中文社区（书伴、MobileRead 中文帖）也有搬运，但**优先用官方源**。

> 解压 `.tar.xz` 用 7-Zip 或 WinRAR 都行，但**别用会自动转换 CR/LF 换行的工具**
> （比如 WinZip 的"智能"模式）—— 会破坏包里的 line ending，装上去各种奇怪问题。

---

## 阶段 1 · 准备

1. **确认固件版本**：菜单 → Settings → 菜单 → Device Info
   - 必须是 **≤ 5.16.2.1.1**。KPW3 官方最终版就是它
   - 低于它的话，先升到 5.16.2.1.1（成功率高）
2. **备份 `documents` 文件夹**到电脑（越狱会清空用户数据）
3. **开启飞行模式** —— 全程不连 WiFi
4. **关掉设备密码**。忘了密码就在密码框输 `111222777` 重置（会清数据）
5. USB 连电脑，**删掉根目录所有 `.bin`** 和 `update.bin.tmp.partial`
6. 设备重置：设置 → 设备选项 → 重置

**验证点**：Device Info 显示 5.16.2.1.1，根目录干净，无密码，飞行模式已开。

---

## 阶段 2-3 · 进演示模式并运行越狱

> 以下 14 步**照抄 LanguageBreak 官方 README**（权威版本）。
> 中间不要重启 —— 演示状态存在内存里，重启就回到正常模式，得从头来。

**进演示模式**

1. 搜索框输 `;enter_demo` 回车，然后**手动重启**设备
2. 设备启动后，关掉 WiFi 选择对话框，文本字段随意填，继续
3. 选 `Skip` → `Standard` → `Done`
4. 设备需要**几分钟**进入 demo 模式。完成后，用**手势**访问主屏
   （两指同时轻点右下角 + 一指从右向左横滑）

**运行越狱**

5. 搜索框输 `;demo` 回车，进入 Demo Mode Configuration 界面
6. 选 `Sideload Content`
7. 连接电脑，把 **`LanguageBreak` 文件夹里的内容**（不是文件夹本身）拷到
   **Kindle 根目录**，提示覆盖就覆盖
8. 弹出并**拔掉** Kindle，回到 Demo Configuration 界面
9. 选 `Resell Device`，确认
10. ⏱️ **一出现「Press the Power Button」画面，立刻插回电脑**（时间敏感，要快）
11. **再拷一次** `LanguageBreak` 文件夹里的内容到根目录（提示覆盖就覆盖）
12. 写完文件后弹出，**长按电源键直到设备重启**
13. 出现**语言选择界面**，选 `简体中文`（位置在 `Pseudot` 上方、Japanese 下方），
    然后点屏幕中间出现的中文文字按钮
14. 设备重启，右上角会出现一些日志消息

### ⚠️ 拷贝时必须显示隐藏文件

`LanguageBreak` 文件夹里有个 **`.demo`** 隐藏文件夹（点号开头），
Windows 资源管理器默认不显示。**先开启「显示隐藏的项目」再拷**，
漏掉它越狱会失败。

文件夹里应该长这样：

```
LanguageBreak/
├── documents/          ← 里面有个名字很怪的文件，别改它
├── DONT_CHECK_BATTERY
├── jb
├── patchedUks
└── .demo/              ← 隐藏文件夹，别漏
    └── boot.flag
```

**验证点**：步骤 14 之后，右上角能看到日志消息 = 越狱成功了。
（官方 FAQ 说：能装上 hotfix 就说明越狱成功。）

---

## 阶段 3.5 · 装 hotfix

1. 设备重启后，搜索框输 **`;uzb`**（启用演示模式下的 USB 访问）回车
2. 连接电脑，把**匹配你语言的**那个 `Update_hotfix_languagebreak-*.bin`
   拷到 Kindle **根目录**
   - 步骤 13 选了简体中文，所以用 **`zh-Hans`** 那个
3. 弹出，搜索框输 **`;dsts`** 进入设置页，
   找到 **`Update your Kindle`** 点它并确认

- 如果报 "Update Error"，重试最后三步即可
- 装完设备会重启，**退出 Demo 模式**

装完可能进入 **Managed mode**（部分设置变灰，提示联系管理员），属正常现象，见下。

---

## 阶段 3.6 · 恢复语言并退出 Managed mode

**如果 Kindle 未注册亚马逊账号**：

1. 搜索框输 `;demo`
2. 会弹出两个按钮的提示，按**最右边**那个
3. 设备重启

**如果 Kindle 已注册账号**：

1. 搜 `;enter_demo`，重启
2. 回到 Demo 模式，用同样手势访问主屏
3. 搜 `;demo` → 选 `Resell device` → 确认
4. 设备重启

**验证点**：Kindle 根目录出现一个名为 **`mkk`** 的文件夹 = 一切正常。

---

## 阶段 4 · 退出演示模式 + 装工具链

1. 搜索框输入 **`;uzb`** → 连接电脑 → 退出演示模式，正常开机
2. 装 **MRPI**（FOR MODERN DEVICES 版）：
   解压后把 `extensions` 和 `mrpackages` 两个文件夹拷到 Kindle 根目录
3. 装 **KUAL**：把 `Update_KUALBooklet_*_install.bin` 放进 `mrpackages/`，
   搜索框输入 **`;log mrpi`** 回车，等它自动安装并重启
4. 重启后书库里会出现一本 **KUAL**（是个文档图标，不是 App）

**验证点**：书库里能看到 KUAL，点开有菜单。安装成功时屏幕下方会闪过
"Hush, little baby" 字样；中途弹 "Application Error" 可以无视，是正常的。

### KUAL 压缩包里有三个 .bin，别拿错

```
Update_KUALBooklet_<hash>_install.bin          ← ✅ 正常用这个，放 mrpackages
Update_KUALBooklet_<hash>_uninstall.bin        ← ❌ 卸载包
Update_KUALBooklet_hotfix_<hash>_install.bin   ← 备用方案，见下
```

**`;log mrpi` 不管用时的备用方案**（官方文档明确写了这条路）：
把 `..._hotfix_..._install.bin` 放到 Kindle **根目录**，
然后 设置 → 更新您的 Kindle —— 它走的是亚马逊原生更新机制，不经过 MRPI。
社区里不少人最后是靠这条装上的。

### 版本选择

- 固件 **≥ 5.9** → 用 **KUAL Booklet (coplate)**（文件名带 commit hash，如 `c6ac782`）
- 固件 **< 5.9** → 用普通 KUAL Booklet（文件名带版本号，如 `v2.7.37`）

KPW3 的 5.16.2.1.1 属于前者。

---

## 阶段 5 · 通 SSH + 封锁 OTA 升级

### 装 USBNetwork（拿到 SSH）

1. 把**KPW3 对应**的 `Update_usbnet_*.bin` 放进 `mrpackages/`
2. KUAL → Helper → Install MR Packages
3. 搜索框输入 **`;un`** 回车 → 启动 SSH 服务

**连接参数**：

| 项 | 值 |
|---|---|
| Kindle IP | `192.168.15.244` |
| 电脑网卡 IP | `192.168.15.201` / 掩码 `255.255.255.0` |
| 用户名 / 密码 | `root` / 留空（不行试 `mario`） |

Windows 要在「网络连接」里找到 RNDIS/Ethernet Gadget 网卡手动设 IP。

想走 WiFi：SSH 进去后改 `/mnt/us/usbnet/etc/config` 里 `USE_WIFI=true`，
再到 KUAL 重启 SSH 服务。

### 封 OTA（联网前必做，否则白折腾）

**越狱成功 ≠ 阻止升级。** 一旦联网，亚马逊推个官方固件过来，
越狱就没了，而且可能回滚不了。

这一步需要**另外下载一个扩展**（不在前面那五个包里）：

> 下载 **renameotabin**（hius07 写的 KUAL 扩展）：
> https://kindlemodding.org/jailbreaking/Legacy/post-jailbreak/disable-ota.html
> 这个页面里有下载链接，中文说明见 https://kindlefere.com/post/472.html

**安装步骤**：

1. 解压 `renameotabin.zip` → 得到 `renameotabin` 文件夹
   - ⚠️ **注意嵌套**：解压出来可能是 `renameotabin/renameotabin/`，
     要拷**最里面**那层
2. 把 `renameotabin` 文件夹拷到 Kindle 的 **`extensions/`** 文件夹里
3. 顺手删掉 Kindle 根目录残留的 `.bin` 和 `update.bin.tmp.partial`
4. 安全弹出，在 KUAL 里点 **Rename OTA Binaries → Rename** → 自动重启

**原理**：把 `/usr/bin/otaupd` 和 `/usr/bin/otav3` 这两个升级程序改名，
让升级流程找不到它们。所以是从文件系统层面封死的，比 UI 里的开关可靠得多。

**恢复方法**（将来要升级或恢复出厂时）：
KUAL → Rename OTA Binaries → **Restore**，然后才能正常更新。

### ⚠️ 一个顺序陷阱

如果你**先封了 OTA，再去装 hotfix，hotfix 会装不上** ——
因为 Kindle 会忽略根目录的更新文件。

解决顺序：KUAL → Rename OTA Binaries → **Restore** → 装 hotfix →
再 → **Rename** 封回去。

所以稳妥的做法是**先装完所有东西，最后再封 OTA**。

**验证点**：SSH 能登进去；KUAL 里 Rename OTA Binaries 执行过；
往根目录丢个 `.bin` 文件，设置里的「更新您的 Kindle」应该是灰的。

---

## 卡住了怎么查

| 现象 | 原因 |
|---|---|
| `;enter_demo` 后没反应 | 正常，它不会自动重启，你手动重启就行 |
| 一直在循环播图 | 神秘手势没成功，重试；注意是「两指同点右下角」+「一指右→左滑」 |
| hotfix 装不上 | 用了 LanguageBreak 自带的版本，换成 KindleModding 通用 2.5.0 |
| KUAL 不出现 | MRPI 装错了版本（PRE-K5），或者没完整重启 |
| SSH 连不上 | Kindle 常禁 ping 但 22 端口开着 —— **别用 ping 判断**，直接连 |
| ssh 要密码 | 默认空密码，兜底试 `mario` |
| 联网后越狱失效 | 忘了执行 Rename OTA Binaries |

## 参考

- LanguageBreak 原帖（含完整 24 步）：
  https://www.mobileread.com/forums/showthread.php?t=356872
- 中文全流程记录（含固件分析、串口救砖、踩坑汇总）：
  https://github.com/zzwcoding/weread-kpw3
- USBNetwork 连接细节：MobileRead Wiki 的 USBNetwork 页
