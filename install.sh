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

VERSION="59.0"
LOG=/tmp/client-sim.log
START_TIME=$(date +%s)
MAX_RETRIES=5

exec > >(tee -a "$LOG") 2>&1

# ============================================================
# Formatting helpers
# ============================================================
ts() { date "+%H:%M:%S"; }
ok()   { echo "[$(ts)] ✔ $*"; }
warn() { echo "[$(ts)] ⚠ $*"; }
fail() { echo "[$(ts)] ✖ $*"; }

stage() {
  echo
  echo "[$(ts)] ▶ $*"
}

elapsed() { echo "$(( $(date +%s) - $1 ))s"; }

echo "=================================================="
echo " Client Simulator Installer v$VERSION"
echo "=================================================="
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
# Driver tracking
# ============================================================
declare -A DRIVER_STATUS
declare -A DRIVER_REASON
declare -A SKIPPED_REPO_NAMES

# ============================================================
# GitHub repo guard
# ============================================================
clone_if_exists() {
  local repo_url="$1"
  local dir="$2"

  echo "[$(ts)] ℹ Checking repository: $repo_url"

  if git ls-remote "$repo_url" >/dev/null 2>&1; then
    if [ ! -d "$dir" ]; then
      git clone "$repo_url" "$dir"
      ok "Cloned $dir"
    else
      echo "[$(ts)] ℹ Repo already present: $dir"
    fi
  else
    warn "Repository unavailable or private — skipping $dir"
    SKIPPED_REPO_NAMES["$dir"]=1
    DRIVER_STATUS["$dir"]="SKIPPED"
    DRIVER_REASON["$dir"]="Repository unavailable or private"
  fi
}

# ============================================================
# Stage 1: System update
# ============================================================
stage "Updating base system"
T1=$(date +%s)
run_or_retry "sudo apt update"
run_or_retry "sudo apt upgrade -y"
sudo dpkg --configure -a
ok "System update complete ($(elapsed $T1))"

# ============================================================
# Stage 2: Base packages (FULL parity)
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
# Stage 3: Display Manager (LightDM, safe)
# ============================================================
stage "Configuring display manager (LightDM)"

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
ok "LightDM configured (will start after reboot)"

# ============================================================
# Stage 4: USB Wi‑Fi drivers (FULL SET)
# ============================================================
stage "Installing USB Wi‑Fi drivers"

export MAKEFLAGS="-j$(nproc)"
cd "$HOME"

DRIVERS=(
  # ---- Original list you provided ----
  "8821au-20210708"
  "8821cu-20210916"
  "8814au"
  "8812au-20210820"
  "rtl8852bu-20250826"
  "rtl8852cu-20251113"
  "rtl8852au"
  "88x2bu-20210702"
  "rtl8188eu"
  "rtl8723au"
  "rtl8192eu-linux-driver"
  "rtl8192fu"

  # ---- Additional high-value repos I identified ----
  "rtl8188fu"
  "mt7601u"
  "mt76"
  "rtw89"
)

REPOS=(
  "https://github.com/morrownr/8821au-20210708.git"
  "https://github.com/morrownr/8821cu-20210916.git"
  "https://github.com/morrownr/8814au.git"
  "https://github.com/morrownr/8812au-20210820.git"
  "https://github.com/morrownr/rtl8852bu-20250826.git"
  "https://github.com/morrownr/rtl8852cu-20251113.git"
  "https://github.com/lwfinger/rtl8852au.git"
  "https://github.com/morrownr/88x2bu-20210702.git"
  "https://github.com/lwfinger/rtl8188eu.git"
  "https://github.com/lwfinger/rtl8723au.git"
  "https://github.com/Mange/rtl8192eu-linux-driver.git"
  "https://github.com/heemsoft/rtl8192fu.git"

  "https://github.com/kelebek333/rtl8188fu.git"
  "https://github.com/kuba-moo/mt7601u.git"
  "https://github.com/aircrack-ng/mt76.git"
  "https://github.com/morrownr/rtw89.git"
)

# ---- Clone phase ----
for i in "${!DRIVERS[@]}"; do
  clone_if_exists "${REPOS[$i]}" "${DRIVERS[$i]}"
done

# ---- Install phase ----
for d in "${DRIVERS[@]}"; do
  if [ "${DRIVER_STATUS[$d]:-}" = "SKIPPED" ]; then
    warn "Skipping $d — ${DRIVER_REASON[$d]}"
    continue
  fi

  if [ -f "$HOME/$d/install-driver.sh" ]; then
    cd "$HOME/$d"
    if sudo ./install-driver.sh NoPrompt; then
      DRIVER_STATUS["$d"]="INSTALLED"
      DRIVER_REASON["$d"]="install-driver.sh"
      ok "Installed $d"
    else
      DRIVER_STATUS["$d"]="FAILED"
      DRIVER_REASON["$d"]="install-driver.sh failed"
    fi
    continue
  fi

  if [ -f "$HOME/$d/Makefile" ]; then
    cd "$HOME/$d"
    if sudo make && sudo make install; then
      sudo dkms add . 2>/dev/null || true
      DRIVER_STATUS["$d"]="INSTALLED"
      DRIVER_REASON["$d"]="make + dkms"
      ok "Installed $d"
    else
      DRIVER_STATUS["$d"]="FAILED"
      DRIVER_REASON["$d"]="make failed"
    fi
    continue
  fi

  DRIVER_STATUS["$d"]="SKIPPED"
  DRIVER_REASON["$d"]="No supported install method"
done

sudo depmod -a
ok "Driver installation completed"

# ============================================================
# Stage 5: Network stack (iperf3 preseeding)
# ============================================================
stage "Final network configuration"

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
printf "%-30s | %-10s | %s\n" "Driver" "Status" "Details"
printf "%-30s-+-%-10s-+-%s\n" "------------------------------" "----------" "----------------------------"

for d in "${DRIVERS[@]}"; do
  printf "%-30s | %-10s | %s\n" \
    "$d" \
    "${DRIVER_STATUS[$d]:-UNKNOWN}" \
    "${DRIVER_REASON[$d]:-N/A}"
done
echo "=================================================="

# ============================================================
# Final message
# ============================================================
END_TIME=$(date +%s)
echo
echo "=================================================="
echo " ✔ Installation completed successfully"
echo " Total time : $((END_TIME - START_TIME)) seconds"
echo " Action    : A reboot is required before simulations can run"
echo " Log       : $LOG"
echo "=================================================="