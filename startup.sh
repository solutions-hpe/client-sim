#!/bin/bash
version=.28
echo ------------------------------| tee /usr/local/scripts/sim.log
echo Startup Script Version $version | tee -a /usr/local/scripts/sim.log
echo $(date) | tee -a /usr/local/scripts/sim.log
echo ------------------------------| tee -a /usr/local/scripts/sim.log
#------------------------------------------------------------
#Check Logs Script
#------------------------------------------------------------
source /usr/local/scripts/sys_mon.sh &
#------------------------------------------------------------
#Verify key settings changed - since this script is ran at startup
#this is where you should put system changes you want to make sure 
#are applied. Some of these may be set during the installer but the 
#installer is only ran one time.
#------------------------------------------------------------
echo Disabling screen blanking | tee -a /usr/local/scripts/sim.log
gsettings set org.gnome.desktop.session idle-delay 0
xset s noblank
xset -dpms
xset s off
sudo rfkill unblock wifi; sudo rfkill unblock all
#------------------------------------------------------------
#Calling config parser script
#------------------------------------------------------------
echo Reading Simulation Config File | tee -a /usr/local/scripts/sim.log
sleep 15
#------------------------------------------------------------
#Calling config parser script - reads the simulation.conf file
#For values assinged to script variables
#------------------------------------------------------------
source '/usr/local/scripts/ini-parser.sh'
#------------------------------------------------------------
#Setting config file location
#------------------------------------------------------------
process_ini_file '/usr/local/scripts/simulation.conf'
#------------------------------------------------------------
echo ------------------------------| tee -a /usr/local/scripts/sim.log
echo Parsing Config File | tee -a /usr/local/scripts/sim.log
#------------------------------------------------------------
#Settings read from the local config file
#Global Simulation settings
#------------------------------------------------------------
reboot_schedule=$(get_value 'simulation' 'reboot_schedule')
kill_switch=$(get_value 'simulation' 'kill_switch')
sim_load=$(get_value 'simulation' 'sim_load')
public_repo=$(get_value 'simulation' 'public_repo')
repo_location=$(get_value 'simulation' 'repo_location')
vh_server=$(get_value 'simulation' 'vh_server')
site_based_ssid=$(get_value 'simulation' 'site_based_ssid')
iperf_bw=$(get_value 'simulation' 'iperf_bw')
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
tempvar=$(get_value $username 'kill_switch')
if [[ -n ${tempvar} ]]; then kill_switch=$tempvar; fi
tempvar=$(get_value $username 'sim_load')
if [[ -n ${tempvar} ]]; then sim_load=$tempvar; fi
tempvar=$(get_value $username 'public_repo')
if [[ -n ${tempvar} ]]; then public_repo=$tempvar; fi
tempvar=$(get_value $username 'repo_location')
if [[ -n ${tempvar} ]]; then repo_location=$tempvar; fi
tempvar=$(get_value $username 'vh_server')
if [[ -n ${tempvar} ]]; then vh_server=$tempvar; fi
tempvar=$(get_value $username 'site_based_ssid')
if [[ -n ${tempvar} ]]; then site_based_ssid=$tempvar; fi
tempvar=$(get_value $username 'iperf_bw')
if [[ -n ${tempvar} ]]; then iperf_bw=$tempvar; fi
#------------------------------------------------------------
tempvar=$(get_value $username 'wsite')
if [[ -n ${tempvar} ]]; then wsite=$tempvar; fi
tempvar=$(get_value $username 'sim_phy')
if [[ -n ${tempvar} ]]; then sim_phy=$tempvar; fi
tempvar=$(get_value $username 'ssid')
if [[ -n ${tempvar} ]]; then ssid=$tempvar; fi
tempvar=$(get_value $username 'ssidpw')
if [[ -n ${tempvar} ]]; then ssidpw=$tempvar; fi
tempvar=$(get_value $username 'dhcp_fail')
if [[ -n ${tempvar} ]]; then dhcp_fail=$tempvar; fi
tempvar=$(get_value $username 'dns_fail')
if [[ -n ${tempvar} ]]; then dns_fail=$tempvar; fi
tempvar=$(get_value $username 'assoc_fail')
if [[ -n ${tempvar} ]]; then assoc_fail=$tempvar; fi
tempvar=$(get_value $username 'port_flap')
if [[ -n ${tempvar} ]]; then port_flap=$tempvar; fi
tempvar=$(get_value $username 'ping_test')
if [[ -n ${tempvar} ]]; then ping_test=$tempvar; fi
tempvar=$(get_value $username 'download')
if [[ -n ${tempvar} ]]; then download=$tempvar; fi
tempvar=$(get_value $username 'iperf')
if [[ -n ${tempvar} ]]; then iperf=$tempvar; fi
tempvar=$(get_value $username 'www_traffic')
if [[ -n ${tempvar} ]]; then www_traffic=$tempvar; fi
tempvar=$(get_value $username 'ssidpw_fail')
if [[ -n ${tempvar} ]]; then ssidpw_fail=$tempvar; fi
#------------------------------------------------------------
tempvar=$(get_value $username 'smb_address')
if [[ -n ${tempvar} ]]; then smb_address=$tempvar; fi
tempvar=$(get_value $username 'ping_address')
if [[ -n ${tempvar} ]]; then ping_address=$tempvar; fi
tempvar=$(get_value $username 'dns_latency_1')
if [[ -n ${tempvar} ]]; then dns_latency_1=$tempvar; fi
tempvar=$(get_value $username 'dns_latency_2')
if [[ -n ${tempvar} ]]; then dns_latency_2=$tempvar; fi
tempvar=$(get_value $username 'dns_latency_3')
if [[ -n ${tempvar} ]]; then dns_latency_3=$tempvar; fi
tempvar=$(get_value $username 'dns_bad_ip_1')
if [[ -n ${tempvar} ]]; then dns_bad_ip_1=$tempvar; fi
tempvar=$(get_value $username 'dns_bad_ip_2')
if [[ -n ${tempvar} ]]; then dns_bad_ip_2=$tempvar; fi
tempvar=$(get_value $username 'dns_bad_ip_3')
if [[ -n ${tempvar} ]]; then dns_bad_ip_3=$tempvar; fi
tempvar=$(get_value $username 'dns_bad_record_1')
if [[ -n ${tempvar} ]]; then dns_bad_record_1=$tempvar; fi
tempvar=$(get_value $username 'dns_bad_record_2')
if [[ -n ${tempvar} ]]; then dns_bad_record_2=$tempvar; fi
tempvar=$(get_value $username 'dns_bad_record_3')
if [[ -n ${tempvar} ]]; then dns_bad_record_3=$tempvar; fi
tempvar=$(get_value $username 'vh_server_addr')
if [[ -n ${tempvar} ]]; then vh_server_addr=$tempvar; fi
tempvar=$(get_value $username 'iperf_server')
if [[ -n ${tempvar} ]]; then iperf_server=$tempvar; fi
#------------------------------------------------------------
#Scheduling Reboot
#------------------------------------------------------------
rn=$(($reboot_schedule + RANDOM % 600))
echo Scheduling reboot $rn minutes | tee -a /usr/local/scripts/sim.log
shutdown -r $rn
#------------------------------------------------------------
#Finding adapter names and setting usable variables for interfaces
#------------------------------------------------------------
wladapter=$(ifconfig -a | grep "wlx\|wlan" | cut -d ':' -f '1')
echo WLAN Adapter name $wladapter | tee -a /usr/local/scripts/sim.log
eadapter=$(ifconfig -a | grep "enp\|eno\|eth0\|eth1\|eth2\|eth3\|eth4\|eth5\|eth6" | cut -d ':' -f '1')
echo Wired Adapter name $eadapter | tee -a /usr/local/scripts/sim.log
#Making sure eth0 and wlan0 are online
echo Bringing up all interfaces online | tee -a /usr/local/scripts/sim.log
sudo ifconfig $eadapter up
sudo ifconfig $wladapter up
echo -----------------------------| tee -a /usr/local/scripts/sim.log
#------------------------------------------------------------
#Changing the MAC Address of the wireless adapter
#------------------------------------------------------------
mac_id=$(echo $HOSTNAME | rev | cut -c 3-4 | rev)
mac_id="${mac_id}:$(echo $HOSTNAME | rev | cut -c 1-2 | rev)"
if [ $sim_phy == "wireless" ] && [ $vh_server == "on" ]; then
 sudo ip link set wlan0 down
 sleep 1
 sudo ip link set dev wlan0 address e8:4e:06:ac:$mac_id
 sleep 1
 sudo ip link set wlan0 up
 sleep 1
fi
#------------------------------------------------------------
#Setting VirtualHere Server as a Daemon
#------------------------------------------------------------
if [ $vh_server == "on" ]; then
  echo Setting VH to autostart | tee -a /usr/local/scripts/sim.log
  echo Waiting for VH Client to start | tee -a /usr/local/scripts/sim.log
  sudo /usr/sbin/vhclientx86_64 -n
fi
#------------------------------------------------------------
echo Setting Script Permissions | tee -a /usr/local/scripts/sim.log
echo -----------------------------| tee -a /usr/local/scripts/sim.log
cd /usr/local/scripts/ && sudo chmod +x *.sh
#------------------------------------------------------------
#Looping Script
#------------------------------------------------------------
echo Launching Simulation Script | tee -a /usr/local/scripts/sim.log
source /usr/local/scripts/simulation.sh
