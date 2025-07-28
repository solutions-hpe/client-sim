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
#Figuring out username from hostname used to parse config
#------------------------------------------------------------
username=$(echo $HOSTNAME | cut -d "-" -f 1)
#------------------------------------------------------------
#Calling config parser script
#------------------------------------------------------------
echo Reading Simulation Config File | tee -a /usr/local/scripts/sim.log
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
repo_location=$(get_value 'simulation' 'repo_location')
vh_server=$(get_value 'simulation' 'vh_server')
sim_phy=$(get_value $simulation_id 'sim_phy')
tempvar=$(get_value $username 'repo_location')
#------------------------------------------------------------
#Checking to see if this device/user has an override
#------------------------------------------------------------
if [[ -n ${tempvar} ]]; then repo_location=$tempvar; fi
tempvar=$(get_value $username 'vh_server')
if [[ -n ${tempvar} ]]; then vh_server=$tempvar; fi
tempvar=$(get_value $username 'sim_phy')
if [[ -n ${tempvar} ]]; then sim_phy=$tempvar; fi
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
if [ $sim_phy == "wireless" ] && [ $vh_server == "on" ] && [ -n ${wladapter} ]; then
 sudo ip link set $wladapter down
 sleep 1
 sudo ip link set dev $wladapter address e8:4e:06:ac:$mac_id
 sleep 1
 sudo ip link set $wladapter up
 sleep 1
fi
#------------------------------------------------------------
#Setting VirtualHere Server as a Daemon
#------------------------------------------------------------
if [ $vh_server == "on" ]; then
  echo Setting VH to autostart | tee -a /usr/local/scripts/sim.log
  echo Waiting for VH Client to start | tee -a /usr/local/scripts/sim.log
  sudo /usr/sbin/vhclientx86_64 -n
  sleep 5
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
