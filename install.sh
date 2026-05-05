#!/usr/bin/env bash
###############################################################################
# Client Simulator Installer v0.99.19
# FULLY RESTORED – lifecycle complete
###############################################################################

# --- ensure Bash ---
if [ -z "${BASH_VERSION:-}" ]; then
  echo "[INFO] Re-running installer with bash..."
  exec bash "$0" "$@"
fi

set -euo pipefail

VERSION="0.99.19"

LOG="/tmp/client-sim-install.log"
STATE_DIR="/var/lib/client-sim"
WLAN_STATE="$STATE_DIR/wlan-drivers.state"

ACTION="${1:-install}"
PURGE="${2:-}"

mkdir -p "$STATE_DIR"
: >"$LOG"

export GIT_TERMINAL_PROMPT=0
export GIT_ASKPASS=/bin/false
export SSH_ASKPASS=/bin/false
export NEEDRESTART_MODE=a

###############################################################################
# UI helpers
###############################################################################
if [ -t 1 ]; then
  G="\033[0;32m"; Y="\033[0;33m"; R="\033[0;31m"; B="\033[0;34m"; Z="\033[0m"
else
  G=""; Y=""; R=""; B=""; Z=""
fi

ts(){ date "+%H:%M:%S"; }
ok(){   echo -e "[$(ts)] ${G}✔${Z} $*"; }
warn(){ echo -e "[$(ts)] ${Y}⚠${Z} $*"; }
info(){ echo "[$(ts)] $*"; }

###############################################################################
# Spinner with block detection + dots + journalctl
###############################################################################
SPIN_BLOCK_TIMEOUT=120

