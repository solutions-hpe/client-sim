#!/bin/bash
version=.02
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
# Helper: returns true if the ethernet adapter carries a 169.253.x.x address.
# WHY: 169.253.1.0/24 is the management subnet used to reach the API server.
# If ethernet has this address, it must NEVER be brought down — doing so would
# cut the heartbeat and config-sync link back to the WebUI dashboard.
#------------------------------------------------------------
ea_is_mgmt() {
  [[ -n "$eadapter" ]] && ip -4 addr show dev "$eadapter" 2>/dev/null | grep -q "169\.253\."
}
# Safe wrapper — always use this instead of raw 'ip link set dev $eadapter down'.
# Silently refuses to shut down the interface if a management IP is present.
ea_down() {
  if ea_is_mgmt; then
    echo "Blocked ethernet shutdown — management IP (169.253.x.x) active on $eadapter" | tee -a "$debug"
  elif [[ -n "$eadapter" ]]; then
    sudo ip link set dev "$eadapter" down
  fi
}
#------------------------------------------------------------
# Hardware type detection — reported to the WebUI API so operators can see
# whether each client is a Pi4, Pi5, KVM VM, x86 physical box, etc.
# Priority: Raspberry Pi (device tree) → systemd-detect-virt → DMI product name → arch fallback
#------------------------------------------------------------
detect_hardware() {
  # Raspberry Pi: device tree model file is the most reliable source
  if [[ -f /sys/firmware/devicetree/base/model ]]; then
    local model
    model=$(tr -d '\0' < /sys/firmware/devicetree/base/model 2>/dev/null)
    if [[ "$model" == *"Raspberry Pi"* ]]; then
      # Shorten to e.g. "Pi 4 Model B" or "Pi 5 Model B"
      echo "$model" | sed 's/Raspberry Pi /Pi /'
      return
    fi
  fi
  # Virtual machine detection via systemd-detect-virt
  if command -v systemd-detect-virt &>/dev/null; then
    local virt
    virt=$(systemd-detect-virt 2>/dev/null)
    case "$virt" in
      kvm)    echo "KVM/QEMU"; return ;;
      qemu)   echo "QEMU";     return ;;
      vmware) echo "VMware";   return ;;
      xen)    echo "Xen";      return ;;
      lxc)    echo "LXC";      return ;;
      none)   ;;  # physical hardware — fall through to DMI
    esac
  fi
  # Physical x86: read DMI product name
  if [[ -f /sys/class/dmi/id/product_name ]]; then
    local product
    product=$(tr -d '\0' < /sys/class/dmi/id/product_name 2>/dev/null | xargs)
    if [[ -n "$product" && "$product" != "To Be Filled By O.E.M." && "$product" != "System Product Name" ]]; then
      echo "${product:0:40}"
      return
    fi
  fi
  echo "Unknown ($(uname -m))"
}
hw_type=$(detect_hardware)
#------------------------------------------------------------
#Settings read from the local config file
#Global Simulation settings
#------------------------------------------------------------
#Global Variable Export Enable
set -a
kill_switch=$(get_value 'simulation' 'kill_switch')
rapid_update=$(get_value 'simulation' 'rapid_update')
sim_load=$(get_value 'simulation' 'sim_load')
github_repo=$(get_value 'simulation' 'github_repo')
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
override_keys=(kill_switch sim_load github_repo repo_location vh_server site_based_ssid iperf_bw \
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
#Checking global kill switch — source of truth is linux/kill_switch.txt in the repo,
#synced to this device by update.sh. To kill all simulations globally, set the file
#to "on" in the GitHub repo; update.sh will pull it down on the next cycle.
#------------------------------------------------------------
gkill_switch=$(cat /usr/local/scripts/kill_switch.txt 2>/dev/null || echo "off")
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
# Error accumulator
# WHY: Errors used to only go to log files. The operator has no easy way
# to see log files on 20+ remote clients. Accumulating here and flushing
# in report_status() surfaces them in the webUI dashboard automatically.
# error_log[] holds raw messages (json-escaped) since the last status POST.
#------------------------------------------------------------
declare -a error_log=()

#------------------------------------------------------------
# json_escape: make a string safe to embed in a JSON string literal
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

#------------------------------------------------------------
# report_error: write an error to local logs AND queue it for the API
# Usage: report_error "message" [severity]
# WHY: The biggest operational pain point is not knowing why a client
# can't connect. This ensures those failures appear in the dashboard
# immediately rather than requiring SSH access to read log files.
# The function also triggers an immediate report_status() call so
# the webUI sees the error without waiting for the next loop iteration.
#------------------------------------------------------------
report_error() {
  local msg="$1"
  local severity="${2:-error}"

  # Always write to local files — unchanged from original behavior
  echo "$(date '+%Y-%m-%dT%H:%M:%S') [$severity] $msg" | tee -a "$debug" "$log"

  # Queue for next (or immediate) API report
  error_log+=("$(json_escape "$msg")")

  # Fire an immediate status POST so the webUI sees the error right away.
  # WHY: Without this, errors would only appear on the next periodic report
  # (could be 10–60 seconds away), which is too slow for a live dashboard.
  # We suppress report_error() inside report_status() to avoid infinite recursion.
  _in_report_error=true report_status "${z:-0}" || true
  unset _in_report_error
}

#------------------------------------------------------------
# report_status: POST current state + any queued errors to the webUI API
# WHY: Originally only sent connectivity and sim flags. Now also flushes
# error_log[] so the server can display them per-client in the dashboard.
# error_log[] is cleared after each successful send to avoid duplicates.
#------------------------------------------------------------
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

  # Build the errors JSON array from the accumulated error_log[].
  # WHY: We use a global array rather than a file so there's no I/O overhead
  # on every error, and so the list is naturally cleared on exec-restart.
  local errors_json="[]"
  if [[ ${#error_log[@]} -gt 0 ]]; then
    local joined
    printf -v joined '"%s",' "${error_log[@]}"
    errors_json="[${joined%,}]"
  fi

  local payload
  printf -v payload \
    '{"hostname":"%s","simulation_id":"%s","platform":"%s","iteration":%s,"connected_ssid":"%s","gateway_reachable":%s,"vh_connected":false,"active_simulations":[%s],"errors":%s,"config":{"sim_phy":"%s","kill_switch":"%s","dns_fail":"%s","iperf":"%s","www_traffic":"%s","download":"%s","ping_test":"%s","ssidpw_fail":"%s","auth_fail":"%s","dhcp_fail":"%s"}}' \
    "$(json_escape "$hostname")" \
    "$(json_escape "$simulation_id")" \
    "$(json_escape "$platform")" \
    "$iteration" \
    "$(json_escape "$connected_ssid")" \
    "$gateway_json" \
    "$active_simulations" \
    "$errors_json" \
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

  if curl -m 5 -s -o /dev/null \
        -H "Content-Type: application/json" \
        -X POST --data "$payload" \
        "${server_url%/}/api/status" 2>/dev/null; then
    # Only clear the error log on a successful send to avoid losing errors
    # if the server was temporarily unreachable.
    # WHY: If the server is down when an error fires, we keep it in the buffer
    # so it will be included in the next successful report.
    [[ -z "${_in_report_error:-}" ]] && error_log=()
  fi
  return 0
}
#------------------------------------------------------------
#Getting username from hostname extraction
#changing DHCP Client configuration to send the username as the hostname
#Pure aesthetics so the usernames in Central look good
#------------------------------------------------------------
sudo sed -i "s/gethostname()/\"$username\"/g" /etc/dhcp/dhclient.conf
#------------------------------------------------------------
# Functions
#------------------------------------------------------------

#------------------------------------------------------------
# wait_for_ssid: scan for a target SSID with progressive fallback
# WHY: We scan first, then force a rescan, then toggle the radio.
# Each stage gets longer; we don't toggle the radio immediately
# because that causes a visible gap and is disruptive if other
# connections are active. Errors at each stage go to the API via
# report_error() so the operator can see what's happening in real time.
#------------------------------------------------------------
wait_for_ssid() {
  local target_ssid="$1"
  local timeout=60
  local interval=3
  local elapsed=0
  echo "Scanning for SSID: $target_ssid" | tee -a "$debug"
  # Stage 1: passive scan
  while [ "$elapsed" -lt "$timeout" ]; do
    if nmcli -t -f SSID device wifi list | grep -Fxq "$target_ssid"; then
      echo "SSID found: $target_ssid" | tee -a "$debug"
      return 0
    fi
    sleep "$interval"
    elapsed=$((elapsed + interval))
  done
  # Stage 2: force a rescan — SSID may just not have been advertised yet
  report_error "SSID '$target_ssid' not visible after ${timeout}s — forcing rescan" "warning"
  nmcli device wifi rescan >/dev/null 2>&1
  sleep 2
  if nmcli -t -f SSID device wifi list | grep -Fxq "$target_ssid"; then
    echo "SSID found after rescan: $target_ssid" | tee -a "$debug"
    return 0
  fi
  # Stage 3: toggle the radio — adapter may be in a stuck state
  report_error "SSID '$target_ssid' still missing after rescan — toggling WiFi radio" "warning"
  nmcli radio wifi off
  sleep 3
  nmcli radio wifi on
  sleep 2
  elapsed=0
  while [ "$elapsed" -lt "$timeout" ]; do
    nmcli device wifi rescan >/dev/null 2>&1
    if nmcli -t -f SSID device wifi list | grep -Fxq "$target_ssid"; then
      echo "SSID found after radio toggle: $target_ssid" | tee -a "$debug" "$log"
      return 0
    fi
    sleep "$interval"
    elapsed=$((elapsed + interval))
  done
  # All three stages exhausted — hard failure, surface to API
  report_error "Cannot find SSID '$target_ssid' after scan + rescan + radio toggle" "error"
  return 1
}
#------------------------------------------------------------
#WiFi connections
#------------------------------------------------------------
# connect_wifi: bring up WiFi and connect to the configured SSID
# WHY: We check if we're already connected before doing anything.
# nmcli connect on an already-connected adapter causes a reconnect
# which looks like a brief outage in Central — avoid it.
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
  current_ssid=$(nmcli -t -f active,ssid dev wifi | awk -F: '$1=="yes"{print $2}')
  if [ "$current_ssid" == "$target_ssid" ]; then
    echo "Already connected to $target_ssid — skipping" | tee -a "$debug"
    return 0
  fi
  if ! wait_for_ssid "$target_ssid"; then
    # wait_for_ssid already called report_error(); just propagate the failure
    return 1
  fi
  echo "Attempting to connect to $target_ssid" | tee -a "$debug"
  if ! nmcli device wifi connect "$target_ssid" password "$ssidpw"; then
    report_error "nmcli failed to connect to '$target_ssid' (bad password or AP rejected)" "error"
    return 1
  fi
}
#------------------------------------------------------------
# manage_connection: bring a connection up or down by name
# WHY: Used for auth_fail simulation (rapid up/down) where we need
# fine-grained control over the connection state rather than the adapter.
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
  if [[ "$action" == "up" ]]; then
    wait_for_ssid "$target_ssid" || return 1
  fi
  echo "Attempting to $action connection: $target_ssid" | tee -a "$debug"
  nmcli -w "$wait_time" connection "$action" "$target_ssid"
}
#------------------------------------------------------------
# run_simulation: launch a sub-simulation script in the background
# WHY: nohup + & detaches it so the main loop isn't blocked.
# We check the file exists first to avoid a confusing bash error.
#------------------------------------------------------------
run_simulation() {
 local script=$1
 if [ -f "/usr/local/scripts/$script" ]; then
  nohup bash "/usr/local/scripts/$script" > /dev/null 2>&1 &
 else
  report_error "run_simulation: script not found: $script" "warning"
 fi
}
#------------------------------------------------------------
# Initial WiFi connection attempt before entering the main loop
#------------------------------------------------------------
if ! connect_wifi; then
  report_error "Pre-simulation WiFi connect failed for SSID '$ssid'" "error"
fi
gateway_reachable=false
dfgw=$(ip route | grep -oP 'default via \K\S+' | head -n1)
if [[ -n "$dfgw" ]] && ping -c1 -W1 "$dfgw" >/dev/null 2>&1; then
  gateway_reachable=true
else
  [[ -n "$dfgw" ]] && report_error "Gateway $dfgw unreachable after initial connect" "warning"
fi
#------------------------------------------------------------
#Dumping Current Device List
#------------------------------------------------------------
echo Disabling unused interface | tee -a "$debug"
if [ "$sim_phy" == "ethernet" ]; then sudo ip link set dev $wladapter down; fi
if [ "$sim_phy" == "wireless" ] && [ "$vh_server" == "off" ]; then
  ea_down
fi
echo Generating MAC address | tee -a "$debug"
mac_id=$(echo $HOSTNAME | rev | cut -c 3-4 | rev)
mac_id="${mac_id}:$(echo $HOSTNAME | rev | cut -c 1-2 | rev)"
#------------------------------------------------------------
# Pre-simulation: verify gateway is reachable via the selected interface
# WHY: After connect_wifi succeeds we still need to confirm we got an IP
# and the gateway responds. If this block fails, we attempt VH recovery
# (for wireless sims using VirtualHere USB adapters) then retry.
# dfgw must have head -n1 because 'ip route' can return multiple defaults
# when both eth and wlan are up; taking the first avoids a multi-word ping.
#------------------------------------------------------------
echo "Finding WLAN Adapter" | tee -a "$debug"
wladapter=$(ip -br a | grep "wlx\|wlan" | cut -d ' ' -f '1')
echo "Unblocking WiFi / RFKill" | tee -a "$debug"
sudo rfkill unblock wifi & disown
echo "Getting Default Gateway" | tee -a "$debug"
dfgw=$(ip route | grep -oP 'default via \K\S+' | head -n1)
echo "Pinging Default Gateway: ${dfgw:-(none)}" | tee -a "$debug"
if [[ -n "$dfgw" ]] && ping -c2 -W2 "$dfgw" >/dev/null 2>&1 \
   && [ "$sim_phy" == "wireless" ] && [[ -n "${wladapter}" ]]; then
  echo "Successful network connection - Pre-Simulation" | tee -a "$debug"
else
  # Report which part failed so we can tell from the dashboard
  if [[ -z "$dfgw" ]]; then
    report_error "No default gateway found — no IP assigned after WiFi connect" "error"
  elif ! ping -c1 -W2 "$dfgw" >/dev/null 2>&1; then
    report_error "Gateway $dfgw unreachable (no L3 path after WiFi connect)" "error"
  fi
  echo "Network connection failed - Pre-Simulation" | tee -a "$debug"
  # If VirtualHere is in use, the WiFi adapter came from a USB server.
  # Attempt to reconnect to a VH device before retrying WiFi.
  if [ "$vh_server" == "on" ]; then source '/usr/local/scripts/vhconnect.sh'; fi
  sleep 15
  wladapter=$(ip -br a | grep "wlx\|wlan" | cut -d ' ' -f '1')
  connect_wifi
  sleep 15
  dfgw=$(ip route | grep -oP 'default via \K\S+' | head -n1)
fi
#------------------------------------------------------------
#Begin Setting up simulation load
#------------------------------------------------------------
if [ "${sim_load:-100}" -lt "${rn_sim_load:-0}" ]; then
  echo Simulation load under threshold | tee -a "$debug"
  echo Skipping Simulations but staying associated | tee -a "$debug"
  if [ "$ssidpw_fail" != "on" ] && [[ -n ${wladapter} ]]; then
    manage_connection up 180
  fi
  sleep 5
fi
#------------------------------------------------------------
#End Setting up simulation load
#------------------------------------------------------------
#------------------------------------------------------------
# Main simulation loop — 100 iterations then exec-restarts for fresh config.
# WHY: 100 iterations is a natural checkpoint to reload config, run apt
# updates, and restart cleanly. We exec-restart (not source) so the bash
# call stack stays flat — see comment at the bottom.
#------------------------------------------------------------
echo "Kill Switch is $kill_switch" | tee -a "$debug"
if [ "$kill_switch" == "off" ]; then
 for z in {1..100}; do
  #----------------------------------------------------------
  # Per-iteration gateway check — used by report_error() and to decide
  # whether to skip simulations this cycle.
  #----------------------------------------------------------
  gateway_reachable=false
  dfgw=$(ip route | grep -oP 'default via \K\S+' | head -n1)
  if [[ -n "$dfgw" ]] && ping -c1 -W1 "$dfgw" >/dev/null 2>&1; then
   gateway_reachable=true
  fi
  #------------------------------------------------------------
  # SSID auth-failure simulations (ssidpw_fail / auth_fail)
  # WHY: Grouped together because both deliberately fail the connection.
  # ssidpw_fail appends "_fail" to the password so the AP rejects it.
  # auth_fail does rapid connect/disconnect to simulate MAC block or
  # 802.1X rejection. Both generate the "Auth Fail" Insight in Central.
  # NOTE: Operator-intended operator precedence:
  #   ssidpw_fail=on → enter regardless of wladapter (ethernet sims OK)
  #   auth_fail=on   → only enter when wladapter is present (needs WiFi)
  #------------------------------------------------------------
  if [ "$ssidpw_fail" == "on" ] || [ "$auth_fail" == "on" ] && [[ -n "${wladapter}" ]]; then
    if [ "$ssidpw_fail" == "on" ]; then
     for i in {1..100}; do
      echo "Running SSID Incorrect Password iteration $i/100" | tee -a "$debug"
      ssidpw="$(get_value "$simulation_id" 'ssidpw')_fail"
      # Remove cached PSK profiles so nmcli can't auto-reconnect with the correct password.
      # WHY: Without this, nmcli uses the saved profile and connects successfully,
      # defeating the simulation purpose.
      _psks=$(nmcli -t -f NAME con | grep PSK 2>/dev/null || true)
      [[ -n "$_psks" ]] && sudo nmcli con del "$_psks"
      connect_wifi
     done
    fi
    if [ "$auth_fail" == "on" ]; then
     echo "Running Auth Failure simulation" | tee -a "$debug"
     for i in {1..100}; do
      echo "Auth fail iteration $i/100" | tee -a "$debug"
      _psks=$(nmcli -t -f NAME con | grep PSK 2>/dev/null || true)
      [[ -n "$_psks" ]] && sudo nmcli con del "$_psks"
      manage_connection up 5
      sleep 5
      manage_connection down 5
     done
    fi
   # Restore correct password so the device can reconnect for updates/maintenance
   ssidpw=$(get_value "$simulation_id" 'ssidpw')
   connect_wifi
  else
   #------------------------------------------------------------
   # Normal simulation path — verify gateway, launch sub-simulations
   # WHY: Re-checking gateway here (not just at loop top) because the
   # adapter state can change during a prior iteration (VH reconnect, etc.).
   # Two pings (-c2) tolerate a single dropped packet.
   #------------------------------------------------------------
   dfgw=$(ip route | grep -oP 'default via \K\S+' | head -n1)
   if [[ -n "$dfgw" ]] && ping -c2 -W2 "$dfgw" >/dev/null 2>&1; then
    echo "Successful network connection — In Simulation Loop" | tee -a "$debug"
   else
    report_error "Gateway unreachable in loop (dfgw=${dfgw:-(none)}) — recovery attempt 1" "error"
    echo "Network connection failed — attempting adapter reset" | tee -a "$debug"
    if [ "$vh_server" == "on" ]; then source '/usr/local/scripts/vhconnect.sh'; fi
    sleep 15
    wladapter=$(ip -br a | grep "wlx\|wlan" | cut -d ' ' -f '1')
    # Remove stale PSK profiles before reconnecting.
    # WHY: A cached bad profile causes nmcli to use wrong credentials silently.
    _psks=$(nmcli -t -f NAME con | grep PSK 2>/dev/null || true)
    [[ -n "$_psks" ]] && sudo nmcli con del "$_psks"
    connect_wifi
    echo "WLAN Adapter: $wladapter" | tee -a "$debug"
    sleep 15
    if [[ -n "$dfgw" ]] && ping -c2 -W2 "$dfgw" >/dev/null 2>&1; then
     echo "Successful network connection after adapter reset" | tee -a "$debug"
    else
     # Second consecutive failure — clear VH device cache and restart cleanly.
     report_error "Network still down after adapter reset — clearing VH config and restarting" "error"
     # VH device IDs change when adapters are re-plugged or the VH server restarts.
     # The cache (vhcached.txt) then points to a stale ID causing repeated failures.
     # Clearing it forces a fresh device assignment on the next exec-restart.
     /usr/sbin/vhclientx86_64 -t "STOP USING ALL LOCAL" 2>/dev/null || true
     /usr/sbin/vhclientx86_64 -t "AUTO USE CLEAR ALL"   2>/dev/null || true
     rm -f /usr/local/scripts/vhcached.txt
     _psks=$(nmcli -t -f NAME con | grep PSK 2>/dev/null || true)
     [[ -n "$_psks" ]] && sudo nmcli con del "$_psks"
     # Break exits the for-loop cleanly; exec at the bottom restarts the script.
     # WHY: Using 'source simulation.sh' here would add another call frame inside
     # an already-running for-loop, making it impossible to unwind — use break+exec.
     break
    fi
   fi
   #------------------------------------------------------------
   # Sub-simulation launchers
   # Each is guarded by pgrep so we never launch duplicates.
   # www_traffic is toggled off after launch then re-enabled every 10
   # iterations to recycle Firefox (prevents memory leak in long sessions).
   #------------------------------------------------------------
   if [ "$www_traffic" == "on" ]; then
    if ! pgrep -f "www_traffic.sh" >/dev/null; then
     run_simulation "www_traffic.sh"
     echo "Running WWW Traffic Simulation" | tee -a "$debug" "$log"
     www_traffic="off"
    fi
   fi
   if [ "$ping_test" == "on" ]; then
    if ! pgrep -f "ping_test.sh" >/dev/null; then
     run_simulation "ping_test.sh"
     echo "Running Ping Test Simulation" | tee -a "$debug" "$log"
    fi
   fi
   if [ "$iperf" == "on" ]; then
    if ! pgrep -f "iperf.sh" >/dev/null; then
     run_simulation "iperf.sh"
     echo "Running iPerf Simulation" | tee -a "$debug" "$log"
    fi
   fi
   if [ "$download" == "on" ]; then
    if ! pgrep -f "download.sh" >/dev/null; then
     run_simulation "download.sh"
     echo "Running Download Simulation" | tee -a "$debug" "$log"
    fi
   fi
   if [ "$dns_fail" == "on" ]; then
    if ! pgrep -f "dns_fail.sh" >/dev/null; then
     run_simulation "dns_fail.sh"
     echo "Running DNS Simulation" | tee -a "$debug" "$log"
    fi
   fi
   sleep 10
   if (( z % 10 == 0 )); then
    echo "Closing Firefox (iteration $z — scheduled recycle)" | tee -a "$debug"
    pkill -f firefox 2>/dev/null || true
    www_traffic="on"
   fi
   echo "End of simulation loop iteration $z/100" | tee -a "$debug"
   # rapid_update=on  → update every iteration (dev/testing; version check keeps it lightweight)
   # rapid_update=off → update only at exec-restart every 100 iterations (production default;
   #                    avoids hammering update services during normal operation)
   if [ "$rapid_update" == "on" ]; then source '/usr/local/scripts/update.sh'; fi
   echo "Sleeping 5 seconds" | tee -a "$debug"
   sleep 5
  fi
 done
else
 #------------------------------------------------------------
 # Kill switch active — park, report, then fall through to exec-restart.
 # WHY: We don't loop here; instead we restart so a config change
 # (kill_switch=off) is picked up on the next exec-restart cycle.
 #------------------------------------------------------------
 echo "Kill switch enabled — parking for 5 minutes" | tee -a "$debug"
 report_error "Kill switch is ON — all simulations suspended" "warning"
 sleep 300
fi
#------------------------------------------------------------
# Post-loop: cleanup, background updates, optional offline period
#------------------------------------------------------------
echo "Closing Firefox" | tee -a "$debug"
pkill -f firefox 2>/dev/null &
echo "Running Updates" | tee -a "$debug"
bash /usr/local/scripts/apt_update.sh &
if [ "$allow_offline" == "on" ]; then
  #------------------------------------------------------------
  # allow_offline: take all interfaces down for a random period.
  # WHY: Devices that are always-connected get flagged as IoT by some
  # network visibility tools. Going offline makes them look like real
  # user devices that leave the office or sleep. Duration is
  # rn_offline_time (random 1-14400 seconds = up to 4 hours).
  #------------------------------------------------------------
  echo "Bringing all interfaces down (allow_offline mode)" | tee -a "$debug"
  if [[ -n "${wladapter}" ]]; then sudo ip link set dev "$wladapter" down; fi
  ea_down
  echo "Sleeping for $rn_offline_time seconds" | tee -a "$debug"
  sleep "$rn_offline_time"
  echo "Bringing all interfaces back online" | tee -a "$debug"
  if [[ -n "${eadapter}" ]]; then sudo ip link set dev "$eadapter" up; fi
  if [[ -n "${wladapter}" ]]; then sudo ip link set dev "$wladapter" up; fi
fi
#------------------------------------------------------------
# Restart via exec — replaces this process without growing the call stack.
# WHY: The original code used 'source simulation.sh' which adds a new bash
# call frame every 100 iterations. Over long runtimes (hours/days) this
# exhausts bash's recursion limit and crashes the simulation silently.
# 'exec bash simulation.sh' replaces the current process entirely:
#   - same PID stays visible in the terminal / dashboard
#   - zero stack growth
#   - fresh variable state including re-reading simulation.conf
#------------------------------------------------------------
exec bash /usr/local/scripts/simulation.sh
