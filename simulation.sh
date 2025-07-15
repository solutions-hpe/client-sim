#!/bin/bash
version=.69
echo $(date) | tee -a /usr/local/scripts/sim.log
echo ------------------------------| tee -a /usr/local/scripts/sim.log
echo Simulation Script Version $version | tee -a /usr/local/scripts/sim.log
echo Reading Simulation Config File | tee -a /usr/local/scripts/sim.log
#------------------------------------------------------------
#Calling config parser script - reads the simulation.conf file
#For values assinged to script variables
#------------------------------------------------------------
source '/usr/local/scripts/ini-parser.sh'
#------------------------------------------------------------
#Running update to either the cloud repo or local SMB repo
#------------------------------------------------------------
source '/usr/local/scripts/update.sh'
#------------------------------------------------------------
#Setting config file location
#------------------------------------------------------------
process_ini_file '/usr/local/scripts/simulation.conf'
#------------------------------------------------------------
#Finding adapter names and setting usable variables for interfaces
#When using a physical piece of hardware we want to diable the
#interface not in use. So that we force the traffic out the interface 
#set int he simulation.conf
#------------------------------------------------------------
wladapter=$(ifconfig -a | grep "wlx\|wlan" | cut -d ':' -f '1')
echo WLAN Adapter name $wladapter | tee -a /usr/local/scripts/sim.log
eadapter=$(ifconfig -a | grep "enp\|eno\|eth0\|eth1\|eth2\|eth3\|eth4\|eth5\|eth6" | cut -d ':' -f '1')
echo Wired Adapter name $eadapter | tee -a /usr/local/scripts/sim.log
#------------------------------------------------------------
#DO NOT EDIT BELOW THIS LINE UNLESS YOU KNOW WHAT YOU ARE DOING
#------------------------------------------------------------
echo Parsing Config File | tee -a /usr/local/scripts/sim.log
site_based_num=$(get_value 'simulation' 'site_based_num')
simulation_id=s
simulation_id+=$(echo $HOSTNAME | rev | cut -c 1-$site_based_num | rev | cut -c 1-1)
#------------------------------------------------------------
#Settings read from the local config file
#Global Simulation settings
#------------------------------------------------------------
kill_switch=$(get_value 'simulation' 'kill_switch')
sim_load=$(get_value 'simulation' 'sim_load')
public_repo=$(get_value 'simulation' 'public_repo')
vh_server=$(get_value 'simulation' 'vh_server')
site_based_ssid=$(get_value 'simulation' 'site_based_ssid')
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
#Pure asthetics so the usernames in Central look good
#------------------------------------------------------------
username=$(echo $HOSTNAME | cut -d "-" -f 1)
sudo sed -i "s/gethostname()/$username/g" /etc/dhcp/dhclient.conf
#------------------------------------------------------------
#Dumping Current Device List
#------------------------------------------------------------
echo Disabling unused interface | tee -a /usr/local/scripts/sim.log
if [ $sim_phy == "ethernet" ]; then sudo ifconfig $wladapter down; fi
if [ $sim_phy == "wireless" ] && [ $vh_server == "off" ]; then sudo ifconfig $eadapter down; fi
mac_id=$(echo $HOSTNAME | rev | cut -c 3-4 | rev)
mac_id="${mac_id}:$(echo $HOSTNAME | rev | cut -c 1-2 | rev)"
if [ $sim_phy == "wireless" ] && [ $vh_server == "on" ]; then
 sudo ip link set wlan0 down
 sudo ip link set wlan0 address e8:4e:06:ac:$mac_id
 sudo ip link set wlan0 up
 echo Set MAC to e8:4e:06:ac:$mac_id | tee -a /usr/local/scripts/sim.log
fi
#------------------------------------------------------------
#Checking for kill switch to stop simulation
#------------------------------------------------------------
#Connecting to VHServer
#Checking to see if google is reachable before 
#------------------------------------------------------------
inet_check=www.google.com
ping -c2 $inet_check
if [ $? -eq 0 ]; then 
 echo Successful network connection | tee -a /usr/local/scripts/sim.log
