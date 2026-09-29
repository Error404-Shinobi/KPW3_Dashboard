# nginx 反代配置

> **为什么需要这一层**：Flask 直接监听公网端口的话，
> 服务、错误页、调试信息全都暴露在外。用 nginx 挡在前面，
> 既能统一入口，又能只让 Flask 在本机监听（`127.0.0.1`），外网碰不到。

---

## ★ 端口分工（搞错这里必踩坑）

| 角色 | 监听 | 说明 |
|---|---|---|
| **nginx** | `0.0.0.0:8787` | 对公网。Kindle 和浏览器访问的就是它 |
| **Flask** | `127.0.0.1:8789` | 只在本机。外网直连不到，只能经 nginx |

数据流：

```
Kindle / 浏览器
      │  http://YOUR_SERVER_IP:8787/dashboard.png
      ▼
   nginx  (0.0.0.0:8787)
      │  proxy_pass http://127.0.0.1:8789
      ▼
   Flask  (127.0.0.1:8789)  ──► 渲染 PNG
```

**两边端口必须错开。** 如果 Flask 也去监听 8787：

- Flask 启动时会报 `Address already in use` 然后退出
- 而 `ss -lntp | grep 8787` 显示的占用者是 **nginx**（它本来就该占着这里）
- 于是 `pkill -f main.py` **杀不掉**这个占用者，你会以为"清不干净"
- 真正的解法是**改 Flask 的端口**，不是杀 nginx

对应配置项：`server/config.yaml` 里的 `server.port` 应该是 **8789**。

---

## nginx 配置

`/etc/nginx/conf.d/kindle-dashboard.conf`：

```nginx
server {
    listen 8787;
    server_name _;

    # 图片可能几十 KB，放开一点
    client_max_body_size 8m;

    location / {
        proxy_pass http://127.0.0.1:8789;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;

        # 渲染可能耗时几秒，别让 nginx 提前断开
        proxy_read_timeout 60s;
        proxy_connect_timeout 10s;
    }
}
```

启用：

```bash
nginx -t                          # 先测语法，报错就别 reload
systemctl reload nginx
```

---

## CentOS 7 特有：SELinux 会拦住 nginx 外连

CentOS 7 默认开着 SELinux，它**默认禁止 nginx 主动发起网络连接**，
表现是 nginx 能启动、也能收请求，但一律返回 502，
而 `nginx -t` 和 `systemctl status nginx` 都是正常的。

```bash
# 允许 nginx 连后端（这是 CentOS 上 502 的高频原因）
setsebool -P httpd_can_network_connect 1

# 确认已生效
getsebool httpd_can_network_connect
```

排查时也可以临时看审计日志，会直接写"拒绝了 nginx 的连接"：

```bash
ausearch -m avc -ts recent 2>/dev/null | tail -20
```

---

## 验证顺序（照着走，别跳步）

**排查"打不开"永远从最内层往外测**，一层层确认，才能定位是哪一段断了：

```bash
# ① Flask 活着吗？（内网直接问它）
curl -s -o /dev/null -w "Flask  %{http_code}\n" http://127.0.0.1:8789/health

# ② nginx 能转发吗？（本机经 nginx）
curl -s -o /dev/null -w "nginx  %{http_code}\n" http://127.0.0.1:8787/health

# ③ 外网能到吗？（顺便验证安全组）
curl -s -o /dev/null -w "外网   %{http_code}\n" http://你的服务器IP:8787/health
```

三条都 200 才算通。任何一条失败，问题就在那一层：

| 现象 | 问题所在 |
|---|---|
| ① 失败（000/502） | Flask 没起 → 看 `journalctl -u kindle-dashboard` |
| ① 好、② 失败 | nginx 配置或 SELinux |
| ①② 好、③ 失败 | 云厂商安全组没放行 8787 |

**注意 `HTTP 000` 和 `HTTP 502` 的区别**：

- `502` = nginx 活着，但后端连不上（Flask 没起 / SELinux 拦住）
- `000` = 连接根本没建立（端口没人监听，或者**你连的端口号写错了**）

---

## 不要改的点

- **Kindle 端用 8787**（对公网的那个），不是 8789。
  8789 只绑在 `127.0.0.1`，设备根本访问不到
- `server/config.yaml` 里 `host` 填 `127.0.0.1` 而不是 `0.0.0.0`，
  否则 Flask 又会直接暴露在公网，nginx 这层就白加了
- 如果没装 nginx 也要用，那把 `host` 改回 `0.0.0.0`、`port` 改回 `8787`，
  二选一，**两个都监听 8787 是最容易犯的错**
