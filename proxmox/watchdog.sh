#!/bin/bash
set -euo pipefail

SERVICE_NAME="client-sim-proxmox-agent.service"
ENV_FILE="/etc/client-sim-proxmox-agent.env"
AGENT_BIN="/usr/local/bin/client-sim-proxmox-agent"
STATE_DIR="/var/lib/proxmox-watchdog"
STATE_FILE="${STATE_DIR}/state"
CRASH_BOOT_ID_FILE="${STATE_DIR}/os-crash-boot-id"   # tracks which boot we already reported
HW_FAULT_LOG="/var/lib/client-sim/hw-faults.json"    # shared with the agent — crash events land here
LOG_FILE="/var/log/proxmox-watchdog.log"
INSTALLER_PATH="/opt/proxmox-agent-installer/install-proxmox-agent.sh"
INSTALLER_TMP_PATH="/tmp/install-proxmox-agent-latest.sh"
REPO_BRANCH="${CLIENT_SIM_REPO_BRANCH:-main}"

log_event() {
    local timestamp message
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    message="$*"
    printf '[%s] %s\n' "$timestamp" "$message" >> "$LOG_FILE"
}

load_state() {
    if [[ -f "$STATE_FILE" ]]; then
        FAILURE_COUNT=$(cat "$STATE_FILE" 2>/dev/null || echo 0)
    else
        FAILURE_COUNT=0
    fi
    [[ "$FAILURE_COUNT" =~ ^[0-9]+$ ]] || FAILURE_COUNT=0
}

save_state() {
    printf '%s\n' "$FAILURE_COUNT" > "$STATE_FILE"
}

iso_timestamp() {
    date -u +%Y-%m-%dT%H:%M:%SZ
}

