#!/bin/bash
version=.12
#Making backup of script
echo Making backup of Script
cp /usr/local/scripts/sim-update.sh /usr/local/scripts/sim-update-backup.sh
sleep 5
github=raw.githubusercontent.com
ping -c1 $github
 if [ $? -eq 0 ]; then
  echo Successful network connection to Github - updating scripts
   sudo wget --waitretry=10 --read-timeout=20 --timeout=15 https://raw.githubusercontent.com/solutions-hpe/client-sim/main/dns_fail.txt -O /usr/local/scripts/dns_fail.txt
   sleep 1
   sudo wget --waitretry=10 --read-timeout=20 --timeout=15 https://raw.githubusercontent.com/solutions-hpe/client-sim/main/kill_switch.txt -O /usr/local/scripts/kill_switch.txt
   sleep 1
   sudo wget --waitretry=10 --read-timeout=20 --timeout=15 https://raw.githubusercontent.com/solutions-hpe/client-sim/main/websites.txt -O /usr/local/scripts/websites.txt
   sleep 1
   sudo wget --waitretry=10 --read-timeout=20 --timeout=15 https://raw.githubusercontent.com/solutions-hpe/client-sim/main/simulation.sh -O /usr/local/scripts/simulation.sh
   sleep 1
   sudo wget --waitretry=10 --read-timeout=20 --timeout=15 https://raw.githubusercontent.com/solutions-hpe/client-sim/main/startup.sh -O /usr/local/scripts/startup.sh
   sleep 1
   sudo wget --waitretry=10 --read-timeout=20 --timeout=15 https://raw.githubusercontent.com/solutions-hpe/client-sim/main/ini-parser.sh -O /usr/local/scripts/ini-parser.sh
   sleep 1
   sudo wget --waitretry=10 --read-timeout=20 --timeout=15 https://raw.githubusercontent.com/solutions-hpe/client-sim/main/sim-update.sh -O /usr/local/scripts/sim-update.sh
   sleep 1
   sudo wget --waitretry=10 --read-timeout=20 --timeout=15 https://raw.githubusercontent.com/solutions-hpe/client-sim/main/update.sh -O /usr/local/scripts/update.sh
   sleep 1
   sudo wget --waitretry=10 --read-timeout=20 --timeout=15 https://raw.githubusercontent.com/solutions-hpe/client-sim/main/vhconnect.sh -O /usr/local/scripts/vhconnect.sh
   sleep 1
   sudo wget --waitretry=10 --read-timeout=20 --timeout=15 https://raw.githubusercontent.com/solutions-hpe/client-sim/main/sys_mon.sh -O /usr/local/scripts/sys_mon.sh
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
   echo DNS Fail Version
   cat /usr/local/scripts/dns_fail.txt | grep version=
   echo Kill Switch Version
   cat /usr/local/scripts/kill_switch.txt | grep version=
   echo Websites Version
   cat /usr/local/scripts/websites.txt | grep version=
else
 echo Network connection failed to GitHub - skipping script updates
fi
