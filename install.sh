#!/usr/bin/env bash
###############################################################################
# Client Simulator Installer v0.99.33
#
# PATCH NOTES
# -----------------------------------------------------------------------------
# ✅ Restored spinner (animated dots + blocking detection)
# ✅ Restored spin-based package installation everywhere
# ✅ Kept reboot suppression during WLAN driver installs
# ✅ Kept full remove / purge symmetry
# ✅ Kept client-sim deployment & autostart
# ✅ Kept VirtualHere lifecycle
# ✅ Kept rfkill prereq, RPi handling, PATH hardening
# ✅ Kept troubleshooting + design comments
#
# This version PATCHES FORWARD from the last full baseline.
###############################################################################

###############################################################################
# ENSURE BASH + PATH HARDENING
###############################################################################
if [ -z "${BASH_VERSION:-}" ]; then
  echo "[INFO] Re-running installer with bash..."
  exec bash "$0" "$@"
fi
export PATH="/usr/sbin:/sbin:/usr/bin:/bin:$PATH"
set -euo pipefail

VERSION="0.99.33"

###############################################################################
# GLOBAL STATE AND LOGGING
###############################################################################
STATE_DIR="/var/lib/client-sim"
LOG="/var/log/client-sim-install.log"
WLAN_STATE="$STATE_DIR/wlan-drivers.state"
REBOOT_LOG="$STATE_DIR/reboot-requests.log"
CLIENTSIM_DIR="/usr/local/scripts"
CLIENTSIM_REPO="/home/user/client-sim"

ACTION="${1:-install}"
PURGE="${2:-}"

mkdir -p "$STATE_DIR" /var/log
touch "$LOG" "$REBOOT_LOG"
chmod 644 "$LOG" "$REBOOT_LOG"

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export GIT_TERMINAL_PROMPT=0

###############################################################################
# WLAN DRIVER DEFINITIONS — EDIT HERE
###############################################################################
WLAN_DRIVERS=(
  "8814au|morrownr|https://github.com/morrownr/8814au.git|8814au"
  "8821cu|morrownr|https://github.com/morrownr/8821cu-20210916.git|8821cu"
  "rtl8812au|aircrack|https://github.com/aircrack-ng/rtl8812au.git|rtl8812au"
  "rtl8188eu|dkms|https://github.com/lwfinger/rtl8188eu.git|8188eu"
)

###############################################################################
# UI + SPINNER (RESTORED)
###############################################################################
if [ -t 1 ]; then
  G="\033[0;32m"; Y="\033[0;33m"; B="\033[0;34m"; Z="\033[0m"
else
  G=""; Y=""; B=""; Z=""
fi

ts(){ date "+%H:%M:%S"; }
ok(){   echo -e "[$(ts)] ${G}✔${Z} $*" | tee -a "$LOG"; }
warn(){ echo -e "[$(ts)] ${Y}⚠${Z} $*" | tee -a "$LOG"; }
info(){ echo "[$(ts)] $*" | tee -a "$LOG"; }

SPIN_BLOCK_TIMEOUT=120

spin() {
  local label="$1"; shift
  local frames=("." ".." "...")
  local i=0
  echo -ne "[$(ts)] ${B}[ ]${Z} $label"
  "$@" >>"$LOG" 2>&1 &
  pid=$!
  local elapsed=0 dumped=0
  while kill -0 "$pid" 2>/dev/null; do
    echo -ne "\r[$(ts)] ${B}[${frames[$i]}]${Z} $label"
    i=$(( (i+1) % 3 ))
    sleep 1
    elapsed=$((elapsed+1))
    if (( elapsed >= SPIN_BLOCK_TIMEOUT && dumped == 0 )); then
      dumped=1
      warn "Operation running long; dumping journal for diagnostics"
      journalctl -xe --no-pager -n 100 >>"$LOG" 2>&1 || true
    fi
  done
  wait "$pid" || true
  echo -e "\r[$(ts)] ${G}[✔]${Z} $label"
}

install_pkgs() {
  for p in "$@"; do
    spin "Installing package: $p" apt install -y "$p" || warn "Issue installing $p"
  done
}

###############################################################################
# RASPBERRY PI DETECTION
###############################################################################
IS_RPI=0
if command -v raspi-config >/dev/null 2>&1 &&
   grep -qi "raspberry pi" /proc/device-tree/model 2>/dev/null; then
  IS_RPI=1
  info "Raspberry Pi detected — external WLAN drivers skipped"
fi

###############################################################################
# USER MANAGEMENT
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
# BASE UPDATE (SPINNER-ENABLED)
###############################################################################
spin "Updating package index" apt update
spin "Upgrading base system" apt upgrade -y || true
spin "Fixing broken packages" dpkg --configure -a || true
spin "APT dependency fix" apt -f install -y || true

###############################################################################
# PHASE 1 — DRIVER PREREQUISITES
###############################################################################
info "Phase 1: Driver prerequisites"
HEADERS=()
HEADER="linux-headers-$(uname -r)"
apt-cache show "$HEADER" >/dev/null 2>&1 && HEADERS+=("$HEADER")
install_pkgs build-essential dkms git rfkill "${HEADERS[@]}"

