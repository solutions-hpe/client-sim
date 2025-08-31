#!/bin/bash
version=.01
echo DNS Failure Script Version $version | tee -a /usr/local/scripts/sim.log
echo $(date) | tee -a /usr/local/scripts/sim.log
#------------------------------------------------------------
dnsfile=$(cat /usr/local/scripts/dns_fail.txt)
for i in {1..10}; do
 for r in $dnsfile; do
  echo $(date) | tee -a /usr/local/scripts/sim.log
  echo ------------------------------| tee -a /usr/local/scripts/sim.log
  echo Simulation Details: | tee -a /usr/local/scripts/sim.log
  echo Hostname: $HOSTNAME | tee -a /usr/local/scripts/sim.log
  echo Site: $wsite | tee -a /usr/local/scripts/sim.log
  echo Site Based SSID: $site_based_ssid | tee -a /usr/local/scripts/sim.log
  echo Simulation Load: $sim_load | tee -a /usr/local/scripts/sim.log
  echo Kill Switch: $kill_switch | tee -a /usr/local/scripts/sim.log
  echo DNS Fail: $dns_fail | tee -a /usr/local/scripts/sim.log
  echo Running DNS Failure: | tee -a /usr/local/scripts/sim.log
  echo Simulation Iteration: $i | tee -a /usr/local/scripts/sim.log
  echo $r | tee -a /usr/local/scripts/sim.log
  echo ------------------------------| tee -a /usr/local/scripts/sim.log
  dig @$dns_bad_record_1 $r &
  dig @$dns_bad_record_2 $r &
  dig @$dns_bad_record_3 $r &
  dig @$dns_bad_ip_1 $r &
  dig @$dns_bad_ip_2 $r &
  dig @$dns_bad_ip_3 $r &
  dig @$dns_latency_1 $r &
  dig @$dns_latency_2 $r &
  dig @$dns_latency_3 $r &
  sleep 5
 done
done
