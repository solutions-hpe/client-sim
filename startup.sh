#!/bin/bash
#Setting Virtual Here to run as a Daemon
sudo /usr/local/virtualhere/vhuit64 -n
#Waiting for System & VirtualHere to start
echo Waiting for startup | tee /usr/local/scripts/sim.log
sleep 30 | tee -a /usr/local/scripts/sim.log
#------------------------------------------------------------
echo Updating Scripts | tee -a /usr/local/scripts/sim.log
#smbclient '//100.127.1.254/Public' -c 'lcd /usr/local/scripts/; cd Scripts; prompt; mget *' -N
sudo wget https://raw.githubusercontent.com/solutions-hpe/client-sim/main/simulation.sh -O /usr/local/scripts/simulation.sh
#------------------------------------------------------------
echo Setting Script Permissions | tee -a /usr/local/scripts/sim.log
cd /usr/local/scripts/ && chmod +x *.sh
echo Scheduling Reboot | tee -a /usr/local/scripts/sim.log
#------------------------------------------------------------
/sbin/shutdown -r 480
#------------------------------------------------------------
#Dumping Current Device List
/usr/local/virtualhere/vhuit64 -t LIST -r /tmp/vhactive.txt
#------------------------------------------------------------
echo Launching Simulation Script | tee -a /usr/local/scripts/sim.log
#Looping Script
source /usr/local/scripts/simulation.sh
