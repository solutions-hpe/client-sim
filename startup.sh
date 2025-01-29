#!/bin/bash
version=.15
echo --------------------------| tee /usr/local/scripts/sim.log
echo Startup Script Version $version | tee -a /usr/local/scripts/sim.log
echo $(date) | tee -a /usr/local/scripts/sim.log
echo --------------------------| tee -a /usr/local/scripts/sim.log
#------------------------------------------------------------
#Verify key settings changed - since this script is ran at startup
#this is where you should put system changes you want to make sure 
#are applied. Some of these may be set during the installer but the 
#installer is only ran one time.
echo Disabling screen blanking | tee -a /usr/local/scripts/sim.log
gsettings set org.gnome.desktop.session idle-delay 0
xset s noblank
xset -dpms
xset s off
sudo rfkill unblock wifi; sudo rfkill unblock all
#------------------------------------------------------------
#Calling config parser script
source '/usr/local/scripts/ini-parser.sh'
#Setting config file location
process_ini_file '/usr/local/scripts/simulation.conf'
echo --------------------------| tee -a /usr/local/scripts/sim.log
echo Parsing Config File | tee -a /usr/local/scripts/sim.log
#Settings read from the local config file
public_repo=$(get_value 'simulation' 'public_repo')
vh_server_address=$(get_value 'address' 'vh_server_addr')
vh_server=$(get_value 'simulation' 'vh_server')
smb_address=$(get_value 'address' 'smb_address')
reboot_schedule=$(get_value 'simulation' 'reboot_schedule')
#------------------------------------------------------------
#Scheduling Reboot
echo Scheduling reboot $reboot_schedule minutes | tee -a /usr/local/scripts/sim.log
shutdown -r $reboot_schedule
#------------------------------------------------------------
#Finding adapter names and setting usable variables for interfaces
wladapter=$(ifconfig -a | grep "wlx\|wlan" | cut -d ':' -f '1')
echo WLAN Adapter name $wladapter | tee -a /usr/local/scripts/sim.log
eadapter=$(ifconfig -a | grep "enp\|eno\|eth0\|eth1\|eth2\|eth3\|eth4\|eth5\|eth6" | cut -d ':' -f '1')
echo Wired Adapter name $eadapter | tee -a /usr/local/scripts/sim.log
#Making sure eth0 and wlan0 are online
echo Bringing up all interfaces online | tee -a /usr/local/scripts/sim.log
sudo ifconfig $eadapter up
sudo ifconfig $wladapter up
#Sleeping for 30 seconds to bring up network interaces
sleep 30
echo Wating for sytem startup | tee -a /usr/local/scripts/sim.log
echo --------------------------| tee -a /usr/local/scripts/sim.log
#------------------------------------------------------------
#Setting VirtualHere Server as a Daemon
if [ $vh_server == "on" ]; then
  echo Setting VH to autostart | tee -a /usr/local/scripts/sim.log
  echo Waiting for VH Client to start | tee -a /usr/local/scripts/sim.log
  sudo /usr/sbin/vhclientx86_64 -n
  sleep 30
  #Dumping Current Device List
  echo Getting VH device list | tee -a /usr/local/scripts/sim.log
  sudo /usr/sbin/vhclientx86_64 -t LIST -r /tmp/vhactive.txt
fi
#------------------------------------------------------------
#End Updating Scripts
#------------------------------------------------------------
echo Setting Script Permissions | tee -a /usr/local/scripts/sim.log
echo --------------------------| tee -a /usr/local/scripts/sim.log
cd /usr/local/scripts/ && sudo chmod +x *.sh
echo --------------------------| tee -a /usr/local/scripts/sim.log
#------------------------------------------------------------
echo Launching Simulation Script | tee -a /usr/local/scripts/sim.log
#Looping Script
source /usr/local/scripts/simulation.sh
