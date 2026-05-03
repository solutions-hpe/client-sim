#!/bin/bash
version=.02
echo Download Script Version $version | tee -a /usr/local/scripts/sim.log
echo $(date) | tee -a /usr/local/scripts/sim.log
#------------------------------------------------------------
r_count=0
echo Running Download simulation
dlfile=($(< /usr/local/scripts/downloads.txt))
r_count=${#dlfile[@]}
rn_dl=$((RANDOM % r_count))
url=${dlfile[rn_dl]}
sleep 1
echo $(date) | tee -a /usr/local/scripts/sim.log
echo ------------------------------| tee -a /usr/local/scripts/sim.log
echo Running Download Simulation: | tee -a /usr/local/scripts/sim.log
echo ------------------------------| tee -a /usr/local/scripts/sim.log
wget --waitretry=10 --read-timeout=20 --show-progress -O /tmp/file.tmp "$url"