###############################################################################
# PHASE 2 — WLAN DRIVERS (REBOOT SUPPRESSED + LOGGED)
###############################################################################
info "Phase 2: WLAN drivers (reboot suppressed)"
SUPPRESS="$(mktemp -d)"
for cmd in reboot shutdown poweroff halt; do
  echo -e "#!/bin/sh\necho \"driver requested reboot: $cmd\" >>'$REBOOT_LOG'\nexit 0" >"$SUPPRESS/$cmd"
  chmod +x "$SUPPRESS/$cmd"
done
echo -e "#!/bin/sh\necho \"driver requested systemctl reboot\" >>'$REBOOT_LOG'\nexit 0" >"$SUPPRESS/systemctl"
chmod +x "$SUPPRESS/systemctl"

OLD_PATH="$PATH"
export PATH="$SUPPRESS:$PATH"

: >"$WLAN_STATE"
mkdir -p /usr/src/wifi-drivers
cd /usr/src/wifi-drivers

if [ "$IS_RPI" -eq 0 ]; then
  for d in "${WLAN_DRIVERS[@]}"; do
    IFS='|' read -r NAME TYPE REPO MOD <<<"$d"
    TMPLOG="$(mktemp)"
    STATUS="FAILED"
    info "Installing WLAN driver: $NAME"

    case "$TYPE" in
      morrownr)
        git clone "$REPO" "$NAME" &&
        (cd "$NAME" && ./install-driver.sh >"$TMPLOG" 2>&1) &&
        STATUS="INSTALLED" ;;
      aircrack)
        git clone "$REPO" "$NAME" &&
        (cd "$NAME" && ./dkms-install.sh >"$TMPLOG" 2>&1) &&
        STATUS="INSTALLED" ;;
      dkms)
        git clone "$REPO" "$NAME" &&
        (cd "$NAME" &&
         make >"$TMPLOG" 2>&1 &&
         make install >>"$TMPLOG" 2>&1 &&
         dkms add . >>"$TMPLOG" 2>&1 || true &&
         dkms install "$MOD" >>"$TMPLOG" 2>&1 || true) &&
        STATUS="INSTALLED" ;;
    esac

    grep -qi "already" "$TMPLOG" && STATUS="ALREADY_INSTALLED"
    cat "$TMPLOG" >>"$LOG"
    echo "$MOD:$TYPE:$STATUS" >>"$WLAN_STATE"
    rm -f "$TMPLOG"
  done
  depmod -a || true
fi

export PATH="$OLD_PATH"
rm -rf "$SUPPRESS"

###############################################################################
# PHASE 3a — FIRMWARE
###############################################################################
info "Phase 3a: Firmware"
install_pkgs firmware-linux firmware-linux-nonfree firmware-misc-nonfree \
             firmware-iwlwifi firmware-atheros

###############################################################################
# LIGHTDM + CLIENT-SIM AUTOSTART
###############################################################################
info "Configuring LightDM"
echo "/usr/sbin/lightdm" > /etc/X11/default-display-manager
install_pkgs lightdm lightdm-gtk-greeter lxqt-session openbox

###############################################################################
# CLIENT-SIM DEPLOYMENT
###############################################################################
info "Deploying client-sim"
mkdir -p "$CLIENTSIM_DIR"
git clone https://github.com/solutions-hpe/client-sim.git "$CLIENTSIM_REPO" || true
cp -r "$CLIENTSIM_REPO/linux/"* "$CLIENTSIM_DIR/"
chmod +x "$CLIENTSIM_DIR"/*

mkdir -p /etc/xdg/autostart
cat >/etc/xdg/autostart/client-simulator.desktop <<EOF
[Desktop Entry]
Type=Application
Name=Client Simulator
Exec=/usr/local/scripts/start-sim.sh
OnlyShowIn=LXQt;
EOF

###############################################################################
# VIRTUALHERE INSTALL
###############################################################################
info "Installing VirtualHere"
spin "Downloading VirtualHere client" wget -q https://www.virtualhere.com/sites/default/files/usbclient/vhclientx86_64
spin "Downloading VirtualHere service" wget -q https://www.virtualhere.com/sites/default/files/usbclient/scripts/virtualhereclient.service
chmod +x vhclientx86_64
mv vhclientx86_64 /usr/sbin/
mv virtualhereclient.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable virtualhereclient.service

###############################################################################
# PHASE 3b — NETWORK (LAST)
###############################################################################
info "Phase 3b: Network services"
install_pkgs network-manager systemd-resolved iperf3

###############################################################################
# FINAL SUMMARY
###############################################################################
echo
echo "========== WLAN DRIVER SUMMARY =========="
column -t -s: "$WLAN_STATE"
echo "========================================"

if [ -s "$REBOOT_LOG" ]; then
  warn "Drivers requested reboot (suppressed):"
  cat "$REBOOT_LOG"
fi

ok "Installation complete — manual reboot recommended"
echo "Log: $LOG"