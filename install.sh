#!/usr/bin/env bash
###############################################################################
# Client Simulator Installer v0.99.13
# FULLY INTEGRATED – NOTHING REMOVED
###############################################################################

# --- force bash ---
if [ -z "${BASH_VERSION:-}" ]; then
  echo "[INFO] Re-running installer with bash..."
  exec bash "$0" "$@"
fi

set -euo pipefail

VERSION="0.99.13"

LOG="/tmp/client-sim-install.log"
STATE_DIR="/var/lib/client-sim"
WLAN_STATE="$STATE_DIR/wlan-drivers.state"

ACTION="${1:-install}"
PURGE="${2:-}"

mkdir -p "$STATE_DIR"
: >"$LOG"

export GIT_TERMINAL_PROMPT=0
export GIT_ASKPASS=/bin/false
export SSH_ASKPASS=/bin/false
export NEEDRESTART_MODE=a

###############################################################################
# UI helpers
###############################################################################
if [ -t 1 ]; then
  G="\033[0;32m"; Y="\033[0;33m"; R="\033[0;31m"; B="\033[0;34m"; Z="\033[0m"
else
  G=""; Y=""; R=""; B=""; Z=""
fi

ts(){ date "+%H:%M:%S"; }
ok(){   echo -e "[$(ts)] ${G}✔${Z} $*"; }
warn(){ echo -e "[$(ts)] ${Y}⚠${Z} $*"; }
err(){  echo -e "[$(ts)] ${R}✖${Z} $*"; }
info(){ echo "[$(ts)] $*"; }

###############################################################################
# Spinner with block detection + journalctl dump
###############################################################################
spin_with_block_detection() {
  local label="$1"; shift
  local timeout="${SPIN_BLOCK_TIMEOUT:-20}"

  echo -ne "[$(ts)] ${B}[ ]${Z} $label"
  "$@" >>"$LOG" 2>&1 &
  pid=$!

  elapsed=0
  dumped=0

  while kill -0 "$pid" 2>/dev/null; do
    echo -ne "\r[$(ts)] ${B}[..]${Z} $label"
    sleep 1
    elapsed=$((elapsed+1))

    if (( elapsed >= timeout && dumped == 0 )); then
      dumped=1
      echo
      warn "Operation appears blocked (${elapsed}s). Dumping journalctl:"
      echo "---------------- journalctl (last 100 lines) ----------------"
      journalctl -xe --no-pager -n 100 || true
      echo "---------------- end journalctl dump ----------------"
      warn "Continuing to wait..."
      echo
    fi
  done

  wait "$pid" || true
  echo -e "\r[$(ts)] ${G}[✔]${Z} $label"
}

###############################################################################
# Install packages one at a time (reliable, visible)
###############################################################################
install_packages_individually() {
  local pkg
  for pkg in "$@"; do
    spin_with_block_detection "Installing package: $pkg" apt install -y "$pkg" || {
      warn "Package failed or blocked: $pkg"
      warn "Continuing install (see $LOG)"
    }
  done
}

###############################################################################
# Raspberry Pi detection
###############################################################################
IS_RPI=0
if command -v raspi-config >/dev/null 2>&1 &&
   [ -r /proc/device-tree/model ] &&
   grep -qi "raspberry pi" /proc/device-tree/model; then
  IS_RPI=1
fi

echo "=================================================="
echo " Client Simulator Installer v$VERSION"
echo " Platform: $([ "$IS_RPI" -eq 1 ] && echo Raspberry\ Pi || echo Non‑Raspberry)"
echo "=================================================="

