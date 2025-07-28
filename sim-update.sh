#!/bin/bash
version=.15
#Making backup of script
echo Making backup of Script
cp /usr/local/scripts/sim-update.sh /usr/local/scripts/sim-update-backup.sh
#------------------------------------------------------------
source '/usr/local/scripts/ini-parser.sh'
#------------------------------------------------------------
#Setting config file location
#------------------------------------------------------------
process_ini_file '/usr/local/scripts/simulation.conf'
#------------------------------------------------------------
public_repo=$(get_value 'simulation' 'public_repo')
repo_location=$(get_value 'simulation' 'repo_location')
#------------------------------------------------------------
#repo_location=https://raw.githubusercontent.com/solutions-hpe/client-sim/lrb/
sleep 5
github=raw.githubusercontent.com
ping -c1 $github
 if [ $? -eq 0 ]; then
  echo Successful network connection to Github - updating scripts
   sudo wget --waitretry=10 --read-timeout=20 --timeout=15 $repo_location"dns_fail.txt" -O /usr/local/scripts/dns_fail.txt
   sleep 1
   sudo wget --waitretry=10 --read-timeout=20 --timeout=15 $repo_location"kill_switch.txt" -O /usr/local/scripts/kill_switch.txt
   sleep 1
   sudo wget --waitretry=10 --read-timeout=20 --timeout=15 $repo_location"websites.txt" -O /usr/local/scripts/websites.txt
   sleep 1
   sudo wget --waitretry=10 --read-timeout=20 --timeout=15 $repo_location"downloads.txt" -O /usr/local/scripts/downloads.txt
   sleep 1
   sudo wget --waitretry=10 --read-timeout=20 --timeout=15 $repo_location"simulation.sh" -O /usr/local/scripts/simulation.sh
   sleep 1
   sudo wget --waitretry=10 --read-timeout=20 --timeout=15 $repo_location"startup.sh" -O /usr/local/scripts/startup.sh
   sleep 1
   sudo wget --waitretry=10 --read-timeout=20 --timeout=15 $repo_location"ini-parser.sh" -O /usr/local/scripts/ini-parser.sh
   sleep 1
   sudo wget --waitretry=10 --read-timeout=20 --timeout=15 $repo_location"sim-update.sh" -O /usr/local/scripts/sim-update.sh
   sleep 1
   sudo wget --waitretry=10 --read-timeout=20 --timeout=15 $repo_location"update.sh" -O /usr/local/scripts/update.sh
   sleep 1
   sudo wget --waitretry=10 --read-timeout=20 --timeout=15 $repo_location"vhconnect.sh" -O /usr/local/scripts/vhconnect.sh
   sleep 1
   sudo wget --waitretry=10 --read-timeout=20 --timeout=15 $repo_location"sys_mon.sh" -O /usr/local/scripts/sys_mon.sh
   sleep 1
   sudo wget --waitretry=10 --read-timeout=20 --timeout=15 $repo_location"configs/simulation.conf" -O /usr/local/scripts/simulation.conf
   sleep 1
   sudo chmod -R 777 /usr/local/scripts
   echo Simulation Script Version
   cat /usr/local/scripts/simulation.sh | grep version=
   echo System Monitor Script Version
   cat /usr/local/scripts/sys_mon.sh | grep version=
   echo Startup Script Version
   cat /usr/local/scripts/startup.sh | grep version=
   echo Update Script Version
   cat /usr/local/scripts/update.sh | grep version=
   echo VHConnect Script Version
   cat /usr/local/scripts/vhconnect.sh | grep version=
else
 echo Network connection failed to GitHub - skipping script updates
fi
