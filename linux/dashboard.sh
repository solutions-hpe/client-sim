#!/bin/bash
#------------------------------------------------------------
# Simulation Dashboard (Read-only monitor)
#------------------------------------------------------------
log="/usr/local/scripts/sim.log"
refresh_rate=5
#------------------------------------------------------------
# Helper: get WiFi status
#------------------------------------------------------------
get_wifi_status() {
  ssid=$(nmcli -t -f active,ssid dev wifi | awk -F: '$1=="yes"{print $2}')
  if [[ -n "$ssid" ]]; then
    echo "CONNECTED ($ssid)"
  else
    echo "DISCONNECTED"
  fi
}
#------------------------------------------------------------
# Helper: get gateway status
#------------------------------------------------------------
get_gateway_status() {
  gw=$(ip route | grep -oP 'default via \K\S+')
  if [[ -z "$gw" ]]; then
    echo "NOT FOUND"
    return
  fi
  if ping -c1 -W1 "$gw" >/dev/null 2>&1; then
    echo "ONLINE ($gw)"
  else
    echo "OFFLINE ($gw)"
  fi
}
#------------------------------------------------------------
# Helper: simulation process status
#------------------------------------------------------------
get_sim_status() {
  for s in \
    firefox-esr \
    ping_test.sh \
    iperf.sh \
    download.sh \
    dns_fail.sh
  do
    if pgrep -f "$s" >/dev/null 2>&1; then
      echo "[RUNNING] $s"
    else
      echo "[STOPPED]  $s"
    fi
  done
}
#------------------------------------------------------------
# Main dashboard loop
#------------------------------------------------------------
while true; do
  clear
  echo "            SIMULATION DASHBOARD (LIVE)              "
  echo "Time:        $(date)"
  echo "Hostname:    $HOSTNAME"
  echo "WiFi Status: $(get_wifi_status)"
  echo "Gateway:     $(get_gateway_status)"
  echo "--------------------------------------------------"
  echo "Active Simulations:"
  get_sim_status
  echo "--------------------------------------------------"
  # Optional: show last log lines (helps debugging)
  echo "Last Log Entries:"
  tail -n 5 "$log" 2>/dev/null
  echo "=================================================="
  sleep "$refresh_rate"
done