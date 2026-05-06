#!/usr/bin/env bash
###############################################################################
# Client Simulator Installer v0.03
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

VERSION="0.03"

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
# PROGRESS TRACKING
###############################################################################
# Define all phases and their weights (must sum to 100)
#   Phase name                    Weight
PHASE_NAMES=(
  "User Provisioning"             # 5
  "Package Install"               # 10
  "GNOME Configuration"           # 5
  "Scripts Directory"             # 2
  "SMB Config Sync"               # 5
  "rsyslog Config"                # 3
  "VirtualHere Install"           # 10
  "WLAN Drivers"                  # 55
  "Network Apps"                  # 3
  "Health Check"                  # 2
)
PHASE_WEIGHTS=( 5 10 5 2 5 3 10 55 3 2 )

CURRENT_PHASE=0
CURRENT_PROGRESS=0   # cumulative % completed so far
SPINNER_PID=""

# ── Terminal colour/width helpers ────────────────────────────────────────────
TERM_WIDTH=80
if command -v tput &>/dev/null && tput cols &>/dev/null 2>&1; then
  TERM_WIDTH="$(tput cols)"
fi
BAR_WIDTH=$(( TERM_WIDTH - 30 ))   # leave room for label & percentage
[[ "$BAR_WIDTH" -lt 20 ]] && BAR_WIDTH=20

COL_RESET="\033[0m"
COL_GREEN="\033[0;32m"
COL_CYAN="\033[0;36m"
COL_YELLOW="\033[1;33m"
COL_BOLD="\033[1m"

# ── Draw the progress bar ────────────────────────────────────────────────────
# Usage: draw_bar <percent 0-100> <label>
draw_bar() {
  local pct="$1"
  local label="$2"
  local filled=$(( pct * BAR_WIDTH / 100 ))
  local empty=$(( BAR_WIDTH - filled ))
  local bar=""

  for (( i=0; i<filled; i++ )); do bar+="█"; done
  for (( i=0; i<empty;  i++ )); do bar+="░"; done

  # Choose colour by completion
  local col="$COL_GREEN"
  [[ "$pct" -lt 50 ]] && col="$COL_CYAN"
  [[ "$pct" -lt 20 ]] && col="$COL_YELLOW"

  # \r to overwrite the same line; no newline at end
  printf "\r${COL_BOLD}%-18s${COL_RESET} ${col}%s${COL_RESET} ${COL_BOLD}%3d%%${COL_RESET}" \
    "${label:0:18}" "$bar" "$pct"
}

# ── Advance to the next phase ────────────────────────────────────────────────
# Call at the START of each phase.
begin_phase() {
  # Stop any running spinner first
  stop_spinner

  local name="${PHASE_NAMES[$CURRENT_PHASE]:-Unknown}"
  local weight="${PHASE_WEIGHTS[$CURRENT_PHASE]:-0}"

  draw_bar "$CURRENT_PROGRESS" "$name"
  echo ""   # newline after the bar so info() lines scroll below it

  info "Phase $((CURRENT_PHASE+1))/${#PHASE_NAMES[@]}: $name"
}

# Call at the END of each phase.
end_phase() {
  stop_spinner
  local weight="${PHASE_WEIGHTS[$CURRENT_PHASE]:-0}"
  CURRENT_PROGRESS=$(( CURRENT_PROGRESS + weight ))
  [[ "$CURRENT_PROGRESS" -gt 100 ]] && CURRENT_PROGRESS=100

  local name="${PHASE_NAMES[$CURRENT_PHASE]:-Unknown}"
  draw_bar "$CURRENT_PROGRESS" "$name"
  printf "  ✓\n"

  CURRENT_PHASE=$(( CURRENT_PHASE + 1 ))
}

# ── Sub-step progress within a phase ────────────────────────────────────────
# Usage: phase_step <current_step> <total_steps> <label>
# Renders fractional progress within the current phase weight.
phase_step() {
  local step="$1" total="$2" label="$3"
  local weight="${PHASE_WEIGHTS[$CURRENT_PHASE]:-0}"
  local prev_weight=0

  # Sum weights of completed phases
  for (( i=0; i<CURRENT_PHASE; i++ )); do
    prev_weight=$(( prev_weight + PHASE_WEIGHTS[i] ))
  done

  local frac_pct=$(( prev_weight + (step * weight / total) ))
  draw_bar "$frac_pct" "${PHASE_NAMES[$CURRENT_PHASE]:-}"
}

