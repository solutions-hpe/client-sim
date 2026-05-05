#!/bin/bash
set -euo pipefail

VERSION=".55"
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
    if [ $rc -eq 0 ]; then return 0; fi
    if grep -Ei "temporary failure|could not resolve|network is unreachable|connection timed out|name or service not known" "$LOG" >/dev/null && [ $attempt -lt $MAX_RETRIES ]; then
      log "Detected network-related failure"
      recover_network
      attempt=$((attempt+1))
    else
      log "Fatal error or retries exhausted"
      exit 1
    fi
  done
}

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
# Display manager handling (logged & safe)
#------------------------------------------------------------
CURRENT_DM=\"none\"
if [ -L /etc/systemd/system/display-manager.service ]; then
  CURRENT_DM=$(readlink -f /etc/systemd/system/display-manager.service || echo unknown)
fi
log \"Current display manager: $CURRENT_DM\"

sudo DEBIAN_FRONTEND=noninteractive apt install -y \
  lightdm lightdm-gtk-greeter lxqt-session openbox || true

sudo ln -sf /lib/systemd/system/lightdm.service /etc/systemd/system/display-manager.service
sudo mkdir -p /etc/lightdm/lightdm.conf.d
sudo tee /etc/lightdm/lightdm.conf.d/20-autologin.conf >/dev/null <<EOF
[Seat:*]
autologin-user=user
autologin-user-timeout=0
user-session=lxqt
EOF
sudo systemctl enable lightdm || true

#------------------------------------------------------------
# USB Wi‑Fi DRIVERS (QEMU only) – FULL BUILD/INSTALL RESTORED
#------------------------------------------------------------
if [ -r /sys/class/dmi/id/sys_vendor ] && grep -q QEMU /sys/class/dmi/id/sys_vendor; then
  export MAKEFLAGS="-j$(nproc)"
  cd "$HOME"

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

  cd "$HOME/rtl8188eu" && sudo make && sudo make install && sudo dkms add .
  cd "$HOME/rtl8852au" && sudo make && sudo make install && sudo dkms add .
  cd "$HOME/rtl8723au" && sudo make && sudo make install && sudo dkms add .
  cd "$HOME/rtw89" && sudo make && sudo make install && sudo dkms add .
  cd "$HOME/mt7601u" && sudo make && sudo make install
  cd "$HOME/mt76" && sudo make && sudo make install

  sudo depmod -a
fi

#============================================================
# FINAL NETWORK + DNS SETUP (ABSOLUTE LAST)
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
log \"Install complete – reboot REQUIRED\"
