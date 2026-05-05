#!/bin/bash
set -euo pipefail

VERSION=".51"
LOG=/tmp/client-sim.log
touch "$LOG"
echo "Installer Version $VERSION" | tee "$LOG"

if ! sudo grep -q "^$USER .*NOPASSWD" /etc/sudoers 2>/dev/null; then
  echo "$USER ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/99-${USER}-nopasswd >/dev/null
  sudo chmod 440 /etc/sudoers.d/99-${USER}-nopasswd
fi

sudo DEBIAN_FRONTEND=noninteractive apt update
sudo DEBIAN_FRONTEND=noninteractive apt upgrade -y
sudo dpkg --configure -a

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

if id user >/dev/null 2>&1; then
  echo "User 'user' already exists" | tee -a "$LOG"
else
  sudo useradd -m -s /bin/bash user
fi

echo "user:password" | sudo chpasswd
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

wget -q https://www.virtualhere.com/sites/default/files/usbclient/scripts/virtualhereclient.service
wget -q https://www.virtualhere.com/sites/default/files/usbclient/vhclientx86_64
chmod +x vhclientx86_64
sudo mv vhclientx86_64 /usr/sbin
sudo mv virtualhereclient.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable virtualhereclient.service

sudo mkdir -p /usr/local/scripts

if [ ! -d "$HOME/client-sim" ]; then
  git clone https://github.com/solutions-hpe/client-sim.git "$HOME/client-sim"
fi

cd "$HOME/client-sim/linux"
sudo cp *.sh *.txt /usr/local/scripts/
sudo chmod -R 755 /usr/local/scripts

# ============================================================
# ✅ FINAL NETWORK + DNS INSTALL, CUTOVER, AND IP REFRESH
# ============================================================
sudo DEBIAN_FRONTEND=noninteractive apt install -y \
  network-manager \
  wpasupplicant \
  systemd-resolved \
  dnsutils \
  iw \
  rfkill \
  net-tools \
  iperf3 \
  firmware-iwlwifi \
  firmware-atheros \
  firmware-brcm80211

sudo systemctl enable NetworkManager
sudo systemctl enable systemd-resolved

sudo ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf

sudo DEBIAN_FRONTEND=noninteractive apt purge -y \
  dhcpcd5 \
  ifupdown \
  connman \
  netplan.io || true

# --- Explicit IP refresh (NM-safe) ---
ACTIVE_DEVICES=$(nmcli -t -f DEVICE,STATE device | awk -F: '$2=="connected"{print $1}')

for dev in $ACTIVE_DEVICES; do
  nmcli device disconnect "$dev" || true
  sleep 1
  nmcli device connect "$dev" || true
done

nmcli networking off
sleep 2
nmcli networking on

echo "Install complete — reboot STRONGLY RECOMMENDED" | tee -a "$LOG"