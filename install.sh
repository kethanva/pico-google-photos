#!/usr/bin/env bash
# ============================================================
# pico-google-photos installer — Raspberry Pi (no X11, no DE)
# Downloads prebuilt binary from GitHub Releases.
# Uses Cage (Wayland kiosk) + Chromium, supervised by Rust.
# ============================================================
set -euo pipefail

REPO="kethanva/pico-google-photos"
BIN_NAME="pico-google-photos"
INSTALL_BIN="/usr/local/bin/${BIN_NAME}"
SERVICE_NAME="pico-google-photos.service"
CONFIG_DIR="${HOME}/.config/pico-google-photos"
CONFIG_FILE="${CONFIG_DIR}/config.toml"
ASSET_URL_BASE="https://github.com/${REPO}/releases/latest/download"

BOLD='\033[1m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'
CYAN='\033[0;36m'; RESET='\033[0m'
info()    { echo -e "${GREEN}[+]${RESET} $*"; }
warn()    { echo -e "${YELLOW}[!]${RESET} $*"; }
die()     { echo -e "${RED}[x]${RESET} $*" >&2; exit 1; }
section() { echo -e "\n${BOLD}${CYAN}== $* ==${RESET}"; }

[[ "$(uname -s)" == "Linux" ]] || die "Linux only."
command -v sudo    &>/dev/null || die "sudo required."
command -v apt-get &>/dev/null || die "apt-get required (Raspberry Pi OS / Debian)."
command -v curl    &>/dev/null || die "curl required."
command -v tar     &>/dev/null || die "tar required."

ARCH=$(uname -m)
case "$ARCH" in
  aarch64) ASSET="pico-google-photos-aarch64-linux-gnu.tar.gz" ;;
  armv7l)  ASSET="pico-google-photos-armv7-linux-gnueabihf.tar.gz" ;;
  armv6l)  ASSET="pico-google-photos-armv6-linux-gnueabihf.tar.gz" ;;
  *)       die "Unsupported arch: $ARCH" ;;
esac

ASSET_URL="${ASSET_URL_BASE}/${ASSET}"

section "Installing system dependencies"
sudo apt-get update -y

# Bookworm renamed `chromium-browser` to `chromium`. Try new name first,
# fall back to old name for Bullseye / Buster.
if apt-cache show chromium >/dev/null 2>&1; then
  CHROMIUM_PKG="chromium"
elif apt-cache show chromium-browser >/dev/null 2>&1; then
  CHROMIUM_PKG="chromium-browser"
else
  die "Neither 'chromium' nor 'chromium-browser' available in apt. Update sources."
fi
info "Chromium package: ${CHROMIUM_PKG}"

CODEC_PKG=""
if apt-cache show chromium-codecs-ffmpeg-extra >/dev/null 2>&1; then
  CODEC_PKG="chromium-codecs-ffmpeg-extra"
fi

sudo apt-get install -y --no-install-recommends \
  cage "${CHROMIUM_PKG}" ${CODEC_PKG} \
  seatd libseat1 libinput10 libdrm2 libgbm1 libegl1 libgles2 \
  fonts-noto-color-emoji ca-certificates curl \
  dbus dbus-user-session libpam-systemd

# Resolve installed chromium binary name for config seed.
if command -v chromium >/dev/null 2>&1; then
  CHROMIUM_BIN="chromium"
elif command -v chromium-browser >/dev/null 2>&1; then
  CHROMIUM_BIN="chromium-browser"
else
  die "Chromium installed but neither 'chromium' nor 'chromium-browser' on PATH."
fi
info "Chromium binary: ${CHROMIUM_BIN}"

section "Downloading latest release asset"
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT
TAR_PATH="${WORK_DIR}/${ASSET}"
info "URL: ${ASSET_URL}"
curl -fL --retry 3 --retry-delay 2 -o "$TAR_PATH" "$ASSET_URL" \
  || die "Download failed. Check release exists at https://github.com/${REPO}/releases"

# Verify checksum if .sha256 is available alongside.
SHA_URL="${ASSET_URL}.sha256"
if curl -fLs -o "${TAR_PATH}.sha256" "$SHA_URL"; then
  EXPECTED=$(awk '{print $1}' "${TAR_PATH}.sha256")
  ACTUAL=$(sha256sum "$TAR_PATH" | awk '{print $1}')
  [[ "$EXPECTED" == "$ACTUAL" ]] || die "Checksum mismatch (expected $EXPECTED, got $ACTUAL)"
  info "Checksum OK: ${ACTUAL:0:12}…"
