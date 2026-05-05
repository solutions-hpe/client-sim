#!/bin/bash
set -euo pipefail

VERSION=".54"
LOG=/tmp/client-sim.log
MAX_RETRIES=5

touch "$LOG"
echo "Installer Version $VERSION" | tee "$LOG"

log() { echo "$(date '+%F %T') - $*" | tee -a "$LOG"; }

#------------------------------------------------------------
# Network recovery helper
#------------------------------------------------------------
recover_network() {
  log "Attempting network recovery"

  systemctl restart NetworkManager 2>/dev/null || true
  nmcli networking off || true
  sleep 2
  nmcli networking on || true

  for dev in $(nmcli -t -f DEVICE,STATE device | awk -F: '$2=="connected"{print $1}'); do
    nmcli device disconnect "$dev" || true
    sleep 1
    nmcli device connect "$dev" || true
  done

  sleep 5
}

#------------------------------------------------------------
# Command runner with network-aware retry
#------------------------------------------------------------
run_or_retry() {
  local attempt=1
  local cmd="$*"

  while :; do
    log "RUN: $cmd (attempt $attempt)"
    set +e
    eval "$cmd" >>"$LOG" 2>&1
    rc=$?
    set -e

    if [ $rc -eq 0 ]; then
      return 0
    fi

    if grep -Ei \
        "temporary failure|could not resolve|network is unreachable|connection timed out|name or service not known" \
        "$LOG" >/dev/null 2>&1 && [ $attempt -lt $MAX_RETRIES ]; then
      log "Detected network-related failure"
      recover_network
      attempt=$((attempt + 1))
    else
      log "Fatal error or max retries exceeded"
      exit 1
    fi
  done
}

#------------------------------------------------------------
# Sudo setup
#------------------------------------------------------------
if ! sudo grep -q "^$USER .*NOPASSWD" /etc/sudoers 2>/dev/null; then
  echo "$USER ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/99-${USER}-nopasswd >/dev/null
  sudo chmod 440 /etc/sudoers.d/99-${USER}-nopasswd
fi

#------------------------------------------------------------
# Base system update
#------------------------------------------------------------
run_or_retry "sudo DEBIAN_FRONTEND=noninteractive apt update"
run_or_retry "sudo DEBIAN_FRONTEND=noninteractive apt upgrade -y"
sudo dpkg --configure -a

#------------------------------------------------------------
# Non-network packages
#------------------------------------------------------------
run_or_retry "sudo DEBIAN_FRONTEND=noninteractive apt install -y \
  linux-headers-$(uname -r) dkms git wget smbclient qemu-guest-agent \
  rsyslog sysstat bash coreutils util-linux procps ca-certificates \
  python3 python3-pip python3-venv python-is-python3 \
  python3-smbus i2c-tools"

#------------------------------------------------------------
# User + LXQt autologin
#------------------------------------------------------------
if id user >/dev/null 2>&1; then
  log \"User 'user' already exists\"
else
  sudo useradd -m -s /bin/bash user
fi

echo "user:password" | sudo chpasswd
sudo usermod -aG sudo,video,audio user

#------------------------------------------------------------
# Display manager handling (robust + logged)
#------------------------------------------------------------
log "Checking existing display manager"

CURRENT_DM="none"
if [ -L /etc/systemd/system/display-manager.service ]; then
  CURRENT_DM=$(readlink -f /etc/systemd/system/display-manager.service || echo unknown)
fi

log "Current display manager: $CURRENT_DM"

log "Installing LightDM"
sudo DEBIAN_FRONTEND=noninteractive apt install -y \
  lightdm lightdm-gtk-greeter lxqt-session openbox || true

TARGET_DM="/lib/systemd/system/lightdm.service"

if [ "$CURRENT_DM" != "$TARGET_DM" ]; then
  log "Switching display manager to LightDM"
  sudo ln -sf "$TARGET_DM" /etc/systemd/system/display-manager.service
else
  log "LightDM already configured as display manager"
fi

sudo mkdir -p /etc/lightdm/lightdm.conf.d
sudo tee /etc/lightdm/lightdm.conf.d/20-autologin.conf >/dev/null <<EOF
[Seat:*]
autologin-user=user
autologin-user-timeout=0
user-session=lxqt
EOF

sudo systemctl daemon-reexec
sudo systemctl enable lightdm || true

#------------------------------------------------------------
# VirtualHere (download only)
#------------------------------------------------------------
run_or_retry "wget -q https://www.virtualhere.com/sites/default/files/usbclient/scripts/virtualhereclient.service"
run_or_retry "wget -q https://www.virtualhere.com/sites/default/files/usbclient/vhclientx86_64"
chmod +x vhclientx86_64
sudo mv vhclientx86_64 /usr/sbin
sudo mv virtualhereclient.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable virtualhereclient.service

#------------------------------------------------------------
# Client-sim scripts
#------------------------------------------------------------
sudo mkdir -p /usr/local/scripts
run_or_retry "git clone https://github.com/solutions-hpe/client-sim.git \$HOME/client-sim || true"
cd "$HOME/client-sim/linux"
sudo cp *.sh *.txt /usr/local/scripts/
sudo chmod -R 755 /usr/local/scripts

#------------------------------------------------------------
# Wi‑Fi drivers (QEMU only)
#------------------------------------------------------------
if [ -r /sys/class/dmi/id/sys_vendor ] && grep -q QEMU /sys/class/dmi/id/sys_vendor; then
  export MAKEFLAGS="-j$(nproc)"
  cd "$HOME"

  for repo in \
    morrownr/8821au-20210708 \
    morrownr/8821cu-20210916 \
    morrownr/8814au \
    morrownr/8812au-20210820 \
    morrownr/rtl8852bu-20250826 \
    morrownr/rtl8852cu-20251113 \
    morrownr/88x2bu-20210702 \
    lwfinger/rtl8188eu \
    kelebek333/rtl8188fu \
    Mange/rtl8192eu-linux-driver \
    heemsoft/rtl8192fu \
    lwfinger/rtl8852au \
    lwfinger/rtl8723au \
    kuba-moo/mt7601u \
    aircrack-ng/mt76 \
    morrownr/rtw89; do
      run_or_retry "git clone https://github.com/$repo || true"
  done
fi

#============================================================
# FINAL NETWORK STACK (LAST)
#============================================================
run_or_retry "sudo DEBIAN_FRONTEND=noninteractive apt install -y \
  network-manager wpasupplicant systemd-resolved dnsutils iw rfkill \
  net-tools iperf3 firmware-iwlwifi firmware-atheros firmware-brcm80211"

sudo systemctl enable NetworkManager
sudo systemctl enable systemd-resolved
sudo ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf

sudo DEBIAN_FRONTEND=noninteractive apt purge -y \
  dhcpcd5 ifupdown connman netplan.io || true

recover_network

log "Install complete — reboot REQUIRED"