#!/bin/sh
# ============================================================
# AUTO-REEXEC UNDER BASH IF RUN WITH sh
# ============================================================
if [ -z "${BASH_VERSION:-}" ]; then
  exec /usr/bin/env bash "$0" "$@"
fi

# ============================================================
# HARD DISABLE ALL GIT AUTH PROMPTS (NON-INTERACTIVE SAFETY)
# ============================================================
export GIT_TERMINAL_PROMPT=0
export GIT_ASKPASS=/bin/false
export SSH_ASKPASS=/bin/false

set -euo pipefail

VERSION="59.4"
LOG=/tmp/client-sim.log
START_TIME=$(date +%s)
MAX_RETRIES=5

exec > >(tee -a "$LOG") 2>&1

# ============================================================
# Formatting helpers
# ============================================================
ts() { date "+%H:%M:%S"; }
ok()    { echo "[$(ts)] ✔ SUCCESS: $*"; }
warn()  { echo "[$(ts)] ⚠ WARNING: $*"; }
info()  { echo "[$(ts)] ℹ INFO: $*"; }
fail()  { echo "[$(ts)] ✖ ERROR: $*"; }

TOTAL_STAGES=6
CURRENT_STAGE=0

stage() {
  CURRENT_STAGE=$((CURRENT_STAGE + 1))
  PCT=$((CURRENT_STAGE * 100 / TOTAL_STAGES))
  echo
  echo "[$(ts)] ▶ Stage ${CURRENT_STAGE}/${TOTAL_STAGES} (${PCT}%) — $*"
}

elapsed() { echo "$(( $(date +%s) - $1 ))s"; }

# ============================================================
# Installer identity header
# ============================================================
echo "=================================================="
echo " Client Simulator Installer v${VERSION}"
echo "=================================================="
echo " Hostname   : $(hostname)"
echo " OS         : $(. /etc/os-release && echo "${NAME} ${VERSION_ID}")"
echo " Kernel     : $(uname -r)"
echo " Shell      : bash ${BASH_VERSION}"
echo " Start time : $(date '+%Y-%m-%d %H:%M:%S')"
echo " Log file   : $LOG"
echo "=================================================="

# ============================================================
# Network recovery helper
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
# Package / system upgrade
# ============================================================
stage "Updating base system"
T1=$(date +%s)
run_or_retry "sudo apt update"
run_or_retry "sudo apt upgrade -y"
sudo dpkg --configure -a
ok "System update complete ($(elapsed $T1))"

# ============================================================
# Base packages (full parity with v58)
# ============================================================
stage "Installing base packages"

run_or_retry "sudo apt install -y \
  linux-headers-$(uname -r) dkms build-essential \
  git wget curl jq \
  smbclient qemu-guest-agent \
  rsyslog sysstat \
  bash coreutils util-linux procps ca-certificates \
  python3 python3-pip python3-venv python-is-python3 python3-smbus \
  i2c-tools net-tools dnsutils iw rfkill"

ok "Base packages installed"

# ============================================================
# Display manager (LightDM, non-interactive & safe)
# ============================================================
stage "Configuring display manager (LightDM)"

info "Masking display manager to prevent auto-start during install"
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
ok "LightDM configured (will start on next boot)"

# ============================================================
# Driver detection helpers
# ============================================================
declare -A DRIVER_STATUS DRIVER_REASON DRIVER_METHOD SKIPPED_REPO_NAMES

is_driver_installed() {
  local module="$1"
  if dkms status 2>/dev/null | grep -qi "$module"; then return 0; fi
  if lsmod | grep -qi "^$module"; then return 0; fi
  if modinfo "$module" >/dev/null 2>&1; then return 0; fi
  return 1
}

clone_if_exists() {
  local repo="$1"
  local dir="$2"
  info "Checking repository: $repo"
  if git ls-remote "$repo" >/dev/null 2>&1; then
    if [ ! -d "$dir" ]; then
      git clone "$repo" "$dir"
      ok "Cloned $dir"
    else
      info "Repo already present: $dir"
    fi
  else
    warn "Repository unavailable or private — skipping $dir"
    DRIVER_STATUS["$dir"]="SKIPPED"
    DRIVER_REASON["$dir"]="Repository unavailable or private"
  fi
}

# ============================================================
# USB Wi‑Fi drivers (FULL LIST)
# ============================================================
stage "Installing USB Wi‑Fi drivers"

export MAKEFLAGS="-j$(nproc)"
cd "$HOME"

