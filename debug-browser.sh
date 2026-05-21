#!/usr/bin/env bash
# ============================================================
# pico-google-photos — debug-browser.sh
# Diagnoses why Chromium kiosk fails to come up on Raspberry Pi
# (especially Pi Zero 2 W with 512MB RAM).
#
# Runs read-only checks, prints PASS/FAIL/WARN per probe with a
# plain-English explanation of what each result means and what
# to do next. Safe to run while the service is up or down.
# ============================================================
set -u

SERVICE="pico-google-photos.service"
BIN="/usr/local/bin/pico-google-photos"
UNIT="/etc/systemd/system/${SERVICE}"

BOLD='\033[1m'; DIM='\033[2m'; RED='\033[0;31m'; GREEN='\033[0;32m'
YEL='\033[1;33m'; CYN='\033[0;36m'; RESET='\033[0m'

PASS=0; FAIL=0; WARN=0
FINDINGS=()

pass()    { echo -e " ${GREEN}[PASS]${RESET} $1"; PASS=$((PASS+1)); }
fail()    { echo -e " ${RED}[FAIL]${RESET} $1"; FAIL=$((FAIL+1)); FINDINGS+=("FAIL: $1 — $2"); }
warn()    { echo -e " ${YEL}[WARN]${RESET} $1"; WARN=$((WARN+1)); FINDINGS+=("WARN: $1 — $2"); }
info()    { echo -e " ${DIM}[info]${RESET} $1"; }
section() { echo -e "\n${BOLD}${CYN}== $* ==${RESET}"; }
hr()      { echo -e "${DIM}------------------------------------------------------------${RESET}"; }

has() { command -v "$1" >/dev/null 2>&1; }

# ----------------------------------------------------------------
section "Host identity"
HOST_MODEL="$(tr -d '\0' </proc/device-tree/model 2>/dev/null || echo unknown)"
KERNEL="$(uname -srm)"
ARCH="$(uname -m)"
OS="$(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-unknown}")"
info "Model:  ${HOST_MODEL}"
info "Kernel: ${KERNEL}"
info "Arch:   ${ARCH}"
info "OS:     ${OS}"

case "$HOST_MODEL" in
  *"Pi Zero 2"*) IS_ZERO2=1 ;;
  *)             IS_ZERO2=0 ;;
esac

# ----------------------------------------------------------------
section "Memory & swap (Pi Zero 2 W = 512MB — Chromium WILL OOM without swap)"
MEM_MB=$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo)
SWAP_MB=$(awk '/SwapTotal/{printf "%d", $2/1024}' /proc/meminfo)
info "RAM:  ${MEM_MB} MB"
info "Swap: ${SWAP_MB} MB"

if [[ "$IS_ZERO2" == 1 && "$SWAP_MB" -lt 512 ]]; then
  fail "Insufficient swap on Pi Zero 2 (have ${SWAP_MB}MB, need >=512MB)" \
       "Chromium needs ~700MB. With 512MB RAM and <512MB swap the kernel will OOM-kill Chromium silently. Enable swap: 'sudo dphys-swapfile swapoff; sudo sed -i s/CONF_SWAPSIZE=.*/CONF_SWAPSIZE=1024/ /etc/dphys-swapfile; sudo dphys-swapfile setup; sudo dphys-swapfile swapon'  (or dietpi-config -> Advanced -> Swapfile -> 1024)."
elif [[ "$SWAP_MB" -lt 256 ]]; then
  warn "Low swap (${SWAP_MB}MB)" \
       "Chromium may struggle. Consider 512MB+ swap."
else
  pass "Swap OK (${SWAP_MB}MB)"
fi

# ----------------------------------------------------------------
section "Recent OOM kills (kernel killing Chromium)"
if has dmesg; then
  OOM_HITS=$(sudo dmesg 2>/dev/null | grep -iE 'killed process|out of memory|oom-killer' | tail -5)
  if [[ -n "$OOM_HITS" ]]; then
    fail "OOM-killer active — kernel is killing processes for memory" \
         "Chromium is being executed but immediately killed by the kernel. Fix swap first (see above). Recent OOM lines:"
    echo "$OOM_HITS" | sed 's/^/        /'
  else
    pass "No recent OOM kills in dmesg"
  fi
