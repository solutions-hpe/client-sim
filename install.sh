#!/usr/bin/env bash
###############################################################################
# Client Simulator Installer v0.99.39
#
# PATCH OVER v0.99.38
# -----------------------------------------------------------------------------
# ✅ Defensively ensure driver log directory & file exist before Phase 2
#
# ROLLBACK
# -----------------------------------------------------------------------------
# v0.99.37 remains the locked rollback baseline
###############################################################################

###############################################################################
# Ensure Bash + PATH hardening
###############################################################################
if [ -z "${BASH_VERSION:-}" ]; then
  echo "[INFO] Re-running installer with bash..."
  exec bash "$0" "$@"
fi
export PATH="/usr/sbin:/sbin:/usr/bin:/bin:$PATH"
set -euo pipefail

VERSION="0.99.39"

###############################################################################
# Global state and logging
###############################################################################
STATE_DIR="/var/lib/client-sim"
LOG="/var/log/client-sim-install.log"
WLAN_STATE="$STATE_DIR/wlan-drivers.state"
REBOOT_LOG="$STATE_DIR/reboot-requests.log"
DRIVER_LOG="$STATE_DIR/driver-install.log"
CLIENTSIM_DIR="/usr/local/scripts"
CLIENTSIM_REPO="/home/user/client-sim"

ACTION="${1:-install}"
PURGE="${2:-}"

mkdir -p "$STATE_DIR" /var/log
: >"$LOG"
: >"$REBOOT_LOG"
: >"$DRIVER_LOG"
chmod 644 "$LOG" "$REBOOT_LOG" "$DRIVER_LOG"

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export GIT_TERMINAL_PROMPT=0

###############################################################################
# WLAN driver definitions — EDIT HERE
###############################################################################
WLAN_DRIVERS=(
  "8814au|morrownr|https://github.com/morrownr/8814au.git|8814au"
  "8821cu|morrownr|https://github.com/morrownr/8821cu-20210916.git|8821cu"
  "rtl8812au|aircrack|https://github.com/aircrack-ng/rtl8812au.git|rtl8812au"
  "rtl8188eu|dkms|https://github.com/lwfinger/rtl8188eu.git|8188eu"
)

###############################################################################
# UI + spinner helpers
###############################################################################
if [ -t 1 ]; then
  G="\033[0;32m"; Y="\033[0;33m"; B="\033[0;34m"; Z="\033[0m"
else
  G=""; Y=""; B=""; Z=""
fi

ts(){ date "+%H:%M:%S"; }
ts_epoch(){ date "+%s"; }
info(){ echo "[$(ts)] $*" | tee -a "$LOG"; }
warn(){ echo -e "[$(ts)] ${Y}WARN:${Z} $*" | tee -a "$LOG"; }
ok(){   echo -e "[$(ts)] ${G}OK:${Z} $*" | tee -a "$LOG"; }

SPIN_BLOCK_TIMEOUT=120
spin() {
  local label="$1"; shift
  local frames=("." ".." "...")
  local i=0
  echo -ne "[$(ts)] ${B}[ ]${Z} $label"
  "$@" >>"$LOG" 2>&1 &
  pid=$!
  local elapsed=0 dumped=0
  while kill -0 "$pid" 2>/dev/null; do
    echo -ne "\r[$(ts)] ${B}[${frames[$i]}]${Z} $label"
    i=$(( (i+1) % 3 ))
    sleep 1
    elapsed=$((elapsed+1))
    if (( elapsed >= SPIN_BLOCK_TIMEOUT && dumped == 0 )); then
      dumped=1
      warn "Operation running long; dumping journal"
      journalctl -xe --no-pager -n 100 >>"$LOG" 2>&1 || true
    fi
  done
  wait "$pid" || true
  echo -e "\r[$(ts)] ${G}[✔]${Z} $label"
}

install_pkgs() {
  for p in "$@"; do
    spin "Installing package: $p" apt install -y "$p" || warn "Issue installing $p"
  done
}

###############################################################################
# Raspberry Pi detection
###############################################################################
IS_RPI=0
if command -v raspi-config >/dev/null 2>&1 &&
   grep -qi "raspberry pi" /proc/device-tree/model 2>/dev/null; then
  IS_RPI=1
  info "Raspberry Pi detected — WLAN drivers will be skipped"
fi

