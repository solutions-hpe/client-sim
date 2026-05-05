#!/usr/bin/env bash
###############################################################################
# Client Simulator Installer v0.99.4
# WLAN‑correct, DKMS‑aware, Raspberry‑Pi safe
###############################################################################

set -euo pipefail

VERSION="0.99.4"
LOG="/tmp/client-sim-install.log"

# Disable git prompts
export GIT_TERMINAL_PROMPT=0
export GIT_ASKPASS=/bin/false
export SSH_ASKPASS=/bin/false

# Avoid needrestart exits
export NEEDRESTART_MODE=a

# Colors (TTY safe)
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

spin() {
  local label="$1"; shift
  echo -ne "[$(ts)] ${B}[ ]${Z} $label"
  "$@" >>"$LOG" 2>&1 &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    for c in / - \\ \|; do
      echo -ne "\r[$(ts)] ${B}[$c]${Z} $label"
      sleep 0.1
    done
  done
  wait "$pid" || true
  echo -e "\r[$(ts)] ${G}[✔]${Z} $label"
}

# Raspberry Pi detection
IS_RPI=0
if command -v raspi-config >/dev/null 2>&1 &&
   [ -r /proc/device-tree/model ] &&
   grep -qi "raspberry pi" /proc/device-tree/model
then
  IS_RPI=1
fi

echo "=================================================="
echo " Client Simulator Installer v$VERSION"
echo " Platform: $([ "$IS_RPI" -eq 1 ] && echo Raspberry\ Pi || echo Non‑Raspberry)"
echo "=================================================="

###############################################################################
# BASE SYSTEM
###############################################################################

spin "Updating package index" apt update
spin "Upgrading system" apt upgrade -y || true
dpkg --configure -a >>"$LOG" 2>&1 || true
apt -f install -y >>"$LOG" 2>&1 || true

spin "Installing base packages" apt install -y \
  linux-headers-$(uname -r) build-essential dkms \
  git wget curl jq unzip \
  htop tmux screen lshw \
  smbclient qemu-guest-agent rsysstat rsyslog \
  bash coreutils util-linux procps ca-certificates \
  python3 python3-pip python3-venv python-is-python3 python3-smbus \
  net-tools dnsutils iw rfkill i2c-tools \
  network-manager systemd-resolved iperf3 \
  firmware-linux firmware-linux-nonfree firmware-misc-nonfree \
  firmware-iwlwifi firmware-atheros firmware-brcm80211

###############################################################################
# LIGHTDM / LXQT (SAFE)
###############################################################################

spin "Preparing display manager" bash -c '
systemctl stop lightdm 2>/dev/null || true
systemctl stop display-manager 2>/dev/null || true
systemctl mask lightdm display-manager || true
'

spin "Installing LightDM / LXQt" bash -c '
export DEBIAN_FRONTEND=noninteractive
export DEBCONF_NONINTERACTIVE_SEEN=true
apt install -y lightdm lightdm-gtk-greeter lxqt-session openbox
'

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
# WLAN DRIVERS (CORRECT HANDLING)
###############################################################################

declare -A DRIVER_STATUS
declare -A DRIVER_VERSION

install_morrownr() {
  local name="$1" repo="$2"
  git clone "$repo" "$name" || return 1
  cd "$name"
  ./install-driver.sh >>"$LOG" 2>&1
}

install_aircrack() {
  git clone https://github.com/aircrack-ng/rtl8812au.git
  cd rtl8812au
  ./dkms-install.sh >>"$LOG" 2>&1
}

install_make_dkms() {
  local name="$1" module="$2" repo="$3"
  git clone "$repo" "$name" || return 1
  cd "$name"
  make >>"$LOG" 2>&1
  make install >>"$LOG" 2>&1
  dkms add . >>"$LOG" 2>&1 || true
  dkms build "$module" >>"$LOG" 2>&1 || true
  dkms install "$module" >>"$LOG" 2>&1 || true
}

if [ "$IS_RPI" -eq 1 ]; then
  warn "Raspberry Pi detected — skipping USB Wi‑Fi DKMS drivers"
  for d in rtl8188eu rtl8188fu rtl8192eu rtl8192fu rtl8723au rtl8812au rtl8814au \
           rtl8821cu 88x2bu rtl8852bu rtl8852au mt7601u mt76 rtw89; do
    DRIVER_STATUS["$d"]="SKIPPED (Raspberry Pi)"
  done
