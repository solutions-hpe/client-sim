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
iperf3 -c $iperf_server -p $rn_iperf_port -b 1k -t $rn_iperf_time
iperf3 -c $iperf_server -p 443 -b 1k -t $rn_iperf_time
iperf3 -c $iperf_server -p 3260 -b 1k -t $rn_iperf_time
iperf3 -c $iperf_server -p 2049 -b 1k -t $rn_iperf_time
iperf3 -c $iperf_server -p 1194 -b 1k -t $rn_iperf_time
iperf3 -c $iperf_server -p 3389 -b 1k -t $rn_iperf_time
iperf3 -c $iperf_server -p 445 -b 1k -t $rn_iperf_time
iperf3 -c $iperf_server -p 80 -b 1k -t $rn_iperf_time
iperf3 -c $iperf_server -p 1433 -b 1k -t $rn_iperf_time
