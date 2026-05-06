#!/usr/bin/env bash
###############################################################################
# Client Simulator Installer v0.02
###############################################################################

set -euo pipefail
export PATH="/usr/sbin:/sbin:/usr/bin:/bin:$PATH"

###############################################################################
# Root check
###############################################################################
if [[ "$EUID" -ne 0 ]]; then
  echo "ERROR: This script must be run as root (e.g. sudo $0)" >&2
  exit 1
fi

###############################################################################
# Non-interactive guarantees
###############################################################################
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export GIT_TERMINAL_PROMPT=0

VERSION="0.02"

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

ts()   { date "+%H:%M:%S"; }
info() { echo "[$(ts)] INFO: $*" | tee -a "$LOG"; }
ok()   { echo "[$(ts)] OK:   $*" | tee -a "$LOG"; }
warn() { echo "[$(ts)] WARN: $*" | tee -a "$LOG"; }
err()  { echo "[$(ts)] ERR:  $*" | tee -a "$LOG" >&2; }

###############################################################################
# Startup banner  (written to both stdout AND the log)
###############################################################################
{
echo
echo "============================================================"
echo " Client Simulator Installer v${VERSION}"
echo " Started at: $(date)"
echo "============================================================"
echo
} | tee -a "$LOG"

###############################################################################
# USER PROVISIONING + SCOPED SUDO
###############################################################################
info "Ensuring user 'sim-user' exists with scoped sudo"

SIM_USER="sim-user"

if ! id "$SIM_USER" &>/dev/null; then
  useradd -m -s /bin/bash "$SIM_USER"
  ok "Created user '$SIM_USER'"
else
  ok "User '$SIM_USER' already exists"
fi

usermod -aG sudo "$SIM_USER"

# Scoped passwordless sudo — only the specific commands this user legitimately needs
cat >/etc/sudoers.d/99-simuser-nopasswd <<EOF
# Managed by client-sim-install.sh — do not edit manually
$SIM_USER ALL=(ALL) NOPASSWD: /usr/bin/apt, /usr/sbin/dpkg, /bin/systemctl, /sbin/depmod, /usr/sbin/dkms
EOF
chmod 0440 /etc/sudoers.d/99-simuser-nopasswd

# Validate the sudoers fragment before leaving it in place
if ! visudo -cf /etc/sudoers.d/99-simuser-nopasswd >>"$LOG" 2>&1; then
  err "sudoers fragment failed validation — removing"
  rm -f /etc/sudoers.d/99-simuser-nopasswd
  exit 1
fi
ok "Scoped passwordless sudo configured for '$SIM_USER'"

###############################################################################
# HELPER: retry wrapper
###############################################################################
retry() {
  local attempts=3 delay=5 cmd=("$@")
  for ((i=1; i<=attempts; i++)); do
    "${cmd[@]}" && return 0
    warn "Command failed (attempt $i/$attempts): ${cmd[*]}"
    sleep "$delay"
  done
  return 1
}

###############################################################################
# PACKAGE INSTALL
###############################################################################
info "Updating package lists"
retry apt-get update --quiet=2 >>"$LOG" 2>&1
ok "Package lists updated"

info "Installing core dependencies"
retry apt-get install -y --quiet=2 \
  gnome-terminal wget linux-headers-"$(uname -r)" \
  git qemu-guest-agent smbclient rsyslog rfkill \
  firefox-esr iperf3 dkms sysstat build-essential \
  net-tools dnsutils network-manager lightdm \
  >>"$LOG" 2>&1

apt-get autoremove -y --quiet=2 >>"$LOG" 2>&1
ok "Core dependencies installed"

###############################################################################
# Live GNOME terminal for installer log (only if a graphical session exists)
###############################################################################
if [[ -n "${DISPLAY:-}" ]] && command -v gnome-terminal &>/dev/null; then
  gnome-terminal --geometry=80x15+0+477 -- tail -f "$LOG" &
  ok "Live log terminal launched"
else
  warn "No DISPLAY detected — skipping live terminal"
fi

###############################################################################
# GNOME DISPLAY & POWER MANAGEMENT
###############################################################################
info "Disabling Wayland (forcing X11)"
if [[ -f /etc/gdm3/custom.conf ]]; then
  sed -i 's/^#\(WaylandEnable=false\)/\1/' /etc/gdm3/custom.conf
  ok "Wayland disabled in gdm3"
