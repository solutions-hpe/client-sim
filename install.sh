#!/usr/bin/env bash
###############################################################################
# Client Simulator Installer v0.99.27
#
# =============================================================================
# DESIGN DECISIONS SUMMARY
# =============================================================================
#
# This installer is a phased lifecycle tool, not a simple package script.
# Its structure is deliberate and based on observed failures during testing.
#
# CORE INVARIANTS (DO NOT VIOLATE):
#
# 1. PHASED EXECUTION MODEL
#    - Phase 1 : Driver build prerequisites (safe under active X)
#    - Phase 2 : GitHub WLAN drivers (build-time only, hardware-specific)
#    - Phase 3a: Firmware (highest reboot / X crash risk)
#    - Phase 3b: Network services (LAST — connectivity may drop)
#
# 2. DESKTOP SESSION STAYS RUNNING
#    - LightDM / LXQt must NOT be stopped or masked during install.
#
# 3. NETWORK-AFFECTING PACKAGES ARE LAST
#    - NetworkManager resets interfaces and DNS.
#
# 4. DRIVER BUILDS BEFORE FIRMWARE
#    - Firmware updates can reset GPUs and crash active X11 sessions.
#
# 5. DRIVER FAILURES DO NOT ABORT INSTALL
#    - WLAN drivers are hardware-specific.
#
# 6. SECURE BOOT IS NOT MANAGED
#    - No module signing or MOK enrollment is done.
#
# 7. PERSISTENT LOGGING IS REQUIRED
#
# 8. PATH HARDENING IS REQUIRED
#    - Non-login shells lack /usr/sbin on minimal systems.
#
# 9. THE "user" ACCOUNT IS CANONICAL
#
###############################################################################

###############################################################################
# ENSURE BASH + HARDEN PATH
###############################################################################
if [ -z "${BASH_VERSION:-}" ]; then
  echo "[INFO] Re-running installer with bash..."
  exec bash "$0" "$@"
fi

export PATH="/usr/sbin:/sbin:/usr/bin:/bin:$PATH"
set -euo pipefail

VERSION="0.99.27"

###############################################################################
# GLOBAL STATE AND LOGGING
###############################################################################
STATE_DIR="/var/lib/client-sim"
LOG="/var/log/client-sim-install.log"
WLAN_STATE="$STATE_DIR/wlan-drivers.state"

ACTION="${1:-install}"
PURGE="${2:-}"

mkdir -p "$STATE_DIR" /var/log
touch "$LOG"
chmod 644 "$LOG"

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export GIT_TERMINAL_PROMPT=0

###############################################################################
# WLAN DRIVER DEFINITIONS — EDIT HERE ONLY
#
# Format:
#   "name|type|git_repo|module"
#
# type:
#   morrownr  -> install-driver.sh
#   aircrack  -> dkms-install.sh
#   dkms      -> make + dkms add/install
#
# NOTES:
# - Exit codes are unreliable; output inspection is used.
# - Secure Boot ON => modules build but will not load.
###############################################################################
WLAN_DRIVERS=(
  "8814au|morrownr|https://github.com/morrownr/8814au.git|8814au"
  "8821cu|morrownr|https://github.com/morrownr/8821cu-20210916.git|8821cu"
  "8821au-20210708|morrownr|https://github.com/morrownr/8821au-20210708.git|8821au"
  "8812au-20210820|morrownr|https://github.com/morrownr/8812au-20210820.git|8812au"
  "88x2bu|morrownr|https://github.com/morrownr/88x2bu-20210702.git|88x2bu"
  "rtl8852bu|morrownr|https://github.com/morrownr/rtl8852bu.git|rtl8852bu"
  "rtl8852cu|morrownr|https://github.com/morrownr/rtl8852cu.git|rtl8852cu"
  "rtl8822bu|morrownr|https://github.com/morrownr/rtl8822bu.git|rtl8822bu"
  "rtl8812au|aircrack|https://github.com/aircrack-ng/rtl8812au.git|rtl8812au"
  "rtl8188eu|dkms|https://github.com/lwfinger/rtl8188eu.git|8188eu"
  "rtl8188fu|dkms|https://github.com/kelebek333/rtl8188fu.git|8188fu"
  "rtl8192eu|dkms|https://github.com/Mange/rtl8192eu-linux-driver.git|8192eu"
  "rtl8192fu|dkms|https://github.com/heemsoft/rtl8192fu.git|8192fu"
  "rtl8723au|dkms|https://github.com/lwfinger/rtl8723au.git|8723au"
  "rtl8852au|dkms|https://github.com/lwfinger/rtl8852au.git|8852au"
  "mt7601u|dkms|https://github.com/kuba-moo/mt7601u.git|mt7601u"
)

###############################################################################
# UI HELPERS
###############################################################################
if [ -t 1 ]; then
  G="\033[0;32m"; Y="\033[0;33m"; B="\033[0;34m"; Z="\033[0m"
else
  G=""; Y=""; B=""; Z=""
fi

ts(){ date "+%H:%M:%S"; }
ok(){   echo -e "[$(ts)] ${G}✔${Z} $*"; }
warn(){ echo -e "[$(ts)] ${Y}⚠${Z} $*"; }
info(){ echo "[$(ts)] $*"; }

###############################################################################
# SPINNER WITH BLOCK DETECTION
###############################################################################
SPIN_BLOCK_TIMEOUT=120

