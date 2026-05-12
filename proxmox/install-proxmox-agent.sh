#!/bin/bash
# install-proxmox-agent.sh — Install the Client-Sim Proxmox agent on this host.
# Usage: curl -sSL <raw_url> | bash -s -- --server http://172.16.1.59:8000 [--key apikey] [--interval 60] [--skip-vh]
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
        --skip-vh)     SKIP_VH=1; shift ;;
        *) echo "Unknown arg: $1"; exit 1 ;;
    esac
done
SKIP_VH="${SKIP_VH:-0}"

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

echo "[4/7] Installing VirtualHere USB client..."
if [[ "$SKIP_VH" -eq 1 ]]; then
    echo "  SKIP: --skip-vh passed"
else
    VH_ARCH="$(uname -m)"
    case "$VH_ARCH" in
        x86_64)       VH_BIN="vhclientx86_64" ;;
        aarch64)      VH_BIN="vhclientarm64"  ;;
        armv7l|armhf) VH_BIN="vhclientarm"   ;;
        *)            VH_BIN="" ; echo "  WARNING: unsupported arch '$VH_ARCH' — skipping VirtualHere" ;;
    esac

    if [[ -n "${VH_BIN:-}" ]]; then
        # Check for an existing VH binary at alternate locations before downloading
        EXISTING_VH=""
        while IFS= read -r candidate; do
            if [[ -x "$candidate" ]]; then
                EXISTING_VH="$candidate"
                break
            fi
        done < <(find /root/.local /opt /home -maxdepth 6 -name 'vhclient*' -type f 2>/dev/null)

        if [[ -n "$EXISTING_VH" ]]; then
            echo "  FOUND: existing VirtualHere binary at $EXISTING_VH"
            # Symlink to canonical path so agent can find it
            ln -sf "$EXISTING_VH" /usr/sbin/vhclient
            echo "  OK: symlinked /usr/sbin/vhclient -> $EXISTING_VH"
            VH_EXEC="$EXISTING_VH"
        else
            VH_TMP="$(mktemp)"
            if curl -fsSL "https://www.virtualhere.com/sites/default/files/usbclient/$VH_BIN" \
                    -o "$VH_TMP" 2>/dev/null; then
                install -o root -g root -m 0755 "$VH_TMP" "/usr/sbin/$VH_BIN"
                ln -sf "/usr/sbin/$VH_BIN" /usr/sbin/vhclient
                echo "  OK: /usr/sbin/$VH_BIN (symlinked to /usr/sbin/vhclient)"
                VH_EXEC="/usr/sbin/$VH_BIN"
            else
                echo "  WARNING: Failed to download VirtualHere binary — skipping"
                VH_EXEC=""
            fi
            rm -f "$VH_TMP"
        fi

        if [[ -n "$VH_EXEC" ]]; then
            VH_SVC_TMP="$(mktemp)"
            if curl -fsSL \
                "https://www.virtualhere.com/sites/default/files/usbclient/scripts/virtualhereclient.service" \
                -o "$VH_SVC_TMP" 2>/dev/null; then
                sed -e "s|ExecStart=.*|ExecStart=$VH_EXEC|" \
                    -e '/\[Service\]/a TimeoutStartSec=15' \
                    "$VH_SVC_TMP" >/etc/systemd/system/virtualhereclient.service
                rm -f "$VH_SVC_TMP"
            else
                rm -f "$VH_SVC_TMP"
                cat >/etc/systemd/system/virtualhereclient.service <<VHSVC
[Unit]
Description=VirtualHere USB Client
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=$VH_EXEC
Restart=on-failure
RestartSec=5
TimeoutStartSec=15
User=root

[Install]
WantedBy=multi-user.target
VHSVC
            fi
            # Remove any stale override so the new ExecStart takes effect
            rm -f /etc/systemd/system/virtualhereclient.service.d/override.conf
            systemctl daemon-reload
            systemctl enable virtualhereclient
            systemctl start virtualhereclient 2>/dev/null || \
                echo "  NOTE: VirtualHere service did not start (needs server on network) — enabled for boot"
            echo "  OK: virtualhereclient service enabled (ExecStart=$VH_EXEC)"
        fi
    fi
fi

echo "[5/7] Preparing watchdog state..."
install -d -m 0755 "$WATCHDOG_STATE_DIR"
echo "  OK: $WATCHDOG_STATE_DIR"

echo "[6/7] Enabling and (re)starting service + timer..."
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

echo "[7/7] Testing connection to WebUI..."
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
