#!/usr/bin/env bash
###############################################################################
# Client Simulator Installer v0.99.53
#
# PATCH OVER v0.99.52
# -----------------------------------------------------------------------------
# ✅ Install sudo (if missing)
# ✅ Enable PASSWORDLESS sudo for user "user" via /etc/sudoers.d
###############################################################################

###############################################################################
# Bash + PATH hardening
###############################################################################
if [ -z "${BASH_VERSION:-}" ]; then
  echo "[INFO] Re-running installer with bash..."
  exec bash "$0" "$@"
fi
set -euo pipefail
export PATH="/usr/sbin:/sbin:/usr/bin:/bin:$PATH"

VERSION="0.99.53"

###############################################################################
# Startup version banner
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

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export GIT_TERMINAL_PROMPT=0

###############################################################################
# Logging helpers
###############################################################################
ts(){ date "+%H:%M:%S"; }
info(){ echo "[$(ts)] INFO: $*"; }
ok(){   echo "[$(ts)] OK:   $*"; }
warn(){ echo "[$(ts)] WARN: $*"; }

###############################################################################
# Helper: quiet apt install with INFO/OK feedback
###############################################################################
apt_install() {
  local label="$1"; shift
  info "$label"
  apt install -y --quiet=2 "$@" >>"$LOG" 2>&1
  ok "$label complete"
}

###############################################################################
# USER provisioning + PASSWORDLESS SUDO (ENHANCEMENT)
###############################################################################
info "Ensuring local user 'user' exists"

if ! id user >/dev/null 2>&1; then
  useradd -m -s /bin/bash user
  ok "Created user 'user'"
else
  ok "User 'user' already exists"
fi

# Ensure sudo is present
apt_install "Installing sudo (if missing)" sudo

# Ensure group membership (idempotent)
if ! id -nG user | grep -qw sudo; then
  usermod -aG sudo user
  ok "Added user 'user' to sudo group"
else
  ok "User 'user' already in sudo group"
fi

# Enable passwordless sudo via sudoers.d
info "Enabling passwordless sudo for user 'user'"
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
  info "Raspberry Pi detected — WLAN drivers will be skipped"
fi

###############################################################################
# Base system update
###############################################################################
info "Updating package index"
apt update --quiet=2 >>"$LOG" 2>&1
ok "Package index updated"

info "Upgrading base system"
apt upgrade -y --quiet=2 >>"$LOG" 2>&1 || true
ok "Base system upgrade complete"

###############################################################################
# Phase 1 — Driver prerequisites
###############################################################################
apt_install "Installing driver build prerequisites" \
  build-essential dkms git rfkill linux-headers-$(uname -r)

###############################################################################
# Phase 2 — WLAN drivers (stable, authoritative)
###############################################################################
info "Phase 2: WLAN drivers"

mkdir -p /usr/src/wifi-drivers
cd /usr/src/wifi-drivers

# Suppress reboots requested by driver scripts
SUPPRESS="$(mktemp -d)"
for cmd in reboot shutdown poweroff halt systemctl; do
  echo -e "#!/bin/sh\necho \"$cmd requested\" >>'$REBOOT_LOG'\nexit 0" \
    >"$SUPPRESS/$cmd"
  chmod +x "$SUPPRESS/$cmd"
done
OLD_PATH="$PATH"
export PATH="$SUPPRESS:$PATH"

