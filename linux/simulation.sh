#!/bin/bash
version=.91
echo $(date) | tee -a /usr/local/scripts/sim.log
echo ------------------------------| tee -a /usr/local/scripts/sim.log
echo Simulation Script Version $version | tee -a /usr/local/scripts/sim.log
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
if [[ -n ${wladapter} ]]; then echo WLAN Adapter name $wladapter | tee -a /usr/local/scripts/sim.log; fi
eadapter=$(ip -br a | grep "enp\|eno\|eth0\|eth1\|eth2\|eth3\|eth4\|eth5\|eth6" | cut -d ' ' -f '1')
if [[ -n ${eadapter} ]]; then echo Wired Adapter name $eadapter | tee -a /usr/local/scripts/sim.log; fi
#------------------------------------------------------------
echo Parsing Config File | tee -a /usr/local/scripts/sim.log
#------------------------------------------------------------
#Settings read from the local config file
#Global Simulation settings
#------------------------------------------------------------
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
#End User/Device Specific Overrides
#------------------------------------------------------------
echo $(date) | tee -a /usr/local/scripts/sim.log
echo ------------------------------| tee -a /usr/local/scripts/sim.log
echo Simulation Details: | tee -a /usr/local/scripts/sim.log
echo Hostname: $HOSTNAME | tee -a /usr/local/scripts/sim.log
echo Site: $wsite | tee -a /usr/local/scripts/sim.log
echo Site Based SSID: $site_based_ssid | tee -a /usr/local/scripts/sim.log
echo VHServer: $vh_server | tee -a /usr/local/scripts/sim.log
if [ $vh_server == "off" ]; then echo Phy: $sim_phy | tee -a /usr/local/scripts/sim.log; fi
if [ $sim_phy == "wireless" ] && [[ -n ${wladapter} ]]; then echo Adapter: $wladapter | tee -a /usr/local/scripts/sim.log; fi
echo Simulation Load: $sim_load | tee -a /usr/local/scripts/sim.log
echo Kill Switch: $kill_switch | tee -a /usr/local/scripts/sim.log
echo DHCP Fail: $dhcp_fail | tee -a /usr/local/scripts/sim.log
echo DNS Fail: $dns_fail | tee -a /usr/local/scripts/sim.log
echo WWW Traffic: $www_traffic | tee -a /usr/local/scripts/sim.log
echo iPerf: $iperf | tee -a /usr/local/scripts/sim.log
echo Download: $download | tee -a /usr/local/scripts/sim.log
echo Port Flap: $port_flap | tee -a /usr/local/scripts/sim.log
echo Incorrect SSID PW: $ssidpw_fail | tee -a /usr/local/scripts/sim.log
echo ------------------------------| tee -a /usr/local/scripts/sim.log
sleep 5
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
#------------------------------------------------------------
#Getting username from hostname extraction
#changing DHCP Client configuration to send the username as the hostname
#Pure aesthetics so the usernames in Central look good
#------------------------------------------------------------
sudo sed -i "s/gethostname()/\"$username\"/g" /etc/dhcp/dhclient.conf
#------------------------------------------------------------
#Functions
#------------------------------------------------------------
#WiFi connections
#------------------------------------------------------------
connect_wifi() {
  nmcli radio wifi off
  nmcli radio wifi on
  sleep 15
  if [ $site_based_ssid == "on" ]; then
    nmcli -w $1 device wifi connect $wsite"-"$ssid password $ssidpw
  else
    nmcli -w $1 device wifi connect $ssid password $ssidpw
  fi
}
#------------------------------------------------------------
#Connection management
#------------------------------------------------------------
manage_connection() {
  local action=$1
  local wait_time=$2
  nmcli radio wifi off
  nmcli radio wifi on
  sleep 15
  if [ $site_based_ssid == "on" ]; then
    nmcli -w $wait_time connection $action $wsite"-"$ssid
  else
    nmcli -w $wait_time connection $action $ssid
  fi
}
#------------------------------------------------------------
#Run simulation scripts
#------------------------------------------------------------
run_simulation() {
 local script=$1
 local sleep_time=$2
 if [ -f "/usr/local/scripts/$script" ]; then
  nohup bash "/usr/local/scripts/$script" >> /usr/local/scripts/sim.log 2>&1 &
  sleep $sleep_time
 fi
}
#------------------------------------------------------------
#Attempting WiFi connection
#------------------------------------------------------------
connect_wifi 10
#------------------------------------------------------------
#Dumping Current Device List
#------------------------------------------------------------
echo Disabling unused interface | tee -a /usr/local/scripts/sim.log
if [ $sim_phy == "ethernet" ]; then sudo ip link set dev $wladapter down; fi
if [ $sim_phy == "wireless" ] && [ $vh_server == "off" ]; then sudo ip link set dev $eadapter down; fi
mac_id=$(echo $HOSTNAME | rev | cut -c 3-4 | rev)
mac_id="${mac_id}:$(echo $HOSTNAME | rev | cut -c 1-2 | rev)"
#------------------------------------------------------------
#Checking to see if the default gateway is reachable
#------------------------------------------------------------
wladapter=$(ip -br a | grep "wlx\|wlan" | cut -d ' ' -f '1')
sudo rfkill unblock wifi; sudo rfkill unblock all
dfgw=$(ip route | grep -oP 'default via \K\S+')
ping -c2 $dfgw
if [ $? -eq 0 ] && [ $sim_phy == "wireless" ] && [[ -n ${wladapter} ]]; then
 echo Successful network connection | tee -a /usr/local/scripts/sim.log
