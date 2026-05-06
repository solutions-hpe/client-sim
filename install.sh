#!/usr/bin/env bash
###############################################################################
# Client Simulator Installer v0.09
###############################################################################

set -euo pipefail
export PATH="/usr/sbin:/sbin:/usr/bin:/bin:$PATH"

###############################################################################
# Debug flag  (sudo bash install.sh --debug)
###############################################################################
DEBUG=0
for arg in "$@"; do
  [[ "$arg" == "--debug" || "$arg" == "-d" ]] && DEBUG=1
done

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
export NEEDRESTART_SUSPEND=1          # belt-and-suspenders for needrestart
export GIT_TERMINAL_PROMPT=0
export UCF_FORCE_CONFFOLD=1           # stop ucf (rsyslog/others) from prompting
export APT_LISTCHANGES_FRONTEND=none  # suppress apt-listchanges pager

VERSION="0.14"
INSTALL_START=$(date +%s)
WARN_COUNT=0
ERR_COUNT=0
PHASE_START=0

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
warn() { WARN_COUNT=$(( WARN_COUNT + 1 )); echo "[$(ts)] WARN: $*" | tee -a "$LOG"; }
err()  { ERR_COUNT=$(( ERR_COUNT + 1 ));  echo "[$(ts)] ERR:  $*" | tee -a "$LOG" >&2; }

###############################################################################
# PROGRESS TRACKING
###############################################################################
PHASE_NAMES=(
  "User Provisioning"
  "Package Install"
  "GNOME Configuration"
  "Scripts Directory"
  "Client-Sim Repo"
  "SMB Config Sync"
  "rsyslog Config"
  "VirtualHere Install"
  "WLAN Drivers"
  "Health Check"
)
PHASE_WEIGHTS=( 4 12 5 2 8 5 3 10 49 2 )

CURRENT_PHASE=0
CURRENT_PROGRESS=0
SPINNER_PID=""

# ── Terminal helpers ─────────────────────────────────────────────────────────
TERM_WIDTH=80
if command -v tput &>/dev/null && tput cols &>/dev/null 2>&1; then
  TERM_WIDTH="$(tput cols)"
fi
BAR_WIDTH=$(( TERM_WIDTH - 30 ))
[[ "$BAR_WIDTH" -lt 20 ]] && BAR_WIDTH=20

COL_RESET="\033[0m"
COL_GREEN="\033[0;32m"
COL_RED="\033[0;31m"
COL_CYAN="\033[0;36m"
COL_YELLOW="\033[1;33m"
COL_BOLD="\033[1m"
COL_DIM="\033[2m"

# ── Draw progress bar ────────────────────────────────────────────────────────
draw_bar() {
  local pct="$1" label="$2"
  local filled=$(( pct * BAR_WIDTH / 100 ))
  local empty=$(( BAR_WIDTH - filled ))
  local bar=""

  for (( i=0; i<filled; i++ )); do bar+="█"; done
  for (( i=0; i<empty;  i++ )); do bar+="░"; done

  printf "\r${COL_BOLD}%-20s${COL_RESET} %s ${COL_BOLD}%3d%%${COL_RESET}" \
    "${label:0:20}" "$bar" "$pct"
}

# ── Phase control ────────────────────────────────────────────────────────────
begin_phase() {
  stop_spinner
  PHASE_START=$(date +%s)
  local name="${PHASE_NAMES[$CURRENT_PHASE]:-Unknown}"
  draw_bar "$CURRENT_PROGRESS" "$name"
  echo ""
  info "Phase $((CURRENT_PHASE+1))/${#PHASE_NAMES[@]}: $name"
}

end_phase() {
  stop_spinner
  local elapsed=$(( $(date +%s) - PHASE_START ))
  local weight="${PHASE_WEIGHTS[$CURRENT_PHASE]:-0}"
  CURRENT_PROGRESS=$(( CURRENT_PROGRESS + weight ))
  [[ "$CURRENT_PROGRESS" -gt 100 ]] && CURRENT_PROGRESS=100
  local name="${PHASE_NAMES[$CURRENT_PHASE]:-Unknown}"
  draw_bar "$CURRENT_PROGRESS" "$name"
  printf "  ${COL_GREEN}✓${COL_RESET}  ${COL_DIM}(%ds)${COL_RESET}\n" "$elapsed"
  CURRENT_PHASE=$(( CURRENT_PHASE + 1 ))
}

