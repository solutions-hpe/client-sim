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

VERSION="60.4"
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
else
  C_RESET=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_BLUE=""
fi

# ============================================================
# Helpers
# ============================================================
ts() { date "+%H:%M:%S"; }
msg()  { echo "[$(ts)] $*"; }
ok()   { echo -e "[$(ts)] ${C_GREEN}✔${C_RESET} $*"; }
warn() { echo -e "[$(ts)] ${C_YELLOW}⚠${C_RESET} $*"; }
fail() { echo -e "[$(ts)] ${C_RED}✖${C_RESET} $*"; }

with_spinner() {
  local label="$1"
  shift

  echo -ne "[$(ts)] ${C_BLUE}[ ]${C_RESET} $label"
  "$@" >>"$LOG" 2>&1 &
  pid=$!

  while kill -0 "$pid" 2>/dev/null; do
    for c in "/" "-" "\\" "|"; do
      echo -ne "\r[$(ts)] ${C_BLUE}[$c]${C_RESET} $label"
      sleep 0.1
    done
  done

  wait "$pid"
  rc=$?

  if [ $rc -eq 0 ]; then
    echo -e "\r[$(ts)] ${C_GREEN}[✔]${C_RESET} $label"
  else
    echo -e "\r[$(ts)] ${C_RED}[✖]${C_RESET} $label"
    tail -50 "$LOG"
    exit 1
  fi
}

# ============================================================
# Identify Raspberry Pi hardware
# ============================================================
IS_RPI=0
if \
  command -v raspi-config >/dev/null 2>&1 && \
  [ -r /proc/device-tree/model ] && \
  grep -qi "raspberry pi" /proc/device-tree/model
then
  IS_RPI=1
fi

# ============================================================
# Identity banner
# ============================================================
echo "=================================================="
echo " Client Simulator Installer v$VERSION"
echo "=================================================="
echo " Hostname : $(hostname)"
echo " OS       : $(. /etc/os-release && echo "$NAME $VERSION_ID")"
echo " Kernel   : $(uname -r)"
if [ "$IS_RPI" -eq 1 ]; then
  echo " Hardware : Raspberry Pi"
else
  echo " Hardware : Non‑Raspberry"
fi
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
  linux-headers-$(uname -r) dkms build-essential \
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
if [ "$IS_RPI" -eq 1 ]; then
  with_spinner "Applying Raspberry Pi configuration" sudo bash -c '
    raspi-config nonint do_change_locale en_US.UTF-8
    raspi-config nonint do_wifi_country US
    raspi-config nonint do_ssh 0
  '
  ok "Raspberry Pi configuration applied"
else
  msg "Skipping Pi‑specific configuration"
fi

# ============================================================
# Stage 4: Display Manager (LXQt + LightDM)
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
# Stage 5: Wi‑Fi drivers (SKIPPED on Raspberry Pi)
# ============================================================
if [ "$IS_RPI" -eq 1 ]; then
  warn "Raspberry Pi detected — skipping extra USB Wi‑Fi drivers"
else
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
      elif [ -f "$d/Makefile" ]; then
        ( cd "$d" && sudo make && sudo make install && sudo dkms add . )
      fi
    done

    sudo depmod -a
  '
  ok "USB Wi‑Fi drivers installed"
fi

# ============================================================
# Stage 6: VirtualHere (ALWAYS installed)
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