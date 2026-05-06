#!/usr/bin/env bash
###############################################################################
# Client Simulator Installer v.01
###############################################################################

set -euo pipefail
export PATH="/usr/sbin:/sbin:/usr/bin:/bin:$PATH"

###############################################################################
# Non-interactive guarantees
###############################################################################
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export GIT_TERMINAL_PROMPT=0

VERSION="0.01"

###############################################################################
# Logging
###############################################################################
STATE_DIR="/var/lib/client-sim"
LOG="/var/log/client-sim_install.log"
DRIVER_STATE="$STATE_DIR/wlan-drivers.state"

mkdir -p "$STATE_DIR"
: >"$LOG"
: >"$DRIVER_STATE"
chmod 644 "$LOG" "$DRIVER_STATE"

ts(){ date "+%H:%M:%S"; }
info(){ echo "[$(ts)] INFO: $*" | tee -a "$LOG"; }
ok(){   echo "[$(ts)] OK:   $*" | tee -a "$LOG"; }
warn(){ echo "[$(ts)] WARN: $*" | tee -a "$LOG"; }

###############################################################################
# Startup banner
###############################################################################
echo
echo "============================================================"
echo " Client Simulator Installer v${VERSION}"
echo " Started at: $(date)"
echo "============================================================"
echo | tee -a "$LOG"

###############################################################################
# USER PROVISIONING + PASSWORDLESS SUDO
###############################################################################
info "Ensuring user 'user' exists with passwordless sudo"

if ! id user &>/dev/null; then
  useradd -m -s /bin/bash user
  ok "Created user 'user'"
else
  ok "User 'user' already exists"
fi

usermod -aG sudo user

cat >/etc/sudoers.d/99-user-nopasswd <<EOF
user ALL=(ALL) NOPASSWD:ALL
EOF
chmod 0440 /etc/sudoers.d/99-user-nopasswd
ok "Passwordless sudo configured"

###############################################################################
# PACKAGE PARITY
###############################################################################
info "Installing apps needed for WiFi Driver Install"

sud apt update --quiet=2 >>"$LOG" 2>&1
sud apt install -y --quiet=2 \
  gnome-terminal wget sudo linux-headers-$(uname -r) \
  git qemu-guest-agent smbclient rsyslog rfkill \
  firefox-esr iperf3 dkms sysstat rfkill build-essential \
  >>"$LOG" 2>&1

sudo apt autoremove -y --quiet=2 >>"$LOG" 2>&1
ok "Installing apps needed for WiFi Driver Install"

###############################################################################
# Live GNOME terminal for installer log
###############################################################################
gnome-terminal --geometry=80x15+0+477 -- tail -f "$LOG" &

###############################################################################
# GNOME DISPLAY & POWER MANAGEMENT
###############################################################################
info "Disabling Wayland (forcing X11)"
sed -i '/WaylandEnable=false/s/^#//g' /etc/gdm3/custom.conf || true
ok "Wayland disabled"

info "Disabling screen blanking and DPMS"
gsettings set org.gnome.desktop.session idle-delay 0 || true
xset s noblank || true
xset -dpms || true
xset s off || true
ok "Screen power management disabled"

info "Setting screen resolution"
xrandr --output Virtual-1 --mode 1440x900 || true

###############################################################################
# RASPBERRY PI REGION
###############################################################################
if command -v raspi-config >/dev/null 2>&1; then
  info "Configuring Raspberry Pi locale and Wi-Fi region"
  raspi-config nonint do_change_locale en_US.UTF-8
  raspi-config nonint do_wifi_country US
  ok "Raspberry Pi configured"
fi

###############################################################################
# /usr/local/scripts population
###############################################################################
info "Preparing /usr/local/scripts"
mkdir -p /usr/local/scripts
chmod 777 /usr/local/scripts

touch /usr/local/scripts/sim.log
echo "Installer Version ${VERSION}" | tee /usr/local/scripts/sim.log
chmod 777 /usr/local/scripts/sim.log

###############################################################################
# SMB CONFIG SYNC
###############################################################################
info "Syncing configuration from SMB share"
smbclient //nas/scripts -N -c \
  'lcd /usr/local/scripts; cd /SIM/CONFIG; prompt off; mget *.conf' \
  >>"$LOG" 2>&1 || warn "SMB config sync failed"