spin() {
  local label="$1"; shift
  local frames=("." ".." "...")
  local i=0
  echo -ne "[$(ts)] ${B}[ ]${Z} $label"
  "$@" >>"$LOG" 2>&1 &
  pid=$!
  elapsed=0; dumped=0
  while kill -0 "$pid" 2>/dev/null; do
    echo -ne "\r[$(ts)] ${B}[${frames[$i]}]${Z} $label"
    i=$(( (i+1) % 3 ))
    sleep 1
    elapsed=$((elapsed+1))
    if (( elapsed >= SPIN_BLOCK_TIMEOUT && dumped == 0 )); then
      dumped=1
      journalctl -xe --no-pager -n 100 >>"$LOG" 2>&1 || true
    fi
  done
  wait "$pid" || true
  echo -e "\r[$(ts)] ${G}[✔]${Z} $label"
}

install_pkgs() {
  for p in "$@"; do
    spin "Installing package: $p" apt install -y "$p" ||
      warn "Issue installing $p"
  done
}

###############################################################################
# USER SETUP
###############################################################################
info "Ensuring canonical user exists and has sudo"
id user >/dev/null 2>&1 || useradd -m -s /bin/bash user
getent group sudo >/dev/null 2>&1 || groupadd sudo || true
usermod -aG sudo user

###############################################################################
# DISABLE SCREEN SAVER / DPMS (LXQt)
###############################################################################
info "Disabling screen saver and DPMS for LXQt"
USER_HOME="$(getent passwd user | cut -d: -f6)"
mkdir -p "$USER_HOME/.config/autostart" "$USER_HOME/.config/lxqt"
cat >"$USER_HOME/.config/autostart/disable-screensaver.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Disable Screen Saver
Exec=sh -c "xset s off; xset s noblank; xset -dpms"
OnlyShowIn=LXQt;
EOF
cat >"$USER_HOME/.config/lxqt/session.conf" <<EOF
[Session]
allowScreenSaver=false
allowSuspend=false
EOF
chown -R user:user "$USER_HOME/.config"

###############################################################################
# BASE UPDATE
###############################################################################
spin "Updating package index" apt update
spin "Upgrading base system" apt upgrade -y || true
dpkg --configure -a >>"$LOG" 2>&1 || true
apt -f install -y >>"$LOG" 2>&1 || true

###############################################################################
# PHASE 1 — DRIVER BUILD PREREQUISITES
###############################################################################
info "Phase 1: Driver build prerequisites"
HEADERS=()
HEADER="linux-headers-$(uname -r)"
apt-cache show "$HEADER" >/dev/null 2>&1 && HEADERS+=("$HEADER")
install_pkgs build-essential dkms git rfkill "${HEADERS[@]}"

###############################################################################
# PHASE 2 — GITHUB WLAN DRIVERS
###############################################################################
info "Phase 2: GitHub WLAN drivers"
: >"$WLAN_STATE"
mkdir -p /usr/src/wifi-drivers
cd /usr/src/wifi-drivers

for d in "${WLAN_DRIVERS[@]}"; do
  IFS='|' read -r NAME TYPE REPO MOD <<<"$d"
  info "Building driver: $NAME"
  TMPLOG="$(mktemp)"
  STATUS="FAILED"

  case "$TYPE" in
    morrownr)
      git clone "$REPO" "$NAME" &&
      (cd "$NAME" && ./install-driver.sh >"$TMPLOG" 2>&1) &&
      STATUS="INSTALLED" ||
      grep -qi "already" "$TMPLOG" && STATUS="ALREADY_INSTALLED"
      ;;
    aircrack)
      git clone "$REPO" "$NAME" &&
      (cd "$NAME" && ./dkms-install.sh >"$TMPLOG" 2>&1) &&
      STATUS="INSTALLED" ||
      grep -qi "already" "$TMPLOG" && STATUS="ALREADY_INSTALLED"
      ;;
    dkms)
      git clone "$REPO" "$NAME" &&
      (cd "$NAME" &&
       make >"$TMPLOG" 2>&1 &&
       make install >>"$TMPLOG" 2>&1 &&
       dkms add . >>"$TMPLOG" 2>&1 || true &&
       dkms install "$MOD" >>"$TMPLOG" 2>&1 || true) &&
      STATUS="INSTALLED" ||
      grep -qi "already" "$TMPLOG" && STATUS="ALREADY_INSTALLED"
      ;;
  esac

  cat "$TMPLOG" >>"$LOG"
  echo "$MOD:$TYPE:$STATUS" >>"$WLAN_STATE"
  rm -f "$TMPLOG"
done

depmod -a || true

###############################################################################
# PHASE 3a — FIRMWARE
###############################################################################
info "Phase 3a: Firmware (before network)"
install_pkgs firmware-linux firmware-linux-nonfree firmware-misc-nonfree \
             firmware-iwlwifi firmware-atheros

###############################################################################
# LIGHTDM CONFIGURATION (AUTHORITATIVE)
###############################################################################
info "Configuring LightDM"
echo "lightdm shared/default-x-display-manager select lightdm" | debconf-set-selections
echo "sddm shared/default-x-display-manager select lightdm" | debconf-set-selections
echo "/usr/sbin/lightdm" > /etc/X11/default-display-manager
install_pkgs lightdm lightdm-gtk-greeter lxqt-session openbox

###############################################################################
# PHASE 3b — NETWORK (LAST)
###############################################################################
info "Phase 3b: Network services (last)"
install_pkgs network-manager systemd-resolved iperf3

###############################################################################
# FINAL SUMMARY
###############################################################################
echo
echo "================ WLAN DRIVER SUMMARY ================"
cat "$WLAN_STATE" | column -t -s:
echo "===================================================="
ok "Installation complete — reboot recommended"
echo "Log saved to $LOG"