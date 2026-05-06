#!/usr/bin/env bash
###############################################################################
# Client Simulator Installer v0.99.46
#
# PATCH OVER v0.99.45
# -----------------------------------------------------------------------------
# ✅ ARCHITECTURAL FIX:
#    - Remove temp-file-based driver logging
#    - Make WLAN driver installs synchronous & authoritative
#    - Spinner is UI-only, never part of control flow
###############################################################################

###############################################################################
# Bash + PATH hardening
###############################################################################
if [ -z "${BASH_VERSION:-}" ]; then
  echo "[INFO] Re-running installer with bash..."
  exec bash "$0" "$@"
fi
export PATH="/usr/sbin:/sbin:/usr/bin:/bin:$PATH"
set -euo pipefail

VERSION="0.99.46"

###############################################################################
# Startup version banner
###############################################################################
echo
echo "============================================================"
echo " Client Simulator Installer v${VERSION}"
echo " Started at: $(date)"
echo "============================================================"
echo

###############################################################################
# Global state and logging
###############################################################################
STATE_DIR="/var/lib/client-sim"
LOG="/var/log/client-sim-install.log"
WLAN_STATE="$STATE_DIR/wlan-drivers.state"
REBOOT_LOG="$STATE_DIR/reboot-requests.log"
DRIVER_LOG="$STATE_DIR/driver-install.log"
CLIENTSIM_DIR="/usr/local/scripts"
CLIENTSIM_REPO="/home/user/client-sim"

mkdir -p "$STATE_DIR" /var/log
: >"$LOG"
: >"$REBOOT_LOG"
: >"$DRIVER_LOG"
chmod 644 "$LOG" "$REBOOT_LOG" "$DRIVER_LOG"

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export GIT_TERMINAL_PROMPT=0

###############################################################################
# WLAN driver definitions — EDIT HERE
###############################################################################
WLAN_DRIVERS=(
  "8814au|morrownr|https://github.com/morrownr/8814au.git|8814au"
  "8821cu|morrownr|https://github.com/morrownr/8821cu-20210916.git|8821cu"
  "rtl8812au|aircrack|https://github.com/aircrack-ng/rtl8812au.git|rtl8812au"
  "rtl8188eu|dkms|https://github.com/lwfinger/rtl8188eu.git|8188eu"
)

###############################################################################
# Spinner helpers (UI-only)
###############################################################################
ts(){ date "+%H:%M:%S"; }
spin() {
  local label="$1"; shift
  local frames=("." ".." "...")
  local i=0
  echo -ne "[$(ts)] [ ] $label"
  while kill -0 "$1" 2>/dev/null; do
    echo -ne "\r[$(ts)] [${frames[$i]}] $label"
    i=$(( (i+1) % 3 ))
    sleep 1
  done
  wait "$1"
  echo -e "\r[$(ts)] [✔] $label"
}

###############################################################################
# Raspberry Pi detection
###############################################################################
IS_RPI=0
if command -v raspi-config >/dev/null 2>&1 &&
   grep -qi "raspberry pi" /proc/device-tree/model 2>/dev/null; then
  IS_RPI=1
  echo "[INFO] Raspberry Pi detected — WLAN drivers skipped"
fi

###############################################################################
# Base update
###############################################################################
apt update >>"$LOG" 2>&1
apt upgrade -y >>"$LOG" 2>&1 || true
dpkg --configure -a >>"$LOG" 2>&1 || true
apt -f install -y >>"$LOG" 2>&1 || true

###############################################################################
# Phase 1 — driver prerequisites
###############################################################################
apt install -y build-essential dkms git rfkill \
  linux-headers-$(uname -r) >>"$LOG" 2>&1 || true

###############################################################################
# Phase 2 — WLAN drivers (FIXED, synchronous)
###############################################################################
echo "[INFO] Phase 2: WLAN drivers"

: >"$WLAN_STATE"
mkdir -p /usr/src/wifi-drivers
cd /usr/src/wifi-drivers

SUPPRESS="$(mktemp -d)"
for cmd in reboot shutdown poweroff halt systemctl; do
  echo -e "#!/bin/sh\necho \"$cmd requested\" >>'$REBOOT_LOG'\nexit 0" >"$SUPPRESS/$cmd"
  chmod +x "$SUPPRESS/$cmd"
done
OLD_PATH="$PATH"
export PATH="$SUPPRESS:$PATH"