else
  warn "/etc/gdm3/custom.conf not found — skipping Wayland disable"
fi

# gsettings / xset / xrandr require a running user session — run as sim-user
if [[ -n "${DISPLAY:-}" && -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]]; then
  info "Disabling screen blanking and DPMS"
  sudo -u "$SIM_USER" gsettings set org.gnome.desktop.session idle-delay 0 || true
  xset s noblank   || true
  xset -dpms       || true
  xset s off       || true
  ok "Screen power management disabled"

  info "Setting screen resolution"
  xrandr --output Virtual-1 --mode 1440x900 || true
  ok "Screen resolution set"
else
  warn "No graphical session detected — skipping gsettings/xset/xrandr"
fi

###############################################################################
# RASPBERRY PI REGION
###############################################################################
if command -v raspi-config &>/dev/null; then
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
chown root:"$SIM_USER" /usr/local/scripts
chmod 775 /usr/local/scripts        # group-writable, not world-writable

touch /usr/local/scripts/sim.log
chown "$SIM_USER":"$SIM_USER" /usr/local/scripts/sim.log
chmod 664 /usr/local/scripts/sim.log
ok "/usr/local/scripts prepared"

###############################################################################
# SMB CONFIG SYNC  (authenticated + checksum validated)
###############################################################################
SMB_CREDS="/etc/client-sim/smb-credentials"   # owner=root, mode=0600
SMB_SHARE="//nas/scripts"
SMB_REMOTE_DIR="/SIM/CONFIG"

info "Syncing configuration from SMB share"

if [[ ! -f "$SMB_CREDS" ]]; then
  warn "SMB credentials file not found at $SMB_CREDS — skipping SMB sync"
  warn "Create $SMB_CREDS with: username=..., password=..., domain=..."
else
  chmod 600 "$SMB_CREDS"

  # Download conf files
  if smbclient "$SMB_SHARE" --authentication-file="$SMB_CREDS" -c \
      "lcd /usr/local/scripts; cd $SMB_REMOTE_DIR; prompt off; mget *.conf" \
      >>"$LOG" 2>&1; then

    # Validate checksums if a manifest was downloaded
    MANIFEST="/usr/local/scripts/checksums.sha256"
    if [[ -f "$MANIFEST" ]]; then
      info "Verifying SMB file checksums"
      if ! (cd /usr/local/scripts && sha256sum -c "$MANIFEST" >>"$LOG" 2>&1); then
        err "Checksum verification FAILED — aborting SMB config application"
        exit 1
      fi
      ok "SMB file checksums verified"
    else
      warn "No checksums.sha256 manifest found — skipping integrity check"
    fi
    ok "SMB config sync complete"
  else
    warn "SMB config sync failed — continuing without remote config"
  fi
fi

###############################################################################
# RSYSLOG CUSTOM CONFIG
###############################################################################
if [[ -f /usr/local/scripts/10-rsyslog.conf ]]; then
  info "Installing custom rsyslog config"
  # Validate config before installing
  if rsyslogd -N1 -f /usr/local/scripts/10-rsyslog.conf >>"$LOG" 2>&1; then
    cp /usr/local/scripts/10-rsyslog.conf /etc/rsyslog.d/10-rsyslog.conf
    systemctl restart rsyslog || true
    systemctl enable rsyslog  || true
    ok "rsyslog configured"
  else
    warn "rsyslog config validation failed — skipping install"
  fi
fi

###############################################################################
# VIRTUALHERE — SHA256-verified install
###############################################################################
info "Installing VirtualHere"

ARCH="$(uname -m)"
VH_BIN=""

# Update these checksums from https://www.virtualhere.com/usb_client_software
declare -A VH_SHA256=(
  [vhclientx86_64]="REPLACE_WITH_OFFICIAL_SHA256_FOR_x86_64"
  [vhclientarm64]="REPLACE_WITH_OFFICIAL_SHA256_FOR_arm64"
  [vhclientarm]="REPLACE_WITH_OFFICIAL_SHA256_FOR_armv7"
)

case "$ARCH" in
  x86_64)       VH_BIN="vhclientx86_64" ;;
  aarch64)      VH_BIN="vhclientarm64"  ;;
  armv7l|armhf) VH_BIN="vhclientarm"   ;;
  *)            warn "Unsupported architecture '$ARCH' for VirtualHere — skipping" ;;
esac

