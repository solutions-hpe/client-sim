#!/usr/bin/env bash
set -uo pipefail

STATE_DIR="${STATE_DIR:-/var/lib/webui-watchdog}"
STATE_FILE="${STATE_FILE:-${STATE_DIR}/state}"
LOG_FILE="${LOG_FILE:-/var/log/webui-watchdog.log}"
INSTALL_DIR="${INSTALL_DIR:-/opt/client-sim-dashboard}"
ENV_FILE="${ENV_FILE:-${INSTALL_DIR}/.env}"
WEBUI_SERVICE="${WEBUI_SERVICE:-client-sim-dashboard}"
INSTALLER_PATH="${INSTALLER_PATH:-/opt/client-sim-repo/webui-spoke/install-lxc.sh}"
HEALTH_PATH="${HEALTH_PATH:-/api/health}"
PORT="${PORT:-8000}"
FAILURE_COUNT=0

log() {
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$LOG_FILE"
}

load_port() {
  local env_port

  if [[ ! -f "$ENV_FILE" ]]; then
    return
  fi

  env_port=$(awk -F= '/^PORT=/{print $2; exit}' "$ENV_FILE" | tr -d '"[:space:]')
  if [[ "$env_port" =~ ^[0-9]+$ ]]; then
    PORT="$env_port"
  fi
}

load_failure_count() {
  if [[ -f "$STATE_FILE" ]]; then
    read -r FAILURE_COUNT <"$STATE_FILE" || FAILURE_COUNT=0
  fi

  if [[ ! "$FAILURE_COUNT" =~ ^[0-9]+$ ]]; then
    FAILURE_COUNT=0
  fi
}

save_failure_count() {
  printf '%s\n' "$1" >"$STATE_FILE"
}

main() {
  local -a reasons=()
  local failure_count_after=0

  mkdir -p "$STATE_DIR" "$(dirname "$LOG_FILE")"
  touch "$LOG_FILE"

  load_port
  load_failure_count

  if ! systemctl is-active --quiet "$WEBUI_SERVICE"; then
    reasons+=("systemd_inactive")
  fi

  if ! curl -sf --max-time 5 "http://localhost:${PORT}${HEALTH_PATH}" >/dev/null; then
    reasons+=("health_check_failed")
  fi

  if (( ${#reasons[@]} == 0 )); then
    if (( FAILURE_COUNT > 0 )); then
      log "recovered service=${WEBUI_SERVICE} port=${PORT} previous_failures=${FAILURE_COUNT}"
    fi
    save_failure_count 0
    exit 0
  fi

  failure_count_after=$((FAILURE_COUNT + 1))
  save_failure_count "$failure_count_after"
  log "failure count=${failure_count_after} service=${WEBUI_SERVICE} port=${PORT} reasons=$(IFS=,; echo "${reasons[*]}")"

  if (( failure_count_after == 2 )); then
    if systemctl restart "$WEBUI_SERVICE"; then
      log "restart service=${WEBUI_SERVICE} after=2_failures"
    else
      log "restart_failed service=${WEBUI_SERVICE} after=2_failures"
    fi
    exit 0
  fi

  if (( failure_count_after >= 5 )); then
    log "installer_rerun_start path=${INSTALLER_PATH} after=5_failures"
    if bash "$INSTALLER_PATH" --unattended >>"$LOG_FILE" 2>&1; then
      log "installer_rerun_complete path=${INSTALLER_PATH}"
    else
      log "installer_rerun_failed path=${INSTALLER_PATH}"
    fi
    save_failure_count 0
  fi
}

main "$@"
