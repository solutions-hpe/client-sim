#!/bin/bash
# install-proxmox-agent.sh — Install the Client-Sim Proxmox agent on this host.
# Usage: curl -sSL <raw_url> | bash -s -- --server http://172.16.1.59:8000 [--key apikey] [--interval 60]
# Or run directly: bash install-proxmox-agent.sh --server http://... --key ...

SCRIPT_VERSION="0.05"

set -euo pipefail

AGENT_BIN="/usr/local/bin/client-sim-proxmox-agent"
WATCHDOG_BIN="/usr/local/bin/proxmox-watchdog"
SERVICE_NAME="client-sim-proxmox-agent"
ENV_FILE="/etc/client-sim-proxmox-agent.env"
SYSTEMD_DIR="/etc/systemd/system"
INSTALLER_DIR="/opt/proxmox-agent-installer"
INSTALLER_SCRIPT="${INSTALLER_DIR}/install-proxmox-agent.sh"
WATCHDOG_STATE_DIR="/var/lib/proxmox-watchdog"
AGENT_PORT="${CLIENT_SIM_AGENT_PORT:-9105}"

SERVER_URL=""
API_KEY=""
POLL_INTERVAL="60"
REPO_BRANCH="${REPO_BRANCH:-lrb}"
UNATTENDED=0
SERVER_SET=0
KEY_SET=0
INTERVAL_SET=0
BRANCH_SET=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --server)      SERVER_URL="$2"; SERVER_SET=1; shift 2 ;;
        --key)         API_KEY="$2"; KEY_SET=1; shift 2 ;;
        --interval)    POLL_INTERVAL="$2"; INTERVAL_SET=1; shift 2 ;;
        --branch)      REPO_BRANCH="$2"; BRANCH_SET=1; shift 2 ;;
        --unattended)  UNATTENDED=1; shift ;;
        *) echo "Unknown arg: $1"; exit 1 ;;
    esac
done

if [[ -f "$ENV_FILE" ]]; then
    existing_server=$(grep -oP '(?<=CLIENT_SIM_SERVER_URL=).*' "$ENV_FILE" || true)
    existing_key=$(grep -oP '(?<=CLIENT_SIM_API_KEY=).*' "$ENV_FILE" || true)
    existing_interval=$(grep -oP '(?<=CLIENT_SIM_POLL_INTERVAL=).*' "$ENV_FILE" || true)
    existing_branch=$(grep -oP '(?<=CLIENT_SIM_REPO_BRANCH=).*' "$ENV_FILE" || true)
    existing_agent_port=$(grep -oP '(?<=CLIENT_SIM_AGENT_PORT=).*' "$ENV_FILE" || true)

    [[ $SERVER_SET -eq 1 ]] || SERVER_URL="$existing_server"
    [[ $KEY_SET -eq 1 ]] || API_KEY="$existing_key"
    [[ $INTERVAL_SET -eq 1 ]] || [[ -z "$existing_interval" ]] || POLL_INTERVAL="$existing_interval"
    [[ $BRANCH_SET -eq 1 ]] || [[ -z "$existing_branch" ]] || REPO_BRANCH="$existing_branch"
    [[ -z "$existing_agent_port" ]] || AGENT_PORT="$existing_agent_port"
fi

REPO_RAW="https://raw.githubusercontent.com/solutions-hpe/client-sim/${REPO_BRANCH}"

if [[ -z "$SERVER_URL" ]]; then
    echo "ERROR: --server <url> is required"
    echo "Usage: bash install-proxmox-agent.sh --server http://172.16.1.59:8000"
    exit 1
fi

if ! command -v qm &>/dev/null && [[ ! -x /usr/sbin/qm ]]; then
    echo "WARNING: 'qm' not found — continuing anyway, but this script is intended for Proxmox hosts."
fi

echo "=== Client-Sim Proxmox Agent Installer v${SCRIPT_VERSION} ==="
echo "Server : $SERVER_URL"
echo "Branch : $REPO_BRANCH"
echo "Key    : ${API_KEY:+(set)}"
echo "Mode   : $([[ $UNATTENDED -eq 1 ]] && echo unattended || echo interactive)"
echo

