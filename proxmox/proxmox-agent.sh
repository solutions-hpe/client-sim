#!/bin/bash
# proxmox-agent.sh — Client-Sim Proxmox Host Agent
# Collects VM + node telemetry, polls for commands, and auto-provisions USB-backed VMs.
# Runs as a systemd service on the Proxmox HOST (not in the LXC container).

set -euo pipefail

AGENT_VERSION="1.72"
AGENT_LOG="/var/log/client-sim-proxmox-agent.log"
AGENT_LOG_OFFSET_FILE="/var/lib/client-sim/agent-log-offset"
PIDFILE="/var/run/client-sim-proxmox-agent.pid"
SERVER_URL="${CLIENT_SIM_SERVER_URL:-}"
API_KEY="${CLIENT_SIM_API_KEY:-}"
POLL_INTERVAL="${CLIENT_SIM_POLL_INTERVAL:-60}"
TELEMETRY_INTERVAL="${CLIENT_SIM_TELEMETRY_INTERVAL:-10}"
STATE_FILE="/etc/client-sim-usb-state.conf"
ENV_FILE="/etc/client-sim-proxmox-agent.env"
USB_STATE_CACHE="/tmp/client-sim-usb-state.cache"
USB_PRESENT_CACHE="/tmp/client-sim-usb-present.cache"
USB_UNKNOWN_CACHE="/tmp/client-sim-usb-unknown.cache"

# Prevent duplicate instances
if [[ -f "$PIDFILE" ]] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Another instance already running (PID $(cat "$PIDFILE")), exiting."
    exit 1
fi
echo $$ > "$PIDFILE"
trap 'rm -f "$PIDFILE"; [[ -n "${TELEMETRY_PID:-}" ]] && kill "$TELEMETRY_PID" 2>/dev/null; true' EXIT

AUTO_PROVISION="off"
MISSING_TIMEOUT=60
IMAGE1_TEMPLATE_ID=100
IMAGE2_TEMPLATE_ID=200
IMAGE1_PCT=50
RECLONE_CONCURRENCY=1
UNKNOWN_USB_JSON="[]"
USB_STATE_JSON="[]"
PRESENT_USB_JSON="[]"