else
 echo Network connection failed | tee -a /usr/local/scripts/sim.log
 if [ $vh_server == "on" ]; then source '/usr/local/scripts/vhconnect.sh'; fi
 if [ $sim_phy == "wireless" ] && [ $vh_server == "on" ]; then
  sudo ip link set wlan0 down
  sleep 1
  sudo ip link set wlan0 address e8:4e:06:ac:$mac_id
  sleep 1
  sudo ip link set wlan0 up
  sleep 1
  echo Set MAC to e8:4e:06:ac:$mac_id | tee -a /usr/local/scripts/sim.log
 fi
fi
#------------------------------------------------------------
#End Connecting to VHServer
#------------------------------------------------------------
#------------------------------------------------------------
#Connecting to Network
#------------------------------------------------------------
if [ $sim_phy == "wireless" ]; then
  sudo rfkill unblock wifi; sudo rfkill unblock all
  echo Setting up WiFi Adapter | tee -a /usr/local/scripts/sim.log
  nmcli radio wifi on
  sleep 10
  echo Connecting to Network | tee -a /usr/local/scripts/sim.log
  if [ $site_based_ssid == "on" ]; then nmcli device wifi connect ${wsite}"-"${ssid} password $ssidpw; fi
  if [ $site_based_ssid != "on" ]; then nmcli device wifi connect $ssid password $ssidpw; fi
  nmcli device wifi rescan
  sleep 5
  if [ $site_based_ssid == "on" ]; then nmcli connection up ${wsite}"-"${ssid}; fi
  if [ $site_based_ssid != "on" ]; then nmcli connection up $ssid; fi
  echo Waiting for Network | tee -a /usr/local/scripts/sim.log
  echo ------------------------------| tee -a /usr/local/scripts/sim.log
  sleep 15
fi
#------------------------------------------------------------
#End Connecting to Network
#------------------------------------------------------------
#------------------------------------------------------------
#Begin Setting up simulation load
#------------------------------------------------------------
if [ $sim_load -lt $rn_sim_load ]; then
  echo Simulation load under threshold | tee -a /usr/local/scripts/sim.log
  echo Skipping Simulations but staying associated | tee -a /usr/local/scripts/sim.log
  nmcli radio wifi off
  sleep $rn_offline_time
  nmcli radio wifi on
  sleep 5
  if [ $site_based_ssid == "on" ]; then nmcli connection up ${wsite}"-"${ssid}; fi
  if [ $site_based_ssid != "on" ]; then nmcli connection up $ssid; fi
  sleep 5
