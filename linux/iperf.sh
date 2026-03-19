#!/bin/bash
version=.01
echo iPerf Script Version $version | tee -a /usr/local/scripts/sim.log
echo $(date) | tee -a /usr/local/scripts/sim.log
#------------------------------------------------------------
echo $(date) | tee -a /usr/local/scripts/sim.log
echo ------------------------------| tee -a /usr/local/scripts/sim.log
echo iPerf Server: $iperf_server | tee -a /usr/local/scripts/sim.log
echo iPerf Port: $rn_iperf_port | tee -a /usr/local/scripts/sim.log
echo iPerf Time: $rn_iperf_time | tee -a /usr/local/scripts/sim.log
echo Running iPerf simulation: | tee -a /usr/local/scripts/sim.log
echo ------------------------------| tee -a /usr/local/scripts/sim.log
ports=($rn_iperf_port 443 3260 2049 1194 3389 445 80 1433)
for port in "${ports[@]}"; do
  iperf3 -c $iperf_server -p $port -b 1k -t $rn_iperf_time
done
