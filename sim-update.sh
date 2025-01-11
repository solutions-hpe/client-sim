#!/bin/bash
version=.03
github=raw.githubusercontent.com
ping -c1 $github
 if [ $? -eq 0 ]; then
  echo Successful network connection to Github - updating scripts
  sudo wget -4 https://raw.githubusercontent.com/solutions-hpe/client-sim/main/simulation.sh -O /usr/local/scripts/simulation.sh
  sudo wget -4 https://raw.githubusercontent.com/solutions-hpe/client-sim/main/startup.sh -O /usr/local/scripts/startup.sh
  sudo wget -4 https://raw.githubusercontent.com/solutions-hpe/client-sim/main/ini-parser.sh -O /usr/local/scripts/ini-parser.sh
  sudo wget -4 https://raw.githubusercontent.com/solutions-hpe/client-sim/main/websites.txt -O /usr/local/scripts/websites.txt
  sudo wget -4 https://raw.githubusercontent.com/solutions-hpe/client-sim/main/dns_fail.txt -O /usr/local/scripts/dns_fail.txt
  sudo chmod -R 777 /usr/local/scripts
else
 echo Network connection failed to GitHub - skipping script updates
fi