fi
#------------------------------------------------------------
#End Setting up simulation load
#------------------------------------------------------------
echo Kill Switch is $kill_switch | tee -a /usr/local/scripts/sim.log
if [ $kill_switch == "off" ]; then
  for z in {1..100}; do
    #------------------------------------------------------------ 
    #Logging Simulation
    #------------------------------------------------------------ 
    echo $(date) | tee -a /usr/local/scripts/sim.log
    echo ------------------------------| tee -a /usr/local/scripts/sim.log
    echo Simulation Details: | tee -a /usr/local/scripts/sim.log
    echo Hostname: $HOSTNAME | tee -a /usr/local/scripts/sim.log
    echo Site: $wsite | tee -a /usr/local/scripts/sim.log
    if [ $vh_server == "off" ]; then echo Phy: $sim_phy | tee -a /usr/local/scripts/sim.log; fi
    echo Simulation Load: $sim_load | tee -a /usr/local/scripts/sim.log
    echo Kill Switch: $kill_switch | tee -a /usr/local/scripts/sim.log
    echo DHCP Fail: $dhcp_fail | tee -a /usr/local/scripts/sim.log
    echo DNS Fail: $dns_fail | tee -a /usr/local/scripts/sim.log
    echo WWW Traffic: $www_traffic | tee -a /usr/local/scripts/sim.log
    echo iPerf: $iperf | tee -a /usr/local/scripts/sim.log
    echo Download: $download | tee -a /usr/local/scripts/sim.log
    echo Port Flap: $port_flap | tee -a /usr/local/scripts/sim.log
    echo ------------------------------| tee -a /usr/local/scripts/sim.log
    inet_check=www.google.com
    ping -c2 $inet_check
    if [ $? -eq 0 ]; then
     echo Successful network connection | tee -a /usr/local/scripts/sim.log
    else
     echo Network connection failed | tee -a /usr/local/scripts/sim.log
     echo Attempting to reset adapter | tee -a /usr/local/scripts/sim.log
     if [ $sim_phy == "wireless" ]; then
      nmcli radio wifi off
      nmcli radio wifi on
      sleep 5
       if [ $site_based_ssid != "on" ]; then nmcli connection up $ssid; fi
       if [ $site_based_ssid == "on" ]; then nmcli connection up ${wsite}"-"${ssid}; fi
     fi
     sleep 30
     ping -c2 $inet_check
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
    fi
    #------------------------------------------------------------
    #End Connecting to Network
    #------------------------------------------------------------
    #Running WWW Traffic Simulation
    #------------------------------------------------------------
    if [ $www_traffic == "on" ]; then
      r_count=0
      echo Running WWW Traffic simulation
      wwwfile=$(cat /usr/local/scripts/websites.txt)
      #------------------------------------------------------------
      #Counting the number of records in the text file
      #That way we know how many records to randomly select from
      #------------------------------------------------------------
      for r in $wwwfile; do r_count=$((r_count+1)); done
      #------------------------------------------------------------
      #Picking a random number between 1 and the number of records 
      #in the text file. Adding 1 in case the random was 0 and setting
      #the max to the number of entries in the txt file
      #------------------------------------------------------------
      rn_www=$((1 + RANDOM % $r_count))
      r_count=0
      for r in $wwwfile; do
	r_count=$((r_count+1))
	if [[ $r_count == $rn_www ]]; then
	  echo Closing Firefox | tee -a /usr/local/scripts/sim.log
	  pkill -f firefox
	  sleep 1
	  echo $(date) | tee -a /usr/local/scripts/sim.log
	  echo ------------------------------| tee -a /usr/local/scripts/sim.log
	  echo Simulation Details: | tee -a /usr/local/scripts/sim.log
	  echo Hostname: $HOSTNAME | tee -a /usr/local/scripts/sim.log
	  echo Site: $wsite | tee -a /usr/local/scripts/sim.log	  		
	  if [ $vh_server == "off" ]; then echo Phy: $sim_phy | tee -a /usr/local/scripts/sim.log; fi
	  echo Simulation Load: $sim_load | tee -a /usr/local/scripts/sim.log
	  echo Website: $r | tee -a /usr/local/scripts/sim.log
	  echo ------------------------------| tee -a /usr/local/scripts/sim.log
	  www_traffic=off
	fi
      done
    fi
    #------------------------------------------------------------
    #End WWW Traffic Simulation	 
    #------------------------------------------------------------
    #Running ping simulation
    #------------------------------------------------------------
    if [ $ping_test == "on" ]; then
      echo $(date) | tee -a /usr/local/scripts/sim.log
      echo ------------------------------| tee -a /usr/local/scripts/sim.log
      echo Simulation Details: | tee -a /usr/local/scripts/sim.log
      echo Hostname: $HOSTNAME | tee -a /usr/local/scripts/sim.log
      echo Site: $wsite | tee -a /usr/local/scripts/sim.log
      if [ $vh_server == "off" ]; then echo Phy: $sim_phy | tee -a /usr/local/scripts/sim.log; fi		
      echo Simulation Load: $sim_load | tee -a /usr/local/scripts/sim.log
      echo Kill Switch: $kill_switch | tee -a /usr/local/scripts/sim.log
      echo Ping Address: $ping_address | tee -a /usr/local/scripts/sim.log
      echo Ping Payload: $rn_ping_size | tee -a /usr/local/scripts/sim.log
      echo Ping Count: $rn | tee -a /usr/local/scripts/sim.log
      echo ------------------------------| tee -a /usr/local/scripts/sim.log
      ping -c $rn $ping_address -s $rn_ping_size
    fi
    #------------------------------------------------------------
    #End Ping Simulation
    #------------------------------------------------------------
    #------------------------------------------------------------
    #Running iPerf simulation
    #------------------------------------------------------------
    if [ $iperf == "on" ]; then
      echo $(date) | tee -a /usr/local/scripts/sim.log
      echo ------------------------------| tee -a /usr/local/scripts/sim.log
      echo Simulation Details: | tee -a /usr/local/scripts/sim.log
      echo Hostname: $HOSTNAME | tee -a /usr/local/scripts/sim.log
      echo Site: $wsite | tee -a /usr/local/scripts/sim.log
      if [ $vh_server == "off" ]; then echo Phy: $sim_phy | tee -a /usr/local/scripts/sim.log; fi
      echo Simulation Load: $sim_load | tee -a /usr/local/scripts/sim.log
      echo Kill Switch: $kill_switch | tee -a /usr/local/scripts/sim.log
      echo iPerf Server: $iperf_server | tee -a /usr/local/scripts/sim.log
      echo iPerf Port: $rn_iperf_port | tee -a /usr/local/scripts/sim.log
      echo iPerf Time: $rn_iperf_time | tee -a /usr/local/scripts/sim.log
      echo Running iPerf simulation: | tee -a /usr/local/scripts/sim.log
      echo ------------------------------| tee -a /usr/local/scripts/sim.log
      iperf3 -u -c $iperf_server -p $rn_iperf_port -t $rn_iperf_time
      iperf3 -c $iperf_server -p 443 -t $rn_iperf_time
      iperf3 -c $iperf_server -p 3260 -t $rn_iperf_time
      iperf3 -c $iperf_server -p 2049 -t $rn_iperf_time
      iperf3 -c $iperf_server -p 1194 -t $rn_iperf_time
      iperf3 -c $iperf_server -p 3389 -t $rn_iperf_time
      iperf3 -c $iperf_server -p 445 -t $rn_iperf_time
      iperf3 -c $iperf_server -p 80 -t $rn_iperf_time
      iperf3 -c $iperf_server -p 1433 -t $rn_iperf_time
    fi
    #------------------------------------------------------------
    #End iPerf Simulation
    #------------------------------------------------------------
    #------------------------------------------------------------
    #Running download simulation
    #------------------------------------------------------------
    if [ $download == "on" ]; then
      r_count=0
      echo Running Download simulation
      dlfile=$(cat /usr/local/scripts/downloads.txt)
      for r in $dlfile; do r_count=$((r_count+1)); done
      rn_dl=$((1 + RANDOM % $r_count))
      r_count=0
      for r in $dlfile; do
	r_count=$((r_count+1))
	if [[ $r_count == $rn_dl ]]; then
	  sleep 1
	  echo $(date) | tee -a /usr/local/scripts/sim.log
	  echo ------------------------------| tee -a /usr/local/scripts/sim.log
	  echo Simulation Details: | tee -a /usr/local/scripts/sim.log
	  echo Hostname: $HOSTNAME | tee -a /usr/local/scripts/sim.log
	  echo Site: $wsite | tee -a /usr/local/scripts/sim.log	  		
	  echo Phy: $sim_phy | tee -a /usr/local/scripts/sim.log
	  echo Simulation Load: $sim_load | tee -a /usr/local/scripts/sim.log
	  echo Running Download Simulation: | tee -a /usr/local/scripts/sim.log
	  echo ------------------------------| tee -a /usr/local/scripts/sim.log
	  wget --waitretry=10 --read-timeout=20 --show-progress -O /tmp/file.tmp $r | tee -a /usr/local/scripts/sim.log
	fi
      done
    fi
    #------------------------------------------------------------
    #Running apt update & apt upgrade
    #------------------------------------------------------------
    echo Running Updates | tee -a /usr/local/scripts/sim.log
    sudo apt update
    sudo apt remove sysstat -y
    sudo apt upgrade -y
    sudo apt install git -y
    sudo apt install wget -y
    sudo apt install gnome-terminal -y
    sudo apt install network-manager -y
    sudo apt install qemu-guest-agent -y
    sudo apt install net-tools -y
    sudo apt install smbclient -y
    sudo apt install dnsutils -y
    sudo apt install dkms -y
    sudo apt install iperf3 -y
    sudo apt install firefox-esr -y
    sudo apt autoremove -y
    #------------------------------------------------------------
    #End Download Simulation
    #------------------------------------------------------------
    #Running DNS Fail simulation
    #------------------------------------------------------------
    if [ $dns_fail == "on" ]; then
      dnsfile=$(cat /usr/local/scripts/dns_fail.txt)
      for i in {1..100}; do
	for r in $dnsfile; do
	  echo $(date) | tee -a /usr/local/scripts/sim.log
	  echo ------------------------------| tee -a /usr/local/scripts/sim.log
	  echo Simulation Details: | tee -a /usr/local/scripts/sim.log
	  echo Hostname: $HOSTNAME | tee -a /usr/local/scripts/sim.log
	  echo Site: $wsite | tee -a /usr/local/scripts/sim.log
	  if [ $vh_server == "off" ]; then echo Phy: $sim_phy | tee -a /usr/local/scripts/sim.log; fi
	  echo Simulation Load: $sim_load | tee -a /usr/local/scripts/sim.log
	  echo Kill Switch: $kill_switch | tee -a /usr/local/scripts/sim.log
	  echo DNS Fail: $dns_fail | tee -a /usr/local/scripts/sim.log
	  echo Running DNS Failure: | tee -a /usr/local/scripts/sim.log
	  echo Simulation Iteration: $i | tee -a /usr/local/scripts/sim.log
	  echo $r | tee -a /usr/local/scripts/sim.log
	  echo ------------------------------| tee -a /usr/local/scripts/sim.log
	  dig @$dns_bad_record_1 $r &
	  dig @$dns_bad_record_2 $r &
	  dig @$dns_bad_record_3 $r &
	  dig @$dns_bad_ip_1 $r &
	  dig @$dns_bad_ip_2 $r &
	  dig @$dns_bad_ip_3 $r &
	  dig @$dns_latency_1 $r &
	  dig @$dns_latency_2 $r &
	  dig @$dns_latency_3 $r &
	  sleep 5
	done
      done
    fi
    #------------------------------------------------------------
    #End DNS Fail Simulation
    #------------------------------------------------------------
    echo End of simulation sleeping for 5 seconds
    sleep 5
    #------------------------------------------------------------
    #End of 100 Loop Count
    #------------------------------------------------------------
  done
