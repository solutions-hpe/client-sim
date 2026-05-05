#!/usr/bin/env bash
###############################################################################
# Client Simulator Installer v0.99.2
###############################################################################

set -euo pipefail

VERSION="0.99.2"

STATE_DIR="/var/lib/client-sim"
STATE_FILE="$STATE_DIR/state"
TXN_ROOT="$STATE_DIR/transactions"

LOG_INSTALL="/tmp/client-sim-install.log"
LOG_REMOVE="/tmp/client-sim-remove.log"
LOG_ROLLBACK="/tmp/client-sim-rollback.log"
LOG_RECOVERY="/tmp/client-sim-recovery.log"

ACTION="${1:-install}"
PURGE="${2:-}"

# Disable git prompts
export GIT_TERMINAL_PROMPT=0
export GIT_ASKPASS=/bin/false
export SSH_ASKPASS=/bin/false

# ANSI colors (TTY-safe)
if [ -t 1 ]; then
  R="\033[0;31m"; G="\033[0;32m"; Y="\033[0;33m"; B="\033[0;34m"; Z="\033[0m"
else
  R=""; G=""; Y=""; B=""; Z=""
fi

ts(){ date "+%H:%M:%S"; }
ok(){   echo -e "[$(ts)] ${G}✔${Z} $*"; }
warn(){ echo -e "[$(ts)] ${Y}⚠${Z} $*"; }
err(){  echo -e "[$(ts)] ${R}✖${Z} $*"; }
info(){ echo "[$(ts)] $*"; }

# Spinner (NO global stdout redirection)
spin() {
  local label="$1"; shift
  echo -ne "[$(ts)] ${B}[ ]${Z} $label"
  "$@" >>"$LOG_INSTALL" 2>&1 &
  local pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    for c in / - \\ \|; do
      echo -ne "\r[$(ts)] ${B}[$c]${Z} $label"
      sleep 0.1
    done
  done
  wait "$pid"
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

###############################################################################
# RECOVERY
###############################################################################
if [ "$ACTION" = "recovery" ]; then
  exec > >(tee "$LOG_RECOVERY") 2>&1
  echo "===== Client Simulator Recovery ====="

  systemctl stop lightdm 2>/dev/null || true
  systemctl stop display-manager 2>/dev/null || true
  systemctl mask lightdm display-manager || true
  ok "Display managers stopped"

  dpkg --configure -a || true
  apt -f install -y || true
  ok "dpkg/apt repaired"

  systemctl enable NetworkManager || true
  systemctl enable systemd-resolved || true
  ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
  systemctl restart NetworkManager || true
  ok "Networking repaired"

  if [ "$IS_RPI" -eq 1 ]; then
    raspi-config nonint do_ssh 0 || true
    ok "SSH ensured (Raspberry Pi)"
  fi

  ok "Recovery complete — reboot recommended"
  exit 0
fi

###############################################################################
# REMOVE / PURGE
###############################################################################
if [ "$ACTION" = "remove" ]; then
  exec > >(tee "$LOG_REMOVE") 2>&1
  echo "===== Client Simulator Uninstall ====="

  systemctl stop virtualhereclient.service 2>/dev/null || true
  systemctl disable virtualhereclient.service 2>/dev/null || true
  rm -f /usr/sbin/vhclientx86_64
  rm -f /etc/systemd/system/virtualhereclient.service
  systemctl daemon-reload
  ok "VirtualHere removed"

  rm -f /etc/xdg/autostart/client-simulator.desktop
  rm -rf /usr/local/scripts/*
  rm -rf "$HOME/client-sim"
  ok "Client simulator removed"

  if [ "$IS_RPI" -eq 0 ]; then
    dkms status | awk -F, '{print $1}' | while read -r m; do
      dkms remove "$m" --all || true
    done
    depmod -a
    ok "Wi‑Fi DKMS cleaned"
  fi

  rm -f /etc/lightdm/lightdm.conf.d/20-autologin.conf

  if [ "$PURGE" = "--purge" ]; then
    apt purge -y lightdm lightdm-gtk-greeter lxqt-session openbox \
                 htop tmux screen lshw \
                 firmware-linux firmware-linux-nonfree firmware-misc-nonfree || true
    apt autoremove -y || true
    rm -rf "$STATE_DIR"
    ok "Packages purged"
  fi

  ok "Uninstall complete — reboot recommended"
  exit 0
fi

###############################################################################
# INSTALL
###############################################################################
echo "===== Client Simulator Installer v$VERSION ====="
echo "Platform: $([ "$IS_RPI" -eq 1 ] && echo Raspberry Pi || echo Non‑Raspberry)"

TXN_DIR="$TXN_ROOT/$VERSION"
mkdir -p "$TXN_DIR/configs"

apt-mark showmanual >"$TXN_DIR/apt-manual.txt"
apt list --installed 2>/dev/null | sed 's#/.*##' >"$TXN_DIR/apt-before.txt"
apt list --upgradable 2>/dev/null | sed 's#/.*##' >"$TXN_DIR/apt-upgraded.txt"

spin "Updating system" apt update
spin "Upgrading system" apt upgrade -y || true

# 🔑 DEFENSIVE PACKAGE FIX (this is the missing piece)
dpkg --configure -a >>"$LOG_INSTALL" 2>&1 || true
apt -f install -y >>"$LOG_INSTALL" 2>&1 || true

spin "Installing base packages" apt install -y \
  linux-headers-$(uname -r) dkms build-essential \
  git wget curl jq unzip htop screen tmux lshw \
  smbclient qemu-guest-agent rsyslog sysstat \
  bash coreutils util-linux procps ca-certificates \
  python3 python3-pip python3-venv python-is-python3 python3-smbus \
  i2c-tools net-tools dnsutils iw rfkill \
  firmware-linux firmware-linux-nonfree firmware-misc-nonfree \
  firmware-iwlwifi firmware-atheros firmware-brcm80211

if [ "$IS_RPI" -eq 1 ]; then
  spin "Setting Raspberry Pi Wi‑Fi country" raspi-config nonint do_wifi_country US
fi

###############################################################################
# LIGHTDM / LXQT — SAFE INSTALL
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

AUTOLOGIN="/etc/lightdm/lightdm.conf.d/20-autologin.conf"
[ -f "$AUTOLOGIN" ] && cp -a "$AUTOLOGIN" "$TXN_DIR/configs/etc_lightdm_autologin.conf"

spin "Configuring LightDM autologin" bash -c '
mkdir -p /etc/lightdm/lightdm.conf.d
cat >'"$AUTOLOGIN"' <<EOF
[Seat:*]
autologin-user=user
user-session=lxqt
EOF
ln -sf /lib/systemd/system/lightdm.service /etc/systemd/system/display-manager.service
systemctl unmask lightdm display-manager
systemctl enable lightdm
'

###############################################################################
# VIRTUALHERE
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
# FINALIZE STATE
###############################################################################
apt list --installed 2>/dev/null | sed 's#/.*##' >"$TXN_DIR/apt-after.txt"
comm -13 <(sort "$TXN_DIR/apt-before.txt") <(sort "$TXN_DIR/apt-after.txt") >"$TXN_DIR/apt-installed.txt"

mkdir -p "$STATE_DIR"
cat >"$STATE_FILE" <<EOF
VERSION_INSTALLED=$VERSION
INSTALLED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
PLATFORM=$([ "$IS_RPI" -eq 1 ] && echo raspberry-pi || echo non-raspberry)
EOF

ok "Installation complete"
echo "Reboot required before use"
echo "Log: $LOG_INSTALL"