else
  warn "dmesg unavailable" "Cannot check kernel log."
fi

# ----------------------------------------------------------------
section "GPU memory split"
if has vcgencmd; then
  GPU_RAW=$(vcgencmd get_mem gpu 2>/dev/null || echo "gpu=?M")
  GPU_MB=$(echo "$GPU_RAW" | grep -oE '[0-9]+' | head -1)
  info "vcgencmd reports: ${GPU_RAW}"
  if [[ -z "$GPU_MB" ]]; then
    warn "Could not parse GPU memory" "Run 'vcgencmd get_mem gpu' manually."
  elif [[ "$GPU_MB" -lt 128 ]]; then
    fail "GPU memory too low (${GPU_MB}MB, need >=128MB)" \
         "Cage/Chromium will fail to initialise the display. Add 'gpu_mem=128' to /boot/firmware/config.txt (or /boot/config.txt) and reboot."
  else
    pass "GPU memory OK (${GPU_MB}MB)"
  fi
else
  warn "vcgencmd not present" "Not running on Raspberry Pi firmware, or vcgencmd not on PATH."
fi

# ----------------------------------------------------------------
section "KMS overlay (Pi Zero 2 prefers fkms — full KMS unstable)"
BOOT_CFG="/boot/firmware/config.txt"
[[ -f "$BOOT_CFG" ]] || BOOT_CFG="/boot/config.txt"
if [[ -f "$BOOT_CFG" ]]; then
  OVERLAY=$(grep -E '^dtoverlay=vc4-(f)?kms-v3d' "$BOOT_CFG" | tail -1)
  info "config.txt: ${BOOT_CFG}"
  info "overlay:    ${OVERLAY:-<none>}"
  if [[ -z "$OVERLAY" ]]; then
    fail "No vc4 KMS overlay enabled" \
         "Cage cannot find a DRM device without KMS. Add 'dtoverlay=vc4-fkms-v3d' to ${BOOT_CFG} and reboot."
  elif [[ "$IS_ZERO2" == 1 && "$OVERLAY" == *"vc4-kms-v3d"* ]]; then
    warn "Full KMS on Pi Zero 2 — known to crash Cage" \
         "Switch to fake KMS: replace 'vc4-kms-v3d' with 'vc4-fkms-v3d' in ${BOOT_CFG} and reboot."
  else
    pass "KMS overlay OK (${OVERLAY})"
  fi
else
  warn "No config.txt found" "Not a Raspberry Pi boot, or unusual layout."
fi

# ----------------------------------------------------------------
section "DRM device (cage needs /dev/dri/card*)"
if compgen -G "/dev/dri/card*" >/dev/null; then
  for d in /dev/dri/card* /dev/dri/render*; do
    [[ -e "$d" ]] || continue
    info "$(ls -l "$d")"
  done
  pass "/dev/dri/card* present"
else
  fail "No /dev/dri/card* device" \
       "GPU/KMS driver not loaded. Check overlay (above), reboot, then re-run."
fi

# ----------------------------------------------------------------
section "Service unit installed & enabled"
if [[ -f "$UNIT" ]]; then
  pass "Unit file exists: $UNIT"
  ENABLED=$(systemctl is-enabled "$SERVICE" 2>/dev/null || echo "no")
  ACTIVE=$(systemctl is-active "$SERVICE" 2>/dev/null || echo "inactive")
  info "is-enabled: ${ENABLED}"
  info "is-active : ${ACTIVE}"
  if [[ "$ENABLED" != "enabled" ]]; then
    fail "Service not enabled" "Run: sudo systemctl enable ${SERVICE}"
  fi
  if [[ "$ACTIVE" != "active" ]]; then
    fail "Service not running" "Check journal below for exit reason."
  fi
