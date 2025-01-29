#!/bin/bash
vversion=.01
echo --------------------------| tee /usr/local/scripts/sim.log
echo VHConnect Script Version $vversion | tee -a /usr/local/scripts/sim.log
echo $(date) | tee -a /usr/local/scripts/sim.log
#Checking to see if there is a cache device to connect to
echo VH Server is $vh_server | tee -a /usr/local/scripts/sim.log
if [ $vh_server == "on" ]; then
	if [ -e "/usr/local/scripts/vhcached.txt" ]; then
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
		vhactive=$(cat /tmp/vhactive.txt | grep -e -- | grep -v you | awk -F'[()]' '{print $2}')
		for r in $vhactive; do
			y_count=$((y_count+1))
		done
		echo VH Record Count $r_count | tee -a /usr/local/scripts/sim.log
		echo VH In-Use $y_count | tee -a /usr/local/scripts/sim.log
		#Generating random number to connect to a random adapter
		rn_vhactive=$((1 + RANDOM % $r_count))
		#If Client is connected to more than 1 device - disconnecting
		echo Clearing out all devices in-use - found multiple devices in-use | tee -a /usr/local/scripts/sim.log
		if [[ $y_count -gt 1 ]]; then /usr/sbin/vhclientx86_64 -t "AUTO USE CLEAR ALL" | tee -a /usr/local/scripts/sim.log
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
	/usr/sbin/vhclientx86_64 -t "AUTO USE DEVICE,$vhserver_device" | tee -a /usr/local/scripts/sim.log
	#End Connecting to VirtualHere Server
	#------------------------------------------------------------
	echo Waiting for Adapter | tee -a /usr/local/scripts/sim.log
	sleep 30
#End if VirtualHere Server is enabled
fi
#------------------------------------------------------------
