#!/bin/bash

# ============================================================
# HARD DISABLE ALL GIT AUTH PROMPTS (CRITICAL)
# ============================================================
export GIT_TERMINAL_PROMPT=0
export GIT_ASKPASS=/bin/false
export SSH_ASKPASS=/bin/false

set -euo pipefail

VERSION="58.6"
LOG=/tmp/client-sim.log
MAX_RETRIES=5
START_TIME=$(date +%s)

exec > >(tee -a "$LOG") 2>&1

# ============================================================
# Formatting helpers
# ============================================================
ts() { date "+%H:%M:%S"; }
ok()   { echo "[$(ts)] ✔ $*"; }
warn() { echo "[$(ts)] ⚠ WARNING: $*"; }
fail() { echo "[$(ts)] ✖ ERROR: $*"; }

stage() {
  echo
  echo "[$(ts)] ▶ Stage $1/$2: $3"
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
# GitHub repo guard (FIXED)
# ============================================================
declare -A SKIPPED_REPO_NAMES
SKIPPED_REPOS=0

clone_if_exists() {
  local repo_url="$1"
  local dir="$2"

  echo "[$(ts)] ℹ Checking repository: $repo_url"

  if git ls-remote "$repo_url" >/dev/null 2>/tmp/git_err.$$; then
    if [ ! -d "$dir" ]; then
      echo "[$(ts)] ▶ Cloning $repo_url"
      git clone "$repo_url" "$dir"
    else
      echo "[$(ts)] ℹ Repo already present: $dir"
    fi
  else
    warn "Repository unavailable or private — skipping"
    SKIPPED_REPOS=1
    SKIPPED_REPO_NAMES["$dir"]=1
  fi

  rm -f /tmp/git_err.$$
}

TOTAL_STAGES=4

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
# Stage 2: Core packages
# ============================================================
stage 2 $TOTAL_STAGES "Installing core packages"
run_or_retry "sudo apt install -y \
  linux-headers-$(uname -r) dkms git make build-essential"

# ============================================================
# Stage 3: USB Wi‑Fi drivers (QEMU only)
# ============================================================
stage 3 $TOTAL_STAGES "Installing USB Wi‑Fi drivers"
if [ -r /sys/class/dmi/id/sys_vendor ] && grep -q QEMU /sys/class/dmi/id/sys_vendor; then
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
      echo "[$(ts)] ▶ Installing driver: $d"
      cd "$HOME/$d"
      sudo ./install-driver.sh NoPrompt || warn "Driver install failed: $d"
    else
      warn "Skipping driver install for $d"
    fi
  done

  sudo depmod -a
  ok "Driver installation completed"
else
  echo "[$(ts)] ℹ Non-QEMU hardware — skipping driver stage"
fi

# ============================================================
# Stage 4: Completion
# ============================================================
stage 4 $TOTAL_STAGES "Finalization"
END_TIME=$(date +%s)

echo "=================================================="
echo " ✔ Installation completed"
echo " Total time : $((END_TIME - START_TIME)) seconds"
if [ "$SKIPPED_REPOS" -eq 1 ]; then
  echo " Note      : One or more driver repositories were skipped"
fi
echo " Action    : A reboot is required before simulations can run"
echo "=================================================="