else
  #------------------------------------------------------------
  #If kill switch is enabled - sleeping for 5 minutes then restarting the loop
  #------------------------------------------------------------
  echo Kill switch enabled - sleeping for 5 minutes
  sleep 300
fi
#------------------------------------------------------------
#End Kill switch Check 
#------------------------------------------------------------
#Bringing all interfaces down to make it look like the device is offline. 
#Otherwise they get triggered as IOT since they are always connected.
#------------------------------------------------------------
echo Bringing all interfaces down | tee -a /usr/local/scripts/sim.log
sudo ifconfig $eadapter down
sudo ifconfig $wladapter down
echo Sleeping for $rn_offlinetime seconds
echo ------------------------------| tee -a /usr/local/scripts/sim.log
#------------------------------------------------------------
#Sleep for up to 4 hours to show the device left
#------------------------------------------------------------
sleep $rn_offlinetime
#------------------------------------------------------------
#Bringing all interfaces back up to call home/update scripts
#------------------------------------------------------------
echo Bringing all interfaces online | tee -a /usr/local/scripts/sim.log
sudo ifconfig $eadapter up
sudo ifconfig $wladapter up
echo ------------------------------| tee -a /usr/local/scripts/sim.log
#------------------------------------------------------------
#Looping Script
#------------------------------------------------------------
source /usr/local/scripts/simulation.sh
