#!/bin/sh
# ============================================================
# AUTO-REEXEC UNDER BASH IF RUN WITH sh
# ============================================================
if [ -z "${BASH_VERSION:-}" ]; then
  exec /usr/bin/env bash "$0" "$@"
fi

# ============================================================
# HARD DISABLE ALL GIT AUTH PROMPTS
# ============================================================
export GIT_TERMINAL_PROMPT=0
export GIT_ASKPASS=/bin/false
export SSH_ASKPASS=/bin/false

set -euo pipefail

VERSION="59.6"
LOG=/tmp/client-sim.log
START_TIME=$(date +%s)
MAX_RETRIES=5

# Log everything, spinner controls console
exec >>"$LOG" 2>&1

# ============================================================
# Formatting helpers
# ============================================================
ts() { date "+%H:%M:%S"; }

msg()  { echo "[$(ts)] $*"; }
ok()   { echo "[$(ts)] ✔ $*"; }
warn() { echo "[$(ts)] ⚠ $*"; }
fail() { echo "[$(ts)] ✖ $*"; }

# ============================================================
# Spinner helper (Option 3)
# ============================================================
with_spinner() {
  local message="$1"
  shift

  echo -n "[$(ts)] [ ] $message"
  "$@" >>"$LOG" 2>&1 &
  pid=$!

  while kill -0 $pid 2>/dev/null; do
    for c in "/" "-" "\\" "|"; do
      echo -ne "\r[$(ts)] [$c] $message"
      sleep 0.1
    done
  done

  wait $pid
  rc=$?

  if [ $rc -eq 0 ]; then
    echo -e "\r[$(ts)] [✔] $message"
  else
    echo -e "\r[$(ts)] [✖] $message (failed)"
    exit 1
  fi
}

# ============================================================
# Network recovery helper
# ============================================================
recover_network() {
  warn "Recovering network"
  systemctl restart NetworkManager 2>/dev/null || true
  nmcli networking off || true
  sleep 2
  nmcli networking on || true
  sleep 5
}

# ============================================================
# Identity banner
# ============================================================
echo "=================================================="
echo " Client Simulator Installer v$VERSION"
echo "=================================================="
echo " Hostname : $(hostname)"
echo " OS       : $(. /etc/os-release && echo "$NAME $VERSION_ID")"
echo " Kernel   : $(uname -r)"
echo " Started  : $(date)"
echo " Log      : $LOG"
echo "=================================================="

# ============================================================
# Stage 1: System update
# ============================================================
with_spinner "Updating package lists" sudo apt update
with_spinner "Upgrading system packages" sudo apt upgrade -y
sudo dpkg --configure -a
ok "System updated"

# ============================================================
# Stage 2: Base packages
# ============================================================
with_spinner "Installing base dependencies" sudo apt install -y \
  linux-headers-$(uname -r) dkms build-essential \
  git wget curl jq smbclient qemu-guest-agent \
  rsyslog sysstat bash coreutils util-linux procps ca-certificates \
  python3 python3-pip python3-venv python3-smbus python-is-python3 \
  i2c-tools net-tools dnsutils iw rfkill

ok "Base packages installed"

# ============================================================
# Stage 3: User
# ============================================================
if ! id user &>/dev/null; then
  with_spinner "Creating user 'user'" sudo useradd -m -s /bin/bash user
  echo "user:password" | sudo chpasswd
  ok "User created"
else
  msg "User 'user' already exists"
fi

# ============================================================
# Stage 4: Display Manager
# ============================================================
with_spinner "Masking display manager" sudo systemctl mask lightdm display-manager
with_spinner "Installing LightDM/LXQt" sudo apt install -y lightdm lightdm-gtk-greeter lxqt-session openbox

sudo ln -sf /lib/systemd/system/lightdm.service /etc/systemd/system/display-manager.service

sudo mkdir -p /etc/lightdm/lightdm.conf.d
sudo tee /etc/lightdm/lightdm.conf.d/20-autologin.conf >/dev/null <<EOF
[Seat:*]
autologin-user=user
autologin-user-timeout=0
user-session=lxqt
EOF

sudo systemctl unmask lightdm display-manager
sudo systemctl enable lightdm
ok "LightDM configured (starts after reboot)"

