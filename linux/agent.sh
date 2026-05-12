#!/bin/bash
# agent.sh — Client inbox agent
# Polls the WebUI API for pending commands and executes them.
# Called from update.sh after the update tiers complete.

log="/usr/local/scripts/sim.log"
debug="/usr/local/scripts/debug-agent.log"
echo "Agent Script $(date)" | tee -a "$debug"

source '/usr/local/scripts/ini-parser.sh'
process_ini_file '/usr/local/scripts/simulation.conf'

web_server=$(get_value 'simulation' 'web_server')
server_url=$(get_value 'server' 'server_url')

[[ "$web_server" != "on" || -z "$server_url" ]] && exit 0

hostname_val=$(hostname)

# Poll inbox
response=$(curl -sS --max-time 10 \
  "$server_url/api/inbox?hostname=${hostname_val}" 2>/dev/null)

[[ -z "$response" || "$response" == "[]" ]] && exit 0

echo "Inbox response: $response" | tee -a "$debug"

# Process each command (simple JSON parsing without jq — one command per line approach)
# Extract id and action pairs using grep/sed
echo "$response" | python3 -c "
import json, sys
cmds = json.load(sys.stdin)
for c in cmds:
    print(c.get('id',''), c.get('action',''), json.dumps(c.get('args', {})), sep='\t')
" 2>/dev/null | while IFS=$'\t' read -r cmd_id action args_json; do
  # Extract a simple 'value' arg if present (e.g. {"value":"off"})
  arg_value=$(echo "$args_json" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('value',''))" 2>/dev/null || true)

  echo "Executing command: $cmd_id action=$action" | tee -a "$debug" "$log"
  status="completed"
  message=""

  case "$action" in
    restart_sim)
      # Send SIGUSR1 to simulation.sh so it exits its loop and re-execs cleanly.
      # DO NOT use pkill — pkill kills the managed process that startup.desktop
      # is watching, which causes "; systemctl reboot" to fire immediately.
      _sim_pid=$(pgrep -f '[/]simulation.sh' | head -1)
      if [[ -n "$_sim_pid" ]]; then
        kill -USR1 "$_sim_pid" 2>/dev/null || true
        message="Restart signal sent (PID $_sim_pid)"
      else
        message="simulation.sh not running — no action taken"
      fi
      ;;
    reboot)
      # Early-boot guard: if simulation.sh isn't running yet we are still in the
      # startup phase (called from update.sh before simulation starts). Executing a
      # reboot here would cause a boot loop if a stale command slipped through.
      # Once simulation.sh is running it is safe to honour a reboot command.
      if ! pgrep -f '[/]simulation.sh' >/dev/null 2>&1; then
        echo "Early-boot guard: skipping reboot command — simulation not yet running" | tee -a "$debug"
        status="completed"
        message="Skipped — early-boot protection (simulation not running)"
      else
        message="Rebooting"
        curl -sS --max-time 5 -X POST "$server_url/api/inbox/ack" \
          -H "Content-Type: application/json" \
          -d "{\"id\":\"$cmd_id\",\"status\":\"completed\",\"message\":\"Rebooting now\"}" \
          >/dev/null 2>&1
        sudo reboot
        exit 0
      fi
      ;;
    update_now)
      bash /usr/local/scripts/update.sh
      message="Update triggered"
      ;;
    kill_switch)
      # Set kill_switch to the requested value (default: on) in simulation.conf
      ks_val="${arg_value:-on}"
      if [[ "$ks_val" != "on" && "$ks_val" != "off" ]]; then ks_val="on"; fi
      sed -i "s/^kill_switch=.*/kill_switch=${ks_val}/" /usr/local/scripts/simulation.conf
      # Send SIGUSR1 to break simulation.sh out of its loop/sleep so it re-execs
      # and picks up the new kill_switch value immediately.
      # DO NOT use pkill — see restart_sim comment above.
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

  # ACK result
  curl -sS --max-time 10 -X POST "$server_url/api/inbox/ack" \
    -H "Content-Type: application/json" \
    -d "{\"id\":\"$cmd_id\",\"status\":\"$status\",\"message\":\"$message\"}" \
    >/dev/null 2>&1

  echo "ACK sent: $cmd_id status=$status" | tee -a "$debug"
done
