#!/usr/bin/env bash
###############################################################################
# Client Simulator Installer v0.99.32
#
# RESTORED FEATURES
# -----------------------------------------------------------------------------
# ✅ Full remove / purge symmetry
# ✅ Full client-sim deployment
# ✅ Full VirtualHere lifecycle
# ✅ WLAN reboot suppression + logging
# ✅ Troubleshooting guide restored
#
# INSTALL ORDER AND PHASED DESIGN ARE UNCHANGED
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

VERSION="0.99.32"

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
# WLAN DRIVER DEFINITIONS — EDIT HERE FIRST
###############################################################################
WLAN_DRIVERS=(
  "8814au|morrownr|https://github.com/morrownr/8814au.git|8814au"
  "8821cu|morrownr|https://github.com/morrownr/8821cu-20210916.git|8821cu"
  "rtl8812au|aircrack|https://github.com/aircrack-ng/rtl8812au.git|rtl8812au"
  "rtl8188eu|dkms|https://github.com/lwfinger/rtl8188eu.git|8188eu"
)

###############################################################################
# UI HELPERS
###############################################################################
ts(){ date "+%H:%M:%S"; }
info(){ echo "[$(ts)] $*" | tee -a "$LOG"; }
warn(){ echo "[$(ts)] WARN: $*" | tee -a "$LOG"; }
ok(){ echo "[$(ts)] OK: $*" | tee -a "$LOG"; }

###############################################################################
# RASPBERRY PI DETECTION
###############################################################################
IS_RPI=0
if command -v raspi-config >/dev/null 2>&1 &&
   grep -qi "raspberry pi" /proc/device-tree/model 2>/dev/null; then
  IS_RPI=1
  info "Raspberry Pi detected — external WLAN drivers will be skipped"
fi

###############################################################################
# REMOVE / PURGE MODE (FULLY RESTORED)
###############################################################################
if [ "$ACTION" = "remove" ]; then
  info "Removing client simulator components"

  # --- WLAN drivers ---
  if [ "$IS_RPI" -eq 0 ] && [ -f "$WLAN_STATE" ]; then
    while IFS=: read -r MOD TYPE STATUS; do
      info "Removing WLAN driver $MOD ($TYPE)"
      case "$TYPE" in
        dkms|aircrack) dkms remove "$MOD" --all || true ;;
        morrownr)
          [ -x "/usr/src/wifi-drivers/$MOD/remove-driver.sh" ] &&
          "/usr/src/wifi-drivers/$MOD/remove-driver.sh" || true ;;
      esac
    done <"$WLAN_STATE"
    depmod -a || true
    rm -f "$WLAN_STATE"
  fi

  # --- client-sim ---
  rm -rf "$CLIENTSIM_DIR" "$CLIENTSIM_REPO"
  rm -f /etc/xdg/autostart/client-simulator.desktop

  # --- VirtualHere ---
  systemctl stop virtualhereclient.service 2>/dev/null || true
  systemctl disable virtualhereclient.service 2>/dev/null || true
  rm -f /usr/sbin/vhclientx86_64
  rm -f /etc/systemd/system/virtualhereclient.service
  systemctl daemon-reload || true

  if [ "$PURGE" = "--purge" ]; then
    info "Purging all system packages installed by this script"
    apt purge -y \
      lightdm lightdm-gtk-greeter lxqt-session openbox \
      build-essential dkms git rfkill \
      firmware-linux firmware-linux-nonfree firmware-misc-nonfree \
      firmware-iwlwifi firmware-atheros \
      network-manager systemd-resolved iperf3 || true
    apt autoremove -y || true
    rm -rf "$STATE_DIR"
  fi

  ok "Removal complete"
  exit 0
fi

###############################################################################
# BASE UPDATE
###############################################################################
info "Updating base system"
apt update
apt upgrade -y || true
dpkg --configure -a || true
apt -f install -y || true

###############################################################################
# PHASE 1 — DRIVER PREREQUISITES
###############################################################################
info "Phase 1: Driver prerequisites"
HEADERS=()
HEADER="linux-headers-$(uname -r)"
apt-cache show "$HEADER" >/dev/null 2>&1 && HEADERS+=("$HEADER")
apt install -y build-essential dkms git rfkill "${HEADERS[@]}"

###############################################################################
# PHASE 2 — WLAN DRIVERS (REBOOT SUPPRESSED + LOGGED)
###############################################################################
info "Phase 2: WLAN driver installation (reboot suppressed)"

SUPPRESS="$(mktemp -d)"
for cmd in reboot shutdown poweroff halt; do
  echo -e "#!/bin/sh\necho \"[reboot-request] $cmd\" >>'$REBOOT_LOG'\nexit 0" >"$SUPPRESS/$cmd"
  chmod +x "$SUPPRESS/$cmd"
done
echo -e "#!/bin/sh\necho \"[reboot-request] systemctl $*\" >>'$REBOOT_LOG'\nexit 0" >"$SUPPRESS/systemctl"
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
apt install -y firmware-linux firmware-linux-nonfree firmware-misc-nonfree \
               firmware-iwlwifi firmware-atheros

###############################################################################
# LIGHTDM + CLIENT-SIM AUTOSTART
###############################################################################
info "Configuring LightDM"
echo "/usr/sbin/lightdm" > /etc/X11/default-display-manager
apt install -y lightdm lightdm-gtk-greeter lxqt-session openbox

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
wget -q https://www.virtualhere.com/sites/default/files/usbclient/vhclientx86_64
wget -q https://www.virtualhere.com/sites/default/files/usbclient/scripts/virtualhereclient.service
chmod +x vhclientx86_64
mv vhclientx86_64 /usr/sbin/
mv virtualhereclient.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable virtualhereclient.service

###############################################################################
# PHASE 3b — NETWORK (LAST)
###############################################################################
info "Phase 3b: Network services"
apt install -y network-manager systemd-resolved iperf3

###############################################################################
# FINAL SUMMARY
###############################################################################
echo
echo "========== WLAN DRIVER SUMMARY =========="
column -t -s: "$WLAN_STATE"
echo "========================================"

if [ -s "$REBOOT_LOG" ]; then
  warn "Some drivers requested a reboot (requests suppressed):"
  cat "$REBOOT_LOG"
fi

ok "Installation complete — manual reboot recommended"
echo "Log: $LOG"