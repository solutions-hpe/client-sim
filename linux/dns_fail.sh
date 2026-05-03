#!/bin/bash
version=.01
echo DNS Failure Script Version $version | tee -a /usr/local/scripts/sim.log
echo $(date) | tee -a /usr/local/scripts/sim.log
#------------------------------------------------------------
source '/usr/local/scripts/ini-parser.sh'
process_ini_file '/usr/local/scripts/simulation.conf'
dnsfile=$(< /usr/local/scripts/dns_fail.txt)
dns_latency_1=$(get_value 'address' 'dns_latency_1')
dns_latency_2=$(get_value 'address' 'dns_latency_2')
dns_latency_3=$(get_value 'address' 'dns_latency_3')
dns_bad_ip_1=$(get_value 'address' 'dns_bad_ip_1')
dns_bad_ip_2=$(get_value 'address' 'dns_bad_ip_2')
dns_bad_ip_3=$(get_value 'address' 'dns_bad_ip_3')
dns_bad_record_1=$(get_value 'address' 'dns_bad_record_1')
dns_bad_record_2=$(get_value 'address' 'dns_bad_record_2')
dns_bad_record_3=$(get_value 'address' 'dns_bad_record_3')
bad_records=($dns_bad_record_1 $dns_bad_record_2 $dns_bad_record_3)
bad_ips=($dns_bad_ip_1 $dns_bad_ip_2 $dns_bad_ip_3)
latencies=($dns_latency_1 $dns_latency_2 $dns_latency_3)
for i in {1..10}; do
  for r in $dnsfile; do
   echo $(date) | tee -a /usr/local/scripts/sim.log
   echo ------------------------------| tee -a /usr/local/scripts/sim.log
   echo DNS Fail: $dns_fail | tee -a /usr/local/scripts/sim.log
   echo Running DNS Failure: | tee -a /usr/local/scripts/sim.log
   echo Simulation Iteration: $i | tee -a /usr/local/scripts/sim.log
   echo $r | tee -a /usr/local/scripts/sim.log
   echo ------------------------------| tee -a /usr/local/scripts/sim.log
   for server in "${bad_records[@]}" "${bad_ips[@]}" "${latencies[@]}"; do
     dig @$server $r
   done
   sleep 5
  done
done
