#!/bin/bash
# install-proxmox-agent.sh — Install the Client-Sim Proxmox agent on this host.
# Usage: curl -sSL <raw_url> | bash -s -- --server http://172.16.1.59:8000 [--key apikey] [--interval 60]
# Or run directly: bash install-proxmox-agent.sh --server http://... --key ...

SCRIPT_VERSION="0.03"

set -euo pipefail

AGENT_BIN="/usr/local/bin/client-sim-proxmox-agent"
SERVICE_NAME="client-sim-proxmox-agent"
ENV_FILE="/etc/client-sim-proxmox-agent.env"

SERVER_URL=""
API_KEY=""
POLL_INTERVAL="60"
REPO_BRANCH="${REPO_BRANCH:-lrb}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --server)   SERVER_URL="$2";    shift 2 ;;
        --key)      API_KEY="$2";       shift 2 ;;
        --interval) POLL_INTERVAL="$2"; shift 2 ;;
        --branch)   REPO_BRANCH="$2";   shift 2 ;;
        *) echo "Unknown arg: $1"; exit 1 ;;
    esac
done

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
echo

echo "[1/5] Downloading agent script..."
curl -sSL "${REPO_RAW}/proxmox/proxmox-agent.sh" -o "$AGENT_BIN"
chmod +x "$AGENT_BIN"
AGENT_VERSION=$(grep -oP '(?<=^AGENT_VERSION=")[^"]+' "$AGENT_BIN" 2>/dev/null || true)
echo "  OK: $AGENT_BIN${AGENT_VERSION:+ (agent v${AGENT_VERSION})}"

echo "[2/5] Writing environment file..."
# Preserve existing API key if --key was not provided
if [[ -z "$API_KEY" && -f "$ENV_FILE" ]]; then
    API_KEY=$(grep -oP '(?<=CLIENT_SIM_API_KEY=).*' "$ENV_FILE" || true)
fi
cat > "$ENV_FILE" <<ENV
CLIENT_SIM_SERVER_URL=${SERVER_URL}
CLIENT_SIM_API_KEY=${API_KEY}
CLIENT_SIM_POLL_INTERVAL=${POLL_INTERVAL}
CLIENT_SIM_REPO_BRANCH=${REPO_BRANCH}
ENV
chmod 600 "$ENV_FILE"
echo "  OK: $ENV_FILE"

echo "[3/5] Writing systemd service unit..."
cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<UNIT
[Unit]
Description=Client-Sim Proxmox Agent
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=${ENV_FILE}
ExecStart=${AGENT_BIN}
Restart=always
RestartSec=30
StandardOutput=append:/var/log/client-sim-proxmox-agent.log
StandardError=append:/var/log/client-sim-proxmox-agent.log

[Install]
WantedBy=multi-user.target
UNIT
echo "  OK: /etc/systemd/system/${SERVICE_NAME}.service"

echo "[4/5] Enabling and (re)starting service..."
systemctl daemon-reload
systemctl enable "$SERVICE_NAME"
systemctl restart "$SERVICE_NAME"
sleep 3
if systemctl is-active --quiet "$SERVICE_NAME"; then
    echo "  OK: service running"
else
    echo "  WARNING: service failed to start — check: journalctl -u $SERVICE_NAME"
fi

echo "[5/5] Testing connection to WebUI..."
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