if [ "$IS_RPI" -eq 0 ]; then
  for entry in \
    "8814au|morrownr|https://github.com/morrownr/8814au.git|8814au" \
    "8821cu|morrownr|https://github.com/morrownr/8821cu-20210916.git|8821cu" \
    "rtl8812au|aircrack|https://github.com/aircrack-ng/rtl8812au.git|rtl8812au" \
    "rtl8188eu|dkms|https://github.com/lwfinger/rtl8188eu.git|8188eu"
  do
    IFS='|' read -r NAME TYPE REPO MOD <<<"$entry"
    info "Installing WLAN driver: $NAME"
    rm -rf "$NAME"

    START_TS="$(date +%s)"
    STATUS="FAILED"

    if git clone "$REPO" "$NAME" >>"$LOG" 2>&1; then
      cd "$NAME"
      case "$TYPE" in
        morrownr) ./install-driver.sh >>"$LOG" 2>&1 && STATUS="INSTALLED" ;;
        aircrack) ./dkms-install.sh >>"$LOG" 2>&1 && STATUS="INSTALLED" ;;
        dkms)
          make >>"$LOG" 2>&1
          make install >>"$LOG" 2>&1
          dkms add . >>"$LOG" 2>&1 || true
          dkms install "$MOD" >>"$LOG" 2>&1 || true
          STATUS="INSTALLED"
          ;;
      esac
      cd ..
    fi

    END_TS="$(date +%s)"
    echo "$START_TS,$END_TS,$NAME,$TYPE,$STATUS" >>"$DRIVER_LOG"
    echo "$MOD:$TYPE:$STATUS" >>"$WLAN_STATE"
    ok "WLAN driver $NAME: $STATUS"
  done
  depmod -a >>"$LOG" 2>&1 || true
fi

export PATH="$OLD_PATH"
rm -rf "$SUPPRESS"

###############################################################################
# Phase 3a — Firmware
###############################################################################
apt_install "Installing firmware packages" \
  firmware-linux firmware-linux-nonfree firmware-misc-nonfree \
  firmware-iwlwifi firmware-atheros

###############################################################################
# Desktop stack (LightDM + LXQt + GNOME Terminal)
###############################################################################
apt_install "Installing desktop components" \
  lightdm lightdm-gtk-greeter lxqt-session openbox gnome-terminal

echo "/usr/sbin/lightdm" > /etc/X11/default-display-manager

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
[Unit]
Conflicts=getty@tty7.service
EOF

systemctl daemon-reload
systemctl enable lightdm
ok "Desktop stack installed"

###############################################################################
# client-sim deployment (deterministic repo sync)
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
cp -f "$CLIENTSIM_REPO/linux/"*.desktop /etc/xdg/autostart/
chmod 644 /etc/xdg/autostart/*.desktop
ok "client-sim deployed"

###############################################################################
# VirtualHere — architecture-aware
###############################################################################
info "Installing VirtualHere client (architecture-aware)"
ARCH="$(uname -m)"
VH_BIN=""
case "$ARCH" in
  x86_64) VH_BIN="vhclientx86_64" ;;
  aarch64) VH_BIN="vhclientarm64" ;;
  armv7l|armhf) VH_BIN="vhclientarm" ;;
  *) warn "Unsupported architecture for VirtualHere: $ARCH" ;;
esac

if [ -n "$VH_BIN" ]; then
  curl -fsSL "https://www.virtualhere.com/sites/default/files/usbclient/$VH_BIN" \
    -o /usr/sbin/vhclient || warn "Failed to download VirtualHere"
  chmod +x /usr/sbin/vhclient

  cat >/etc/systemd/system/virtualhereclient.service <<EOF
[Unit]
Description=VirtualHere Client
After=network-online.target
Wants=network-online.target
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
# Health check summary + VERIFICATION
###############################################################################
echo
echo "========== HEALTH CHECK =========="
id user >/dev/null && echo "User: OK" || echo "User: MISSING"
groups user | grep -qw sudo && echo "Sudo group: OK" || echo "Sudo group: FAIL"
test -f /etc/sudoers.d/99-user-nopasswd && echo "Passwordless sudo: OK" || echo "Passwordless sudo: MISSING"
systemctl is-active --quiet lightdm && echo "LightDM: OK" || echo "LightDM: FAIL"
systemctl is-active --quiet NetworkManager && echo "Network: OK" || echo "Network: FAIL"
systemctl is-active --quiet virtualhereclient && echo "VirtualHere: OK" || echo "VirtualHere: NOT RUNNING"
ls /etc/xdg/autostart/*.desktop >/dev/null && echo "Autostart: OK" || echo "Autostart: MISSING"
echo "================================="
echo

info "Installation complete — manual reboot recommended"
info "Log file: $LOG"