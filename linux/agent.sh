#!/bin/bash
# agent.sh — Client websocket agent
# Launches a background websocket client that streams status and receives commands.

set -u

SCRIPT_PATH=$(python3 - <<'PY'
from pathlib import Path
print(Path(__file__).resolve())
PY
)
PID_FILE="/var/run/client-sim-ws-agent.pid"
STATUS_FILE="/usr/local/scripts/client-status.json"
log="/usr/local/scripts/sim.log"
debug="/usr/local/scripts/debug-agent.log"

echo "Agent Script $(date)" | tee -a "$debug"

log_warning() {
  local payload="${1:-}"
  echo "[WARN] Malformed payload (truncated): ${payload:0:200}" | tee -a "$debug" "$log" >&2
}

source '/usr/local/scripts/ini-parser.sh'
process_ini_file '/usr/local/scripts/simulation.conf'

web_server=$(get_value 'simulation' 'web_server')
server_url=$(get_value 'server' 'server_url')
platform="${CLIENT_SIM_PLATFORM:-linux}"
hostname_val=$(hostname)

[[ "$web_server" != "on" || -z "$server_url" ]] && exit 0

handle_command() {
  local raw_cmd="${1:-}"
  python3 - "$raw_cmd" <<'PY'
import json, sys
cmd = json.loads(sys.argv[1] or '{}')
print(cmd.get('id',''), cmd.get('action',''), json.dumps(cmd.get('args', {})), sep='\t')
PY
}

run_command() {
  local raw_cmd="${1:-}"
  local cmd_id action args_json arg_value status message reboot_now parsed_cmd
  if ! parsed_cmd=$(handle_command "$raw_cmd" 2>/dev/null); then
    log_warning "$raw_cmd"
    parsed_cmd=$'\t\t'
  fi
  IFS=$'\t' read -r cmd_id action args_json <<< "$parsed_cmd"
  if ! arg_value=$(printf '%s' "$args_json" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('value',''))" 2>/dev/null); then
    log_warning "$raw_cmd"
    arg_value=""
  fi
  status="completed"
  message=""
  reboot_now="false"

  echo "Executing command: $cmd_id action=$action" | tee -a "$debug" "$log"
  case "$action" in
    restart_sim)
      _sim_pid=$(pgrep -f '[/]simulation.sh' | head -1)
      if [[ -n "$_sim_pid" ]]; then
        kill -USR1 "$_sim_pid" 2>/dev/null || true
        message="Restart signal sent (PID $_sim_pid)"
      else
        message="simulation.sh not running — no action taken"
      fi
      ;;
    reboot)
      if ! pgrep -f '[/]simulation.sh' >/dev/null 2>&1; then
        echo "Early-boot guard: skipping reboot command — simulation not yet running" | tee -a "$debug"
        message="Skipped — early-boot protection (simulation not running)"
      else
        message="Rebooting now"
        reboot_now="true"
      fi
      ;;
    update_now)
      bash /usr/local/scripts/update.sh
      message="Update triggered"
      ;;
    kill_switch)
      ks_val="${arg_value:-on}"
      if [[ "$ks_val" != "on" && "$ks_val" != "off" ]]; then ks_val="on"; fi
      sed -i "s/^kill_switch=.*/kill_switch=${ks_val}/" /usr/local/scripts/simulation.conf
      _sim_pid=$(pgrep -f '[/]simulation.sh' | head -1)
      if [[ -n "$_sim_pid" ]]; then
        kill -USR1 "$_sim_pid" 2>/dev/null || true
      fi
      if [[ "$ks_val" == "on" ]]; then
        message="Kill switch activated"
      else
        message="Kill switch deactivated — simulation will restart"
      fi
      ;;
    *)
      status="failed"
      message="Unknown action: $action"
      echo "Unknown action: $action" | tee -a "$debug"
      ;;
  esac

  python3 - <<PY
import json
print(json.dumps({
  "id": ${cmd_id@Q},
  "status": ${status@Q},
  "message": ${message@Q},
  "reboot": ${reboot_now@Q}
}))
PY
}

