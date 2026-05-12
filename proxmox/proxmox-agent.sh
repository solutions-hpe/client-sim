#!/bin/bash
# proxmox-agent.sh — Client-Sim Proxmox Host Agent
# Collects VM + node telemetry, polls for commands, and auto-provisions USB-backed VMs.
# Runs as a systemd service on the Proxmox HOST (not in the LXC container).

set -euo pipefail

AGENT_VERSION="3.16"
AGENT_LOG="/var/log/client-sim-proxmox-agent.log"
AGENT_LOG_OFFSET_FILE="/var/lib/client-sim/agent-log-offset"
PIDFILE="/var/run/client-sim-proxmox-agent.pid"
SERVER_URL="${CLIENT_SIM_SERVER_URL:-}"
API_KEY="${CLIENT_SIM_API_KEY:-}"
POLL_INTERVAL="${CLIENT_SIM_POLL_INTERVAL:-15}"
TELEMETRY_INTERVAL="${CLIENT_SIM_TELEMETRY_INTERVAL:-10}"
INBOX_INTERVAL="${CLIENT_SIM_INBOX_INTERVAL:-10}"
SELF_UPDATE_INTERVAL="${CLIENT_SIM_SELF_UPDATE_INTERVAL:-21600}"  # 6 hours
STATE_FILE="/etc/client-sim-usb-state.conf"
ENV_FILE="/etc/client-sim-proxmox-agent.env"
AGENT_PORT="${CLIENT_SIM_AGENT_PORT:-9105}"
HEALTH_STALE_SECS="${CLIENT_SIM_AGENT_HEALTH_STALE_SECS:-180}"
HEALTH_FILE="/var/lib/client-sim/agent-health.json"
USB_STATE_CACHE="/tmp/client-sim-usb-state.cache"
USB_PRESENT_CACHE="/tmp/client-sim-usb-present.cache"
USB_UNKNOWN_CACHE="/tmp/client-sim-usb-unknown.cache"
RECLONE_STATE_CACHE="/var/lib/client-sim/reclone-state.json"

# Prevent duplicate instances
if [[ -f "$PIDFILE" ]] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Another instance already running (PID $(cat "$PIDFILE")), exiting."
    exit 1
fi
echo $$ > "$PIDFILE"
trap 'rm -f "$PIDFILE"; [[ -n "${TELEMETRY_PID:-}" ]] && kill "$TELEMETRY_PID" 2>/dev/null; [[ -n "${INBOX_PID:-}" ]] && kill "$INBOX_PID" 2>/dev/null; true' EXIT

AUTO_PROVISION="off"
MISSING_TIMEOUT=60
PROV_DIR=/tmp/client-sim-prov
mkdir -p "$PROV_DIR"
IMAGE1_TEMPLATE_ID=100
IMAGE2_TEMPLATE_ID=200
IMAGE1_PCT=50
RECLONE_CONCURRENCY=1
L1_VLAN_START=100
L1_VLAN_END=199
MAX_USB_SLOTS=24
UNKNOWN_USB_JSON="[]"
USB_STATE_JSON="[]"
PRESENT_USB_JSON="[]"

h=$(hostname)
last3="${h: -3}"
[[ "$last3" =~ ^[0-9]{3}$ ]] && host_id="$last3" || host_id="001"
id_num=$((10#$host_id))
# MAX_USB_SLOTS is updated from usb-config at runtime; default 24 per host.
MAX_USB_SLOTS=24
start_vmid=$((90000 + (id_num - 1) * MAX_USB_SLOTS + 1))
end_vmid=$((start_vmid + MAX_USB_SLOTS - 1))

declare -A CERTIFIED_TYPES CERTIFIED_LABELS IGNORED_VIDPIDS
declare -A USB_NAME_BY_BUS USB_VIDPID_BY_BUS PRESENT_BUSES
declare -A STATE_VMID_TO_IMAGE
declare -A STATE_BUS_TO_VMID STATE_VMID_TO_BUS STATE_MISSING_BY_BUS STATE_VIDPID_BY_BUS
declare -A _RECLONE_CMD_IDS=()   # vmid -> cmd_id, used for parallel reclone ACKs

declare -a UNKNOWN_USB_LINES USB_STATE_LINES

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

write_reclone_state_cache() {
    local status="$1" vmids_json="${2:-[]}" phase="${3:-}"
    local phase_field=""
    [[ -n "$phase" ]] && phase_field=",\"phase\":\"${phase}\""
    cat >"$RECLONE_STATE_CACHE" <<JSON
{"status":"${status}","active_vmids":${vmids_json}${phase_field},"updated_at":"$(date -u +%Y-%m-%dT%H:%M:%SZ)"}
JSON
}

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

json_field() {
    local payload="$1" field="$2"
    python3 -c "import json,sys; data=json.loads(sys.argv[1] or '{}'); value=data.get(sys.argv[2], ''); print(str(value))" "$payload" "$field" 2>/dev/null || true
}

save_api_key() {
    local key="$1"
    if grep -q '^CLIENT_SIM_API_KEY=' "$ENV_FILE" 2>/dev/null; then
        sed -i "s/^CLIENT_SIM_API_KEY=.*/CLIENT_SIM_API_KEY=${key}/" "$ENV_FILE"
    else
        echo "CLIENT_SIM_API_KEY=${key}" >> "$ENV_FILE"
    fi
    API_KEY="$key"
}

save_repo_branch() {
    local branch="$1"
    if grep -q '^CLIENT_SIM_REPO_BRANCH=' "$ENV_FILE" 2>/dev/null; then
        sed -i "s/^CLIENT_SIM_REPO_BRANCH=.*/CLIENT_SIM_REPO_BRANCH=${branch}/" "$ENV_FILE"
    else
        echo "CLIENT_SIM_REPO_BRANCH=${branch}" >> "$ENV_FILE"
    fi
}

schedule_agent_restart() {
    local service_name="client-sim-proxmox-agent"
    local systemctl_bin
    systemctl_bin=$(command -v systemctl || echo /bin/systemctl)
    if command -v systemd-run >/dev/null 2>&1; then
        local restart_unit="client-sim-proxmox-agent-restart-$(date +%s)"
        if systemd-run --quiet --collect --unit "$restart_unit" --on-active=2s "$systemctl_bin" restart "$service_name"; then
            log "Scheduled agent restart via ${restart_unit}"
            return 0
        fi
        log "WARNING: systemd-run restart scheduling failed; falling back to nohup"
    fi
    nohup bash -lc "sleep 2; exec \"$systemctl_bin\" restart \"$service_name\"" >/dev/null 2>&1 &
    return 0
}

clear_api_key() {
    if grep -q '^CLIENT_SIM_API_KEY=' "$ENV_FILE" 2>/dev/null; then
        sed -i 's/^CLIENT_SIM_API_KEY=.*/CLIENT_SIM_API_KEY=/' "$ENV_FILE"
    fi
    API_KEY=""
}

curl_api_status() {
    local method="$1" path="$2" data="${3:-}"
    local args=(-sS --max-time 15 -X "$method" "${SERVER_URL}${path}" -H "Content-Type: application/json" -w $'\n%{http_code}')
    [[ -n "$API_KEY" ]] && args+=(-H "X-API-Key: $API_KEY")
    [[ -n "$data" ]] && args+=(-d "$data")
    curl "${args[@]}"
}

normalize_command_name() {
    printf '%s' "${1//-/_}"
}

json_payload() {
    python3 - "$@" <<'PY'
import json
import sys
print(json.dumps({
    "id": sys.argv[1],
    "status": sys.argv[2],
    "message": sys.argv[3],
}))
PY
}

ack_inbox_command() {
    local cmd_id="$1" status="$2" message="${3:-}"
    local payload response_with_status http_status body attempt
    payload=$(json_payload "$cmd_id" "$status" "$message") || return 1
    for attempt in 1 2 3; do
        response_with_status=$(curl_api_status POST /api/inbox/ack "$payload" 2>/dev/null || true)
        http_status="${response_with_status##*$'\n'}"
        body="${response_with_status%$'\n'*}"
        case "$http_status" in
            200)
                log "ACK: ${cmd_id} status=${status}"
                return 0
                ;;
            404)
                log "ACK skipped: ${cmd_id} already gone from server queue"
                return 0
                ;;
            202|401|403)
                handle_auth_failure "$http_status" "/api/inbox/ack"
                ;;
            "")
                ;;
            *)
                log "WARNING: ACK ${cmd_id} attempt ${attempt} returned HTTP ${http_status} ${body:+body=${body:0:160}}"
                ;;
        esac
        sleep 2
    done
    log "ERROR: failed to ACK command ${cmd_id} after 3 attempts"
    return 1
}

handle_auth_failure() {
    local status="$1" endpoint="$2"
    case "$status" in
        202|401|403)
            log "Auth/reset required after ${endpoint} (HTTP ${status}) — re-registering agent"
            clear_api_key
            register_and_wait_for_key
            return 0
            ;;
    esac
    return 1
}

