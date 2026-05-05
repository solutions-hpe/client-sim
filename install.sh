#!/bin/bash

# ============================================================
# HARD DISABLE ALL GIT AUTH PROMPTS (CRITICAL)
# ============================================================
export GIT_TERMINAL_PROMPT=0
export GIT_ASKPASS=/bin/false
export SSH_ASKPASS=/bin/false

set -euo pipefail

VERSION="58.4"
LOG=/tmp/client-sim.log
MAX_RETRIES=5
START_TIME=$(date +%s)

exec > >(tee -a "$LOG") 2>&1

# ============================================================
# Formatting helpers
# ============================================================
ts() { date "+%H:%M:%S"; }

banner() {
  echo
  echo "=================================================="
  echo " Client Simulator Installer v$VERSION"
  echo "=================================================="
  echo
}

stage() {
  echo
  echo "[$(ts)] ▶ Stage $1/$2: $3"
}

ok()   { echo "[$(ts)] ✔ $*"; }
warn() { echo "[$(ts)] ⚠ WARNING: $*"; }
fail() { echo "[$(ts)] ✖ ERROR: $*"; }

elapsed() { echo "$(( $(date +%s) - $1 ))s"; }

banner
echo "[$(ts)] Initializing installer"
echo "[$(ts)] Log file: $LOG"

# ============================================================
# Network recovery helper
# ============================================================
recover_network() {
  warn "Attempting network recovery"
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
  ok "Network recovery completed"
}

# ============================================================
# Network-aware command runner
# ============================================================
run_or_retry() {
  local attempt=1
  local cmd="$*"

  while :; do
    echo "[$(ts)] RUN: $cmd (attempt $attempt)"
    set +e
    eval "$cmd"
    rc=$?
    set -e

    [ $rc -eq 0 ] && return 0

    if grep -Ei \
      "temporary failure|could not resolve|network is unreachable|connection timed out|name or service not known" \
      "$LOG" >/dev/null && [ $attempt -lt $MAX_RETRIES ]; then
      warn "Network-related failure detected"
      recover_network
      attempt=$((attempt + 1))
    else
      fail "Command failed after $attempt attempts"
      exit 1
    fi
  done
}

# ============================================================
# GitHub repo guard (no auth prompts, skip cleanly)
# ============================================================
declare -A SKIPPED_REPO_NAMES
SKIPPED_REPOS=0

clone_if_exists() {
  local repo_url="$1"
  local dir="$2"
  local err

  echo "[$(ts)] ℹ Checking repository: $repo_url"
  err=$(git ls-remote "$repo_url" 2>&1 || true)

  if echo "$err" | grep -qiE \
      "repository not found|authentication failed|could not read Username|403|404"; then
    warn "Repository unavailable or private — skipping"
    SKIPPED_REPOS=1
    SKIPPED_REPO_NAMES["$dir"]=1
    return 0
  fi

  if [ -n "$err" ]; then
    warn "Transient or network error — skipping repo"
    SKIPPED_REPOS=1
    SKIPPED_REPO_NAMES["$dir"]=1
    return 0
  fi

  if [ ! -d "$dir" ]; then
    echo "[$(ts)] ▶ Cloning $repo_url"
    git clone "$repo_url" "$dir"
  else
    echo "[$(ts)] ℹ Repo already present: $dir"
  fi
}

TOTAL_STAGES=6

# ============================================================
# Stage 1: System update
# ============================================================
stage 1 $TOTAL_STAGES "Updating base system"
T1=$(date +%s)
run_or_retry "sudo apt update"
run_or_retry "sudo apt upgrade -y"
sudo dpkg --configure -a
ok "System update complete ($(elapsed $T1))"

# ============================================================
# Stage 2: Core packages (non-network)
# ============================================================
stage 2 $TOTAL_STAGES "Installing core packages"
T2=$(date +%s)
run_or_retry "sudo apt install -y \
  linux-headers-$(uname -r) dkms git wget smbclient qemu-guest-agent \
  rsyslog sysstat bash coreutils util-linux procps ca-certificates \
  python3 python3-pip python3-venv python-is-python3 \
  python3-smbus i2c-tools"
