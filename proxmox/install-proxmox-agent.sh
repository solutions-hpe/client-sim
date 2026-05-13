#!/bin/bash
# install-proxmox-agent.sh — Install the Client-Sim Proxmox agent on this host.
# Usage: curl -sSL <raw_url> | bash -s -- --server http://172.16.1.59:8000 [--hub-url https://cs-hub.example.com:8443] [--tenant-id <uuid>] [--key apikey] [--interval 60]
# Or run directly: bash install-proxmox-agent.sh --server http://... --hub-url https://... --tenant-id ...

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
AZURE_ACCOUNT="lrbcsvms"
AZURE_CONTAINER="vms"
SPOKE_IP=""
SPOKE_NAME=""
SPOKE_PORT="8000"

HUB_URL=""
TENANT_ID=""
HUB_SET=0
TENANT_SET=0

SERVER_URL=""
API_KEY=""
POLL_INTERVAL="60"
REPO_BRANCH="${REPO_BRANCH:-lrb}"
UNATTENDED=0
SERVER_SET=0
KEY_SET=0
INTERVAL_SET=0
BRANCH_SET=0

_restore_template_from_azure() {
    local blob_manifest_url="https://${AZURE_ACCOUNT}.blob.core.windows.net/${AZURE_CONTAINER}?restype=container&comp=list"
    local blob_manifest
    if ! blob_manifest=$(curl -sf "$blob_manifest_url"); then
        echo "[WARN] Unable to query Azure template backups (${blob_manifest_url}). Skipping template restore."
        return 0
    fi

    local blob_list
    blob_list=$(printf '%s\n' "$blob_manifest" | grep -oP '(?<=<Name>)[^<]+\.vma\.zst' | sort || true)

    if [ -z "$blob_list" ]; then
        echo "[WARN] No template backups found in Azure (https://${AZURE_ACCOUNT}.blob.core.windows.net/${AZURE_CONTAINER}). Skipping template restore."
        return 0
    fi

    local blob_count
    blob_count=$(echo "$blob_list" | wc -l)
    local selected_blob

    if [ "$blob_count" -eq 1 ]; then
        selected_blob=$(echo "$blob_list" | head -1)
        echo "[INFO] Found template: $selected_blob"
    else
        echo "[INFO] Multiple templates available:"
        local i=1
        while IFS= read -r blob; do
            echo "  $i) $(basename "$blob")"
            i=$((i+1))
        done <<< "$blob_list"
        printf "Select template [1-${blob_count}]: "
        if ! read -r selection; then
            echo "[WARN] No template selection received. Skipping template restore."
            return 0
        fi
        if ! [[ "$selection" =~ ^[0-9]+$ ]]; then
            echo "[WARN] Invalid selection. Skipping template restore."
            return 0
        fi
        selected_blob=$(echo "$blob_list" | sed -n "${selection}p")
        if [ -z "$selected_blob" ]; then
            echo "[WARN] Invalid selection. Skipping template restore."
            return 0
        fi
    fi

    local blob_url="https://${AZURE_ACCOUNT}.blob.core.windows.net/${AZURE_CONTAINER}/${selected_blob}"
    local local_file="${INSTALLER_DIR}/$(basename "$selected_blob")"
    echo "[INFO] Downloading template from Azure: $blob_url"
    if ! curl -L --progress-bar -o "$local_file" "$blob_url"; then
        echo "[ERROR] Failed to download template. Skipping restore."
        rm -f "$local_file"
        return 0
    fi

    echo "[INFO] Restoring template to VM ID 100..."
    if ! qmrestore "$local_file" 100 --force; then
        echo "[ERROR] qmrestore failed. Skipping template conversion."
        rm -f "$local_file"
        return 0
    fi

    echo "[INFO] Converting VM 100 to template..."
    if qm template 100; then
        echo "[INFO] Template VM 100 ready."
    else
        echo "[WARN] qm template conversion failed — VM 100 restored but not marked as template."
    fi

    rm -f "$local_file"
}

