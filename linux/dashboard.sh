#!/bin/bash
version=.01
source '/usr/local/scripts/ini-parser.sh'
process_ini_file '/usr/local/scripts/simulation.conf'
#------------------------------------------------------------
# Simulation Dashboard (Read-only monitor)
#------------------------------------------------------------
log="/usr/local/scripts/sim.log"
refresh_rate=5
site_based_num=$(get_value 'simulation' 'site_based_num')
simulation_id=s
simulation_id+=$(echo $HOSTNAME | rev | cut -c 1-$site_based_num | rev | cut -c 1-1)
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
#Device Specific Simulation settings
#------------------------------------------------------------
wsite=$(get_value $simulation_id 'wsite')
sim_phy=$(get_value $simulation_id 'sim_phy')
ssid=$(get_value $simulation_id 'ssid')
ssidpw=$(get_value $simulation_id 'ssidpw')
dhcp_fail=$(get_value $simulation_id 'dhcp_fail')
dns_fail=$(get_value $simulation_id 'dns_fail')
assoc_fail=$(get_value $simulation_id 'assoc_fail')
port_flap=$(get_value $simulation_id 'port_flap')
ping_test=$(get_value $simulation_id 'ping_test')
download=$(get_value $simulation_id 'download')
iperf=$(get_value $simulation_id 'iperf')
www_traffic=$(get_value $simulation_id 'www_traffic')
#------------------------------------------------------------
#Simlation IP
#------------------------------------------------------------
smb_address=$(get_value 'address' 'smb_address')
ping_address=$(get_value 'address' 'ping_address')
dns_latency_1=$(get_value 'address' 'dns_latency_1')
dns_latency_2=$(get_value 'address' 'dns_latency_2')
dns_latency_3=$(get_value 'address' 'dns_latency_3')
dns_bad_ip_1=$(get_value 'address' 'dns_bad_ip_1')
dns_bad_ip_2=$(get_value 'address' 'dns_bad_ip_2')
dns_bad_ip_3=$(get_value 'address' 'dns_bad_ip_3')
dns_bad_record_1=$(get_value 'address' 'dns_bad_record_1')
dns_bad_record_2=$(get_value 'address' 'dns_bad_record_2')
dns_bad_record_3=$(get_value 'address' 'dns_bad_record_3')
vh_server_address=$(get_value 'address' 'vh_server_addr')
iperf_server=$(get_value 'address' 'iperf_server')
#------------------------------------------------------------
#User/Device Specific Overrides
#------------------------------------------------------------
apply_override() {
  local var=$1
  local val=$(get_value $username "$var")
  [[ -n ${val} ]] && declare -g "$var=$val"
}
override_keys=(kill_switch sim_load public_repo repo_location vh_server site_based_ssid iperf_bw \
  wsite sim_phy ssid ssidpw dhcp_fail dns_fail assoc_fail port_flap ping_test download iperf \
  www_traffic ssidpw_fail auth_fail smb_address ping_address dns_latency_1 dns_latency_2 \
  dns_latency_3 dns_bad_ip_1 dns_bad_ip_2 dns_bad_ip_3 dns_bad_record_1 dns_bad_record_2 \
  dns_bad_record_3 vh_server_addr iperf_server)
for key in "${override_keys[@]}"; do
  apply_override "$key"
done
#------------------------------------------------------------
# Helper: get WiFi status
#------------------------------------------------------------
get_wifi_status() {
  ssid=$(nmcli -t -f active,ssid dev wifi | awk -F: '$1=="yes"{print $2}')
  if [[ -n "$ssid" ]]; then
    echo "CONNECTED ($ssid)"
  else
    echo "DISCONNECTED"
  fi
}
#------------------------------------------------------------
# Helper: get gateway status
#------------------------------------------------------------
get_gateway_status() {
  gw=$(ip route | grep -oP 'default via \K\S+')
  if [[ -z "$gw" ]]; then
    echo "NOT FOUND"
    return
  fi
  if ping -c1 -W1 "$gw" >/dev/null 2>&1; then
    echo "ONLINE ($gw)"
  else
    echo "OFFLINE ($gw)"
  fi
}
#------------------------------------------------------------
# Helper: simulation process status
#------------------------------------------------------------
get_sim_status() {
  exclude=("dashboard.sh" "install.sh" "simulation.sh" "ini-parser.sh" "sys_mon.sh" "startup.sh")
  printf "%-10s %-15s %-8s %-10s\n" "STATUS" "SCRIPT" "PID" "RUNTIME"
  printf "%-10s %-15s %-8s %-10s\n" "------" "------" "---" "-------"
  for s in /usr/local/scripts/*.sh; do
    script_name=$(basename "$s")
    # check if script is in exclude list
    for e in "${exclude[@]}"; do
      [[ "$script_name" == "$e" ]] && continue 2
    done
    pid=$(pgrep -f "$script_name" | head -n 1)
    if [[ -n "$pid" ]]; then
      runtime=$(ps -p "$pid" -o etime= | tr -d ' ')
      printf "%-10s %-15s %-8s %-10s\n" "[RUNNING]" "$script_name" "$pid" "$runtime"
    else
      printf "%-10s %-15s %-8s %-10s\n" "[STOPPED]" "$script_name" "-" "-"
    fi
  done
}
#------------------------------------------------------------
# Main dashboard loop
#------------------------------------------------------------
while true; do
  clear
  echo "            SIMULATION DASHBOARD (LIVE)              "
  echo "Time:        $(date)"
  echo "Hostname:    $HOSTNAME"
  echo "WiFi Status: $(get_wifi_status)"
  echo "Gateway:     $(get_gateway_status)"
  echo ""--------------------------------------------------""
  echo "Simulation Details:"
  echo "Simulation Load: $sim_load"
  echo "Site: $wsite || Site Based SSID: $site_based_ssid"
  if [ $vh_server == "off" ]; then echo "Phy: $sim_phy"; fi
  if [ $sim_phy == "wireless" ] && [[ -n ${wladapter} ]]; then echo "Adapter: $wladapter"; fi
  declare -A sim_flags=(
   ["VHServer"]="$vh_server"
   ["Kill Switch"]="$kill_switch"
   ["DHCP Fail"]="$dhcp_fail"
   ["DNS Fail"]="$dns_fail"
   ["WWW Traffic"]="$www_traffic"
   ["iPerf"]="$iperf"
   ["Download"]="$download"
   ["Port Flap"]="$port_flap"
   ["Incorrect SSID PW"]="$ssidpw_fail"
  )
  for label in "${!sim_flags[@]}"; do
   [[ "${sim_flags[$label]}" == "on" ]] && echo "$label: on"
  done
  echo ""--------------------------------------------------""
  #echo "Active Simulations:"
  get_sim_status
  echo "--------------------------------------------------"
  # Optional: show last log lines (helps debugging)
  echo "Last Log Entries:"
  tail -n 10 "$log" 2>/dev/null
  echo "--------------------------------------------------"
  sleep "$refresh_rate"
done