# ── Spinner for commands where progress is unknown ───────────────────────────
SPINNER_FRAMES=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")

start_spinner() {
  local label="${1:-Working...}"
  stop_spinner   # ensure no double-spinner

  (
    local i=0
    while true; do
      printf "\r  ${COL_CYAN}%s${COL_RESET}  %s " "${SPINNER_FRAMES[$i]}" "$label"
      i=$(( (i + 1) % ${#SPINNER_FRAMES[@]} ))
      sleep 0.1
    done
  ) &
  SPINNER_PID=$!
  disown "$SPINNER_PID" 2>/dev/null || true
}

stop_spinner() {
  if [[ -n "${SPINNER_PID:-}" ]]; then
    kill "$SPINNER_PID" 2>/dev/null || true
    wait "$SPINNER_PID" 2>/dev/null || true
    SPINNER_PID=""
    printf "\r\033[K"   # clear the spinner line
  fi
}

# Ensure spinner is always stopped on exit
trap 'stop_spinner; tput cnorm 2>/dev/null || true' EXIT

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

# Hide cursor during install for cleaner output
tput civis 2>/dev/null || true

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
# PHASE 1 — USER PROVISIONING + SCOPED SUDO
###############################################################################
begin_phase
SIM_USER="sim-user"

start_spinner "Checking user '$SIM_USER'"
if ! id "$SIM_USER" &>/dev/null; then
  useradd -m -s /bin/bash "$SIM_USER" >>"$LOG" 2>&1
  stop_spinner; ok "Created user '$SIM_USER'"
else
  stop_spinner; ok "User '$SIM_USER' already exists"
fi

start_spinner "Configuring sudoers"
usermod -aG sudo "$SIM_USER"

cat >/etc/sudoers.d/99-simuser-nopasswd <<EOF
# Managed by client-sim-install.sh — do not edit manually
$SIM_USER ALL=(ALL) NOPASSWD: /usr/bin/apt, /usr/sbin/dpkg, /bin/systemctl, /sbin/depmod, /usr/sbin/dkms
EOF
chmod 0440 /etc/sudoers.d/99-simuser-nopasswd

if ! visudo -cf /etc/sudoers.d/99-simuser-nopasswd >>"$LOG" 2>&1; then
  stop_spinner
  err "sudoers fragment failed validation — removing"
  rm -f /etc/sudoers.d/99-simuser-nopasswd
  exit 1
fi
stop_spinner
ok "Scoped passwordless sudo configured for '$SIM_USER'"
end_phase

###############################################################################
# PHASE 2 — PACKAGE INSTALL
###############################################################################
begin_phase

PACKAGES=(
  gnome-terminal wget "linux-headers-$(uname -r)"
  git qemu-guest-agent smbclient rsyslog rfkill
  firefox-esr iperf3 dkms sysstat build-essential
  net-tools dnsutils network-manager lightdm
)
TOTAL_PKGS="${#PACKAGES[@]}"

start_spinner "Updating package lists"
retry apt-get update --quiet=2 >>"$LOG" 2>&1
stop_spinner; ok "Package lists updated"

# Install in smaller batches so we can show sub-step progress
BATCH_SIZE=5
BATCH_NUM=0
INSTALLED_COUNT=0

for (( i=0; i<TOTAL_PKGS; i+=BATCH_SIZE )); do
  BATCH=( "${PACKAGES[@]:$i:$BATCH_SIZE}" )
  BATCH_NUM=$(( BATCH_NUM + 1 ))
  INSTALLED_COUNT=$(( i + ${#BATCH[@]} ))
  [[ "$INSTALLED_COUNT" -gt "$TOTAL_PKGS" ]] && INSTALLED_COUNT="$TOTAL_PKGS"

  stop_spinner
  phase_step "$INSTALLED_COUNT" "$TOTAL_PKGS" ""
  start_spinner "Installing: ${BATCH[*]}"

  retry apt-get install -y --quiet=2 "${BATCH[@]}" >>"$LOG" 2>&1
done

stop_spinner
start_spinner "Running autoremove"
apt-get autoremove -y --quiet=2 >>"$LOG" 2>&1
stop_spinner; ok "Core dependencies installed"
end_phase

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
# PHASE 3 — GNOME DISPLAY & POWER MANAGEMENT
###############################################################################
begin_phase

start_spinner "Disabling Wayland"
if [[ -f /etc/gdm3/custom.conf ]]; then
  sed -i 's/^#\(WaylandEnable=false\)/\1/' /etc/gdm3/custom.conf
  stop_spinner; ok "Wayland disabled in gdm3"
else
  stop_spinner; warn "/etc/gdm3/custom.conf not found — skipping"
fi

if [[ -n "${DISPLAY:-}" && -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]]; then
  start_spinner "Disabling screen blanking and DPMS"
  sudo -u "$SIM_USER" gsettings set org.gnome.desktop.session idle-delay 0 || true
  xset s noblank || true
  xset -dpms     || true
  xset s off     || true
  stop_spinner; ok "Screen power management disabled"

  start_spinner "Setting screen resolution"
  xrandr --output Virtual-1 --mode 1440x900 || true
  stop_spinner; ok "Screen resolution set"
else
  warn "No graphical session — skipping gsettings/xset/xrandr"
fi

if command -v raspi-config &>/dev/null; then
  start_spinner "Configuring Raspberry Pi locale and Wi-Fi region"
  raspi-config nonint do_change_locale en_US.UTF-8
  raspi-config nonint do_wifi_country US
  stop_spinner; ok "Raspberry Pi configured"
fi

end_phase

###############################################################################
# PHASE 4 — /usr/local/scripts population
###############################################################################
begin_phase

start_spinner "Preparing /usr/local/scripts"
mkdir -p /usr/local/scripts
chown root:"$SIM_USER" /usr/local/scripts
chmod 775 /usr/local/scripts
touch /usr/local/scripts/sim.log
chown "$SIM_USER":"$SIM_USER" /usr/local/scripts/sim.log
chmod 664 /usr/local/scripts/sim.log
stop_spinner; ok "/usr/local/scripts prepared"
end_phase

###############################################################################
# PHASE 5 — SMB CONFIG SYNC
###############################################################################
begin_phase

SMB_CREDS="/etc/client-sim/smb-credentials"
SMB_SHARE="//nas/scripts"
SMB_REMOTE_DIR="/SIM/CONFIG"

if [[ ! -f "$SMB_CREDS" ]]; then
  warn "SMB credentials file not found at $SMB_CREDS — skipping SMB sync"
  warn "Create $SMB_CREDS with: username=..., password=..., domain=..."
else
  chmod 600 "$SMB_CREDS"
  start_spinner "Syncing config files from SMB share"
  if smbclient "$SMB_SHARE" --authentication-file="$SMB_CREDS" -c \
      "lcd /usr/local/scripts; cd $SMB_REMOTE_DIR; prompt off; mget *.conf" \
      >>"$LOG" 2>&1; then
    stop_spinner

    MANIFEST="/usr/local/scripts/checksums.sha256"
    if [[ -f "$MANIFEST" ]]; then
      start_spinner "Verifying SMB file checksums"
      if ! (cd /usr/local/scripts && sha256sum -c "$MANIFEST" >>"$LOG" 2>&1); then
        stop_spinner
        err "Checksum verification FAILED — aborting"
        exit 1
      fi
      stop_spinner; ok "SMB file checksums verified"
    else
      warn "No checksums.sha256 manifest — skipping integrity check"
    fi
    ok "SMB config sync complete"
  else
    stop_spinner; warn "SMB config sync failed — continuing without remote config"
  fi
fi
end_phase

###############################################################################
# PHASE 6 — RSYSLOG CUSTOM CONFIG
###############################################################################
begin_phase

if [[ -f /usr/local/scripts/10-rsyslog.conf ]]; then
  start_spinner "Validating and installing rsyslog config"
  if rsyslogd -N1 -f /usr/local/scripts/10-rsyslog.conf >>"$LOG" 2>&1; then
    cp /usr/local/scripts/10-rsyslog.conf /etc/rsyslog.d/10-rsyslog.conf
    systemctl restart rsyslog || true
    systemctl enable rsyslog  || true
    stop_spinner; ok "rsyslog configured"
  else
    stop_spinner; warn "rsyslog config validation failed — skipping"
  fi
else
  warn "No custom rsyslog config found — skipping"
fi
end_phase

###############################################################################
# PHASE 7 — VIRTUALHERE INSTALL
###############################################################################
begin_phase
info "Installing VirtualHere"

ARCH="$(uname -m)"
VH_BIN=""

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

  start_spinner "Downloading VirtualHere ($VH_BIN)"
  if retry curl -fsSL "https://www.virtualhere.com/sites/default/files/usbclient/$VH_BIN" \
      -o "$VH_TMP"; then
    stop_spinner

    EXPECTED_SUM="${VH_SHA256[$VH_BIN]:-}"
    if [[ "$EXPECTED_SUM" == "REPLACE_WITH_OFFICIAL_SHA256"* || -z "$EXPECTED_SUM" ]]; then
      warn "No checksum configured for $VH_BIN — skipping install until checksums are set"
    else
      start_spinner "Verifying VirtualHere binary"
      ACTUAL_SUM="$(sha256sum "$VH_TMP" | awk '{print $1}')"
      if [[ "$ACTUAL_SUM" != "$EXPECTED_SUM" ]]; then
        stop_spinner
        err "VirtualHere checksum mismatch! Expected: $EXPECTED_SUM  Got: $ACTUAL_SUM"
        rm -f "$VH_TMP"
        exit 1
      fi
      stop_spinner; ok "VirtualHere checksum verified"

      install -o root -g root -m 0755 "$VH_TMP" /usr/sbin/vhclient

      start_spinner "Creating VirtualHere systemd service"
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
      stop_spinner

      rm -f /usr/local/scripts/vhcached.txt || true
      /usr/sbin/vhclient -t "AUTO USE CLEAR ALL"   || true
      /usr/sbin/vhclient -t "STOP USING ALL LOCAL"  || true

      ok "VirtualHere installed and initialized"
    fi
  else
    stop_spinner; warn "Failed to download VirtualHere binary — skipping"
  fi
  rm -f "$VH_TMP"
fi
end_phase

###############################################################################
# PHASE 8 — WLAN DRIVERS INSTALL
###############################################################################
begin_phase

WIFI_SRC="/usr/src/wifi-drivers"
mkdir -p "$WIFI_SRC"
cd "$WIFI_SRC"

# ── Reboot suppression shim ──────────────────────────────────────────────────
SUPPRESS="$(mktemp -d)"
for c in reboot shutdown poweroff halt; do
  printf '#!/bin/sh\necho "[SUPPRESSED] %s called — ignored during driver install"\nexit 0\n' "$c" \
    >"$SUPPRESS/$c"
  chmod +x "$SUPPRESS/$c"
done
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

TOTAL_DRIVERS="${#DRIVERS[@]}"
DRIVER_NUM=0

for entry in "${DRIVERS[@]}"; do
  SAVED_IFS="$IFS"
  IFS='|' read -r NAME TYPE REPO MOD PIN <<<"$entry"
  IFS="$SAVED_IFS"

  DRIVER_NUM=$(( DRIVER_NUM + 1 ))

  # Sub-step progress bar for this driver within the phase weight
  stop_spinner
  phase_step "$DRIVER_NUM" "$TOTAL_DRIVERS" ""
  printf "  [%d/%d] " "$DRIVER_NUM" "$TOTAL_DRIVERS"

  info "Installing WLAN driver: $NAME ($DRIVER_NUM/$TOTAL_DRIVERS)"
  rm -rf "$NAME"

  CLONE_ARGS=(--depth=1)
  [[ "$PIN" != "HEAD" ]] && CLONE_ARGS+=(--branch "$PIN")

  start_spinner "Cloning $NAME"
  if git clone "${CLONE_ARGS[@]}" "$REPO" "$NAME" >>"$LOG" 2>&1; then
    stop_spinner
    cd "$NAME"

    INSTALL_OK=true
    case "$TYPE" in
      morrownr)
        if [[ -x ./install-driver.sh ]]; then
          start_spinner "Building $NAME (morrownr)"
          ./install-driver.sh NoPrompt >>"$LOG" 2>&1 || INSTALL_OK=false
          stop_spinner
        else
          warn "$NAME: install-driver.sh not found or not executable"
          INSTALL_OK=false
        fi
        ;;

      aircrack)
        if [[ -x ./install-driver.sh ]]; then
          start_spinner "Building $NAME (aircrack-ng)"
          echo "" | ./install-driver.sh >>"$LOG" 2>&1 || INSTALL_OK=false
          stop_spinner
        else
          warn "$NAME: install-driver.sh not found or not executable"
          INSTALL_OK=false
        fi
        ;;

      lwfinger)
        start_spinner "Building $NAME (lwfinger)"
        if make all >>"$LOG" 2>&1 && make install >>"$LOG" 2>&1; then
          stop_spinner
          DKMS_VER="0.0"
          if [[ -f dkms.conf ]]; then
            DKMS_VER="$(grep -Po '(?<=PACKAGE_VERSION=")[^"]+' dkms.conf || echo "0.0")"
          fi
          start_spinner "DKMS install $NAME"
          dkms add    . >>"$LOG" 2>&1 || true
          dkms install "${MOD}/${DKMS_VER}" >>"$LOG" 2>&1 \
            || warn "$NAME: dkms install failed (non-fatal)"
          stop_spinner
        else
          stop_spinner
          INSTALL_OK=false
        fi
        ;;
    esac

    cd "$WIFI_SRC"

    if $INSTALL_OK; then
      echo "$NAME:INSTALLED" >>"$DRIVER_STATE"
      ok "✓ WLAN driver $NAME installed ($DRIVER_NUM/$TOTAL_DRIVERS)"
    else
      echo "$NAME:FAILED" >>"$DRIVER_STATE"
      warn "✗ WLAN driver $NAME failed ($DRIVER_NUM/$TOTAL_DRIVERS)"
    fi
  else
    stop_spinner
    echo "$NAME:CLONE_FAILED" >>"$DRIVER_STATE"
    warn "✗ Failed to clone $NAME ($DRIVER_NUM/$TOTAL_DRIVERS)"
  fi
done

start_spinner "Running depmod"
depmod -a >>"$LOG" 2>&1
stop_spinner

export PATH="$OLD_PATH"
rm -rf "$SUPPRESS"
ok "WLAN driver installation complete"
end_phase

###############################################################################
# PHASE 9 — NETWORK APPS
###############################################################################
begin_phase

start_spinner "Installing network tools"
retry apt-get install -y --quiet=2 \
  net-tools dnsutils network-manager >>"$LOG" 2>&1
stop_spinner

start_spinner "Running autoremove"
apt-get autoremove -y --quiet=2 >>"$LOG" 2>&1
stop_spinner; ok "Network tools installed"
end_phase

###############################################################################
# PHASE 10 — FINAL HEALTH SUMMARY
###############################################################################
begin_phase

# Restore cursor before printing final report
tput cnorm 2>/dev/null || true

echo ""
{
echo "================ HEALTH CHECK ================"
id "$SIM_USER"    &>/dev/null              && echo "  User ($SIM_USER):   OK"      || echo "  User ($SIM_USER):   MISSING"
groups "$SIM_USER" | grep -q sudo          && echo "  Sudo group:         OK"      || echo "  Sudo group:         MISSING"
systemctl is-active --quiet lightdm        && echo "  LightDM:            OK"      || echo "  LightDM:            NOT ACTIVE"
systemctl is-active --quiet NetworkManager && echo "  NetworkManager:     OK"      || echo "  NetworkManager:     NOT ACTIVE"
systemctl is-active --quiet virtualhereclient \
                                           && echo "  VirtualHere:        OK"      || echo "  VirtualHere:        NOT ACTIVE"
lsmod | grep -qE '88|rtw|885'             && echo "  WLAN modules:       LOADED"  || echo "  WLAN modules:       NOT LOADED"

echo ""
echo "  ---- Driver State ----"
while IFS=: read -r drv status; do
  case "$status" in
    INSTALLED)    printf "  ✓ %-35s INSTALLED\n"    "$drv" ;;
    FAILED)       printf "  ✗ %-35s FAILED\n"       "$drv" ;;
    CLONE_FAILED) printf "  ✗ %-35s CLONE FAILED\n" "$drv" ;;
    *)            printf "  ? %-35s %s\n"            "$drv" "$status" ;;
  esac
done < "$DRIVER_STATE"

echo "============================================="
} | tee -a "$LOG"

end_phase

###############################################################################
# FINAL PROGRESS BAR — 100%
###############################################################################
draw_bar 100 "Complete"
printf "  ✓\n\n"

###############################################################################
# END
###############################################################################
ok "Installation complete — reboot recommended"
info "Full log:      $LOG"
info "Driver state:  $DRIVER_STATE"