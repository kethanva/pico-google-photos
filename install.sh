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

# DietPi (and other minimal images) mask systemd-logind by default. We must
# unmask it because PAMName=login -> pam_systemd needs logind, otherwise it
# corrupts XDG_RUNTIME_DIR and cage fails with "Unable to open Wayland socket:
# Invalid argument".
#
# Always attempt unmask (no-op if already unmasked). Cover both persistent
# (/etc) and runtime (/run) mask locations because `systemctl unmask` only
# touches one path depending on systemd version + reporting state.
LOGIND_STATE=$(systemctl is-enabled systemd-logind 2>&1 || true)
info "systemd-logind state: ${LOGIND_STATE}"
sudo systemctl unmask systemd-logind 2>/dev/null || true

# Manual mask cleanup — symlinks to /dev/null that systemctl unmask sometimes misses.
for MASK_PATH in \
  /etc/systemd/system/systemd-logind.service \
  /run/systemd/system/systemd-logind.service
do
  if [[ -L "$MASK_PATH" ]]; then
    TARGET=$(readlink "$MASK_PATH")
    if [[ "$TARGET" == "/dev/null" ]]; then
      warn "Removing /dev/null mask symlink: $MASK_PATH"
      sudo rm -f "$MASK_PATH"
    fi
  fi
done

sudo systemctl daemon-reload

# Verify unmask worked. If still masked, we cannot proceed cleanly.
LOGIND_STATE_AFTER=$(systemctl is-enabled systemd-logind 2>&1 || true)
if echo "$LOGIND_STATE_AFTER" | grep -qi masked; then
  warn "systemd-logind still reports: ${LOGIND_STATE_AFTER}"
  warn "Continuing anyway. Cage may fail. Manual fix:"
  warn "  sudo rm -f /etc/systemd/system/systemd-logind.service"
  warn "  sudo rm -f /run/systemd/system/systemd-logind.service"
  warn "  sudo systemctl daemon-reload"
else
  info "systemd-logind unmasked: ${LOGIND_STATE_AFTER}"
fi

# Force-clean the dbus alias symlink that breaks logind with:
#   "Unit dbus-org.freedesktop.login1.service failed to load properly: File exists"
# This file is supposed to be a symlink to /lib/systemd/system/systemd-logind.service.
# On DietPi / minimal images it may exist as a regular file, wrong-target symlink,
# or be left over from a previously-masked logind. Remove unconditionally and let
# `systemctl reenable systemd-logind` recreate it from the unit's [Install] Alias=.
for ALIAS_LINK in \
  /etc/systemd/system/dbus-org.freedesktop.login1.service \
  /etc/systemd/system/multi-user.target.wants/dbus-org.freedesktop.login1.service
do
  if [[ -e "$ALIAS_LINK" || -L "$ALIAS_LINK" ]]; then
    warn "Removing stale logind alias: $ALIAS_LINK"
    sudo rm -f "$ALIAS_LINK"
  fi
done

sudo systemctl daemon-reload
sudo systemctl enable dbus              || true
sudo systemctl start  dbus              || true

# Reenable recreates the alias symlink properly from [Install] Alias= directive.
sudo systemctl reenable systemd-logind  || sudo systemctl enable systemd-logind || true
sudo systemctl restart  systemd-logind  || true

sudo systemctl enable seatd.service     || true
sudo systemctl start  seatd.service     || true

# loginctl needs logind on the bus — give it a moment, then try.
# Non-fatal: with RuntimeDirectory=cage in the unit, linger is defense-in-depth.
sleep 1
if ! sudo loginctl enable-linger "$TTY_USER" 2>/dev/null; then
  warn "enable-linger failed; daemon-reexec and retry"
  sudo systemctl daemon-reexec || true
  sleep 1
  sudo loginctl enable-linger "$TTY_USER" \
    || warn "enable-linger still failing (non-fatal — RuntimeDirectory=cage handles runtime dir)"
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
