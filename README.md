# pico-google-photos

Rust-supervised Chromium kiosk that loads the **Google Photos mobile UI** on a Raspberry Pi — **no desktop environment, no X11**.

Inspired by [pico-gallery](../pico-gallery). Where pico-gallery renders JPEGs directly to KMS/DRM, this project takes the opposite path: it spawns a tiny Wayland kiosk compositor ([Cage](https://github.com/cage-kiosk/cage)) and runs Chromium inside it. The mobile Google Photos UA is forced so the lightweight phone PWA is served instead of the desktop bundle.

## Target

- **Hardware:** Raspberry Pi Zero 2 W / Pi 3 (or newer). Pi 4 / Pi 5 also fine.
- **OS:** Raspberry Pi OS Bookworm (Lite is enough — no desktop needed).
- **Display:** HDMI / DSI, direct KMS.

## How it works

```
systemd (tty7)
  └─ pico-google-photos          (this binary — Rust supervisor)
       └─ cage -s --             (Wayland kiosk compositor)
            └─ chromium-browser  (--kiosk --ozone-platform=wayland + mobile UA)
                 └─ photos.google.com  (mobile PWA)
```

The supervisor:
- spawns `cage … -- chromium-browser …` as a single child,
- restarts the session on crash,
- optionally reloads on an interval,
- turns the display off/on at scheduled times via `vcgencmd display_power`.

## Install

On the Pi:

```bash
git clone https://github.com/kethanva/pico-google-photos.git
cd pico-google-photos
./install.sh
```

The installer:
1. installs `cage`, `chromium-browser`, `seatd`, codecs, and runtime libs,
2. builds the Rust supervisor (release-fast on low-RAM Pis),
3. drops a config at `~/.config/pico-google-photos/config.toml`,
4. enables `pico-google-photos.service` to start on boot.

## First boot

Chromium opens to `photos.google.com`, which redirects to the login screen. Sign in once — the profile persists at `~/.local/share/pico-google-photos/profile`. On every subsequent boot the kiosk drops straight into your library.

## Config

`~/.config/pico-google-photos/config.toml`:

```toml
[browser]
url               = "https://photos.google.com/"
user_agent        = "Mozilla/5.0 (Linux; Android 13; Pixel 5) AppleWebKit/537.36 Chrome/120 Mobile Safari/537.36"
profile_dir       = "/home/pi/.local/share/pico-google-photos/profile"
chromium_binary   = "chromium-browser"
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

| Toggle | True (default) | False |
|---|---|---|
| `app_mode` | `--app=URL`, no chrome UI | bare URL, kiosk fullscreen |
| `disable_gpu` | software render, no GL — safest on Pi Zero | GPU raster, ignore blocklist |
| `ephemeral_cache` | disk cache → `/dev/null`, no SD writes | disk cache on disk (32 MB if `low_ram`) |
| `low_ram` | `--process-per-site`, renderer cap 2, JS heap 128 MB | Chromium defaults |

The default set matches the canonical "headless Pi Zero kiosk" recipe:

```
chromium-browser --kiosk --ozone-platform=wayland --enable-features=UseOzonePlatform \
  --app=https://photos.google.com/ \
  --user-agent="Mozilla/5.0 (Linux; Android 13; Pixel 5) ... Mobile Safari/537.36" \
  --disable-gpu --disable-software-rasterizer --disable-dev-shm-usage \
  --disk-cache-dir=/dev/null \
  --no-first-run --noerrdialogs --disable-session-crashed-bubble --process-per-site
```

Flip `disable_gpu = false` on Pi 4 / Pi 5 to get hardware-accelerated scroll and decode.

### Pi Zero 2 W tuning

- Keep `low_ram = true` (cuts renderer count, caps the JS heap, shrinks caches).
- `gpu_mem=128` is set automatically by the installer.
- Boot from a fast SD card or USB SSD — Chromium cold-start is I/O bound.

## Why the mobile UA?

The desktop Google Photos bundle is heavy: large React tree, eager prefetch, multiple worker threads. The phone PWA is purpose-built for low-power devices — smaller JS payload, lazy image decode, simpler scroll virtualisation. Spoofing `Pixel 7 / Chrome Mobile` forces Google to serve that bundle. The result on a Pi Zero 2 W is roughly a 2–3× drop in steady-state RAM and a much smoother grid scroll.

## Commands

```bash
# Tail logs
journalctl -u pico-google-photos.service -f

# Restart
sudo systemctl restart pico-google-photos.service

# Inspect the exact Chromium argv the supervisor would use
pico-google-photos --print-args

# Override config path
pico-google-photos --config /path/to/config.toml
```

## Acknowledgements

- [pico-gallery](https://github.com/kethanva/pico-gallery) — display power schedule + installer patterns reused here.
- [Cage](https://github.com/cage-kiosk/cage) — the kiosk compositor that makes "no X11" viable.

## License

MIT.
