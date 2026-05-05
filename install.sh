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

VERSION="60.3"
LOG=/tmp/client-sim.log
START_TIME=$(date +%s)

# ============================================================
# ANSI COLORS (auto-disable if not TTY)
# ============================================================
if [ -t 1 ]; then
  C_RESET="\033[0m"
  C_GREEN="\033[0;32m"
  C_YELLOW="\033[0;33m"
  C_RED="\033[0;31m"
  C_BLUE="\033[0;34m"
  C_GRAY="\033[0;90m"
else
  C_RESET=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_BLUE=""; C_GRAY=""
fi

# ============================================================
# Helpers (console)
# ============================================================
ts() { date "+%H:%M:%S"; }
msg()  { echo "[$(ts)] $*"; }
ok()   { echo -e "[$(ts)] ${C_GREEN}✔${C_RESET} $*"; }
warn() { echo -e "[$(ts)] ${C_YELLOW}⚠${C_RESET} $*"; }
fail() { echo -e "[$(ts)] ${C_RED}✖${C_RESET} $*"; }

# ============================================================
# Spinner helper (correct pattern)
# ============================================================
with_spinner() {
  local message="$1"
  shift

  echo -ne "[$(ts)] ${C_BLUE}[ ]${C_RESET} $message"
  "$@" >>"$LOG" 2>&1 &
  local pid=$!

  while kill -0 "$pid" 2>/dev/null; do
    for c in "/" "-" "\\" "|"; do
      echo -ne "\r[$(ts)] ${C_BLUE}[$c]${C_RESET} $message"
      sleep 0.1
    done
  done

  wait "$pid"
  local rc=$?

  if [ $rc -eq 0 ]; then
    echo -e "\r[$(ts)] ${C_GREEN}[✔]${C_RESET} $message"
  else
    echo -e "\r[$(ts)] ${C_RED}[✖]${C_RESET} $message"
    echo "---- LAST 50 LOG LINES ----"
    tail -50 "$LOG"
    exit 1
  fi
}

