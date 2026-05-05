#!/usr/bin/env bash
###############################################################################
# Client Simulator Installer v0.99.8.1
# FULL integration: base OS, desktop, WLAN, VirtualHere, client-sim
###############################################################################

set -euo pipefail

VERSION="0.99.8.1"
LOG="/tmp/client-sim-install.log"
STATE_DIR="/var/lib/client-sim"
WLAN_STATE="$STATE_DIR/wlan-drivers.state"

mkdir -p "$STATE_DIR"

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
ok(){ echo -e "[$(ts)] ${G}✔${Z} $*"; }
warn(){ echo -e "[$(ts)] ${Y}⚠${Z} $*"; }
err(){ echo -e "[$(ts)] ${R}✖${Z} $*"; }
info(){ echo "[$(ts)] $*"; }

###############################################################################
# Package install with live status (non-scrolling)
###############################################################################
pkg_install_with_status() {
  local label="$1"; shift
  local pkgs=("$@")

  echo -ne "[$(ts)] ${B}[ ]${Z} $label"

  (
    apt install -y \
      -o Dpkg::Use-Pty=0 \
      -o Dpkg::Status-Fd=3 \
      "${pkgs[@]}" \
      3> >(while read -r line; do
        set -- $line
        if [ "$1" = "status" ]; then
          pkg="${5:-}"
          state="${3:-${2:-}}"
          [ -n "$pkg" ] && \
            echo -ne "\r[$(ts)] ${Y}[pkg]${Z} $pkg — $state    "
        fi
      done)
  ) >>"$LOG" 2>&1 || true

  echo -e "\r[$(ts)] ${G}[✔]${Z} $label"
}

