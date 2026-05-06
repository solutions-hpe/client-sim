#!/bin/bash
version=.94
log="/usr/local/scripts/sim.log"
debug="/usr/local/scripts/debug-simulation.log"
echo Simulation Script Version $version | tee "$debug"
#------------------------------------------------------------
#DO NOT EDIT BELOW THIS LINE UNLESS YOU KNOW WHAT YOU ARE DOING
#------------------------------------------------------------
#------------------------------------------------------------
#Finding adapter names and setting usable variables for interfaces
#When using a physical piece of hardware we want to diable the
#interface not in use. So that we force the traffic out the interface
#set int he simulation.conf
#------------------------------------------------------------
#------------------------------------------------------------
wladapter=$(ip -br a | grep "wlx\|wlan" | cut -d ' ' -f '1')
if [[ -n ${wladapter} ]]; then echo WLAN Adapter name $wladapter | tee -a "$debug"; fi
eadapter=$(ip -br a | grep "enp\|eno\|eth0\|eth1\|eth2\|eth3\|eth4\|eth5\|eth6" | cut -d ' ' -f '1')
if [[ -n ${eadapter} ]]; then echo Wired Adapter name $eadapter | tee -a "$debug"; fi
#------------------------------------------------------------
#Settings read from the local config file
#Global Simulation settings
#------------------------------------------------------------
#Global Variable Export Enable
set -a
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
web_server=$(get_value 'simulation' 'web_server')
server_url=$(get_value 'server' 'server_url')
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
#End User/Device Specific Overrides
#------------------------------------------------------------
#Checking global kill switch config
#------------------------------------------------------------
gkill_switch=$(cat /usr/local/scripts/kill_switch.txt)
#------------------------------------------------------------
#Generating a random number to have some variance in the scripts
#------------------------------------------------------------
rn=$((1 + RANDOM % 60))
rn_iperf_port=$((5201 + RANDOM % 10))
rn_iperf_time=$((1 + RANDOM % 300))
rn_ping_size=$((1 + RANDOM % 65000))
rn_offline_time=$((1 + RANDOM % 14400))
rn_sim_load=$((1 + RANDOM % 99))
#Global Variable Export Disable
set +a
hostname=$HOSTNAME
platform=linux
#------------------------------------------------------------
#Status reporting
#------------------------------------------------------------
json_escape() {
  local value="${1-}"
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  value=${value//$'\n'/\\n}
  value=${value//$'\r'/\\r}
  value=${value//$'\t'/\\t}
  printf '%s' "$value"
}

report_status() {
  local iteration="${1:-${z:-0}}"
  [[ $web_server != "on" ]] && return 0
  [[ -z ${server_url} ]] && return 0

  local connected_ssid gateway_json=false first=true active_simulations=""
  connected_ssid=$(nmcli -t -f active,ssid dev wifi | grep '^yes' | cut -d: -f2 | head -n1)
  if [[ ${gateway_reachable} == "true" ]]; then
    gateway_json=true
  fi

  local sim
  for sim in dns_fail iperf download www_traffic ping_test ssidpw_fail auth_fail dhcp_fail; do
    if [[ ${!sim} == "on" ]]; then
      if [[ $first == true ]]; then
        first=false
      else
        active_simulations+=","
      fi
      active_simulations+="\"$sim\""
    fi
  done

  local payload
  printf -v payload '{"hostname":"%s","simulation_id":"%s","platform":"%s","iteration":%s,"connected_ssid":"%s","gateway_reachable":%s,"vh_connected":false,"active_simulations":[%s],"config":{"sim_phy":"%s","kill_switch":"%s","dns_fail":"%s","iperf":"%s","www_traffic":"%s","download":"%s","ping_test":"%s","ssidpw_fail":"%s","auth_fail":"%s","dhcp_fail":"%s"}}' \
    "$(json_escape "$hostname")" \
    "$(json_escape "$simulation_id")" \
    "$(json_escape "$platform")" \
    "$iteration" \
    "$(json_escape "$connected_ssid")" \
    "$gateway_json" \
    "$active_simulations" \
    "$(json_escape "$sim_phy")" \
    "$(json_escape "$kill_switch")" \
    "$(json_escape "$dns_fail")" \
    "$(json_escape "$iperf")" \
    "$(json_escape "$www_traffic")" \
    "$(json_escape "$download")" \
    "$(json_escape "$ping_test")" \
    "$(json_escape "$ssidpw_fail")" \
    "$(json_escape "$auth_fail")" \
    "$(json_escape "$dhcp_fail")"

  curl -m 5 -s -o /dev/null -H "Content-Type: application/json" -X POST --data "$payload" "${server_url%/}/api/status" >/dev/null 2>&1 || true
  return 0
}
#------------------------------------------------------------
#Getting username from hostname extraction
#changing DHCP Client configuration to send the username as the hostname
#Pure aesthetics so the usernames in Central look good
#------------------------------------------------------------
sudo sed -i "s/gethostname()/\"$username\"/g" /etc/dhcp/dhclient.conf
#------------------------------------------------------------
#Functions
#------------------------------------------------------------
wait_for_ssid() {
  local target_ssid="$1"
  local timeout=60
  local interval=3
  local elapsed=0
  echo "Scanning for SSID: $target_ssid" | tee -a "$debug"
  # First scan phase
  while [ "$elapsed" -lt "$timeout" ]; do
    if nmcli -t -f SSID device wifi list | grep -Fxq "$target_ssid"; then
      echo "SSID found: $target_ssid" | tee -a "$debug"
      return 0
    fi
    sleep "$interval"
    elapsed=$((elapsed + interval))
  done
  echo "SSID not found after $timeout seconds, attempting rescan" | tee -a "$debug" "$log"
  # Force rescan
  nmcli device wifi rescan >/dev/null 2>&1
  sleep 2
  if nmcli -t -f SSID device wifi list | grep -Fxq "$target_ssid"; then
    echo "SSID found after rescan: $target_ssid" | tee -a "$debug"
    return 0
  fi
  echo "SSID still not found, resetting WiFi adapter" | tee -a "$debug" "$log"
  # Toggle WiFi ONLY now
  nmcli radio wifi off
  sleep 3
  nmcli radio wifi on
  sleep 2
  # Final attempt after reset
  elapsed=0
  while [ "$elapsed" -lt "$timeout" ]; do
    nmcli device wifi rescan >/dev/null 2>&1
    if nmcli -t -f SSID device wifi list | grep -Fxq "$target_ssid"; then
      echo "SSID found after WiFi reset: $target_ssid" | tee -a "$debug" "$log"
      return 0
    fi
    sleep "$interval"
    elapsed=$((elapsed + interval))
  done
  echo "ERROR: SSID '$target_ssid' not found after rescan and WiFi reset" | tee -a "$debug" "$log"
  return 1
}
#------------------------------------------------------------
#WiFi connections
#------------------------------------------------------------
connect_wifi() {
  nmcli radio wifi on
  echo "Ensuring WiFi Adapter is ON" | tee -a "$debug"
  sleep 2
  if [ "$site_based_ssid" == "on" ]; then
    target_ssid="$wsite-$ssid"
  else
    target_ssid="$ssid"
  fi
  # --- NEW: check current connection ---
  current_ssid=$(nmcli -t -f active,ssid dev wifi | awk -F: '$1=="yes"{print $2}')
  if [ "$current_ssid" == "$target_ssid" ]; then
    echo "Already connected to $target_ssid — skipping" | tee -a "$debug"
    return 0
  fi
  wait_for_ssid "$target_ssid" || return 1
  echo "Attempting to connect to $target_ssid" | tee -a "$debug"
  nmcli device wifi connect "$target_ssid" password "$ssidpw"
}
#------------------------------------------------------------
#Connection management
#------------------------------------------------------------
manage_connection() {
  local action=$1
  local wait_time=$2
  nmcli radio wifi on
  echo "Ensuring WiFi Adapter is ON" | tee -a "$debug"
  sleep 2
  if [ "$site_based_ssid" == "on" ]; then
    target_ssid="$wsite-$ssid"
  else
    target_ssid="$ssid"
  fi
  current_ssid=$(nmcli -t -f active,ssid dev wifi | awk -F: '$1=="yes"{print $2}')
  if [ "$current_ssid" == "$target_ssid" ] && [ "$action" == "up" ]; then
    echo "Already connected to $target_ssid — skipping bring-up" | tee -a "$debug"
    return 0
  fi
  wait_for_ssid "$target_ssid" || return 1
  echo "Attempting to $action connection: $target_ssid" | tee -a "$debug"
  nmcli -w "$wait_time" connection "$action" "$target_ssid"
}
#------------------------------------------------------------
#Run simulation scripts
#------------------------------------------------------------
run_simulation() {
 local script=$1
 if [ -f "/usr/local/scripts/$script" ]; then
  nohup bash "/usr/local/scripts/$script" > /dev/null 2>&1 &
 fi
}
#------------------------------------------------------------
#Attempting WiFi connection
#------------------------------------------------------------
connect_wifi
gateway_reachable=false
dfgw=$(ip route | grep -oP 'default via \K\S+' | head -n1)
if [[ -n ${dfgw} ]] && ping -c1 -W1 "$dfgw" >/dev/null 2>&1; then
  gateway_reachable=true
fi
report_status 0
#------------------------------------------------------------
#Dumping Current Device List
#------------------------------------------------------------
echo Disabling unused interface | tee -a "$debug"
if [ $sim_phy == "ethernet" ]; then sudo ip link set dev $wladapter down; fi
if [ $sim_phy == "wireless" ] && [ $vh_server == "off" ]; then sudo ip link set dev $eadapter down; fi
echo Generating MAC address | tee -a "$debug"
mac_id=$(echo $HOSTNAME | rev | cut -c 3-4 | rev)
mac_id="${mac_id}:$(echo $HOSTNAME | rev | cut -c 1-2 | rev)"
#------------------------------------------------------------
#Checking to see if the default gateway is reachable
#------------------------------------------------------------
echo Finding WLAN Adapter | tee -a "$debug"
wladapter=$(ip -br a | grep "wlx\|wlan" | cut -d ' ' -f '1')
echo Unblocking WiFi / RFKill | tee -a "$debug"
sudo rfkill unblock wifi & disown
echo Getting Default Gateway | tee -a "$debug"
dfgw=$(ip route | grep -oP 'default via \K\S+')
echo Ping the Default Gateway | tee -a "$debug"
ping -c2 $dfgw
if [ $? -eq 0 ] && [ $sim_phy == "wireless" ] && [[ -n ${wladapter} ]]; then
 echo Successful network connection - Pre-Simulation | tee -a "$debug"
 echo In Pre-Simulation | tee -a "$debug"
else
  echo Network connection failed | tee -a "$debug"
  echo In Pre-Simulation | tee -a "$debug"
  #------------------------------------------------------------
  #If VH is enabled then attempt to connect to VHServer
  #------------------------------------------------------------
  if [ $vh_server == "on" ]; then source '/usr/local/scripts/vhconnect.sh'; fi
  #------------------------------------------------------------
  #End Connecting to VHServer
  #------------------------------------------------------------
  sleep 15
  wladapter=$(ip -br a | grep "wlx\|wlan" | cut -d ' ' -f '1')
  connect_wifi
  sleep 15
  dfgw=$(ip route | grep -oP 'default via \K\S+')
fi
#------------------------------------------------------------
#Begin Setting up simulation load
#------------------------------------------------------------
if [ $sim_load -lt $rn_sim_load ]; then
  echo Simulation load under threshold | tee -a "$debug"
  echo Skipping Simulations but staying associated | tee -a "$debug"
  if [ $ssidpw_fail != "on" ] && [[ -n ${wladapter} ]]; then
    manage_connection up 180
  fi
  sleep 5
fi
#------------------------------------------------------------
#End Setting up simulation load
#------------------------------------------------------------
echo Kill Switch is $kill_switch | tee -a "$debug"
if [ $kill_switch == "off" ]; then
 for z in {1..100}; do
  gateway_reachable=false
  dfgw=$(ip route | grep -oP 'default via \K\S+' | head -n1)
  if [[ -n ${dfgw} ]] && ping -c1 -W1 "$dfgw" >/dev/null 2>&1; then
   gateway_reachable=true
  fi
  report_status "$z"
  #------------------------------------------------------------
  #SSID Incorrect Password Simulation or Auth Failure Simulation
  #since these are very similar they are in the same section one
  #has a bad PSK and others have a blocked mac or invalud username/password combo
  #both need to be constantly connecting so we trigger insights
  #------------------------------------------------------------
  if [ $ssidpw_fail == "on" ] || [ $auth_fail == "on" ] && [[ -n ${wladapter} ]]; then
    if [ $ssidpw_fail == "on" ]; then
     for i in {1..100}; do
      echo Running SSID Incorrect Password | tee -a "$debug"
      ssidpw="$(get_value $simulation_id 'ssidpw')""_fail"
      echo Iteration $i of 100 | tee -a "$debug"
      sudo nmcli con del $(nmcli -t -f NAME con | grep PSK)
      connect_wifi
     done
    fi
    if [ $auth_fail == "on" ]; then
     echo Running Auth Failure | tee -a "$debug"
     for i in {1..100}; do
      echo Enable/Disable WLAN interface | tee -a "$debug"
      echo Iteration $i of 100 | tee -a "$debug"
      sudo nmcli con del $(nmcli -t -f NAME con | grep PSK)
      manage_connection up 5
      sleep 5
      manage_connection down 5
     done
    fi
   #------------------------------------------------------------
   #Resetting the WIFI Password so it can connect correctly for updates/maintenance
   #------------------------------------------------------------
   ssidpw=$(get_value $simulation_id 'ssidpw')
   connect_wifi
   #------------------------------------------------------------
   #End SSID Incorrect Password Simualtion or Auth Failure Simulation
   #------------------------------------------------------------
  else
   #------------------------------------------------------------
   #If SSID Incorrect Password Sim is not triggered then check
   #for the other simualtions
   #------------------------------------------------------------
   dfgw=$(ip route | grep -oP 'default via \K\S+')
   ping -c2 $dfgw
   if [ $? -eq 0 ]; then
    echo Successful network connection | tee -a "$debug"
    echo In Simulation Loop | tee -a "$debug"
    else
     echo Network connection failed | tee -a "$debug"
     echo In Simulation Loop | tee -a "$debug"
     echo Attempting to reset adapter | tee -a "$debug"
     if [ $vh_server == "on" ]; then source '/usr/local/scripts/vhconnect.sh'; fi
     sleep 15
     wladapter=$(ip -br a | grep "wlx\|wlan" | cut -d ' ' -f '1')
     sudo nmcli con del $(nmcli -t -f NAME con | grep PSK)
     connect_wifi
     echo WLAN Adapter name $wladapter | tee -a "$debug"
     sleep 15
     ping -c2 $dfgw
     if [ $? -eq 0 ]; then
      echo Successful network connection | tee -a "$debug"
      echo After Adapter Reset | tee -a "$debug"
     else
     echo Connection failed muiltiple times | tee -a "$debug"
     echo Resetting configuration | tee -a "$debug"
     echo Purging VHConfig | tee -a "$debug"
     #------------------------------------------------------------
     #Running API to VHClient to disconnect all clients this device is connecting to
     #When a device ID changes on VH the client can think it should connect to multiple devices
     #------------------------------------------------------------
     /usr/sbin/vhclientx86_64 -t "STOP USING ALL LOCAL"
     /usr/sbin/vhclientx86_64 -t "AUTO USE CLEAR ALL"
     #------------------------------------------------------------
     #VHCached.txt will hold the server and device ID from VH so we use the same device every time
     #In the case when a device ID Changes, puring this setting will make sure a new device is captured
     #Device IDs on VH do not happen often, this is mostly when initial turn up happens, or significant
     #changes occur in the environment. This is a workaround just for when the IDs change.
     #------------------------------------------------------------
     rm -f /usr/local/scripts/vhcached.txt
     #------------------------------------------------------------
     #Cleaning up old network connection profiles
     #------------------------------------------------------------
     sudo nmcli con del $(nmcli -t -f NAME con | grep PSK)
     #------------------------------------------------------------
     #Looping Script - Network Connectivity Failed
     #------------------------------------------------------------
     source /usr/local/scripts/simulation.sh
    fi
   fi
   #------------------------------------------------------------
   #End Connecting to Network
   #------------------------------------------------------------
   if [ "$www_traffic" == "on" ]; then
    if ! pgrep -f "www_traffic.sh" >/dev/null; then
     run_simulation "www_traffic.sh"
     echo Running WWW Traffic Simulation | tee -a "$debug" "$log"
     www_traffic="off"
    fi
   fi
   if [ "$ping_test" == "on" ]; then
    if ! pgrep -f "ping_test.sh" >/dev/null; then
     run_simulation "ping_test.sh"
     echo Running Ping Test Simulation | tee -a "$debug" "$log"
    fi
   fi
   if [ "$iperf" == "on" ]; then
    if ! pgrep -f "iperf.sh" >/dev/null; then
     run_simulation "iperf.sh"
     echo Running iPerf Simulation | tee -a "$debug" "$log"
    fi
   fi
   if [ "$download" == "on" ]; then
    if ! pgrep -f "download.sh" >/dev/null; then
     run_simulation "download.sh"
     echo Running Download Simulation | tee -a "$debug" "$log"
    fi
   fi
   if [ "$dns_fail" == "on" ]; then
    if ! pgrep -f "dns_fail.sh" >/dev/null; then
     run_simulation "dns_fail.sh"
     echo Running DNS Simulation| tee -a "$debug" "$log"
    fi
   fi
   sleep 10
   if (( z % 10 == 0 )); then
    echo Closing Firefox | tee -a "$debug"
    pkill -f firefox
    www_traffic="on"
   fi
   echo End of simulation | tee -a "$debug"
   #------------------------------------------------------------
   #Running update to either the cloud repo or local SMB repo
   #------------------------------------------------------------
   if [ $rapid_update == "on" ]; then source '/usr/local/scripts/update.sh'; fi
   #------------------------------------------------------------
   #End Script Updates
   #------------------------------------------------------------
   echo Sleeping for 5 seconds | tee -a "$debug"
   echo Loop iteration $z of 100 | tee -a "$debug"
   sleep 5
   #------------------------------------------------------------
   #End of 100 Loop Count
   #------------------------------------------------------------
  fi
 done
else
 #------------------------------------------------------------
 #If kill switch is enabled - sleeping for 5 minutes then restarting the loop
 #------------------------------------------------------------
 echo Kill switch enabled - sleeping for 5 minutes | tee -a "$debug"
 sleep 300
fi
#------------------------------------------------------------
#Killing Firefox simulation
#------------------------------------------------------------
echo Closing Firefox | tee -a "$debug"
pkill -f firefox &
#------------------------------------------------------------
#End Kill switch Check 
#------------------------------------------------------------
#------------------------------------------------------------
#Running apt update & apt upgrade
#------------------------------------------------------------
echo Running Updates | tee -a "$debug"
bash /usr/local/scripts/apt_update.sh &
if [ $allow_offline == "yes" ]; then
  #------------------------------------------------------------
  #Bringing all interfaces down to make it look like the device is offline.
  #Otherwise they get triggered as IOT since they are always connected.
  #------------------------------------------------------------
  echo Bringing all interfaces down | tee -a "$debug"
  if [[ -n ${wladapter} ]]; then sudo ip link set dev $wladapter down; fi
  if [[ -n ${eadapter} ]]; then sudo ip link set dev $eadapter down; fi
  echo Sleeping for $rn_offline_time seconds | tee -a "$debug"
  echo ------------------------------ | tee -a "$debug"
  #------------------------------------------------------------
  #Sleep for up to 4 hours to show the device left
  #------------------------------------------------------------
  sleep $rn_offline_time
  #------------------------------------------------------------
  #Bringing all interfaces back up to call home/update scripts
  #------------------------------------------------------------
  echo Bringing all interfaces online | tee -a "$debug"
  if [[ -n ${eadapter} ]]; then sudo ip link set dev $eadapter up; fi
  if [[ -n ${wladapter} ]]; then sudo ip link set dev $wladapter up; fi
  echo ------------------------------ | tee -a "$debug"
fi
#------------------------------------------------------------
#Looping Script
#------------------------------------------------------------
source /usr/local/scripts/simulation.sh