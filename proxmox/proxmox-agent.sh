#!/bin/bash
# proxmox-agent.sh — Client-Sim Proxmox Host Agent
# Collects VM + node telemetry, polls for commands, and auto-provisions USB-backed VMs.
# Runs as a systemd service on the Proxmox HOST (not in the LXC container).

set -euo pipefail

AGENT_LOG="/var/log/client-sim-proxmox-agent.log"
SERVER_URL="${CLIENT_SIM_SERVER_URL:-}"
API_KEY="${CLIENT_SIM_API_KEY:-}"
POLL_INTERVAL="${CLIENT_SIM_POLL_INTERVAL:-60}"
STATE_FILE="/etc/client-sim-usb-state.conf"

AUTO_PROVISION="off"
MISSING_TIMEOUT=60
TEMPLATE_ID=100
UNKNOWN_USB_JSON="[]"
USB_STATE_JSON="[]"

h=$(hostname)
last3="${h: -3}"
[[ "$last3" =~ ^[0-9]{3}$ ]] && host_id="$last3" || host_id="001"
id_num=$((10#$host_id))
start_vmid=$((90000 + (id_num - 1) * 24 + 1))
end_vmid=$((start_vmid + 23))

declare -A CERTIFIED_TYPES CERTIFIED_LABELS IGNORED_VIDPIDS
declare -A USB_NAME_BY_BUS USB_VIDPID_BY_BUS PRESENT_BUSES
declare -A STATE_BUS_TO_VMID STATE_VMID_TO_BUS STATE_MISSING_BY_BUS

declare -a UNKNOWN_USB_LINES USB_STATE_LINES

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$AGENT_LOG"; }

if [[ -z "$SERVER_URL" ]]; then
    log "ERROR: CLIENT_SIM_SERVER_URL not set."
    exit 1
fi

curl_api() {
    local method="$1" path="$2" data="${3:-}"
    local args=(-sS --max-time 15 -X "$method" "${SERVER_URL}${path}" -H "Content-Type: application/json")
    [[ -n "$API_KEY" ]] && args+=(-H "X-API-Key: $API_KEY")
    [[ -n "$data" ]] && args+=(-d "$data")
    curl "${args[@]}"
}

ensure_state_file() {
    touch "$STATE_FILE"
}

json_from_records() {
    local kind="$1"
    shift || true
    python3 - "$kind" "$@" <<'PY'
import json
import sys

kind = sys.argv[1]
items = []
for raw in sys.argv[2:]:
    parts = raw.split("\t")
    if kind == "unknown":
        bus_path, vidpid, name = (parts + ["", "", ""])[:3]
        items.append({"bus_path": bus_path, "vidpid": vidpid, "name": name})
    else:
        vmid, bus_path, missing_since, name, vidpid = (parts + ["", "", "", "", ""])[:5]
        items.append({
            "vmid": int(vmid) if vmid else None,
            "bus_path": bus_path,
            "missing_since": int(missing_since) if missing_since else None,
            "name": name,
            "vidpid": vidpid,
        })
print(json.dumps(items))
PY
}

find_label_for_vidpid() {
    local vidpid="$1"
    if [[ -n "${CERTIFIED_LABELS[$vidpid]:-}" ]]; then
        printf '%s' "${CERTIFIED_LABELS[$vidpid]}"
    else
        printf '%s' "$vidpid"
    fi
}

device_name_from_sysfs() {
    local dev="$1" manufacturer="" product="" name
    [[ -f "$dev/manufacturer" ]] && manufacturer=$(tr -d '\n' < "$dev/manufacturer")
    [[ -f "$dev/product" ]] && product=$(tr -d '\n' < "$dev/product")
    name="$manufacturer $product"
    name=$(echo "$name" | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//')
    if [[ -z "$name" ]]; then
        name=$(basename "$dev")
    fi
    printf '%s' "$name"
}

refresh_usb_config() {
    local response parsed kind a b c
    response=$(curl_api GET /api/proxmox/usb-config "" 2>/dev/null || echo '{}')
    parsed=$(python3 - "$response" <<'PY' 2>/dev/null || true
import json
import sys

raw = sys.argv[1] if len(sys.argv) > 1 else '{}'
try:
    data = json.loads(raw)
except Exception:
    data = {}

print("CFG\t{}\t{}\t{}".format(
    str(data.get("auto_provision", "off")).lower(),
    int(data.get("missing_timeout", 60) or 60),
    int(data.get("template_id", 100) or 100),
))
for item in data.get("vidpids", []) or []:
    if not isinstance(item, dict):
        continue
    vidpid = str(item.get("vidpid", "")).strip().lower()
    if not vidpid:
        continue
    dtype = str(item.get("type", "wireless")).strip().lower() or "wireless"
    label = str(item.get("label", "")).replace("\t", " ").strip()
    print(f"CERT\t{vidpid}\t{dtype}\t{label}")
for vidpid in data.get("ignored_vidpids", []) or []:
    value = str(vidpid).strip().lower()
    if value:
        print(f"IGN\t{value}")
PY
)

    CERTIFIED_TYPES=()
    CERTIFIED_LABELS=()
    IGNORED_VIDPIDS=()
    AUTO_PROVISION="off"
    MISSING_TIMEOUT=60
    TEMPLATE_ID=100

    while IFS=$'\t' read -r kind a b c; do
        [[ -z "$kind" ]] && continue
        case "$kind" in
            CFG)
                AUTO_PROVISION="$a"
                MISSING_TIMEOUT="$b"
                TEMPLATE_ID="$c"
                ;;
            CERT)
                CERTIFIED_TYPES["$a"]="$b"
                CERTIFIED_LABELS["$a"]="$c"
                ;;
            IGN)
                IGNORED_VIDPIDS["$a"]=1
                ;;
        esac
    done <<< "$parsed"
}