###############################################################################
# Remove / purge mode
###############################################################################
if [ "$ACTION" = "remove" ]; then
  info "Removing client-sim components"

  if [ "$IS_RPI" -eq 0 ] && [ -f "$WLAN_STATE" ]; then
    while IFS=: read -r MOD TYPE STATUS; do
      info "Removing WLAN driver $MOD ($TYPE)"
      case "$TYPE" in
        dkms|aircrack) dkms remove "$MOD" --all || true ;;
        morrownr)
          [ -x "/usr/src/wifi-drivers/$MOD/remove-driver.sh" ] &&
          "/usr/src/wifi-drivers/$MOD/remove-driver.sh" || true ;;
      esac
    done <"$WLAN_STATE"
    depmod -a || true
    rm -f "$WLAN_STATE"
  fi

  rm -rf "$CLIENTSIM_DIR" "$CLIENTSIM_REPO"
  rm -f /etc/xdg/autostart/*.desktop

  systemctl stop virtualhereclient.service 2>/dev/null || true
  systemctl disable virtualhereclient.service 2>/dev/null || true
  rm -f /usr/sbin/vhclientx86_64
  rm -f /etc/systemd/system/virtualhereclient.service
  systemctl daemon-reload || true

  if [ "$PURGE" = "--purge" ]; then
    info "Purging packages installed by script"
    apt purge -y \
      lightdm lightdm-gtk-greeter lxqt-session openbox \
      build-essential dkms git rfkill \
      firmware-linux firmware-linux-nonfree firmware-misc-nonfree \
      firmware-iwlwifi firmware-atheros \
      network-manager systemd-resolved iperf3 || true
    apt autoremove -y || true
    rm -rf "$STATE_DIR"
  fi

  ok "Removal complete"
  exit 0
fi

###############################################################################
# Base update
###############################################################################
spin "Updating package index" apt update
spin "Upgrading base system" apt upgrade -y || true
spin "Configuring packages" dpkg --configure -a || true
spin "Fixing dependencies" apt -f install -y || true

###############################################################################
# Phase 1 — driver prerequisites
###############################################################################
info "Phase 1: Driver prerequisites"
HEADERS=()
HEADER="linux-headers-$(uname -r)"
apt-cache show "$HEADER" >/dev/null 2>&1 && HEADERS+=("$HEADER")
install_pkgs build-essential dkms git rfkill "${HEADERS[@]}"

###############################################################################
# Phase 2 — WLAN drivers (spinner-enhanced, reboot suppressed)
###############################################################################
info "Phase 2: WLAN drivers (spinner-enhanced)"

# ✅ DEFENSIVE FIX (NEW)
mkdir -p "$STATE_DIR"
touch "$DRIVER_LOG"

SUPPRESS="$(mktemp -d)"
for cmd in reboot shutdown poweroff halt; do
  echo -e "#!/bin/sh\necho \"driver requested reboot: $cmd\" >>'$REBOOT_LOG'\nexit 0" >"$SUPPRESS/$cmd"
  chmod +x "$SUPPRESS/$cmd"
done
echo -e "#!/bin/sh\necho \"driver requested systemctl reboot\" >>'$REBOOT_LOG'\nexit 0" >"$SUPPRESS/systemctl"
chmod +x "$SUPPRESS/systemctl"

OLD_PATH="$PATH"
export PATH="$SUPPRESS:$PATH"

: >"$WLAN_STATE"
mkdir -p /usr/src/wifi-drivers
cd /usr/src/wifi-drivers

if [ "$IS_RPI" -eq 0 ]; then
  for d in "${WLAN_DRIVERS[@]}"; do
    IFS='|' read -r NAME TYPE REPO MOD <<<"$d"

    start_ts="$(ts_epoch)"
    info "Starting WLAN driver: $NAME"

    TMPLOG="$(mktemp)"
    STATUS="FAILED"

    spin "Installing WLAN driver: $NAME" bash -c "
      case \"$TYPE\" in
        morrownr)
          git clone \"$REPO\" \"$NAME\" &&
          (cd \"$NAME\" && ./install-driver.sh)
          ;;
        aircrack)
          git clone \"$REPO\" \"$NAME\" &&
          (cd \"$NAME\" && ./dkms-install.sh)
          ;;
        dkms)
          git clone \"$REPO\" \"$NAME\" &&
          (cd \"$NAME\" &&
           make &&
           make install &&
           dkms add . || true &&
           dkms install \"$MOD\" || true)
          ;;
      esac
    " >\"$TMPLOG\" 2>&1 && STATUS=\"INSTALLED\"

    grep -qi \"already\" \"$TMPLOG\" && STATUS=\"ALREADY_INSTALLED\"

    end_ts=\"$(ts_epoch)\"
    echo \"$start_ts,$end_ts,$NAME,$TYPE,$STATUS\" >>\"$DRIVER_LOG\"

    cat \"$TMPLOG\" >>\"$LOG\"
    rm -f \"$TMPLOG\"

    echo \"$MOD:$TYPE:$STATUS\" >>\"$WLAN_STATE\"
  done
  depmod -a || true
fi

export PATH="$OLD_PATH"
rm -rf "$SUPPRESS"

###############################################################################
# Phase 3a — firmware
###############################################################################
info "Phase 3a: Firmware"
install_pkgs firmware-linux firmware-linux-nonfree firmware-misc-nonfree \
             firmware-iwlwifi firmware-atheros

###############################################################################
# LightDM install + autologin + hardening
###############################################################################
info "Installing and configuring LightDM"
echo "/usr/sbin/lightdm" > /etc/X11/default-display-manager
install_pkgs lightdm lightdm-gtk-greeter lxqt-session openbox

mkdir -p /etc/lightdm/lightdm.conf.d
cat >/etc/lightdm/lightdm.conf.d/20-autologin.conf <<EOF
[Seat:*]
autologin-user=user
user-session=lxqt
EOF

mkdir -p /etc/systemd/system/lightdm.service.d
cat >/etc/systemd/system/lightdm.service.d/override.conf <<EOF
[Service]
Restart=always
RestartSec=2
StartLimitIntervalSec=0
[Unit]
Conflicts=getty@tty7.service
After=systemd-user-sessions.service
EOF

systemctl daemon-reload
systemctl enable lightdm

###############################################################################
# Client-sim deployment (repo is source of truth)
###############################################################################
info "Deploying client-sim"
mkdir -p "$CLIENTSIM_DIR"
git clone https://github.com/solutions-hpe/client-sim.git "$CLIENTSIM_REPO" || true
cp -r "$CLIENTSIM_REPO/linux/"* "$CLIENTSIM_DIR/"
chmod +x "$CLIENTSIM_DIR"/*

info "Installing client-sim autostart entries from repo"
mkdir -p /etc/xdg/autostart
cp -f "$CLIENTSIM_REPO/linux/"*.desktop /etc/xdg/autostart/ || true
chown root:root /etc/xdg/autostart/*.desktop
chmod 644 /etc/xdg/autostart/*.desktop

###############################################################################
# VirtualHere
###############################################################################
info "Installing VirtualHere"
spin "Downloading VirtualHere client" wget -q https://www.virtualhere.com/sites/default/files/usbclient/vhclientx86_64
spin "Downloading VirtualHere service" wget -q https://www.virtualhere.com/sites/default/files/usbclient/scripts/virtualhereclient.service
chmod +x vhclientx86_64
mv vhclientx86_64 /usr/sbin/
mv virtualhereclient.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable virtualhereclient.service

###############################################################################
# Phase 3b — network (LAST)
###############################################################################
info "Phase 3b: Network"
install_pkgs network-manager systemd-resolved iperf3

###############################################################################
# Post-install health check
###############################################################################
info "Running post-install health check"

health_ok=true

check_service() {
  local svc="$1"
  if systemctl is-active --quiet "$svc"; then
    ok "$svc is active"
  else
    warn "$svc is NOT active"
    health_ok=false
  fi
}

check_service lightdm
check_service virtualhereclient.service
check_service NetworkManager
check_service systemd-resolved

if [ -x /usr/local/scripts/start-sim.sh ]; then
  ok "client-sim start script present"
else
  warn "client-sim start script missing"
  health_ok=false
fi

if ls /etc/xdg/autostart/*.desktop >/dev/null 2>&1; then
  ok "autostart desktop files present"
else
  warn "no autostart desktop files found"
  health_ok=false
fi

if [ -f "$WLAN_STATE" ]; then
  ok "WLAN driver state file present"
else
  warn "WLAN driver state file missing"
fi

echo
echo "========== POST-INSTALL HEALTH SUMMARY =========="
if [ "$health_ok" = true ]; then
  ok "System health PASSED"
else
  warn "System health has WARNINGS"
fi
echo "==============================================="

###############################################################################
# Final summary
###############################################################################
echo
echo "========== WLAN DRIVER SUMMARY =========="
column -t -s: "$WLAN_STATE"
echo "========================================"

if [ -s "$REBOOT_LOG" ]; then
  warn "Drivers requested a reboot (suppressed):"
  cat "$REBOOT_LOG"
fi

ok "Installation complete — manual reboot recommended"
echo "Log: $LOG"