# ── OS crash detection ─────────────────────────────────────────────────────────
# Runs only within the first 10 minutes after a boot so we catch the previous
# boot's crash without re-scanning on every 5-minute watchdog tick.
# Writes any findings into the agent's hw-faults.json so they appear in the
# hub's Hardware Faults panel without requiring any hub/spoke code changes.
detect_and_report_os_crash() {
    command -v journalctl &>/dev/null || return 0
    command -v python3    &>/dev/null || return 0

    # Only act in the first 10 minutes of uptime
    local uptime_secs
    uptime_secs=$(awk '{print int($1)}' /proc/uptime 2>/dev/null || echo 99999)
    (( uptime_secs > 600 )) && return 0

    # Only report once per boot (track by boot-id)
    local boot_id
    boot_id=$(journalctl --list-boots --no-pager 2>/dev/null | awk 'NR==1{print $2}' || echo "unknown")
    if [[ -f "$CRASH_BOOT_ID_FILE" ]] && [[ "$(cat "$CRASH_BOOT_ID_FILE" 2>/dev/null)" == "$boot_id" ]]; then
        return 0
    fi

    local crash_type="" crash_detail="" crash_found=0

    # 1. OOM kill
    local oom_lines
    oom_lines=$(journalctl -b -1 --no-pager -q 2>/dev/null \
        | grep -iE "oom.killer|out of memory: Kill|Killed process|memory cgroup out of memory" \
        | tail -5 || true)
    if [[ -n "$oom_lines" ]]; then
        crash_type="oom_kill"; crash_detail="$oom_lines"; crash_found=1
    fi

    # 2. Kernel panic / BUG / oops
    if [[ $crash_found -eq 0 ]]; then
        local panic_lines
        panic_lines=$(journalctl -b -1 --no-pager -q 2>/dev/null \
            | grep -iE "kernel panic|BUG:|general protection fault|unable to handle kernel" \
            | tail -5 || true)
        if [[ -n "$panic_lines" ]]; then
            crash_type="kernel_panic"; crash_detail="$panic_lines"; crash_found=1
        fi
    fi

    # 3. Hung task / soft lockup
    if [[ $crash_found -eq 0 ]]; then
        local hung_lines
        hung_lines=$(journalctl -b -1 --no-pager -q 2>/dev/null \
            | grep -iE "hung_task|soft lockup|hard lockup|rcu_sched stall" \
            | tail -5 || true)
        if [[ -n "$hung_lines" ]]; then
            crash_type="hung_task"; crash_detail="$hung_lines"; crash_found=1
        fi
    fi

    # 4. kdump crash file present
    local kdump_file=""
    if [[ -d /var/crash ]]; then
        kdump_file=$(find /var/crash -maxdepth 2 -name "*.crash" -newer /proc/uptime 2>/dev/null | head -1 || true)
        if [[ -n "$kdump_file" ]] && [[ $crash_found -eq 0 ]]; then
            crash_type="kernel_crash_dump"; crash_found=1
        fi
    fi

    [[ $crash_found -eq 0 ]] && { echo "$boot_id" > "$CRASH_BOOT_ID_FILE"; return 0; }

    local hostname ts
    hostname=$(hostname 2>/dev/null || echo "unknown")
    ts=$(iso_timestamp)
    log_event "OS_CRASH_DETECTED type=${crash_type} host=${hostname} boot=${boot_id}"

    # Append the crash event into the agent's hw-faults.json so it surfaces
    # in the hub's Hardware Faults panel automatically via the next telemetry post.
    mkdir -p "$(dirname "$HW_FAULT_LOG")"
    python3 - "$crash_type" "$crash_detail" "$hostname" "$ts" "${kdump_file:-}" "$HW_FAULT_LOG" <<'PY' 2>/dev/null || true
import json, sys
from pathlib import Path

crash_type, crash_detail, hostname, ts, kdump_file, fault_log = sys.argv[1:7]

fault = {
    "type":       f"os_crash:{crash_type}",
    "check":      "os_crash",
    "message":    crash_detail[:500] if crash_detail else crash_type,
    "detail":     crash_detail[:2000] if crash_detail else "",
    "hostname":   hostname,
    "kdump_file": kdump_file or None,
    "ts":         ts,
}

p = Path(fault_log)
try:
    data = json.loads(p.read_text())
    faults = data.get("faults", []) if isinstance(data, dict) else []
except Exception:
    faults = []

faults.append(fault)
faults = faults[-50:]   # cap at 50 entries
p.write_text(json.dumps({"faults": faults}))
PY

    echo "$boot_id" > "$CRASH_BOOT_ID_FILE"

    # Also send immediately to the spoke API (best-effort) — the agent will
    # relay a full copy on its next telemetry cycle regardless.
    if [[ -n "${CLIENT_SIM_SERVER_URL:-}" ]]; then
        local payload
        payload=$(python3 -c "
import json, sys
print(json.dumps({
    'event':       'os_crash',
    'crash_type':  sys.argv[1],
    'detail':      sys.argv[2][:500],
    'hostname':    sys.argv[3],
    'timestamp':   sys.argv[4],
    'failure_count': 0,
}))" "$crash_type" "$crash_detail" "$hostname" "$ts" 2>/dev/null || echo "{}")
        local -a curl_args=(-sS --max-time 5 -X POST \
            "${CLIENT_SIM_SERVER_URL%/}/api/proxmox/watchdog_event" \
            -H "Content-Type: application/json")
        [[ -n "${CLIENT_SIM_API_KEY:-}" ]] && curl_args+=(-H "X-API-Key: ${CLIENT_SIM_API_KEY}")
        curl_args+=(-d "$payload")
        curl "${curl_args[@]}" >/dev/null 2>&1 || true
    fi
}


read_agent_port() {
    if [[ -n "${CLIENT_SIM_AGENT_PORT:-}" ]]; then
        printf '%s\n' "$CLIENT_SIM_AGENT_PORT"
        return 0
    fi
    if [[ -f "$AGENT_BIN" ]]; then
        grep -oP '(?<=CLIENT_SIM_AGENT_PORT:-)[0-9]+' "$AGENT_BIN" 2>/dev/null | head -n1 && return 0
    fi
    printf '9105\n'
}

report_event() {
    local event="$1"
    local timestamp payload
    local -a curl_args
    [[ -n "${CLIENT_SIM_SERVER_URL:-}" ]] || return 0
    timestamp="$(iso_timestamp)"
    payload=$(python3 - "$event" "$SERVICE_NAME" "$(hostname -f 2>/dev/null || hostname)" "$timestamp" "$FAILURE_COUNT" <<'PY'
import json
import sys
print(json.dumps({
    "event": sys.argv[1],
    "service": sys.argv[2],
    "hostname": sys.argv[3],
    "timestamp": sys.argv[4],
    "failure_count": int(sys.argv[5]),
}))
PY
)
    curl_args=(-sS --max-time 5 -X POST "${CLIENT_SIM_SERVER_URL%/}/api/proxmox/watchdog_event" -H "Content-Type: application/json")
    [[ -n "${CLIENT_SIM_API_KEY:-}" ]] && curl_args+=(-H "X-API-Key: ${CLIENT_SIM_API_KEY}")
    curl_args+=(-d "$payload")
    curl "${curl_args[@]}" >/dev/null 2>&1 || true
}

reinstall_agent() {
    local latest_installer_url installer_to_run installer_label

    latest_installer_url="https://raw.githubusercontent.com/solutions-hpe/client-sim/${REPO_BRANCH}/proxmox/install-proxmox-agent.sh"
    installer_to_run="$INSTALLER_PATH"
    installer_label="$INSTALLER_PATH"

    if curl -fsSL "$latest_installer_url" -o "$INSTALLER_TMP_PATH"; then
        installer_to_run="$INSTALLER_TMP_PATH"
        installer_label="$latest_installer_url"
    else
        log_event "REINSTALL_DOWNLOAD_WARNING service=${SERVICE_NAME} failure_count=${FAILURE_COUNT} url=${latest_installer_url} fallback=${INSTALLER_PATH}"
    fi

    if [[ -f "$installer_to_run" ]]; then
        if bash "$installer_to_run" --unattended; then
            log_event "REINSTALL service=${SERVICE_NAME} failure_count=${FAILURE_COUNT} installer=${installer_label}"
        else
            log_event "REINSTALL_FAILED service=${SERVICE_NAME} failure_count=${FAILURE_COUNT} installer=${installer_label}"
        fi
    else
        log_event "REINSTALL_MISSING service=${SERVICE_NAME} failure_count=${FAILURE_COUNT} installer=${INSTALLER_PATH}"
    fi
}

mkdir -p "$STATE_DIR"
touch "$LOG_FILE"

if [[ -f "$ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$ENV_FILE"
fi
REPO_BRANCH="${CLIENT_SIM_REPO_BRANCH:-$REPO_BRANCH}"

# Check for OS-level crashes from the previous boot and record them into the
# agent's hw-faults.json so they surface in the hub Hardware Faults panel.
detect_and_report_os_crash || true

load_state
AGENT_PORT="$(read_agent_port)"
TIMESTAMP="$(iso_timestamp)"

service_ok=false
health_ok=false
if systemctl is-active --quiet "$SERVICE_NAME"; then
    service_ok=true
    # The proxmox agent is a bash script, not an HTTP server — health is
    # confirmed by the service being active (systemctl is sufficient).
    health_ok=true
fi

if [[ "$service_ok" == true && "$health_ok" == true ]]; then
    if (( FAILURE_COUNT > 0 )); then
        log_event "RECOVERY service=${SERVICE_NAME} failure_count=${FAILURE_COUNT} health_port=${AGENT_PORT}"
        report_event "recovered"
    fi
    FAILURE_COUNT=0
    save_state
    exit 0
fi

FAILURE_COUNT=$((FAILURE_COUNT + 1))
save_state
log_event "FAILURE service=${SERVICE_NAME} failure_count=${FAILURE_COUNT} service_ok=${service_ok} health_ok=${health_ok} health_port=${AGENT_PORT} timestamp=${TIMESTAMP}"
report_event "failure"

if (( FAILURE_COUNT == 2 )); then
    if systemctl restart "$SERVICE_NAME"; then
        log_event "RESTART service=${SERVICE_NAME} failure_count=${FAILURE_COUNT}"
    else
        log_event "RESTART_FAILED service=${SERVICE_NAME} failure_count=${FAILURE_COUNT}"
    fi
    report_event "restart"
elif (( FAILURE_COUNT >= 5 )); then
    reinstall_agent
    report_event "reinstall"
    FAILURE_COUNT=0
    save_state
fi