h=$(hostname)
last3="${h: -3}"
[[ "$last3" =~ ^[0-9]{3}$ ]] && host_id="$last3" || host_id="001"
id_num=$((10#$host_id))
start_vmid=$((90000 + (id_num - 1) * 24 + 1))
end_vmid=$((start_vmid + 23))

declare -A CERTIFIED_TYPES CERTIFIED_LABELS IGNORED_VIDPIDS
declare -A USB_NAME_BY_BUS USB_VIDPID_BY_BUS PRESENT_BUSES
declare -A STATE_VMID_TO_IMAGE
declare -A STATE_BUS_TO_VMID STATE_VMID_TO_BUS STATE_MISSING_BY_BUS STATE_VIDPID_BY_BUS
declare -A _RECLONE_CMD_IDS=()   # vmid -> cmd_id, used for parallel reclone ACKs

declare -a UNKNOWN_USB_LINES USB_STATE_LINES

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

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

print("CFG\t{}\t{}\t{}\t{}\t{}\t{}\t{}".format(
    str(data.get("auto_provision", "off")).lower(),
    int(data.get("missing_timeout", 60) or 60),
    int(data.get("image1_template_id", data.get("template_id", 100)) or 100),
    int(data.get("image2_template_id", 200) or 200),
    max(0, min(100, int(data.get("image1_pct", 50) or 50))),
    str(data.get("sim_phy", "wireless")).strip().lower() or "wireless",
    max(1, int(data.get("reclone_concurrency", 1) or 1)),
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

    while IFS=$'\t' read -r kind a b c d e f g; do
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
    local vmid bus_path missing_since image_num vidpid
    while IFS=$'\t' read -r vmid bus_path missing_since image_num vidpid; do
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

    if ! qm_vmids=$(qm list 2>/dev/null | awk 'NR>1 && $1 ~ /^[0-9]+$/ { print $1 }'); then
        log "WARNING: qm list failed; skipping stale VM state cleanup"
        return
    fi

    while IFS= read -r vmid; do
        [[ -n "$vmid" ]] && existing_vmids["$vmid"]=1
    done <<< "$qm_vmids"

    for vmid in "${!STATE_VMID_TO_BUS[@]}"; do
        [[ -n "${existing_vmids[$vmid]:-}" ]] && continue
        bus_path="${STATE_VMID_TO_BUS[$vmid]:-}"
        unset 'STATE_VMID_TO_BUS[$vmid]'
        unset 'STATE_VMID_TO_IMAGE[$vmid]'
        if [[ -n "$bus_path" ]]; then
            unset 'STATE_BUS_TO_VMID[$bus_path]'
            unset 'STATE_MISSING_BY_BUS[$bus_path]'
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

build_usb_state_json() {
    USB_STATE_LINES=()
    local vmid bus_path missing_since name vidpid
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
        USB_STATE_LINES+=("${vmid}"$'\t'"${bus_path}"$'\t'"${missing_since}"$'\t'"${name}"$'\t'"${vidpid}")
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
        log "ERROR: VM $vmid provisioning failed — ${reason}. Tearing down and releasing USB $bus_path for retry."
        timeout 60 qm stop "$vmid" 2>/dev/null || true
        timeout 60 qm destroy "$vmid" --skiplock --purge --destroy-unreferenced-disks 2>/dev/null || true
        unset 'STATE_VMID_TO_BUS[$vmid]'
        unset 'STATE_VMID_TO_IMAGE[$vmid]'
        unset 'STATE_BUS_TO_VMID[$bus_path]'
        unset 'STATE_MISSING_BY_BUS[$bus_path]'
        save_state_file
    }

    # Clone
    if ! timeout 180 qm clone "$template_id" "$vmid" --name "$full_name" 2>/dev/null; then
        _teardown "qm clone failed (template $template_id missing or VMID $vmid conflict)"
        return 1
    fi

    timeout 30 qm set "$vmid" --onboot 1 --startup "order=2,up=60" 2>/dev/null || true
    timeout 30 qm set "$vmid" -usb0 "host=$bus_path" 2>/dev/null || true

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

destroy_vm() {
    local vmid="$1"
    local bus_path="${STATE_VMID_TO_BUS[$vmid]:-}"
    timeout 60 qm stop "$vmid" 2>/dev/null || true
    timeout 60 qm destroy "$vmid" --skiplock --purge --destroy-unreferenced-disks 2>/dev/null || true
    if [[ -n "$bus_path" ]]; then
        unset 'STATE_MISSING_BY_BUS[$bus_path]'
        unset 'STATE_BUS_TO_VMID[$bus_path]'
    fi
    unset 'STATE_VMID_TO_BUS[$vmid]'
    unset 'STATE_VMID_TO_IMAGE[$vmid]'
    save_state_file
    log "Destroyed VM $vmid"
}

# Destroy VM via qm only — does NOT update in-memory state or write the state file.
# Used by parallel reclone jobs where state is managed by the parent process.
_destroy_vm_qm_only() {
    local vmid="$1"
    timeout 60 qm stop "$vmid" 2>/dev/null || true
    timeout 60 qm destroy "$vmid" --skiplock --purge --destroy-unreferenced-disks 2>/dev/null || true
}

# Run one reclone in a background subshell. All needed values are passed as arguments
# because bash associative arrays are NOT inherited by background subshells.
# State file updates are handled by the parent after all jobs complete.
_reclone_parallel_job() {
    local vmid="$1" bus_path="$2" product_name="$3" saved_image="$4" device_type="$5"
    _destroy_vm_qm_only "$vmid"
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

    refresh_usb_config
    scan_usb_devices
    load_state_file

    # ── Stale state cleanup: remove entries for VMIDs that no longer exist ────
    # Prevents dongles from being "stuck" assigned to a manually-deleted VM.
    local -A _existing_vmids=()
    while IFS= read -r _vid; do
        [[ -n "$_vid" ]] && _existing_vmids["$_vid"]="1"
    done < <(qm list 2>/dev/null | awk 'NR>1{print $1}')
    local _state_changed=0
    for vmid in "${!STATE_VMID_TO_BUS[@]}"; do
        if [[ -z "${_existing_vmids[$vmid]:-}" ]]; then
            local _stale_bus="${STATE_VMID_TO_BUS[$vmid]:-}"
            log "State cleanup: VM $vmid no longer exists — releasing bus ${_stale_bus:-unknown} for re-provision"
            [[ -n "$_stale_bus" ]] && {
                unset "STATE_BUS_TO_VMID[$_stale_bus]"
                unset "STATE_MISSING_BY_BUS[$_stale_bus]"
            }
            unset "STATE_VMID_TO_BUS[$vmid]"
            unset "STATE_VMID_TO_IMAGE[$vmid]"
            _state_changed=1
        fi
    done
    [[ "$_state_changed" -eq 1 ]] && save_state_file

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
                unset 'STATE_VMID_TO_BUS[${_prov_vmids[$_i]}]'
                unset 'STATE_VMID_TO_IMAGE[${_prov_vmids[$_i]}]'
                unset 'STATE_BUS_TO_VMID[${_prov_buses[$_i]}]'
                unset 'STATE_MISSING_BY_BUS[${_prov_buses[$_i]}]'
            fi
        done
        save_state_file
        build_usb_state_json
        curl_api POST /api/proxmox/telemetry "$(collect_telemetry)" >/dev/null 2>&1 || true
    fi

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

    local pve_version=""
    if command -v pveversion &>/dev/null; then
        pve_version=$(pveversion 2>/dev/null | awk -F'/' 'NR==1{print $2}' || true)
    fi

    vms_json="[]"
    if command -v pvesh &>/dev/null; then
        # pvesh returns: cpu (0.0-1.0 fraction), mem (bytes), maxmem (bytes)
        # Normalise: cpu → percent, mem/maxmem → MB. Merge QEMU VMs + LXC containers.
        vms_json=$(python3 -c "
import json, subprocess, sys

def fetch(path):
    try:
        r = subprocess.run(['pvesh','get',path,'--output-format','json'],
                           capture_output=True, text=True, timeout=15)
        return json.loads(r.stdout) if r.returncode == 0 else []
    except Exception:
        return []

node = subprocess.run(['hostname', '-s'], capture_output=True, text=True).stdout.strip()
qemu = fetch(f'/nodes/{node}/qemu')
lxc  = fetch(f'/nodes/{node}/lxc')

out = []
for v in qemu:
    out.append({
        'vmid':        v.get('vmid'),
        'name':        v.get('name', ''),
        'status':      v.get('status', 'unknown'),
        'cpu':         round(float(v.get('cpu') or 0) * 100, 1),
        'mem':         round(int(v.get('mem') or 0) / 1024 / 1024),
        'maxmem':      round(int(v.get('maxmem') or 0) / 1024 / 1024),
        'is_template': bool(v.get('template', 0)),
        'type':        'qemu',
    })
for v in lxc:
    out.append({
        'vmid':        v.get('vmid'),
        'name':        v.get('name', ''),
        'status':      v.get('status', 'unknown'),
        'cpu':         round(float(v.get('cpu') or 0) * 100, 1),
        'mem':         round(int(v.get('mem') or 0) / 1024 / 1024),
        'maxmem':      round(int(v.get('maxmem') or 0) / 1024 / 1024),
        'is_template': False,
        'type':        'lxc',
    })
print(json.dumps(out))
" 2>/dev/null || echo "[]")
    fi

    # Fallback: qm list + pct list (no CPU stats; maxmem unavailable)
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
  "vms": ${vms_json:-[]},
  "unknown_usb": $(cat "$USB_UNKNOWN_CACHE" 2>/dev/null || echo "${UNKNOWN_USB_JSON:-[]}"),
  "usb_state": $(cat "$USB_STATE_CACHE"   2>/dev/null || echo "${USB_STATE_JSON:-[]}"),
  "present_usb": $(cat "$USB_PRESENT_CACHE" 2>/dev/null || echo "${PRESENT_USB_JSON:-[]}"),
  "log_lines": $(collect_log_lines)
}
JSON
}

execute_vm_command() {
    local action="$1" vmid="${2:-}" _type="${3:-}"
    case "$action" in
        start_vm)     timeout 60 qm start "$vmid" ;;
        stop_vm)      timeout 60 qm stop "$vmid" ;;
        reboot_vm)    qm reboot "$vmid" 2>/dev/null || true ;;
        snapshot_vm)  qm snapshot "$vmid" "auto-$(date +%Y%m%d%H%M)" --description "client-sim" ;;
        reclone_vm)   reclone_vm_instance "$vmid" ;;
        delete_vm)
            load_state_file
            destroy_vm "$vmid"
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
        update_agent)
            local agent_script="/usr/local/bin/client-sim-proxmox-agent"
            local repo_raw="https://raw.githubusercontent.com/solutions-hpe/client-sim/lrb"
            local tmp_file
            tmp_file=$(mktemp)
            log "Checking for agent update from GitHub (current: v${AGENT_VERSION})..."
            if ! curl -sSf --max-time 30 "${repo_raw}/proxmox/proxmox-agent.sh" -o "$tmp_file"; then
                rm -f "$tmp_file"
                log "ERROR: Failed to download agent update"
                return 1
            fi
            # Validate downloaded script is valid bash before replacing
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
                log "Agent is already up to date (v${AGENT_VERSION})"
            else
                chmod +x "$tmp_file"
                mv "$tmp_file" "$agent_script"
                log "Agent updated v${AGENT_VERSION} → v${new_version} — restarting in 5s..."
                ( sleep 5 && systemctl restart client-sim-proxmox-agent ) &
            fi
            ;;
        *)          return 1 ;;
    esac
}

