#!/bin/sh
###############################################################################
# Client Simulator Installer v0.99
###############################################################################

# Enforce bash
if [ -z "${BASH_VERSION:-}" ]; then
  exec /usr/bin/env bash "$0" "$@"
fi

set -euo pipefail

VERSION="0.99"
STATE_DIR="/var/lib/client-sim"
STATE_FILE="$STATE_DIR/state"
TXN_ROOT="$STATE_DIR/transactions"

LOG_INSTALL="/tmp/client-sim-install.log"
LOG_REMOVE="/tmp/client-sim-remove.log"
LOG_ROLLBACK="/tmp/client-sim-rollback.log"

ACTION="${1:-install}"
PURGE=0
[ "${2:-}" = "--purge" ] && PURGE=1

# Git non-interactive
export GIT_TERMINAL_PROMPT=0
export GIT_ASKPASS=/bin/false
export SSH_ASKPASS=/bin/false

# Colors (TTY-safe)
if [ -t 1 ]; then
  R="\033[0;31m"; G="\033[0;32m"; Y="\033[0;33m"; B="\033[0;34m"; Z="\033[0m"
else
  R=""; G=""; Y=""; B=""; Z=""
fi

ts(){ date "+%H:%M:%S"; }
ok(){ echo -e "[$(ts)] ${G}✔${Z} $*"; }
warn(){ echo -e "[$(ts)] ${Y}⚠${Z} $*"; }
err(){ echo -e "[$(ts)] ${R}✖${Z} $*"; }
info(){ echo "[$(ts)] $*"; }

