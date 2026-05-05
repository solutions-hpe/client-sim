#!/bin/bash
set -euo pipefail

VERSION=".47"
LOG=/tmp/client-sim.log
touch "$LOG"
echo "Installer Version $VERSION" | tee "$LOG"

#------------------------------------------------------------
# Sudo setup
#------------------------------------------------------------
if ! sudo grep -q "^$USER .*NOPASSWD" /etc/sudoers 2>/dev/null; then
  echo "$USER ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/99-${USER}-nopasswd >/dev/null
  sudo chmod 440 /etc/sudoers.d/99-${USER}-nopasswd
fi

#------------------------------------------------------------
# Base system update (DO NOT touch networking yet)
#------------------------------------------------------------
sudo DEBIAN_FRONTEND=noninteractive apt update
sudo DEBIAN_FRONTEND=noninteractive apt upgrade -y
sudo dpkg --configure -a

#------------------------------------------------------------
# Install packages WITHOUT enabling / purging network stacks
#------------------------------------------------------------
sudo DEBIAN_FRONTEND=noninteractive apt install -y \
  network-manager \
  wpasupplicant \
  systemd-resolved \
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
  i2c-tools \
  iw \
  rfkill \
  net-tools \
  dnsutils \
  iperf3

#------------------------------------------------------------
# User + LightDM autologin
#------------------------------------------------------------
sudo usermod -aG sudo,netdev,video,audio user

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
# Raspberry Pi–specific (guarded)
#------------------------------------------------------------
if grep -qi raspberry /proc/cpuinfo; then
  sudo raspi-config nonint do_change_locale en_US.UTF-8
  sudo raspi-config nonint do_wifi_country US
fi

#------------------------------------------------------------
# VirtualHere
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