_restore_spoke_from_azure() {
    local blob_manifest_url="https://${AZURE_ACCOUNT}.blob.core.windows.net/${AZURE_CONTAINER}?restype=container&comp=list"
    local blob_manifest
    if ! blob_manifest=$(curl -sf "$blob_manifest_url"); then
        echo "[WARN] Unable to query Azure spoke backups (${blob_manifest_url}). Skipping spoke restore."
        return 0
    fi

    local blob_list
    blob_list=$(printf '%s\n' "$blob_manifest" | grep -oP '(?<=<Name>)[^<]+\.vma\.zst' | sort || true)

    if [ -z "$blob_list" ]; then
        echo "[WARN] No spoke backups found in Azure (https://${AZURE_ACCOUNT}.blob.core.windows.net/${AZURE_CONTAINER}). Skipping spoke VM restore."
        return 0
    fi

    local blob_count
    blob_count=$(echo "$blob_list" | wc -l)
    local selected_blob

    if [ "$blob_count" -eq 1 ]; then
        selected_blob=$(echo "$blob_list" | head -1)
        echo "[INFO] Found spoke backup: $selected_blob"
    else
        echo "[INFO] Available backups in Azure:"
        local i=1
        while IFS= read -r blob; do
            echo "  $i) $(basename "$blob")"
            i=$((i+1))
        done <<< "$blob_list"
        printf "Select backup for spoke VM 1001 [1-${blob_count}]: "
        if ! read -r selection; then
            echo "[WARN] No spoke backup selection received. Skipping spoke restore."
            return 0
        fi
        if ! [[ "$selection" =~ ^[0-9]+$ ]]; then
            echo "[WARN] Invalid selection. Skipping spoke restore."
            return 0
        fi
        selected_blob=$(echo "$blob_list" | sed -n "${selection}p")
        if [ -z "$selected_blob" ]; then
            echo "[WARN] Invalid selection. Skipping spoke restore."
            return 0
        fi
    fi

    local blob_url="https://${AZURE_ACCOUNT}.blob.core.windows.net/${AZURE_CONTAINER}/${selected_blob}"
    local local_file="${INSTALLER_DIR}/$(basename "$selected_blob")"
    echo "[INFO] Downloading spoke backup from Azure: $blob_url"
    if ! curl -L --progress-bar -o "$local_file" "$blob_url"; then
        echo "[ERROR] Download failed. Skipping spoke restore."
        rm -f "$local_file"
        return 0
    fi

    echo "[INFO] Restoring spoke VM to ID 1001..."
    local restore_cmd
    if echo "$selected_blob" | grep -q "lxc"; then
        restore_cmd="pct restore 1001 $local_file --force"
    else
        restore_cmd="qmrestore $local_file 1001 --force"
    fi
    if ! $restore_cmd; then
        echo "[ERROR] Restore failed. Skipping rename and start."
        rm -f "$local_file"
        return 0
    fi

    local pxmx_hostname
    pxmx_hostname=$(hostname)
    local svr_num
    svr_num=$(echo "$pxmx_hostname" | grep -oP '\d+$' || true)
    if [ -n "$svr_num" ]; then
        local spoke_name="spoke-svr-${svr_num}"
        echo "[INFO] Renaming VM 1001 to ${spoke_name}..."
        if qm list 2>/dev/null | awk '{print $1}' | grep -q '^1001$'; then
            qm set 1001 --name "$spoke_name" 2>/dev/null || true
        else
            pct set 1001 --hostname "$spoke_name" 2>/dev/null || true
        fi
    else
        echo "[WARN] Could not extract server number from hostname '$pxmx_hostname' — skipping rename."
    fi

    echo "[INFO] Starting spoke VM 1001..."
    if qm list 2>/dev/null | awk '{print $1}' | grep -q '^1001$'; then
        qm start 1001 || echo "[WARN] qm start 1001 failed — start it manually."
    else
        pct start 1001 || echo "[WARN] pct start 1001 failed — start it manually."
    fi

    rm -f "$local_file"
    echo "[INFO] Spoke VM 1001 restore complete."

    # Wait for IP then configure hub settings
    if _wait_for_spoke_ip; then
        _configure_spoke_hub "$SPOKE_IP"
    fi
}

