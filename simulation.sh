#!/bin/bash
#------------------------------------------------------------
#Global Simulation enable/disable
sim=generic
kill_switch=off
sim_load=100
dhcp_fail=off
dns_fail=on
assoc_fail=off
port_flap=off
ping_test=on
download=off
www_traffic=on
#------------------------------------------------------------
#Edit these for valid DNS servers you want to send a bad dns lookup to
#Will trigger a bad dns lookup alert
dns_bad_record_1=172.31.201.1
dns_bad_record_2=172.31.202.2
dns_bad_record_3=100.100.0.1
#------------------------------------------------------------
#Edit these for servers that do not exist
#Will trigger a failed DNS server alert
dns_bad_ip_1=10.0.0.1 #Dead Server
dns_bad_ip_2=172.16.0.1 #Dead Server
dns_bad_ip_3=192.168.0.1 #Dead Server
#------------------------------------------------------------
#Edit these for servers that do not exist
#Will trigger a slow DNS server alert
dns_latency_1=13.239.88.95 #Australia
dns_latency_2=27.110.152.250 #Philippines
dns_latency_3=165.246.10.2 #S. Korea
#------------------------------------------------------------
#Address that will attempt to ping
#------------------------------------------------------------
ping_address=172.31.201.3
#------------------------------------------------------------
#SMB Share to get scripts from
#smb_location='//100.127.1.254/Public'
#------------------------------------------------------------
#DO NOT EDIT BELOW THIS LINE UNLESS YOU KNOW WHAT YOU ARE DOING

#Generating a random number to have some variance in the scripts
rn=$((1 + RANDOM % 60))
#------------------------------------------------------------
#Checking to see if there is a cache device to connect to
if [[ -e "/usr/local/scripts/vhcached.txt" ]]; then
	#Setting value to cached adapter
	#This way the client is always using the same adapter
	#Otherwise connectivity for clients will have gaps when the adapter changes in Central
	vhserver_device=$(cat /usr/local/scripts/vhcached.txt)
	echo Cached $vhserver_device | tee -a /usr/local/scripts/sim.log
else
	#Counting & searching records in /tmp/vhactive.txt
	vhactive=$(cat /tmp/vhactive.txt | grep -e -- | grep -v In-use | awk -F'[()]' '{print $2}')
		for r in $vhactive; do
			r_count=$((r_count+1))
		done
		echo VH Record Count $r_count | tee -a /usr/local/scripts/sim.log
		#Generating random number to connect to a random adapter
		rn_vhactive=$((1 + RANDOM% $r_count))
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
fi
#------------------------------------------------------------

#------------------------------------------------------------
echo Connecting to USB Adapter | tee -a /usr/local/scripts/sim.log
#Connecting to Adapter
/usr/local/virtualhere/vhuit64 -t USE,$vhserver_device | tee -a /usr/local/scripts/sim.log
#------------------------------------------------------------
echo Waiting for Adapter | tee -a /usr/local/scripts/sim.log
sleep 30 | tee -a /usr/local/scripts/sim.log
#------------------------------------------------------------

#Checking for kill switch to stop simulation
if [ $kill_switch == "off" ]; then
	for z in {1..100}; do
	#------------------------------------------------------------
	#Setting up Client Simulations
	if [[ $HOSTNAME == "SIM-LNX-200"* ]]; then wsite=MIA && sim=DNS; fi
	#End Setting up Client Simulations
	#------------------------------------------------------------

	#------------------------------------------------------------ 
	#Logging Simulation
	echo --------------------------| tee -a /usr/local/scripts/sim.log
	echo Simulation Details: | tee -a /usr/local/scripts/sim.log
	echo Hostname: $HOSTNAME | tee -a /usr/local/scripts/sim.log
	echo Site: $wsite | tee -a /usr/local/scripts/sim.log
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
	nmcli dev wifi connect $wsite-PSK password Aruba123! | tee -a /usr/local/scripts/sim.log
	echo Waiting for Network | tee -a /usr/local/scripts/sim.log
	sleep 30 | tee -a /usr/local/scripts/sim.log
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
					echo Simulation Details: | tee -a /usr/local/scripts/sim.log
					echo Hostname: $HOSTNAME | tee -a /usr/local/scripts/sim.log
					echo Site: $wsite | tee -a /usr/local/scripts/sim.log
					echo Simulation: $sim | tee -a /usr/local/scripts/sim.log
					echo Simulation Load: $sim_load | tee -a /usr/local/scripts/sim.log
					echo Kill Switch: $kill_switch | tee -a /usr/local/scripts/sim.log
					echo WWW Sim: $www_traffic | tee -a /usr/local/scripts/sim.log
					echo WWW Traffic Generation: | tee -a /usr/local/scripts/sim.log
					echo Website: $r | tee -a /usr/local/scripts/sim.log
					echo --------------------------| tee -a /usr/local/scripts/sim.log
					echo --------------------------| tee -a /usr/local/scripts/sim.log
					#firefox --headless $r &
					firefox --new-tab $r &
					www_traffic=off
				fi
			done
		fi
	#End WWW Traffic Simulation
	#------------------------------------------------------------	

	#------------------------------------------------------------
	#Updating Scripts
	echo Updating Scripts | tee -a /usr/local/scripts/sim.log
	sudo wget https://raw.githubusercontent.com/solutions-hpe/client-sim/main/simulation.sh -O /usr/local/scripts/simulation.sh
	sudo wget https://raw.githubusercontent.com/solutions-hpe/client-sim/main/startup.sh -O /usr/local/scripts/startup.sh
	sudo wget https://raw.githubusercontent.com/solutions-hpe/client-sim/main/websites.txt -O /usr/local/scripts/websits.txt
	sudo wget https://raw.githubusercontent.com/solutions-hpe/client-sim/main/dns_fail.txt -O /usr/local/scripts/dns_fail.txt
	#------------------------------------------------------------
 	#smbclient $smb_location -c 'lcd /usr/local/scripts/; cd Scripts; prompt; mget *' -N
	#End Updating Scripts
	#------------------------------------------------------------

	#------------------------------------------------------------
	#Running ping simulation
	if [ $ping_test == "on" ]; then
		echo --------------------------| tee -a /usr/local/scripts/sim.log
		echo --------------------------| tee -a /usr/local/scripts/sim.log
		echo Simulation Details: | tee -a /usr/local/scripts/sim.log
		echo Hostname: $HOSTNAME | tee -a /usr/local/scripts/sim.log
		echo Site: $wsite | tee -a /usr/local/scripts/sim.log
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
			curl -o /tmp/Ubuntu.gz http://archive.ubuntu.com/ubuntu/dists/bionic/Contents-i386.gz
			curl -o /tmp/PDF10MB.pdf https://link.testfile.org/PDF10MB
			curl -o /tmp/Test.mp3 https://files.testfile.org/anime.mp3	
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
						echo Simulation Details: | tee -a /usr/local/scripts/sim.log
						echo Hostname: $HOSTNAME | tee -a /usr/local/scripts/sim.log
						echo Site: $wsite | tee -a /usr/local/scripts/sim.log
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
						wait
					done
			done
		fi
	#End DNS Fail Simulation
	#------------------------------------------------------------
	echo End of simulation sleeping for 5 seconds
	sleep 5
done
else
	#------------------------------------------------------------
	#If kill switch is enabled - sleeping for 5 minutes then restarting the loop
	echo Kill switch enabled - sleeping for 5 minutes
	sleep 300
fi
#------------------------------------------------------------
#Looping Script
source /usr/local/scripts/simulation.sh