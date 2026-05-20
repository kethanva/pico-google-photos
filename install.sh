#!/usr/bin/env bash
# ============================================================
# pico-google-photos installer — Raspberry Pi (no X11, no DE)
# Uses Cage (Wayland kiosk) + Chromium, supervised by Rust.
# ============================================================
set -euo pipefail

REPO="kethanva/pico-google-photos"
BIN_NAME="pico-google-photos"
INSTALL_BIN="/usr/local/bin/${BIN_NAME}"
SERVICE_NAME="pico-google-photos.service"
CONFIG_DIR="${HOME}/.config/pico-google-photos"
CONFIG_FILE="${CONFIG_DIR}/config.toml"

BOLD='\033[1m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'
CYAN='\033[0;36m'; RESET='\033[0m'
info()    { echo -e "${GREEN}[+]${RESET} $*"; }
warn()    { echo -e "${YELLOW}[!]${RESET} $*"; }
die()     { echo -e "${RED}[x]${RESET} $*" >&2; exit 1; }
section() { echo -e "\n${BOLD}${CYAN}== $* ==${RESET}"; }

[[ "$(uname -s)" == "Linux" ]] || die "Linux only."
command -v sudo  &>/dev/null || die "sudo required."
command -v apt-get &>/dev/null || die "apt-get required (Raspberry Pi OS / Debian)."

ARCH=$(uname -m)
case "$ARCH" in
  aarch64) RUST_TARGET="aarch64-unknown-linux-gnu" ;;
  armv7l)  RUST_TARGET="armv7-unknown-linux-gnueabihf" ;;
  armv6l)  RUST_TARGET="arm-unknown-linux-gnueabihf" ;;
  *)       die "Unsupported arch: $ARCH" ;;
esac

MEM_KB=$(awk '/MemTotal/ {print $2; exit}' /proc/meminfo 2>/dev/null || echo 0)
MEM_MB=$(( MEM_KB / 1024 ))
PROFILE="${PICO_GP_PROFILE:-release}"
if [[ "$MEM_MB" -lt 900 ]] && [[ "$PROFILE" == "release" ]]; then
  warn "Low RAM (${MEM_MB} MB) — switching to release-fast profile."
  PROFILE="release-fast"
fi

section "Installing system dependencies"
sudo apt-get update -y
sudo apt-get install -y --no-install-recommends \
  cage chromium-browser chromium-codecs-ffmpeg-extra \
  seatd libseat1 libinput10 libdrm2 libgbm1 libegl1 libgles2 \
  fonts-noto-color-emoji ca-certificates curl

if ! command -v cargo &>/dev/null; then
  section "Installing Rust toolchain"
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
    | sh -s -- -y --default-toolchain stable --profile minimal
  # shellcheck disable=SC1091
  source "$HOME/.cargo/env"
fi

section "Building ${BIN_NAME} (profile: ${PROFILE})"
cargo build --profile "$PROFILE" --target "$RUST_TARGET"
BUILT_BIN="target/${RUST_TARGET}/${PROFILE}/${BIN_NAME}"
[[ -f "$BUILT_BIN" ]] || die "Build did not produce ${BUILT_BIN}"

section "Installing binary"
sudo install -Dm755 "$BUILT_BIN" "$INSTALL_BIN"

section "Installing systemd service"
TTY_USER="${SUDO_USER:-$USER}"
TMP_UNIT=$(mktemp)
sed -e "s/^User=pi$/User=${TTY_USER}/" \
    -e "s|XDG_RUNTIME_DIR=/run/user/1000|XDG_RUNTIME_DIR=/run/user/$(id -u "$TTY_USER")|" \
    pico-google-photos.service > "$TMP_UNIT"
sudo install -Dm644 "$TMP_UNIT" "/etc/systemd/system/${SERVICE_NAME}"
rm -f "$TMP_UNIT"

sudo usermod -aG video,render,input,seat "$TTY_USER" || true
sudo loginctl enable-linger "$TTY_USER" || true
sudo systemctl enable seatd.service || true
sudo systemctl start  seatd.service || true

section "Seeding config"
if [[ ! -f "$CONFIG_FILE" ]]; then
  mkdir -p "$CONFIG_DIR"
  cp config.example.toml "$CONFIG_FILE"
  info "Wrote ${CONFIG_FILE}"
else
  warn "Config exists; leaving as-is: ${CONFIG_FILE}"
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