if [[ -n "$VH_BIN" ]]; then
  VH_TMP="$(mktemp)"
  trap 'rm -f "$VH_TMP"' EXIT

  info "Downloading VirtualHere binary: $VH_BIN"
  if retry curl -fsSL "https://www.virtualhere.com/sites/default/files/usbclient/$VH_BIN" \
      -o "$VH_TMP"; then

    # Integrity check
    EXPECTED_SUM="${VH_SHA256[$VH_BIN]:-}"
    if [[ "$EXPECTED_SUM" == "REPLACE_WITH_OFFICIAL_SHA256"* || -z "$EXPECTED_SUM" ]]; then
      warn "No checksum configured for $VH_BIN — install it from the VirtualHere website"
      warn "Skipping VirtualHere install until checksums are set in this script"
    else
      ACTUAL_SUM="$(sha256sum "$VH_TMP" | awk '{print $1}')"
      if [[ "$ACTUAL_SUM" != "$EXPECTED_SUM" ]]; then
        err "VirtualHere checksum mismatch! Expected: $EXPECTED_SUM  Got: $ACTUAL_SUM"
        exit 1
      fi

      install -o root -g root -m 0755 "$VH_TMP" /usr/sbin/vhclient

      cat >/etc/systemd/system/virtualhereclient.service <<EOF
[Unit]
Description=VirtualHere USB Client
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/sbin/vhclient
Restart=on-failure
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
EOF

      systemctl daemon-reload
      systemctl enable virtualhereclient
      systemctl start virtualhereclient

      rm -f /usr/local/scripts/vhcached.txt || true
      /usr/sbin/vhclient -t "AUTO USE CLEAR ALL"  || true
      /usr/sbin/vhclient -t "STOP USING ALL LOCAL" || true

      ok "VirtualHere installed and initialized"
    fi
  else
    warn "Failed to download VirtualHere binary — skipping"
  fi

  trap - EXIT
  rm -f "$VH_TMP"
fi

###############################################################################
# WLAN DRIVERS INSTALL
###############################################################################
info "Installing WLAN drivers"

WIFI_SRC="/usr/src/wifi-drivers"
mkdir -p "$WIFI_SRC"
cd "$WIFI_SRC"

# ── Reboot suppression shim ──────────────────────────────────────────────────
SUPPRESS="$(mktemp -d)"
for c in reboot shutdown poweroff halt; do
  printf '#!/bin/sh\necho "[SUPPRESSED] %s called — ignored during driver install" "$0"\nexit 0\n' "$c" \
    >"$SUPPRESS/$c"
  chmod +x "$SUPPRESS/$c"
done
# Wrap systemctl to block reboot/shutdown subcommands only
cat >"$SUPPRESS/systemctl" <<'SHIM'
#!/bin/sh
case "${1:-}" in
  reboot|shutdown|poweroff|halt)
    echo "[SUPPRESSED] systemctl $* ignored during driver install"
    exit 0 ;;
  *) exec /bin/systemctl "$@" ;;
esac
SHIM
chmod +x "$SUPPRESS/systemctl"
OLD_PATH="$PATH"
export PATH="$SUPPRESS:$PATH"
# ────────────────────────────────────────────────────────────────────────────

# Format: "dir-name|type|repo-url|dkms-module|pinned-tag-or-commit"
DRIVERS=(
  "8821au-20210708|morrownr|https://github.com/morrownr/8821au-20210708.git|8821au|HEAD"
  "8821cu-20210916|morrownr|https://github.com/morrownr/8821cu-20210916.git|8821cu|HEAD"
  "8814au|morrownr|https://github.com/morrownr/8814au.git|8814au|HEAD"
  "8812au-20210820|morrownr|https://github.com/morrownr/8812au-20210820.git|8812au|HEAD"
  "rtl8852bu-20240418|morrownr|https://github.com/morrownr/rtl8852bu-20240418.git|8852bu|HEAD"
  "rtl8852cu-20240510|morrownr|https://github.com/morrownr/rtl8852cu-20240510.git|8852cu|HEAD"
  "88x2bu-20210702|morrownr|https://github.com/morrownr/88x2bu-20210702.git|88x2bu|HEAD"
  "rtw89|morrownr|https://github.com/morrownr/rtw89.git|rtw89|HEAD"
  "rtl8812au|aircrack|https://github.com/aircrack-ng/rtl8812au.git|rtl8812au|HEAD"
  "rtl8188eu|lwfinger|https://github.com/lwfinger/rtl8188eu.git|8188eu|HEAD"
  "rtl8723au|lwfinger|https://github.com/lwfinger/rtl8723au.git|8723au|HEAD"
  "rtl8852au|lwfinger|https://github.com/lwfinger/rtl8852au.git|8852au|HEAD"
)

