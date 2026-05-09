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
      pkill -f simulation.sh 2>/dev/null || true
      sleep 2
      bash /usr/local/scripts/startup.sh &
      message="Simulation restarted"
      ;;
    reboot)
      message="Rebooting"
      curl -sS --max-time 5 -X POST "$server_url/api/inbox/ack" \
        -H "Content-Type: application/json" \
        -d "{\"id\":\"$cmd_id\",\"status\":\"completed\",\"message\":\"Rebooting now\"}" \
        >/dev/null 2>&1
      sudo reboot
      exit 0
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
      if [[ "$ks_val" == "on" ]]; then
        pkill -f simulation.sh 2>/dev/null || true
        message="Kill switch activated"
      else
        # Turn off: restart simulation so it picks up the new config
        pkill -f simulation.sh 2>/dev/null || true
        sleep 1
        bash /usr/local/scripts/startup.sh &
        message="Kill switch deactivated — simulation restarting"
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
