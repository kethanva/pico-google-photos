# pico-google-photos

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
![Rust](https://img.shields.io/badge/Rust-1.75+-orange)
![Platform](https://img.shields.io/badge/Platform-Raspberry%20Pi%20Zero%202%20W%20%2F%203%20%2F%204%20%2F%205-red)

Rust-supervised Chromium kiosk that loads the **Google Photos mobile UI** on a Raspberry Pi — **no desktop environment, no X11**.

Repo: <https://github.com/kethanva/pico-google-photos>

Inspired by [pico-gallery](https://github.com/kethanva/pico-gallery). Where pico-gallery renders JPEGs directly to KMS/DRM, this project takes the opposite path: it spawns a tiny Wayland kiosk compositor ([Cage](https://github.com/cage-kiosk/cage)) and runs Chromium inside it. The mobile Google Photos UA is forced so the lightweight phone PWA is served instead of the desktop bundle.

---

## Target

- **Hardware:** Raspberry Pi Zero 2 W / Pi 3 (or newer). Pi 4 / Pi 5 also fine.
- **OS:** Raspberry Pi OS Lite (Bookworm, 64-bit) — see [Recommended OS](#recommended-os) below.
- **Display:** HDMI / DSI, direct KMS.

---

## Recommended OS

**Use Raspberry Pi OS Lite (Bookworm, 64-bit).** It is the smallest officially-supported image that ships everything `pico-google-photos` needs, with no desktop, no display manager, and no X server.

Download: <https://www.raspberrypi.com/software/operating-systems/> → "Raspberry Pi OS Lite (64-bit)".

| Why it wins on a Pi Zero 2 W |
|------------------------------|
| Boots to a TTY in ~12 s, idles around 130 MB RAM — leaves ~370 MB free for Chromium. |
| 64-bit kernel — Zero 2 W's Cortex-A53 is 64-bit native; 32-bit ABI wastes cycles. |
| `cage`, `chromium-browser`, `seatd`, `libdrm`, `libgbm`, `libgles2` all in apt — no manual builds. |
| Ships `vcgencmd` for HDMI on/off scheduling. |
| KMS/DRM is the default video stack — no fakeKMS, no `Xorg`, no overlays to disable. |
| `gpu_mem` and `dtoverlay=vc4-kms-v3d` honoured by `/boot/firmware/config.txt`. |

### Why not the alternatives

| OS | Idle RAM | Verdict |
|----|---------|---------|
| **Raspberry Pi OS Lite 64-bit (Bookworm)** | ~130 MB | **Recommended.** Best Cage + Chromium support, smallest official image. |
| Raspberry Pi OS Lite 32-bit | ~120 MB | Works but loses 64-bit perf on Zero 2 W. Pick only if forced (Pi Zero W / Pi 1). |
| Raspberry Pi OS *with desktop* | ~400 MB | Wastes RAM on LXDE you never see. Don't. |
| DietPi (Bookworm) | ~60 MB | Lightest option — viable for power users. Install `cage` + `chromium` via `dietpi-software`. Less tested with this project. |
| Ubuntu Server 24.04 (arm64) | ~200 MB | Heavier base; Chromium ships as snap which doesn't work in Cage. Skip. |
| Alpine Linux (aarch64) | ~40 MB | Smallest, but Chromium support on aarch64 musl is patchy and `vcgencmd` is unavailable. Not recommended. |
| Buildroot custom | <30 MB | Theoretical minimum — high maintenance, you'd lose `apt`. Only for embedded shops. |

### First-flash checklist (Raspberry Pi OS Lite 64-bit)

1. Flash with **Raspberry Pi Imager**. In the customisation pane:
   - Set hostname (e.g. `photo-frame`).
   - Enable SSH with a key.
   - Set Wi-Fi SSID + password (Zero 2 W has no Ethernet).
   - Set locale and timezone.
2. Boot, SSH in, then:
   ```bash
   sudo apt-get update && sudo apt-get -y full-upgrade
   sudo apt-get install -y git
   git clone https://github.com/kethanva/pico-google-photos.git
   cd pico-google-photos
   ./install.sh
   sudo reboot
   ```
3. After reboot the kiosk auto-launches on `tty7`. SSH back in once to sign into Google.

---

## How it works

```
systemd (tty7)
  └─ pico-google-photos          (Rust supervisor)
       └─ cage -s --             (Wayland kiosk compositor)
            └─ chromium-browser  (--kiosk --ozone-platform=wayland + mobile UA)
                 └─ photos.google.com  (mobile PWA)
```

The supervisor:
- spawns `cage … -- chromium-browser …` as a single child,
- restarts the session on crash (3-second backoff),
- optionally reloads on a configurable interval,
- turns the display off/on at scheduled times via `vcgencmd display_power`.

---

## Install

On the Pi:

```bash
git clone https://github.com/kethanva/pico-google-photos.git
cd pico-google-photos
./install.sh
```

The installer:

| Step | Action |
|------|--------|
| 1 | Detects architecture (`aarch64` / `armv7l` / `armv6l`) |
| 2 | Detects RAM — switches to `release-fast` profile on <900 MB |
| 3 | Installs `cage`, `chromium-browser`, `seatd`, codecs, runtime libs |
| 4 | Installs Rust toolchain if missing |
| 5 | Builds the supervisor and installs to `/usr/local/bin/pico-google-photos` |
| 6 | Rewrites `pico-google-photos.service` for the invoking user + UID |
| 7 | Adds user to `video`, `render`, `input`, `seat` groups |
| 8 | Enables `seatd` and lingering for the user |
| 9 | Seeds `~/.config/pico-google-photos/config.toml` |
| 10 | Sets `gpu_mem=128` in `/boot/firmware/config.txt` (or `/boot/config.txt`) |
| 11 | Enables `pico-google-photos.service` to run on boot |

Environment overrides:

```bash
PICO_GP_PROFILE=release-fast ./install.sh   # force the fast-build profile
PICO_GP_PROFILE=release      ./install.sh   # force the size-optimised profile
```

---

## First boot

Chromium opens straight to `photos.google.com`, which redirects to the Google login screen. Sign in once — the session cookies and profile persist at `~/.local/share/pico-google-photos/profile`. On every subsequent boot the kiosk drops directly into your library.

---

## Config

`~/.config/pico-google-photos/config.toml`:

```toml
[browser]
url               = "https://photos.google.com/"
user_agent        = "Mozilla/5.0 (Linux; Android 13; Pixel 5) AppleWebKit/537.36 Chrome/120 Mobile Safari/537.36"
profile_dir       = "/home/pi/.local/share/pico-google-photos/profile"
chromium_binary   = "chromium"          # Bookworm; use "chromium-browser" on Bullseye
reload_every_secs = 0          # 0 = never; e.g. 3600 reloads hourly
extra_flags       = []         # appended to Chromium args

# Tuning toggles (defaults target Pi Zero 2 W / Pi 3)
app_mode        = true   # launch via --app=URL (chromeless window)
disable_gpu     = true   # --disable-gpu + --disable-software-rasterizer (safest on Pi Zero)
ephemeral_cache = true   # --disk-cache-dir=/dev/null (no SD-card writes)
low_ram         = true   # process limits + small JS heap

[display]
compositor = "cage"
cage_flags = ["-s"]

[schedule]
enabled  = false
on_time  = "07:00"
off_time = "23:00"
```

### Tuning toggles

| Toggle | `true` (default) | `false` |
|---|---|---|
| `app_mode` | `--app=URL` — chromeless window, no address bar | bare URL, kiosk fullscreen |
| `disable_gpu` | `--disable-gpu --disable-software-rasterizer` — software-rendered, safest on Pi Zero | GPU raster + ignore blocklist |
| `ephemeral_cache` | `--disk-cache-dir=/dev/null` — zero SD-card writes | on-disk cache (32 MB when `low_ram`) |
| `low_ram` | `--process-per-site`, renderer cap 2, JS heap 128 MB, `--disable-dev-shm-usage` | Chromium defaults |

### The default flag set

With every toggle on (factory default), the supervisor invokes Chromium with the canonical "headless Pi Zero kiosk" recipe:

```bash
chromium \
  --kiosk \
  --ozone-platform=wayland \
  --enable-features=UseOzonePlatform \
  --app=https://photos.google.com/ \
  --user-agent="Mozilla/5.0 (Linux; Android 13; Pixel 5) AppleWebKit/537.36 Chrome/120 Mobile Safari/537.36" \
  --disable-gpu \
  --disable-software-rasterizer \
  --disable-dev-shm-usage \
  --disk-cache-dir=/dev/null \
  --no-first-run \
  --noerrdialogs \
  --disable-session-crashed-bubble \
  --process-per-site
```

Inspect the exact argv any time:

```bash
pico-google-photos --print-args
```

### Pi 4 / Pi 5 tuning

Flip `disable_gpu = false` to enable GPU raster, hardware video decode, and smoother grid scrolling. Keep `low_ram = false` on Pi 4 (2 GB+) for full renderer parallelism.

```toml
[browser]
disable_gpu     = false
low_ram         = false
ephemeral_cache = false
```

### Pi Zero 2 W tuning

- Keep every toggle at its default (`true`).
- `gpu_mem=128` is set automatically by the installer.
- Boot from a fast SD card or USB SSD — Chromium cold-start is I/O-bound.

---

## Why the mobile UA?

The desktop Google Photos bundle is heavy: large React tree, eager prefetch, multiple worker threads. The phone PWA is purpose-built for low-power devices — smaller JS payload, lazy image decode, simpler scroll virtualisation. Spoofing **Pixel 5 / Chrome Mobile** forces Google to serve that bundle. The result on a Pi Zero 2 W is roughly a 2–3× drop in steady-state RAM and a noticeably smoother grid scroll.

---

## Commands

```bash
# Tail logs
journalctl -u pico-google-photos.service -f

# Restart
sudo systemctl restart pico-google-photos.service

# Inspect the exact Chromium argv the supervisor would launch
pico-google-photos --print-args

# Override config path
pico-google-photos --config /path/to/config.toml
```

---

## Development

```bash
# Clone
git clone https://github.com/kethanva/pico-google-photos.git
cd pico-google-photos

# Build (host target — macOS/Linux dev box)
cargo build

# Lint
cargo clippy --all-targets -- -W clippy::all

# Cross-compile for Raspberry Pi (aarch64)
rustup target add aarch64-unknown-linux-gnu
cargo build --release --target aarch64-unknown-linux-gnu
```

The supervisor compiles and runs `--print-args` on any platform; spawning Cage + Chromium only works on Linux with the right packages installed.

### Layout

```
pico-google-photos/
├── Cargo.toml
├── Cargo.lock              # committed for reproducible bin builds
├── LICENSE
├── README.md
├── config.example.toml
├── install.sh              # Raspberry Pi installer
├── pico-google-photos.service
└── src/
    ├── main.rs             # CLI, signal loop, schedule gating
    ├── config.rs           # TOML schema + defaults
    ├── chromium.rs         # kiosk arg builder (toggle-driven)
    ├── compositor.rs       # spawn Cage + Chromium as a single child
    ├── display_power.rs    # vcgencmd display_power on/off
    └── schedule.rs         # on/off-time window with cross-midnight wrap
```

---

## Troubleshooting

### `E: Package 'chromium-browser' has no installation candidate`

You are on **Raspberry Pi OS Bookworm**, which renamed the package to `chromium`. The installer in this repo handles that automatically — pull the latest `main` and rerun:

```bash
git pull
./install.sh
```

If you are running the supervisor against an older config that still says `chromium_binary = "chromium-browser"`, the supervisor will detect the mismatch and fall back to `chromium` at runtime (a `WARN` is logged). To silence the warning, edit `~/.config/pico-google-photos/config.toml`:

```toml
chromium_binary = "chromium"   # Bookworm
# chromium_binary = "chromium-browser"  # Bullseye / Buster
```

### Cage exits immediately with `seatd not running`

```bash
sudo systemctl enable --now seatd
sudo usermod -aG seat,video,render,input "$USER"
# log out, log back in, or reboot
```

### Black screen, but the service is running

Confirm the Pi booted to console (not desktop):

```bash
sudo systemctl get-default     # should print: multi-user.target
sudo systemctl set-default multi-user.target
sudo reboot
```

---

## Recent changes

| Date | Change |
|------|--------|
| 2026-05-21 | **Initial public release.** Pixel-5 mobile UA, `app_mode`/`disable_gpu`/`ephemeral_cache`/`low_ram` toggles, Cage+Chromium supervision, schedule + reload loop. |
| 2026-05-21 | Switched default UA from Pixel 7 to Pixel 5 (matches the canonical low-end kiosk recipe). |
| 2026-05-21 | Added `app_mode` (`--app=URL`), `disable_gpu` (software render), `ephemeral_cache` (`--disk-cache-dir=/dev/null`). |
| 2026-05-21 | Added MIT `LICENSE`. Committed `Cargo.lock` for reproducible binary builds. |

---

## Acknowledgements

- [pico-gallery](https://github.com/kethanva/pico-gallery) — display power schedule + installer patterns reused here.
- [Cage](https://github.com/cage-kiosk/cage) — the kiosk compositor that makes "no X11" viable.
- [Chromium](https://www.chromium.org/) — the browser engine doing all the actual work.

---

## License

MIT — see [LICENSE](LICENSE).
