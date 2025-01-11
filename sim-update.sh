#!/bin/bash
version=.02
$github=raw.githubusercontent.com
if [ ping -c1 $github 1>/dev/null 2>/dev/null ]; then
sudo wget -4 https://raw.githubusercontent.com/solutions-hpe/client-sim/main/simulation.sh -O /usr/local/scripts/simulation.sh
sudo wget -4 https://raw.githubusercontent.com/solutions-hpe/client-sim/main/startup.sh -O /usr/local/scripts/startup.sh
sudo wget -4 https://raw.githubusercontent.com/solutions-hpe/client-sim/main/ini-parser.sh -O /usr/local/scripts/ini-parser.sh
sudo wget -4 https://raw.githubusercontent.com/solutions-hpe/client-sim/main/websites.txt -O /usr/local/scripts/websites.txt
sudo wget -4 https://raw.githubusercontent.com/solutions-hpe/client-sim/main/dns_fail.txt -O /usr/local/scripts/dns_fail.txt
sudo chmod -R 777 /usr/local/scripts
fi
