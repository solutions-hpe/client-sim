#!/bin/bash
version=.13
echo --------------------------| tee -a /usr/local/scripts/sim.log
echo VHConnect Script Version $version | tee -a /usr/local/scripts/sim.log
echo $(date)
#Dumping Current Device List
echo Getting VH device list
sudo /usr/sbin/vhclientx86_64 -t LIST -r /tmp/vhactive.txt
#Checking to see if there is a cache device to connect to
echo VH Server is $vh_server
#Counting & searching records in /tmp/vhactive.txt
r_count=0
y_count=0
#Checking for the number of devices that are currently attached
vhactive=$(cat /tmp/vhactive.txt | grep "*" | awk -F'[()]' '{print $2}')
for r in $vhactive; do
	y_count=$((y_count+1))
done
#Checking the number of devices that are available
vhactive=$(cat /tmp/vhactive.txt | grep -e -- | grep -v In-use | awk -F'[()]' '{print $2}')
 for r in $vhactive; do
	r_count=$((r_count+1))
done
echo VH Available Adapters $r_count | tee -a /usr/local/scripts/sim.log
if [ $r_count == 0 ]; then
 echo No Available Adapters | tee -a /usr/local/scripts/sim.log
 echo Sleeping for 300 seconds | tee -a /usr/local/scripts/sim.log
 echo Will retry afer sleep | tee -a /usr/local/scripts/sim.log
 echo --------------------------| tee -a /usr/local/scripts/sim.log
 sleep 300
 exit
fi
if [ $vh_server == "on" ]; then
	if [ -e "/usr/local/scripts/vhcached.txt" ]; then
 		#Setting value to cached adapter
		#This way the client is always using the same adapter
		#Otherwise connectivity for clients will have gaps when the adapter changes in Central
		vhserver_device=$(cat /usr/local/scripts/vhcached.txt)
		echo Cached $vhserver_device
		#If Client is connected to more than 1 device - disconnecting
		if [[ $y_count -gt 1 ]]; then
			echo Found multiple devices in-use
   			echo Clearing out all devices in-use
			sudo /usr/sbin/vhclientx86_64 -t "AUTO USE CLEAR ALL"
			sudo /usr/sbin/vhclientx86_64 -t "STOP USING ALL LOCAL"
		fi
  	#If VirtualHere cached value does not exist
   	else
		#Generating random number to connect to a random adapter
		echo No Cached VH Device found - finding avaiable adapter
		rn_vhactive=$((1 + RANDOM % $r_count))
		#If Client is connected to more than 1 device - disconnecting
		if [[ $y_count -gt 1 ]]; then
  			echo Found multiple devices in-use
			echo Clearing out all devices in-use
			sudo /usr/sbin/vhclientx86_64 -t "AUTO USE CLEAR ALL"
			sudo /usr/sbin/vhclientx86_64 -t "STOP USING ALL LOCAL"
		fi
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
	/usr/sbin/vhclientx86_64 -t "AUTO USE PORT,$vhserver_device"
	#End Connecting to VirtualHere Server
 	echo Waiting for Adapter | tee -a /usr/local/scripts/sim.log
	#------------------------------------------------------------
	sleep 30
#End if VirtualHere Server is enabled
fi
#------------------------------------------------------------