spin_with_block_detection() {
  local label="$1"; shift
  local frames=("." ".." "...")
  local i=0

  echo -ne "[$(ts)] ${B}[ ]${Z} $label"
  "$@" >>"$LOG" 2>&1 &
  pid=$!

  elapsed=0
  dumped=0
  while kill -0 "$pid" 2>/dev/null; do
    echo -ne "\r[$(ts)] ${B}[${frames[$i]}]${Z} $label"
    i=$(( (i+1) % ${#frames[@]} ))
    sleep 1
    elapsed=$((elapsed+1))

    if (( elapsed >= SPIN_BLOCK_TIMEOUT && dumped == 0 )); then
      dumped=1
      echo
      warn "Operation appears blocked (${elapsed}s). Dumping journalctl:"
      journalctl -xe --no-pager -n 100 || true
      warn "Continuing to wait..."
      echo
    fi
  done

  wait "$pid" || true
  echo -e "\r[$(ts)] ${G}[✔]${Z} $label"
}

###############################################################################
# Per-package install
###############################################################################
install_packages_individually() {
  local pkg
  for pkg in "$@"; do
    spin_with_block_detection "Installing package: $pkg" \
      apt install -y "$pkg" || warn "Package issue: $pkg"
  done
}

###############################################################################
# Raspberry Pi detection
###############################################################################
IS_RPI=0
if command -v raspi-config >/dev/null 2>&1 &&
   [ -r /proc/device-tree/model ] &&
   grep -qi "raspberry pi" /proc/device-tree/model; then
  IS_RPI=1
fi

echo "=================================================="
echo " Client Simulator Installer v$VERSION"
echo " Platform: $([ "$IS_RPI" -eq 1 ] && echo Raspberry\ Pi || echo Debian/Ubuntu)"
echo "=================================================="

###############################################################################
# WLAN DRIVER LIST — single source of truth
###############################################################################
WLAN_DRIVERS=(
  "8814au|morrownr|https://github.com/morrownr/8814au.git|8814au"
  "8821cu|morrownr|https://github.com/morrownr/8821cu-20210916.git|8821cu"
  "8821au-20210708|morrownr|https://github.com/morrownr/8821au-20210708.git|8821au"
  "8812au-20210820|morrownr|https://github.com/morrownr/8812au-20210820.git|8812au"
  "88x2bu|morrownr|https://github.com/morrownr/88x2bu-20210702.git|88x2bu"
  "rtl8852bu|morrownr|https://github.com/morrownr/rtl8852bu.git|rtl8852bu"
  "rtl8852cu|morrownr|https://github.com/morrownr/rtl8852cu.git|rtl8852cu"
  "rtl8822bu|morrownr|https://github.com/morrownr/rtl8822bu.git|rtl8822bu"
  "rtl8812au|aircrack|https://github.com/aircrack-ng/rtl8812au.git|rtl8812au"
  "rtl8188eu|dkms|https://github.com/lwfinger/rtl8188eu.git|8188eu"
  "rtl8188fu|dkms|https://github.com/kelebek333/rtl8188fu.git|8188fu"
  "rtl8192eu|dkms|https://github.com/Mange/rtl8192eu-linux-driver.git|8192eu"
  "rtl8192fu|dkms|https://github.com/heemsoft/rtl8192fu.git|8192fu"
  "rtl8723au|dkms|https://github.com/lwfinger/rtl8723au.git|8723au"
  "rtl8852au|dkms|https://github.com/lwfinger/rtl8852au.git|8852au"
  "mt7601u|dkms|https://github.com/kuba-moo/mt7601u.git|mt7601u"
)

###############################################################################
# REMOVE / PURGE MODE (RESTORED)
###############################################################################
if [ "$ACTION" = "remove" ]; then
  info "Removing Client Simulator components"

  if [ -f "$WLAN_STATE" ] && [ "$IS_RPI" -eq 0 ]; then
    while IFS=: read -r MODULE TYPE; do
      info "Removing WLAN driver: $MODULE ($TYPE)"
      case "$TYPE" in
        dkms|aircrack) dkms remove "$MODULE" --all || true ;;
        morrownr)
          [ -x "/usr/src/wifi-drivers/$MODULE/remove-driver.sh" ] &&
          "/usr/src/wifi-drivers/$MODULE/remove-driver.sh" || true ;;
      esac
    done <"$WLAN_STATE"
    depmod -a || true
    rm -f "$WLAN_STATE"
  fi

  systemctl stop virtualhereclient.service 2>/dev/null || true
  systemctl disable virtualhereclient.service 2>/dev/null || true
  rm -f /usr/sbin/vhclientx86_64 /etc/systemd/system/virtualhereclient.service
  systemctl daemon-reload

  rm -rf /usr/local/scripts "$HOME/client-sim"
  rm -f /etc/xdg/autostart/client-simulator.desktop

  if [ "$PURGE" = "--purge" ]; then
    apt purge -y lightdm lightdm-gtk-greeter lxqt-session openbox \
      htop tmux screen lshw qemu-guest-agent sysstat iperf3 || true
    apt autoremove -y || true
    rm -rf "$STATE_DIR"
  fi

  ok "Removal complete — reboot recommended"
  exit 0
fi

###############################################################################
# BASE SYSTEM
###############################################################################
spin_with_block_detection "Updating package index" apt update
spin_with_block_detection "Upgrading base system" apt upgrade -y || true
dpkg --configure -a >>"$LOG" 2>&1 || true
apt -f install -y >>"$LOG" 2>&1 || true

###############################################################################
# Kernel headers (RESTORED)
###############################################################################
HEADERS=()
HEADER_PKG="linux-headers-$(uname -r)"
apt-cache show "$HEADER_PKG" >/dev/null 2>&1 && HEADERS+=("$HEADER_PKG")

###############################################################################
# BASE PACKAGES (non-network)
###############################################################################
BASE_PKGS=(
  build-essential dkms
  git wget curl jq unzip
  htop tmux screen lshw
  smbclient qemu-guest-agent
  sysstat rsyslog
  bash coreutils util-linux procps ca-certificates
  python3 python3-pip python3-venv python-is-python3 python3-smbus
  net-tools dnsutils iw rfkill i2c-tools
  firmware-linux firmware-linux-nonfree firmware-misc-nonfree
  firmware-iwlwifi firmware-atheros firmware-brcm80211
)

install_packages_individually "${HEADERS[@]}" "${BASE_PKGS[@]}"

###############################################################################
# DESKTOP (LightDM debconf fixed)
###############################################################################
echo "lightdm shared/default-x-display-manager select lightdm" | debconf-set-selections
echo "gdm3 shared/default-x-display-manager select lightdm" | debconf-set-selections

install_packages_individually lightdm lightdm-gtk-greeter lxqt-session openbox

spin_with_block_detection "Configuring LightDM autologin" bash -c '
mkdir -p /etc/lightdm/lightdm.conf.d
cat >/etc/lightdm/lightdm.conf.d/20-autologin.conf <<EOF
[Seat:*]
autologin-user=user
user-session=lxqt
EOF
ln -sf /lib/systemd/system/lightdm.service /etc/systemd/system/display-manager.service
systemctl enable lightdm
'

###############################################################################
# WLAN DRIVER INSTALL (FULL)
###############################################################################
: >"$WLAN_STATE"
record_driver(){ echo "$1:$2" >>"$WLAN_STATE"; }

if [ "$IS_RPI" -eq 0 ]; then
  mkdir -p /usr/src/wifi-drivers && cd /usr/src/wifi-drivers
  for entry in "${WLAN_DRIVERS[@]}"; do
    IFS='|' read -r NAME TYPE REPO MODULE <<<"$entry"
    info "Installing WLAN driver: $NAME"
    case "$TYPE" in
      morrownr)
        git clone "$REPO" "$NAME" &&
        (cd "$NAME" && ./install-driver.sh >>"$LOG" 2>&1 &&
         record_driver "$NAME" morrownr) || warn "$NAME failed"
        ;;
      aircrack)
        git clone "$REPO" "$NAME" &&
        (cd "$NAME" && ./dkms-install.sh >>"$LOG" 2>&1 &&
         record_driver "$MODULE" aircrack) || warn "$NAME failed"
        ;;
      dkms)
        git clone "$REPO" "$NAME" &&
        (cd "$NAME" &&
         make >>"$LOG" 2>&1 &&
         make install >>"$LOG" 2>&1 &&
         dkms add . >>"$LOG" 2>&1 || true &&
         dkms install "$MODULE" >>"$LOG" 2>&1 || true &&
         record_driver "$MODULE" dkms) || warn "$NAME failed"
        ;;
    esac
  done
  depmod -a || true
