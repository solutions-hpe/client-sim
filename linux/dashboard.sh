#!/bin/bash
version=.02
# WHY: dashboard.sh is a read-only live monitor. It runs in its own terminal
# window (launched by launch-terminals.sh) so the operator can always see
# what's happening without interrupting the simulation loop in the other pane.
source '/usr/local/scripts/ini-parser.sh'
process_ini_file '/usr/local/scripts/simulation.conf'
if [[ -f '/usr/local/scripts/user-overrides.conf' ]]; then
  process_ini_file '/usr/local/scripts/user-overrides.conf'
fi
#------------------------------------------------------------
# Simulation Dashboard (Read-only live monitor)
#------------------------------------------------------------
log="/usr/local/scripts/sim.log"
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
simulation_id=s
simulation_id+=$(echo "$HOSTNAME" | rev | cut -c 1-"$site_based_num" | rev | cut -c 1-1)
kill_switch=$(get_value 'simulation' 'kill_switch')
rapid_update=$(get_value 'simulation' 'rapid_update')
sim_load=$(get_value 'simulation' 'sim_load')
public_repo=$(get_value 'simulation' 'public_repo')
repo_location=$(get_value 'simulation' 'repo_location')
vh_server=$(get_value 'simulation' 'vh_server')
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
override_keys=(kill_switch sim_load public_repo repo_location vh_server site_based_ssid iperf_bw \
  wsite sim_phy ssid dhcp_fail dns_fail assoc_fail port_flap ping_test download iperf \
  www_traffic ssidpw_fail auth_fail)
for key in "${override_keys[@]}"; do
  apply_override "$key"
done
#------------------------------------------------------------
# Helper: WiFi status with color
#------------------------------------------------------------
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
  printf "  %s%-12s %-22s %-8s %-10s%s\n" "$BOLD" "STATUS" "SCRIPT" "PID" "RUNTIME" "$RST"
  printf "  %-12s %-22s %-8s %-10s\n" "──────────" "──────────────────────" "───" "───────"
  for s in /usr/local/scripts/*.sh; do
    local script_name pid runtime
    script_name=$(basename "$s")
    for e in "${exclude[@]}"; do
      [[ "$script_name" == "$e" ]] && continue 2
    done
    pid=$(pgrep -f "$script_name" | head -n 1)
    if [[ -n "$pid" ]]; then
      runtime=$(ps -p "$pid" -o etime= 2>/dev/null | tr -d ' ')
      printf "  %s%-12s%s %-22s %-8s %-10s\n" "$GRN" "[RUNNING]" "$RST" "$script_name" "$pid" "$runtime"
    else
      printf "  %s%-12s%s %-22s %-8s %-10s\n" "$RED" "[STOPPED]" "$RST" "$script_name" "-" "-"
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
  # Re-detect the WiFi adapter each refresh — it can appear/disappear with VH
  wladapter=$(ip -br a | grep "wlx\|wlan" | cut -d ' ' -f '1')
  # Read the global kill switch from the flat file (may differ from config-based one)
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
  # Surface global kill-switch override prominently — operator needs to know immediately
  if [[ "$gkill" == "on" ]]; then
    printf "  %sKill Sw:%s %s\n" "$BOLD" "$RST" "${RED}${BOLD}ENABLED — all simulations suspended${RST}"
  fi
  echo ""
  # Ordered flag display using parallel arrays.
  # WHY: Bash associative arrays have no guaranteed iteration order so the
  # flags would appear in a different sequence every refresh. Parallel arrays
  # give consistent ordering so the operator can scan quickly.
  flag_labels=("Kill Switch" "VH Server"  "DHCP Fail" "DNS Fail"  "WWW Traffic" "iPerf" "Download" "Port Flap" "Bad SSID PW" "Auth Fail")
  flag_values=("$kill_switch" "$vh_server" "$dhcp_fail" "$dns_fail" "$www_traffic" "$iperf" "$download" "$port_flap" "$ssidpw_fail" "$auth_fail")
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
  echo ""
  printf "%s  Recent Errors (sim.log):%s\n" "$BOLD" "$RST"
  # Show last 5 lines that contain [error] or [warning] — surface problems fast
  # WHY: Operators don't want to read all 10 log lines; they want errors first.
  errors_shown=$(grep -i '\[error\]\|\[warning\]' "$log" 2>/dev/null | tail -n 5)
  if [[ -n "$errors_shown" ]]; then
    echo "$errors_shown" | sed "s/^/  ${RED}/" | sed "s/$/${RST}/"
  else
    printf "  ${GRN}No recent errors${RST}\n"
  fi
  echo ""
  printf "%s  Recent Log (last 6 lines):%s\n" "$BOLD" "$RST"
  tail -n 6 "$log" 2>/dev/null | sed 's/^/  /'
  printf "%s%s%s\n" "$BOLD" "$(printf '═%.0s' $(seq 1 $(tput cols 2>/dev/null || echo 58)))" "$RST"
  sleep "$refresh_rate"
done