#!/bin/bash
# launch-terminals.sh v0.02
# Launches and positions gnome-terminal windows for client-sim.
# Called from openbox autostart — replaces individual .desktop autostart entries.
#
# Strategy:
#   1. Auto-detect the connected display output (works on VM, HDMI, DP, eDP, Pi)
#   2. Try to set 1920x1080 — if supported, use original fixed pixel offsets
#   3. If not supported (smaller display), scale offsets proportionally
#
# Original layout designed for 1920x1080:
#   Dashboard  (50x80)  +0+0       — left column, full height
#   Journal    (88x20)  +500+0     — center, top
#   Startup    (88x15)  +1400+525  — right, lower half
#   Update     (35x15)  +0+525     — bottom left (uncomment to enable)

SCRIPTS="/usr/local/scripts"
LOG="$SCRIPTS/sim.log"
TARGET_W=1920
TARGET_H=1080

# ── Wait for X to be ready ───────────────────────────────────────────────────
for i in $(seq 1 15); do
  xrandr --query &>/dev/null && break
  sleep 1
done

# ── Auto-detect connected display output ─────────────────────────────────────
# Covers: Virtual-1 (QEMU/Proxmox VM), HDMI-1, HDMI-0 (Pi), DP-1, eDP-1, VGA-1
OUTPUT=$(xrandr --query 2>/dev/null | awk '/ connected/ {print $1; exit}')
if [[ -z "$OUTPUT" ]]; then
  echo "$(date) launch-terminals: WARNING — no connected display found, skipping xrandr" \
    >>"$LOG"
else
  # Try to set 1920x1080; fall back to native if the mode isn't available
  if xrandr --output "$OUTPUT" --mode ${TARGET_W}x${TARGET_H} 2>/dev/null; then
    echo "$(date) launch-terminals: set ${OUTPUT} to ${TARGET_W}x${TARGET_H}" >>"$LOG"
  else
    xrandr --output "$OUTPUT" --auto 2>/dev/null
    echo "$(date) launch-terminals: ${TARGET_W}x${TARGET_H} not available on ${OUTPUT}, using native" \
      >>"$LOG"
  fi
fi

# ── Read actual resolution after xrandr ─────────────────────────────────────
SCREEN_W=$(xrandr --query 2>/dev/null \
  | awk '/\*/ {for(i=1;i<=NF;i++) if($i~/^[0-9]+x[0-9]+$/) {split($i,a,"x"); print a[1]; exit}}')
SCREEN_H=$(xrandr --query 2>/dev/null \
  | awk '/\*/ {for(i=1;i<=NF;i++) if($i~/^[0-9]+x[0-9]+$/) {split($i,a,"x"); print a[2]; exit}}')
SCREEN_W=${SCREEN_W:-$TARGET_W}
SCREEN_H=${SCREEN_H:-$TARGET_H}

echo "$(date) launch-terminals: screen=${SCREEN_W}x${SCREEN_H} output=${OUTPUT}" >>"$LOG"

# ── Calculate pixel offsets proportional to actual resolution ────────────────
# Baseline offsets are from the original 1920x1080 layout:
#   Journal X  = 500  → 500/1920  = 26.04%
#   Startup X  = 1400 → 1400/1920 = 72.92%
#   Startup Y  = 525  → 525/1080  = 48.61%
#   Update  Y  = 525  → 525/1080  = 48.61%
JOUR_X=$(( SCREEN_W * 500  / TARGET_W ))
START_X=$(( SCREEN_W * 1400 / TARGET_W ))
START_Y=$(( SCREEN_H * 525  / TARGET_H ))
UPDT_Y=$(( SCREEN_H * 525  / TARGET_H ))

# ── Ensure dbus session is available (gnome-terminal requires it) ────────────
if [[ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]]; then
  eval "$(dbus-launch --sh-syntax --exit-with-session 2>/dev/null)" || true
fi

# ── Launch helper with retry (handles dbus race at session start) ─────────────
_launch() {
  local label="$1"; shift
  for attempt in 1 2 3; do
    gnome-terminal "$@" 2>/dev/null && {
      echo "$(date) launch-terminals: opened $label" >>"$LOG"
      return 0
    }
    sleep 1
  done
  echo "$(date) launch-terminals: WARNING — $label failed after 3 attempts" >>"$LOG"
}

# ── Open terminal windows ─────────────────────────────────────────────────────

# Dashboard — left column, full height
_launch "Dashboard" \
  --title="Dashboard" \
  --geometry="50x80+0+0" \
  -- bash -c "$SCRIPTS/dashboard.sh" &

# Journal viewer — center, top
_launch "Journal" \
  --title="Journal" \
  --geometry="88x20+${JOUR_X}+0" \
  -- journalctl -f &

# Startup / Simulation — right side, lower half; reboots on exit
_launch "Simulation" \
  --title="Simulation" \
  --geometry="88x15+${START_X}+${START_Y}" \
  -- bash -c "$SCRIPTS/startup.sh ; systemctl reboot" &

# Update — bottom left (uncomment to enable)
# _launch "Update" \
#   --title="Update" \
#   --geometry="35x15+0+${UPDT_Y}" \
#   -- bash -c "$SCRIPTS/update.sh" &
