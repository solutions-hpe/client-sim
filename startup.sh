#!/bin/bash
version=.11
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
fi
#------------------------------------------------------------
#Checking to see if there is a cache device to connect to
echo VH Server is $vh_server | tee -a /usr/local/scripts/sim.log
if [ $vh_server == "on" ]; then
	if [[ -e "/usr/local/scripts/vhcached.txt" ]]; then
 		#Setting value to cached adapter
		#This way the client is always using the same adapter
		#Otherwise connectivity for clients will have gaps when the adapter changes in Central
		vhserver_device=$(cat /usr/local/scripts/vhcached.txt)
		echo Cached $vhserver_device | tee -a /usr/local/scripts/sim.log
  	#If VirtualHere cached value does not exist
   	else
		#Counting & searching records in /tmp/vhactive.txt
		vhactive=$(cat /tmp/vhactive.txt | grep -e -- | grep -v In-use | awk -F'[()]' '{print $2}')
		for r in $vhactive; do
			r_count=$((r_count+1))
		done
		echo VH Record Count $r_count | tee -a /usr/local/scripts/sim.log
		#Generating random number to connect to a random adapter
		rn_vhactive=$((1 + RANDOM % $r_count))
		#Resetting record counter for next loop
		r_count=0
		#Looping through records to find an available adapter
		for r in $vhactive; do
			r_count=$((r_count+1))
			if [[ $r_count == $rn_vhactive ]]; then
				vhserver_device=$r
				echo New VH $vhserver_device | tee -a /usr/local/scripts/sim.log
				echo $vhserver_device | tee /usr/local/scripts/vhcached.txt
			fi
		done
   	#End if VirtualHere cached value check
    	fi
	#End Checking to see if there is a cache device to connect to
	#------------------------------------------------------------
	#------------------------------------------------------------
	#Connecting to VirtualHere Server
	echo Connecting to USB Adapter | tee -a /usr/local/scripts/sim.log
	#Connecting to Adapter
	/usr/sbin/vhclientx86_64 -t AUTO USE,$vhserver_device | tee -a /usr/local/scripts/sim.log
	#End Connecting to VirtualHere Server
	#------------------------------------------------------------
	echo Waiting for Adapter | tee -a /usr/local/scripts/sim.log
	sleep 30
#End if VirtualHere Server is enabled
fi
#------------------------------------------------------------
if [ $public_repo == "on" ]; then
  echo Updating Scripts - GitHub | tee -a /usr/local/scripts/sim.log
  echo --------------------------| tee -a /usr/local/scripts/sim.log
  #Downloading latest scripts from GitHub
  sudo wget -4 https://raw.githubusercontent.com/solutions-hpe/client-sim/main/simulation.sh -O /usr/local/scripts/simulation.sh
  sudo wget -4 https://raw.githubusercontent.com/solutions-hpe/client-sim/main/startup.sh -O /usr/local/scripts/startup.sh
  sudo wget -4 https://raw.githubusercontent.com/solutions-hpe/client-sim/main/ini-parser.sh -O /usr/local/scripts/ini-parser.sh
  sudo wget -4 https://raw.githubusercontent.com/solutions-hpe/client-sim/main/websites.txt -O /usr/local/scripts/websites.txt
  sudo wget -4 https://raw.githubusercontent.com/solutions-hpe/client-sim/main/dns_fail.txt -O /usr/local/scripts/dns_fail.txt
else
  echo Updating Scripts - SMB | tee -a /usr/local/scripts/sim.log
  echo --------------------------| tee -a /usr/local/scripts/sim.log
  #Using local network repsotory if defined
  smbclient $smb_address -c 'lcd /usr/local/scripts/; cd sim; prompt; mget *' -N
fi
#------------------------------------------------------------
echo Setting Script Permissions | tee -a /usr/local/scripts/sim.log
echo --------------------------| tee -a /usr/local/scripts/sim.log
cd /usr/local/scripts/ && sudo chmod +x *.sh
echo --------------------------| tee -a /usr/local/scripts/sim.log
#------------------------------------------------------------

#------------------------------------------------------------
#Dumping Current Device List
sudo /usr/sbin/vhclientx86_64 -t LIST -r /tmp/vhactive.txt
#------------------------------------------------------------
echo Launching Simulation Script | tee -a /usr/local/scripts/sim.log
#Looping Script
source /usr/local/scripts/simulation.sh