###############################################################################
# RSYSLOG CUSTOM CONFIG
###############################################################################
if [ -f /usr/local/scripts/10-rsyslog.conf ]; then
  info "Installing custom rsyslog config"
  cp /usr/local/scripts/10-rsyslog.conf /etc/rsyslog.d/10-rsyslog.conf
  sudo systemctl restart rsyslog || true
  sudo systemctl enable rsyslog || true
  ok "rsyslog configured"
fi

###############################################################################
# VIRTUALHERE INSTALL + RUNTIME INIT
###############################################################################
info "Installing VirtualHere"

ARCH="$(uname -m)"
VH_BIN=""

case "$ARCH" in
  x86_64)  VH_BIN="vhclientx86_64" ;;
  aarch64) VH_BIN="vhclientarm64" ;;
  armv7l|armhf) VH_BIN="vhclientarm" ;;
esac

if [ -n "$VH_BIN" ]; then
  curl -fsSL "https://www.virtualhere.com/sites/default/files/usbclient/$VH_BIN" \
    -o /usr/sbin/vhclient
  chmod +x /usr/sbin/vhclient

  cat >/etc/systemd/system/virtualhereclient.service <<EOF
[Unit]
Description=VirtualHere Client
After=network-online.target

[Service]
ExecStart=/usr/sbin/vhclient
Restart=always

[Install]
WantedBy=multi-user.target
EOF

  sudo systemctl daemon-reload
  sudo systemctl enable virtualhereclient
  sudo systemctl start virtualhereclient

  rm -f /usr/local/scripts/vhcached.txt || true
  /usr/sbin/vhclient -t "AUTO USE CLEAR ALL" || true
  /usr/sbin/vhclient -t "STOP USING ALL LOCAL" || true

  ok "VirtualHere installed and initialized"
fi

###############################################################################
# WLAN DRIVERS INSTALL
###############################################################################
info "Installing WLAN drivers"

mkdir -p /usr/src/wifi-drivers
cd /usr/src/wifi-drivers
rm -f "$DRIVER_STATE"

# Reboot suppression
SUPPRESS="$(mktemp -d)"
for c in reboot shutdown poweroff halt systemctl; do
  printf '#!/bin/sh\nexit 0\n' >"$SUPPRESS/$c"
  chmod +x "$SUPPRESS/$c"
done
OLD_PATH="$PATH"
export PATH="$SUPPRESS:$PATH"

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

  if git clone "$REPO" "$NAME" >>"$LOG" 2>&1; then
    cd "$NAME"
    case "$TYPE" in
      morrownr) sudo ./install-driver.sh NoPrompt >>"$LOG" 2>&1 ;;
      aircrack) sudo ./install-driver.sh >>"$LOG" 2>&1 ;;
      lwfinger)
        sudo make all >>"$LOG" 2>&1
        sudo make install >>"$LOG" 2>&1
        sudo dkms add . >>"$LOG" 2>&1 || true
        sudo dkms install "$MOD" >>"$LOG" 2>&1 || true
        ;;
    esac
    cd ..
    echo "$NAME:INSTALLED" >>"$DRIVER_STATE"
    ok "WLAN driver $NAME installed"
  else
    echo "$NAME:FAILED" >>"$DRIVER_STATE"
    warn "Failed to clone $NAME"
  fi
done

sudo depmod -a >>"$LOG" 2>&1
export PATH="$OLD_PATH"
rm -rf "$SUPPRESS"

info "Installing Network Related Applications"
sudo apt install -y --quiet=2 \
  net-tools dnsutils network-manager \
  >>"$LOG" 2>&1

sudo apt autoremove -y --quiet=2 >>"$LOG" 2>&1
ok "Installing Network Related Applications"

###############################################################################
# FINAL HEALTH SUMMARY
###############################################################################
echo "================ HEALTH CHECK ================" | tee -a "$LOG"
id user &>/dev/null && echo "User: OK" | tee -a "$LOG"
groups user | grep -q sudo && echo "Sudo: OK" | tee -a "$LOG"
systemctl is-active --quiet lightdm && echo "LightDM: OK" | tee -a "$LOG"
systemctl is-active --quiet network-manager && echo "NetworkManager: OK" | tee -a "$LOG"
systemctl is-active --quiet virtualhereclient && echo "VirtualHere: OK" | tee -a "$LOG"
lsmod | grep -E '88|rtw|885' >/dev/null && echo "WLAN modules loaded" | tee -a "$LOG"
echo "=============================================" | tee -a "$LOG"

###############################################################################
# END
###############################################################################
ok "Installation complete"
info "Reboot recommended"
info "Log file: $LOG"