else
  mkdir -p /usr/src/wifi-drivers
  cd /usr/src/wifi-drivers

  # Morrownr drivers
  for d in \
    8814au=https://github.com/morrownr/8814au.git \
    8821cu=https://github.com/morrownr/8821cu-20210916.git \
    88x2bu=https://github.com/morrownr/88x2bu-20210702.git \
    rtl8852bu=https://github.com/morrownr/rtl8852bu.git
  do
    NAME="${d%%=*}"; REPO="${d##*=}"
    if install_morrownr "$NAME" "$REPO"; then
      DRIVER_STATUS["$NAME"]="INSTALLED"
    else
      DRIVER_STATUS["$NAME"]="FAILED"
    fi
    cd /usr/src/wifi-drivers
  done

  # Aircrack 8812au
  if install_aircrack; then
    DRIVER_STATUS["rtl8812au"]="INSTALLED"
  else
    DRIVER_STATUS["rtl8812au"]="FAILED"
  fi
  cd /usr/src/wifi-drivers

  # Make + DKMS drivers
  install_make_dkms rtl8188eu 8188eu https://github.com/lwfinger/rtl8188eu.git \
    && DRIVER_STATUS["rtl8188eu"]="INSTALLED" \
    || DRIVER_STATUS["rtl8188eu"]="FAILED"

  install_make_dkms rtl8188fu 8188fu https://github.com/kelebek333/rtl8188fu.git \
    && DRIVER_STATUS["rtl8188fu"]="INSTALLED" \
    || DRIVER_STATUS["rtl8188fu"]="FAILED"

  install_make_dkms rtl8192eu 8192eu https://github.com/Mange/rtl8192eu-linux-driver.git \
    && DRIVER_STATUS["rtl8192eu"]="INSTALLED" \
    || DRIVER_STATUS["rtl8192eu"]="FAILED"

  install_make_dkms rtl8192fu 8192fu https://github.com/heemsoft/rtl8192fu.git \
    && DRIVER_STATUS["rtl8192fu"]="INSTALLED" \
    || DRIVER_STATUS["rtl8192fu"]="FAILED"

  install_make_dkms rtl8723au 8723au https://github.com/lwfinger/rtl8723au.git \
    && DRIVER_STATUS["rtl8723au"]="INSTALLED" \
    || DRIVER_STATUS["rtl8723au"]="FAILED"

  install_make_dkms rtl8852au 8852au https://github.com/lwfinger/rtl8852au.git \
    && DRIVER_STATUS["rtl8852au"]="INSTALLED" \
    || DRIVER_STATUS["rtl8852au"]="FAILED"

  install_make_dkms mt7601u mt7601u https://github.com/kuba-moo/mt7601u.git \
    && DRIVER_STATUS["mt7601u"]="INSTALLED" \
    || DRIVER_STATUS["mt7601u"]="FAILED"

  # In‑kernel drivers
  DRIVER_STATUS["mt76"]="SKIPPED (in‑kernel)"
  DRIVER_STATUS["rtw89"]="SKIPPED (in‑kernel)"

  depmod -a || true
fi

###############################################################################
# DRIVER SUMMARY
###############################################################################

echo
echo "=================================================="
echo " Wi‑Fi Driver Installation Summary"
echo "=================================================="
for d in "${!DRIVER_STATUS[@]}"; do
  printf " %-15s : %s\n" "$d" "${DRIVER_STATUS[$d]}"
done
echo "=================================================="

###############################################################################
# VIRTUALHERE
###############################################################################

spin "Installing VirtualHere client" bash -c '
wget -q https://www.virtualhere.com/sites/default/files/usbclient/vhclientx86_64
wget -q https://www.virtualhere.com/sites/default/files/usbclient/scripts/virtualhereclient.service
chmod +x vhclientx86_64
mv vhclientx86_64 /usr/sbin
mv virtualhereclient.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable virtualhereclient.service
'

###############################################################################
# CLIENT SIM + AUTOSTART
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
# FINAL
###############################################################################

ok "Installation complete"
echo "Reboot required before use"
echo "Log: $LOG"