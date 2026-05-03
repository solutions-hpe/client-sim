#!/bin/bash
version=.02
log="/usr/local/scripts/sim.log"
ping -c "$rn" "$ping_address" -s "$rn_ping_size"