mkdir -p /var/lib/client-sim
log "Proxmox agent starting. Server: $SERVER_URL"
log "Host block $host_id → VM range $start_vmid-$end_vmid"
if [[ -z "$API_KEY" ]]; then
    register_and_wait_for_key
fi
ensure_state_file
refresh_usb_telemetry_only || true

# Helper: collect and POST telemetry immediately
post_telemetry() {
    local telem
    telem=$(collect_telemetry 2>/dev/null) || return 0
    curl_api POST /api/proxmox/telemetry "$telem" >/dev/null 2>&1 || true
}

# Background real-time telemetry sender (every TELEMETRY_INTERVAL seconds)
# Runs as a subprocess — reads node/VM stats fresh and USB state from cache files
(
    while true; do
        sleep "$TELEMETRY_INTERVAL"
        telem=$(collect_telemetry 2>/dev/null) || continue
        curl_api POST /api/proxmox/telemetry "$telem" >/dev/null 2>&1 || true
    done
) &
TELEMETRY_PID=$!
log "Background telemetry sender started (PID $TELEMETRY_PID, interval ${TELEMETRY_INTERVAL}s)"

post_telemetry || true

while true; do
    refresh_usb_config || true
    if [[ "$AUTO_PROVISION" == "on" ]]; then
        usb_provision_loop || log "WARNING: USB auto-provisioning loop failed"
    else
        refresh_usb_telemetry_only || true
    fi

    # Post telemetry after USB scan (has fresh USB state in this process)
    post_telemetry

    response=$(curl_api GET "/api/inbox?hostname=$h" "" 2>/dev/null || echo "[]")
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
        _seq_ids=()
        _seq_actions=()
        _seq_vmids=()
        _seq_types=()
        _rc_ids=()
        _rc_vmids=()
        while IFS=$'\t' read -r cmd_id action vmid cmd_type; do
            [[ -z "$cmd_id" || -z "$action" ]] && continue
            if [[ "$action" == "reclone_vm" && -n "$vmid" ]]; then
                _rc_ids+=("$cmd_id")
                _rc_vmids+=("$vmid")
            else
                _seq_ids+=("$cmd_id")
                _seq_actions+=("$action")
                _seq_vmids+=("$vmid")
                _seq_types+=("$cmd_type")
            fi
        done <<< "$parsed_commands"

        for _si in "${!_seq_ids[@]}"; do
            log "Executing ${_seq_actions[$_si]} (vmid=${_seq_vmids[$_si]:-})"
            status="completed"
            message=""
            if execute_vm_command "${_seq_actions[$_si]}" "${_seq_vmids[$_si]}" "${_seq_types[$_si]}" 2>>"$AGENT_LOG"; then
                message="${_seq_actions[$_si]} completed"
            else
                status="failed"
                message="${_seq_actions[$_si]} failed — check $AGENT_LOG"
            fi
            curl_api POST /api/inbox/ack "{\"id\":\"${_seq_ids[$_si]}\",\"status\":\"$status\",\"message\":\"$message\"}" >/dev/null 2>&1
            log "ACK: ${_seq_ids[$_si]} status=$status"
            post_telemetry  # reflect VM state change immediately
        done

        if [[ ${#_rc_vmids[@]} -gt 0 ]]; then
            load_state_file
            _rc_active_pids=()
            _rc_pids=()
            _rc_batch_ids=()
            _rc_batch_vmids=()
            _rc_batch_buses=()
            _conc="${RECLONE_CONCURRENCY:-1}"

            for _ri in "${!_rc_vmids[@]}"; do
                _vmid="${_rc_vmids[$_ri]}"
                _cmd_id="${_rc_ids[$_ri]}"
                _bus="${STATE_VMID_TO_BUS[$_vmid]:-}"
                if [[ -z "$_bus" ]]; then
                    _usb_line=$(qm config "$_vmid" 2>/dev/null | grep -m1 '^usb[0-9]*: ' || true)
                    if [[ "$_usb_line" =~ host=([^,[:space:]]+) ]]; then
                        _bus="${BASH_REMATCH[1]}"
                        log "Recovered USB bus_path=$_bus for VM $_vmid from qm config"
                        STATE_VMID_TO_BUS["$_vmid"]="$_bus"
                        STATE_BUS_TO_VMID["$_bus"]="$_vmid"
                    fi
                fi
                _vidpid="${USB_VIDPID_BY_BUS[$_bus]:-}"
                _product="${USB_NAME_BY_BUS[$_bus]:-$(find_label_for_vidpid "$_vidpid")}"
                _image="${STATE_VMID_TO_IMAGE[$_vmid]:-1}"
                _dtype="${CERTIFIED_TYPES[$_vidpid]:-wireless}"

                if [[ -z "$_bus" || ! -d "/sys/bus/usb/devices/$_bus" ]]; then
                    log "WARNING: USB device ${_bus:-<unknown>} is not present; cannot reclone VM $_vmid"
                    curl_api POST /api/inbox/ack "{\"id\":\"$_cmd_id\",\"status\":\"failed\",\"message\":\"USB device not present for VM $_vmid\"}" >/dev/null 2>&1
                    continue
                fi
                if [[ "$_dtype" != "$SIM_PHY" ]]; then
                    log "WARNING: VM $_vmid type=$_dtype != sim_phy=$SIM_PHY — skipping reclone"
                    curl_api POST /api/inbox/ack "{\"id\":\"$_cmd_id\",\"status\":\"failed\",\"message\":\"sim_phy mismatch: device is $_dtype but sim_phy=$SIM_PHY\"}" >/dev/null 2>&1
                    continue
                fi

                while [[ ${#_rc_active_pids[@]} -ge $_conc ]]; do
                    _live=()
                    for _p in "${_rc_active_pids[@]}"; do
                        kill -0 "$_p" 2>/dev/null && _live+=("$_p")
                    done
                    _rc_active_pids=("${_live[@]}")
                    [[ ${#_rc_active_pids[@]} -ge $_conc ]] && sleep 5
                done

                _RECLONE_CMD_IDS["$_vmid"]="$_cmd_id"
                log "Parallel reclone starting: VM $_vmid (bus=$_bus type=$_dtype image=$_image)"
                (
                    _reclone_parallel_job "$_vmid" "$_bus" "$_product" "$_image" "$_dtype"
                ) &
                _pid=$!
                _rc_active_pids+=("$_pid")
                _rc_pids+=("$_pid")
                _rc_batch_ids+=("$_cmd_id")
                _rc_batch_vmids+=("$_vmid")
                _rc_batch_buses+=("$_bus")
            done

            for _rpi in "${!_rc_pids[@]}"; do
                _rc_status="completed"
                _rc_msg="reclone_vm completed"
                if ! wait "${_rc_pids[$_rpi]}" 2>/dev/null; then
                    _rc_status="failed"
                    _rc_msg="reclone_vm failed — check $AGENT_LOG"
                    unset 'STATE_VMID_TO_BUS[${_rc_batch_vmids[$_rpi]}]'
                    unset 'STATE_VMID_TO_IMAGE[${_rc_batch_vmids[$_rpi]}]'
                    unset 'STATE_BUS_TO_VMID[${_rc_batch_buses[$_rpi]}]'
                    unset 'STATE_MISSING_BY_BUS[${_rc_batch_buses[$_rpi]}]'
                fi
                curl_api POST /api/inbox/ack "{\"id\":\"${_rc_batch_ids[$_rpi]}\",\"status\":\"$_rc_status\",\"message\":\"$_rc_msg\"}" >/dev/null 2>&1
                log "ACK: ${_rc_batch_ids[$_rpi]} status=$_rc_status (parallel reclone VM ${_rc_batch_vmids[$_rpi]})"
                unset '_RECLONE_CMD_IDS[${_rc_batch_vmids[$_rpi]}]'
            done

            for _vmid in "${_rc_batch_vmids[@]}"; do
                _b="${STATE_VMID_TO_BUS[$_vmid]:-}"
                [[ -n "$_b" ]] && STATE_MISSING_BY_BUS["$_b"]=""
            done
            save_state_file
        fi
    fi

    sleep "$POLL_INTERVAL"
done
