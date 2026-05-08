#!/bin/bash
# proxmox-agent.sh — Proxmox host command agent for Client-Sim
# Install as a systemd service on the Proxmox HOST (not in the LXC container).
# It polls the WebUI API for commands addressed to "proxmox".
#
# Setup:
#   cp proxmox-agent.sh /usr/local/bin/client-sim-proxmox-agent
#   chmod +x /usr/local/bin/client-sim-proxmox-agent
#   systemctl enable --now client-sim-proxmox-agent  (after creating the service unit)

set -euo pipefail

AGENT_LOG="/var/log/client-sim-proxmox-agent.log"
SERVER_URL="${CLIENT_SIM_SERVER_URL:-}"   # set via env or edit below
POLL_INTERVAL=60

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$AGENT_LOG"; }

if [[ -z "$SERVER_URL" ]]; then
  log "ERROR: CLIENT_SIM_SERVER_URL not set. Edit this script or set the env var."
  exit 1
fi

log "Proxmox agent starting. Server: $SERVER_URL"

while true; do
  response=$(curl -sS --max-time 10 \
    "$SERVER_URL/api/inbox?hostname=proxmox" 2>/dev/null || echo "")

  if [[ -n "$response" && "$response" != "[]" ]]; then
    log "Received commands: $response"

    echo "$response" | grep -o '"id":"[^"]*","action":"[^"]*"' | while IFS= read -r pair; do
      cmd_id=$(echo "$pair" | grep -o '"id":"[^"]*"' | cut -d'"' -f4)
      action=$(echo "$pair" | grep -o '"action":"[^"]*"' | cut -d'"' -f4)

      log "Executing: $cmd_id action=$action"
      status="completed"
      message=""

      case "$action" in
        reclone_vms)
          if [[ -f /opt/client-sim-repo/proxmox/clone.sh ]]; then
            bash /opt/client-sim-repo/proxmox/clone.sh && message="Reclone completed" || { status="failed"; message="clone.sh failed"; }
          else
            status="failed"; message="clone.sh not found"
          fi
          ;;
        snapshot_vms)
          errors=0
          for vmid in $(qm list | awk 'NR>1 {print $1}'); do
            qm snapshot "$vmid" "auto-$(date +%Y%m%d%H%M)" --description "client-sim auto" 2>>"$AGENT_LOG" || errors=$((errors+1))
          done
          [[ $errors -eq 0 ]] && message="Snapshots created" || { status="failed"; message="$errors snapshots failed"; }
          ;;
        start_vms)
          for vmid in $(qm list | awk 'NR>1 {print $1}'); do qm start "$vmid" 2>>"$AGENT_LOG" || true; done
          message="VMs started"
          ;;
        stop_vms)
          for vmid in $(qm list | awk 'NR>1 {print $1}'); do qm stop "$vmid" 2>>"$AGENT_LOG" || true; done
          message="VMs stopped"
          ;;
        *)
          status="failed"; message="Unknown action: $action"
          ;;
      esac

      curl -sS --max-time 10 -X POST "$SERVER_URL/api/inbox/ack" \
        -H "Content-Type: application/json" \
        -d "{\"id\":\"$cmd_id\",\"status\":\"$status\",\"message\":\"$message\"}" \
        >/dev/null 2>&1

      log "ACK: $cmd_id status=$status message=$message"
    done
  fi

  sleep "$POLL_INTERVAL"
done
