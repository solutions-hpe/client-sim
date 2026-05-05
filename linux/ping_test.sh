#!/bin/bash
version=.02
log="/usr/local/scripts/sim.log"
debug="/usr/local/scripts/debug-ping-test.log"
echo Ping_Test Script Version $version | tee "$debug"
ping -c "$rn" "$ping_address" -s "$rn_ping_size" | tee -a "$debug"