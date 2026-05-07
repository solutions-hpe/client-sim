#!/usr/bin/env bash
###############################################################################
# Client-Sim — Proxmox Host Setup  v0.01
#
# Run this script directly on the Proxmox host (not inside an LXC).
#
# What it does (so far):
#   - Creates vmbr255: an internal Linux bridge with no uplink
#     Used as an isolated client-sim network. LXC containers and VMs
#     attached to vmbr255 can only talk to each other and to the
#     Client-Sim webUI LXC (which will have a second NIC on this bridge).
#
# Usage:
#   sudo bash proxmox_setup.sh
#
# Configuration variables below can be overridden before running:
#   BRIDGE=vmbr255 bash proxmox_setup.sh
#
# Requirements:
#   - Proxmox VE 7 or 8 (Debian-based)
#   - Run as root on the Proxmox host itself
###############################################################################

set -euo pipefail

###############################################################################
# Configuration — override via environment variables if needed
###############################################################################
BRIDGE="${BRIDGE:-vmbr255}"
BRIDGE_COMMENT="${BRIDGE_COMMENT:-Client-Sim internal isolated network}"
INTERFACES_FILE="/etc/network/interfaces"

###############################################################################
# Colours & logging
###############################################################################
COL_RESET="\033[0m"
COL_GREEN="\033[0;32m"
COL_YELLOW="\033[1;33m"
COL_RED="\033[0;31m"
COL_BOLD="\033[1m"

ts()   { date "+%H:%M:%S"; }
info() { echo -e "[$(ts)] ${COL_BOLD}INFO${COL_RESET}  $*"; }
ok()   { echo -e "[$(ts)] ${COL_GREEN}OK${COL_RESET}    $*"; }
warn() { echo -e "[$(ts)] ${COL_YELLOW}WARN${COL_RESET}  $*"; }
err()  { echo -e "[$(ts)] ${COL_RED}ERR${COL_RESET}   $*" >&2; }

###############################################################################
# Preflight checks
###############################################################################
echo
echo "============================================================"
echo "  Client-Sim Proxmox Setup  v0.01"
echo "  $(date)"
echo "============================================================"
echo "  Bridge  : $BRIDGE"
echo "  Comment : $BRIDGE_COMMENT"
echo "  Config  : $INTERFACES_FILE"
echo "============================================================"
echo

if [[ $EUID -ne 0 ]]; then
  err "This script must be run as root."
  exit 1
fi

if [[ ! -f /etc/pve/version ]]; then
  err "This script must be run on a Proxmox VE host."
  exit 1
fi

###############################################################################
# STEP 1 — Check if bridge already exists
###############################################################################
info "Checking if ${BRIDGE} already exists..."

if grep -qE "^iface ${BRIDGE} " "$INTERFACES_FILE" 2>/dev/null; then
  warn "${BRIDGE} is already defined in ${INTERFACES_FILE} — skipping creation."
  echo
  echo "Current definition:"
  grep -A8 "iface ${BRIDGE}" "$INTERFACES_FILE" || true
  echo
else
  ###############################################################################
  # STEP 2 — Append bridge definition to /etc/network/interfaces
  ###############################################################################
  info "Adding ${BRIDGE} to ${INTERFACES_FILE}..."

  # Backup interfaces file first
  cp "$INTERFACES_FILE" "${INTERFACES_FILE}.bak.$(date +%Y%m%d%H%M%S)"
  ok "Backed up ${INTERFACES_FILE}"

  cat >> "$INTERFACES_FILE" <<EOF

# ${BRIDGE_COMMENT}
auto ${BRIDGE}
iface ${BRIDGE} inet manual
        bridge-ports none
        bridge-stp off
        bridge-fd 0
        bridge-maxwait 0
# END ${BRIDGE}
EOF

  ok "${BRIDGE} definition added to ${INTERFACES_FILE}"
fi

###############################################################################
# STEP 3 — Bring the bridge up now without rebooting
###############################################################################
info "Bringing up ${BRIDGE}..."

if ip link show "$BRIDGE" &>/dev/null; then
  ok "${BRIDGE} is already up"
else
  if command -v ifup &>/dev/null; then
    ifup "$BRIDGE" 2>/dev/null && ok "${BRIDGE} brought up with ifup" || {
      warn "ifup failed — trying ip link directly"
      ip link add name "$BRIDGE" type bridge
      ip link set "$BRIDGE" up
      ok "${BRIDGE} brought up with ip link"
    }
  else
    ip link add name "$BRIDGE" type bridge
    ip link set "$BRIDGE" up
    ok "${BRIDGE} brought up with ip link"
  fi
fi

###############################################################################
# STEP 4 — Verify
###############################################################################
echo
echo "============================================================"
echo "  Verification"
echo "============================================================"

if ip link show "$BRIDGE" &>/dev/null; then
  STATE=$(ip link show "$BRIDGE" | grep -oE 'state \S+' | awk '{print $2}')
  echo -e "  ${COL_GREEN}✓${COL_RESET}  ${BRIDGE} exists   (state: ${STATE})"
else
  echo -e "  ${COL_RED}✗${COL_RESET}  ${BRIDGE} NOT found"
fi

if grep -q "auto ${BRIDGE}" "$INTERFACES_FILE"; then
  echo -e "  ${COL_GREEN}✓${COL_RESET}  ${BRIDGE} in ${INTERFACES_FILE}"
else
  echo -e "  ${COL_RED}✗${COL_RESET}  ${BRIDGE} NOT in ${INTERFACES_FILE}"
fi

echo
echo "============================================================"
echo "  Next steps"
echo "============================================================"
echo "  1. In Proxmox UI → System → Network, you should now see ${BRIDGE}"
echo "  2. Attach the Client-Sim webUI LXC to ${BRIDGE} as a second NIC"
echo "  3. Run the Client-Sim LXC installer (install-lxc.sh) — it will"
echo "     configure the static IP and dnsmasq DHCP on that interface"
echo "  4. Attach client VMs/LXCs to ${BRIDGE} and set them to DHCP"
echo "============================================================"
echo
