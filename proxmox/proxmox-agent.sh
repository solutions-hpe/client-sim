#!/bin/bash
# proxmox-agent.sh — Client-Sim Proxmox Host Agent
# Collects VM + node telemetry and polls for commands from the local WebUI.
# Runs as a systemd service on the Proxmox HOST (not in the LXC container).

set -euo pipefail

AGENT_LOG="/var/log/client-sim-proxmox-agent.log"
SERVER_URL="${CLIENT_SIM_SERVER_URL:-}"
API_KEY="${CLIENT_SIM_API_KEY:-}"
POLL_INTERVAL="${CLIENT_SIM_POLL_INTERVAL:-60}"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$AGENT_LOG"; }

if [[ -z "$SERVER_URL" ]]; then
    log "ERROR: CLIENT_SIM_SERVER_URL not set."
    exit 1
fi

AUTH_HEADER=""
[[ -n "$API_KEY" ]] && AUTH_HEADER='-H "X-API-Key: '$API_KEY'"'

curl_api() {
    local method="$1" path="$2" data="${3:-}"
    local args=(-sS --max-time 15 -X "$method" "${SERVER_URL}${path}"
                -H "Content-Type: application/json")
    [[ -n "$API_KEY" ]] && args+=(-H "X-API-Key: $API_KEY")
    [[ -n "$data"   ]] && args+=(-d "$data")
    curl "${args[@]}"
}

collect_telemetry() {
    local cpu_line mem_total mem_free
    cpu_line=$(top -bn1 | grep "Cpu(s)" | awk '{print $2}' | cut -d'%' -f1 2>/dev/null || echo "0")
    mem_total=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    mem_free=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
    local mem_used=$(( mem_total - mem_free ))

    local storage_json="[]"
    if command -v pvesm &>/dev/null; then
        storage_json=$(pvesm status 2>/dev/null | awk 'NR>1 {
            printf "{\"name\":\"%s\",\"type\":\"%s\",\"used\":%s,\"total\":%s},",
            $1,$2,$6,$4
        }' | sed 's/,$//' | awk 'BEGIN{print "["}{print}END{print "]"}' | tr -d '\n')
    fi

    local vms_json="[]"
    if command -v qm &>/dev/null; then
        vms_json=$(qm list 2>/dev/null | awk 'NR>1 {
            printf "{\"vmid\":%s,\"name\":\"%s\",\"status\":\"%s\",\"mem\":%s,\"maxmem\":%s},",
            $1,$2,$3,$4,$5
        }' | sed 's/,$//' | awk 'BEGIN{print "["}{print}END{print "]"}' | tr -d '\n')
    fi

    cat <<JSON
{
  "node": {
    "hostname": "$(hostname)",
    "cpu_percent": ${cpu_line:-0},
    "mem_used_kb": ${mem_used:-0},
    "mem_total_kb": ${mem_total:-0},
    "storage": ${storage_json:-[]}
  },
  "vms": ${vms_json:-[]}
}
JSON
}

execute_vm_command() {
    local action="$1" vmid="$2"
    case "$action" in
        start_vm)     qm start "$vmid" ;;
        stop_vm)      qm stop  "$vmid" ;;
        reboot_vm)    qm reboot "$vmid" ;;
        snapshot_vm)  qm snapshot "$vmid" "auto-$(date +%Y%m%d%H%M)" --description "client-sim" ;;
        reclone_vm)
            qm stop "$vmid" 2>/dev/null || true
            sleep 3
            qm destroy "$vmid" --purge
            if [[ -f /opt/client-sim-repo/proxmox/clone.sh ]]; then
                bash /opt/client-sim-repo/proxmox/clone.sh
            fi
            ;;
        delete_vm)
            qm stop "$vmid" 2>/dev/null || true
            sleep 2
            qm destroy "$vmid" --purge
            ;;
        reclone_vms)   [[ -f /opt/client-sim-repo/proxmox/clone.sh ]] && bash /opt/client-sim-repo/proxmox/clone.sh ;;
        snapshot_vms)
            for vid in $(qm list | awk 'NR>1{print $1}'); do
                qm snapshot "$vid" "auto-$(date +%Y%m%d%H%M)" --description "client-sim" || true
            done
            ;;
        start_vms)  for vid in $(qm list | awk 'NR>1{print $1}'); do qm start "$vid"  || true; done ;;
        stop_vms)   for vid in $(qm list | awk 'NR>1{print $1}'); do qm stop  "$vid"  || true; done ;;
        *)          return 1 ;;
    esac
}

log "Proxmox agent starting. Server: $SERVER_URL"

while true; do
    telemetry=$(collect_telemetry)
    curl_api POST /api/proxmox/telemetry "$telemetry" >/dev/null 2>&1         && log "Telemetry sent"         || log "WARNING: telemetry POST failed"

    response=$(curl_api GET "/api/inbox?hostname=proxmox" "" 2>/dev/null || echo "[]")
    if [[ -n "$response" && "$response" != "[]" ]]; then
        log "Commands received: $response"
        echo "$response" | grep -o '"id":"[^"]*","action":"[^"]*"' | while IFS= read -r pair; do
            cmd_id=$(echo "$pair" | grep -o '"id":"[^"]*"'     | cut -d'"' -f4)
            action=$(echo "$pair" | grep -o '"action":"[^"]*"' | cut -d'"' -f4)
            vmid=$(echo "$response" | grep -o '"vmid":[0-9]*' | head -1 | cut -d: -f2 || echo "")

            log "Executing $action (vmid=$vmid)"
            status="completed"; message=""
            if execute_vm_command "$action" "$vmid" 2>>"$AGENT_LOG"; then
                message="$action completed"
            else
                status="failed"; message="$action failed — check $AGENT_LOG"
            fi

            curl_api POST /api/inbox/ack                 "{\"id\":\"$cmd_id\",\"status\":\"$status\",\"message\":\"$message\"}"                 >/dev/null 2>&1
            log "ACK: $cmd_id status=$status"
        done
    fi

    sleep "$POLL_INTERVAL"
done
