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
if ! id user >/dev/null 2>&1; then
  sudo useradd -m -s /bin/bash user
fi

echo "user:password" | sudo chpasswd
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
#------------------------------------------------------------
sudo mkdir -p /usr/local/scripts

if [ ! -d "$HOME/client-sim" ]; then
  git clone https://github.com/solutions-hpe/client-sim.git "$HOME/client-sim"
fi

cd "$HOME/client-sim/linux"
sudo cp *.sh *.txt /usr/local/scripts/
sudo chmod -R 755 /usr/local/scripts

#------------------------------------------------------------
# USB Wi‑Fi drivers (QEMU only)
#------------------------------------------------------------
if [ -r /sys/class/dmi/id/sys_vendor ] && grep -q QEMU /sys/class/dmi/id/sys_vendor; then
  export MAKEFLAGS="-j$(nproc)"
  cd "$HOME"

  sudo DEBIAN_FRONTEND=noninteractive apt install -y \
    firmware-iwlwifi \
    firmware-atheros \
    firmware-brcm80211 || true

  git clone https://github.com/morrownr/8821au-20210708.git
  git clone https://github.com/morrownr/8821cu-20210916.git
  git clone https://github.com/morrownr/8814au.git
  git clone https://github.com/morrownr/8812au-20210820.git
  git clone https://github.com/morrownr/rtl8852bu-20250826.git
  git clone https://github.com/morrownr/rtl8852cu-20251113.git
  git clone https://github.com/morrownr/88x2bu-20210702.git
  git clone https://github.com/lwfinger/rtl8188eu.git
  git clone https://github.com/kelebek333/rtl8188fu.git
  git clone https://github.com/Mange/rtl8192eu-linux-driver.git
  git clone https://github.com/heemsoft/rtl8192fu.git
  git clone https://github.com/lwfinger/rtl8852au.git
  git clone https://github.com/lwfinger/rtl8723au.git
  git clone https://github.com/kuba-moo/mt7601u.git
  git clone https://github.com/aircrack-ng/mt76.git
  git clone https://github.com/morrownr/rtw89.git

  for d in \
    8821au-20210708 \
    8821cu-20210916 \
    8814au \
    8812au-20210820 \
    rtl8852bu-20250826 \
    rtl8852cu-20251113 \
    88x2bu-20210702 \
    rtl8188fu \
    rtl8192eu-linux-driver \
    rtl8192fu; do
      cd "$HOME/$d"
      sudo ./install-driver.sh NoPrompt || true
  done

  cd "$HOME/rtl8188eu" && sudo make && sudo make install && sudo dkms add . || true
  cd "$HOME/rtl8852au" && sudo make && sudo make install && sudo dkms add . || true
  cd "$HOME/rtl8723au" && sudo make && sudo make install && sudo dkms add . || true
  cd "$HOME/rtw89" && sudo make && sudo make install && sudo dkms add . || true
  cd "$HOME/mt7601u" && sudo make && sudo make install || true
  cd "$HOME/mt76" && sudo make && sudo make install || true

  sudo depmod -a
fi

#------------------------------------------------------------
# ✅ FINAL NETWORK STACK CUTOVER (LAST)
#------------------------------------------------------------
sudo systemctl enable NetworkManager --now
sudo systemctl enable systemd-resolved --now
sudo ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf

sudo DEBIAN_FRONTEND=noninteractive apt purge -y \
  dhcpcd5 \
  ifupdown \
  connman \
  netplan.io || true

echo "Install complete — reboot recommended" | tee -a "$LOG"