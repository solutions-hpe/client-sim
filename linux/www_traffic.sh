#!/bin/bash
version=.02
log="/usr/local/scripts/sim.log"
wwwfile=($(< /usr/local/scripts/websites.txt))
rn_www=$((RANDOM % ${#wwwfile[@]}))
url="${wwwfile[$rn_www]}"
firefox --headless "$url" &