#!/bin/bash
version=.05
echo --------------------------| tee /usr/local/scripts/sim.log
echo Startup Script Version $version | tee -a /usr/local/scripts/sim.log
echo $(date) | tee -a /usr/local/scripts/sim.log
echo --------------------------| tee -a /usr/local/scripts/sim.log
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
#------------------------------------------------------------
#Making sure eth0 and wlan0 are online
echo Bringing all interfaces online | tee -a /usr/local/scripts/sim.log
sudo ifconfig eth0 up
sudo ifconfig wlan0 up
#Sleeping for 30 seconds to bring up network interaces
sleep 30
echo Wating for sytem startup | tee -a /usr/local/scripts/sim.log
echo --------------------------| tee -a /usr/local/scripts/sim.log
#------------------------------------------------------------
#Setting VirtualHere Server as a Daemon
if [ $vh_server == "on" ]; then
  echo Waiting for VH startup | tee -a /usr/local/scripts/sim.log
  sudo /usr/local/virtualhere/vhuit64 -n
  sleep 30
fi
#------------------------------------------------------------
if [ $public_repo == "on" ]; then
  echo Updating Scripts - GitHub | tee -a /usr/local/scripts/sim.log
  echo --------------------------| tee -a /usr/local/scripts/sim.log
  #Downloading latest scripts from GitHub
  sudo wget https://raw.githubusercontent.com/solutions-hpe/client-sim/main/simulation.sh -O /usr/local/scripts/simulation.sh
  sudo wget https://raw.githubusercontent.com/solutions-hpe/client-sim/main/startup.sh -O /usr/local/scripts/startup.sh
  sudo wget https://raw.githubusercontent.com/solutions-hpe/client-sim/main/ini-parser.sh -O /usr/local/scripts/ini-parser.sh
  sudo wget https://raw.githubusercontent.com/solutions-hpe/client-sim/main/websites.txt -O /usr/local/scripts/websits.txt
  sudo wget https://raw.githubusercontent.com/solutions-hpe/client-sim/main/dns_fail.txt -O /usr/local/scripts/dns_fail.txt
else
  echo Updating Scripts - SMB | tee -a /usr/local/scripts/sim.log
  echo --------------------------| tee -a /usr/local/scripts/sim.log
  #Using local network repsotory if defined
  #smbclient $smb_address -c 'lcd /usr/local/scripts/; cd Scripts; prompt; mget *' -N
fi
#------------------------------------------------------------
echo Setting Script Permissions | tee -a /usr/local/scripts/sim.log
echo --------------------------| tee -a /usr/local/scripts/sim.log
cd /usr/local/scripts/ && sudo chmod +x *.sh
echo Scheduling Reboot | tee -a /usr/local/scripts/sim.log
/sbin/shutdown -r 480
echo --------------------------| tee -a /usr/local/scripts/sim.log
#------------------------------------------------------------

#------------------------------------------------------------
#Dumping Current Device List
/usr/local/virtualhere/vhuit64 -t LIST -r /tmp/vhactive.txt
#------------------------------------------------------------
echo Launching Simulation Script | tee -a /usr/local/scripts/sim.log
#Looping Script
source /usr/local/scripts/simulation.sh
