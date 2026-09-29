# KPW3 E-Ink Dashboard

[中文](README.md) | **English**

Turn an idle Kindle Paperwhite 3 into an always-on information panel:
date/time, weather, and **MiniMax Token Plan quota** — and it can still
double as a KOReader device for reading notes.

> Every pitfall we hit is documented in [`docs/pitfalls.md`](docs/pitfalls.md)
> (in Chinese) — cross-region API auth, ancient CentOS 7 environment,
> silent CA-certificate failures, systemd env priority, and more.
> **Worth a skim before you start.**

```
┌─────────────────┐   HTTP GET     ┌──────────────┐
│ Linux server    │ ─────────────▶ │ KPW3 (jailbr.)│
│ Python + Pillow │  dashboard.png │ eips to screen│
│ weather + quota │ ◀── ?batt=85   │ RTC sleep/wake│
└─────────────────┘                └──────────────┘
```

Rendering happens on the server. The Kindle only does three things:
fetch an image → push it with `eips` → deep sleep. During sleep the CPU is
off but the E-Ink image persists, which is why a single charge lasts weeks.

**Screen specs (get these right)**: the KPW3 is **1448 × 1072**, 300 ppi,
16 grayscale levels. Many tutorials online say `758×1024` — that's the
Paperwhite 1st/2nd gen. Copying it will misalign everything.

**★ Note that "canvas size" and "framebuffer size" are not the same thing.**
Measured with `eips -i`:

```
xres: 1072    yres: 1448    bits_per_pixel: 8    grayscale: 1
```

The framebuffer itself is a **1072×1448 portrait** layout, while `eips -g`
pastes an image as-is — **no rotation, no color-depth conversion** (the
official wiki lists only `-g -b -w -f -x -y -v`).

So the server must do two transforms before sending, which is what
`display.rotate: true` in the config is for:

```python
img.transpose(2)      # 1448×1072 → 1072×1448 (counter-clockwise; 2 == ROTATE_90)
img.convert("L")      # 8-bit grayscale, matching the framebuffer
```

> We use `transpose(2)` instead of `Image.Transpose.ROTATE_90` because the
> latter needs Pillow ≥ 9.1 while our lower bound is 8.0 — it would crash
> the service on startup.

Skip this and you get a cropped right edge and misaligned content
(it looks like a "portrait version"), **plus the `framework` process gets
woken up and throws a soft keyboard over your image**. To preview the
landscape layout in a browser, temporarily set `rotate` to `false`.

**★ Port layout (must not overlap)**:

| Role | Listens on | Notes |
|---|---|---|
| nginx | `0.0.0.0:8787` | Public. This is what the Kindle talks to. |
| Flask | `127.0.0.1:8789` | Localhost only, reverse-proxied by nginx. |

The two **must use different ports**. If Flask also binds 8787 it fights
nginx for the port, you get `Address already in use`, and `pkill main.py`
won't help — **nginx is the one holding it**. See [`docs/nginx.md`](docs/nginx.md).

---

## Layout

| Path | Purpose |
|---|---|
| `server/` | The rendering service that runs on Linux |
| `server/config.yaml.example` | Config template — copy to `config.yaml` and edit |
| `kindle/dashboard.sh` | The refresh daemon that runs on the Kindle |
| `kindle/config.env.example` | **Device-side config template** — copy to `config.env` |
| `kindle/runme.sh` | No-SSH entry point, triggered from the search box via `;log runme` |
| `kindle/stopdash.sh` | Cleanup helper for after the dashboard has stopped (see below) |
| `docs/PROJECT-LOG.md` | **Full engineering log** (architecture decisions, pitfalls) |
| `docs/pitfalls.md` | **Pitfall log** — read this first |
| `docs/nginx.md` | nginx reverse-proxy config + port layout |
| `deploy.sh` / `deploy.ps1` | Optional upload helpers (rsync / scp) |

---