# ── Sub-step progress within a phase ────────────────────────────────────────
phase_step() {
  local step="$1" total="$2"
  local weight="${PHASE_WEIGHTS[$CURRENT_PHASE]:-0}"
  local prev_weight=0
  for (( i=0; i<CURRENT_PHASE; i++ )); do
    prev_weight=$(( prev_weight + PHASE_WEIGHTS[i] ))
  done
  local frac_pct=$(( prev_weight + (step * weight / total) ))
  draw_bar "$frac_pct" "${PHASE_NAMES[$CURRENT_PHASE]:-}"
}

# ── Spinner ──────────────────────────────────────────────────────────────────
SPINNER_FRAMES=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")

start_spinner() {
  local label="${1:-Working...}"
  stop_spinner
  (
    local i=0
    while true; do
      printf "\r  ${COL_CYAN}%s${COL_RESET}  %s " "${SPINNER_FRAMES[$i]}" "$label"
      i=$(( (i + 1) % ${#SPINNER_FRAMES[@]} ))
      sleep 0.1
    done
  ) &
  SPINNER_PID=$!
}

stop_spinner() {
  if [[ -n "${SPINNER_PID:-}" ]]; then
    kill "$SPINNER_PID" 2>/dev/null || true
    wait "$SPINNER_PID" 2>/dev/null || true
    SPINNER_PID=""
    printf "\r\033[K"
  fi
}

trap 'stop_spinner; tput cnorm 2>/dev/null || true' EXIT
trap 'echo; echo; printf "${COL_RED}Installation cancelled by user.${COL_RESET}\n"; stop_spinner; tput cnorm 2>/dev/null || true; exit 130' INT

###############################################################################
# Startup banner
###############################################################################
{
echo
echo "============================================================"
echo " Client Simulator Installer v${VERSION}"
echo " Started at: $(date)"
[[ "$DEBUG" -eq 1 ]] && echo " *** DEBUG MODE — apt output shown on screen ***"
echo "============================================================"
echo
} | tee -a "$LOG"

# Hide cursor during install
tput civis 2>/dev/null || true

# ── Pre-flight summary ───────────────────────────────────────────────────────
printf "${COL_DIM}  Phases : ${COL_RESET}"
for (( i=0; i<${#PHASE_NAMES[@]}; i++ )); do
  [[ $i -gt 0 ]] && printf "${COL_DIM} →${COL_RESET} "
  printf "${COL_DIM}%s${COL_RESET}" "${PHASE_NAMES[$i]}"
done
printf "\n"
printf "${COL_DIM}  Log    : %s${COL_RESET}\n" "$LOG"
printf "${COL_DIM}  Press Ctrl+C at any time to abort.${COL_RESET}\n"
echo

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
# HELPER: apt_run — silent normally, live output in --debug mode
#         timeout baked in: APT_TIMEOUT seconds (default 300)
# Usage: apt_run [apt-get args...]
###############################################################################
APT_TIMEOUT=300
apt_run() {
  if [[ "$DEBUG" -eq 1 ]]; then
    stop_spinner
    printf "\n${COL_DIM}  [DEBUG] apt-get %s${COL_RESET}\n" "$*"
    timeout "$APT_TIMEOUT" apt-get "$@" 2>&1 | tee -a "$LOG"
    local rc=${PIPESTATUS[0]}
    return $rc
  else
    timeout "$APT_TIMEOUT" apt-get "$@" >>"$LOG" 2>&1
  fi
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

cat >/etc/sudoers.d/99-simuser-nopasswd <<EOF
# Managed by client-sim-install.sh — do not edit manually
$SIM_USER ALL=(ALL) NOPASSWD: /usr/bin/apt-get, /usr/sbin/dpkg, /bin/systemctl, /sbin/depmod, /usr/sbin/dkms
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

# ── SMB credentials template ─────────────────────────────────────────────────
start_spinner "Checking SMB credentials file"
SMB_CREDS_DIR="/etc/client-sim"
SMB_CREDS="$SMB_CREDS_DIR/smb-credentials"
mkdir -p "$SMB_CREDS_DIR"
if [[ ! -f "$SMB_CREDS" ]]; then
  cat >"$SMB_CREDS" <<'CREDS'
# client-sim SMB credentials — edit before running installer
# username=your_username
# password=your_password
# domain=your_domain
CREDS
  chmod 600 "$SMB_CREDS"
  stop_spinner
  warn "SMB credentials template created at $SMB_CREDS — edit it to enable SMB sync"
else
  chmod 600 "$SMB_CREDS"
  stop_spinner; ok "SMB credentials file already exists"
fi
end_phase

###############################################################################
# PHASE 2 — PACKAGE INSTALL  (update + upgrade + install)
###############################################################################
begin_phase

start_spinner "Updating package lists"
retry apt_run update --quiet=2
stop_spinner; ok "Package lists updated"

# Pre-seed debconf answers for packages known to prompt interactively.
# samba-common ignores DEBIAN_FRONTEND without do_debconf=false.
start_spinner "Pre-seeding debconf answers"
{
  # samba-common: do_debconf=false prevents ALL interactive questions
  echo "samba-common samba-common/do_debconf boolean false"
  echo "samba-common samba-common/workgroup string WORKGROUP"
  echo "samba-common samba-common/dhcp boolean false"
  echo "samba-common samba-common/smb.conf.update.template boolean false"
  echo "samba-common samba-common/smb.conf.upgrade boolean false"
  # rsyslog
  echo "rsyslog rsyslog/enable_all boolean false"
  # display manager
  echo "lightdm shared/default-x-display-manager select lightdm"
  echo "gdm3 shared/default-x-display-manager select lightdm"
} | debconf-set-selections >>"$LOG" 2>&1
stop_spinner; ok "debconf answers pre-seeded"

start_spinner "Upgrading existing packages"
retry apt_run upgrade -y --quiet \
  -o Dpkg::Options::="--force-confdef" \
  -o Dpkg::Options::="--force-confold"
stop_spinner; ok "System packages upgraded"

PACKAGES=(
  "gnome-terminal"
  "wget"
  "linux-headers-$(uname -r)"
  "git"
  "qemu-guest-agent"
  "smbclient"
  "rsyslog"
  "rfkill"
  "firefox-esr"
  "iperf3"
  "dkms"
  "build-essential"
  "net-tools"
  "dnsutils"
  "network-manager"
  "lightdm"
)
TOTAL_PKGS="${#PACKAGES[@]}"
BATCH_SIZE=4
INSTALLED_COUNT=0

for (( i=0; i<TOTAL_PKGS; i+=BATCH_SIZE )); do
  BATCH=( "${PACKAGES[@]:$i:$BATCH_SIZE}" )
  INSTALLED_COUNT=$(( i + ${#BATCH[@]} ))
  [[ "$INSTALLED_COUNT" -gt "$TOTAL_PKGS" ]] && INSTALLED_COUNT="$TOTAL_PKGS"

  stop_spinner
  phase_step "$INSTALLED_COUNT" "$TOTAL_PKGS"
  start_spinner "Installing: ${BATCH[*]}"
  info "Batch install start [$(ts)]: ${BATCH[*]}"
  if ! apt_run install -y --quiet \
      -o Dpkg::Options::="--force-confdef" \
      -o Dpkg::Options::="--force-confold" \
      "${BATCH[@]}"; then
    stop_spinner
    warn "Batch install failed or timed out: ${BATCH[*]} — retrying individually"
    for pkg in "${BATCH[@]}"; do
      info "Retrying individual install: $pkg"
      APT_TIMEOUT=180
      apt_run install -y --quiet \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold" \
        "$pkg" \
        && ok "Installed: $pkg" \
        || warn "Failed to install: $pkg (non-fatal, continuing)"
      APT_TIMEOUT=300
    done
    start_spinner "Installing: ${BATCH[*]}"
  fi
  info "Batch install end   [$(ts)]: ${BATCH[*]}"
done

stop_spinner
start_spinner "Running autoremove"
apt_run autoremove -y --quiet=2
stop_spinner; ok "Core dependencies installed"
end_phase

###############################################################################
# Live GNOME terminal for installer log
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

  start_spinner "Setting screen resolution to 1440x900"
  xrandr --output Virtual-1 --mode 1440x900 || true
  stop_spinner; ok "Screen resolution set"
else
  warn "No graphical session — skipping gsettings/xset/xrandr"
fi

if command -v raspi-config &>/dev/null; then
  start_spinner "Configuring Raspberry Pi locale and Wi-Fi region"
  raspi-config nonint do_change_locale en_US.UTF-8
  raspi-config nonint do_wifi_country US
  stop_spinner; ok "Raspberry Pi locale and Wi-Fi region configured"
fi

end_phase

###############################################################################
# PHASE 4 — /usr/local/scripts setup
###############################################################################
begin_phase

start_spinner "Preparing /usr/local/scripts"
mkdir -p /usr/local/scripts
chown root:"$SIM_USER" /usr/local/scripts
chmod 775 /usr/local/scripts

touch /usr/local/scripts/sim.log
chown "$SIM_USER":"$SIM_USER" /usr/local/scripts/sim.log
chmod 664 /usr/local/scripts/sim.log

# Write installer version to sim.log (from original script)
echo "Installer Version $VERSION" | tee /usr/local/scripts/sim.log >>"$LOG"

stop_spinner; ok "/usr/local/scripts prepared — version $VERSION written to sim.log"
end_phase

###############################################################################
# PHASE 5 — CLIENT-SIM GITHUB REPO CLONE + FILE DEPLOYMENT
###############################################################################
begin_phase

CLIENT_SIM_REPO="https://github.com/solutions-hpe/client-sim.git"
CLIENT_SIM_DIR="$HOME/client-sim"

start_spinner "Cloning solutions-hpe/client-sim"
rm -rf "$CLIENT_SIM_DIR"
if retry git clone --depth=1 "$CLIENT_SIM_REPO" "$CLIENT_SIM_DIR" >>"$LOG" 2>&1; then
  stop_spinner; ok "client-sim repo cloned"

  LINUX_DIR="$CLIENT_SIM_DIR/linux"
  CONFIGS_DIR="$CLIENT_SIM_DIR/configs"

  if [[ -d "$LINUX_DIR" ]]; then
    cd "$LINUX_DIR"

    # ── .desktop autostart files ─────────────────────────────────────────────
    start_spinner "Installing .desktop autostart files"
    if compgen -G "*.desktop" &>/dev/null; then
      cp *.desktop /etc/xdg/autostart/ >>"$LOG" 2>&1
      stop_spinner; ok ".desktop autostart files installed"
    else
      stop_spinner; warn "No .desktop files found in $LINUX_DIR"
    fi

    # ── Shell scripts ────────────────────────────────────────────────────────
    start_spinner "Copying shell scripts to /usr/local/scripts"
    if compgen -G "*.sh" &>/dev/null; then
      cp *.sh /usr/local/scripts/ >>"$LOG" 2>&1
      stop_spinner; ok "Shell scripts copied"
    else
      stop_spinner; warn "No .sh files found in $LINUX_DIR"
    fi

    # ── Flat text files ──────────────────────────────────────────────────────
    start_spinner "Copying text files to /usr/local/scripts"
    if compgen -G "*.txt" &>/dev/null; then
      cp *.txt /usr/local/scripts/ >>"$LOG" 2>&1
      stop_spinner; ok "Text files copied"
    else
      stop_spinner; warn "No .txt files found in $LINUX_DIR"
    fi

    # ── simulation.conf (conditional — don't overwrite existing) ─────────────
    start_spinner "Checking simulation.conf"
    if [[ -f /usr/local/scripts/simulation.conf ]]; then
      stop_spinner; ok "simulation.conf already exists — not overwriting"
    else
      if [[ -f "$CONFIGS_DIR/simulation.conf" ]]; then
        cp "$CONFIGS_DIR/simulation.conf" /usr/local/scripts/simulation.conf >>"$LOG" 2>&1
        stop_spinner; ok "simulation.conf copied from configs directory"
      elif [[ -f "$LINUX_DIR/simulation.conf" ]]; then
        cp "$LINUX_DIR/simulation.conf" /usr/local/scripts/simulation.conf >>"$LOG" 2>&1
        stop_spinner; ok "simulation.conf copied from linux directory"
      else
        stop_spinner; warn "simulation.conf not found in repo — skipping"
      fi
    fi

    # ── rsyslog config from repo ─────────────────────────────────────────────
    start_spinner "Checking for rsyslog config in repo"
    if [[ -f "$LINUX_DIR/10-rsyslog.conf" ]]; then
      stop_spinner
      info "Found 10-rsyslog.conf in repo — will apply in rsyslog phase"
      REPO_RSYSLOG_CONF="$LINUX_DIR/10-rsyslog.conf"
    else
      stop_spinner; warn "No 10-rsyslog.conf in repo linux directory"
      REPO_RSYSLOG_CONF=""
    fi

    # ── Final permissions ────────────────────────────────────────────────────
    start_spinner "Setting permissions on /usr/local/scripts"
    find /usr/local/scripts -type d                -exec chmod 755 {} \; >>"$LOG" 2>&1
    find /usr/local/scripts -type f -name "*.sh"   -exec chmod 755 {} \; >>"$LOG" 2>&1
    find /usr/local/scripts -type f ! -name "*.sh" -exec chmod 644 {} \; >>"$LOG" 2>&1
    stop_spinner; ok "Permissions set on /usr/local/scripts"

    cd "$HOME"
  else
    stop_spinner; warn "linux/ directory not found in client-sim repo — skipping file deployment"
    REPO_RSYSLOG_CONF=""
  fi
else
  stop_spinner; warn "Failed to clone client-sim repo — skipping file deployment"
  REPO_RSYSLOG_CONF=""
fi

end_phase

###############################################################################
# PHASE 6 — SMB CONFIG SYNC  (authenticated + checksum validated)
###############################################################################
begin_phase

SMB_SHARE="//nas/scripts"
SMB_REMOTE_DIR="/SIM/CONFIG"

# Check credentials exist and have been filled in (not just the template)
if [[ ! -f "$SMB_CREDS" ]]; then
  warn "SMB credentials file not found at $SMB_CREDS — skipping SMB sync"
elif grep -qE '^\s*#|^[[:space:]]*$' "$SMB_CREDS" && ! grep -qE '^username=' "$SMB_CREDS"; then
  warn "SMB credentials file is still a template — edit $SMB_CREDS to enable SMB sync"
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
      warn "No checksums.sha256 manifest found — skipping integrity check"
    fi
    ok "SMB config sync complete"
  else
    stop_spinner; warn "SMB config sync failed — continuing without remote config"
  fi
fi

end_phase

###############################################################################
# PHASE 7 — RSYSLOG CUSTOM CONFIG
# Priority: repo file > SMB-synced file > skip
###############################################################################
begin_phase

RSYSLOG_SOURCE=""
if [[ -n "${REPO_RSYSLOG_CONF:-}" && -f "$REPO_RSYSLOG_CONF" ]]; then
  RSYSLOG_SOURCE="$REPO_RSYSLOG_CONF"
  info "Using rsyslog config from GitHub repo"
elif [[ -f /usr/local/scripts/10-rsyslog.conf ]]; then
  RSYSLOG_SOURCE="/usr/local/scripts/10-rsyslog.conf"
  info "Using rsyslog config from /usr/local/scripts (SMB)"
fi

if [[ -n "$RSYSLOG_SOURCE" ]]; then
  start_spinner "Installing rsyslog config"
  cp "$RSYSLOG_SOURCE" /etc/rsyslog.d/10-rsyslog.conf
  # Validate the full rsyslog config (including the new drop-in) not just the snippet
  if rsyslogd -N1 >>"$LOG" 2>&1; then
    systemctl restart rsyslog || true
    systemctl enable  rsyslog || true
    stop_spinner; ok "rsyslog configured from $RSYSLOG_SOURCE"
  else
    stop_spinner
    warn "rsyslog config validation failed — reverting"
    rm -f /etc/rsyslog.d/10-rsyslog.conf
  fi
else
  warn "No rsyslog config source found — skipping"
fi

end_phase

###############################################################################
# PHASE 8 — VIRTUALHERE INSTALL
###############################################################################
begin_phase
info "Installing VirtualHere"

ARCH="$(uname -m)"
VH_BIN=""

case "$ARCH" in
  x86_64)       VH_BIN="vhclientx86_64" ;;
  aarch64)      VH_BIN="vhclientarm64"  ;;
  armv7l|armhf) VH_BIN="vhclientarm"   ;;
  *)            warn "Unsupported architecture '$ARCH' for VirtualHere — skipping" ;;
esac

if [[ -n "$VH_BIN" ]]; then
  VH_TMP="$(mktemp)"

  start_spinner "Downloading VirtualHere ($VH_BIN)"
  if retry curl -fsSL \
      "https://www.virtualhere.com/sites/default/files/usbclient/$VH_BIN" \
      -o "$VH_TMP" >>"$LOG" 2>&1; then
    stop_spinner

    # Install binary — keep arch-specific name AND create generic symlink
    install -o root -g root -m 0755 "$VH_TMP" "/usr/sbin/$VH_BIN"
    ln -sf "/usr/sbin/$VH_BIN" /usr/sbin/vhclient
    ok "VirtualHere binary installed as /usr/sbin/$VH_BIN (symlinked to /usr/sbin/vhclient)"

    start_spinner "Downloading VirtualHere systemd service"
    VH_SVC_TMP="$(mktemp)"
    if retry curl -fsSL \
        "https://www.virtualhere.com/sites/default/files/usbclient/scripts/virtualhereclient.service" \
        -o "$VH_SVC_TMP" >>"$LOG" 2>&1; then
      stop_spinner
      # Patch ExecStart and add start timeout so install never blocks
      sed -e "s|ExecStart=.*|ExecStart=/usr/sbin/$VH_BIN|" \
          -e '/\[Service\]/a TimeoutStartSec=15' \
          "$VH_SVC_TMP" >/etc/systemd/system/virtualhereclient.service
      rm -f "$VH_SVC_TMP"
      ok "VirtualHere service file installed"
    else
      stop_spinner
      warn "Could not download official service file — writing fallback"
      rm -f "$VH_SVC_TMP"
      cat >/etc/systemd/system/virtualhereclient.service <<EOF
[Unit]
Description=VirtualHere USB Client
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/sbin/$VH_BIN
Restart=on-failure
RestartSec=5
TimeoutStartSec=15
User=root

[Install]
WantedBy=multi-user.target
EOF
    fi

    start_spinner "Enabling VirtualHere service"
    systemctl daemon-reload
    systemctl enable virtualhereclient >>"$LOG" 2>&1
    # Start non-blocking — VH client needs a server to connect to which may
    # not be present at install time; failure here is non-fatal.
    systemctl start virtualhereclient >>"$LOG" 2>&1 || \
      warn "VirtualHere service did not start (no server reachable yet) — will start on boot"
    stop_spinner

    sleep 2
    rm -f /usr/local/scripts/vhcached.txt || true
    "/usr/sbin/$VH_BIN" -t "AUTO USE CLEAR ALL"   >>"$LOG" 2>&1 || true
    "/usr/sbin/$VH_BIN" -t "STOP USING ALL LOCAL"  >>"$LOG" 2>&1 || true

    ok "VirtualHere installed and initialized"
  else
    stop_spinner; warn "Failed to download VirtualHere binary — skipping"
  fi
  rm -f "$VH_TMP"
fi

end_phase

###############################################################################
# PHASE 9 — WLAN DRIVERS INSTALL
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

# Format: "dir-name|type|repo-url|dkms-module|pinned-tag|modprobe-module"
# modprobe-module: use "-" if no explicit modprobe needed after install
DRIVERS=(
  "8821au-20210708|morrownr|https://github.com/morrownr/8821au-20210708.git|8821au|HEAD|-"
  "8821cu-20210916|morrownr|https://github.com/morrownr/8821cu-20210916.git|8821cu|HEAD|-"
  "8814au|morrownr|https://github.com/morrownr/8814au.git|8814au|HEAD|-"
  "8812au-20210820|morrownr|https://github.com/morrownr/8812au-20210820.git|8812au|HEAD|-"
  "rtl8852bu-20240418|morrownr|https://github.com/morrownr/rtl8852bu-20240418.git|8852bu|HEAD|-"
  "rtl8852cu-20240510|morrownr|https://github.com/morrownr/rtl8852cu-20240510.git|8852cu|HEAD|-"
  "88x2bu-20210702|morrownr|https://github.com/morrownr/88x2bu-20210702.git|88x2bu|HEAD|-"
  "rtw89|morrownr|https://github.com/morrownr/rtw89.git|rtw89|HEAD|-"
  "rtl8812au|aircrack|https://github.com/aircrack-ng/rtl8812au.git|rtl8812au|HEAD|-"
  "rtl8188eu|lwfinger|https://github.com/lwfinger/rtl8188eu.git|8188eu|HEAD|-"
  "rtl8723au|lwfinger|https://github.com/lwfinger/rtl8723au.git|8723au|HEAD|8723au"
  "rtl8852au|lwfinger|https://github.com/lwfinger/rtl8852au.git|8852au|HEAD|-"
)

TOTAL_DRIVERS="${#DRIVERS[@]}"
DRIVER_NUM=0

for entry in "${DRIVERS[@]}"; do
  SAVED_IFS="$IFS"
  IFS='|' read -r NAME TYPE REPO MOD PIN MODPROBE <<<"$entry"
  IFS="$SAVED_IFS"

  DRIVER_NUM=$(( DRIVER_NUM + 1 ))

  stop_spinner
  phase_step "$DRIVER_NUM" "$TOTAL_DRIVERS"
  info "Driver $DRIVER_NUM/$TOTAL_DRIVERS: $NAME"

  rm -rf "$NAME"
  CLONE_ARGS=(--depth=1)
  [[ "$PIN" != "HEAD" ]] && CLONE_ARGS+=(--branch "$PIN")

  start_spinner "Cloning $NAME [$DRIVER_NUM/$TOTAL_DRIVERS]"
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
            DKMS_VER="$(grep 'PACKAGE_VERSION=' dkms.conf | cut -d'"' -f2 || echo "0.0")"
          fi

          start_spinner "DKMS install $NAME ($MOD/$DKMS_VER)"
          dkms add -m "$MOD" -v "$DKMS_VER" --sourcetree "$(pwd)" >>"$LOG" 2>&1 || true
          dkms install "${MOD}/${DKMS_VER}" >>"$LOG" 2>&1 \
            || warn "$NAME: dkms install failed (non-fatal)"
          stop_spinner

          # Explicit modprobe if specified in driver table
          if [[ "$MODPROBE" != "-" && -n "$MODPROBE" ]]; then
            start_spinner "Loading module: $MODPROBE"
            modprobe "$MODPROBE" >>"$LOG" 2>&1 \
              || warn "modprobe $MODPROBE failed (may need reboot)"
            stop_spinner; ok "Module $MODPROBE loaded"
          fi
        else
          stop_spinner
          INSTALL_OK=false
        fi
        ;;
    esac

    cd "$WIFI_SRC"

    if $INSTALL_OK; then
      echo "$NAME:INSTALLED" >>"$DRIVER_STATE"
      ok "✓ $NAME installed [$DRIVER_NUM/$TOTAL_DRIVERS]"
    else
      echo "$NAME:FAILED" >>"$DRIVER_STATE"
      warn "✗ $NAME build/install failed [$DRIVER_NUM/$TOTAL_DRIVERS]"
    fi
  else
    stop_spinner
    echo "$NAME:CLONE_FAILED" >>"$DRIVER_STATE"
    warn "✗ Failed to clone $NAME [$DRIVER_NUM/$TOTAL_DRIVERS]"
  fi
done

start_spinner "Running depmod -a"
depmod -a >>"$LOG" 2>&1
stop_spinner

export PATH="$OLD_PATH"
rm -rf "$SUPPRESS"
ok "WLAN driver installation complete"
end_phase

###############################################################################
# PHASE 10 — FINAL HEALTH SUMMARY
###############################################################################
begin_phase

tput cnorm 2>/dev/null || true

echo ""
{
# Helper functions for colored health check rows (output goes to tee below)
_hc_ok()   { printf "  \033[0;32m✓\033[0m  %-24s \033[0;32mOK\033[0m\n"       "$1"; }
_hc_warn()  { printf "  \033[1;33m✗\033[0m  %-24s \033[1;33m%s\033[0m\n"      "$1" "$2"; }
_hc_fail()  { printf "  \033[0;31m✗\033[0m  %-24s \033[0;31m%s\033[0m\n"      "$1" "$2"; }
_hc_drv_ok(){ printf "  \033[0;32m✓\033[0m  %-35s \033[0;32mINSTALLED\033[0m\n" "$1"; }
_hc_drv_fail(){ printf "  \033[0;31m✗\033[0m  %-35s \033[0;31m%s\033[0m\n"    "$1" "$2"; }

echo "================ HEALTH CHECK ================"
id "$SIM_USER" &>/dev/null \
  && _hc_ok   "User ($SIM_USER)" \
  || _hc_fail "User ($SIM_USER)" "MISSING"
[[ -f /etc/sudoers.d/99-simuser-nopasswd ]] \
  && _hc_ok   "Scoped sudoers" \
  || _hc_fail "Scoped sudoers" "MISSING"
systemctl is-active --quiet lightdm \
  && _hc_ok   "LightDM" \
  || _hc_warn "LightDM" "NOT ACTIVE"
systemctl is-active --quiet NetworkManager \
  && _hc_ok   "NetworkManager" \
  || _hc_fail "NetworkManager" "NOT ACTIVE"
systemctl is-enabled --quiet virtualhereclient 2>/dev/null \
  && _hc_ok   "VirtualHere (enabled)" \
  || _hc_warn "VirtualHere" "NOT ENABLED"
systemctl is-active --quiet virtualhereclient 2>/dev/null \
  && _hc_ok   "VirtualHere (running)" \
  || _hc_warn "VirtualHere (running)" "NOT ACTIVE — needs server on boot"
lsmod | grep -qE '^(88|rtw|rtl)' \
  && _hc_ok   "WLAN modules" \
  || _hc_warn "WLAN modules" "NOT LOADED (reboot may be needed)"
[[ -f /usr/local/scripts/simulation.conf ]] \
  && _hc_ok   "simulation.conf" \
  || _hc_fail "simulation.conf" "MISSING"
[[ -f /etc/rsyslog.d/10-rsyslog.conf ]] \
  && _hc_ok   "rsyslog config" \
  || _hc_warn "rsyslog config" "NOT INSTALLED"

echo ""
echo "  ---- Driver State ----"
while IFS=: read -r drv status; do
  case "$status" in
    INSTALLED)    _hc_drv_ok   "$drv" ;;
    FAILED)       _hc_drv_fail "$drv" "FAILED" ;;
    CLONE_FAILED) _hc_drv_fail "$drv" "CLONE FAILED" ;;
    *)            printf "  ?  %-35s %s\n" "$drv" "$status" ;;
  esac
done < "$DRIVER_STATE"

echo "============================================="
} | tee -a "$LOG"

end_phase

###############################################################################
# FINAL PROGRESS BAR — 100%
###############################################################################
draw_bar 100 "Complete"
printf "  ${COL_GREEN}✓${COL_RESET}\n\n"

###############################################################################
# END
###############################################################################
TOTAL_ELAPSED=$(( $(date +%s) - INSTALL_START ))
ELAPSED_MIN=$(( TOTAL_ELAPSED / 60 ))
ELAPSED_SEC=$(( TOTAL_ELAPSED % 60 ))

{
echo "============================================================"
printf " Installation complete — reboot recommended\n"
printf " Total time : %dm %02ds\n" "$ELAPSED_MIN" "$ELAPSED_SEC"
if [[ "$WARN_COUNT" -gt 0 ]]; then
  printf " Warnings   : %d  (see %s)\n" "$WARN_COUNT" "$LOG"
else
  printf " Warnings   : 0\n"
fi
if [[ "$ERR_COUNT" -gt 0 ]]; then
  printf " Errors     : %d  (see %s)\n" "$ERR_COUNT" "$LOG"
else
  printf " Errors     : 0\n"
fi
printf " Full log   : %s\n" "$LOG"
printf " Driver state: %s\n" "$DRIVER_STATE"
printf " Sim log    : /usr/local/scripts/sim.log\n"
echo "============================================================"
} | tee -a "$LOG" | while IFS= read -r line; do
  if   echo "$line" | grep -q "Warnings" && [[ "$WARN_COUNT" -gt 0 ]]; then
    printf "${COL_YELLOW}%s${COL_RESET}\n" "$line"
  elif echo "$line" | grep -q "Errors"   && [[ "$ERR_COUNT"  -gt 0 ]]; then
    printf "${COL_RED}%s${COL_RESET}\n" "$line"
  elif echo "$line" | grep -q "complete"; then
    printf "${COL_GREEN}%s${COL_RESET}\n" "$line"
  else
    echo "$line"
  fi
done