###############################################################################
# REMOVE / PURGE MODE
###############################################################################
if [ "$ACTION" = "remove" ]; then
  echo "==== Removal mode ($([ "$PURGE" = "--purge" ] && echo PURGE || echo SAFE)) ===="

  # --- WLAN drivers ---
  if [ -f "$WLAN_STATE" ] && [ "$IS_RPI" -eq 0 ]; then
    while IFS=: read -r DRIVER METHOD; do
      echo "Removing WLAN driver: $DRIVER ($METHOD)"
      case "$METHOD" in
        dkms)     dkms remove "$DRIVER" --all || true ;;
        aircrack) dkms remove rtl8812au --all || true ;;
        morrownr)
          [ -x "/usr/src/wifi-drivers/$DRIVER/remove-driver.sh" ] &&
          "/usr/src/wifi-drivers/$DRIVER/remove-driver.sh" || true ;;
        make) rm -rf "/usr/src/wifi-drivers/$DRIVER" ;;
      esac
    done <"$WLAN_STATE"
    depmod -a || true
    rm -f "$WLAN_STATE"
    ok "WLAN drivers removed"
  fi

  # --- VirtualHere ---
  systemctl stop virtualhereclient.service 2>/dev/null || true
  systemctl disable virtualhereclient.service 2>/dev/null || true
  rm -f /usr/sbin/vhclientx86_64 /etc/systemd/system/virtualhereclient.service
  systemctl daemon-reload
  ok "VirtualHere removed"

  # --- Client simulator ---
  rm -rf /usr/local/scripts "$HOME/client-sim"
  rm -f /etc/xdg/autostart/client-simulator.desktop
  ok "Client simulator removed"

  if [ "$PURGE" = "--purge" ]; then
    apt purge -y lightdm lightdm-gtk-greeter lxqt-session openbox \
                 htop tmux screen lshw qemu-guest-agent sysstat iperf3 || true
    apt autoremove -y || true
    rm -rf "$STATE_DIR"
    ok "Packages and state purged"
  fi

  echo "Removal complete. Reboot recommended."
  exit 0
fi

###############################################################################
# INSTALL PATH
###############################################################################
spin_with_block_detection "Updating package index" apt update
spin_with_block_detection "Upgrading system packages" apt upgrade -y || true
dpkg --configure -a >>"$LOG" 2>&1 || true
apt -f install -y >>"$LOG" 2>&1 || true

# --- Kernel headers ---
KERNEL="$(uname -r)"
HEADER_PKG="linux-headers-$KERNEL"
HEADERS=()
apt-cache show "$HEADER_PKG" >/dev/null 2>&1 \
  && HEADERS+=("$HEADER_PKG") \
  || warn "Kernel headers $HEADER_PKG not available — skipping"

BASE_PKGS=(
  build-essential dkms
  git wget curl jq unzip
  htop tmux screen lshw
  smbclient qemu-guest-agent
  sysstat rsyslog
  bash coreutils util-linux procps ca-certificates
  python3 python3-pip python3-venv python-is-python3 python3-smbus
  net-tools dnsutils iw rfkill i2c-tools
  network-manager systemd-resolved iperf3
  firmware-linux firmware-linux-nonfree firmware-misc-nonfree
  firmware-iwlwifi firmware-atheros firmware-brcm80211
)

install_packages_individually "${HEADERS[@]}" "${BASE_PKGS[@]}"

###############################################################################
# Desktop stack (LXQt + LightDM)
###############################################################################
spin_with_block_detection "Preparing display manager" bash -c '
systemctl stop lightdm 2>/dev/null || true
systemctl stop display-manager 2>/dev/null || true
systemctl mask lightdm display-manager || true
'

install_packages_individually lightdm lightdm-gtk-greeter lxqt-session openbox

spin_with_block_detection "Configuring LightDM autologin" bash -c '
mkdir -p /etc/lightdm/lightdm.conf.d
cat >/etc/lightdm/lightdm.conf.d/20-autologin.conf <<EOF
[Seat:*]
autologin-user=user
user-session=lxqt
EOF
ln -sf /lib/systemd/system/lightdm.service /etc/systemd/system/display-manager.service
systemctl unmask lightdm display-manager
systemctl enable lightdm
'

###############################################################################
# WLAN DRIVERS (FULL SUPERSET, NON-PI ONLY)
###############################################################################
: >"$WLAN_STATE"
record_driver(){ echo "$1:$2" >>"$WLAN_STATE"; }

