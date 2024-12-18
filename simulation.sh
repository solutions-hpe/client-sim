#!/bin/bash
version=.15
echo $(date) | tee -a /usr/local/scripts/sim.log
echo --------------------------| tee -a /usr/local/scripts/sim.log
echo Simulation Script Version $version | tee -a /usr/local/scripts/sim.log
echo Reading Simulation Config File | tee -a /usr/local/scripts/sim.log
#Calling config parser script
source '/usr/local/scripts/ini-parser.sh'
#Setting config file location
process_ini_file '/usr/local/scripts/simulation.conf'
#------------------------------------------------------------
#Global Simulation defaults enable/disable
#------------------------------------------------------------
sim=generic
kill_switch=off
sim_load=100
dhcp_fail=off
dns_fail=on
assoc_fail=off
port_flap=off
ping_test=on
download=on
www_traffic=on
public_repo=on
vh_server=off
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
dhcp_fail=$(get_value 'simulation' 'dhcp_fail')
dns_fail=$(get_value 'simulation' 'dns_fail')
assoc_fail=$(get_value 'simulation' 'assoc_fail')
port_flap=$(get_value 'simulation' 'port_flap')
ping_test=$(get_value 'simulation' 'ping_test')
download=$(get_value 'simulation' 'download')
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
#------------------------------------------------------------
#------------------------------------------------------------
#Generating a random number to have some variance in the scripts
rn=$((1 + RANDOM % 60))
#------------------------------------------------------------
echo Disabling unused interface | tee -a /usr/local/scripts/sim.log
if [ $sim_phy == "ethernet" ]; then sudo ifconfig wlan0 down; fi
if [ $sim_phy == "wireless" ]; then sudo ifconfig eth0 down; fi
#------------------------------------------------------------
#Checking to see if there is a cache device to connect to
echo VH Server is $vh_server | tee -a /usr/local/scripts/sim.log
if [ $vh_server == "on" ]; then
	if [[ -e "/usr/local/scripts/vhcached.txt" ]]; then
		#Setting Virtual Here to run as a Daemon
 		sudo /usr/local/virtualhere/vhuit64 -n
	 	echo Waiting for VH startup | tee -a /usr/local/scripts/sim.log
		sleep 30
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
	/usr/local/virtualhere/vhuit64 -t USE,$vhserver_device | tee -a /usr/local/scripts/sim.log
	#End Connecting to VirtualHere Server
	#------------------------------------------------------------
	echo Waiting for Adapter | tee -a /usr/local/scripts/sim.log
	sleep 30