install -d -m 0755 "$INSTALLER_DIR" "$WATCHDOG_STATE_DIR"

echo "[1/6] Downloading agent and watchdog scripts..."
curl -sSL "${REPO_RAW}/proxmox/proxmox-agent.sh" -o "$AGENT_BIN"
curl -sSL "${REPO_RAW}/proxmox/watchdog.sh" -o "$WATCHDOG_BIN"
curl -sSL "${REPO_RAW}/proxmox/install-proxmox-agent.sh" -o "$INSTALLER_SCRIPT"
chmod +x "$AGENT_BIN" "$WATCHDOG_BIN" "$INSTALLER_SCRIPT"
AGENT_VERSION=$(grep -oP '(?<=^AGENT_VERSION=")[^"]+' "$AGENT_BIN" 2>/dev/null || true)
echo "  OK: $AGENT_BIN${AGENT_VERSION:+ (agent v${AGENT_VERSION})}"
echo "  OK: $WATCHDOG_BIN"
echo "  OK: $INSTALLER_SCRIPT"

echo "[2/6] Downloading systemd units..."
curl -sSL "${REPO_RAW}/proxmox/client-sim-proxmox-agent.service" -o "${SYSTEMD_DIR}/${SERVICE_NAME}.service"
curl -sSL "${REPO_RAW}/proxmox/proxmox-watchdog.service" -o "${SYSTEMD_DIR}/proxmox-watchdog.service"
curl -sSL "${REPO_RAW}/proxmox/proxmox-watchdog.timer" -o "${SYSTEMD_DIR}/proxmox-watchdog.timer"
chmod 0644 "${SYSTEMD_DIR}/${SERVICE_NAME}.service" "${SYSTEMD_DIR}/proxmox-watchdog.service" "${SYSTEMD_DIR}/proxmox-watchdog.timer"
echo "  OK: ${SYSTEMD_DIR}/${SERVICE_NAME}.service"
echo "  OK: ${SYSTEMD_DIR}/proxmox-watchdog.service"
echo "  OK: ${SYSTEMD_DIR}/proxmox-watchdog.timer"

echo "[3/6] Writing environment file..."
cat > "$ENV_FILE" <<ENV
CLIENT_SIM_SERVER_URL=${SERVER_URL}
CLIENT_SIM_API_KEY=${API_KEY}
CLIENT_SIM_POLL_INTERVAL=${POLL_INTERVAL}
CLIENT_SIM_REPO_BRANCH=${REPO_BRANCH}
CLIENT_SIM_AGENT_PORT=${AGENT_PORT}
ENV
chmod 600 "$ENV_FILE"
echo "  OK: $ENV_FILE"

echo "[4/6] Preparing watchdog state..."
install -d -m 0755 "$WATCHDOG_STATE_DIR"
echo "  OK: $WATCHDOG_STATE_DIR"

echo "[5/6] Enabling and (re)starting service + timer..."
systemctl daemon-reload
systemctl enable "$SERVICE_NAME"
systemctl restart "$SERVICE_NAME"
systemctl enable --now proxmox-watchdog.timer
systemctl start proxmox-watchdog.service || true
sleep 3
if systemctl is-active --quiet "$SERVICE_NAME"; then
    echo "  OK: service running"
else
    echo "  WARNING: service failed to start — check: journalctl -u $SERVICE_NAME"
fi
if systemctl is-active --quiet proxmox-watchdog.timer; then
    echo "  OK: watchdog timer running"
else
    echo "  WARNING: watchdog timer failed to start — check: systemctl status proxmox-watchdog.timer"
fi

echo "[6/6] Testing connection to WebUI..."
if curl -sSf --max-time 5 "${SERVER_URL}/api/health" | grep -q '"status".*"ok"'; then
    echo "  OK: WebUI reachable at $SERVER_URL"
else
    echo "  WARNING: Could not reach WebUI at $SERVER_URL"
fi

echo
echo "=== Installation complete ==="
echo "  Agent : v${AGENT_VERSION:-unknown}"
echo "  Logs  : journalctl -u $SERVICE_NAME -f"
echo "  Status: systemctl status $SERVICE_NAME"
echo "  Watchdog: systemctl status proxmox-watchdog.timer"
