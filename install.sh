#!/usr/bin/env bash
###############################################################################
# Client Simulator Installer v0.99.23
# - PATH hardened for admin tools
# - Ensure 'user' exists and is sudoer
# - WLAN driver status classification fixed
# - Screen saver / DPMS disabled for LXQt session
# - Phased ordering (drivers -> firmware -> network)
###############################################################################

# ---------------------------------------------------------------------------
# Ensure Bash + harden PATH for non-login shells
# ---------------------------------------------------------------------------
if [ -z "${BASH_VERSION:-}" ]; then
  echo "[INFO] Re-running installer with bash..."
  exec bash "$0" "$@"
fi

# PATH hardening (admin utilities live here on minimal systems)
export PATH="/usr/sbin:/sbin:/usr/bin:/bin:$PATH"

set -euo pipefail

VERSION="0.99.23"

STATE_DIR="/var/lib/client-sim"
LOG="/var/log/client-sim-install.log"
WLAN_STATE="$STATE_DIR/wlan-drivers.state"

ACTION="${1:-install}"
PURGE="${2:-}"

mkdir -p "$STATE_DIR" /var/log
touch "$LOG"
chmod 644 "$LOG"

export GIT_TERMINAL_PROMPT=0
export GIT_ASKPASS=/bin/false
export SSH_ASKPASS=/bin/false
export NEEDRESTART_MODE=a
export DEBIAN_FRONTEND=noninteractive

###############################################################################
# UI helpers
###############################################################################
if [ -t 1 ]; then
  G="\033[0;32m"; Y="\033[0;33m"; B="\033[0;34m"; Z="\033[0m"
else
  G=""; Y=""; B=""; Z=""
fi

ts(){ date "+%H:%M:%S"; }
ok(){   echo -e "[$(ts)] ${G}✔${Z} $*"; }
warn(){ echo -e "[$(ts)] ${Y}⚠${Z} $*"; }
info(){ echo "[$(ts)] $*"; }

###############################################################################
# Spinner with animated dots + block detection + journal dump
###############################################################################
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
    i=$(( (i+1) % ${#frames[@]} ))
    sleep 1
    elapsed=$((elapsed+1))
    if (( elapsed >= SPIN_BLOCK_TIMEOUT && dumped == 0 )); then
      dumped=1
      echo
      warn "Long operation (${elapsed}s). Dumping journalctl:"
      journalctl -xe --no-pager -n 100 >>"$LOG" 2>&1 || true
      echo
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
fi

info "Client Simulator Installer v$VERSION"

###############################################################################
# Ensure 'user' exists and is in sudoers (queued fix applied)
###############################################################################
info "Ensuring 'user' account exists and has sudo privileges"
if ! id user >/dev/null 2>&1; then
  useradd -m -s /bin/bash user
  info "Created user: user"
fi

if getent group sudo >/dev/null 2>&1; then
  usermod -aG sudo user
else
  groupadd sudo || true
  usermod -aG sudo user
fi

###############################################################################
# Disable screen saver / screen blanking for LXQt session (queued fix applied)
###############################################################################
info "Disabling screen saver and DPMS for user session"

USER_HOME="$(getent passwd user | cut -d: -f6)"
mkdir -p "$USER_HOME/.config/autostart" "$USER_HOME/.config/lxqt"
chown -R user:user "$USER_HOME/.config"

# Autostart xset commands at session start
cat >"$USER_HOME/.config/autostart/disable-screensaver.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Disable Screen Saver
Exec=sh -c "xset s off; xset s noblank; xset -dpms"
X-LXQt-Need-Tray=false
OnlyShowIn=LXQt;
EOF

# Disable LXQt screen saver at the session level
cat >"$USER_HOME/.config/lxqt/session.conf" <<EOF
[Session]
allowScreenSaver=false
allowSuspend=false
EOF

chown user:user "$USER_HOME/.config/autostart/disable-screensaver.desktop"
chown user:user "$USER_HOME/.config/lxqt/session.conf"

###############################################################################
# WLAN driver list (single source of truth)
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
# REMOVE / PURGE
###############################################################################
if [ "$ACTION" = "remove" ]; then
  info "Removal mode"
  if [ -f "$WLAN_STATE" ] && [ "$IS_RPI" -eq 0 ]; then
    while IFS=: read -r MOD TYPE STATUS; do
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

  systemctl stop virtualhereclient.service 2>/dev/null || true
  systemctl disable virtualhereclient.service 2>/dev/null || true
  rm -f /usr/sbin/vhclientx86_64 /etc/systemd/system/virtualhereclient.service
  systemctl daemon-reload || true

  rm -rf /usr/local/scripts "$HOME/client-sim"
  rm -f /etc/xdg/autostart/client-simulator.desktop

  if [ "$PURGE" = "--purge" ]; then
    apt purge -y lightdm lightdm-gtk-greeter lxqt-session openbox \
      build-essential dkms git || true
    apt autoremove -y || true
    rm -rf "$STATE_DIR"
  fi

  ok "Removal complete"
  exit 0
fi

###############################################################################
# BASE UPDATE
###############################################################################
spin "Updating package index" apt update
spin "Upgrading base system" apt upgrade -y || true
dpkg --configure -a >>"$LOG" 2>&1 || true
apt -f install -y >>"$LOG" 2>&1 || true

###############################################################################
# PHASE 1 — DRIVER BUILD PREREQUISITES
###############################################################################
info "Phase 1: GitHub driver prerequisites"

HEADERS=()
HEADER="linux-headers-$(uname -r)"
apt-cache show "$HEADER" >/dev/null 2>&1 && HEADERS+=("$HEADER")

install_pkgs build-essential dkms git "${HEADERS[@]}"

###############################################################################
# PHASE 2 — GITHUB WLAN DRIVERS (status-aware)
###############################################################################
info "Phase 2: GitHub WLAN drivers"

: >"$WLAN_STATE"
mkdir -p /usr/src/wifi-drivers

if [ "$IS_RPI" -eq 0 ]; then
  cd /usr/src/wifi-drivers
  for d in "${WLAN_DRIVERS[@]}"; do
    IFS='|' read -r NAME TYPE REPO MOD <<<"$d"
    info "Installing WLAN driver: $NAME"

    TMPLOG="$(mktemp)"
    STATUS="FAILED"

    case "$TYPE" in
      morrownr)
        if git clone "$REPO" "$NAME" &&
           (cd "$NAME" && ./install-driver.sh >"$TMPLOG" 2>&1); then
          STATUS="INSTALLED"
        else
          grep -qiE "already installed|already exists|nothing to do" "$TMPLOG" && STATUS="ALREADY_INSTALLED"
        fi
        ;;
      aircrack)
        if git clone "$REPO" "$NAME" &&
           (cd "$NAME" && ./dkms-install.sh >"$TMPLOG" 2>&1); then
          STATUS="INSTALLED"
        else
          grep -qiE "already installed|already exists|nothing to do" "$TMPLOG" && STATUS="ALREADY_INSTALLED"
        fi
        ;;
      dkms)
        if git clone "$REPO" "$NAME" &&
           (cd "$NAME" &&
            make >"$TMPLOG" 2>&1 &&
            make install >>"$TMPLOG" 2>&1 &&
            dkms add . >>"$TMPLOG" 2>&1 || true &&
            dkms install "$MOD" >>"$TMPLOG" 2>&1 || true); then
          STATUS="INSTALLED"
        else
          grep -qiE "already installed|already exists|dkms.*present|module.*exists" "$TMPLOG" && STATUS="ALREADY_INSTALLED"
        fi
        ;;
    esac

    cat "$TMPLOG" >>"$LOG"
    rm -f "$TMPLOG"

    echo "$MOD:$TYPE:$STATUS" >>"$WLAN_STATE"
    info "WLAN driver $NAME status: $STATUS"
  done
  depmod -a || true