install_morrownr(){
  git clone "$2" "$1" && cd "$1" &&
  ./install-driver.sh >>"$LOG" 2>&1 &&
  record_driver "$1" morrownr
}

install_aircrack(){
  git clone https://github.com/aircrack-ng/rtl8812au.git &&
  cd rtl8812au &&
  ./dkms-install.sh >>"$LOG" 2>&1 &&
  record_driver rtl8812au aircrack
}

install_make_dkms(){
  git clone "$3" "$1" &&
  cd "$1" &&
  make >>"$LOG" 2>&1 &&
  make install >>"$LOG" 2>&1 &&
  dkms add . >>"$LOG" 2>&1 || true
  dkms install "$2" >>"$LOG" 2>&1 || true
  record_driver "$1" dkms
}

if [ "$IS_RPI" -eq 0 ]; then
  mkdir -p /usr/src/wifi-drivers && cd /usr/src/wifi-drivers

  for e in \
    "8814au https://github.com/morrownr/8814au.git" \
    "8821cu https://github.com/morrownr/8821cu-20210916.git" \
    "8821au-20210708 https://github.com/morrownr/8821au-20210708.git" \
    "8812au-20210820 https://github.com/morrownr/8812au-20210820.git" \
    "88x2bu https://github.com/morrownr/88x2bu-20210702.git" \
    "rtl8852bu https://github.com/morrownr/rtl8852bu.git" \
    "rtl8852cu https://github.com/morrownr/rtl8852cu.git" \
    "rtl8822bu https://github.com/morrownr/rtl8822bu.git"
  do
    set -- $e
    install_morrownr "$1" "$2" || warn "$1 failed"
    cd /usr/src/wifi-drivers
  done

  install_aircrack || warn "rtl8812au failed"
  cd /usr/src/wifi-drivers

  for e in \
    "rtl8188eu 8188eu https://github.com/lwfinger/rtl8188eu.git" \
    "rtl8188fu 8188fu https://github.com/kelebek333/rtl8188fu.git" \
    "rtl8192eu 8192eu https://github.com/Mange/rtl8192eu-linux-driver.git" \
    "rtl8192fu 8192fu https://github.com/heemsoft/rtl8192fu.git" \
    "rtl8723au 8723au https://github.com/lwfinger/rtl8723au.git" \
    "rtl8852au 8852au https://github.com/lwfinger/rtl8852au.git" \
    "mt7601u mt7601u https://github.com/kuba-moo/mt7601u.git"
  do
    set -- $e
    install_make_dkms "$1" "$2" "$3" || warn "$1 failed"
    cd /usr/src/wifi-drivers
  done

  depmod -a || true
else
  warn "Raspberry Pi detected — skipping WLAN drivers"
fi

###############################################################################
# VirtualHere
###############################################################################
spin_with_block_detection "Installing VirtualHere" bash -c '
wget -q https://www.virtualhere.com/sites/default/files/usbclient/vhclientx86_64 &&
wget -q https://www.virtualhere.com/sites/default/files/usbclient/scripts/virtualhereclient.service &&
chmod +x vhclientx86_64 &&
mv vhclientx86_64 /usr/sbin &&
mv virtualhereclient.service /etc/systemd/system/ &&
systemctl daemon-reload &&
systemctl enable virtualhereclient.service
'

###############################################################################
# Client simulator + autostart
###############################################################################
spin_with_block_detection "Deploying client simulator" bash -c '
mkdir -p /usr/local/scripts &&
git clone https://github.com/solutions-hpe/client-sim.git ~/client-sim || true &&
cp ~/client-sim/linux/* /usr/local/scripts/ &&
chmod -R 755 /usr/local/scripts
'

mkdir -p /etc/xdg/autostart
cat >/etc/xdg/autostart/client-simulator.desktop <<EOF
[Desktop Entry]
Type=Application
Name=Client Simulator
Exec=/usr/local/scripts/start-sim.sh
OnlyShowIn=LXQt;
EOF

###############################################################################
# FINAL SUMMARY
###############################################################################
ok "Installation complete"
echo "Reboot required before use"
echo "Log file: $LOG"