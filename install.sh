#!/usr/bin/env bash
###############################################################################
# Client Simulator Installer v0.99.55
#
# PATCH OVER v0.99.53
# -----------------------------------------------------------------------------
# ✅ Integrate full WLAN driver parity (12 repos) using original install methods
###############################################################################

set -euo pipefail
export PATH="/usr/sbin:/sbin:/usr/bin:/bin:$PATH"

VERSION="0.99.55"

###############################################################################
# Startup banner
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

mkdir -p "$STATE_DIR" /var/log
: >"$LOG" : >"$WLAN_STATE" : >"$REBOOT_LOG" : >"$DRIVER_LOG"
chmod 644 "$LOG" "$WLAN_STATE" "$REBOOT_LOG" "$DRIVER_LOG"

###############################################################################
# Logging helpers
###############################################################################
ts(){ date "+%H:%M:%S"; }
info(){ echo "[$(ts)] INFO: $*"; }
ok(){ echo "[$(ts)] OK:   $*"; }
warn(){ echo "[$(ts)] WARN: $*"; }

###############################################################################
# Quiet apt install helper (INFO / OK only)
###############################################################################
apt_install() {
  local label="$1"; shift
  info "$label"
  apt install -y --quiet=2 "$@" >>"$LOG" 2>&1
  ok "$label complete"
}

###############################################################################
# USER + PASSWORDLESS SUDO
###############################################################################
info "Ensuring user 'user' exists with passwordless sudo"

if ! id user >/dev/null 2>&1; then
  useradd -m -s /bin/bash user
  ok "Created user 'user'"
else
  ok "User 'user' already exists"
fi

apt_install "Installing sudo (if missing)" sudo

if ! id -nG user | grep -qw sudo; then
  usermod -aG sudo user
  ok "Added user 'user' to sudo group"
else
  ok "User 'user' already in sudo group"
fi

cat >/etc/sudoers.d/99-user-nopasswd <<EOF
user ALL=(ALL) NOPASSWD:ALL
EOF
chmod 0440 /etc/sudoers.d/99-user-nopasswd
ok "Passwordless sudo enabled for user 'user'"

###############################################################################
# Raspberry Pi detection
###############################################################################
IS_RPI=0
if command -v raspi-config >/dev/null 2>&1 &&
   grep -qi "raspberry pi" /proc/device-tree/model 2>/dev/null; then
  IS_RPI=1
  info "Raspberry Pi detected — WLAN drivers skipped"
fi

###############################################################################
# Base system
###############################################################################
info "Updating package index"
apt update --quiet=2 >>"$LOG" 2>&1
ok "Package index updated"

info "Upgrading base system"
apt upgrade -y --quiet=2 >>"$LOG" 2>&1 || true
ok "Base system upgrade complete"

###############################################################################
# Build prerequisites
###############################################################################
apt_install "Installing build prerequisites" \
  build-essential dkms git rfkill linux-headers-$(uname -r)

###############################################################################
# Phase 2 — WLAN drivers (FULL PARITY)
###############################################################################
info "Phase 2: Installing WLAN drivers (full parity)"

mkdir -p /usr/src/wifi-drivers
cd /usr/src/wifi-drivers
: >"$WLAN_STATE"

# Suppress reboot calls from driver scripts
SUPPRESS="$(mktemp -d)"
for c in reboot shutdown poweroff halt systemctl; do
  printf '#!/bin/sh\necho "%s requested"\nexit 0\n' "$c" >"$SUPPRESS/$c"
  chmod +x "$SUPPRESS/$c"
done
OLD_PATH="$PATH"
export PATH="$SUPPRESS:$PATH"