ok "Core packages installed ($(elapsed $T2))"

# ============================================================
# Stage 3: Display Manager (SAFE, NON-INTERACTIVE)
# ============================================================
stage 3 $TOTAL_STAGES "Configuring display manager (LightDM)"

CURRENT_DM="none"
[ -L /etc/systemd/system/display-manager.service ] && \
  CURRENT_DM=$(readlink -f /etc/systemd/system/display-manager.service || echo unknown)
echo "[$(ts)] ℹ Existing display manager: $CURRENT_DM"

sudo systemctl stop lightdm 2>/dev/null || true
sudo systemctl mask lightdm display-manager 2>/dev/null || true

sudo DEBIAN_FRONTEND=noninteractive \
  apt install -y lightdm lightdm-gtk-greeter lxqt-session openbox || true

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

ok "LightDM configured (will start on reboot)"

# ============================================================
# Stage 4: USB Wi-Fi drivers (QEMU only)
# ============================================================
stage 4 $TOTAL_STAGES "Installing USB Wi-Fi drivers"

if [ -r /sys/class/dmi/id/sys_vendor ] && grep -q QEMU /sys/class/dmi/id/sys_vendor; then
  ok "QEMU detected — installing drivers"
  export MAKEFLAGS="-j$(nproc)"
  cd "$HOME"

  clone_if_exists https://github.com/morrownr/8821au-20210708.git 8821au-20210708
  clone_if_exists https://github.com/morrownr/8821cu-20210916.git 8821cu-20210916
  clone_if_exists https://github.com/Mange/rtl8192eu-linux-driver.git rtl8192eu-linux-driver
  clone_if_exists https://github.com/heemsoft/rtl8192fu.git rtl8192fu

  for d in \
    8821au-20210708 \
    8821cu-20210916 \
    rtl8192eu-linux-driver \
    rtl8192fu; do
    if [ -d "$HOME/$d" ] && [ -z "${SKIPPED_REPO_NAMES[$d]:-}" ]; then
      cd "$HOME/$d"
      sudo ./install-driver.sh NoPrompt || warn "Driver install failed: $d"
    else
      warn "Skipping driver install for $d"
    fi
  done

  sudo depmod -a
  ok "Driver installation stage completed"
else
  echo "[$(ts)] ℹ Physical hardware detected — skipping USB Wi-Fi drivers"
fi

# ============================================================
# Stage 5: Final network & DNS stack (iperf3 preseeded)
# ============================================================
stage 5 $TOTAL_STAGES "Final network and DNS configuration"

# Prevent iperf3 from prompting or starting
echo "iperf3 iperf3/start_daemon boolean false" | sudo debconf-set-selections
sudo systemctl mask iperf3 2>/dev/null || true

run_or_retry "sudo apt install -y \
  network-manager wpasupplicant systemd-resolved dnsutils iw rfkill \
  net-tools iperf3 firmware-iwlwifi firmware-atheros firmware-brcm80211"

sudo systemctl enable NetworkManager
sudo systemctl enable systemd-resolved
sudo ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf

recover_network
ok "Network configuration finalized"

# ============================================================
# Stage 6: Completion summary
# ============================================================
stage 6 $TOTAL_STAGES "Finalization"
END_TIME=$(date +%s)

echo
echo "=================================================="
echo " ✔ Installation completed successfully"
echo "=================================================="
echo " Total time : $((END_TIME - START_TIME)) seconds"
echo " Log file  : $LOG"
if [ "$SKIPPED_REPOS" -eq 1 ]; then
  echo " Note      : One or more driver repositories were skipped"
  echo "             due to access restrictions or availability"
fi
echo " Reboot    : STRONGLY recommended"
echo "=================================================="
echo