else
  warn "Raspberry Pi detected — skipping Wi‑Fi drivers"
fi

###############################################################################
# WLAN DRIVER SUMMARY (RESTORED)
###############################################################################
echo
echo "================= Wi‑Fi Driver Summary ================="
while IFS=: read -r NAME TYPE; do
  printf " %-20s : %s\n" "$NAME" "$TYPE"
done <"$WLAN_STATE" 2>/dev/null || echo "No external Wi‑Fi drivers installed"
echo "========================================================"

###############################################################################
# VirtualHere
###############################################################################
spin_with_block_detection "Installing VirtualHere" bash -c '
wget -q https://www.virtualhere.com/sites/default/files/usbclient/vhclientx86_64 &&
wget -q https://www.virtualhere.com/sites/default/files/usbclient/scripts/virtualhereclient.service &&
chmod +x vhclientx86_64 &&
mv vhclientx86_64 /usr/sbin &&
mv virtualhereclient.service /etc/systemd/system/ &&
systemctl daemon-reload &&
systemctl enable virtualhereclient.service
'

###############################################################################
# Client Simulator
###############################################################################
spin_with_block_detection "Deploying client simulator" bash -c '
mkdir -p /usr/local/scripts &&
git clone https://github.com/solutions-hpe/client-sim.git ~/client-sim || true &&
cp ~/client-sim/linux/* /usr/local/scripts/ &&
chmod -R 755 /usr/local/scripts
'

mkdir -p /etc/xdg/autostart
cat >/etc/xdg/autostart/client-simulator.desktop <<EOF
[Desktop Entry]
Type=Application
Name=Client Simulator
Exec=/usr/local/scripts/start-sim.sh
OnlyShowIn=LXQt;
EOF

###############################################################################
# NETWORK SERVICES — INSTALLED LAST
###############################################################################
install_packages_individually network-manager systemd-resolved iperf3

###############################################################################
# FINAL
###############################################################################
ok "Installation complete"
echo "Reboot required"
echo "Log file: $LOG"