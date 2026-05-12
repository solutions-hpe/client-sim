#!/bin/bash
version=.03
# WHY: dashboard.sh is a read-only live monitor. It runs in its own terminal
# window (launched by startup.desktop) so the operator can always see
# what's happening without interrupting the simulation loop in the other pane.
source '/usr/local/scripts/ini-parser.sh'
process_ini_file '/usr/local/scripts/simulation.conf'
if [[ -f '/usr/local/scripts/user-overrides.conf' ]]; then
  process_ini_file '/usr/local/scripts/user-overrides.conf'
fi
#------------------------------------------------------------
# Simulation Dashboard (Read-only live monitor)
#------------------------------------------------------------
refresh_rate=5

# Terminal colors — degrade gracefully if tput is unavailable (e.g. SSH without TERM)
GRN=$(tput setaf 2 2>/dev/null || true)
RED=$(tput setaf 1 2>/dev/null || true)
YLW=$(tput setaf 3 2>/dev/null || true)
CYN=$(tput setaf 6 2>/dev/null || true)
BOLD=$(tput bold 2>/dev/null || true)
RST=$(tput sgr0 2>/dev/null || true)

# Derive username the same way startup.sh does — hostname prefix before first "-"
# WHY: username is used by apply_override() to check per-device config sections.
username=$(echo "$HOSTNAME" | cut -d "-" -f 1)

site_based_num=$(get_value 'simulation' 'site_based_num')
server_url=$(get_value 'server' 'server_url')
web_server=$(get_value 'simulation' 'web_server')
simulation_id=s
simulation_id+=$(echo "$HOSTNAME" | rev | cut -c 1-"$site_based_num" | rev | cut -c 1-1)
kill_switch=$(get_value 'simulation' 'kill_switch')
rapid_update=$(get_value 'simulation' 'rapid_update')
sim_load=$(get_value 'simulation' 'sim_load')
github_repo=$(get_value 'simulation' 'github_repo')
repo_location=$(get_value 'simulation' 'repo_location')
site_based_ssid=$(get_value 'simulation' 'site_based_ssid')
iperf_bw=$(get_value 'simulation' 'iperf_bw')
auth_fail=$(get_value 'simulation' 'auth_fail')
ssidpw_fail=$(get_value 'simulation' 'ssidpw_fail')
allow_offline=$(get_value 'simulation' 'allow_offline')
#------------------------------------------------------------
# Device-specific settings
#------------------------------------------------------------
wsite=$(get_value "$simulation_id" 'wsite')
sim_phy=$(get_value "$simulation_id" 'sim_phy')
ssid=$(get_value "$simulation_id" 'ssid')
dhcp_fail=$(get_value "$simulation_id" 'dhcp_fail')
dns_fail=$(get_value "$simulation_id" 'dns_fail')
assoc_fail=$(get_value "$simulation_id" 'assoc_fail')
port_flap=$(get_value "$simulation_id" 'port_flap')
ping_test=$(get_value "$simulation_id" 'ping_test')
download=$(get_value "$simulation_id" 'download')
iperf=$(get_value "$simulation_id" 'iperf')
www_traffic=$(get_value "$simulation_id" 'www_traffic')
#------------------------------------------------------------
# Per-device config overrides (same logic as simulation.sh)
#------------------------------------------------------------
apply_override() {
  local var=$1
  local val
  val=$(get_value "$username" "$var")
  [[ -n "${val}" ]] && declare -g "$var=$val"
}
override_keys=(kill_switch sim_load github_repo repo_location site_based_ssid iperf_bw \
  wsite sim_phy ssid dhcp_fail dns_fail assoc_fail port_flap ping_test download iperf \
  www_traffic ssidpw_fail auth_fail)
for key in "${override_keys[@]}"; do
  apply_override "$key"