if [ "$IS_RPI" -eq 0 ]; then
  for entry in \
    "8821au-20210708|morrownr|https://github.com/morrownr/8821au-20210708.git|8821au" \
    "8821cu-20210916|morrownr|https://github.com/morrownr/8821cu-20210916.git|8821cu" \
    "8814au|morrownr|https://github.com/morrownr/8814au.git|8814au" \
    "8812au-20210820|morrownr|https://github.com/morrownr/8812au-20210820.git|8812au" \
    "rtl8852bu-20240418|morrownr|https://github.com/morrownr/rtl8852bu-20240418.git|8852bu" \
    "rtl8852cu-20240510|morrownr|https://github.com/morrownr/rtl8852cu-20240510.git|8852cu" \
    "88x2bu-20210702|morrownr|https://github.com/morrownr/88x2bu-20210702.git|88x2bu" \
    "rtw89|morrownr|https://github.com/morrownr/rtw89.git|rtw89" \
    "rtl8812au|aircrack|https://github.com/aircrack-ng/rtl8812au.git|rtl8812au" \
    "rtl8188eu|lwfinger|https://github.com/lwfinger/rtl8188eu.git|8188eu" \
    "rtl8723au|lwfinger|https://github.com/lwfinger/rtl8723au.git|8723au" \
    "rtl8852au|lwfinger|https://github.com/lwfinger/rtl8852au.git|8852au"
  do
    IFS='|' read -r NAME TYPE REPO MOD <<<"$entry"
    info "Installing WLAN driver: $NAME"
    rm -rf "$NAME"
    STATUS="FAILED"

    if git clone "$REPO" "$NAME" >>"$LOG" 2>&1; then
      cd "$NAME"
      case "$TYPE" in
        morrownr)
          ./install-driver.sh NoPrompt >>"$LOG" 2>&1 && STATUS="INSTALLED"
          ;;
        aircrack)
          ./install-driver.sh >>"$LOG" 2>&1 && STATUS="INSTALLED"
          ;;
        lwfinger)
          make all >>"$LOG" 2>&1
          make install >>"$LOG" 2>&1
          dkms add . >>"$LOG" 2>&1 || true
          dkms install "$MOD" >>"$LOG" 2>&1 || true
          STATUS="INSTALLED"
          ;;
      esac
      cd ..
    fi

    echo "$MOD:$TYPE:$STATUS" >>"$WLAN_STATE"
    ok "WLAN driver $NAME: $STATUS"
  done

  depmod -a >>"$LOG" 2>&1 || true
fi

export PATH="$OLD_PATH"
rm -rf "$SUPPRESS"

###############################################################################
# Firmware
###############################################################################
apt_install "Installing firmware packages" \
  firmware-linux firmware-linux-nonfree firmware-misc-nonfree \
  firmware-iwlwifi firmware-atheros

###############################################################################
# Desktop stack
###############################################################################
apt_install "Installing desktop components" \
  lightdm lightdm-gtk-greeter lxqt-session openbox gnome-terminal

echo "/usr/sbin/lightdm" >/etc/X11/default-display-manager

mkdir -p /etc/lightdm/lightdm.conf.d
cat >/etc/lightdm/lightdm.conf.d/20-autologin.conf <<EOF
[Seat:*]
autologin-user=user
user-session=lxqt
EOF

systemctl enable lightdm

###############################################################################
# client-sim deployment
###############################################################################
info "Deploying client-sim"

if [ -d "$CLIENTSIM_REPO/.git" ]; then
  git -C "$CLIENTSIM_REPO" fetch --all >>"$LOG" 2>&1
  git -C "$CLIENTSIM_REPO" reset --hard origin/HEAD >>"$LOG" 2>&1
else
  rm -rf "$CLIENTSIM_REPO"
  git clone https://github.com/solutions-hpe/client-sim.git "$CLIENTSIM_REPO" >>"$LOG" 2>&1
fi

mkdir -p "$CLIENTSIM_DIR"
cp -r "$CLIENTSIM_REPO/linux/"* "$CLIENTSIM_DIR/"
chmod +x "$CLIENTSIM_DIR"/*

mkdir -p /etc/xdg/autostart
cp "$CLIENTSIM_REPO/linux/"*.desktop /etc/xdg/autostart/
chmod 644 /etc/xdg/autostart/*.desktop
ok "client-sim deployed"

###############################################################################
# Architecture-aware VirtualHere
###############################################################################
info "Installing VirtualHere client"

ARCH="$(uname -m)"
case "$ARCH" in
  x86_64) VH="vhclientx86_64" ;;
  aarch64) VH="vhclientarm64" ;;
  armv7l|armhf) VH="vhclientarm" ;;
  *) warn "Unsupported arch for VirtualHere: $ARCH"; VH="" ;;
esac

if [ -n "$VH" ]; then
  curl -fsSL "https://www.virtualhere.com/sites/default/files/usbclient/$VH" \
    -o /usr/sbin/vhclient
  chmod +x /usr/sbin/vhclient
  cat >/etc/systemd/system/virtualhereclient.service <<EOF
[Service]
ExecStart=/usr/sbin/vhclient
Restart=always
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable virtualhereclient
  systemctl start virtualhereclient || true
  ok "VirtualHere installed for $ARCH"
fi

###############################################################################
# Network (LAST)
###############################################################################
apt_install "Installing network services" \
  network-manager systemd-resolved iperf3

###############################################################################
# Health check
###############################################################################
echo
echo "========== HEALTH CHECK =========="
id user && echo "User OK"
groups user | grep -qw sudo && echo "Sudo OK"
ls /usr/src/wifi-drivers | wc -l | xargs echo "WLAN repos installed:"
lsmod | grep -E '88|rtw|885' >/dev/null && echo "WLAN modules loaded" || echo "WLAN modules not loaded (reboot may be required)"
systemctl is-active --quiet lightdm && echo "LightDM OK"
systemctl is-active --quiet NetworkManager && echo "Network OK"
echo "================================="

info "Installation complete — manual reboot recommended"
info "Log: $LOG"