#!/bin/bash
version=.05
github=raw.githubusercontent.com
ping -c1 $github
 if [ $? -eq 0 ]; then
  echo Successful network connection to Github - updating scripts
  sudo wget https://raw.githubusercontent.com/solutions-hpe/client-sim/main/simulation.sh -O /usr/local/scripts/simulation.sh
  sudo wget https://raw.githubusercontent.com/solutions-hpe/client-sim/main/startup.sh -O /usr/local/scripts/startup.sh
  sudo wget https://raw.githubusercontent.com/solutions-hpe/client-sim/main/ini-parser.sh -O /usr/local/scripts/ini-parser.sh
  sudo wget https://raw.githubusercontent.com/solutions-hpe/client-sim/main/sim-update.sh -O /usr/local/scripts/sim-update.sh
  sudo wget https://raw.githubusercontent.com/solutions-hpe/client-sim/main/update.sh -O /usr/local/scripts/update.sh
  sudo wget https://raw.githubusercontent.com/solutions-hpe/client-sim/main/vhconnect.sh -O /usr/local/scripts/vhconnect.sh
  sudo wget https://raw.githubusercontent.com/solutions-hpe/client-sim/main/websites.txt -O /usr/local/scripts/websites.txt
  sudo wget https://raw.githubusercontent.com/solutions-hpe/client-sim/main/dns_fail.txt -O /usr/local/scripts/dns_fail.txt
  sudo wget https://raw.githubusercontent.com/solutions-hpe/client-sim/main/kill_switch.txt -O /usr/local/scripts/kill_switch.txt
  sudo chmod -R 777 /usr/local/scripts
else
 echo Network connection failed to GitHub - skipping script updates
fi