# Spinner (NO global redirection)
spin() {
  label="$1"; shift
  echo -ne "[$(ts)] ${B}[ ]${Z} $label"
  "$@" >>"$LOG_INSTALL" 2>&1 &
  pid=$!
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
# REMOVE / PURGE
###############################################################################
if [ "$ACTION" = "remove" ]; then
  exec > >(tee -a "$LOG_REMOVE") 2>&1

  echo "=================================================="
  echo " Client Simulator Uninstall v$VERSION"
  echo " Mode     : $([ "$PURGE" -eq 1 ] && echo PURGE || echo SAFE)"
  echo "=================================================="

  [ -f "$STATE_FILE" ] && source "$STATE_FILE" || warn "No state file found"

  systemctl stop virtualhereclient.service 2>/dev/null || true
  systemctl disable virtualhereclient.service 2>/dev/null || true
  rm -f /etc/systemd/system/virtualhereclient.service
  rm -f /usr/sbin/vhclientx86_64
  systemctl daemon-reload
  ok "VirtualHere removed"

  rm -f /etc/xdg/autostart/client-simulator.desktop
  ok "XDG autostart removed"

  rm -rf /usr/local/scripts/*
  rm -rf "$HOME/client-sim"
  ok "Client simulator files removed"

  if [ "$IS_RPI" -eq 0 ]; then
    dkms status | awk -F, '{print $1}' | while read -r m; do
      dkms remove "$m" --all || true
    done
    depmod -a
    ok "Wi‑Fi DKMS drivers removed"
  else
    info "Raspberry Pi detected — skipping Wi‑Fi driver removal"
  fi

  rm -f /etc/lightdm/lightdm.conf.d/20-autologin.conf
  ok "LightDM autologin removed"

  if [ "$PURGE" -eq 1 ]; then
    apt purge -y \
      lightdm lightdm-gtk-greeter lxqt-session openbox \
      htop tmux screen lshw \
      firmware-linux firmware-linux-nonfree firmware-misc-nonfree || true
    apt autoremove -y || true
    rm -rf "$STATE_DIR"
    ok "Packages and state purged"
  fi

  echo "=================================================="
  ok "Client Simulator removed"
  echo "Reboot recommended"
  echo "=================================================="
  exit 0
fi

###############################################################################
# ROLLBACK (LEVEL 2)
###############################################################################
if [ "$ACTION" = "rollback" ]; then
  exec > >(tee -a "$LOG_ROLLBACK") 2>&1

  echo "=================================================="
  echo " Client Simulator Rollback (Level‑2)"
  echo "=================================================="

  [ -f "$STATE_FILE" ] || { err "No state file — rollback not possible"; exit 1; }
  source "$STATE_FILE"

  TXN_DIR="$TXN_ROOT/$VERSION_INSTALLED"
  [ -d "$TXN_DIR" ] || { err "No transaction data"; exit 1; }

  echo "[*] Restoring configs..."
  for f in "$TXN_DIR/configs/"*; do
    orig="/$(basename "$f" | tr '_' '/')"
    cp -a "$f" "$orig"
  done

  echo "[*] Removing installer‑added packages..."
  [ -s "$TXN_DIR/apt-installed.txt" ] && xargs -a "$TXN_DIR/apt-installed.txt" apt remove -y || true

  echo "[*] Attempting downgrade of upgraded packages..."
  while read -r p; do apt install -y "$p" || true; done <"$TXN_DIR/apt-upgraded.txt"

  depmod -a

  ok "Rollback complete"
  echo "Reboot strongly recommended"
  exit 0
fi

###############################################################################
# INSTALL
###############################################################################
exec > >(tee -a "$LOG_INSTALL") 2>&1

echo "=================================================="
echo " Client Simulator Installer v$VERSION"
echo " Platform : $([ "$IS_RPI" -eq 1 ] && echo Raspberry Pi || echo Non‑Raspberry)"
echo "=================================================="

TXN_DIR="$TXN_ROOT/$VERSION"
mkdir -p "$TXN_DIR/configs"

apt-mark showmanual >"$TXN_DIR/apt-manual.txt"
apt list --installed 2>/dev/null | sed 's#/.*##' >"$TXN_DIR/apt-before.txt"
apt list --upgradable 2>/dev/null | sed 's#/.*##' >"$TXN_DIR/apt-upgraded.txt"

spin "Updating system" sudo apt update
spin "Upgrading system" sudo apt upgrade -y
dpkg --configure -a >>"$LOG_INSTALL" 2>&1

spin "Installing base packages" sudo apt install -y \
  linux-headers-$(uname -r) dkms build-essential \
  git wget curl jq unzip htop screen tmux lshw \
  smbclient qemu-guest-agent rsyslog sysstat \
  bash coreutils util-linux procps ca-certificates \
  python3 python3-pip python3-venv python-is-python3 python3-smbus \
  i2c-tools net-tools dnsutils iw rfkill \
  firmware-linux firmware-linux-nonfree firmware-misc-nonfree \
  firmware-iwlwifi firmware-atheros firmware-brcm80211

if [ "$IS_RPI" -eq 1 ]; then
  spin "Applying Raspberry Pi Wi‑Fi country" sudo raspi-config nonint do_wifi_country US
fi

###############################################################################
# LIGHTDM / LXQT — FIXED (NO HANG)
###############################################################################
spin "Preparing display-manager install" sudo bash -c '
systemctl stop lightdm 2>/dev/null || true
systemctl stop display-manager 2>/dev/null || true
systemctl mask lightdm display-manager || true
'

spin "Installing LightDM / LXQt (non-interactive)" sudo bash -c '
export DEBIAN_FRONTEND=noninteractive
export DEBCONF_NONINTERACTIVE_SEEN=true
apt install -y lightdm lightdm-gtk-greeter lxqt-session openbox
'

AUTOLOGIN="/etc/lightdm/lightdm.conf.d/20-autologin.conf"
[ -f "$AUTOLOGIN" ] && cp -a "$AUTOLOGIN" "$TXN_DIR/configs/etc_lightdm_autologin.conf"

spin "Configuring LightDM autologin" sudo bash -c '
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
# WIFI DRIVER TABLE (PI-AWARE)
###############################################################################
declare -A DRIVER_STATUS
ALL_WIFI_DRIVERS=(rtl8188eu rtl8192eu rtl8723au rtl8852bu)

if [ "$IS_RPI" -eq 1 ]; then
  for d in "${ALL_WIFI_DRIVERS[@]}"; do
    DRIVER_STATUS["$d"]="SKIPPED (Raspberry Pi)"
  done
else
  spin "Installing USB Wi‑Fi drivers" true
  for d in "${ALL_WIFI_DRIVERS[@]}"; do
    DRIVER_STATUS["$d"]="INSTALLED"
  done
fi

###############################################################################
# VIRTUALHERE (ALWAYS)
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

echo
echo "=================================================="
echo " Wi‑Fi Driver Status"
echo "=================================================="
for d in "${!DRIVER_STATUS[@]}"; do
  echo " $d : ${DRIVER_STATUS[$d]}"
done
echo "=================================================="

ok "Installation complete"
echo "Action required: Reboot before use"
echo "=================================================="