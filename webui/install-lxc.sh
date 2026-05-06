#!/usr/bin/env bash
###############################################################################
# Client-Sim Dashboard — LXC Installer v0.01
# Installs the FastAPI web server inside a Proxmox LXC container (Debian/Ubuntu)
###############################################################################

set -euo pipefail
export PATH="/usr/sbin:/sbin:/usr/bin:/bin:$PATH"
export DEBIAN_FRONTEND=noninteractive

###############################################################################
# Root check
###############################################################################
if [[ "$EUID" -ne 0 ]]; then
  echo "ERROR: Run as root (e.g. sudo $0)" >&2
  exit 1
fi

###############################################################################
# Config — override via environment variables before running
###############################################################################
REPO_URL="${REPO_URL:-https://github.com/solutions-hpe/client-sim.git}"
REPO_BRANCH="${REPO_BRANCH:-lrb}"
INSTALL_DIR="${INSTALL_DIR:-/opt/client-sim-dashboard}"
REPO_CACHE="${REPO_CACHE:-/opt/client-sim-repo}"
SERVICE_USER="${SERVICE_USER:-dashboard}"
PORT="${PORT:-8000}"
OFFLINE_TIMEOUT="${OFFLINE_TIMEOUT:-60}"
LOG="/var/log/client-sim-dashboard-install.log"

VERSION="0.01"
INSTALL_START=$(date +%s)

###############################################################################
# Colours & logging
###############################################################################
COL_RESET="\033[0m"
COL_GREEN="\033[0;32m"
COL_CYAN="\033[0;36m"
COL_YELLOW="\033[1;33m"
COL_RED="\033[0;31m"
COL_BOLD="\033[1m"

: >"$LOG"
ts()   { date "+%H:%M:%S"; }
info() { echo -e "[$(ts)] ${COL_BOLD}INFO${COL_RESET}  $*" | tee -a "$LOG"; }
ok()   { echo -e "[$(ts)] ${COL_GREEN}OK${COL_RESET}    $*" | tee -a "$LOG"; }
warn() { echo -e "[$(ts)] ${COL_YELLOW}WARN${COL_RESET}  $*" | tee -a "$LOG"; }
err()  { echo -e "[$(ts)] ${COL_RED}ERR${COL_RESET}   $*" | tee -a "$LOG" >&2; }

trap 'err "Installer failed at line $LINENO — check $LOG"' ERR

###############################################################################
# Banner
###############################################################################
echo
echo "============================================================"
echo " Client-Sim Dashboard Installer v${VERSION}"
echo " $(date)"
echo "============================================================"
echo " Repo URL   : $REPO_URL"
echo " Branch     : $REPO_BRANCH"
echo " Install dir: $INSTALL_DIR"
echo " Port       : $PORT"
echo " Log        : $LOG"
echo "============================================================"
echo

###############################################################################
# STEP 1 — OS check
###############################################################################
info "Checking OS..."
if [[ ! -f /etc/debian_version ]]; then
  err "This installer requires Debian or Ubuntu. Detected: $(uname -a)"
  exit 1
fi
OS_NAME=$(grep '^PRETTY_NAME' /etc/os-release | cut -d'"' -f2)
ok "OS: $OS_NAME"

###############################################################################
# STEP 2 — System packages
###############################################################################
info "Updating package lists..."
apt-get update --quiet=2 >>"$LOG" 2>&1
ok "Package lists updated"

info "Installing dependencies (python3, pip, venv, git, curl)..."
apt-get install -y --quiet=2 \
  python3 python3-pip python3-venv \
  git curl \
  -o Dpkg::Options::="--force-confdef" \
  -o Dpkg::Options::="--force-confold" \
  >>"$LOG" 2>&1
ok "System packages installed"

###############################################################################
# STEP 3 — Service user
###############################################################################
info "Checking service user '$SERVICE_USER'..."
if ! id "$SERVICE_USER" &>/dev/null; then
  useradd -r -s /bin/false -d "$INSTALL_DIR" "$SERVICE_USER" >>"$LOG" 2>&1
  ok "Created service user '$SERVICE_USER'"
else
  ok "Service user '$SERVICE_USER' already exists"
fi

###############################################################################
# STEP 4 — Clone / update client-sim repo
###############################################################################
info "Setting up client-sim repo at $REPO_CACHE..."
if [[ -d "$REPO_CACHE/.git" ]]; then
  git -C "$REPO_CACHE" fetch origin >>"$LOG" 2>&1
  git -C "$REPO_CACHE" reset --hard "origin/$REPO_BRANCH" >>"$LOG" 2>&1
  ok "Repo updated to latest $REPO_BRANCH"
elif [[ -d "$REPO_CACHE" ]]; then
  warn "Directory exists but is not a git repo — removing and re-cloning"
  rm -rf "$REPO_CACHE"
  git clone --depth=1 -b "$REPO_BRANCH" "$REPO_URL" "$REPO_CACHE" >>"$LOG" 2>&1
  ok "Repo cloned"
else
  git clone --depth=1 -b "$REPO_BRANCH" "$REPO_URL" "$REPO_CACHE" >>"$LOG" 2>&1
  ok "Repo cloned"
fi

###############################################################################
# STEP 5 — Install dashboard app
###############################################################################
info "Installing dashboard app to $INSTALL_DIR..."
mkdir -p "$INSTALL_DIR"

