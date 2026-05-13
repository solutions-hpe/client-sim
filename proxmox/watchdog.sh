#!/bin/bash
set -euo pipefail

SERVICE_NAME="client-sim-proxmox-agent.service"
ENV_FILE="/etc/client-sim-proxmox-agent.env"
AGENT_BIN="/usr/local/bin/client-sim-proxmox-agent"
STATE_DIR="/var/lib/proxmox-watchdog"
STATE_FILE="${STATE_DIR}/state"
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