else
  fail "Unit file missing ($UNIT)" "Re-run install.sh."
fi

# ----------------------------------------------------------------
section "Binary installed"
if [[ -x "$BIN" ]]; then
  info "$(file "$BIN" 2>/dev/null || ls -l "$BIN")"
  BIN_ARCH=$(file -b "$BIN" 2>/dev/null | grep -oE 'ARM aarch64|ARM, EABI5|x86-64' | head -1)
  case "$ARCH" in
    aarch64) [[ "$BIN_ARCH" == *aarch64* ]] || warn "Binary arch != host arch (have $BIN_ARCH, host $ARCH)" "Reinstall: installer picks asset by uname -m." ;;
    armv7l)  [[ "$BIN_ARCH" == *EABI5*    ]] || warn "Binary arch != host arch (have $BIN_ARCH, host $ARCH)" "Reinstall." ;;
  esac
  pass "Binary present and executable"
else
  fail "Binary missing: $BIN" "Run install.sh."
fi

# ----------------------------------------------------------------
section "Required system packages"
for pkg_cmd in "cage" "chromium" "chromium-browser" "seatd"; do
  if has "$pkg_cmd"; then
    VER=$("$pkg_cmd" --version 2>&1 | head -1)
    pass "${pkg_cmd}: ${VER}"
  else
    case "$pkg_cmd" in
      chromium|chromium-browser)
        # Only one of these is required.
        ;;
      *)
        fail "${pkg_cmd} not installed" "sudo apt-get install ${pkg_cmd}" ;;
    esac
  fi
done
if ! has chromium && ! has chromium-browser; then
  fail "Neither chromium nor chromium-browser installed" \
       "sudo apt-get install chromium  (Bookworm) or chromium-browser (Bullseye)"
fi

# ----------------------------------------------------------------
section "Dependent services (seatd, dbus)"
for s in seatd dbus; do
  ST=$(systemctl is-active "$s" 2>/dev/null || echo inactive)
  if [[ "$ST" == "active" ]]; then
    pass "${s}.service active"
  else
    fail "${s}.service not active (state: ${ST})" \
         "sudo systemctl enable --now ${s}"
  fi
done

# ----------------------------------------------------------------
section "tty7 ownership (kiosk binds /dev/tty7)"
GETTY_STATE=$(systemctl is-enabled getty@tty7.service 2>/dev/null || echo masked)
info "getty@tty7 is-enabled: ${GETTY_STATE}"
case "$GETTY_STATE" in
  masked|disabled) pass "tty7 free for kiosk" ;;
  *)               fail "getty@tty7 competes for /dev/tty7" \
                        "sudo systemctl disable --now getty@tty7 ; sudo systemctl mask getty@tty7" ;;
esac

if has fuser; then
  TTY_HOLDER=$(sudo fuser -v /dev/tty7 2>&1 | tail -n +2)
  if [[ -n "$TTY_HOLDER" ]]; then
    info "tty7 currently held by:"
    echo "$TTY_HOLDER" | sed 's/^/        /'
  fi
fi

# ----------------------------------------------------------------
section "Service user — groups and home"
if [[ -f "$UNIT" ]]; then
  SVC_USER=$(grep -E '^User=' "$UNIT" | head -1 | cut -d= -f2)
  info "User= ${SVC_USER}"
  if id "$SVC_USER" >/dev/null 2>&1; then
    GROUPS_LIST=$(id -nG "$SVC_USER")
    info "groups: ${GROUPS_LIST}"
    for g in video render input; do
      if echo " $GROUPS_LIST " | grep -q " $g "; then
        pass "${SVC_USER} in group ${g}"
      else
        fail "${SVC_USER} NOT in group ${g}" \
             "sudo usermod -aG ${g} ${SVC_USER}  (then reboot — group changes apply on new login)"
      fi
    done
  else
    fail "Service user '${SVC_USER}' does not exist" "Check install.sh User= substitution."
  fi
