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

VERSION="58.8"
LOG=/tmp/client-sim.log
START_TIME=$(date +%s)

exec > >(tee -a "$LOG") 2>&1

# ------------------------------------------------------------
# Formatting helpers
# ------------------------------------------------------------
ts() { date "+%H:%M:%S"; }
ok()   { echo "[$(ts)] ✔ $*"; }
warn() { echo "[$(ts)] ⚠ $*"; }

stage() {
  echo
  echo "[$(ts)] ▶ $*"
}

# ------------------------------------------------------------
# Driver tracking tables
# ------------------------------------------------------------
declare -A DRIVER_STATUS
declare -A DRIVER_REASON

# ------------------------------------------------------------
# Repo guard
# ------------------------------------------------------------
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
    warn "Repo unavailable or private — will not install: $dir"
    DRIVER_STATUS["$dir"]="SKIPPED"
    DRIVER_REASON["$dir"]="Repository unavailable or private"
  fi
}

# ------------------------------------------------------------
# Driver list
# ------------------------------------------------------------
DRIVERS=(
  "8821au-20210708"
  "8821cu-20210916"
  "rtl8192eu-linux-driver"
  "rtl8192fu"
)

DRIVER_REPOS=(
  "https://github.com/morrownr/8821au-20210708.git"
  "https://github.com/morrownr/8821cu-20210916.git"
  "https://github.com/Mange/rtl8192eu-linux-driver.git"
  "https://github.com/heemsoft/rtl8192fu.git"
)

# ------------------------------------------------------------
# Stage: Driver install
# ------------------------------------------------------------
stage "USB Wi‑Fi driver installation"

export MAKEFLAGS="-j$(nproc)"
cd "$HOME"

# Clone phase
for i in "${!DRIVERS[@]}"; do
  clone_if_exists "${DRIVER_REPOS[$i]}" "${DRIVERS[$i]}"
done

# Install phase
for d in "${DRIVERS[@]}"; do

  # Already skipped due to repo issue
  if [ "${DRIVER_STATUS[$d]:-}" = "SKIPPED" ]; then
    warn "Skipping $d — ${DRIVER_REASON[$d]}"
    continue
  fi

  # install-driver.sh method
  if [ -f "$HOME/$d/install-driver.sh" ]; then
    echo "[$(ts)] ▶ Installing $d via install-driver.sh"
    cd "$HOME/$d"
    if sudo ./install-driver.sh NoPrompt; then
      DRIVER_STATUS["$d"]="INSTALLED"
      DRIVER_REASON["$d"]="install-driver.sh"
      ok "Installed $d"
    else
      DRIVER_STATUS["$d"]="FAILED"
      DRIVER_REASON["$d"]="install-driver.sh error"
      warn "Install failed for $d"
    fi
    continue
  fi

  # Makefile method
  if [ -f "$HOME/$d/Makefile" ]; then
    echo "[$(ts)] ▶ Installing $d via make"
    cd "$HOME/$d"
    if sudo make && sudo make install 2>/dev/null; then
      sudo dkms add . 2>/dev/null || true
      DRIVER_STATUS["$d"]="INSTALLED"
      DRIVER_REASON["$d"]="make + dkms"
      ok "Installed $d"
    else
      DRIVER_STATUS["$d"]="FAILED"
      DRIVER_REASON["$d"]="make error"
      warn "Install failed for $d"
    fi
    continue
  fi

  DRIVER_STATUS["$d"]="SKIPPED"
  DRIVER_REASON["$d"]="No supported install method"
  warn "Skipping $d — no supported install method found"
done

sudo depmod -a
ok "Driver installation stage complete"

# ------------------------------------------------------------
# Driver Summary Table
# ------------------------------------------------------------
echo
echo "=================================================="
echo " Driver Installation Summary"
echo "=================================================="
printf "%-28s | %-10s | %s\n" "Driver" "Status" "Details"
printf "%-28s-+-%-10s-+-%s\n" "----------------------------" "----------" "----------------------------"

for d in "${DRIVERS[@]}"; do
  printf "%-28s | %-10s | %s\n" \
    "$d" \
    "${DRIVER_STATUS[$d]:-UNKNOWN}" \
    "${DRIVER_REASON[$d]:-N/A}"
done

echo "=================================================="

# ------------------------------------------------------------
# Final message
# ------------------------------------------------------------
END_TIME=$(date +%s)
echo
echo "=================================================="
echo " ✔ Installation completed"
echo " Total time : $((END_TIME - START_TIME)) seconds"
echo " Action    : A reboot is required before simulations can run"
echo " Log       : $LOG"
echo "=================================================="