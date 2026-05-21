#!/usr/bin/env bash
# ============================================================
# pico-google-photos uninstaller
# ============================================================
set -euo pipefail

BIN_NAME="pico-google-photos"
INSTALL_BIN="/usr/local/bin/${BIN_NAME}"
SERVICE_NAME="pico-google-photos.service"

BOLD='\033[1m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'
CYAN='\033[0;36m'; RESET='\033[0m'
info()    { echo -e "${GREEN}[+]${RESET} $*"; }
warn()    { echo -e "${YELLOW}[!]${RESET} $*"; }
die()     { echo -e "${RED}[x]${RESET} $*" >&2; exit 1; }
section() { echo -e "\n${BOLD}${CYAN}== $* ==${RESET}"; }

[[ "$(uname -s)" == "Linux" ]] || die "Linux only."
command -v sudo &>/dev/null || die "sudo required."

section "Stopping and disabling service"
if systemctl list-unit-files | grep -q "^${SERVICE_NAME}"; then
  sudo systemctl disable --now "${SERVICE_NAME}" || true
  sudo rm -f "/etc/systemd/system/${SERVICE_NAME}"
  sudo systemctl daemon-reload
  info "Service stopped and removed."
else
  warn "Service not found, skipping."
fi

section "Removing binary"
if [[ -f "$INSTALL_BIN" ]]; then
  sudo rm -f "$INSTALL_BIN"
  info "Removed $INSTALL_BIN"
else
  warn "Binary $INSTALL_BIN not found, skipping."
fi

section "User configurations"
TTY_USER="${SUDO_USER:-$USER}"
sudo loginctl disable-linger "$TTY_USER" || true
info "Disabled linger for $TTY_USER."

CONFIG_DIR="${HOME}/.config/pico-google-photos"
if [[ -d "$CONFIG_DIR" ]]; then
  warn "Configuration and Chromium profile data remain in ${CONFIG_DIR}."
  warn "To completely remove them, run: rm -rf ${CONFIG_DIR}"
fi

section "System packages"
warn "System packages (cage, chromium, seatd, dbus, rust) were NOT removed."
warn "If you wish to remove them, run:"
warn "  sudo apt-get remove --purge cage chromium chromium-browser seatd libseat1"

section "GPU Memory Split"
BOOT_CFG="/boot/firmware/config.txt"
[[ -f "$BOOT_CFG" ]] || BOOT_CFG="/boot/config.txt"
if [[ -f "$BOOT_CFG" ]] && grep -q '^gpu_mem=128' "$BOOT_CFG"; then
  warn "gpu_mem=128 is still present in ${BOOT_CFG}."
  warn "You may want to manually remove or change it if no longer needed."
fi

info "Uninstallation complete."