fi

# ----------------------------------------------------------------
section "XDG_RUNTIME_DIR (/run/cage) — must be 0700 and owned by service user"
if [[ -d /run/cage ]]; then
  RD_INFO=$(ls -ld /run/cage)
  info "$RD_INFO"
  MODE=$(stat -c '%a' /run/cage)
  OWNER=$(stat -c '%U' /run/cage)
  if [[ "$MODE" != "700" ]]; then
    warn "/run/cage mode ${MODE} (expected 700)" \
         "Wayland refuses runtime dir if too open. Fix: sudo chmod 700 /run/cage"
  fi
  if [[ -n "${SVC_USER:-}" && "$OWNER" != "$SVC_USER" ]]; then
    warn "/run/cage owned by ${OWNER}, not ${SVC_USER}" \
         "Service won't be able to write socket. Fix: sudo chown ${SVC_USER}: /run/cage  (RuntimeDirectory= should auto-create on start)."
  fi
else
  info "/run/cage absent (only created while service runs — OK if service stopped)"
fi

# ----------------------------------------------------------------
section "Config file"
CFG="/home/${SVC_USER:-pi}/.config/pico-google-photos/config.toml"
if [[ -f "$CFG" ]]; then
  pass "Config exists: $CFG"
  CHROM=$(grep -E '^chromium_binary' "$CFG" | head -1)
  URL=$(grep -E '^url' "$CFG" | head -1)
  info "${CHROM}"
  info "${URL}"
else
  warn "Config not at $CFG" "App will fall back to defaults. Not necessarily a problem."
fi

# ----------------------------------------------------------------
section "Recent service journal (last 60 lines)"
if has journalctl; then
  hr
  sudo journalctl -u "$SERVICE" -b --no-pager -n 60 2>/dev/null | sed 's/^/  /'
  hr
  # Scan for known killer lines.
  J=$(sudo journalctl -u "$SERVICE" -b --no-pager 2>/dev/null)
  if echo "$J" | grep -qiE 'failed to create.*backend|no DRM device|cannot open /dev/dri'; then
    fail "Cage cannot init DRM" "GPU memory / KMS overlay issue. See sections above."
  fi
  if echo "$J" | grep -qiE 'failed to open seat|seatd'; then
    fail "seatd handshake failed" "Ensure seatd active and user in 'seat'/'_seatd' group, then reboot."
  fi
  if echo "$J" | grep -qiE 'killed|signal 9|SIGKILL'; then
    fail "Process killed (likely OOM)" "Add swap (see Memory section)."
  fi
  if echo "$J" | grep -qiE 'Profile.*lock|SingletonLock'; then
    fail "Chromium profile locked" "rm -f ~/.local/share/pico-google-photos/profile/Singleton*  then restart service."
  fi
fi

# ----------------------------------------------------------------
section "Manual reproduce (run this AFTER stopping the service)"
cat <<'EOF'
  sudo systemctl stop pico-google-photos.service
  sudo chvt 2
  sudo -u pi XDG_RUNTIME_DIR=/run/cage WLR_BACKENDS=drm \
       WLR_NO_HARDWARE_CURSORS=1 RUST_LOG=debug \
       /usr/local/bin/pico-google-photos 2>&1 | tee /tmp/pgp-debug.log
  # Watch /tmp/pgp-debug.log for the first error line — that is the root cause.
EOF

# ----------------------------------------------------------------
section "Summary"
echo -e " ${GREEN}PASS:${RESET} ${PASS}   ${YEL}WARN:${RESET} ${WARN}   ${RED}FAIL:${RESET} ${FAIL}"
if [[ ${#FINDINGS[@]} -gt 0 ]]; then
  echo
  echo -e "${BOLD}Action items (in priority order):${RESET}"
  i=1
  for f in "${FINDINGS[@]}"; do
    echo "  ${i}. ${f}"
    i=$((i+1))
  done
fi

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
exit 0