#End if VirtualHere Server is enabled
fi
#------------------------------------------------------------
#Checking for kill switch to stop simulation
if [ $kill_switch == "off" ]; then
	for z in {1..100}; do
		#------------------------------------------------------------ 
		#Logging Simulation
		echo --------------------------| tee -a /usr/local/scripts/sim.log
		echo $(date) | tee -a /usr/local/scripts/sim.log
  		echo --------------------------| tee -a /usr/local/scripts/sim.log
  		echo Simulation Details: | tee -a /usr/local/scripts/sim.log
		echo Hostname: $HOSTNAME | tee -a /usr/local/scripts/sim.log
		echo Site: $wsite | tee -a /usr/local/scripts/sim.log
  		echo Phy: $sim_phy | tee -a /usr/local/scripts/sim.log
		echo Simulation: $sim | tee -a /usr/local/scripts/sim.log
		echo Simulation Load: $sim_load | tee -a /usr/local/scripts/sim.log
		echo Kill Switch: $kill_switch | tee -a /usr/local/scripts/sim.log
		echo DHCP Fail: $dhcp_fail | tee -a /usr/local/scripts/sim.log
		echo DNS Fail: $dns_fail | tee -a /usr/local/scripts/sim.log
		echo WWW Traffic: $www_traffic | tee -a /usr/local/scripts/sim.log
		echo Port Flap: $port_flap | tee -a /usr/local/scripts/sim.log
		echo --------------------------| tee -a /usr/local/scripts/sim.log
		#------------------------------------------------------------ 

		#------------------------------------------------------------
		#Connecting to Network
  		if [ $sim_phy == "wireless" ]; then
			nmcli dev wifi connect $ssid password $ssidpw | tee -a /usr/local/scripts/sim.log
			echo Waiting for Network | tee -a /usr/local/scripts/sim.log
			sleep 30 | tee -a /usr/local/scripts/sim.log
  		fi
		#End Connecting to Network
		#------------------------------------------------------------

		#------------------------------------------------------------
		#Running WWW Traffic Simulation
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
						echo Simulation: $sim | tee -a /usr/local/scripts/sim.log
						echo Simulation Load: $sim_load | tee -a /usr/local/scripts/sim.log
						echo Kill Switch: $kill_switch | tee -a /usr/local/scripts/sim.log
						echo WWW Sim: $www_traffic | tee -a /usr/local/scripts/sim.log
						echo WWW Traffic Generation: | tee -a /usr/local/scripts/sim.log
						echo Website: $r | tee -a /usr/local/scripts/sim.log
						echo --------------------------| tee -a /usr/local/scripts/sim.log
						echo --------------------------| tee -a /usr/local/scripts/sim.log
						firefox --headless --newtab $r &
						#firefox --new-tab $r &
						www_traffic=off
					fi
				done
		fi
		#End WWW Traffic Simulation
		#------------------------------------------------------------	
	 
		#------------------------------------------------------------
		#Updating Scripts
		echo Updating Scripts | tee -a /usr/local/scripts/sim.log
 		if [ $public_repo == "on" ]; then
  			#Using remote GitHub repo
			sudo wget https://raw.githubusercontent.com/solutions-hpe/client-sim/main/simulation.sh -O /usr/local/scripts/simulation.sh
			sudo wget https://raw.githubusercontent.com/solutions-hpe/client-sim/main/startup.sh -O /usr/local/scripts/startup.sh
			sudo wget https://raw.githubusercontent.com/solutions-hpe/client-sim/main/ini-parser.sh -O /usr/local/scripts/ini-parser.sh
 			sudo wget https://raw.githubusercontent.com/solutions-hpe/client-sim/main/websites.txt -O /usr/local/scripts/websits.txt
			sudo wget https://raw.githubusercontent.com/solutions-hpe/client-sim/main/dns_fail.txt -O /usr/local/scripts/dns_fail.txt
 		else
  			#Local repo defined in the conf file
  			smbclient $smb_location -c 'lcd /usr/local/scripts/; cd Scripts; prompt; mget *' -N
  		fi
		#------------------------------------------------------------
		#End Updating Scripts
		#------------------------------------------------------------
	 
		#------------------------------------------------------------
		#Running ping simulation
		if [ $ping_test == "on" ]; then
			echo --------------------------| tee -a /usr/local/scripts/sim.log
			echo --------------------------| tee -a /usr/local/scripts/sim.log
   			echo $(date) | tee -a /usr/local/scripts/sim.log
      			echo --------------------------| tee -a /usr/local/scripts/sim.log
			echo Simulation Details: | tee -a /usr/local/scripts/sim.log
			echo Hostname: $HOSTNAME | tee -a /usr/local/scripts/sim.log
			echo Site: $wsite | tee -a /usr/local/scripts/sim.log
	  		echo Phy: $sim_phy | tee -a /usr/local/scripts/sim.log		
   			echo Simulation: $sim | tee -a /usr/local/scripts/sim.log
			echo Simulation Load: $sim_load | tee -a /usr/local/scripts/sim.log
			echo Kill Switch: $kill_switch | tee -a /usr/local/scripts/sim.log
			echo Ping Sim: $ping_test | tee -a /usr/local/scripts/sim.log
			echo Ping Address: $ping_address | tee -a /usr/local/scripts/sim.log
			echo Count: $rn | tee -a /usr/local/scripts/sim.log
			echo --------------------------| tee -a /usr/local/scripts/sim.log
			echo --------------------------| tee -a /usr/local/scripts/sim.log
			echo Running ping simulation
			echo Pinging Default Gateway
			ping -c $rn $ping_address
		fi
		#End Ping Simulation
		#------------------------------------------------------------
 		#------------------------------------------------------------
		#Running download simulation
		if [ $download == "on" ]; then
				echo Running download simulation | tee -a /usr/local/scripts/sim.log
				curl -o /tmp/Ubuntu.gz http://archive.ubuntu.com/ubuntu/dists/bionic/Contents-i386.gz | tee -a /usr/local/scripts/sim.log 
				curl -o /tmp/main.cvd https://packages.microsoft.com/clamav/main.cvd | tee -a /usr/local/scripts/sim.log
				curl -o /tmp/manifest https://android.googlesource.com/platform/manifest | tee -a /usr/local/scripts/sim.log
    				curl -0 /tmp/bootcamp5.1.5769.zip https://download.info.apple.com/Mac_OS_X/031-30890-20150812-ea191174-4130-11e5-a125-930911ba098f/bootcamp5.1.5769.zip| tee -a /usr/local/scripts/sim.log
		fi
		#Running apt update & apt upgrade
		echo Running Updates | tee -a /usr/local/scripts/sim.log
		sudo apt update 
		sudo apt upgrade -y 
		#End Download Simulation
		#------------------------------------------------------------
		#------------------------------------------------------------
		#Running DNS Fail simulation
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
   						echo Simulation: $sim | tee -a /usr/local/scripts/sim.log
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
		#End DNS Fail Simulation
		#------------------------------------------------------------
	echo End of simulation sleeping for 5 seconds
	sleep 5
	#End of 100 Loop Count
	#------------------------------------------------------------
	done
else
	#------------------------------------------------------------
	#If kill switch is enabled - sleeping for 5 minutes then restarting the loop
	echo Kill switch enabled - sleeping for 5 minutes
	sleep 300
fi
#End Kill switch Check 
#------------------------------------------------------------
#Bringing all interfaces back up to call home/update scripts
echo --------------------------| tee -a /usr/local/scripts/sim.log
echo Bringing all interfaces online | tee -a /usr/local/scripts/sim.log
sudo ifconfig eth0 up
sudo ifconfig wlan0 up
echo --------------------------| tee -a /usr/local/scripts/sim.log
#------------------------------------------------------------
#Looping Script
source /usr/local/scripts/simulation.sh
