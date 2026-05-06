#!/usr/bin/env bash
###############################################################################
# Client Simulator Installer v0.99.45
#
# PATCH OVER v0.99.44
# -----------------------------------------------------------------------------
# ✅ FIX WLAN DRIVER INSTALLATION REGRESSION
#    - Restore single-step authoritative installs per driver repo
#    - Retain per-repo spinner (no internal stage splitting)
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

VERSION="0.99.45"

###############################################################################
# STARTUP VERSION BANNER
###############################################################################
echo
echo "============================================================"
echo " Client Simulator Installer v${VERSION}"
echo " Started at: $(date)"
echo "============================================================"
echo

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
# Phase 2 — WLAN drivers (FIXED: single-step installs per repo)
###############################################################################
info "Phase 2: WLAN drivers (authoritative installs)"

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
    info "Installing WLAN driver: $NAME"
    start_ts="$(ts_epoch)"
    STATUS="FAILED"
    TMPLOG="$(mktemp)"

    spin "[$NAME] Installing driver" bash -c "
      set -e
      git clone '$REPO' '$NAME'
      cd '$NAME'
      case '$TYPE' in
        morrownr)
          ./install-driver.sh
          ;;
        aircrack)
          ./dkms-install.sh
          ;;
        dkms)
          make
          make install
          dkms add . || true
          dkms install '$MOD' || true
          ;;
      esac
    " >\"$TMPLOG\" 2>&1 && STATUS=\"INSTALLED\"

    grep -qi \"already\" \"$TMPLOG\" && STATUS=\"ALREADY_INSTALLED\"

    end_ts=\"$(ts_epoch)\"
    echo \"$start_ts,$end_ts,$NAME,$TYPE,$STATUS\" >>\"$DRIVER_LOG\"
    echo \"$MOD:$TYPE:$STATUS\" >>\"$WLAN_STATE\"
    cat \"$TMPLOG\" >>\"$LOG\"
    rm -f \"$TMPLOG\"
  done
  depmod -a || true
fi

export PATH=\"$OLD_PATH\"
rm -rf \"$SUPPRESS\"

###############################################################################
# Phase 3a — firmware
###############################################################################
info \"Phase 3a: Firmware\"
install_pkgs firmware-linux firmware-linux-nonfree firmware-misc-nonfree \\
             firmware-iwlwifi firmware-atheros

###############################################################################
# LightDM install + autologin + hardening
###############################################################################
info \"Installing and configuring LightDM\"
echo \"/usr/sbin/lightdm\" > /etc/X11/default-display-manager
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
# Client-sim deployment (fresh repo guaranteed)
###############################################################################
info \"Deploying client-sim\"

if [ -d \"$CLIENTSIM_REPO/.git\" ]; then
  git -C \"$CLIENTSIM_REPO\" fetch --all
  git -C \"$CLIENTSIM_REPO\" reset --hard origin/HEAD
else
  rm -rf \"$CLIENTSIM_REPO\"
  git clone https://github.com/solutions-hpe/client-sim.git \"$CLIENTSIM_REPO\"
fi

mkdir -p \"$CLIENTSIM_DIR\"
cp -r \"$CLIENTSIM_REPO/linux/\"* \"$CLIENTSIM_DIR/\"
chmod +x \"$CLIENTSIM_DIR\"/*

info \"Installing client-sim autostart entries from repo\"
mkdir -p /etc/xdg/autostart
cp -f \"$CLIENTSIM_REPO/linux/\"*.desktop /etc/xdg/autostart/
chown root:root /etc/xdg/autostart/*.desktop
chmod 644 /etc/xdg/autostart/*.desktop

###############################################################################
# VirtualHere
###############################################################################
info \"Installing VirtualHere\"
spin \"Downloading VirtualHere client\" wget -q https://www.virtualhere.com/sites/default/files/usbclient/vhclientx86_64
spin \"Downloading VirtualHere service\" wget -q https://www.virtualhere.com/sites/default/files/usbclient/scripts/virtualhereclient.service
chmod +x vhclientx86_64
mv vhclientx86_64 /usr/sbin/
mv virtualhereclient.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable virtualhereclient.service

###############################################################################
# Phase 3b — network (LAST)
###############################################################################
info \"Phase 3b: Network\"
install_pkgs network-manager systemd-resolved iperf3

###############################################################################
# Post-install health check
###############################################################################
info \"Running post-install health check\"

systemctl is-active --quiet lightdm && ok \"LightDM active\" || warn \"LightDM inactive\"
systemctl is-active --quiet virtualhereclient.service && ok \"VirtualHere active\" || warn \"VirtualHere inactive\"
systemctl is-active --quiet NetworkManager && ok \"NetworkManager active\" || warn \"NetworkManager inactive\"
systemctl is-active --quiet systemd-resolved && ok \"Resolved active\" || warn \"Resolved inactive\"

ls /etc/xdg/autostart/*.desktop >/dev/null 2>&1 && ok \"Autostart files present\" || warn \"No autostart files\"

ok \"Installation complete — manual reboot recommended\"
echo \"Log: $LOG\"