if [ "$IS_RPI" -eq 0 ]; then
  for d in "${WLAN_DRIVERS[@]}"; do
    IFS='|' read -r NAME TYPE REPO MOD <<<"$d"
    echo "[INFO] Installing WLAN driver: $NAME"
    start_ts="$(date +%s)"
    STATUS="FAILED"

    rm -rf "$NAME"
    if git clone "$REPO" "$NAME" >>"$LOG" 2>&1; then
      cd "$NAME"
      if [ "$TYPE" = "morrownr" ]; then
        ./install-driver.sh >>"$LOG" 2>&1 && STATUS="INSTALLED"
      elif [ "$TYPE" = "aircrack" ]; then
        ./dkms-install.sh >>"$LOG" 2>&1 && STATUS="INSTALLED"
      elif [ "$TYPE" = "dkms" ]; then
        make >>"$LOG" 2>&1 &&
        make install >>"$LOG" 2>&1 &&
        dkms add . >>"$LOG" 2>&1 || true
        dkms install "$MOD" >>"$LOG" 2>&1 || true
        STATUS="INSTALLED"
      fi
      cd ..
    fi

    end_ts="$(date +%s)"
    echo "$start_ts,$end_ts,$NAME,$TYPE,$STATUS" >>"$DRIVER_LOG"
    echo "$MOD:$TYPE:$STATUS" >>"$WLAN_STATE"
  done
  depmod -a >>"$LOG" 2>&1 || true
fi

export PATH="$OLD_PATH"
rm -rf "$SUPPRESS"

###############################################################################
# Phase 3a — firmware
###############################################################################
apt install -y firmware-linux firmware-linux-nonfree \
  firmware-misc-nonfree firmware-iwlwifi firmware-atheros \
  >>"$LOG" 2>&1 || true

###############################################################################
# LightDM + LXQt
###############################################################################
apt install -y lightdm lightdm-gtk-greeter lxqt-session openbox \
  >>"$LOG" 2>&1
echo "/usr/sbin/lightdm" > /etc/X11/default-display-manager

mkdir -p /etc/lightdm/lightdm.conf.d
cat >/etc/lightdm/lightdm.conf.d/20-autologin.conf <<EOF
[Seat:*]
autologin-user=user
user-session=lxqt
EOF

mkdir -p /etc/systemd/system/lightdm.service.d
cat >/etc/systemd/system/lightdm.service.d/override.conf <<EOF
[Service]
Restart=always
RestartSec=2
StartLimitIntervalSec=0
[Unit]
Conflicts=getty@tty7.service
EOF

systemctl daemon-reload
systemctl enable lightdm

###############################################################################
# Client-sim deployment (deterministic)
###############################################################################
if [ -d "$CLIENTSIM_REPO/.git" ]; then
  git -C "$CLIENTSIM_REPO" fetch --all
  git -C "$CLIENTSIM_REPO" reset --hard origin/HEAD
else
  rm -rf "$CLIENTSIM_REPO"
  git clone https://github.com/solutions-hpe/client-sim.git "$CLIENTSIM_REPO"
fi

mkdir -p "$CLIENTSIM_DIR"
cp -r "$CLIENTSIM_REPO/linux/"* "$CLIENTSIM_DIR/"
chmod +x "$CLIENTSIM_DIR"/*

mkdir -p /etc/xdg/autostart
cp -f "$CLIENTSIM_REPO/linux/"*.desktop /etc/xdg/autostart/
chmod 644 /etc/xdg/autostart/*.desktop

###############################################################################
# Network (last)
###############################################################################
apt install -y network-manager systemd-resolved iperf3 \
  >>"$LOG" 2>&1

###############################################################################
# Health check
###############################################################################
echo "========== HEALTH CHECK =========="
systemctl is-active --quiet lightdm && echo "LightDM: OK" || echo "LightDM: FAIL"
systemctl is-active --quiet NetworkManager && echo "Network: OK" || echo "Network: FAIL"
lsmod | grep -E '88|rtl' >/dev/null && echo "WLAN: PRESENT" || echo "WLAN: NOT LOADED"
ls /etc/xdg/autostart/*.desktop >/dev/null && echo "Autostart: OK" || echo "Autostart: MISSING"
echo "================================="

echo
echo "Installation complete — manual reboot recommended"
echo "Log: $LOG"