load_state_file() {
    ensure_state_file
    STATE_BUS_TO_VMID=()
    STATE_VMID_TO_BUS=()
    STATE_MISSING_BY_BUS=()
    while IFS=$'\t' read -r vmid bus_path missing_since; do
        [[ -z "$vmid" || -z "$bus_path" ]] && continue
        STATE_BUS_TO_VMID["$bus_path"]="$vmid"
        STATE_VMID_TO_BUS["$vmid"]="$bus_path"
        STATE_MISSING_BY_BUS["$bus_path"]="$missing_since"
    done < "$STATE_FILE"
}

save_state_file() {
    ensure_state_file
    {
        for vmid in "${!STATE_VMID_TO_BUS[@]}"; do
            local_bus="${STATE_VMID_TO_BUS[$vmid]}"
            printf '%s\t%s\t%s\n' "$vmid" "$local_bus" "${STATE_MISSING_BY_BUS[$local_bus]:-}"
        done | sort -n
    } > "$STATE_FILE"
}

scan_usb_devices() {
    USB_NAME_BY_BUS=()
    USB_VIDPID_BY_BUS=()
    PRESENT_BUSES=()
    UNKNOWN_USB_LINES=()

    local dev bus_path vid pid vidpid name
    for dev in /sys/bus/usb/devices/*; do
        [[ -d "$dev" ]] || continue
        [[ -f "$dev/idVendor" && -f "$dev/idProduct" ]] || continue
        [[ "$dev" == *:* ]] && continue

        bus_path=$(basename "$dev")
        vid=$(tr '[:upper:]' '[:lower:]' < "$dev/idVendor")
        pid=$(tr '[:upper:]' '[:lower:]' < "$dev/idProduct")
        vidpid="$vid:$pid"
        name=$(device_name_from_sysfs "$dev")

        USB_NAME_BY_BUS["$bus_path"]="$name"
        USB_VIDPID_BY_BUS["$bus_path"]="$vidpid"

        if [[ -n "${IGNORED_VIDPIDS[$vidpid]:-}" ]]; then
            continue
        fi
        if [[ -n "${CERTIFIED_TYPES[$vidpid]:-}" || -n "${CERTIFIED_LABELS[$vidpid]:-}" ]]; then
            PRESENT_BUSES["$bus_path"]="$vidpid"
        else
            UNKNOWN_USB_LINES+=("${bus_path}\t${vidpid}\t${name}")
        fi
    done
}

build_usb_state_json() {
    USB_STATE_LINES=()
    local vmid bus_path missing_since name vidpid
    for vmid in "${!STATE_VMID_TO_BUS[@]}"; do
        bus_path="${STATE_VMID_TO_BUS[$vmid]}"
        missing_since="${STATE_MISSING_BY_BUS[$bus_path]:-}"
        vidpid="${USB_VIDPID_BY_BUS[$bus_path]:-}"
        name="${USB_NAME_BY_BUS[$bus_path]:-$(find_label_for_vidpid "$vidpid")}"
        USB_STATE_LINES+=("${vmid}\t${bus_path}\t${missing_since}\t${name}\t${vidpid}")
    done
    if (( ${#UNKNOWN_USB_LINES[@]} )); then
        UNKNOWN_USB_JSON=$(json_from_records unknown "${UNKNOWN_USB_LINES[@]}")
    else
        UNKNOWN_USB_JSON="[]"
    fi
    if (( ${#USB_STATE_LINES[@]} )); then
        USB_STATE_JSON=$(json_from_records state "${USB_STATE_LINES[@]}")
    else
        USB_STATE_JSON="[]"
    fi
}

clone_vm_for_usb() {
    local vmid="$1" bus_path="$2" product_name="$3"
    local guest_ready=0

    qm clone "$TEMPLATE_ID" "$vmid" --name "sim-client-$vmid"
    qm set "$vmid" --onboot 1 --startup "order=2,up=60"
    qm set "$vmid" -usb0 "host=$bus_path"
    qm start "$vmid"

    for _ in $(seq 1 60); do
        if qm guest ping "$vmid" >/dev/null 2>&1; then
            guest_ready=1
            break
        fi
        sleep 2
    done

    if [[ "$guest_ready" -eq 1 ]]; then
        qm guest exec "$vmid" -- hostnamectl set-hostname "sim-client-$vmid" >/dev/null 2>&1 || true
        qm guest exec "$vmid" -- reboot >/dev/null 2>&1 || true
    else
        log "WARNING: Guest agent not ready for VM $vmid"
    fi

    log "Provisioned VM $vmid for USB $bus_path (${product_name})"
}

provision_vm() {
    local bus_path="$1" vidpid="$2" product_name="$3"
    local free_vmid=""
    local vmid

    for vmid in $(seq "$start_vmid" "$end_vmid"); do
        if [[ -z "${STATE_VMID_TO_BUS[$vmid]:-}" ]]; then
            free_vmid="$vmid"
            break
        fi
    done

    if [[ -z "$free_vmid" ]]; then
        log "No free slots available in VM range $start_vmid-$end_vmid"
        return 1
    fi

    clone_vm_for_usb "$free_vmid" "$bus_path" "$product_name"
    STATE_BUS_TO_VMID["$bus_path"]="$free_vmid"
    STATE_VMID_TO_BUS["$free_vmid"]="$bus_path"
    STATE_MISSING_BY_BUS["$bus_path"]=""
    log "Provisioned VM $free_vmid for USB $bus_path ($vidpid)"
}

destroy_vm() {
    local vmid="$1"
    local bus_path="${STATE_VMID_TO_BUS[$vmid]:-}"
    qm stop "$vmid" 2>/dev/null || true
    qm destroy "$vmid" --skiplock --purge --destroy-unreferenced-disks 2>/dev/null || true
    if [[ -n "$bus_path" ]]; then
        unset 'STATE_MISSING_BY_BUS[$bus_path]'
        unset 'STATE_BUS_TO_VMID[$bus_path]'
    fi
    unset 'STATE_VMID_TO_BUS[$vmid]'
    save_state_file
    log "Destroyed VM $vmid"
}

reclone_vm_instance() {
    local vmid="$1"
    local bus_path vidpid product_name

    refresh_usb_config
    load_state_file
    scan_usb_devices

    bus_path="${STATE_VMID_TO_BUS[$vmid]:-}"
    if [[ -z "$bus_path" ]]; then
        log "WARNING: No tracked USB mapping found for VM $vmid"
        return 1
    fi
    if [[ ! -d "/sys/bus/usb/devices/$bus_path" ]]; then
        log "WARNING: USB device $bus_path is not present; cannot reclone VM $vmid"
        return 1
    fi

    vidpid="${USB_VIDPID_BY_BUS[$bus_path]:-}"
    product_name="${USB_NAME_BY_BUS[$bus_path]:-$(find_label_for_vidpid "$vidpid")}"

    destroy_vm "$vmid"
    clone_vm_for_usb "$vmid" "$bus_path" "$product_name"
    STATE_BUS_TO_VMID["$bus_path"]="$vmid"
    STATE_VMID_TO_BUS["$vmid"]="$bus_path"
    STATE_MISSING_BY_BUS["$bus_path"]=""
    save_state_file
    log "Recloned VM $vmid for USB $bus_path ($vidpid)"
}

usb_provision_loop() {
    local now bus_path vidpid product_name vmid missing_since

    refresh_usb_config
    scan_usb_devices
    load_state_file

    for bus_path in "${!PRESENT_BUSES[@]}"; do
        if [[ -z "${STATE_BUS_TO_VMID[$bus_path]:-}" ]]; then
            vidpid="${PRESENT_BUSES[$bus_path]}"
            product_name="${USB_NAME_BY_BUS[$bus_path]:-$(find_label_for_vidpid "$vidpid")}"
            provision_vm "$bus_path" "$vidpid" "$product_name" || true
        fi
    done

    now=$(date +%s)
    for bus_path in "${!STATE_BUS_TO_VMID[@]}"; do
        vmid="${STATE_BUS_TO_VMID[$bus_path]}"
        if [[ -z "${PRESENT_BUSES[$bus_path]:-}" ]]; then
            missing_since="${STATE_MISSING_BY_BUS[$bus_path]:-}"
            if [[ -z "$missing_since" ]]; then
                STATE_MISSING_BY_BUS["$bus_path"]="$now"
                log "USB $bus_path missing for VM $vmid; grace timer started"
            elif (( now - missing_since > MISSING_TIMEOUT * 60 )); then
                destroy_vm "$vmid"
            fi
        elif [[ -n "${STATE_MISSING_BY_BUS[$bus_path]:-}" ]]; then
            STATE_MISSING_BY_BUS["$bus_path"]=""
            log "USB $bus_path returned for VM $vmid"
        fi
    done

    save_state_file
    build_usb_state_json
}

refresh_usb_telemetry_only() {
    refresh_usb_config
    scan_usb_devices
    load_state_file
    build_usb_state_json
}

collect_telemetry() {
    local cpu_line mem_total mem_free mem_used storage_json vms_json
    cpu_line=$(top -bn1 | grep "Cpu(s)" | awk '{print $2}' | cut -d'%' -f1 2>/dev/null || echo "0")
    mem_total=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    mem_free=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
    mem_used=$(( mem_total - mem_free ))

    storage_json="[]"
    if command -v pvesm &>/dev/null; then
        storage_json=$(pvesm status 2>/dev/null | awk 'NR>1 {
            printf "{\"name\":\"%s\",\"type\":\"%s\",\"used\":%s,\"total\":%s},",
            $1,$2,$6,$4
        }' | sed 's/,$//' | awk 'BEGIN{print "["}{print}END{print "]"}' | tr -d '\n')
    fi

    vms_json="[]"
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
  "vms": ${vms_json:-[]},
  "unknown_usb": ${UNKNOWN_USB_JSON:-[]},
  "usb_state": ${USB_STATE_JSON:-[]}
}
JSON
}

execute_vm_command() {
    local action="$1" vmid="${2:-}" _type="${3:-}"
    case "$action" in
        start_vm)     qm start "$vmid" ;;
        stop_vm)      qm stop "$vmid" ;;
        reboot_vm)    qm reboot "$vmid" ;;
        snapshot_vm)  qm snapshot "$vmid" "auto-$(date +%Y%m%d%H%M)" --description "client-sim" ;;
        reclone_vm)   reclone_vm_instance "$vmid" ;;
        delete_vm)
            load_state_file
            destroy_vm "$vmid"
            ;;
        reclone_vms)  [[ -f /opt/client-sim-repo/proxmox/clone.sh ]] && bash /opt/client-sim-repo/proxmox/clone.sh ;;
        snapshot_vms)
            for vid in $(qm list | awk 'NR>1{print $1}'); do
                qm snapshot "$vid" "auto-$(date +%Y%m%d%H%M)" --description "client-sim" || true
            done
            ;;
        start_vms)  for vid in $(qm list | awk 'NR>1{print $1}'); do qm start "$vid" || true; done ;;
        stop_vms)   for vid in $(qm list | awk 'NR>1{print $1}'); do qm stop  "$vid" || true; done ;;
        *)          return 1 ;;
    esac
}

log "Proxmox agent starting. Server: $SERVER_URL"
log "Host block $host_id → VM range $start_vmid-$end_vmid"
ensure_state_file
refresh_usb_telemetry_only || true

while true; do
    refresh_usb_config || true
    if [[ "$AUTO_PROVISION" == "on" ]]; then
        usb_provision_loop || log "WARNING: USB auto-provisioning loop failed"
    else
        refresh_usb_telemetry_only || true
    fi

    telemetry=$(collect_telemetry)
    curl_api POST /api/proxmox/telemetry "$telemetry" >/dev/null 2>&1 \
        && log "Telemetry sent" \
        || log "WARNING: telemetry POST failed"

    response=$(curl_api GET "/api/inbox?hostname=proxmox" "" 2>/dev/null || echo "[]")
    if [[ -n "$response" && "$response" != "[]" ]]; then
        log "Commands received: $response"
        parsed_commands=$(python3 - "$response" <<'PY' 2>/dev/null || true
import json
import sys

raw = sys.argv[1] if len(sys.argv) > 1 else '[]'
try:
    commands = json.loads(raw)
except Exception:
    commands = []
for cmd in commands:
    cid = str(cmd.get('id', '')).replace('\t', ' ')
    action = str(cmd.get('action', '')).replace('\t', ' ')
    vmid = cmd.get('args', {}).get('vmid', '')
    ctype = str(cmd.get('type') or '').replace('\t', ' ')
    print(f"{cid}\t{action}\t{vmid}\t{ctype}")
PY
)
        while IFS=$'\t' read -r cmd_id action vmid cmd_type; do
            [[ -z "$cmd_id" || -z "$action" ]] && continue
            log "Executing $action (vmid=${vmid:-})"
            status="completed"
            message=""
            if execute_vm_command "$action" "$vmid" "$cmd_type" 2>>"$AGENT_LOG"; then
                message="$action completed"
            else
                status="failed"
                message="$action failed — check $AGENT_LOG"
            fi

            curl_api POST /api/inbox/ack "{\"id\":\"$cmd_id\",\"status\":\"$status\",\"message\":\"$message\"}" >/dev/null 2>&1
            log "ACK: $cmd_id status=$status"
        done <<< "$parsed_commands"
    fi

    sleep "$POLL_INTERVAL"
done