register_and_wait_for_key() {
    local my_hostname response approved key poll_response poll_approved poll_key
    my_hostname=$(hostname)
    log "No API key found. Registering with server..."

    while true; do
        response=$(curl -sS --max-time 10 -X POST "${SERVER_URL}/api/proxmox/register" \
            -H "Content-Type: application/json" \
            -d "{\"hostname\":\"$my_hostname\"}" 2>/dev/null || echo '{}')

        approved=$(json_field "$response" approved)
        key=$(json_field "$response" key)

        if [[ "$approved" == "True" || "$approved" == "true" ]] && [[ -n "$key" ]]; then
            log "Approved! Saving API key."
            save_api_key "$key"
            return 0
        fi

        log "Pending approval... checking again in 30s"
        sleep 30

        poll_response=$(curl -sS --max-time 10 \
            "${SERVER_URL}/api/proxmox/key?hostname=$my_hostname" 2>/dev/null || echo '{}')
        poll_approved=$(json_field "$poll_response" approved)
        poll_key=$(json_field "$poll_response" key)

        if [[ "$poll_approved" == "True" || "$poll_approved" == "true" ]] && [[ -n "$poll_key" ]]; then
            log "Approved! Saving API key."
            save_api_key "$poll_key"
            return 0
        fi
    done
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
        vmid, bus_path, missing_since, name, vidpid, prov_status = (parts + ["", "", "", "", "", ""])[:6]
        items.append({
            "vmid": int(vmid) if vmid else None,
            "bus_path": bus_path,
            "missing_since": int(missing_since) if missing_since else None,
            "name": name,
            "vidpid": vidpid,
            "prov_status": prov_status or "active",
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

CLIENT_SETUP_CONF="/etc/pve/scripts/client-setup.conf"

get_vm_name() {
    local vmid="$1" name=""
    if [[ -f "$CLIENT_SETUP_CONF" ]]; then
        name=$(awk -v sec="[c${vmid}]" '
            $0 == sec        { found=1; next }
            found && /^\[/   { exit }
            found && /^vm_name=/ { sub(/^vm_name=[ \t]*/, ""); print; exit }
        ' "$CLIENT_SETUP_CONF")
    fi
    printf '%s' "${name:-sim-client}"
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

print("CFG\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}".format(
    str(data.get("auto_provision", "off")).lower(),
    int(data.get("missing_timeout", 60) or 60),
    int(data.get("image1_template_id", data.get("template_id", 100)) or 100),
    int(data.get("image2_template_id", 200) or 200),
    max(0, min(100, int(data.get("image1_pct", 50) or 50))),
    str(data.get("sim_phy", "wireless")).strip().lower() or "wireless",
    max(1, int(data.get("reclone_concurrency", 1) or 1)),
    max(1, min(4094, int(data.get("l1_vlan_start", 100) or 100))),
    max(1, min(4094, int(data.get("l1_vlan_end", 199) or 199))),
    max(1, min(256, int(data.get("max_slots", 24) or 24))),
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
    IMAGE1_TEMPLATE_ID=100
    IMAGE2_TEMPLATE_ID=200
    IMAGE1_PCT=50
    SIM_PHY="wireless"
    RECLONE_CONCURRENCY=1
    L1_VLAN_START=100
    L1_VLAN_END=199
    MAX_USB_SLOTS=24

    while IFS=$'\t' read -r kind a b c d e f g h i j; do
        [[ -z "$kind" ]] && continue
        case "$kind" in
            CFG)
                AUTO_PROVISION="$a"
                MISSING_TIMEOUT="$b"
                IMAGE1_TEMPLATE_ID="$c"
                IMAGE2_TEMPLATE_ID="$d"
                IMAGE1_PCT="${e:-50}"
                SIM_PHY="${f:-wireless}"
                RECLONE_CONCURRENCY="${g:-1}"
                L1_VLAN_START="${h:-100}"
                L1_VLAN_END="${i:-199}"
                MAX_USB_SLOTS="${j:-24}"
                start_vmid=$(( 90000 + (id_num - 1) * MAX_USB_SLOTS + 1 ))
                end_vmid=$(( start_vmid + MAX_USB_SLOTS - 1 ))
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
    STATE_VMID_TO_IMAGE=()
    STATE_VIDPID_BY_BUS=()
    local vmid bus_path missing_since image_num vidpid line rest
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" ]] && continue

        # Preserve empty tab-delimited fields; `read` with tab IFS collapses them and
        # turns a blank missing_since into the image number on every reload.
        vmid="${line%%$'\t'*}"
        rest="${line#*$'\t'}"
        [[ "$rest" == "$line" ]] && continue
        bus_path="${rest%%$'\t'*}"
        rest="${rest#*$'\t'}"
        missing_since="${rest%%$'\t'*}"
        if [[ "$rest" == *$'\t'* ]]; then
            rest="${rest#*$'\t'}"
            image_num="${rest%%$'\t'*}"
            if [[ "$rest" == *$'\t'* ]]; then
                vidpid="${rest#*$'\t'}"
            else
                vidpid=""
            fi
        else
            image_num="1"
            vidpid=""
        fi

        [[ -z "$vmid" || -z "$bus_path" ]] && continue
        STATE_BUS_TO_VMID["$bus_path"]="$vmid"
        STATE_VMID_TO_BUS["$vmid"]="$bus_path"
        STATE_MISSING_BY_BUS["$bus_path"]="$missing_since"
        STATE_VMID_TO_IMAGE["$vmid"]="${image_num:-1}"
        [[ -n "$vidpid" ]] && STATE_VIDPID_BY_BUS["$bus_path"]="$vidpid"
    done < "$STATE_FILE"
    prune_stale_state_vmids
}

prune_stale_state_vmids() {
    local qm_vmids vmid bus_path stale_count=0
    local -A existing_vmids=()

    if ! qm_vmids=$({ qm list 2>/dev/null || true; pct list 2>/dev/null || true; } | awk '$1 ~ /^[0-9]+$/ { print $1 }'); then
        log "WARNING: failed to enumerate existing guests; skipping stale VM state cleanup"
        return
    fi

    while IFS= read -r vmid; do
        [[ -n "$vmid" ]] && existing_vmids["$vmid"]=1
    done <<< "$qm_vmids"

    for vmid in "${!STATE_VMID_TO_BUS[@]}"; do
        [[ -n "${existing_vmids[$vmid]:-}" ]] && continue
        bus_path="${STATE_VMID_TO_BUS[$vmid]:-}"
        unset "STATE_VMID_TO_BUS[$vmid]"
        unset "STATE_VMID_TO_IMAGE[$vmid]"
        if [[ -n "$bus_path" ]]; then
            unset "STATE_BUS_TO_VMID[$bus_path]"
            unset "STATE_MISSING_BY_BUS[$bus_path]"
        fi
        ((stale_count++))
        log "Removed stale VM state for VM $vmid${bus_path:+ (bus $bus_path)}"
    done

    (( stale_count > 0 )) && save_state_file
}

save_state_file() {
    ensure_state_file
    {
        for vmid in "${!STATE_VMID_TO_BUS[@]}"; do
            local_bus="${STATE_VMID_TO_BUS[$vmid]}"
            printf '%s\t%s\t%s\t%s\t%s\n' "$vmid" "$local_bus" "${STATE_MISSING_BY_BUS[$local_bus]:-}" "${STATE_VMID_TO_IMAGE[$vmid]:-1}" "${STATE_VIDPID_BY_BUS[$local_bus]:-}"
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
            UNKNOWN_USB_LINES+=("${bus_path}"$'\t'"${vidpid}"$'\t'"${name}")
        fi
    done
}

usb_missing_timeout_seconds() {
    printf '%s' "$(( MISSING_TIMEOUT * 60 ))"
}

find_present_bus_for_vidpid() {
    local vidpid="$1" bus_path
    for bus_path in "${!PRESENT_BUSES[@]}"; do
        [[ "${PRESENT_BUSES[$bus_path]}" == "$vidpid" ]] || continue
        printf '%s' "$bus_path"
        return 0
    done
    return 1
}

guest_is_template() {
    local vmid="$1" guest_type="${2:-}" conf=""
    if [[ -z "$guest_type" ]]; then
        guest_type=$(get_guest_type "$vmid" 2>/dev/null || true)
    fi
    case "$guest_type" in
        qemu) conf="/etc/pve/qemu-server/${vmid}.conf" ;;
        lxc)  conf="/etc/pve/lxc/${vmid}.conf" ;;
        *)    return 1 ;;
    esac
    [[ -f "$conf" ]] && grep -Eq '^template:\s*1\s*$' "$conf"
}

reconcile_present_usb_state() {
    local _current_bus vmid missing_since _present_vidpid _state_vidpid _reconnected_bus _assigned_vmid
    local _changed=1

    for _current_bus in "${!STATE_BUS_TO_VMID[@]}"; do
        vmid="${STATE_BUS_TO_VMID[$_current_bus]}"
        missing_since="${STATE_MISSING_BY_BUS[$_current_bus]:-}"
        _present_vidpid="${PRESENT_BUSES[$_current_bus]:-}"
        _state_vidpid="${_present_vidpid:-${USB_VIDPID_BY_BUS[$_current_bus]:-${STATE_VIDPID_BY_BUS[$_current_bus]:-}}}"

        if [[ -n "$_state_vidpid" && "${STATE_VIDPID_BY_BUS[$_current_bus]:-}" != "$_state_vidpid" ]]; then
            STATE_VIDPID_BY_BUS["$_current_bus"]="$_state_vidpid"
            _changed=0
        fi

        if [[ -n "$_present_vidpid" ]]; then
            if [[ -n "$missing_since" ]]; then
                unset "STATE_MISSING_BY_BUS[$_current_bus]"
                _changed=0
                log "USB $_current_bus present again, clearing missing state for VM $vmid"
            fi
            continue
        fi

        [[ -n "$_state_vidpid" ]] || continue
        _reconnected_bus=$(find_present_bus_for_vidpid "$_state_vidpid" 2>/dev/null || true)
        [[ -n "$_reconnected_bus" && "$_reconnected_bus" != "$_current_bus" ]] || continue

        _assigned_vmid="${STATE_BUS_TO_VMID[$_reconnected_bus]:-}"
        if [[ -n "$_assigned_vmid" && "$_assigned_vmid" != "$vmid" ]]; then
            continue
        fi

        unset "STATE_BUS_TO_VMID[$_current_bus]"
        unset "STATE_MISSING_BY_BUS[$_current_bus]"
        unset "STATE_VIDPID_BY_BUS[$_current_bus]"
        STATE_VMID_TO_BUS["$vmid"]="$_reconnected_bus"
        STATE_BUS_TO_VMID["$_reconnected_bus"]="$vmid"
        STATE_VIDPID_BY_BUS["$_reconnected_bus"]="$_state_vidpid"
        unset "STATE_MISSING_BY_BUS[$_reconnected_bus]"
        _changed=0
        log "USB dongle vidpid $_state_vidpid moved from $_current_bus to $_reconnected_bus, clearing missing state for VM $vmid"
    done

    return $_changed
}

build_usb_state_json() {
    USB_STATE_LINES=()
    local vmid bus_path missing_since name vidpid prov_status _now_ts
    _now_ts=$(date +%s)
    for vmid in "${!STATE_VMID_TO_BUS[@]}"; do
        bus_path="${STATE_VMID_TO_BUS[$vmid]}"
        missing_since="${STATE_MISSING_BY_BUS[$bus_path]:-}"
        # Use live-scanned vidpid if device is present; update stored value so it
        # persists in the state file even after the dongle goes physically missing.
        if [[ -n "${USB_VIDPID_BY_BUS[$bus_path]:-}" ]]; then
            vidpid="${USB_VIDPID_BY_BUS[$bus_path]}"
            STATE_VIDPID_BY_BUS["$bus_path"]="$vidpid"
        else
            vidpid="${STATE_VIDPID_BY_BUS[$bus_path]:-}"
        fi
        name="${USB_NAME_BY_BUS[$bus_path]:-$(find_label_for_vidpid "$vidpid")}"
        # Determine provisioning status for UI display
        if [[ -f "${PROV_DIR}/${vmid}" ]]; then
            prov_status="provisioning"
        elif [[ -n "$missing_since" ]]; then
            if (( _now_ts - missing_since > MISSING_TIMEOUT * 60 )); then
                prov_status="tearing_down"
            else
                prov_status="missing"
            fi
        else
            prov_status="active"
        fi
        USB_STATE_LINES+=("${vmid}"$'\t'"${bus_path}"$'\t'"${missing_since}"$'\t'"${name}"$'\t'"${vidpid}"$'\t'"${prov_status}")
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
    # Build present_usb: all certified dongles physically detected right now
    local present_lines=()
    for bus_path in "${!PRESENT_BUSES[@]}"; do
        vidpid="${PRESENT_BUSES[$bus_path]}"
        name="${USB_NAME_BY_BUS[$bus_path]:-}"
        present_lines+=("${bus_path}"$'\t'"${vidpid}"$'\t'"${name}")
    done
    if (( ${#present_lines[@]} )); then
        PRESENT_USB_JSON=$(json_from_records unknown "${present_lines[@]}")
    else
        PRESENT_USB_JSON="[]"
    fi
    # Persist to cache files so the background telemetry sender can read them
    echo "$USB_STATE_JSON"  > "$USB_STATE_CACHE"
    echo "$PRESENT_USB_JSON" > "$USB_PRESENT_CACHE"
    echo "$UNKNOWN_USB_JSON" > "$USB_UNKNOWN_CACHE"
}

# Wait until a VM is fully stopped, with a timeout.
_wait_vm_stopped() {
    local vmid="$1" max_wait="${2:-90}"
    local elapsed=0
    while [[ $elapsed -lt $max_wait ]]; do
        local state
        state=$(qm status "$vmid" 2>/dev/null | awk '{print $2}')
        [[ "$state" == "stopped" ]] && return 0
        sleep 3
        elapsed=$(( elapsed + 3 ))
    done
    log "WARNING: VM $vmid did not stop within ${max_wait}s (state=$(qm status "$vmid" 2>/dev/null))"
    return 1
}

# Wait until a VMID no longer appears in qm list, with a timeout.
_wait_vmid_gone() {
    local vmid="$1" max_wait="${2:-90}"
    local elapsed=0
    while [[ $elapsed -lt $max_wait ]]; do
        qm status "$vmid" 2>/dev/null || return 0
        sleep 3
        elapsed=$(( elapsed + 3 ))
    done
    log "WARNING: VMID $vmid still exists after ${max_wait}s"
    return 1
}

get_guest_type() {
    local vmid="$1"
    if [[ -f "/etc/pve/qemu-server/${vmid}.conf" ]]; then
        printf 'qemu'
        return 0
    fi
    if [[ -f "/etc/pve/lxc/${vmid}.conf" ]]; then
        printf 'lxc'
        return 0
    fi
    qm status "$vmid" >/dev/null 2>&1 && { printf 'qemu'; return 0; }
    pct status "$vmid" >/dev/null 2>&1 && { printf 'lxc'; return 0; }
    return 1
}

_wait_guest_stopped() {
    local guest_type="$1" vmid="$2" max_wait="${3:-90}"
    local elapsed=0 cmd="qm"
    [[ "$guest_type" == "lxc" ]] && cmd="pct"
    while [[ $elapsed -lt $max_wait ]]; do
        local state
        state=$($cmd status "$vmid" 2>/dev/null | awk '{print $2}')
        [[ "$state" == "stopped" ]] && return 0
        sleep 3
        elapsed=$(( elapsed + 3 ))
    done
    log "WARNING: ${guest_type^^} $vmid did not stop within ${max_wait}s"
    return 1
}

_wait_guest_gone() {
    local guest_type="$1" vmid="$2" max_wait="${3:-90}"
    local elapsed=0 cmd="qm"
    [[ "$guest_type" == "lxc" ]] && cmd="pct"
    while [[ $elapsed -lt $max_wait ]]; do
        $cmd status "$vmid" 2>/dev/null || return 0
        sleep 3
        elapsed=$(( elapsed + 3 ))
    done
    log "WARNING: ${guest_type^^} $vmid still exists after ${max_wait}s"
    return 1
}

_destroy_guest_only() {
    local vmid="$1" guest_type="${2:-}"
    if [[ -z "$guest_type" ]]; then
        guest_type=$(get_guest_type "$vmid" 2>/dev/null || true)
    fi
    if [[ -z "$guest_type" ]]; then
        log "ERROR: Unable to determine guest type for VMID $vmid"
        return 1
    fi

    log "Stopping ${guest_type^^} $vmid before destroy"
    if [[ "$guest_type" == "lxc" ]]; then
        timeout 120 pct stop "$vmid" --force 2>/dev/null || \
            timeout 120 pct stop "$vmid" --skiplock 2>/dev/null || \
            timeout 120 pct stop "$vmid" 2>/dev/null || true
        _wait_guest_stopped "$guest_type" "$vmid" 90 || true
        log "Destroying LXC $vmid"
        timeout 300 pct destroy "$vmid" --skiplock --purge --force 2>/dev/null || \
            timeout 300 pct destroy "$vmid" --purge --force 2>/dev/null || \
            timeout 300 pct destroy "$vmid" --skiplock --purge 2>/dev/null || \
            timeout 300 pct destroy "$vmid" --skiplock 2>/dev/null || \
            timeout 300 pct destroy "$vmid" 2>/dev/null || true
    else
        qm stop "$vmid" --skiplock --timeout 120 2>/dev/null || \
            qm stop "$vmid" --skiplock --timeout 0 2>/dev/null || true
        _wait_guest_stopped "$guest_type" "$vmid" 150 || true
        log "Destroying VM $vmid"
        timeout 300 qm destroy "$vmid" --skiplock --purge --destroy-unreferenced-disks 2>/dev/null || true
    fi

    _wait_guest_gone "$guest_type" "$vmid" 90
}

destroy_lxc() {
    _destroy_guest_only "$1" "lxc"
}

clone_lxc_instance() {
    local vmid="$1" source_vmid="$2"
    if [[ -z "$source_vmid" ]]; then
        log "ERROR: No LXC template/source VMID provided for CT $vmid"
        return 1
    fi

    local ct_name
    ct_name=$(pct config "$vmid" 2>/dev/null | awk -F': ' '$1=="hostname" {print $2; exit}')
    [[ -z "$ct_name" ]] && ct_name="ct-${vmid}"

    local -a reapply_args=()
    local line key value
    while IFS= read -r line; do
        case "$line" in
            onboot:*|startup:*|cores:*|memory:*|swap:*|features:*|protection:*|tags:*|description:*|nameserver:*|searchdomain:*|unprivileged:*|net[0-9]*:*)
                key="${line%%:*}"
                value="${line#*: }"
                [[ -n "$value" ]] && reapply_args+=("--${key}" "$value")
                ;;
        esac
    done < <(pct config "$vmid" 2>/dev/null || true)

    if ! _destroy_guest_only "$vmid" "lxc"; then
        log "ERROR: Failed to destroy CT $vmid before reclone"
        return 1
    fi

    if ! timeout 600 pct clone "$source_vmid" "$vmid" --hostname "$ct_name" 2>/dev/null; then
        log "ERROR: pct clone failed for CT $vmid from source $source_vmid"
        return 1
    fi

    if [[ ${#reapply_args[@]} -gt 0 ]]; then
        timeout 120 pct set "$vmid" "${reapply_args[@]}" 2>/dev/null || \
            log "WARNING: Failed to reapply one or more settings to CT $vmid"
    fi

    if ! timeout 60 pct start "$vmid" 2>/dev/null; then
        log "ERROR: pct start failed for CT $vmid"
        return 1
    fi

    log "Recloned LXC $vmid from source/template $source_vmid"
}

clone_vm_for_usb() {
    local vmid="$1" bus_path="$2" product_name="$3" image_num="${4:-1}" device_type="${5:-wireless}"
    local guest_ready=0
    local template_id="$IMAGE1_TEMPLATE_ID"
    [[ "$image_num" == "2" ]] && template_id="$IMAGE2_TEMPLATE_ID"

    local vm_name
    vm_name=$(get_vm_name "$vmid")
    local full_name="${vm_name}-${vmid}"

    # Helper: destroy this VM and free its slot so the next loop retries
    _teardown() {
        local reason="$1"
        rm -f "${PROV_DIR}/${vmid}" 2>/dev/null || true
        log "ERROR: VM $vmid provisioning failed — ${reason}. Tearing down and releasing USB $bus_path for retry."
        timeout 30 qm stop "$vmid" --skiplock 2>/dev/null || true
        _wait_vm_stopped "$vmid" 60 || true
        timeout 120 qm destroy "$vmid" --skiplock --purge --destroy-unreferenced-disks 2>/dev/null || true
        _wait_vmid_gone "$vmid" 60 || true
        unset "STATE_VMID_TO_BUS[$vmid]"
        unset "STATE_VMID_TO_IMAGE[$vmid]"
        unset "STATE_BUS_TO_VMID[$bus_path]"
        unset "STATE_MISSING_BY_BUS[$bus_path]"
        save_state_file
    }

    # Mark this VMID as actively provisioning so the UI can show "Spinning up"
    echo "$(date +%s)" > "${PROV_DIR}/${vmid}"

    # Clone
    if ! timeout 600 qm clone "$template_id" "$vmid" --name "$full_name" 2>/dev/null; then
        _teardown "qm clone failed (template $template_id missing or VMID $vmid conflict)"
        return 1
    fi

    timeout 30 qm set "$vmid" --onboot 1 --startup "order=2,up=60" 2>/dev/null || true
    timeout 30 qm set "$vmid" -usb0 "host=$bus_path" 2>/dev/null || true

    # L1 VLAN NIC: check if simulation.conf has l1=yes for this VM's bucket
    # Bucket is determined by (vmid % 100) // 10 (matches startup.sh site_based_num=2 logic)
    _check_l1_vlan() {
        local bucket_digit=$(( (vmid % 100) / 10 ))
        local sim_conf
        sim_conf=$(curl_api GET "/api/config" "" 2>/dev/null || true)
        [[ -z "$sim_conf" ]] && return
        local l1_val
        l1_val=$(python3 - "$sim_conf" "$bucket_digit" <<'PY' 2>/dev/null || true
import sys, configparser
text, bucket_idx = sys.argv[1], sys.argv[2]
p = configparser.ConfigParser()
p.read_string(text)
section = f"s{bucket_idx}"
print(p.get(section, "l1", fallback="no").strip().lower())
PY
)
        if [[ "$l1_val" == "yes" ]]; then
            local slot_index=$(( vmid - start_vmid ))
            local vlan_id=$(( L1_VLAN_START + slot_index ))
            if (( vlan_id >= L1_VLAN_START && vlan_id <= L1_VLAN_END )); then
                log "Attaching L1 VLAN NIC on vmbr254 tag=$vlan_id to VM $vmid"
                timeout 30 qm set "$vmid" --net1 "virtio,bridge=vmbr254,tag=${vlan_id}" 2>/dev/null || \
                    log "WARNING: Failed to set net1 VLAN for VM $vmid"
            else
                log "WARNING: Computed VLAN $vlan_id out of range [$L1_VLAN_START-$L1_VLAN_END] for VM $vmid — skipping L1 NIC"
            fi
        fi
    }
    _check_l1_vlan

    # Start
    if ! timeout 60 qm start "$vmid" 2>/dev/null; then
        _teardown "qm start failed"
        return 1
    fi

    # Wait for guest agent
    for _ in $(seq 1 60); do
        if qm guest ping "$vmid" >/dev/null 2>&1; then
            guest_ready=1
            break
        fi
        sleep 2
    done

    if [[ "$guest_ready" -eq 0 ]]; then
        log "WARNING: Guest agent not ready after 120s for VM $vmid — attempting hostname set anyway"
    fi

    # Set hostname — write /etc/hostname + suppress cloud-init from overriding it.
    # IMPORTANT: qm guest exec defaults to --timeout 0 (async/fire-and-forget).
    # We must pass --timeout explicitly so PVE waits for the commands to finish
    # before returning. Without this the reboot fires before the write completes.
    # Also avoid hostnamectl: it communicates via D-Bus which may not be ready
    # right after boot and can hang the entire bash script.
    local hostname_set=0
    for _ in $(seq 1 6); do
        if timeout 90 qm guest exec "$vmid" --timeout 60 -- bash -c "
            echo '${full_name}' > /etc/hostname
            sed -i 's/^127\.0\.1\.1.*/127.0.1.1\t${full_name}/' /etc/hosts 2>/dev/null || true
            mkdir -p /etc/cloud/cloud.cfg.d
            echo 'preserve_hostname: true' > /etc/cloud/cloud.cfg.d/99_preserve_hostname.cfg
            rm -f /var/lib/cloud/sem/config_set_hostname 2>/dev/null || true
        " >/dev/null 2>&1; then
            hostname_set=1
            break
        fi
        sleep 5
    done

    if [[ "$hostname_set" -eq 0 ]]; then
        _teardown "guest agent unreachable — hostname never set"
        return 1
    fi

    log "Set hostname to $full_name on VM $vmid"

    # Write USB device type for startup.sh (also synchronous)
    timeout 90 qm guest exec "$vmid" --timeout 60 -- bash -c "echo 'sim_phy=${device_type}' > /usr/local/scripts/usb-phy-override.conf" >/dev/null 2>&1 \
        && log "Wrote sim_phy=${device_type} to usb-phy-override.conf on VM $vmid" \
        || log "WARNING: Could not write usb-phy-override.conf on VM $vmid"

    timeout 30 qm guest exec "$vmid" --timeout 10 -- reboot >/dev/null 2>&1 || true
    rm -f "${PROV_DIR}/${vmid}" 2>/dev/null || true
    log "Provisioned VM $vmid ($full_name) for USB $bus_path (${product_name}) type=${device_type}"
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

    # Choose image based on current distribution vs target %
    local img1_count=0 img2_count=0 total_vms image_num=1
    for vmid in "${!STATE_VMID_TO_IMAGE[@]}"; do
        [[ "${STATE_VMID_TO_IMAGE[$vmid]}" == "2" ]] && ((img2_count++)) || ((img1_count++))
    done
    total_vms=$(( img1_count + img2_count + 1 ))
    local target_img1=$(( (IMAGE1_PCT * total_vms + 99) / 100 ))  # ceiling
    [[ "$img1_count" -ge "$target_img1" ]] && image_num=2

    local device_type="${CERTIFIED_TYPES[$vidpid]:-wireless}"
    clone_vm_for_usb "$free_vmid" "$bus_path" "$product_name" "$image_num" "$device_type"
    STATE_BUS_TO_VMID["$bus_path"]="$free_vmid"
    STATE_VMID_TO_BUS["$free_vmid"]="$bus_path"
    STATE_MISSING_BY_BUS["$bus_path"]=""
    STATE_VMID_TO_IMAGE["$free_vmid"]="$image_num"
    log "Provisioned VM $free_vmid for USB $bus_path ($vidpid) type=$device_type image=$image_num (${IMAGE1_PCT}% img1 target, ${img1_count}/${total_vms} currently img1)"
}

_expire_vm_pending_commands() {
    local vmid="$1"
    local _destroy_hostname
    _destroy_hostname=$(get_vm_name "$vmid" 2>/dev/null || true)
    if [[ -n "$_destroy_hostname" ]]; then
        curl_api DELETE "/api/commands/pending?target=${_destroy_hostname}-${vmid}" "" >/dev/null 2>&1 || true
        curl_api DELETE "/api/commands/pending?target=${_destroy_hostname}" "" >/dev/null 2>&1 || true
    fi
}

destroy_vm() {
    local vmid="$1" guest_type="${2:-}"
    local bus_path="${STATE_VMID_TO_BUS[$vmid]:-}"
    if [[ -z "$guest_type" ]]; then
        guest_type=$(get_guest_type "$vmid" 2>/dev/null || true)
    fi

    # Expire any pending client inbox commands for this VM's hostname BEFORE destroying.
    # Without this, stale commands (e.g. reboot) remain in the queue and are delivered
    # to the replacement VM when the same VMID slot is re-used, causing an immediate reboot.
    _expire_vm_pending_commands "$vmid"
    if ! _destroy_guest_only "$vmid" "$guest_type"; then
        log "ERROR: Failed to destroy VMID $vmid"
        return 1
    fi
    if [[ -n "$bus_path" ]]; then
        unset "STATE_MISSING_BY_BUS[$bus_path]"
        unset "STATE_BUS_TO_VMID[$bus_path]"
    fi
    unset "STATE_VMID_TO_BUS[$vmid]"
    unset "STATE_VMID_TO_IMAGE[$vmid]"
    save_state_file
    log "Destroyed ${guest_type^^} $vmid"
}

# Destroy VM via qm only — does NOT update in-memory state or write the state file.
# Used by parallel reclone jobs where state is managed by the parent process.
_destroy_vm_qm_only() {
    local vmid="$1"
    log "Stopping VM $vmid before destroy"
    # Use qm's own --timeout so Proxmox manages graceful→force shutdown internally.
    # timeout 30 + external kill was cutting the shutdown short, leaving the VM running
    # and causing qm destroy to fail silently.
    qm stop "$vmid" --skiplock --timeout 120 2>/dev/null || \
        qm stop "$vmid" --skiplock --timeout 0 2>/dev/null || true
    # Wait up to 150s (120s qm stop + 30s buffer) for the VM to reach stopped state
    _wait_vm_stopped "$vmid" 150 || true
    log "Destroying VM $vmid"
    timeout 300 qm destroy "$vmid" --skiplock --purge --destroy-unreferenced-disks 2>/dev/null || true
    _wait_vmid_gone "$vmid" 90 || true
    log "VM $vmid destroyed"
}

# Run one reclone in a background subshell. All needed values are passed as arguments
# because bash associative arrays are NOT inherited by background subshells.
# State file updates are handled by the parent after all jobs complete.
_reclone_parallel_job() {
    local vmid="$1" bus_path="$2" product_name="$3" saved_image="$4" device_type="$5"
    local _vm_name
    _vm_name=$(get_vm_name "$vmid")
    # Expire stale client inbox commands before destroying so the new VM doesn't inherit them
    curl_api DELETE "/api/commands/pending?target=${_vm_name}-${vmid}" "" >/dev/null 2>&1 || true
    write_reclone_state_cache "running" "[${vmid}]" "stopping"
    _destroy_vm_qm_only "$vmid"
    write_reclone_state_cache "running" "[${vmid}]" "cloning"
    if clone_vm_for_usb "$vmid" "$bus_path" "$product_name" "$saved_image" "$device_type"; then
        log "Parallel reclone done: VM $vmid bus=$bus_path type=$device_type image=$saved_image"
    else
        return 1
    fi
}

reclone_vm_instance() {
    local vmid="$1"
    local bus_path vidpid product_name

    refresh_usb_config
    load_state_file
    scan_usb_devices

    bus_path="${STATE_VMID_TO_BUS[$vmid]:-}"
    if [[ -z "$bus_path" ]]; then
        # Fallback: recover bus_path from qm config (handles VMs created outside the agent)
        local usb_line
        usb_line=$(qm config "$vmid" 2>/dev/null | grep -m1 '^usb[0-9]*: ')
        if [[ "$usb_line" =~ host=([^,[:space:]]+) ]]; then
            bus_path="${BASH_REMATCH[1]}"
            log "Recovered USB bus_path=$bus_path for VM $vmid from qm config"
            STATE_VMID_TO_BUS[$vmid]="$bus_path"
            STATE_BUS_TO_VMID[$bus_path]="$vmid"
            save_state_file
        else
            log "WARNING: No USB mapping found for VM $vmid (state file and qm config both empty)"
            return 1
        fi
    fi
    if [[ ! -d "/sys/bus/usb/devices/$bus_path" ]]; then
        log "WARNING: USB device $bus_path is not present; cannot reclone VM $vmid"
        return 1
    fi

    vidpid="${USB_VIDPID_BY_BUS[$bus_path]:-}"
    product_name="${USB_NAME_BY_BUS[$bus_path]:-$(find_label_for_vidpid "$vidpid")}"
    # sim_phy is always derived from the certified USB device table so the correct
    # wired/wireless type is applied regardless of what simulation.conf says globally.
    local device_type="${CERTIFIED_TYPES[$vidpid]:-wireless}"
    # Guard: if the assigned USB device type no longer matches sim_phy, skip reclone.
    # This prevents accidentally recloning a wired VM when sim_phy=wireless.
    if [[ "$device_type" != "$SIM_PHY" ]]; then
        log "WARNING: VM $vmid USB $bus_path ($vidpid) type=$device_type does not match sim_phy=$SIM_PHY — skipping reclone"
        return 1
    fi
    # Save image number BEFORE destroy_vm — destroy_vm unsets STATE_VMID_TO_IMAGE[$vmid].
    local saved_image="${STATE_VMID_TO_IMAGE[$vmid]:-1}"

    # Expire any pending client inbox commands for this VM's hostname BEFORE destroying
    # it. Without this, commands (e.g. reboot) that the old VM never ACK'd remain as
    # "pending" and will be delivered to the replacement VM with the same hostname,
    # causing it to reboot immediately after calling home.
    local _client_hostname
    _client_hostname="${vm_name}-${vmid}"
    curl_api DELETE "/api/commands/pending?target=${_client_hostname}" "" >/dev/null 2>&1 || true
    log "Expired pending client commands for ${_client_hostname} before reclone"

    destroy_vm "$vmid"
    clone_vm_for_usb "$vmid" "$bus_path" "$product_name" "$saved_image" "$device_type"
    STATE_BUS_TO_VMID["$bus_path"]="$vmid"
    STATE_VMID_TO_BUS["$vmid"]="$bus_path"
    STATE_MISSING_BY_BUS["$bus_path"]=""
    save_state_file
    log "Recloned VM $vmid for USB $bus_path ($vidpid) type=$device_type image=$saved_image"
}

usb_provision_loop() {
    local now bus_path vidpid product_name vmid missing_since
    local timeout_seconds missing_age _current_bus _state_vidpid _guest_type

    refresh_usb_config
    scan_usb_devices
    load_state_file

    # ── Stale state cleanup: remove entries for VMIDs that no longer exist ────
    # Prevents dongles from being "stuck" assigned to a manually-deleted VM.
    local -A _existing_vmids=()
    local -A _reconnected_vidpids=()
    while IFS= read -r _vid; do
        [[ -n "$_vid" ]] && _existing_vmids["$_vid"]="1"
    done < <({ qm list 2>/dev/null || true; pct list 2>/dev/null || true; } | awk '$1 ~ /^[0-9]+$/ { print $1 }')
    local _state_changed=0
    for vmid in "${!STATE_VMID_TO_BUS[@]}"; do
        if [[ -z "${_existing_vmids[$vmid]:-}" ]]; then
            local _stale_bus="${STATE_VMID_TO_BUS[$vmid]:-}"
            log "State cleanup: VM $vmid no longer exists — releasing bus ${_stale_bus:-unknown} for re-provision"
            [[ -n "$_stale_bus" ]] && {
                unset "STATE_BUS_TO_VMID[$_stale_bus]"
                unset "STATE_MISSING_BY_BUS[$_stale_bus]"
                unset "STATE_VIDPID_BY_BUS[$_stale_bus]"
            }
            unset "STATE_VMID_TO_BUS[$vmid]"
            unset "STATE_VMID_TO_IMAGE[$vmid]"
            _state_changed=1
        fi
    done

    now=$(date +%s)
    timeout_seconds=$(usb_missing_timeout_seconds)
    if reconcile_present_usb_state; then
        _state_changed=1
    fi
    for _current_bus in "${!STATE_BUS_TO_VMID[@]}"; do
        vmid="${STATE_BUS_TO_VMID[$_current_bus]}"
        missing_since="${STATE_MISSING_BY_BUS[$_current_bus]:-}"
        _state_vidpid="${USB_VIDPID_BY_BUS[$_current_bus]:-${STATE_VIDPID_BY_BUS[$_current_bus]:-}}"
        [[ -n "$_state_vidpid" ]] && STATE_VIDPID_BY_BUS["$_current_bus"]="$_state_vidpid"

        if [[ -n "${PRESENT_BUSES[$_current_bus]:-}" ]]; then
            continue
        fi

        if [[ -z "$missing_since" ]]; then
            STATE_MISSING_BY_BUS["$_current_bus"]="$now"
            _state_changed=1
            log "USB $_current_bus missing for VM $vmid; grace timer started"
        else
            missing_age=$(( now - missing_since ))
            if (( missing_age > timeout_seconds )); then
                _guest_type=$(get_guest_type "$vmid" 2>/dev/null || true)
                if guest_is_template "$vmid" "$_guest_type"; then
                    log "USB dongle missing for ${missing_age}s but VM $vmid is a template; skipping teardown"
                    continue
                fi
                log "USB dongle missing for ${missing_age}s — tearing down VM $vmid"
                [[ -n "$_state_vidpid" && -n "$(find_present_bus_for_vidpid "$_state_vidpid" 2>/dev/null || true)" ]] && _reconnected_vidpids["$_state_vidpid"]=1
                if destroy_vm "$vmid" "$_guest_type"; then
                    _state_changed=1
                fi
            fi
        fi
    done

    # ── Parallel provision: new USB dongles not yet assigned a VM ─────────────
    # Pre-assign VMIDs in the parent before forking so parallel subshells
    # cannot race and pick the same slot. Associative arrays (STATE_*, CERTIFIED_TYPES)
    # are NOT inherited by background subshells — capture all needed values here.
    local -a _prov_buses=() _prov_vmids=() _prov_products=() _prov_images=() _prov_types=()
    local _next_free_vmid="$start_vmid"
    local _img1_count=0 _img2_count=0

    for vmid in "${!STATE_VMID_TO_IMAGE[@]}"; do
        [[ "${STATE_VMID_TO_IMAGE[$vmid]}" == "2" ]] && ((_img2_count++)) || ((_img1_count++))
    done

    for bus_path in "${!PRESENT_BUSES[@]}"; do
        [[ -n "${STATE_BUS_TO_VMID[$bus_path]:-}" ]] && continue
        vidpid="${PRESENT_BUSES[$bus_path]}"
        local _dtype="${CERTIFIED_TYPES[$vidpid]:-wireless}"
        if [[ "$_dtype" != "$SIM_PHY" ]]; then
            log "Skipping USB $bus_path ($vidpid) — type=$_dtype, sim_phy=$SIM_PHY"
            continue
        fi
        while (( _next_free_vmid <= end_vmid )); do
            [[ -z "${STATE_VMID_TO_BUS[$_next_free_vmid]:-}" ]] && break
            ((_next_free_vmid++))
        done
        if (( _next_free_vmid > end_vmid )); then
            log "No free VM slots available — stopping provisioning"
            break
        fi
        local _free="$_next_free_vmid"
        ((_next_free_vmid++))

        product_name="${USB_NAME_BY_BUS[$bus_path]:-$(find_label_for_vidpid "$vidpid")}"

        local _total_vms=$(( _img1_count + _img2_count + 1 ))
        local _target_img1=$(( (IMAGE1_PCT * _total_vms + 99) / 100 ))
        local _img_num=1
        [[ "$_img1_count" -ge "$_target_img1" ]] && _img_num=2
        [[ "$_img_num" == "1" ]] && ((_img1_count++)) || ((_img2_count++))

        STATE_VMID_TO_BUS["$_free"]="$bus_path"
        STATE_BUS_TO_VMID["$bus_path"]="$_free"
        STATE_VMID_TO_IMAGE["$_free"]="$_img_num"

        _prov_buses+=("$bus_path")
        _prov_vmids+=("$_free")
        _prov_products+=("$product_name")
        _prov_images+=("$_img_num")
        _prov_types+=("$_dtype")

        if [[ -n "${_reconnected_vidpids[$vidpid]:-}" ]]; then
            log "USB dongle vidpid $vidpid reconnected — auto-provisioning new VM"
        fi
    done

    if [[ ${#_prov_buses[@]} -gt 0 ]]; then
        local _active_pids=() _all_pids=()
        for _i in "${!_prov_buses[@]}"; do
            while [[ ${#_active_pids[@]} -ge ${RECLONE_CONCURRENCY:-1} ]]; do
                local _live_pids=()
                for _p in "${_active_pids[@]}"; do
                    kill -0 "$_p" 2>/dev/null && _live_pids+=("$_p")
                done
                _active_pids=("${_live_pids[@]}")
                [[ ${#_active_pids[@]} -ge ${RECLONE_CONCURRENCY:-1} ]] && sleep 3
            done
            # Create sentinel in the PARENT right before forking — this means only
            # RECLONE_CONCURRENCY sentinels exist at once, so the UI shows exactly
            # as many "provisioning" VMs as are actively cloning (not the full queue).
            echo "$(date +%s)" > "${PROV_DIR}/${_prov_vmids[$_i]}"
            build_usb_state_json
            post_telemetry || true
            # Stagger clone starts to avoid all VMs hammering storage at the same time
            (( _i > 0 )) && sleep 15
            (
                if clone_vm_for_usb "${_prov_vmids[$_i]}" "${_prov_buses[$_i]}" \
                    "${_prov_products[$_i]}" "${_prov_images[$_i]}" "${_prov_types[$_i]}"; then
                    log "Provisioned VM ${_prov_vmids[$_i]} for USB ${_prov_buses[$_i]} type=${_prov_types[$_i]} image=${_prov_images[$_i]} (parallel)"
                else
                    exit 1
                fi
            ) &
            _pid=$!
            _active_pids+=("$_pid")
            _all_pids+=("$_pid")
        done
        for _i in "${!_all_pids[@]}"; do
            if ! wait "${_all_pids[$_i]}" 2>/dev/null; then
                log "WARNING: A parallel provision job failed for VM ${_prov_vmids[$_i]}"
                unset "STATE_VMID_TO_BUS[${_prov_vmids[$_i]}]"
                unset "STATE_VMID_TO_IMAGE[${_prov_vmids[$_i]}]"
                unset "STATE_BUS_TO_VMID[${_prov_buses[$_i]}]"
                unset "STATE_MISSING_BY_BUS[${_prov_buses[$_i]}]"
            fi
        done
        _state_changed=1
        save_state_file
        build_usb_state_json
        post_telemetry || true
    fi

    [[ "$_state_changed" -eq 1 ]] && save_state_file
    build_usb_state_json
}

refresh_usb_telemetry_only() {
    refresh_usb_config
    scan_usb_devices
    load_state_file
    if reconcile_present_usb_state; then
        save_state_file
    fi
    build_usb_state_json
}

collect_log_lines() {
    # Read new log lines since last send, return as JSON array of strings.
    # Uses tail -c +N for fast byte-offset seeking (avoids slow dd bs=1).
    [[ -f "$AGENT_LOG" ]] || { echo "[]"; return; }

    local offset=0 current_size new_content
    [[ -f "$AGENT_LOG_OFFSET_FILE" ]] && offset=$(<"$AGENT_LOG_OFFSET_FILE" 2>/dev/null || echo 0)
    current_size=$(wc -c < "$AGENT_LOG" 2>/dev/null || echo 0)

    # If log was rotated (shrunk), reset offset
    (( current_size < offset )) && offset=0

    if (( current_size <= offset )); then echo "[]"; return; fi

    # On first call (offset=0) only send last 100 lines to avoid flooding
    if (( offset == 0 )); then
        new_content=$(tail -n 100 "$AGENT_LOG" 2>/dev/null || true)
    else
        # tail -c +N starts at byte N (1-based)
        new_content=$(tail -c +$(( offset + 1 )) "$AGENT_LOG" 2>/dev/null || true)
    fi

    echo "$current_size" > "$AGENT_LOG_OFFSET_FILE"

    [[ -z "$new_content" ]] && { echo "[]"; return; }

    echo "$new_content" | python3 -c "
import sys, json
lines = [l.rstrip() for l in sys.stdin if l.strip()]
print(json.dumps(lines[-200:]))
" 2>/dev/null || echo "[]"
}


# Find the vhclient binary in common install locations.
_find_vhclient() {
    local found
    while IFS= read -r found; do
        [[ -x "$found" ]] && echo "$found" && return 0
    done < <(find /root/.local /opt /home -maxdepth 6 -name 'vhclient*' -type f 2>/dev/null)
    local c
    for c in /usr/sbin/vhclient /usr/bin/vhclient /usr/local/bin/vhclient; do
        [[ -x "$c" ]] && echo "$c" && return 0
    done
    return 1
}

collect_vh_devices() {
    local vhbin
    vhbin=$(_find_vhclient 2>/dev/null) || vhbin=""

    python3 - "$vhbin" <<'PY'
import subprocess, re, json, sys

vhbin = sys.argv[1] if len(sys.argv) > 1 else ""

def run(cmd, timeout=5):
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return r.stdout, r.returncode == 0
    except Exception:
        return "", False

vh_out, vh_ok = ("", False)
svc_active = False

if vhbin:
    vh_out, vh_ok = run([vhbin, "-t", "list"])
    svc_r = subprocess.run(
        ["systemctl", "is-active", "virtualhereclient"],
        capture_output=True, text=True
    )
    svc_active = svc_r.stdout.strip() == "active"

devices = []
current_server = None
auto_use_all = "Auto-Use All currently on" in vh_out

for line in vh_out.splitlines():
    srv_m = re.match(r'^\s*(.+?)\s+\((\S+:\d+)\)\s*$', line)
    if srv_m and '-->' not in line:
        current_server = srv_m.group(2)
        continue
    dev_m = re.match(r'^(\*?)\s*-->\s+(.+?)\s+\((\S+)\)\s*$', line)
    if dev_m:
        auto_use = bool(dev_m.group(1)) or auto_use_all
        devices.append({
            "name":     dev_m.group(2).strip(),
            "address":  dev_m.group(3).strip(),
            "server":   current_server,
            "auto_use": auto_use,
        })

lsusb_out, _ = run(["lsusb"])
phys = []
for m in re.finditer(r'ID ([0-9a-fA-F]{4}):([0-9a-fA-F]{4})\s+(.*)', lsusb_out):
    phys.append({
        "vidpid": f"{m.group(1).lower()}:{m.group(2).lower()}",
        "name":   m.group(3).strip(),
        "source": "physical",
    })

print(json.dumps({
    "vh_service_active": svc_active,
    "vh_connected":      vh_ok and bool(devices),
    "auto_use_all":      auto_use_all,
    "count":             len(devices),
    "devices":           devices,
    "physical_usb":      phys,
}))
PY
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
            $1,$2,$5,$4
        }' | sed 's/,$//' | awk 'BEGIN{print "["}{print}END{print "]"}' | tr -d '\n')
    fi

    local pve_version=""
    if command -v pveversion &>/dev/null; then
        pve_version=$(pveversion 2>/dev/null | awk -F'/' 'NR==1{print $2}' || true)
    fi

    vms_json="[]"
    if command -v pvesh &>/dev/null; then
        # pvesh returns: cpu (0.0-1.0 fraction), mem (bytes), maxmem (bytes)
        # Normalise: cpu → percent, mem/maxmem → MB. Merge QEMU VMs + LXC containers.
        vms_json=$(python3 -c "
import json, subprocess, sys, re
from pathlib import Path

META_RE = re.compile(r'(?:reclone[-_ ](?:source|template)|template[-_ ]source)\\s*[:=]\\s*(\\d+)', re.I)


def fetch(path):
    try:
        r = subprocess.run(['pvesh','get',path,'--output-format','json'],
                           capture_output=True, text=True, timeout=15)
        return json.loads(r.stdout) if r.returncode == 0 else []
    except Exception:
        return []


def config_text(kind, vmid):
    cfg_path = Path('/etc/pve/qemu-server' if kind == 'qemu' else '/etc/pve/lxc') / f'{vmid}.conf'
    try:
        return cfg_path.read_text(encoding='utf-8')
    except Exception:
        return ''


def reclone_info(kind, vmid):
    text = config_text(kind, vmid)
    source_vmid = None
    for line in text.splitlines():
        if ':' not in line:
            continue
        key, value = line.split(':', 1)
        if key.strip() in {'description', 'tags', 'notes', 'comment'}:
            m = META_RE.search(value)
            if m:
                source_vmid = int(m.group(1))
                break
    if kind == 'qemu':
        m = re.search(r'^usb\\d+:\\s.*?host=([^,\\s]+)', text, re.M)
        bus_path = m.group(1) if m else None
        # has_usb_config: True if any USB passthrough line exists (host= or mapping= or any format)
        has_usb_config = bool(re.search(r'^usb\\d+:', text, re.M))
        supported = bool(bus_path) or (source_vmid is not None)
        reason = None if supported else 'No USB passthrough mapping or reclone-source metadata found'
        is_template = bool(re.search(r'^template:\\s*1\\s*$', text, re.M))
        return bus_path, has_usb_config, source_vmid, supported, reason, is_template
    supported = source_vmid is not None
    reason = None if supported else 'Set tags/description with reclone-source=<template CTID>'
    is_template = bool(re.search(r'^template:\\s*1\\s*$', text, re.M))
    return None, False, source_vmid, supported, reason, is_template


node = subprocess.run(['hostname', '-s'], capture_output=True, text=True).stdout.strip()
qemu = fetch(f'/nodes/{node}/qemu')
lxc  = fetch(f'/nodes/{node}/lxc')

out = []
for v in qemu:
    vmid = v.get('vmid')
    bus_path, has_usb_config, source_vmid, supported, reason, is_template = reclone_info('qemu', vmid)
    out.append({
        'vmid':                vmid,
        'name':                v.get('name', ''),
        'status':              v.get('status', 'unknown'),
        'cpu':                 round(float(v.get('cpu') or 0) * 100, 1),
        'mem':                 round(int(v.get('mem') or 0) / 1024 / 1024),
        'maxmem':              round(int(v.get('maxmem') or 0) / 1024 / 1024),
        'is_template':         bool(v.get('template', 0)) or is_template,
        'type':                'qemu',
        'has_usb_config':      has_usb_config,
        'reclone_bus_path':    bus_path,
        'reclone_source_vmid': source_vmid,
        'reclone_supported':   supported,
        'reclone_reason':      reason,
    })
for v in lxc:
    vmid = v.get('vmid')
    _bus_path, _has_usb, source_vmid, supported, reason, is_template = reclone_info('lxc', vmid)
    out.append({
        'vmid':                vmid,
        'name':                v.get('name', ''),
        'status':              v.get('status', 'unknown'),
        'cpu':                 round(float(v.get('cpu') or 0) * 100, 1),
        'mem':                 round(int(v.get('mem') or 0) / 1024 / 1024),
        'maxmem':              round(int(v.get('maxmem') or 0) / 1024 / 1024),
        'is_template':         is_template,
        'type':                'lxc',
        'reclone_source_vmid': source_vmid,
        'reclone_supported':   supported,
        'reclone_reason':      reason,
    })
print(json.dumps(out))
" 2>/dev/null || echo "[]")
    fi

    # Fallback: qm list + pct list (no real-time CPU/mem usage; maxmem from qm list col 4)
    # qm list columns: VMID  NAME  STATUS  MEM(MB)  BOOTDISK(GB)  PID
    if [[ "$vms_json" == "[]" ]] && command -v qm &>/dev/null; then
        local tmpl_ids=""
        for conf in /etc/pve/qemu-server/*.conf; do
            [[ -f "$conf" ]] || continue
            grep -q "^template: 1" "$conf" && tmpl_ids+="$(basename "$conf" .conf),"
        done
        tmpl_ids="${tmpl_ids%,}"
        local qemu_part lxc_part
        qemu_part=$(qm list 2>/dev/null | awk -v tmpls="$tmpl_ids" 'BEGIN {
            n=split(tmpls, t, ","); for(i=1;i<=n;i++) tmpl_set[t[i]]=1
        }
        NR>1 {
            is_tmpl = ($1 in tmpl_set) ? "true" : "false"
            printf "{\"vmid\":%s,\"name\":\"%s\",\"status\":\"%s\",\"cpu\":null,\"mem\":0,\"maxmem\":%s,\"is_template\":%s,\"type\":\"qemu\"},",
            $1,$2,$3,$4,is_tmpl
        }')
        lxc_part=$(pct list 2>/dev/null | awk 'NR>1 {
            printf "{\"vmid\":%s,\"name\":\"%s\",\"status\":\"%s\",\"cpu\":null,\"mem\":0,\"maxmem\":0,\"is_template\":false,\"type\":\"lxc\"},",
            $1,$3,$2
        }')
        local combined="${qemu_part}${lxc_part}"
        combined="${combined%,}"
        vms_json="[${combined}]"
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
  "agent_version": "${AGENT_VERSION}",
  "pve_version": "${pve_version}",
  "missing_timeout_mins": ${MISSING_TIMEOUT},
  "vms": ${vms_json:-[]},
  "reclone_state": $(cat "$RECLONE_STATE_CACHE" 2>/dev/null || echo '{"status":"idle","active_vmids":[]}'),
  "unknown_usb": $(cat "$USB_UNKNOWN_CACHE" 2>/dev/null || echo "${UNKNOWN_USB_JSON:-[]}"),
  "usb_state": $(cat "$USB_STATE_CACHE"   2>/dev/null || echo "${USB_STATE_JSON:-[]}"),
  "present_usb": $(cat "$USB_PRESENT_CACHE" 2>/dev/null || echo "${PRESENT_USB_JSON:-[]}"),
  "vh_devices": $(collect_vh_devices 2>/dev/null || echo '{"vh_connected":false,"vh_service_active":false,"count":0,"devices":[]}'),
  "log_lines": $(collect_log_lines)
}
JSON
}

# ── Self-update ────────────────────────────────────────────────────────────────
# Downloads the latest agent script from GitHub, validates it, and replaces the
# running binary if the SHA256 hash differs. Called both from the inbox handler
# (update_agent command) and from the main loop's periodic self-check.
self_update_agent() {
    local requested_branch="${1:-}"
    local requested_repo_raw="${2:-}"
    local agent_script="/usr/local/bin/client-sim-proxmox-agent"
    local configured_branch branch repo_raw download_dir tmp_file
    configured_branch=$(grep -oP '(?<=CLIENT_SIM_REPO_BRANCH=).*' "$ENV_FILE" 2>/dev/null | tr -d '[:space:]')
    branch="${requested_branch:-$configured_branch}"
    branch="${branch:-lrb}"
    repo_raw="${requested_repo_raw:-https://raw.githubusercontent.com/solutions-hpe/client-sim/${branch}}"
    download_dir="/var/lib/client-sim/update"
    tmp_file="${download_dir}/proxmox-agent.sh.download"
    mkdir -p "$download_dir"
    log "Checking for agent update from GitHub (branch: ${branch}, current: v${AGENT_VERSION})..."
    if ! curl -sSf --max-time 30 "${repo_raw}/proxmox/proxmox-agent.sh" -o "$tmp_file"; then
        rm -f "$tmp_file"
        log "ERROR: Failed to download agent update from ${repo_raw}"
        return 1
    fi
    if ! bash -n "$tmp_file" 2>/dev/null; then
        rm -f "$tmp_file"
        log "ERROR: Downloaded agent script failed syntax check — aborting update"
        return 1
    fi
    local current_hash new_hash new_version
    current_hash=$(sha256sum "$agent_script" 2>/dev/null | awk '{print $1}')
    new_hash=$(sha256sum "$tmp_file" | awk '{print $1}')
    new_version=$(grep '^AGENT_VERSION=' "$tmp_file" | cut -d'"' -f2)
    if [[ "$current_hash" == "$new_hash" ]]; then
        rm -f "$tmp_file"
        if [[ -n "$requested_branch" && "$requested_branch" != "$configured_branch" ]]; then
            save_repo_branch "$branch"
        fi
        log "Agent is already up to date (v${AGENT_VERSION})"
        return 0
    fi
    install -m 0755 "$tmp_file" "$agent_script"
    rm -f "$tmp_file"
    save_repo_branch "$branch"
    log "Agent updated v${AGENT_VERSION} → v${new_version} from ${repo_raw} — scheduling restart..."
    if ! schedule_agent_restart; then
        log "ERROR: Failed to schedule agent restart"
        return 1
    fi
}

execute_vm_command() {
    local action="$1" vmid="${2:-}" _type="${3:-qemu}" _source_vmid="${4:-}" _branch="${5:-}" _repo_raw="${6:-}"
    local guest_type="${_type:-qemu}"
    if [[ -n "$vmid" && "$guest_type" != "lxc" ]]; then
        if pct status "$vmid" >/dev/null 2>&1 && ! qm status "$vmid" >/dev/null 2>&1; then
            guest_type="lxc"
        fi
    fi
    action=$(normalize_command_name "$action")
    case "$action" in
        start_vm)
            if [[ "$guest_type" == "lxc" ]]; then timeout 60 pct start "$vmid"; else timeout 60 qm start "$vmid"; fi
            ;;
        stop_vm)
            if [[ "$guest_type" == "lxc" ]]; then timeout 60 pct stop "$vmid"; else timeout 60 qm stop "$vmid"; fi
            ;;
        reboot_vm)
            if [[ "$guest_type" == "lxc" ]]; then pct reboot "$vmid" 2>/dev/null || true; else qm reboot "$vmid" 2>/dev/null || true; fi
            ;;
        snapshot_vm)
            if [[ "$guest_type" == "lxc" ]]; then
                pct snapshot "$vmid" "auto-$(date +%Y%m%d%H%M)" --description "client-sim"
            else
                qm snapshot "$vmid" "auto-$(date +%Y%m%d%H%M)" --description "client-sim"
            fi
            ;;
        reclone_vm)
            if [[ "$guest_type" == "lxc" ]]; then
                clone_lxc_instance "$vmid" "$_source_vmid"
            else
                reclone_vm_instance "$vmid"
            fi
            ;;
        delete_vm|delete-vm)
            if [[ "$guest_type" == "lxc" ]]; then
                destroy_lxc "$vmid"
            else
                load_state_file
                destroy_vm "$vmid"
            fi
            ;;
        reclone_vms)  [[ -f /opt/client-sim-repo/proxmox/clone.sh ]] && bash /opt/client-sim-repo/proxmox/clone.sh ;;
        provision_unassigned)
            log "provision_unassigned: running USB provision loop to assign dongles without VMs"
            usb_provision_loop || log "WARNING: provision_unassigned loop failed"
            ;;
        snapshot_vms)
            for vid in $(qm list | awk 'NR>1{print $1}'); do
                qm snapshot "$vid" "auto-$(date +%Y%m%d%H%M)" --description "client-sim" || true
            done
            ;;
        start_vms)  for vid in $(qm list | awk 'NR>1{print $1}'); do timeout 60 qm start "$vid" || true; done ;;
        stop_vms)   for vid in $(qm list | awk 'NR>1{print $1}'); do timeout 60 qm stop  "$vid" || true; done ;;
        update_agent|update-agent)
            self_update_agent "$_branch" "$_repo_raw"
            ;;
        *)          return 1 ;;
    esac
}

mkdir -p /var/lib/client-sim
write_reclone_state_cache idle "[]"
log "Proxmox agent starting. Server: $SERVER_URL"
_LAST_SELF_UPDATE=0
log "Host block $host_id → VM range $start_vmid-$end_vmid"
if [[ -z "$API_KEY" ]]; then
    register_and_wait_for_key
fi
ensure_state_file
refresh_usb_telemetry_only || true

# Helper: collect and POST telemetry immediately
post_telemetry() {
    local telem response status body
    telem=$(collect_telemetry 2>/dev/null) || return 0
    response=$(curl_api_status POST /api/proxmox/telemetry "$telem" 2>/dev/null || true)
    status="${response##*$'\n'}"
    body="${response%$'\n'*}"
    case "$status" in
        200) return 0 ;;
        202|401|403)
            handle_auth_failure "$status" "/api/proxmox/telemetry"
            return 0
            ;;
        "") return 0 ;;
        *)
            log "WARNING: telemetry POST returned HTTP ${status} ${body:+body=${body:0:160}}"
            return 0
            ;;
    esac
}

# Background real-time telemetry sender (every TELEMETRY_INTERVAL seconds)
# Runs as a subprocess — reads node/VM stats fresh and USB state from cache files
(
    while true; do
        sleep "$TELEMETRY_INTERVAL"
        post_telemetry || true
    done
) &
TELEMETRY_PID=$!
log "Background telemetry sender started (PID $TELEMETRY_PID, interval ${TELEMETRY_INTERVAL}s)"

post_telemetry || true

# ── Inbox command processor ────────────────────────────────────────────────────
# Runs in its own background loop every INBOX_INTERVAL seconds, fully decoupled
# from the main USB provisioning loop. Reclone wait+ACK is itself backgrounded
# so process_inbox always returns immediately — never blocked by clone operations.
process_inbox() {
    local response_with_status response status poll_hostname
    local -a args
    poll_hostname=$(hostname 2>/dev/null || printf '%s' "$h")
    args=(-sS --max-time 15 -G "${SERVER_URL}/api/inbox" --data-urlencode "hostname=${poll_hostname}" -w $'\n%{http_code}')
    [[ -n "$API_KEY" ]] && args+=(-H "X-API-Key: $API_KEY")
    response_with_status=$(curl "${args[@]}" 2>/dev/null || true)
    status="${response_with_status##*$'\n'}"
    response="${response_with_status%$'\n'*}"
    case "$status" in
        200) ;;
        202|401|403)
            handle_auth_failure "$status" "/api/inbox"
            return 0
            ;;
        "") return 0 ;;
        *)
            log "WARNING: inbox poll returned HTTP ${status}"
            return 0
            ;;
    esac
    [[ -z "$response" || "$response" == "[]" ]] && return 0

    log "Commands received: $response"
    local parsed_commands
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
    action = str(cmd.get('action', '')).replace('\t', ' ').replace('-', '_')
    vmid = cmd.get('args', {}).get('vmid', '')
    guest_type = str(cmd.get('args', {}).get('type') or cmd.get('args', {}).get('vm_type') or '').replace('\t', ' ')
    source_vmid = cmd.get('args', {}).get('source_vmid', '')
    branch = str(cmd.get('args', {}).get('branch') or '').replace('\t', ' ')
    repo_raw = str(cmd.get('args', {}).get('repo_raw') or '').replace('\t', ' ')
    ctype = str(cmd.get('type') or '').replace('\t', ' ').replace('-', '_')
    print(f"{cid}\t{action}\t{vmid}\t{guest_type}\t{source_vmid}\t{branch}\t{repo_raw}\t{ctype}")
PY
)
    local _seq_ids=() _seq_actions=() _seq_vmids=() _seq_types=() _seq_sources=() _seq_branches=() _seq_repo_raws=()
    local _rc_ids=() _rc_vmids=() _rc_types=() _rc_sources=()
    local _del_ids=() _del_vmids=()
    while IFS=$'\t' read -r cmd_id action vmid guest_type source_vmid branch repo_raw cmd_type; do
        [[ -z "$cmd_id" || -z "$action" ]] && continue
        if [[ "$action" == "reclone_vm" && -n "$vmid" ]]; then
            _rc_ids+=("$cmd_id")
            _rc_vmids+=("$vmid")
            _rc_types+=("${guest_type:-qemu}")
            _rc_sources+=("$source_vmid")
        elif [[ "$action" == "delete_vm" && -n "$vmid" ]]; then
            _del_ids+=("$cmd_id")
            _del_vmids+=("$vmid")
        else
            _seq_ids+=("$cmd_id")
            _seq_actions+=("$action")
            _seq_vmids+=("$vmid")
            _seq_types+=("${guest_type:-$cmd_type}")
            _seq_sources+=("$source_vmid")
            _seq_branches+=("$branch")
            _seq_repo_raws+=("$repo_raw")
        fi
    done <<< "$parsed_commands"

    for _si in "${!_seq_ids[@]}"; do
        log "Executing ${_seq_actions[$_si]} (vmid=${_seq_vmids[$_si]:-})"
        local status="completed" message=""
        if execute_vm_command "${_seq_actions[$_si]}" "${_seq_vmids[$_si]}" "${_seq_types[$_si]}" "${_seq_sources[$_si]}" "${_seq_branches[$_si]}" "${_seq_repo_raws[$_si]}" 2>>"$AGENT_LOG"; then
            message="${_seq_actions[$_si]} completed"
        else
            status="failed"
            message="${_seq_actions[$_si]} failed — check $AGENT_LOG"
        fi
        ack_inbox_command "${_seq_ids[$_si]}" "$status" "$message" || true
        post_telemetry
    done

    if [[ ${#_rc_vmids[@]} -gt 0 ]]; then
        load_state_file
        local _rc_active_pids=() _rc_pids=() _rc_batch_ids=() _rc_batch_vmids=() _rc_batch_buses=()
        local _conc="${RECLONE_CONCURRENCY:-1}"

        for _ri in "${!_rc_vmids[@]}"; do
            local _vmid="${_rc_vmids[$_ri]}" _cmd_id="${_rc_ids[$_ri]}" _guest_type="${_rc_types[$_ri]:-qemu}" _source_vmid="${_rc_sources[$_ri]:-}" _bus=""
            if [[ "$_guest_type" == "lxc" ]]; then
                if [[ -z "$_source_vmid" ]]; then
                    log "WARNING: No LXC template/source configured for CT $_vmid"
                    ack_inbox_command "$_cmd_id" "failed" "No LXC template/source configured for CT $_vmid" || true
                    continue
                fi
            else
                local _bus="${STATE_VMID_TO_BUS[$_vmid]:-}"
                if [[ -z "$_bus" ]]; then
                    local _usb_line
                    _usb_line=$(qm config "$_vmid" 2>/dev/null | grep -m1 '^usb[0-9]*: ' || true)
                    if [[ "$_usb_line" =~ host=([^,[:space:]]+) ]]; then
                        _bus="${BASH_REMATCH[1]}"
                        log "Recovered USB bus_path=$_bus for VM $_vmid from qm config"
                        STATE_VMID_TO_BUS["$_vmid"]="$_bus"
                        STATE_BUS_TO_VMID["$_bus"]="$_vmid"
                    fi
                fi
                local _vidpid="${USB_VIDPID_BY_BUS[$_bus]:-}"
                local _product="${USB_NAME_BY_BUS[$_bus]:-$(find_label_for_vidpid "$_vidpid")}"
                local _image="${STATE_VMID_TO_IMAGE[$_vmid]:-1}"
                local _dtype="${CERTIFIED_TYPES[$_vidpid]:-wireless}"

                if [[ -z "$_bus" || ! -d "/sys/bus/usb/devices/$_bus" ]]; then
                    log "WARNING: USB device ${_bus:-<unknown>} is not present; cannot reclone VM $_vmid"
                    ack_inbox_command "$_cmd_id" "failed" "USB device not present for VM $_vmid" || true
                    continue
                fi
                if [[ "$_dtype" != "$SIM_PHY" ]]; then
                    log "WARNING: VM $_vmid type=$_dtype != sim_phy=$SIM_PHY — skipping reclone"
                    ack_inbox_command "$_cmd_id" "failed" "sim_phy mismatch: device is $_dtype but sim_phy=$SIM_PHY" || true
                    continue
                fi
            fi

            while [[ ${#_rc_active_pids[@]} -ge $_conc ]]; do
                local _live=()
                for _p in "${_rc_active_pids[@]}"; do
                    kill -0 "$_p" 2>/dev/null && _live+=("$_p")
                done
                _rc_active_pids=("${_live[@]}")
                [[ ${#_rc_active_pids[@]} -ge $_conc ]] && sleep 5
            done

            _RECLONE_CMD_IDS["$_vmid"]="$_cmd_id"
            local _rj=$(( RANDOM % 31 ))
            if [[ "$_guest_type" == "lxc" ]]; then
                log "Parallel reclone starting: CT $_vmid (source=$_source_vmid, jitter=${_rj}s)"
                (
                    [[ $_rj -gt 0 ]] && sleep "$_rj"
                    clone_lxc_instance "$_vmid" "$_source_vmid"
                ) &
            else
                log "Parallel reclone starting: VM $_vmid (bus=$_bus type=$_dtype image=$_image, jitter=${_rj}s)"
                (
                    [[ $_rj -gt 0 ]] && sleep "$_rj"
                    _reclone_parallel_job "$_vmid" "$_bus" "$_product" "$_image" "$_dtype"
                ) &
            fi
            local _pid=$!
            _rc_active_pids+=("$_pid")
            _rc_pids+=("$_pid")
            _rc_batch_ids+=("$_cmd_id")
            _rc_batch_vmids+=("$_vmid")
            _rc_batch_buses+=("$_bus")
        done

        # Wait for reclone jobs and ACK results in a background subshell so
        # process_inbox returns immediately — never blocked by multi-minute clones.
        local _rc_vmids_json="[]"
        if [[ ${#_rc_batch_vmids[@]} -gt 0 ]]; then
            _rc_vmids_json="[$(IFS=,; echo "${_rc_batch_vmids[*]}")]"
            write_reclone_state_cache running "$_rc_vmids_json"
        fi
        local _snap_pids=("${_rc_pids[@]}")
        local _snap_ids=("${_rc_batch_ids[@]}")
        local _snap_vmids=("${_rc_batch_vmids[@]}")
        local _snap_buses=("${_rc_batch_buses[@]}")
        (
            for _rpi in "${!_snap_pids[@]}"; do
                local _rc_status="completed" _rc_msg="reclone_vm completed"
                if ! wait "${_snap_pids[$_rpi]}" 2>/dev/null; then
                    _rc_status="failed"
                    _rc_msg="reclone_vm failed — check $AGENT_LOG"
                fi
                ack_inbox_command "${_snap_ids[$_rpi]}" "$_rc_status" "$_rc_msg" || true
                log "ACK reclone: ${_snap_ids[$_rpi]} status=$_rc_status vmid=${_snap_vmids[$_rpi]}"
            done
            # Reload state, clear missing flags for completed reclones, persist
            load_state_file
            for _vmid in "${_snap_vmids[@]}"; do
                local _b="${STATE_VMID_TO_BUS[$_vmid]:-}"
                [[ -n "$_b" ]] && STATE_MISSING_BY_BUS["$_b"]=""
            done
            save_state_file
            write_reclone_state_cache idle "[]"
        ) &
    fi

    # Parallel delete_vm: stop+destroy all selected guests concurrently, then update state once.
    if [[ ${#_del_vmids[@]} -gt 0 ]]; then
        load_state_file
        local _del_pids=() _del_results=()
        for _di in "${!_del_vmids[@]}"; do
            local _dvmid="${_del_vmids[$_di]}"
            _expire_vm_pending_commands "$_dvmid"
            (
                _destroy_guest_only "$_dvmid"
            ) &
            _del_pids+=($!)
        done
        for _di in "${!_del_pids[@]}"; do
            if wait "${_del_pids[$_di]}" 2>/dev/null; then
                _del_results[$_di]="completed"
                log "Parallel delete done: VMID ${_del_vmids[$_di]}"
            else
                _del_results[$_di]="failed"
                log "Parallel delete failed: VMID ${_del_vmids[$_di]}"
            fi
        done
        load_state_file
        for _di in "${!_del_vmids[@]}"; do
            [[ "${_del_results[$_di]:-failed}" == "completed" ]] || continue
            local _dvmid="${_del_vmids[$_di]}"
            local _dbus="${STATE_VMID_TO_BUS[$_dvmid]:-}"
            if [[ -n "$_dbus" ]]; then
                unset "STATE_MISSING_BY_BUS[$_dbus]"
                unset "STATE_BUS_TO_VMID[$_dbus]"
                unset "STATE_VIDPID_BY_BUS[$_dbus]"
            fi
            unset "STATE_VMID_TO_BUS[$_dvmid]"
            unset "STATE_VMID_TO_IMAGE[$_dvmid]"
        done
        save_state_file
        build_usb_state_json  # rebuild cache so post_telemetry doesn't report stale VMs
        for _di in "${!_del_vmids[@]}"; do
            local _status="${_del_results[$_di]:-failed}"
            local _message="delete_vm completed"
            if [[ "$_status" != "completed" ]]; then
                _message="delete_vm failed — check $AGENT_LOG"
            fi
            ack_inbox_command "${_del_ids[$_di]}" "$_status" "$_message" || true
            log "ACK delete: ${_del_ids[$_di]} vmid=${_del_vmids[$_di]} status=$_status"
        done
        post_telemetry
    fi
}

# Launch inbox as an independent background loop
(
    while true; do
        process_inbox || true
        sleep "$INBOX_INTERVAL"
    done
) &
INBOX_PID=$!
log "Background inbox poller started (PID $INBOX_PID, interval ${INBOX_INTERVAL}s)"

while true; do
    refresh_usb_config || true
    if [[ "$AUTO_PROVISION" == "on" ]]; then
        usb_provision_loop || log "WARNING: USB auto-provisioning loop failed"
    else
        refresh_usb_telemetry_only || true
    fi

    # Post telemetry after USB scan (has fresh USB state in this process)
    post_telemetry

    # Periodic self-update: check GitHub every SELF_UPDATE_INTERVAL seconds.
    # This ensures the agent updates even if the WebUI never sends update_agent.
    _now=$(date +%s)
    if (( _now - _LAST_SELF_UPDATE >= SELF_UPDATE_INTERVAL )); then
        _LAST_SELF_UPDATE=$_now
        self_update_agent || true
    fi

    sleep "$POLL_INTERVAL"
done