###############################################################################
# Spinner for non-apt tasks
###############################################################################
spin() {
  local label="$1"; shift
  echo -ne "[$(ts)] ${B}[ ]${Z} $label"
  "$@" >>"$LOG" 2>&1 &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    echo -ne "\r[$(ts)] ${B}[..]${Z} $label"
    sleep 1
  done
  wait "$pid" || true
  echo -e "\r[$(ts)] ${G}[✔]${Z} $label"
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
# Base system update / repair
###############################################################################
spin "Updating package index" apt update
spin "Upgrading system packages" apt upgrade -y || true
dpkg --configure -a >>"$LOG" 2>&1 || true
apt -f install -y >>"$LOG" 2>&1 || true

###############################################################################
# Kernel header detection
###############################################################################
KERNEL="$(uname -r)"
HEADER_PKG="linux-headers-$KERNEL"
HEADER_LIST=()

if apt-cache show "$HEADER_PKG" >/dev/null 2>&1; then
  HEADER_LIST+=("$HEADER_PKG")
  ok "Kernel headers found: $HEADER_PKG"
else
  warn "Kernel headers $HEADER_PKG not found — skipping"
fi

###############################################################################
# Base packages
###############################################################################
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

pkg_install_with_status "Installing base packages" \
  "${BASE_PKGS[@]}" "${HEADER_LIST[@]}"

###############################################################################
# Desktop stack (LXQt + LightDM, safe)
###############################################################################
spin "Preparing display manager" bash -c '
systemctl stop lightdm 2>/dev/null || true
systemctl stop display-manager 2>/dev/null || true
systemctl mask lightdm display-manager || true
'

pkg_install_with_status "Installing LXQt and LightDM" \
  lightdm lightdm-gtk-greeter lxqt-session openbox

spin "Configuring LightDM autologin" bash -c '
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
# WLAN drivers (FULL Option B, non-Pi only)
###############################################################################
declare -A DRIVER_STATUS
: >"$WLAN_STATE"

record_driver() { echo "$1:$2" >>"$WLAN_STATE"; }

install_morrownr() {
  git clone "$2" "$1" || return 1
  cd "$1"
  ./install-driver.sh >>"$LOG" 2>&1 && record_driver "$1" morrownr
}

install_aircrack() {
  git clone https://github.com/aircrack-ng/rtl8812au.git || return 1
  cd rtl8812au
  ./dkms-install.sh >>"$LOG" 2>&1 && record_driver rtl8812au aircrack
}

install_make_dkms() {
  git clone "$3" "$1" || return 1
  cd "$1"
  make >>"$LOG" 2>&1
  make install >>"$LOG" 2>&1
  dkms add . >>"$LOG" 2>&1 || true
  dkms install "$2" >>"$LOG" 2>&1 || true
  record_driver "$1" dkms
}

if [ "$IS_RPI" -eq 0 ]; then
  mkdir -p /usr/src/wifi-drivers
  cd /usr/src/wifi-drivers

  for entry in \
    "8814au https://github.com/morrownr/8814au.git" \
    "8821cu https://github.com/morrownr/8821cu-20210916.git" \
    "8821au-20210708 https://github.com/morrownr/8821au-20210708.git" \
    "8812au-20210820 https://github.com/morrownr/8812au-20210820.git" \
    "88x2bu https://github.com/morrownr/88x2bu-20210702.git" \
    "rtl8852bu https://github.com/morrownr/rtl8852bu.git" \
    "rtl8852cu https://github.com/morrownr/rtl8852cu.git" \
    "rtl8822bu https://github.com/morrownr/rtl8822bu.git"
  do
    set -- $entry
    install_morrownr "$1" "$2" \
      && DRIVER_STATUS["$1"]="INSTALLED" \
      || DRIVER_STATUS["$1"]="FAILED"
    cd /usr/src/wifi-drivers
  done

  install_aircrack \
    && DRIVER_STATUS["rtl8812au"]="INSTALLED" \
    || DRIVER_STATUS["rtl8812au"]="FAILED"
  cd /usr/src/wifi-drivers

  for entry in \
    "rtl8188eu 8188eu https://github.com/lwfinger/rtl8188eu.git" \
    "rtl8188fu 8188fu https://github.com/kelebek333/rtl8188fu.git" \
    "rtl8192eu 8192eu https://github.com/Mange/rtl8192eu-linux-driver.git" \
    "rtl8192fu 8192fu https://github.com/heemsoft/rtl8192fu.git" \
    "rtl8723au 8723au https://github.com/lwfinger/rtl8723au.git" \
    "rtl8852au 8852au https://github.com/lwfinger/rtl8852au.git" \
    "mt7601u mt7601u https://github.com/kuba-moo/mt7601u.git"
  do
    set -- $entry
    install_make_dkms "$1" "$2" "$3" \
      && DRIVER_STATUS["$1"]="INSTALLED" \
      || DRIVER_STATUS["$1"]="FAILED"
    cd /usr/src/wifi-drivers
  done

  DRIVER_STATUS["mt76"]="SKIPPED (in-kernel)"
  DRIVER_STATUS["rtw89"]="SKIPPED (in-kernel)"
  depmod -a || true
else
  warn "Raspberry Pi detected — skipping WLAN driver installation"
fi

###############################################################################
# WLAN summary
###############################################################################
echo
echo "========== Wi‑Fi Driver Installation Summary =========="
for d in "${!DRIVER_STATUS[@]}"; do
  printf " %-22s : %s\n" "$d" "${DRIVER_STATUS[$d]}"
done
echo "======================================================="

###############################################################################
# VirtualHere
###############################################################################
spin "Installing VirtualHere" bash -c '
wget -q https://www.virtualhere.com/sites/default/files/usbclient/vhclientx86_64
wget -q https://www.virtualhere.com/sites/default/files/usbclient/scripts/virtualhereclient.service
chmod +x vhclientx86_64
mv vhclientx86_64 /usr/sbin
mv virtualhereclient.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable virtualhereclient.service
'

###############################################################################
# Client simulator + autostart
###############################################################################
spin "Deploying client simulator" bash -c '
mkdir -p /usr/local/scripts
git clone https://github.com/solutions-hpe/client-sim.git ~/client-sim || true
cp ~/client-sim/linux/* /usr/local/scripts/
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
# Final
###############################################################################
ok "Installation complete"
echo "Reboot required before use"
echo "Log file: $LOG"