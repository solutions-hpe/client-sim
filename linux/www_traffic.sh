#!/bin/bash
version=.04
log="/usr/local/scripts/sim.log"
wwwfile=($(< /usr/local/scripts/websites.txt))
rn_www=$((RANDOM % ${#wwwfile[@]}))
url="${wwwfile[$rn_www]}"
cpulimit -l 25 -- firefox --headless "$url"