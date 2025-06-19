#!/bin/bash
version=.31
echo $(date) | tee -a /usr/local/scripts/sim.log
echo --------------------------| tee -a /usr/local/scripts/sim.log
echo Simulation Script Version $version | tee -a /usr/local/scripts/sim.log
echo Reading Simulation Config File | tee -a /usr/local/scripts/sim.log
#Calling config parser script
source '/usr/local/scripts/ini-parser.sh'
#Setting config file location
process_ini_file '/usr/local/scripts/simulation.conf'
#Finding adapter names and setting usable variables for interfaces
wladapter=$(ifconfig -a | grep "wlx\|wlan" | cut -d ':' -f '1')
echo WLAN Adapter name $wladapter | tee -a /usr/local/scripts/sim.log
eadapter=$(ifconfig -a | grep "enp\|eno\|eth0\|eth1\|eth2\|eth3\|eth4\|eth5\|eth6" | cut -d ':' -f '1')
echo Wired Adapter name $eadapter | tee -a /usr/local/scripts/sim.log
#------------------------------------------------------------
#DO NOT EDIT BELOW THIS LINE UNLESS YOU KNOW WHAT YOU ARE DOING
#------------------------------------------------------------
echo Parsing Config File | tee -a /usr/local/scripts/sim.log
#Settings read from the local config file
#Simulation settings
wsite=$(get_value 'simulation' 'wsite')
sim_phy=$(get_value 'simulation' 'sim_phy')
ssid=$(get_value 'simulation' 'ssid')
ssidpw=$(get_value 'simulation' 'ssidpw')
kill_switch=$(get_value 'simulation' 'kill_switch')
sim_load=$(get_value 'simulation' 'sim_load')
dhcp_fail=$(get_value 'simulation' 'dhcp_fail')
dns_fail=$(get_value 'simulation' 'dns_fail')
assoc_fail=$(get_value 'simulation' 'assoc_fail')
port_flap=$(get_value 'simulation' 'port_flap')
ping_test=$(get_value 'simulation' 'ping_test')
download=$(get_value 'simulation' 'download')
iperf=$(get_value 'simulation' 'iperf')
www_traffic=$(get_value 'simulation' 'www_traffic')
public_repo=$(get_value 'simulation' 'public_repo')
vh_server=$(get_value 'simulation' 'vh_server')
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
rn_iperf_timer=((1+ RANDOM % 300))
#------------------------------------------------------------
#Dumping Current Device List
echo Disabling unused interface | tee -a /usr/local/scripts/sim.log
if [ $sim_phy == "ethernet" ]; then sudo ifconfig $wladapter down; fi
if [ $sim_phy == "wireless" ] && [ $vh_server == "off" ]; then sudo ifconfig $eadapter down; fi
#------------------------------------------------------------
#Checking for kill switch to stop simulation
#------------------------------------------------------------
#Connecting to VHServer
#------------------------------------------------------------
source '/usr/local/scripts/vhconnect.sh'
#------------------------------------------------------------
#End Connecting to VHServer
#------------------------------------------------------------
echo Kill Switch is $kill_switch | tee -a /usr/local/scripts/sim.log
if [ $kill_switch == "off" ]; then
	for z in {1..100}; do
		#------------------------------------------------------------ 
		#Logging Simulation
  		#------------------------------------------------------------ 
		echo --------------------------| tee -a /usr/local/scripts/sim.log
		echo $(date) | tee -a /usr/local/scripts/sim.log
  		echo --------------------------| tee -a /usr/local/scripts/sim.log
  		echo Simulation Details: | tee -a /usr/local/scripts/sim.log
		echo Hostname: $HOSTNAME | tee -a /usr/local/scripts/sim.log
		echo Site: $wsite | tee -a /usr/local/scripts/sim.log
  		echo Phy: $sim_phy | tee -a /usr/local/scripts/sim.log
		echo Simulation Load: $sim_load | tee -a /usr/local/scripts/sim.log
		echo Kill Switch: $kill_switch | tee -a /usr/local/scripts/sim.log
		echo DHCP Fail: $dhcp_fail | tee -a /usr/local/scripts/sim.log
		echo DNS Fail: $dns_fail | tee -a /usr/local/scripts/sim.log
		echo WWW Traffic: $www_traffic | tee -a /usr/local/scripts/sim.log
  		echo iPerf: $iperf | tee -a /usr/local/scripts/sim.log
    		echo Download: $download | tee -a /usr/local/scripts/sim.log
		echo Port Flap: $port_flap | tee -a /usr/local/scripts/sim.log
		echo --------------------------| tee -a /usr/local/scripts/sim.log
		#------------------------------------------------------------
		#Connecting to Network
  		#------------------------------------------------------------
  		if [ $sim_phy == "wireless" ]; then
    		sudo rfkill unblock wifi; sudo rfkill unblock all
      			echo --------------------------| tee -a /usr/local/scripts/sim.log
			echo Setting up WiFi Adapter: | tee -a /usr/local/scripts/sim.log
	 		nmcli radio wifi on
    			sleep 5
    			nmcli device wifi rescan
			echo --------------------------| tee -a /usr/local/scripts/sim.log
			echo Connecting to: | tee -a /usr/local/scripts/sim.log
			echo SSID - $ssid | tee -a /usr/local/scripts/sim.log
   			#sleep 15 | tee -a /usr/local/scripts/sim.log
			#echo Password - $ssidpw | tee -a /usr/local/scripts/sim.log
			echo --------------------------| tee -a /usr/local/scripts/sim.log
			nmcli device wifi connect $ssid password $ssidpw
      			#echo Conneting to $ssid on device $wladapter | tee -a /usr/local/scripts/sim.log
   			nmcli radio wifi off
      			nmcli radio wifi on
	 		sleep 5
    			nmcli connection up $ssid
			echo Waiting for Network | tee -a /usr/local/scripts/sim.log
			sleep 15 | tee -a /usr/local/scripts/sim.log
  		fi
    		inet_check=raw.githubusercontent.com
		ping -c1 $inet_check
		if [ $? -eq 0 ]; then
		 echo Successful network connection | tee -a /usr/local/scripts/sim.log
   		 #Running update to either the cloud repo or local SMB repo
   		 source '/usr/local/scripts/update.sh'
		else
  			echo Network connection failed | tee -a /usr/local/scripts/sim.log
     			echo Purging VHConfig | tee -a /usr/local/scripts/sim.log
			#Running API to VHClient to disconnect all clients this device is connecting to
   			#When a device ID changes on VH the client can think it should connect to multiple devices
   			/usr/sbin/vhclientx86_64 -t "STOP USING ALL LOCAL"
			/usr/sbin/vhclientx86_64 -t "AUTO USE CLEAR ALL"
      		 	#VHCached.txt will hold the server and device ID from VH so we use the same device every time
		 	#In the case when a device ID Changes, puring this setting will make sure a new device is captured
   		 	#Device IDs on VH do not happen often, this is mostly when initial turn up happens, or significant
      			#changes occur in the environment. This is a workaround just for when the IDs change.
		 	rm /usr/local/scripts/vhcached.txt
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
			r_count=0
			echo Running WWW Traffic simulation
			wwwfile=$(cat /usr/local/scripts/websites.txt)
				for r in $wwwfile; do
				 r_count=$((r_count+1))
				done
				 rn_www=$((1 + RANDOM % $r_count))
				 r_count=0
				 for r in $wwwfile; do
					r_count=$((r_count+1))
					if [[ $r_count == $rn_www ]]; then
					 echo Closing Firefox | tee -a /usr/local/scripts/sim.log
					 pkill -f firefox
					 sleep 1
					 echo --------------------------| tee -a /usr/local/scripts/sim.log
					 echo --------------------------| tee -a /usr/local/scripts/sim.log
					 echo $(date) | tee -a /usr/local/scripts/sim.log
      					 echo --------------------------| tee -a /usr/local/scripts/sim.log
      					 echo Simulation Details: | tee -a /usr/local/scripts/sim.log
					 echo Hostname: $HOSTNAME | tee -a /usr/local/scripts/sim.log
					 echo Site: $wsite | tee -a /usr/local/scripts/sim.log	  		
      					 echo Phy: $sim_phy | tee -a /usr/local/scripts/sim.log
					 echo Simulation Load: $sim_load | tee -a /usr/local/scripts/sim.log
					 echo Running WWW Traffic Simulation: | tee -a /usr/local/scripts/sim.log
					 echo Website: $r | tee -a /usr/local/scripts/sim.log
					 echo --------------------------| tee -a /usr/local/scripts/sim.log
					 echo --------------------------| tee -a /usr/local/scripts/sim.log
					 firefox --headless --newtab $r &
					 #firefox --new-tab $r &
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
			echo --------------------------| tee -a /usr/local/scripts/sim.log
			echo --------------------------| tee -a /usr/local/scripts/sim.log
   			echo $(date) | tee -a /usr/local/scripts/sim.log
     			echo --------------------------| tee -a /usr/local/scripts/sim.log
			echo Simulation Details: | tee -a /usr/local/scripts/sim.log
			echo Hostname: $HOSTNAME | tee -a /usr/local/scripts/sim.log
			echo Site: $wsite | tee -a /usr/local/scripts/sim.log
	  		echo Phy: $sim_phy | tee -a /usr/local/scripts/sim.log		
   			echo Simulation Load: $sim_load | tee -a /usr/local/scripts/sim.log
			echo Kill Switch: $kill_switch | tee -a /usr/local/scripts/sim.log
			echo Ping Address: $ping_address | tee -a /usr/local/scripts/sim.log
			echo Count: $rn | tee -a /usr/local/scripts/sim.log
			echo --------------------------| tee -a /usr/local/scripts/sim.log
			echo --------------------------| tee -a /usr/local/scripts/sim.log
			echo Running ping simulation
			echo Pinging Default Gateway
			ping -c $rn $ping_address
		fi
  		#------------------------------------------------------------
		#End Ping Simulation
 		#------------------------------------------------------------
     		#------------------------------------------------------------
		#Running iPerf simulation
  		#------------------------------------------------------------
   		if [ $iperf == "on" ]; then
           		echo --------------------------| tee -a /usr/local/scripts/sim.log
			echo Simulation Details: | tee -a /usr/local/scripts/sim.log
			echo Hostname: $HOSTNAME | tee -a /usr/local/scripts/sim.log
			echo Site: $wsite | tee -a /usr/local/scripts/sim.log
		  	echo Phy: $sim_phy | tee -a /usr/local/scripts/sim.log
			echo Simulation Load: $sim_load | tee -a /usr/local/scripts/sim.log
			echo Kill Switch: $kill_switch | tee -a /usr/local/scripts/sim.log
   			echo iPerf Server: $iperf_server | tee -a /usr/local/scripts/sim.log
   			echo iPerf Port: $rn_iperf_port | tee -a /usr/local/scripts/sim.log
      			echo iPerf Time: $rn_iperf_time | tee -a /usr/local/scripts/sim.log
			echo Running iPerf simulation: | tee -a /usr/local/scripts/sim.log
     			iperf3 -u -c $iperf_server -p $rn_iperf_port -t $rn_iperf_time
		fi
    		#------------------------------------------------------------
		#End Download Simulation
		#------------------------------------------------------------
  		#------------------------------------------------------------
		#Running download simulation
  		#------------------------------------------------------------
		if [ $download == "on" ]; then
			echo Running download simulation | tee -a /usr/local/scripts/sim.log
			wget --show-progress -o /tmp/Ubuntu.gz http://archive.ubuntu.com/ubuntu/dists/bionic/Contents-i386.gz | tee -a /usr/local/scripts/sim.log 
			wget --show-progress -o /tmp/main.cvd https://packages.microsoft.com/clamav/main.cvd | tee -a /usr/local/scripts/sim.log
			wget --show-progress -o /tmp/manifest https://android.googlesource.com/platform/manifest | tee -a /usr/local/scripts/sim.log
       			wget --show-progress -o /tmp/bootcamp5.1.5769.zip https://download.info.apple.com/Mac_OS_X/031-30890-20150812-ea191174-4130-11e5-a125-930911ba098f/bootcamp5.1.5769.zip| tee -a /usr/local/scripts/sim.log
		fi
		#Running apt update & apt upgrade
		echo Running Updates | tee -a /usr/local/scripts/sim.log
		sudo apt update 
		sudo apt upgrade -y
  		#------------------------------------------------------------
		#End Download Simulation
		#------------------------------------------------------------
		#Running DNS Fail simulation
  		#------------------------------------------------------------
		if [ $dns_fail == "on" ]; then
			dnsfile=$(cat /usr/local/scripts/dns_fail.txt)
			for i in {1..100}; do
				for r in $dnsfile
					do
     					 echo --------------------------| tee -a /usr/local/scripts/sim.log
					 echo --------------------------| tee -a /usr/local/scripts/sim.log
					 echo $(date) | tee -a /usr/local/scripts/sim.log
      					 echo --------------------------| tee -a /usr/local/scripts/sim.log
					 echo Simulation Details: | tee -a /usr/local/scripts/sim.log
					 echo Hostname: $HOSTNAME | tee -a /usr/local/scripts/sim.log
					 echo Site: $wsite | tee -a /usr/local/scripts/sim.log
		  			 echo Phy: $sim_phy | tee -a /usr/local/scripts/sim.log
					 echo Simulation Load: $sim_load | tee -a /usr/local/scripts/sim.log
					 echo Kill Switch: $kill_switch | tee -a /usr/local/scripts/sim.log
					 echo DNS Fail: $dns_fail | tee -a /usr/local/scripts/sim.log
					 echo Running DNS Failure: | tee -a /usr/local/scripts/sim.log
					 echo Simulation Iteration: $i | tee -a /usr/local/scripts/sim.log
					 echo $r | tee -a /usr/local/scripts/sim.log
					 echo --------------------------| tee -a /usr/local/scripts/sim.log
					 echo --------------------------| tee -a /usr/local/scripts/sim.log
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
 	sudo nmcli connection delete id MIA-PSK
	sleep 5
 	#------------------------------------------------------------
	#End of 100 Loop Count
	#------------------------------------------------------------
	done
else
	#------------------------------------------------------------
	#If kill switch is enabled - sleeping for 5 minutes then restarting the loop
	echo Kill switch enabled - sleeping for 5 minutes
	sleep 300
fi
#------------------------------------------------------------
#End Kill switch Check 
#------------------------------------------------------------
#Bringing all interfaces back up to call home/update scripts
echo --------------------------| tee -a /usr/local/scripts/sim.log
echo Bringing all interfaces online | tee -a /usr/local/scripts/sim.log
sudo ifconfig $eadapter up
sudo ifconfig $wladapter up
echo --------------------------| tee -a /usr/local/scripts/sim.log
#------------------------------------------------------------
#Looping Script
#------------------------------------------------------------
source /usr/local/scripts/simulation.sh
