#!/usr/bin/env bash
###############################################################################
# Client Simulator Installer v0.99.3
# WLAN-Complete (Option B) — DKMS drivers enabled only on non-Raspberry Pi
###############################################################################

set -euo pipefail

VERSION="0.99.3"

LOG="/tmp/client-sim-install.log"

# -------------------- Git safety --------------------
export GIT_TERMINAL_PROMPT=0
export GIT_ASKPASS=/bin/false
export SSH_ASKPASS=/bin/false

# -------------------- Colors ------------------------
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

# -------------------- Spinner -----------------------
spin() {
  local label="$1"; shift
  echo -ne "[$(ts)] ${B}[ ]${Z} $label"
  "$@" >>"$LOG" 2>&1 &
  local pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    for c in / - \\ \|; do
      echo -ne "\r[$(ts)] ${B}[$c]${Z} $label"
      sleep 0.1
    done
  done
  wait "$pid" || true
  echo -e "\r[$(ts)] ${G}[✔]${Z} $label"
}

# -------------------- Raspberry Pi detection --------
IS_RPI=0
if command -v raspi-config >/dev/null 2>&1 &&
   [ -r /proc/device-tree/model ] &&
   grep -qi "raspberry pi" /proc/device-tree/model
then
  IS_RPI=1
fi

###############################################################################
# BASE SYSTEM
###############################################################################

info "Client Simulator Installer v$VERSION"
info "Platform: $([ "$IS_RPI" -eq 1 ] && echo Raspberry\ Pi || echo Non‑Raspberry)"

export NEEDRESTART_MODE=a

spin "Updating package index" apt update
spin "Upgrading system packages" apt upgrade -y || true
dpkg --configure -a >>"$LOG" 2>&1 || true
apt -f install -y >>"$LOG" 2>&1 || true

spin "Installing base packages" apt install -y \
  linux-headers-$(uname -r) dkms build-essential \
  git wget curl jq unzip \
  htop tmux screen lshw \
  smbclient qemu-guest-agent rsyslog sysstat \
  bash coreutils util-linux procps ca-certificates \
  python3 python3-pip python3-venv python-is-python3 python3-smbus \
  net-tools dnsutils iw rfkill i2c-tools \
  network-manager systemd-resolved iperf3 \
  firmware-linux firmware-linux-nonfree firmware-misc-nonfree \
  firmware-iwlwifi firmware-atheros firmware-brcm80211

###############################################################################
# LIGHTDM / LXQT (SAFE INSTALL)
###############################################################################

spin "Preparing display manager" bash -c '
systemctl stop lightdm 2>/dev/null || true
systemctl stop display-manager 2>/dev/null || true
systemctl mask lightdm display-manager || true
'

spin "Installing LXQt + LightDM" bash -c '
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
# WLAN DRIVERS (OPTION B — FULL, NON‑PI ONLY)
###############################################################################

declare -A DRIVER_STATUS

DRIVER_REPOS=(
  rtl8188eu=https://github.com/lwfinger/rtl8188eu.git
  rtl8188fu=https://github.com/kelebek333/rtl8188fu.git
  rtl8192eu=https://github.com/Mange/rtl8192eu-linux-driver.git
  rtl8192fu=https://github.com/heemsoft/rtl8192fu.git
  rtl8723au=https://github.com/lwfinger/rtl8723au.git
  rtl8812au=https://github.com/aircrack-ng/rtl8812au.git
  rtl8814au=https://github.com/morrownr/8814au.git
  rtl8821cu=https://github.com/morrownr/8821cu-20210916.git
  88x2bu=https://github.com/morrownr/88x2bu-20210702.git
  rtl8852bu=https://github.com/morrownr/rtl8852bu.git
  rtl8852au=https://github.com/lwfinger/rtl8852au.git
  mt7601u=https://github.com/kuba-moo/mt7601u.git
  mt76=https://github.com/aircrack-ng/mt76.git
)

if [ "$IS_RPI" -eq 1 ]; then
  warn "Raspberry Pi detected — skipping USB Wi‑Fi DKMS drivers"
  for entry in "${DRIVER_REPOS[@]}"; do
    name="${entry%%=*}"
    DRIVER_STATUS["$name"]="SKIPPED (Raspberry Pi)"
  done
else
  spin "Installing USB Wi‑Fi drivers (DKMS)" bash -c '
    set -e
    mkdir -p /usr/src/wifi-drivers
    cd /usr/src/wifi-drivers
  '

  for entry in "${DRIVER_REPOS[@]}"; do
    NAME="${entry%%=*}"
    REPO="${entry##*=}"
    info "Installing driver: $NAME"
    if git clone "$REPO" "$NAME" >>"$LOG" 2>&1; then
      if cd "$NAME"; then
        if make >>"$LOG" 2>&1 && make install >>"$LOG" 2>&1; then
          dkms add . >>"$LOG" 2>&1 || true
          dkms build "$NAME" >>"$LOG" 2>&1 || true
          dkms install "$NAME" >>"$LOG" 2>&1 || true
          DRIVER_STATUS["$NAME"]="INSTALLED"
        else
          DRIVER_STATUS["$NAME"]="BUILD FAILED"
        fi
        cd ..
      else
        DRIVER_STATUS["$NAME"]="DIR ERROR"
      fi
    else
      DRIVER_STATUS["$NAME"]="CLONE FAILED"
    fi
  done

  depmod -a || true
fi

###############################################################################
# DRIVER SUMMARY TABLE
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