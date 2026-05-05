#!/bin/bash
set -euo pipefail

VERSION=".48"
LOG=/tmp/client-sim.log
touch "$LOG"
echo "Installer Version $VERSION" | tee "$LOG"

#------------------------------------------------------------
# Sudo
#------------------------------------------------------------
if ! sudo grep -q "^$USER .*NOPASSWD" /etc/sudoers 2>/dev/null; then
  echo "$USER ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/99-${USER}-nopasswd >/dev/null
  sudo chmod 440 /etc/sudoers.d/99-${USER}-nopasswd
fi

#------------------------------------------------------------
# Base system update (NO networking changes)
#------------------------------------------------------------
sudo DEBIAN_FRONTEND=noninteractive apt update
sudo DEBIAN_FRONTEND=noninteractive apt upgrade -y
sudo dpkg --configure -a

#------------------------------------------------------------
# Non‑network system packages ONLY
#------------------------------------------------------------
sudo DEBIAN_FRONTEND=noninteractive apt install -y \
  linux-headers-$(uname -r) \
  dkms \
  git \
  wget \
  smbclient \
  qemu-guest-agent \
  rsyslog \
  sysstat \
  bash \
  coreutils \
  util-linux \
  procps \
  ca-certificates \
  python3 \
  python3-pip \
  python3-venv \
  python-is-python3 \
  python3-smbus \
  i2c-tools

#------------------------------------------------------------
# User + LightDM autologin (no network impact)
#------------------------------------------------------------
sudo usermod -aG sudo,video,audio user

sudo DEBIAN_FRONTEND=noninteractive apt install -y \
  lightdm \
  lightdm-gtk-greeter \
  lxqt-session \
  openbox

sudo mkdir -p /etc/lightdm/lightdm.conf.d
sudo tee /etc/lightdm/lightdm.conf.d/20-autologin.conf >/dev/null <<EOF
[Seat:*]
autologin-user=user
autologin-user-timeout=0
user-session=lxqt
EOF

sudo systemctl enable lightdm

#------------------------------------------------------------
# Raspberry Pi specific (safe — no network stack)
#------------------------------------------------------------
if grep -qi raspberry /proc/cpuinfo; then
  sudo raspi-config nonint do_change_locale en_US.UTF-8
  sudo raspi-config nonint do_wifi_country US
fi

#------------------------------------------------------------
# VirtualHere (binary + unit only, not started yet)
#------------------------------------------------------------
wget -q https://www.virtualhere.com/sites/default/files/usbclient/scripts/virtualhereclient.service
wget -q https://www.virtualhere.com/sites/default/files/usbclient/vhclientx86_64
chmod +x vhclientx86_64
sudo mv vhclientx86_64 /usr/sbin
sudo mv virtualhereclient.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable virtualhereclient.service

#------------------------------------------------------------
# Client simulation scripts
#------------------------------------------------------------
sudo mkdir -p /usr/local/scripts

if [ ! -d "$HOME/client-sim" ]; then
  git clone https://github.com/solutions-hpe/client-sim.git "$HOME/client-sim"
fi

cd "$HOME/client-sim/linux"
sudo cp *.sh *.txt /usr/local/scripts/
sudo chmod -R 755 /usr/local/scripts

#============================================================
# 🚫 NOTHING ABOVE THIS LINE TOUCHES NETWORKING 🚫
#============================================================

#------------------------------------------------------------
# ✅ FINAL NETWORK STACK INSTALL & CUTOVER (ABSOLUTE LAST)
#------------------------------------------------------------
sudo DEBIAN_FRONTEND=noninteractive apt install -y \
  network-manager \
  wpasupplicant \
  systemd-resolved \
  iw \
  rfkill \
  net-tools \
  dnsutils \
  iperf3 \
  firmware-iwlwifi \
  firmware-atheros \
  firmware-brcm80211 || true

sudo systemctl enable NetworkManager
sudo systemctl enable systemd-resolved

sudo ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf

sudo DEBIAN_FRONTEND=noninteractive apt purge -y \
  dhcpcd5 \
  ifupdown \
  connman \
  netplan.io || true

echo "Install complete — REBOOT REQUIRED" | tee -a "$LOG"