# Copy webui files from cloned repo
cp -r "$REPO_CACHE/webui/." "$INSTALL_DIR/"
ok "Dashboard files copied"

###############################################################################
# STEP 6 — Python virtual environment + dependencies
###############################################################################
info "Creating Python virtual environment..."
python3 -m venv "$INSTALL_DIR/venv" >>"$LOG" 2>&1
ok "Virtual environment created"

info "Installing Python dependencies..."
"$INSTALL_DIR/venv/bin/pip" install --quiet --upgrade pip >>"$LOG" 2>&1
"$INSTALL_DIR/venv/bin/pip" install --quiet -r "$INSTALL_DIR/requirements.txt" >>"$LOG" 2>&1
ok "Python dependencies installed"

###############################################################################
# STEP 7 — Environment file
###############################################################################
info "Writing environment config..."
cat >"$INSTALL_DIR/.env" <<EOF
REPO_URL=$REPO_URL
REPO_BRANCH=$REPO_BRANCH
REPO_DIR=$REPO_CACHE
OFFLINE_TIMEOUT=$OFFLINE_TIMEOUT
EOF
chmod 640 "$INSTALL_DIR/.env"
ok "Environment file written to $INSTALL_DIR/.env"

###############################################################################
# STEP 8 — systemd service
###############################################################################
info "Installing systemd service..."
cat >/etc/systemd/system/client-sim-dashboard.service <<EOF
[Unit]
Description=Client-Sim Dashboard
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$SERVICE_USER
WorkingDirectory=$INSTALL_DIR
EnvironmentFile=$INSTALL_DIR/.env
ExecStart=$INSTALL_DIR/venv/bin/uvicorn server:app --host 0.0.0.0 --port $PORT
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=client-sim-dashboard

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable client-sim-dashboard >>"$LOG" 2>&1
ok "systemd service installed and enabled"

###############################################################################
# STEP 9 — Permissions
###############################################################################
info "Setting permissions..."
chown -R "$SERVICE_USER:$SERVICE_USER" "$INSTALL_DIR"
chown -R "$SERVICE_USER:$SERVICE_USER" "$REPO_CACHE"
ok "Permissions set"

###############################################################################
# STEP 10 — Start service
###############################################################################
info "Starting client-sim-dashboard service..."
systemctl start client-sim-dashboard
sleep 3

if systemctl is-active --quiet client-sim-dashboard; then
  ok "Service started successfully"
else
  warn "Service may not have started — check: journalctl -u client-sim-dashboard"
fi

###############################################################################
# HEALTH CHECK
###############################################################################
echo
echo "================ HEALTH CHECK ================"
CONTAINER_IP=$(hostname -I | awk '{print $1}')

id "$SERVICE_USER" &>/dev/null \
  && echo -e "  ${COL_GREEN}✓${COL_RESET}  Service user ($SERVICE_USER)   OK" \
  || echo -e "  ${COL_RED}✗${COL_RESET}  Service user ($SERVICE_USER)   MISSING"

[[ -d "$INSTALL_DIR/venv" ]] \
  && echo -e "  ${COL_GREEN}✓${COL_RESET}  Python venv                   OK" \
  || echo -e "  ${COL_RED}✗${COL_RESET}  Python venv                   MISSING"

[[ -d "$REPO_CACHE/.git" ]] \
  && echo -e "  ${COL_GREEN}✓${COL_RESET}  Repo cache                    OK" \
  || echo -e "  ${COL_RED}✗${COL_RESET}  Repo cache                    MISSING"

systemctl is-active --quiet client-sim-dashboard \
  && echo -e "  ${COL_GREEN}✓${COL_RESET}  Dashboard service             RUNNING" \
  || echo -e "  ${COL_YELLOW}✗${COL_RESET}  Dashboard service             NOT RUNNING"

systemctl is-enabled --quiet client-sim-dashboard \
  && echo -e "  ${COL_GREEN}✓${COL_RESET}  Auto-start on boot            ENABLED" \
  || echo -e "  ${COL_YELLOW}✗${COL_RESET}  Auto-start on boot            DISABLED"

# Quick API health check
if curl -fsSL --connect-timeout 5 "http://localhost:${PORT}/api/health" >>/dev/null 2>&1; then
  echo -e "  ${COL_GREEN}✓${COL_RESET}  API responding on :${PORT}         OK"
else
  echo -e "  ${COL_YELLOW}✗${COL_RESET}  API not yet responding on :${PORT}  (may still be starting)"
fi

echo "============================================="
echo

ELAPSED=$(( $(date +%s) - INSTALL_START ))
echo -e "${COL_GREEN}${COL_BOLD}Installation complete${COL_RESET} in ${ELAPSED}s"
echo
echo -e "  Dashboard : ${COL_BOLD}http://${CONTAINER_IP}:${PORT}${COL_RESET}"
echo -e "  API docs  : ${COL_BOLD}http://${CONTAINER_IP}:${PORT}/docs${COL_RESET}"
echo -e "  Logs      : journalctl -u client-sim-dashboard -f"
echo -e "  Install log: $LOG"
echo
echo -e "  ${COL_YELLOW}Set in simulation.conf on each client:${COL_RESET}"
echo -e "  [server]"
echo -e "  server_url=http://${CONTAINER_IP}:${PORT}"
echo
