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

VERSION="59.5"
LOG=/tmp/client-sim.log
START_TIME=$(date +%s)
MAX_RETRIES=5

exec > >(tee -a "$LOG") 2>&1

# ============================================================
# Logging helpers
# ============================================================
ts() { date "+%H:%M:%S"; }
info() { echo "[$(ts)] ℹ INFO: $*"; }
ok()   { echo "[$(ts)] ✔ SUCCESS: $*"; }
warn() { echo "[$(ts)] ⚠ WARNING: $*"; }
fail() { echo "[$(ts)] ✖ ERROR: $*"; }

TOTAL_STAGES=8
CURRENT_STAGE=0

stage() {
  CURRENT_STAGE=$((CURRENT_STAGE + 1))
  PCT=$((CURRENT_STAGE * 100 / TOTAL_STAGES))
  echo
  echo "[$(ts)] ▶ Stage ${CURRENT_STAGE}/${TOTAL_STAGES} (${PCT}%) — $*"
}

elapsed() { echo "$(( $(date +%s) - $1 ))s"; }

# ============================================================
# Identity banner
# ============================================================
echo "=================================================="
echo " Client Simulator Installer v$VERSION"
echo "=================================================="
echo " Hostname : $(hostname)"
echo " OS       : $(. /etc/os-release && echo "${NAME} ${VERSION_ID}")"
echo " Kernel   : $(uname -r)"
echo " Shell    : bash ${BASH_VERSION}"
echo " Started  : $(date '+%Y-%m-%d %H:%M:%S')"
echo " Log      : $LOG"
echo "=================================================="

# ============================================================
# Network helpers
# ============================================================
recover_network() {
  warn "Attempting network recovery"
  systemctl restart NetworkManager 2>/dev/null || true
  nmcli networking off || true
  sleep 2
  nmcli networking on || true
  sleep 5
  info "Network recovery completed"
}

run_or_retry() {
  local attempt=1 cmd="$*"
  while :; do
    info "RUN ($attempt/$MAX_RETRIES): $cmd"
    set +e; eval "$cmd"; rc=$?; set -e
    [ $rc -eq 0 ] && return 0
    if grep -Ei "could not resolve|temporary failure|network is unreachable|timeout" "$LOG" >/dev/null && [ $attempt -lt $MAX_RETRIES ]; then
      recover_network
      attempt=$((attempt+1))
    else
      fail "Command failed: $cmd"
      exit 1
    fi
  done
}

# ============================================================
# Stage 1: System update
# ============================================================
stage "Updating system"
T1=$(date +%s)
run_or_retry "sudo apt update"
run_or_retry "sudo apt upgrade -y"
sudo dpkg --configure -a
ok "System updated ($(elapsed $T1))"

# ============================================================
# Stage 2: Base packages
# ============================================================
stage "Installing base packages"
run_or_retry "sudo apt install -y \
  linux-headers-$(uname -r) dkms build-essential \
  git wget curl jq smbclient qemu-guest-agent \
  rsyslog sysstat \
  bash util-linux procps coreutils ca-certificates \
  python3 python3-pip python3-venv python3-smbus python-is-python3 \
  i2c-tools net-tools dnsutils iw rfkill"
ok "Base packages installed"

# ============================================================
# Stage 3: User setup
# ============================================================
stage "Ensuring user account"
if ! id user &>/dev/null; then
  sudo useradd -m -s /bin/bash user
  echo "user:password" | sudo chpasswd
  ok "User 'user' created"
else
  info "User 'user' already exists"
fi

# ============================================================
# Stage 4: Display manager
# ============================================================
stage "Configuring LightDM"

sudo systemctl stop lightdm 2>/dev/null || true
sudo systemctl mask lightdm display-manager 2>/dev/null || true

sudo DEBIAN_FRONTEND=noninteractive apt install -y \
  lightdm lightdm-gtk-greeter lxqt-session openbox || true

sudo ln -sf /lib/systemd/system/lightdm.service \
  /etc/systemd/system/display-manager.service

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
# Stage 5: USB Wi-Fi drivers (FULL LIST + detection)
# ============================================================
stage "Installing USB Wi-Fi drivers"

declare -A DRIVER_STATUS DRIVER_REASON DRIVER_METHOD

is_driver_installed() {
  dkms status 2>/dev/null | grep -qi "$1" || \
  lsmod | grep -qi "^$1" || \
  modinfo "$1" &>/dev/null
}

