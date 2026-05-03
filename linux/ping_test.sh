#!/bin/bash
version=.01
log="/usr/local/scripts/sim.log"
echo Ping Test Script Version $version | tee -a "$log"
echo "$(date)" | tee -a "$log"
echo "------------------------------" | tee -a "$log"
echo "Ping Simulation Starting" | tee -a "$log"
echo "Ping Address: $ping_address" | tee -a "$log"
echo "Ping Payload: $rn_ping_size" | tee -a "$log"
echo "Ping Count: $rn" | tee -a "$log"
echo "------------------------------" | tee -a "$log"

ping -c "$rn" "$ping_address" -s "$rn_ping_size" >> "$log" 2>&1

echo "Ping Simulation Complete" | tee -a "$log"