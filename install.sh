#!/usr/bin/env bash
###############################################################################
# Client Simulator Installer v0.99.28
#
# RESTORED FEATURES:
# - VirtualHere client install + service + removal
# - Explicit client-sim autostart lifecycle
# - Explicit Raspberry Pi handling (install + remove)
# - Complete remove / purge symmetry
#
# DESIGN INVARIANTS REMAIN UNCHANGED:
# - Phased ordering
# - Desktop session remains running
# - Network services last
# - Drivers before firmware
# - PATH hardening
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

VERSION="0.99.28"

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

###############################################################################
# UI HELPERS
###############################################################################
if [ -t 1 ]; then
  G="\033[0;32m"; Y="\033[0;33m"; B="\033[0;34m"; Z="\033[0m"
else
  G=""; Y=""; B=""; Z=""
fi
ts(){ date "+%H:%M:%S"; }
ok(){ echo -e "[$(ts)] ${G}✔${Z} $*"; }
warn(){ echo -e "[$(ts)] ${Y}⚠${Z} $*"; }
info(){ echo "[$(ts)] $*"; }

###############################################################################
# SPINNER
###############################################################################
SPIN_BLOCK_TIMEOUT=120
spin() {
  local label="$1"; shift
  local frames=("." ".." "...")
  local i=0
  echo -ne "[$(ts)] ${B}[ ]${Z} $label"
  "$@" >>"$LOG" 2>&1 &
  pid=$!
  elapsed=0 dumped=0
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
install_pkgs(){ for p in "$@"; do spin "Installing: $p" apt install -y "$p" || warn "$p failed"; done; }

###############################################################################
# RASPBERRY PI DETECTION (RESTORED)
###############################################################################
IS_RPI=0
if command -v raspi-config >/dev/null 2>&1 &&
   grep -qi "raspberry pi" /proc/device-tree/model 2>/dev/null; then
  IS_RPI=1
  info "Raspberry Pi detected — external WLAN drivers will be skipped"
fi

###############################################################################
# USER MANAGEMENT
###############################################################################
info "Ensuring canonical user exists and has sudo"
id user >/dev/null 2>&1 || useradd -m -s /bin/bash user
getent group sudo >/dev/null 2>&1 || groupadd sudo || true
usermod -aG sudo user

###############################################################################
# SCREEN SAVER / DPMS DISABLE
###############################################################################
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
# WLAN DRIVER DEFINITIONS (EDIT HERE)
###############################################################################
WLAN_DRIVERS=(
  "8814au|morrownr|https://github.com/morrownr/8814au.git|8814au"
  "8821cu|morrownr|https://github.com/morrownr/8821cu-20210916.git|8821cu"
  "rtl8812au|aircrack|https://github.com/aircrack-ng/rtl8812au.git|rtl8812au"
  "rtl8188eu|dkms|https://github.com/lwfinger/rtl8188eu.git|8188eu"
)

###############################################################################
# REMOVE / PURGE MODE (RESTORED FULLY)
###############################################################################
if [ "$ACTION" = "remove" ]; then
  info "Removing client simulator"

  if [ "$IS_RPI" -eq 0 ] && [ -f "$WLAN_STATE" ]; then
    while IFS=: read -r MOD TYPE STATUS; do
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

  # VirtualHere removal
  systemctl stop virtualhereclient.service 2>/dev/null || true
  systemctl disable virtualhereclient.service 2>/dev/null || true
  rm -f /usr/sbin/vhclientx86_64 /etc/systemd/system/virtualhereclient.service
  systemctl daemon-reload || true

  # Client-sim removal
  rm -rf /usr/local/scripts /home/user/client-sim
  rm -f /etc/xdg/autostart/client-simulator.desktop

  if [ "$PURGE" = "--purge" ]; then
    apt purge -y lightdm lxqt-session build-essential dkms git rfkill || true
    apt autoremove -y || true
    rm -rf "$STATE_DIR"
  fi

  ok "Removal complete"
  exit 0
fi

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
HEADERS=()
HEADER="linux-headers-$(uname -r)"
apt-cache show "$HEADER" >/dev/null 2>&1 && HEADERS+=("$HEADER")
install_pkgs build-essential dkms git rfkill "${HEADERS[@]}"

###############################################################################
# PHASE 2 — WLAN DRIVERS (SKIPPED ON RPI)
###############################################################################
: >"$WLAN_STATE"
mkdir -p /usr/src/wifi-drivers
cd /usr/src/wifi-drivers

if [ "$IS_RPI" -eq 0 ]; then
  for d in "${WLAN_DRIVERS[@]}"; do
    IFS='|' read -r NAME TYPE REPO MOD <<<"$d"
    TMPLOG="$(mktemp)"
    STATUS="FAILED"

    case "$TYPE" in
      morrownr) git clone "$REPO" "$NAME" &&
        (cd "$NAME" && ./install-driver.sh >"$TMPLOG" 2>&1) &&
        STATUS="INSTALLED" ;;
      aircrack) git clone "$REPO" "$NAME" &&
        (cd "$NAME" && ./dkms-install.sh >"$TMPLOG" 2>&1) &&
        STATUS="INSTALLED" ;;
      dkms) git clone "$REPO" "$NAME" &&
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
else
  info "RPi: WLAN drivers skipped"
fi

###############################################################################
# PHASE 3a — FIRMWARE
###############################################################################
install_pkgs firmware-linux firmware-linux-nonfree firmware-misc-nonfree \
             firmware-iwlwifi firmware-atheros

###############################################################################
# LIGHTDM CONFIG + CLIENT-SIM AUTOSTART (RESTORED)
###############################################################################
echo "lightdm shared/default-x-display-manager select lightdm" | debconf-set-selections
echo "/usr/sbin/lightdm" > /etc/X11/default-display-manager
install_pkgs lightdm lightdm-gtk-greeter lxqt-session openbox

# Client-sim autostart (explicit)
mkdir -p /etc/xdg/autostart
cat >/etc/xdg/autostart/client-simulator.desktop <<EOF
[Desktop Entry]
Type=Application
Name=Client Simulator
Exec=/usr/local/scripts/start-sim.sh
OnlyShowIn=LXQt;
EOF

###############################################################################
# VIRTUALHERE INSTALL (RESTORED)
###############################################################################
spin "Installing VirtualHere client" bash -c '
wget -q https://www.virtualhere.com/sites/default/files/usbclient/vhclientx86_64 &&
wget -q https://www.virtualhere.com/sites/default/files/usbclient/scripts/virtualhereclient.service &&
mv vhclientx86_64 /usr/sbin &&
mv virtualhereclient.service /etc/systemd/system &&
chmod +x /usr/sbin/vhclientx86_64 &&
systemctl daemon-reload &&
systemctl enable virtualhereclient.service
'

###############################################################################
# PHASE 3b — NETWORK (LAST)
###############################################################################
install_pkgs network-manager systemd-resolved iperf3

###############################################################################
# FINAL SUMMARY
###############################################################################
echo
echo "========== WLAN DRIVER SUMMARY =========="
[ -f "$WLAN_STATE" ] && column -t -s: "$WLAN_STATE"
echo "========================================"
ok "Installation complete — reboot recommended"
echo "Log: $LOG"