DRIVERS=(
  8821au-20210708 8821cu-20210916 8814au 8812au-20210820
  rtl8812au-aircrack-ng rtl8852bu-20250826 rtl8852cu-20251113 rtl8852au
  88x2bu-20210702 rtl8188eu rtl8188fu rtl8723au
  rtl8192eu-linux-driver rtl8192fu mt7601u mt76 rtw89
)

REPOS=(
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

MODULES=(
  8812au 8821cu 8814au 8812au 8812au 8852bu 8852cu 8852au
  88x2bu 8188eu 8188fu 8723au 8192eu 8192fu mt7601u mt76_usb rtw89
)

export MAKEFLAGS="-j$(nproc)"
cd "$HOME"

for i in "${!DRIVERS[@]}"; do
  drv="${DRIVERS[$i]}"
  mod="${MODULES[$i]}"
  if is_driver_installed "$mod"; then
    DRIVER_STATUS["$drv"]="INSTALLED"
    DRIVER_REASON["$drv"]="already present"
    DRIVER_METHOD["$drv"]="kernel/dkms"
    info "Driver $drv already installed"
  else
    git clone "${REPOS[$i]}" "$drv" 2>/dev/null || true
  fi
done

for drv in "${DRIVERS[@]}"; do
  [ "${DRIVER_STATUS[$drv]:-}" = "INSTALLED" ] && continue
  if [ -f "$HOME/$drv/install-driver.sh" ]; then
    cd "$HOME/$drv"
    sudo ./install-driver.sh NoPrompt
    DRIVER_STATUS["$drv"]="INSTALLED"
    DRIVER_METHOD["$drv"]="install-driver.sh"
    DRIVER_REASON["$drv"]="installed"
  elif [ -f "$HOME/$drv/Makefile" ]; then
    cd "$HOME/$drv"
    sudo make && sudo make install && sudo dkms add .
    DRIVER_STATUS["$drv"]="INSTALLED"
    DRIVER_METHOD["$drv"]="make+dkms"
    DRIVER_REASON["$drv"]="installed"
  else
    DRIVER_STATUS["$drv"]="SKIPPED"
    DRIVER_REASON["$drv"]="no install method"
  fi
done

sudo depmod -a
ok "Driver installation finished"

# ============================================================
# Stage 6: Network stack
# ============================================================
stage "Configuring network services"

echo "iperf3 iperf3/start_daemon boolean false" | sudo debconf-set-selections
sudo systemctl mask iperf3 2>/dev/null || true

run_or_retry "sudo apt install -y \
  network-manager wpasupplicant systemd-resolved iperf3 \
  firmware-iwlwifi firmware-atheros firmware-brcm80211"

sudo systemctl enable NetworkManager
sudo systemctl enable systemd-resolved
sudo ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
recover_network
ok "Network configured"

# ============================================================
# Stage 7: VirtualHere
# ============================================================
stage "Installing VirtualHere client"

wget -q https://www.virtualhere.com/sites/default/files/usbclient/vhclientx86_64
wget -q https://www.virtualhere.com/sites/default/files/usbclient/scripts/virtualhereclient.service
chmod +x vhclientx86_64
sudo mv vhclientx86_64 /usr/sbin
sudo mv virtualhereclient.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable virtualhereclient.service
ok "VirtualHere installed"

# ============================================================
# Stage 8: Client simulator + NAS sync
# ============================================================
stage "Installing client simulator scripts"

sudo mkdir -p /usr/local/scripts
git clone https://github.com/solutions-hpe/client-sim.git ~/client-sim || true
sudo cp ~/client-sim/linux/* /usr/local/scripts/
sudo chmod -R 755 /usr/local/scripts

info "Attempting NAS config sync (non-fatal)"
smbclient //nas/scripts -N -c 'lcd /usr/local/scripts; cd /SIM/CONFIG; mget *.conf' || true

ok "Client simulator installed"

# ============================================================
# Driver summary table
# ============================================================
echo
echo "=================================================="
echo " Driver Installation Summary"
echo "=================================================="
printf "%-30s | %-10s | %-18s | %s\n" \
  "Driver" "Status" "Method" "Details"
printf "%-30s-+-%-10s-+-%-18s-+-%s\n" \
  "------------------------------" "----------" "------------------" "----------------------------"

for d in "${DRIVERS[@]}"; do
  printf "%-30s | %-10s | %-18s | %s\n" \
    "$d" \
    "${DRIVER_STATUS[$d]:-UNKNOWN}" \
    "${DRIVER_METHOD[$d]:-N/A}" \
    "${DRIVER_REASON[$d]:-N/A}"
done

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