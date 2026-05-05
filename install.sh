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

VERSION="60.0"
LOG=/tmp/client-sim.log
START_TIME=$(date +%s)

# ============================================================
# Logging helpers (console only)
# ============================================================
ts() { date "+%H:%M:%S"; }
msg()  { echo "[$(ts)] $*"; }
ok()   { echo "[$(ts)] ✔ $*"; }
warn() { echo "[$(ts)] ⚠ $*"; }
fail() { echo "[$(ts)] ✖ $*"; }

# ============================================================
# Spinner helper (Option 3 – CORRECTED)
# ============================================================
with_spinner() {
  local message="$1"
  shift

  echo -n "[$(ts)] [ ] $message"
  "$@" >>"$LOG" 2>&1 &
  local pid=$!

  while kill -0 "$pid" 2>/dev/null; do
    for c in "/" "-" "\\" "|"; do
      echo -ne "\r[$(ts)] [$c] $message"
      sleep 0.1
    done
  done

  wait "$pid"
  local rc=$?

  if [ $rc -eq 0 ]; then
    echo -e "\r[$(ts)] [✔] $message"
  else
    echo -e "\r[$(ts)] [✖] $message (failed)"
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
  systemctl restart NetworkManager 2>>"$LOG" || true
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
with_spinner "Installing base packages, firmware, and admin tools" sudo apt install -y \
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
  msg "Not Raspberry Pi hardware – skipping Pi configuration"
fi

# ============================================================
# Stage 4: User setup
# ============================================================
if ! id user &>/dev/null; then
  with_spinner "Creating user '\''user'\''" sudo useradd -m -s /bin/bash user
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
# Stage 6: Network stack
# ============================================================
echo "iperf3 iperf3/start_daemon boolean false" | sudo debconf-set-selections >>"$LOG" 2>&1
sudo systemctl mask iperf3 >>"$LOG" 2>&1

with_spinner "Installing network services" sudo apt install -y \
  network-manager wpasupplicant systemd-resolved iperf3 \
  firmware-iwlwifi firmware-atheros firmware-brcm80211

sudo systemctl enable NetworkManager >>"$LOG" 2>&1
sudo systemctl enable systemd-resolved >>"$LOG" 2>&1
sudo ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf

recover_network
ok "Network configured"

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