DRIVERS=(
  8821au-20210708
  8821cu-20210916
  8814au
  8812au-20210820
  rtl8812au-aircrack-ng
  rtl8852bu-20250826
  rtl8852cu-20251113
  rtl8852au
  88x2bu-20210702
  rtl8188eu
  rtl8188fu
  rtl8723au
  rtl8192eu-linux-driver
  rtl8192fu
  mt7601u
  mt76
  rtw89
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
  8812au
  8821cu
  8814au
  8812au
  8812au
  8852bu
  8852cu
  8852au
  88x2bu
  8188eu
  8188fu
  8723au
  8192eu
  8192fu
  mt7601u
  mt76_usb
  rtw89
)

# Clone if needed
for i in "${!DRIVERS[@]}"; do
  drv="${DRIVERS[$i]}"
  mod="${MODULES[$i]}"
  if is_driver_installed "$mod"; then
    DRIVER_STATUS["$drv"]="INSTALLED"
    DRIVER_METHOD["$drv"]="already present"
    DRIVER_REASON["$drv"]="kernel/dkms"
    info "Skipping $drv — driver already installed"
  else
    clone_if_exists "${REPOS[$i]}" "$drv"
  fi
done

# Install drivers
for i in "${!DRIVERS[@]}"; do
  drv="${DRIVERS[$i]}"
  mod="${MODULES[$i]}"

  [ "${DRIVER_STATUS[$drv]:-}" = "INSTALLED" ] && continue
  [ "${DRIVER_STATUS[$drv]:-}" = "SKIPPED" ] && continue

  if [ -f "$HOME/$drv/install-driver.sh" ]; then
    info "Decision: $drv uses install-driver.sh"
    cd "$HOME/$drv"
    sudo ./install-driver.sh NoPrompt
    DRIVER_STATUS["$drv"]="INSTALLED"
    DRIVER_METHOD["$drv"]="install-driver.sh"
    DRIVER_REASON["$drv"]="Installed successfully"
    ok "Installed $drv"
    continue
  fi

  if [ -f "$HOME/$drv/Makefile" ]; then
    info "Decision: $drv uses make + dkms"
    cd "$HOME/$drv"
    sudo make && sudo make install
    sudo dkms add . 2>/dev/null || true
    DRIVER_STATUS["$drv"]="INSTALLED"
    DRIVER_METHOD["$drv"]="make + dkms"
    DRIVER_REASON["$drv"]="Installed successfully"
    ok "Installed $drv"
    continue
  fi

  DRIVER_STATUS["$drv"]="SKIPPED"
  DRIVER_REASON["$drv"]="No supported install method"
done

sudo depmod -a

# ============================================================
# Network stack (iperf3 preseeding)
# ============================================================
stage "Final network configuration"

info "Preseeding iperf3 to avoid daemon prompt"
echo "iperf3 iperf3/start_daemon boolean false" | sudo debconf-set-selections
sudo systemctl mask iperf3 2>/dev/null || true

run_or_retry "sudo apt install -y \
  network-manager wpasupplicant systemd-resolved iperf3 \
  firmware-iwlwifi firmware-atheros firmware-brcm80211"

sudo systemctl enable NetworkManager
sudo systemctl enable systemd-resolved
sudo ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf

recover_network
ok "Network stack configured"

# ============================================================
# Driver Summary Table
# ============================================================
echo
echo "=================================================="
echo " Driver Installation Summary"
echo "=================================================="
printf "%-32s | %-10s | %-18s | %s\n" \
  "Driver" "Status" "Method" "Details"
printf "%-32s-+-%-10s-+-%-18s-+-%s\n" \
  "--------------------------------" "----------" "------------------" "----------------------------"

for d in "${DRIVERS[@]}"; do
  printf "%-32s | %-10s | %-18s | %s\n" \
    "$d" \
    "${DRIVER_STATUS[$d]:-UNKNOWN}" \
    "${DRIVER_METHOD[$d]:-N/A}" \
    "${DRIVER_REASON[$d]:-N/A}"
done
echo "=================================================="

# ============================================================
# Final Installation Summary
# ============================================================
END_TIME=$(date +%s)

INSTALLED_COUNT=$(printf "%s\n" "${DRIVER_STATUS[@]}" | grep -c INSTALLED || true)
SKIPPED_COUNT=$(printf "%s\n" "${DRIVER_STATUS[@]}" | grep -c SKIPPED || true)

echo
echo "=================================================="
echo " Installation Outcome Summary"
echo "=================================================="
echo " Drivers installed : $INSTALLED_COUNT"
echo " Drivers skipped   : $SKIPPED_COUNT"
echo " Network stack     : NetworkManager + systemd-resolved"
echo " Display manager   : LightDM (enabled, next boot)"
echo " Reboot required   : YES — simulations will not run until reboot"
echo " Total time        : $((END_TIME - START_TIME)) seconds"
echo " Log               : $LOG"
echo "=================================================="