for entry in "${DRIVERS[@]}"; do
  IFS='|' read -r NAME TYPE REPO MOD PIN <<<"$entry"
  SAVED_IFS="$IFS"; IFS="$SAVED_IFS"   # restore IFS immediately
  info "Installing WLAN driver: $NAME"
  rm -rf "$NAME"

  CLONE_ARGS=(--depth=1)
  [[ "$PIN" != "HEAD" ]] && CLONE_ARGS+=(--branch "$PIN")

  if git clone "${CLONE_ARGS[@]}" "$REPO" "$NAME" >>"$LOG" 2>&1; then
    cd "$NAME"

    INSTALL_OK=true
    case "$TYPE" in
      morrownr)
        if [[ -x ./install-driver.sh ]]; then
          ./install-driver.sh NoPrompt >>"$LOG" 2>&1 || INSTALL_OK=false
        else
          warn "$NAME: install-driver.sh not found or not executable"
          INSTALL_OK=false
        fi
        ;;

      aircrack)
        if [[ -x ./install-driver.sh ]]; then
          # Pass a dummy 'yes' to suppress any prompts
          echo "" | ./install-driver.sh >>"$LOG" 2>&1 || INSTALL_OK=false
        else
          warn "$NAME: install-driver.sh not found or not executable"
          INSTALL_OK=false
        fi
        ;;

      lwfinger)
        if make all >>"$LOG" 2>&1 && make install >>"$LOG" 2>&1; then
          # Extract version from dkms.conf if present
          if [[ -f dkms.conf ]]; then
            DKMS_VER="$(grep -Po '(?<=PACKAGE_VERSION=")[^"]+' dkms.conf || true)"
          fi
          DKMS_VER="${DKMS_VER:-0.0}"

          dkms add    . >>"$LOG" 2>&1 || true
          if ! dkms install "${MOD}/${DKMS_VER}" >>"$LOG" 2>&1; then
            warn "$NAME: dkms install failed (non-fatal)"
          fi
        else
          INSTALL_OK=false
        fi
        ;;
    esac

    cd "$WIFI_SRC"

    if $INSTALL_OK; then
      echo "$NAME:INSTALLED" >>"$DRIVER_STATE"
      ok "WLAN driver $NAME installed"
    else
      echo "$NAME:FAILED" >>"$DRIVER_STATE"
      warn "WLAN driver $NAME build/install failed"
    fi
  else
    echo "$NAME:CLONE_FAILED" >>"$DRIVER_STATE"
    warn "Failed to clone $NAME from $REPO"
  fi
done

depmod -a >>"$LOG" 2>&1
export PATH="$OLD_PATH"
rm -rf "$SUPPRESS"
ok "WLAN driver installation complete"

###############################################################################
# FINAL HEALTH SUMMARY
###############################################################################
{
echo "================ HEALTH CHECK ================"
id "$SIM_USER"    &>/dev/null              && echo "User ($SIM_USER): OK"    || echo "User ($SIM_USER): MISSING"
groups "$SIM_USER" | grep -q sudo          && echo "Sudo group:       OK"    || echo "Sudo group:       MISSING"
systemctl is-active --quiet lightdm        && echo "LightDM:          OK"    || echo "LightDM:          NOT ACTIVE"
systemctl is-active --quiet NetworkManager && echo "NetworkManager:   OK"    || echo "NetworkManager:   NOT ACTIVE"
systemctl is-active --quiet virtualhereclient \
                                           && echo "VirtualHere:      OK"    || echo "VirtualHere:      NOT ACTIVE"
lsmod | grep -qE '88|rtw|885'             && echo "WLAN modules:     LOADED" || echo "WLAN modules:     NOT LOADED"

echo ""
echo "---- Driver State ----"
cat "$DRIVER_STATE"
echo "============================================="
} | tee -a "$LOG"

###############################################################################
# END
###############################################################################
ok "Installation complete — reboot recommended"
info "Full log: $LOG"
info "Driver state: $DRIVER_STATE"