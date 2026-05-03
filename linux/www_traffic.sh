#!/bin/bash
version=.01
echo WWW Traffic Script Version $version | tee -a /usr/local/scripts/sim.log
log="/usr/local/scripts/sim.log"
wwwfile=($(< /usr/local/scripts/websites.txt))
rn_www=$((RANDOM % ${#wwwfile[@]}))
url="${wwwfile[$rn_www]}"
echo "$(date)" | tee -a "$log"
echo "------------------------------" | tee -a "$log"
if [ "$vh_server" == "off" ]; then
  echo "Phy: $sim_phy" | tee -a "$log"
fi
echo "Simulation Load: $sim_load" | tee -a "$log"
echo "Website: $url" | tee -a "$log"
echo "------------------------------" | tee -a "$log"
firefox --headless "$url" >> "$log" 2>&1 &