if [[ "${1:-}" == "--handle-command" ]]; then
  run_command "${2:-{}}"
  exit 0
fi

if [[ "${1:-}" != "--daemon" ]]; then
  if [[ -f "$PID_FILE" ]]; then
    existing_pid=$(cat "$PID_FILE" 2>/dev/null || true)
    if [[ -n "$existing_pid" ]] && kill -0 "$existing_pid" 2>/dev/null; then
      exit 0
    fi
  fi
  nohup bash "$0" --daemon >/dev/null 2>&1 &
  echo $! > "$PID_FILE"
  exit 0
fi

trap 'rm -f "$PID_FILE"' EXIT

echo $$ > "$PID_FILE"

python3 - "$0" "$server_url" "$hostname_val" "$platform" "$STATUS_FILE" "$debug" "$log" <<'PY'
import asyncio, json, os, pathlib, subprocess, sys

script_path, server_url, hostname, platform, status_file, debug_log, main_log = sys.argv[1:8]


def warn(raw):
    message = f"[WARN] Malformed payload (truncated): {str(raw)[:200]}"
    for path in (debug_log, main_log):
        try:
            with open(path, "a", encoding="utf-8") as fh:
                fh.write(message + "\n")
        except Exception:
            pass
try:
    import websockets
except ImportError:
    sys.exit(0)

ws_url = server_url.rstrip('/').replace('https://', 'wss://').replace('http://', 'ws://')
ws_url += f"/ws/client?hostname={hostname}&platform={platform}"


def fallback_status():
    return {
        "hostname": hostname,
        "simulation_id": "",
        "platform": platform,
        "iteration": 0,
        "connected_ssid": "",
        "gateway_reachable": False,
        "active_simulations": [],
        "errors": [],
        "config": {},
    }


def load_status():
    path = pathlib.Path(status_file)
    if not path.exists():
        return fallback_status()
    try:
        payload = json.loads(path.read_text())
    except Exception:
        return fallback_status()
    payload.setdefault("hostname", hostname)
    payload.setdefault("platform", platform)
    payload.setdefault("simulation_id", "")
    payload.setdefault("iteration", 0)
    payload.setdefault("gateway_reachable", False)
    payload.setdefault("active_simulations", [])
    payload.setdefault("errors", [])
    payload.setdefault("config", {})
    return payload


async def handle_command(ws, command):
    proc = await asyncio.create_subprocess_exec(
        "bash", script_path, "--handle-command", json.dumps(command),
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    stdout, _stderr = await proc.communicate()
    raw = stdout.decode().strip().splitlines()
    if not raw:
        return
    try:
        ack = json.loads(raw[-1])
    except Exception:
        warn(raw[-1])
        return
    await ws.send(json.dumps({"type": "ack", "payload": ack}))
    if ack.get("reboot") == "true":
        subprocess.Popen(["sudo", "reboot"])


async def send_loop(ws):
    while True:
        await ws.send(json.dumps({"type": "status", "payload": load_status()}))
        await asyncio.sleep(15)


async def main():
    backoff = 1
    while True:
        try:
            async with websockets.connect(ws_url, ping_interval=20, ping_timeout=10) as ws:
                backoff = 1
                await ws.send(json.dumps({"type": "sync"}))
                sender = asyncio.create_task(send_loop(ws))
                try:
                    async for message in ws:
                        try:
                            payload = json.loads(message)
                        except Exception:
                            warn(message)
                            continue
                        msg_type = str(payload.get("type") or "").lower()
                        if msg_type == "commands":
                            for command in payload.get("commands") or []:
                                await handle_command(ws, command)
                finally:
                    sender.cancel()
                    with contextlib.suppress(asyncio.CancelledError):
                        await sender
        except Exception:
            await asyncio.sleep(min(backoff, 30))
            backoff = min(backoff * 2, 30)


import contextlib
asyncio.run(main())
PY