else
  warn "No .sha256 published; skipping checksum verification."
fi

section "Extracting"
EXTRACT_DIR="${WORK_DIR}/extracted"
mkdir -p "$EXTRACT_DIR"
tar -C "$EXTRACT_DIR" -xzf "$TAR_PATH"
[[ -f "${EXTRACT_DIR}/${BIN_NAME}" ]] || die "Archive missing ${BIN_NAME}"
[[ -f "${EXTRACT_DIR}/${SERVICE_NAME}" ]] || die "Archive missing ${SERVICE_NAME}"

section "Installing binary"
sudo install -Dm755 "${EXTRACT_DIR}/${BIN_NAME}" "$INSTALL_BIN"

section "Installing systemd service"
TTY_USER="${SUDO_USER:-$USER}"
TMP_UNIT=$(mktemp)
# Service file in the release tarball is already correct (After=/Requires=
# dbus, RuntimeDirectory=cage, etc.). Only the user account differs per host.
sed -e "s/^User=pi$/User=${TTY_USER}/" \
    "${EXTRACT_DIR}/${SERVICE_NAME}" > "$TMP_UNIT"
sudo install -Dm644 "$TMP_UNIT" "/etc/systemd/system/${SERVICE_NAME}"
rm -f "$TMP_UNIT"

for g in video render input seat; do
  sudo getent group "$g" >/dev/null 2>&1 || sudo groupadd -r "$g"
  sudo usermod -aG "$g" "$TTY_USER" || true
done

# Clear stale logind symlink that breaks `loginctl enable-linger` with
# "Unit dbus-org.freedesktop.login1.service failed to load properly: File exists"
STALE_LINK="/etc/systemd/system/dbus-org.freedesktop.login1.service"
if [[ -L "$STALE_LINK" && ! -e "$STALE_LINK" ]]; then
  warn "Removing dangling logind symlink: $STALE_LINK"
  sudo rm -f "$STALE_LINK"
fi

sudo systemctl daemon-reload
sudo systemctl enable dbus              || true
sudo systemctl start  dbus              || true
sudo systemctl enable systemd-logind    || true
sudo systemctl restart systemd-logind   || true
sudo systemctl enable seatd.service     || true
sudo systemctl start  seatd.service     || true

# loginctl needs logind on the bus — retry once after restart.
if ! sudo loginctl enable-linger "$TTY_USER" 2>/dev/null; then
  warn "First enable-linger failed; reloading and retrying"
  sudo systemctl daemon-reexec || true
  sudo loginctl enable-linger "$TTY_USER" || warn "enable-linger still failing (non-fatal)"
fi

section "Seeding config"
if [[ ! -f "$CONFIG_FILE" ]]; then
  mkdir -p "$CONFIG_DIR"
  CONFIG_TEMPLATE="${EXTRACT_DIR}/config.example.toml"
  [[ -f "$CONFIG_TEMPLATE" ]] || die "Archive missing config.example.toml"
  sed -e "s|^chromium_binary.*|chromium_binary   = \"${CHROMIUM_BIN}\"|" \
      "$CONFIG_TEMPLATE" > "$CONFIG_FILE"
  info "Wrote ${CONFIG_FILE} (chromium_binary=${CHROMIUM_BIN})"
else
  warn "Config exists; leaving as-is: ${CONFIG_FILE}"
  warn "If Chromium fails to launch, set chromium_binary=\"${CHROMIUM_BIN}\" in ${CONFIG_FILE}"
fi

section "Configuring GPU memory split"
BOOT_CFG="/boot/firmware/config.txt"
[[ -f "$BOOT_CFG" ]] || BOOT_CFG="/boot/config.txt"
if [[ -f "$BOOT_CFG" ]] && ! grep -q '^gpu_mem=' "$BOOT_CFG"; then
  echo "gpu_mem=128" | sudo tee -a "$BOOT_CFG" >/dev/null
  warn "Set gpu_mem=128 in ${BOOT_CFG} (reboot required)."
fi

section "Enabling service"
sudo systemctl daemon-reload
sudo systemctl enable --now "$SERVICE_NAME"
sudo systemctl --no-pager status "$SERVICE_NAME" || true

info "Done. Logs: journalctl -u ${SERVICE_NAME} -f"
info "First boot: Chromium will prompt for Google login. Sign in once; profile persists."