# ============================================================
# Network recovery helper
# ============================================================
recover_network() {
  warn "Recovering network"
  systemctl restart NetworkManager >>"$LOG" 2>&1 || true
  nmcli networking off >>"$LOG" 2>&1 || true
  sleep 2
  nmcli networking on >>"$LOG" 2>&1 || true
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
echo

# ============================================================
# Stage 1: System update
# ============================================================
with_spinner "Updating package lists" sudo apt update
with_spinner "Upgrading system packages" sudo apt upgrade -y
sudo dpkg --configure -a >>"$LOG" 2>&1
ok "System updated"

# ============================================================
# Stage 2: Base packages + firmware + admin tools
# ============================================================
with_spinner "Installing base packages and firmware" sudo apt install -y \
  linux-headers-$(uname -r) \
  dkms build-essential \
  git wget curl jq unzip \
  htop screen tmux lshw \
  smbclient qemu-guest-agent \
  rsyslog sysstat \
  bash coreutils util-linux procps ca-certificates \
  python3 python3-pip python3-venv python3-smbus python-is-python3 \
  i2c-tools net-tools dnsutils iw rfkill \
  firmware-linux firmware-linux-nonfree firmware-misc-nonfree \
  firmware-iwlwifi firmware-atheros firmware-brcm80211

ok "Base packages installed"

# ============================================================
# Stage 3: Raspberry Pi config (conditional)
# ============================================================
if command -v raspi-config >/dev/null 2>&1 && \
   grep -qi raspberry /proc/device-tree/model 2>/dev/null; then
  with_spinner "Applying Raspberry Pi configuration" sudo bash -c '
    raspi-config nonint do_change_locale en_US.UTF-8
    raspi-config nonint do_wifi_country US
    raspi-config nonint do_ssh 0
  '
  ok "Raspberry Pi configuration applied"
else
  msg "Not Raspberry Pi hardware — skipping Pi configuration"
fi

# ============================================================
# Stage 4: User setup
# ============================================================
if ! id user &>/dev/null; then
  with_spinner "Creating user 'user'" sudo useradd -m -s /bin/bash user
  echo "user:password" | sudo chpasswd
  ok "User created"
else
  msg "User 'user' already exists"
fi

# ============================================================
# Stage 5: Display Manager
# ============================================================
with_spinner "Configuring LightDM / LXQt" sudo bash -c '
systemctl stop lightdm 2>/dev/null || true
systemctl mask lightdm display-manager 2>/dev/null || true
apt install -y lightdm lightdm-gtk-greeter lxqt-session openbox || true
ln -sf /lib/systemd/system/lightdm.service /etc/systemd/system/display-manager.service
mkdir -p /etc/lightdm/lightdm.conf.d
cat >/etc/lightdm/lightdm.conf.d/20-autologin.conf <<EOF
[Seat:*]
autologin-user=user
autologin-user-timeout=0
user-session=lxqt
EOF
systemctl unmask lightdm display-manager
systemctl enable lightdm
'

ok "LightDM configured (starts after reboot)"

# ============================================================
# Stage 6: USB Wi‑Fi drivers (with status + version capture)
# ============================================================
declare -A DRIVER_STATUS
declare -A DRIVER_METHOD
declare -A DRIVER_VERSION

with_spinner "Installing USB Wi‑Fi drivers" bash -c '
set -e
cd "$HOME"
export MAKEFLAGS="-j$(nproc)"

drivers=(
  rtl8188eu rtl8188fu rtl8723au rtl8192eu-linux-driver rtl8192fu
  8821au-20210708 8821cu-20210916 8814au 8812au-20210820
  rtl8812au-aircrack-ng rtl8852bu-20250826 rtl8852cu-20251113
  rtl8852au 88x2bu-20210702 mt7601u mt76 rtw89
)

repos=(
  https://github.com/lwfinger/rtl8188eu.git
  https://github.com/kelebek333/rtl8188fu.git
  https://github.com/lwfinger/rtl8723au.git
  https://github.com/Mange/rtl8192eu-linux-driver.git
  https://github.com/heemsoft/rtl8192fu.git
  https://github.com/morrownr/8821au-20210708.git
  https://github.com/morrownr/8821cu-20210916.git
  https://github.com/morrownr/8814au.git
  https://github.com/morrownr/8812au-20210820.git
  https://github.com/aircrack-ng/rtl8812au.git
  https://github.com/morrownr/rtl8852bu-20250826.git
  https://github.com/morrownr/rtl8852cu-20251113.git
  https://github.com/lwfinger/rtl8852au.git
  https://github.com/morrownr/88x2bu-20210702.git
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
    mod=$(modinfo -F name "$d" 2>/dev/null || true)
    ver=$(modinfo -F version "$mod" 2>/dev/null || echo "unknown")
    echo "$d INSTALLED install-driver.sh $ver"
  elif [ -f "$d/Makefile" ]; then
    ( cd "$d" && sudo make && sudo make install && sudo dkms add . )
    mod=$(ls "$d"/*.ko 2>/dev/null | head -1 | xargs -n1 basename | sed "s/\\.ko//")
    ver=$(modinfo -F version "$mod" 2>/dev/null || echo "unknown")
    echo "$d INSTALLED make+dkms $ver"
  else
    echo "$d SKIPPED none -"
  fi
done

sudo depmod -a
' > /tmp/driver_status.txt

ok "USB Wi‑Fi drivers processed"

while read -r d status method version; do
  DRIVER_STATUS["$d"]="$status"
  DRIVER_METHOD["$d"]="$method"
  DRIVER_VERSION["$d"]="$version"
done </tmp/driver_status.txt

# ============================================================
# Stage 7: Driver Success Table (color‑coded)
# ============================================================
echo
echo "=================================================="
echo " Driver Installation Summary"
echo "=================================================="
printf "%-28s | %-10s | %-15s | %-10s\n" "Driver" "Status" "Method" "Version"
printf "%-28s-+-%-10s-+-%-15s-+-%-10s\n" "----------------------------" "----------" "---------------" "----------"

for d in "${!DRIVER_STATUS[@]}"; do
  status="${DRIVER_STATUS[$d]}"
  case "$status" in
    INSTALLED) sc="$C_GREEN$status$C_RESET" ;;
    SKIPPED)   sc="$C_YELLOW$status$C_RESET" ;;
    *)         sc="$C_RED$status$C_RESET" ;;
  esac

  printf "%-28s | %-10b | %-15s | %-10s\n" \
    "$d" "$sc" "${DRIVER_METHOD[$d]}" "${DRIVER_VERSION[$d]}"
done
echo "=================================================="

# ============================================================
# Final summary
# ============================================================
END_TIME=$(date +%s)
echo
echo "=================================================="
echo -e " ${C_GREEN}✔${C_RESET} Installation completed successfully"
echo " Total time : $((END_TIME - START_TIME)) seconds"
echo " Action    : A reboot is required before simulations can run"
echo " Log       : $LOG"
echo "=================================================="