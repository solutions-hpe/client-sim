#!/bin/bash
version=.01
echo Download Script Version $version | tee -a /usr/local/scripts/sim.log
echo $(date) | tee -a /usr/local/scripts/sim.log
#------------------------------------------------------------
r_count=0
echo Running Download simulation
dlfile=$(cat /usr/local/scripts/downloads.txt)
for r in $dlfile; do r_count=$((r_count+1)); done
rn_dl=$((1 + RANDOM % $r_count))
r_count=0
for r in $dlfile; do
 r_count=$((r_count+1))
 if [[ $r_count == $rn_dl ]]; then
  sleep 1
  echo $(date) | tee -a /usr/local/scripts/sim.log
  echo ------------------------------| tee -a /usr/local/scripts/sim.log
  echo Simulation Details: | tee -a /usr/local/scripts/sim.log
  echo Hostname: $HOSTNAME | tee -a /usr/local/scripts/sim.log
  echo Site: $wsite | tee -a /usr/local/scripts/sim.log
  echo Site Based SSID: $site_based_ssid | tee -a /usr/local/scripts/sim.log
  echo Phy: $sim_phy | tee -a /usr/local/scripts/sim.log
  echo Simulation Load: $sim_load | tee -a /usr/local/scripts/sim.log
  echo Running Download Simulation: | tee -a /usr/local/scripts/sim.log
  echo ------------------------------| tee -a /usr/local/scripts/sim.log
  wget --waitretry=10 --read-timeout=20 --show-progress -O /tmp/file.tmp $r | tee -a /usr/local/scripts/sim.log
 fi
done