## Stage 1: Jailbreaking the KPW3

> 📋 **Step-by-step checklist: [`docs/jailbreak.md`](docs/jailbreak.md)**
> (Chinese) — five stages, each with a verification point, plus a
> "what to check if it's stuck" table.

> This carries risk. Back up the whole `documents` folder to your computer
> first. For recovering a soft-bricked device (serial + u-boot), see the
> `docs/04` folder in the `zzwcoding/weread-kpw3` repo.

### Prerequisites

1. **Firmware ≤ 5.16.2.1.1.** Check via Menu → Settings → Menu → Device Info.
   That's the final official KPW3 release (no longer updated), so most
   devices already satisfy this.
2. **Enable airplane mode.** The whole process runs offline.
3. **Remove the device password** (if set, `111222777` in the password box
   resets it, but wipes data).
4. Connect to a computer and **delete every `.bin` file and
   `update.bin.tmp.partial`** from the root directory.
5. Back up `documents` — LanguageBreak wipes content.

### Jailbreak with LanguageBreak

On the KPW3, **prefer LanguageBreak**; avoid WinterBreak (reported to error
out on reboot).

Main flow:

1. Reset the device: Settings → Device Options → Reset
2. Type `;enter_demo` in the search box → **manually reboot** (it will *not*
   reboot by itself, don't wait for it)
3. After reboot: skip WiFi → enter anything for registration → Skip →
   Standard → Done (there's a blank screen for a while — wait it out until
   it starts cycling through demo images)
4. **Secret gesture** to reach the library: tap the bottom-right corner with
   two fingers, then immediately swipe left with one finger. Retry a few
   times, 1–2 s apart, if it doesn't take.
5. `;demo` in the search box → tap "Sideload Content" → connect to computer
6. Copy LanguageBreak over → follow the on-screen instructions
7. Install the **hotfix**: use the **KindleModding generic hotfix (2.5.0)**,
   **not** the one bundled with LanguageBreak — the wrong one blocks later
   plugin installs
8. `;uzb` to connect to a computer, then exit demo mode back to the normal system
9. Install **MRPI** (choose FOR MODERN DEVICES, not PRE-K5) and **KUAL**
10. Install **USBNet** if you want SSH

> Exact filenames and commands: see the official sources —
> MobileRead's [LanguageBreak thread](https://www.mobileread.com/forums/showthread.php?t=356872)
> and `github.com/zzwcoding/weread-kpw3`'s `docs/02-越狱与部署.md` (Chinese, very thorough).

### Do this immediately after jailbreaking: block OTA updates

**A successful jailbreak ≠ OTA blocked.** Before going online, run
**Rename OTA Binaries** in KUAL (under the Helper menu). Otherwise Amazon
pushes an official firmware and your jailbreak is gone.

---

## Stage 2: The server (Linux)

> **Python 3.7+ required** (the code uses dataclasses). The 3.6 that ships
> with CentOS 7 won't do — see "installing a newer Python" below.

```bash
cd server
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt

# A CJK font is mandatory, otherwise you get tofu boxes
apt install fonts-noto-cjk          # Debian/Ubuntu
# yum install google-noto-sans-cjk-fonts    # CentOS
# Verify: .venv/bin/python fontutil.py should list a font path

cp config.yaml.example config.yaml
$EDITOR config.yaml
```

First get the layout and pipeline working with fake data:

```bash
DASH_FAKE_DATA=1 python main.py
```

Then open `http://YOUR_SERVER_IP:8787/` in a browser — that's a scaled
preview page. **Tweak the layout here, not by refreshing the E-Ink screen
over and over** — it's dozens of times faster.

Once it looks right, wire up real data sources (next section) and run it
under systemd:

```ini
# /etc/systemd/system/kindle-dashboard.service
[Unit]
Description=KPW3 dashboard
After=network.target

[Service]
WorkingDirectory=/opt/kindle-dashboard/server
# Secrets belong in server/.env — don't duplicate them here, this overrides .env.
# If you do set one here, the right-hand side must be a real ASCII value:
# leaving a placeholder causes HTTP header encoding failures (latin-1 codec).
# Optional: when set, requests must carry ?token=xxx (recommended with a public IP)
Environment=DASH_ACCESS_TOKEN=
ExecStart=/opt/kindle-dashboard/server/.venv/bin/python main.py
Restart=always

[Install]
WantedBy=multi-user.target
```

> `ExecStart` must point at the Python inside your virtualenv — not
> `/usr/bin/python3`, which is 3.6 on old systems and won't run this.

```bash
systemctl daemon-reload
systemctl enable --now kindle-dashboard
systemctl is-active kindle-dashboard      # should return active
```

If startup fails with `Address already in use`, a manually started process
is still holding the port:

```bash
pkill -f "main.py" && systemctl start kindle-dashboard
```

When the browser can't reach it, check in this order:
**cloud security group → OS firewall → the service itself.** On cloud VMs the
security group is the most commonly missed one (allow TCP 8787 in the
console — OS-level commands won't help).

```bash
systemctl enable --now kindle-dashboard
curl -s http://127.0.0.1:8787/debug.json | head   # data-source status
```

---

### Installing a newer Python on an old server (common with CentOS 7)

The system Python is often 3.6 with pip 9, which can't install modern
dependencies (`No matching distribution found for Flask>=3.0.0`). 3.6 is not
usable because the project relies on `from __future__ import annotations`
and `dataclasses`, both requiring 3.7+.

```bash
python3 --version          # check first

# 3.7+: just an outdated pip
.venv/bin/pip install --upgrade pip
.venv/bin/pip install -r requirements.txt

# 3.6 or older: install a newer Python
yum install -y epel-release
yum install -y python39 python39-pip     # try python38 if unavailable
rm -rf .venv                              # rebuild from scratch
python3.9 -m venv .venv
.venv/bin/pip install -r requirements.txt
```

If `python39` isn't in your mirror:
`yum install -y centos-release-scl && yum install -y rh-python38 && scl enable rh-python38 bash`

---

## Stage 3: Wiring up MiniMax Token Plan

MiniMax exposes an official quota-query endpoint. It's already configured in
`config.yaml`; you only need your key:

```yaml
token:
  provider: minimax
  enabled: true
  label: MiniMax Token Plan
  # China-region accounts use minimaxi.com, international use minimax.io
  # — cross-region always yields "invalid api key"
  url: https://api.minimaxi.com/v1/token_plan/remains
  # Quota is split per model; usually you care about `general`
  model: general
  api_key_env: MINIMAX_SUBSCRIPTION_KEY
```

Two ways to provide the key — pick one:

```bash
# Option 1 (recommended): put it in .env, shell-independent
cd server
cp .env.example .env
$EDITOR .env          # set MINIMAX_SUBSCRIPTION_KEY=your_key

# Option 2: environment variable
export MINIMAX_SUBSCRIPTION_KEY=your_key
# PowerShell: $env:MINIMAX_SUBSCRIPTION_KEY="your_key"
# CMD:        set MINIMAX_SUBSCRIPTION_KEY=your_key
```

Then run the probe:

```bash
python probe_minimax.py        # always run this first to calibrate field names
```

`.env` is in `.gitignore`.

Priority is **real environment variable > `.env`** — if systemd sets the same
variable it wins, and the (correct) value in `.env` is never read. This bit us
once. **Use only one of the two; `.env` is recommended.**

### Three things you must know (the first two cost us real time)

1. **Region must match.** MiniMax's international site
   (`platform.minimax.io` → `api.minimax.io`) and China site
   (`platform.minimaxi.com` → `api.minimaxi.com`) are **two independent
   systems with non-interoperable credentials**. Use the domain matching
   where you got the key. Cross-region always returns
   `2049 invalid api key` — even if it really is a Subscription Key.
2. **Key type is in the prefix**: `sk-cp-` is a Subscription Key;
   `sk-api-` is a pay-as-you-go API Key (not accepted here). The probe
   tells you which one you have.
3. **It's a dual-window scheme**: a rolling 5-hour window plus a weekly
   window, tracked independently. The dashboard draws two progress bars.
   "Rolling" means usage from the past 5 hours is gradually returned — it
   does *not* reset on the hour.

### Actual response shape (the field names floating around online are wrong)

Measured in 2026-09, the real response differs substantially from what's
circulating:

```json
{
  "model_remains": [
    {
      "model_name": "general",
      "current_interval_total_count": 0,         // always 0, ignore
      "current_interval_usage_count": 0,         // always 0, ignore
      "current_interval_remaining_percent": 100, // ← 5h window remaining %, use this
      "end_time": 1790146800000,                 // ← 5h window end (ms timestamp)
      "current_weekly_remaining_percent": 99,    // ← weekly window remaining %
      "weekly_end_time": 1790524800000
    },
    { "model_name": "video", "...": "..." }
  ],
  "base_resp": { "status_code": 0, "status_msg": "success" }
}
```

Key points: **there is no `data` wrapper**; quota is split per model inside
`model_remains[]`; `total/usage_count` are always 0 and **only
`remaining_percent` is meaningful**. The dashboard shows `general` by
default; change `token.model` for others.

`probe_minimax.py` does three things automatically: tries both domains
(**including on business errors**, to catch the cross-region case where HTTP
is 200 but the key is invalid), reports the key prefix type, and dumps the
full response. Re-run it whenever you change region or plan.

---

## Stage 3B: Using a different API (generic mode)

Set `token.provider: generic` in `config.yaml`, give it an HTTP endpoint and
extraction paths — no code changes needed:

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

- `${TOKEN_API_KEY}` is expanded from the environment — **never hardcode secrets**
- Paths support nesting and array indices like `a.b[0].c`
- If the endpoint returns only *remaining* amounts, set `extract_is_remaining: true`

Weather uses Open-Meteo (free, no key). If it's slow from your location,
switch `weather.url` to wttr.in or QWeather (needs a key; parsing code lives
in `sources/weather.py`).

---

## Stage 4: The Kindle side

```bash
cd kindle
KINDLE_HOST=root@192.168.15.244 sh install.sh
```

Over a direct USB connection USBNet usually gives `192.168.15.244`; over
WiFi use the LAN IP.

```bash
ssh root@192.168.15.244

# Run once first to verify the image
DASH_SERVER=http://192.168.1.10:8787 /mnt/us/dashboard/dashboard.sh once

# Then run as a daemon
DASH_SERVER=http://192.168.1.10:8787 /mnt/us/dashboard/dashboard.sh start
```

`DASH_INTERVAL` sets the refresh interval (default 600 s); `DASH_FULL_EVERY`
sets how often a full screen clear happens (default 12, to fight ghosting).

To start it on boot, hook `start` into a Kindle upstart job or drop a conf
under `/etc/upstart/` (needs root and a writable filesystem).

---

## ★ How to exit the dashboard (read this first)

**Bottom line: the only reliable way out is to force a reboot by holding
the power button.**

### Why it comes down to one method

Once the dashboard is running, **you cannot type any command on the Kindle** —
the search box is provided by `lab126_gui`, and the dashboard stops exactly
that service to take over the screen. (`;log` command *execution* is indeed
system-level, but **entering it requires the search box**.)

What about the "web remote exit"? **It depends on the network, and the
dashboard's network is not reliable** — e.g. it connects to a phone hotspot,
which drops whenever the phone leaves.

> **Measured**: with the hotspot off, clicking "Exit dashboard" in the
> browser and then pressing the power button to wake the device **still
> didn't exit**. The status request issued after waking failed as well
> (the device log said the local network was unreachable).
>
> Put another way: **the more you need it — offline, in trouble — the less
> it works.**

### So there is one method

| Action | Notes |
|---|---|
| **Hold the power button 10+ seconds until it reboots** | No network needed, always available |

**Things you need to know**:

- **While the dashboard is running, holding the power button will NOT show
  the "Restart / Cancel / Turn off screen" menu.** The device is in deep
  sleep most of the time, and in that state a long press means "wake up",
  not "show UI menu". **But holding it long enough (10+ s) still forces a
  reboot** — this is the one reliable way out.
- Want that menu? **Hold the button while the dashboard is not running**
  (e.g. right after a reboot, before starting the dashboard).
- `stopdash.sh` / `;log stopdash` is **not** an exit method — it's for
  **after** the dashboard has already stopped, to clean up leftovers and
  restore the native UI.
- (The web-remote code is still there and would work on a healthy network,
  but **don't rely on it as your exit strategy**.)

---

## What's on the panel

- Top-left: date + weekday
- Top-right: **current time HH:MM** + battery
  (time uses `location.timezone`, so a server in UTC won't be 8 hours off)
- Middle: weather (temp, description, humidity/feels-like/wind) + 5-day forecast
- Bottom: MiniMax dual-window progress bars (rolling 5-hour / weekly)

## Choosing the refresh interval

`DASH_INTERVAL` controls how often the Kindle fetches an image (default 600 s).

One clarification: **E-Ink refresh is not slow** — a full refresh takes 1–2 s.
What actually matters is that **every refresh has to wake WiFi and talk to
the server**, and that's the real power cost.

| Scenario | `DASH_INTERVAL` | Time error |
|---|---|---|
| USB-powered (desk dashboard, recommended) | `300` (5 min) | up to 5 min |
| Battery | `600` (default) | up to 10 min |
| Battery, date/weather only | `1800` (30 min) | time is basically meaningless |

Ghosting is handled by `DASH_FULL_EVERY` (a full clear every 12 rounds by
default) — usually you don't need to touch it.

```bash
DASH_INTERVAL=300 DASH_SERVER=http://YOUR_SERVER_IP:8787 /mnt/us/dashboard/dashboard.sh start
```

## Known issues

| Symptom | Cause / fix |
|---|---|
| Home screen or screensaver covers the image | `hold_screen` stops **`lab126_gui` + `webreader`** (**leaving `framework` alone** — stopping it kills the power button). If your firmware uses different service names, try `initctl stop <name>` manually via SSH and keep whichever works |
| Fetch fails, screen stays blank | Server IP unreachable, or the Kindle isn't on WiFi. Check `/mnt/us/dashboard/dashboard.log` |
| Ghosting gets worse over time | Lower `DASH_FULL_EVERY`, e.g. to 4 |
| Battery drains fast | RTC wake isn't working and it fell back to `sleep` (CPU stays awake). The log will say "no usable wakealarm" |
| Chinese renders as boxes | No CJK font on the server, see Stage 2 |
| Jailbreak disappears after going online | Forgot to run Rename OTA Binaries |

Battery display: the script reads `lipc-get-prop com.lab126.powerd battLevel`
on each fetch and passes it in the URL; the server draws it top-right. So
**the battery value is one frame behind** — one refresh cycle, no big deal.

---

## Coexisting with note-reading

Dashboard and reading don't have to be mutually exclusive:

- **To read**: exit the dashboard first using the method in "How to exit the
  dashboard" above (**hold the power button 10+ seconds to reboot**), then use
  KOReader normally
- **To return**: from the native UI, type `;log runme` in the search box

With KOReader installed you can read `.md` files directly — copy an Obsidian
vault into `documents` and read your notes on E-Ink. Note that `[[wikilinks]]`
won't become clickable links and Dataview/plugins won't work at all: it's
good for reading finished long-form notes, not as a second brain.
