#!/bin/bash
# launch-terminals.sh v0.03
# Launches and positions gnome-terminal windows for client-sim.
# Called from openbox autostart — replaces individual .desktop autostart entries.
#
# Strategy:
#   1. Auto-detect the connected display output (works on VM, HDMI, DP, eDP, Pi)
#   2. Try to set 1920x1080 — if supported, use original fixed pixel offsets
#   3. If not supported (smaller display), scale offsets proportionally
#
# Layout designed for 1920x1080 @ Monospace 13 (≈10px wide × 24px tall per cell):
#   Dashboard  (58x43)  +0+0       — left column  (58×10 = 580px right edge)
#   Journal    (88x20)  +580+0     — center, top   (580+88×10 = 1460px right edge)
#   Startup    (88x15)  +1460+525  — right, lower  (20×24+chrome ≈ 525px Y start)
#
# IMPORTANT: startup.sh must NOT call xrandr — it runs after windows are placed
# and a mode-switch event repositions every window. Resolution is set here only.

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
# Baseline values match the 1920x1080 layout above (TARGET_W/H = 1920×1080).
# On smaller screens the offsets scale down proportionally.
JOUR_X=$(( SCREEN_W * 580  / TARGET_W ))
START_X=$(( SCREEN_W * 1460 / TARGET_W ))
START_Y=$(( SCREEN_H * 525  / TARGET_H ))

# ── Ensure dbus session is available (gnome-terminal requires it) ────────────
if [[ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]]; then
  eval "$(dbus-launch --sh-syntax --exit-with-session 2>/dev/null)" || true
fi

# ── Lock gnome-terminal font so pixel offsets stay consistent ────────────────
# Layout designed for Monospace 13 at 96 dpi (≈10px wide × 24px tall per cell):
#   Dashboard (50 cols) right edge ≈ 500px  → Journal starts at +500
#   Journal   (20 rows) bottom     ≈ 525px  → Startup starts at +525 (Y)
# If windows have gaps/overlaps, change the font size here to match your display.
GTERM_PROFILE=$(gsettings get org.gnome.Terminal.ProfilesList default 2>/dev/null \
  | tr -d "'" || true)
if [[ -n "$GTERM_PROFILE" ]]; then
  dconf write \
    "/org/gnome/terminal/legacy/profiles:/:${GTERM_PROFILE}/font" \
    "'Monospace 13'" 2>/dev/null || true
  dconf write \
    "/org/gnome/terminal/legacy/profiles:/:${GTERM_PROFILE}/use-system-font" \
    "false" 2>/dev/null || true
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

# Dashboard — left column, full height (58 cols matches dashboard.sh content width)
_launch "Dashboard" \
  --title="Dashboard" \
  --geometry="58x43+0+0" \
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