else
  echo Network connection failed | tee -a /usr/local/scripts/sim.log
  #------------------------------------------------------------
  #If VH is enabled then attempt to connect to VHServer
  #------------------------------------------------------------
  if [ $vh_server == "on" ]; then source '/usr/local/scripts/vhconnect.sh'; fi
  #------------------------------------------------------------
  #End Connecting to VHServer
  #------------------------------------------------------------
  sleep 15
  wladapter=$(ip -br a | grep "wlx\|wlan" | cut -d ' ' -f '1')
  connect_wifi 180
  sleep 15
  dfgw=$(ip route | grep -oP 'default via \K\S+')
fi
#------------------------------------------------------------
#Begin Setting up simulation load
#------------------------------------------------------------
if [ $sim_load -lt $rn_sim_load ]; then
  echo Simulation load under threshold | tee -a /usr/local/scripts/sim.log
  echo Skipping Simulations but staying associated | tee -a /usr/local/scripts/sim.log
  if [ $ssidpw_fail != "on" ] && [[ -n ${wladapter} ]]; then
    manage_connection up 180
  fi
  sleep 5
fi
#------------------------------------------------------------
#End Setting up simulation load
#------------------------------------------------------------
echo Kill Switch is $kill_switch | tee -a /usr/local/scripts/sim.log
if [ $kill_switch == "off" ]; then
 for z in {1..100}; do
  #------------------------------------------------------------
  #SSID Incorrect Password Simulation or Auth Failure Simulation
  #since these are very similar they are in the same section one
  #has a bad PSK and others have a blocked mac or invalud username/password combo
  #both need to be constantly connecting so we trigger insights
  #------------------------------------------------------------
  if [ $ssidpw_fail == "on" ] || [ $auth_fail == "on" ] && [[ -n ${wladapter} ]]; then
    if [ $ssidpw_fail == "on" ]; then
     for i in {1..100}; do
      echo Running SSID Incorrect Password | tee -a /usr/local/scripts/sim.log
      ssidpw="$(get_value $simulation_id 'ssidpw')""_fail"
      echo Iteration $i of 100 | tee -a /usr/local/scripts/sim.log
      sudo nmcli con del $(nmcli -t -f NAME con | grep PSK)
      connect_wifi 10
     done
    fi
    if [ $auth_fail == "on" ]; then
     echo Running Auth Failure | tee -a /usr/local/scripts/sim.log
     for i in {1..100}; do
      echo Enable/Disable WLAN interface | tee -a /usr/local/scripts/sim.log
      echo Iteration $i of 100 | tee -a /usr/local/scripts/sim.log
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
   connect_wifi 5
   #------------------------------------------------------------
   #End SSID Incorrect Password Simualtion or Auth Failure Simulation
   #------------------------------------------------------------
  else
   #------------------------------------------------------------
   #If SSID Incorrect Password Sim is not triggered then check
   #for the other simualtions
   #------------------------------------------------------------
   ping -c2 $dfgw
   if [ $? -eq 0 ]; then
    echo Successful network connection | tee -a /usr/local/scripts/sim.log
    else
     echo Network connection failed | tee -a /usr/local/scripts/sim.log
     echo Attempting to reset adapter | tee -a /usr/local/scripts/sim.log
     if [ $vh_server == "on" ]; then source '/usr/local/scripts/vhconnect.sh'; fi
     sleep 15
     wladapter=$(ip -br a | grep "wlx\|wlan" | cut -d ' ' -f '1')
     sudo nmcli con del $(nmcli -t -f NAME con | grep PSK)
     connect_wifi 180
     echo WLAN Adapter name $wladapter | tee -a /usr/local/scripts/sim.log
     sleep 15
    fi
    dfgw=$(ip route | grep -oP 'default via \K\S+')
    ping -c2 $dfgw
    if [ $? -eq 0 ]; then
     echo Successful network connection | tee -a /usr/local/scripts/sim.log
    else
    echo Connection failed muiltiple times | tee -a /usr/local/scripts/sim.log
    echo Resetting configuration | tee -a /usr/local/scripts/sim.log
    echo Purging VHConfig | tee -a /usr/local/scripts/sim.log
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
    rm /usr/local/scripts/vhcached.txt
    #------------------------------------------------------------
    #Cleaning up old network connection profiles
    #------------------------------------------------------------
    sudo nmcli con del $(nmcli -t -f NAME con | grep PSK)
    #------------------------------------------------------------
    #Looping Script - Network Connectivity Failed
    #------------------------------------------------------------
    source /usr/local/scripts/simulation.sh
   fi
   #------------------------------------------------------------
   #End Connecting to Network
   #------------------------------------------------------------
   #Running WWW Traffic Simulation
   #------------------------------------------------------------
    if [ $www_traffic == "on" ]; then
     echo Running WWW Traffic simulation
     wwwfile=($(< /usr/local/scripts/websites.txt))
     rn_www=$((RANDOM % ${#wwwfile[@]}))
     url="${wwwfile[$rn_www]}"
     echo $(date) | tee -a /usr/local/scripts/sim.log
     echo ------------------------------| tee -a /usr/local/scripts/sim.log
     if [ $vh_server == "off" ]; then echo Phy: $sim_phy | tee -a /usr/local/scripts/sim.log; fi
     echo Simulation Load: $sim_load | tee -a /usr/local/scripts/sim.log
     echo Website: $url | tee -a /usr/local/scripts/sim.log
     echo ------------------------------| tee -a /usr/local/scripts/sim.log
     firefox --headless $url &
     www_traffic=off
    fi
   #------------------------------------------------------------
   #End WWW Traffic Simulation
   #------------------------------------------------------------
   #Running ping simulation
   #------------------------------------------------------------
   if [ $ping_test == "on" ]; then
    echo $(date) | tee -a /usr/local/scripts/sim.log
    echo ------------------------------| tee -a /usr/local/scripts/sim.log
    echo Ping Address: $ping_address | tee -a /usr/local/scripts/sim.log
    echo Ping Payload: $rn_ping_size | tee -a /usr/local/scripts/sim.log
    echo Ping Count: $rn | tee -a /usr/local/scripts/sim.log
    echo ------------------------------| tee -a /usr/local/scripts/sim.log
    ping -c $rn $ping_address -s $rn_ping_size &
   fi
   #------------------------------------------------------------
   #End Ping Simulation

    #Running iPerf simulation
    #------------------------------------------------------------
    if [ $iperf == "on" ]; then
     run_simulation "iperf.sh" 30
    fi
    #------------------------------------------------------------
    #Running download simulation
    #------------------------------------------------------------
    if [ $download == "on" ]; then
     run_simulation "download.sh" 30
    fi
    #------------------------------------------------------------
    #Running DNS Fail simulation
    #------------------------------------------------------------
    if [ $dns_fail == "on" ]; then
     run_simulation "dns_fail.sh" 30
    fi
   #------------------------------------------------------------
   #End DNS Fail Simulation
   #------------------------------------------------------------
   echo End of simulation | tee -a /usr/local/scripts/sim.log
   #------------------------------------------------------------
   #Running update to either the cloud repo or local SMB repo
   #------------------------------------------------------------
   if [ $rapid_update == "on" ]; then source '/usr/local/scripts/update.sh'; fi
   #------------------------------------------------------------
   #End Script Updates
   #------------------------------------------------------------
   echo Sleeping for 5 seconds | tee -a /usr/local/scripts/sim.log
   echo Loop iteration $z of 100 | tee -a /usr/local/scripts/sim.log
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
 echo Kill switch enabled - sleeping for 5 minutes
 sleep 300
fi
#------------------------------------------------------------
#Killing Firefox simulation
#------------------------------------------------------------
echo Closing Firefox | tee -a /usr/local/scripts/sim.log
pkill -f firefox &
#------------------------------------------------------------
#End Kill switch Check 
#------------------------------------------------------------
#------------------------------------------------------------
#Running apt update & apt upgrade
#------------------------------------------------------------
echo Running Updates | tee -a /usr/local/scripts/sim.log
bash /usr/local/scripts/apt_update.sh &
if [ $allow_offline == "yes" ]; then
  #------------------------------------------------------------
  #Bringing all interfaces down to make it look like the device is offline.
  #Otherwise they get triggered as IOT since they are always connected.
  #------------------------------------------------------------
  echo Bringing all interfaces down | tee -a /usr/local/scripts/sim.log
  if [[ -n ${wladapter} ]]; then sudo ip link set dev $wladapter down; fi
  if [[ -n ${eadapter} ]]; then sudo ip link set dev $eadapter down; fi
  echo Sleeping for $rn_offline_time seconds
  echo ------------------------------| tee -a /usr/local/scripts/sim.log
  #------------------------------------------------------------
  #Sleep for up to 4 hours to show the device left
  #------------------------------------------------------------
  sleep $rn_offline_time
  #------------------------------------------------------------
  #Bringing all interfaces back up to call home/update scripts
  #------------------------------------------------------------
  echo Bringing all interfaces online | tee -a /usr/local/scripts/sim.log
  if [[ -n ${eadapter} ]]; then sudo ip link set dev $eadapter up; fi
  if [[ -n ${wladapter} ]]; then sudo ip link set dev $wladapter up; fi
  echo ------------------------------| tee -a /usr/local/scripts/sim.log
fi
#------------------------------------------------------------
#Looping Script
#------------------------------------------------------------
source /usr/local/scripts/simulation.sh