# ============================================================
# Stage 5: USB Wi‑Fi Drivers (all repos, detection + install)
# ============================================================
with_spinner "Installing USB Wi‑Fi drivers" bash -c '
set -e
cd "$HOME"
export MAKEFLAGS="-j$(nproc)"

drivers=(
  8821au-20210708 8821cu-20210916 8814au 8812au-20210820
  rtl8812au-aircrack-ng rtl8852bu-20250826 rtl8852cu-20251113 rtl8852au
  88x2bu-20210702 rtl8188eu rtl8188fu rtl8723au
  rtl8192eu-linux-driver rtl8192fu mt7601u mt76 rtw89
)

repos=(
  https://github.com/morrownr/8821au-20210708.git
  https://github.com/morrownr/8821cu-20210916.git
  https://github.com/morrownr/8814au.git
  https://github.com/morrownr/8812au-20210820.git
  https://github.com/aircrack-ng/rtl8812au.git
  https://github.com/morrownr/rtl8852bu-20250826.git
  https://github.com/morrownr/rtl8852cu-20251113.git
  https://github.com/lwfinger/rtl8852au.git
  https://github.com/morrownr/88x2bu-20210702.git
  https://github.com/lwfinger/rtl8188eu.git
  https://github.com/kelebek333/rtl8188fu.git
  https://github.com/lwfinger/rtl8723au.git
  https://github.com/Mange/rtl8192eu-linux-driver.git
  https://github.com/heemsoft/rtl8192fu.git
  https://github.com/kuba-moo/mt7601u.git
  https://github.com/aircrack-ng/mt76.git
  https://github.com/morrownr/rtw89.git
)

for i in "${!drivers[@]}"; do
  d="${drivers[$i]}"
  r="${repos[$i]}"
  git clone "$r" "$d" 2>/dev/null || true
  if [ -f "$d/install-driver.sh" ]; then
    ( cd "$d" && sudo ./install-driver.sh NoPrompt )
  elif [ -f "$d/Makefile" ]; then
    ( cd "$d" && sudo make && sudo make install && sudo dkms add . )
  fi
done

sudo depmod -a
'

ok "Wi‑Fi drivers installed"

# ============================================================
# Stage 6: Network stack
# ============================================================
echo "iperf3 iperf3/start_daemon boolean false" | sudo debconf-set-selections
sudo systemctl mask iperf3

with_spinner "Installing network services" sudo apt install -y \
  network-manager wpasupplicant systemd-resolved iperf3 \
  firmware-iwlwifi firmware-atheros firmware-brcm80211

sudo systemctl enable NetworkManager
sudo systemctl enable systemd-resolved
sudo ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
recover_network
ok "Network configured"

# ============================================================
# Stage 7: VirtualHere
# ============================================================
with_spinner "Installing VirtualHere client" bash -c '
wget -q https://www.virtualhere.com/sites/default/files/usbclient/vhclientx86_64
wget -q https://www.virtualhere.com/sites/default/files/usbclient/scripts/virtualhereclient.service
chmod +x vhclientx86_64
sudo mv vhclientx86_64 /usr/sbin
sudo mv virtualhereclient.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable virtualhereclient.service
'

ok "VirtualHere installed"

# ============================================================
# Stage 8: Client sim + NAS
# ============================================================
with_spinner "Deploying client simulator" bash -c '
sudo mkdir -p /usr/local/scripts
git clone https://github.com/solutions-hpe/client-sim.git ~/client-sim 2>/dev/null || true
sudo cp ~/client-sim/linux/* /usr/local/scripts/
sudo chmod -R 755 /usr/local/scripts
smbclient //nas/scripts -N -c "lcd /usr/local/scripts; cd /SIM/CONFIG; mget *.conf" || true
'

ok "Client simulator deployed"

# ============================================================
# Final summary
# ============================================================
END_TIME=$(date +%s)
echo
echo "=================================================="
echo " ✔ Installation completed successfully"
echo " Total time : $((END_TIME - START_TIME)) seconds"
echo " Action    : A reboot is required before simulations can run"
echo " Log       : $LOG"
echo "=================================================="