else
  warn "RPi detected — skipping external WLAN drivers"
fi

###############################################################################
# PHASE 3a — FIRMWARE (before network)
###############################################################################
info "Phase 3a: Firmware"

install_pkgs \
  firmware-linux \
  firmware-linux-nonfree \
  firmware-misc-nonfree \
  firmware-iwlwifi \
  firmware-atheros

###############################################################################
# DESKTOP — AUTHORITATIVE LightDM FIX
###############################################################################
info "Configuring LightDM (non-interactive)"

echo "lightdm shared/default-x-display-manager select lightdm" | debconf-set-selections
echo "gdm3 shared/default-x-display-manager select lightdm" | debconf-set-selections
echo "sddm shared/default-x-display-manager select lightdm" | debconf-set-selections
echo "/usr/sbin/lightdm" > /etc/X11/default-display-manager

install_pkgs lightdm lightdm-gtk-greeter lxqt-session openbox

spin "Configuring LightDM autologin" bash -c '
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
# VIRTUALHERE + CLIENT SIM
###############################################################################
spin "Installing VirtualHere" bash -c '
wget -q https://www.virtualhere.com/sites/default/files/usbclient/vhclientx86_64 &&
wget -q https://www.virtualhere.com/sites/default/files/usbclient/scripts/virtualhereclient.service &&
chmod +x vhclientx86_64 &&
mv vhclientx86_64 /usr/sbin &&
mv virtualhereclient.service /etc/systemd/system/ &&
systemctl daemon-reload &&
systemctl enable virtualhereclient.service
'

spin "Deploying client simulator" bash -c '
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
# PHASE 3b — NETWORK (LAST)
###############################################################################
info "Phase 3b: Network services (last)"

install_pkgs network-manager systemd-resolved iperf3

###############################################################################
# DRIVER SUMMARY
###############################################################################
echo
echo "================= Wi‑Fi Driver Summary ================="
if [ -f "$WLAN_STATE" ]; then
  while IFS=: read -r MOD TYPE STATUS; do
    printf " %-20s | %-10s | %s\n" "$MOD" "$TYPE" "$STATUS"
  done <"$WLAN_STATE"
else
  echo "No external Wi‑Fi drivers processed"
fi
echo "========================================================"

###############################################################################
# FINAL
###############################################################################
ok "Installation complete"
echo "Reboot recommended"
echo "Log: $LOG"