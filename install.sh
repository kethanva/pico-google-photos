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
# Resolve actual end-user (not root) so config lands in their home, not /root.
TTY_USER="${SUDO_USER:-$USER}"
TTY_HOME=$(getent passwd "$TTY_USER" | cut -d: -f6)
[[ -n "$TTY_HOME" && -d "$TTY_HOME" ]] || TTY_HOME="${HOME}"
CONFIG_DIR="${TTY_HOME}/.config/pico-google-photos"
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

section "Resolving release version"
VERSION=$(curl -sI "https://github.com/${REPO}/releases/latest" | awk -F'/' '/[Ll]ocation:/{print $NF}' | tr -d '\r\n')
VERSION="${VERSION:-latest}"
info "Installing pico-google-photos version: ${VERSION}"

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
info "Service user: ${TTY_USER}  (home: ${TTY_HOME})"
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

# The kiosk unit no longer uses PAMName=login, so systemd-logind is NOT required.
# Cage uses seatd for seat management; XDG_RUNTIME_DIR comes from RuntimeDirectory=
# in the unit. On DietPi systemd-logind is masked by default — that is fine now,
# we simply skip it. No `loginctl enable-linger` is attempted.
sudo systemctl daemon-reload
sudo systemctl enable dbus          || true
sudo systemctl start  dbus          || true
sudo systemctl enable seatd.service || true
sudo systemctl start  seatd.service || true

# Free tty7 — getty races for the VT and blocks Cage from binding the seat.
sudo systemctl disable --now getty@tty7.service 2>/dev/null || true
sudo systemctl mask          getty@tty7.service 2>/dev/null || true

# Ensure boot reaches multi-user.target (DietPi headless default). Without
# this, on hosts where a previous DM left graphical.target as default but the
# DM is now removed, boot can stall before reaching our unit.
sudo systemctl set-default multi-user.target >/dev/null 2>&1 || true

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

info "Done. pico-google-photos version ${VERSION} installed successfully."
info "Logs: journalctl -u ${SERVICE_NAME} -f"
info "First boot: Chromium will prompt for Google login. Sign in once; profile persists."