# Waits up to ~3 minutes for VM 1001 to boot and report a non-loopback IP.
# Sets SPOKE_IP on success. Works for both QEMU (qm agent) and LXC (pct exec).
_wait_for_spoke_ip() {
    echo "[INFO] Waiting for spoke VM 1001 to boot and report an IP address..."
    local is_qemu=0
    qm list 2>/dev/null | awk '{print $1}' | grep -q '^1001$' && is_qemu=1

    local attempts=0 max_attempts=36  # 36 × 5s = 3 minutes
    while [ "$attempts" -lt "$max_attempts" ]; do
        local ip=""
        if [ "$is_qemu" -eq 1 ]; then
            # qm agent network-get-interfaces returns JSON; extract first non-loopback IPv4
            ip=$(qm agent 1001 network-get-interfaces 2>/dev/null \
                | python3 -c "
import json, sys
ifaces = json.load(sys.stdin)
for iface in ifaces:
    if iface.get('name','') == 'lo':
        continue
    for addr in iface.get('ip-addresses', []):
        if addr.get('ip-address-type') == 'ipv4':
            print(addr['ip-address'])
            sys.exit(0)
" 2>/dev/null || true)
        else
            ip=$(pct exec 1001 -- bash -c "hostname -I 2>/dev/null | tr ' ' '\n' | grep -v '^127\.' | grep -v '^::' | head -1" 2>/dev/null || true)
        fi

        if [ -n "$ip" ]; then
            SPOKE_IP="$ip"
            echo "[INFO] Spoke VM 1001 IP: ${SPOKE_IP}"
            return 0
        fi

        attempts=$((attempts + 1))
        printf "\r[INFO] Waiting for IP... (%ds)" "$((attempts * 5))"
        sleep 5
    done
    echo ""
    echo "[WARN] Spoke VM 1001 did not report an IP within 3 minutes — configure hub settings manually."
    return 1
}

# Configures hub URL and tenant ID on the spoke via its settings API.
# Called after VM 1001 is up and we have its IP.
_configure_spoke_hub() {
    local spoke_ip="$1"
    local spoke_base="http://${spoke_ip}:${SPOKE_PORT}"

    if [ -z "$HUB_URL" ] && [ -z "$TENANT_ID" ]; then
        echo "[INFO] No --hub-url or --tenant-id provided — skipping spoke hub configuration."
        return 0
    fi

    echo "[INFO] Waiting for spoke API to be ready at ${spoke_base}..."
    local attempts=0 max_attempts=24  # 24 × 5s = 2 minutes
    while [ "$attempts" -lt "$max_attempts" ]; do
        if curl -sf --max-time 3 "${spoke_base}/api/health" >/dev/null 2>&1; then
            break
        fi
        attempts=$((attempts + 1))
        printf "\r[INFO] Waiting for spoke API... (%ds)" "$((attempts * 5))"
        sleep 5
    done
    echo ""

    if ! curl -sf --max-time 3 "${spoke_base}/api/health" >/dev/null 2>&1; then
        echo "[WARN] Spoke API not reachable at ${spoke_base} — configure hub settings manually."
        return 0
    fi

    echo "[INFO] Configuring hub settings on spoke..."

    # Build JSON payload with only the fields that were provided
    local payload
    payload=$(python3 -c "
import json, sys
d = {}
hub_url   = sys.argv[1]
tenant_id = sys.argv[2]
if hub_url:
    d['relay_server_url'] = hub_url
    d['relay_enabled']    = 'on'
if tenant_id:
    d['relay_tenant_id']   = tenant_id
    d['relay_tenant_hint'] = tenant_id
print(json.dumps(d))
" "$HUB_URL" "$TENANT_ID")

    local http_status
    http_status=$(curl -sf --max-time 10 \
        -X POST "${spoke_base}/api/settings" \
        -H "Content-Type: application/json" \
        -d "$payload" \
        -o /dev/null -w "%{http_code}" 2>/dev/null || echo "000")

    if [ "$http_status" = "200" ]; then
        echo "[INFO] Spoke hub settings configured successfully."
        [ -n "$HUB_URL" ]    && echo "  Hub URL   : $HUB_URL"
        [ -n "$TENANT_ID" ]  && echo "  Tenant ID : $TENANT_ID"
    else
        echo "[WARN] Failed to configure spoke hub settings (HTTP ${http_status}) — configure manually in the spoke UI."
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --server)      SERVER_URL="$2"; SERVER_SET=1; shift 2 ;;
        --key)         API_KEY="$2"; KEY_SET=1; shift 2 ;;
        --interval)    POLL_INTERVAL="$2"; INTERVAL_SET=1; shift 2 ;;
        --branch)      REPO_BRANCH="$2"; BRANCH_SET=1; shift 2 ;;
        --hub-url)     HUB_URL="$2"; HUB_SET=1; shift 2 ;;
        --tenant-id)   TENANT_ID="$2"; TENANT_SET=1; shift 2 ;;
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
echo "Server    : $SERVER_URL"
echo "Branch    : $REPO_BRANCH"
echo "Key       : ${API_KEY:+(set)}"
echo "Hub URL   : ${HUB_URL:-(not set)}"
echo "Tenant ID : ${TENANT_ID:-(not set)}"
echo "Mode      : $([[ $UNATTENDED -eq 1 ]] && echo unattended || echo interactive)"
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
systemctl restart "$SERVICE_NAME" --no-block
systemctl enable --now proxmox-watchdog.timer --no-block
systemctl start proxmox-watchdog.service --no-block || true
sleep 5
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

echo "[INFO] Checking for template VM (ID 100)..."
if qm list 2>/dev/null | awk '{print $1}' | grep -q '^100$'; then
    echo "[INFO] Template VM 100 already exists — skipping Azure restore."
else
    echo "[INFO] VM 100 not found — checking Azure for template backup..."
    _restore_template_from_azure
fi

echo "[INFO] Checking for spoke VM (ID 1001)..."
if qm list 2>/dev/null | awk '{print $1}' | grep -q '^1001$' || \
   pct list 2>/dev/null | awk '{print $1}' | grep -q '^1001$'; then
    echo "[INFO] Spoke VM 1001 already exists — skipping restore."
else
    echo "[INFO] VM 1001 not found — checking Azure for spoke backup..."
    _restore_spoke_from_azure
fi

echo
echo "=== Installation complete ==="
echo "  Agent    : v${AGENT_VERSION:-unknown}"
[ -n "$SPOKE_IP" ] && echo "  Spoke IP : ${SPOKE_IP}  (login: http://${SPOKE_IP}:${SPOKE_PORT})"
echo "  Logs     : journalctl -u $SERVICE_NAME -f"
echo "  Status   : systemctl status $SERVICE_NAME"
echo "  Watchdog : systemctl status proxmox-watchdog.timer"