done
#------------------------------------------------------------
# Helper: webUI API reachability
# WHY: Clients heartbeat to the webUI server; if the API is unreachable the
# operator needs to know immediately — heartbeats and config updates will fail.
#------------------------------------------------------------
get_api_status() {
  if [[ "$web_server" != "on" ]]; then
    echo "${YLW}DISABLED${RST} (web_server=off in config)"
    return
  fi
  if [[ -z "$server_url" ]]; then
    echo "${YLW}NOT CONFIGURED${RST}"
    return
  fi
  local http_code
  http_code=$(curl -o /dev/null -s -w "%{http_code}" \
    --connect-timeout 2 --max-time 3 \
    "${server_url%/}/api/health" 2>/dev/null)
  if [[ "$http_code" == "200" ]]; then
    echo "${GRN}CONNECTED${RST} (${server_url})"
  else
    echo "${RED}UNREACHABLE${RST} (${server_url})"
  fi
}
#------------------------------------------------------------
# Heartbeat: POST current client state to the webUI API every dashboard refresh.
# WHY: Keeps the server's client list alive independent of the simulation loop,
# which may have long-running steps between iterations.
#------------------------------------------------------------
send_heartbeat() {
  [[ "$web_server" != "on" ]] && return 0
  [[ -z "$server_url" ]] && return 0

  local connected_ssid gateway_reachable=false
  local active_sims_json="[]"
  connected_ssid=$(nmcli -t -f active,ssid dev wifi 2>/dev/null | awk -F: '$1=="yes"{print $2}')
  local dfgw
  dfgw=$(ip route | grep -oP 'default via \K\S+' | head -n1)
  [[ -n "$dfgw" ]] && ping -c1 -W1 "$dfgw" >/dev/null 2>&1 && gateway_reachable=true

  # Build active simulations list from flags
  local active_sims=()
  [[ "$dhcp_fail"   == "on" ]] && active_sims+=("dhcp_fail")
  [[ "$dns_fail"    == "on" ]] && active_sims+=("dns_fail")
  [[ "$assoc_fail"  == "on" ]] && active_sims+=("assoc_fail")
  [[ "$port_flap"   == "on" ]] && active_sims+=("port_flap")
  [[ "$ping_test"   == "on" ]] && active_sims+=("ping_test")
  [[ "$download"    == "on" ]] && active_sims+=("download")
  [[ "$iperf"       == "on" ]] && active_sims+=("iperf")
  [[ "$www_traffic" == "on" ]] && active_sims+=("www_traffic")
  [[ "$ssidpw_fail" == "on" ]] && active_sims+=("ssidpw_fail")
  [[ "$auth_fail"   == "on" ]] && active_sims+=("auth_fail")
  if [[ ${#active_sims[@]} -gt 0 ]]; then
    active_sims_json=$(printf '"%s",' "${active_sims[@]}" | sed 's/,$//')
    active_sims_json="[$active_sims_json]"
  fi

  local ssid_json="null"
  [[ -n "$connected_ssid" ]] && ssid_json="\"$connected_ssid\""

  curl -s -X POST "${server_url%/}/api/status" \
    -H "Content-Type: application/json" \
    -d "{
      \"hostname\": \"$HOSTNAME\",
      \"simulation_id\": \"$simulation_id\",
      \"platform\": \"linux\",
      \"iteration\": 0,
      \"connected_ssid\": $ssid_json,
      \"gateway_reachable\": $gateway_reachable,
      \"active_simulations\": $active_sims_json,
      \"config\": {
        \"kill_switch\": \"$kill_switch\",
        \"sim_load\": \"$sim_load\",
        \"ssid\": \"$ssid\",
        \"wsite\": \"$wsite\"
      },
      \"errors\": []
    }" >/dev/null 2>&1 || true
}

get_wifi_status() {
  local connected_ssid
  connected_ssid=$(nmcli -t -f active,ssid dev wifi 2>/dev/null | awk -F: '$1=="yes"{print $2}')
  if [[ -n "$connected_ssid" ]]; then
    echo "${GRN}CONNECTED${RST} ($connected_ssid)"
  else
    echo "${RED}DISCONNECTED${RST}"
  fi
}
#------------------------------------------------------------
# Helper: gateway reachability with color
# WHY: Pings once with 1s timeout so the dashboard refresh isn't delayed.
#------------------------------------------------------------
get_gateway_status() {
  local gw
  gw=$(ip route | grep -oP 'default via \K\S+' | head -n1)
  if [[ -z "$gw" ]]; then
    echo "${RED}NO ROUTE${RST}"
    return
  fi
  if ping -c1 -W1 "$gw" >/dev/null 2>&1; then
    echo "${GRN}ONLINE${RST} ($gw)"
  else
    echo "${RED}OFFLINE${RST} ($gw)"
  fi
}
#------------------------------------------------------------
# Helper: simulation process table
# Excluded scripts are infrastructure — we only show simulation workers.
#------------------------------------------------------------
get_sim_status() {
  local exclude=("dashboard.sh" "install.sh" "simulation.sh" "ini-parser.sh" "sys_mon.sh" "startup.sh")
  printf "  %s%-12s %-22s %-10s%s\n" "$BOLD" "STATUS" "SCRIPT" "RUNTIME" "$RST"
  printf "  %-12s %-22s %-10s\n" "──────────" "──────────────────────" "───────"
  for s in /usr/local/scripts/*.sh; do
    local script_name pid runtime
    script_name=$(basename "$s")
    for e in "${exclude[@]}"; do
      [[ "$script_name" == "$e" ]] && continue 2
    done
    pid=$(pgrep -f "$script_name" | head -n 1)
    if [[ -n "$pid" ]]; then
      runtime=$(ps -p "$pid" -o etime= 2>/dev/null | tr -d ' ')
      printf "  %s%-12s%s %-22s %-10s\n" "$GRN" "[RUNNING]" "$RST" "$script_name" "$runtime"
    else
      printf "  %s%-12s%s %-22s %-10s\n" "$RED" "[STOPPED]" "$RST" "$script_name" "-"
    fi
  done
}
#------------------------------------------------------------
# Main dashboard loop
# WHY: clear+redraw every refresh_rate seconds gives a live view without
# needing curses or a separate UI framework.
#------------------------------------------------------------
while true; do
  clear
  # Re-detect the WiFi adapter each refresh.
  wladapter=$(ip -br a | grep "wlx\|wlan" | cut -d ' ' -f '1')
  # Global kill switch comes from kill_switch.txt, synced from the GitHub repo by update.sh.
  # To kill all simulations globally, set linux/kill_switch.txt = "on" in the repo.
  gkill=$(cat /usr/local/scripts/kill_switch.txt 2>/dev/null || echo "off")

  printf "%s%s%s\n" "$BOLD" "$(printf '═%.0s' $(seq 1 $(tput cols 2>/dev/null || echo 58)))" "$RST"
  printf "%s  SIMULATION DASHBOARD   %s%-20s%s  %s%s\n" "$BOLD" "$CYN" "$HOSTNAME" "$RST" "$(date '+%H:%M:%S')" "$RST"
  printf "%s%s%s\n" "$BOLD" "$(printf '═%.0s' $(seq 1 $(tput cols 2>/dev/null || echo 58)))" "$RST"
  echo ""
  printf "  %sSite:%s    %-22s  %sSim-ID:%s %s\n" "$BOLD" "$RST" "$wsite" "$BOLD" "$RST" "$simulation_id"
  printf "  %sPHY:%s     %-22s  %sLoad:%s   %s%%\n" "$BOLD" "$RST" "$sim_phy" "$BOLD" "$RST" "$sim_load"
  [[ -n "$wladapter" ]] && printf "  %sAdapter:%s %s\n" "$BOLD" "$RST" "$wladapter"
  echo ""
  printf "  %sWiFi:%s    %s\n" "$BOLD" "$RST" "$(get_wifi_status)"
  printf "  %sGateway:%s %s\n" "$BOLD" "$RST" "$(get_gateway_status)"
  printf "  %sAPI:%s     %s\n" "$BOLD" "$RST" "$(get_api_status)"
  # Surface global kill-switch prominently — operator needs to know immediately.
  # Controlled via linux/kill_switch.txt in the GitHub repo (update.sh syncs it).
  if [[ "$gkill" == "on" ]]; then
    printf "  %sKill Sw:%s %s\n" "$BOLD" "$RST" "${RED}${BOLD}ENABLED — all simulations suspended${RST}"
  fi
  echo ""
  # Ordered flag display using parallel arrays.
  # WHY: Bash associative arrays have no guaranteed iteration order so the
  # flags would appear in a different sequence every refresh. Parallel arrays
  # give consistent ordering so the operator can scan quickly.
  flag_labels=("Kill Switch" "DHCP Fail" "DNS Fail" "WWW Traffic" "iPerf" "Download" "Port Flap" "Bad SSID PW" "Auth Fail")
  flag_values=("$kill_switch" "$dhcp_fail" "$dns_fail" "$www_traffic" "$iperf" "$download" "$port_flap" "$ssidpw_fail" "$auth_fail")
  flags_on=()
  for i in "${!flag_labels[@]}"; do
    [[ "${flag_values[$i]}" == "on" ]] && flags_on+=("${flag_labels[$i]}")
  done
  if [[ ${#flags_on[@]} -gt 0 ]]; then
    printf "  %s${YLW}Active Simulations:%s %s\n" "$BOLD" "$RST" "$(IFS=', '; echo "${flags_on[*]}")"
  else
    printf "  %sActive Simulations:%s ${GRN}none%s (staying associated only)\n" "$BOLD" "$RST" "$RST"
  fi
  echo ""
  printf "%s  Script Status:%s\n" "$BOLD" "$RST"
  get_sim_status
  printf "%s%s%s\n" "$BOLD" "$(printf '═%.0s' $(seq 1 $(tput cols 2>/dev/null || echo 58)))" "$RST"
  send_heartbeat
  sleep "$refresh_rate"
done