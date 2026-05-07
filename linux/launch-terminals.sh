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

# ── Remove stale X11 config that used the wrong driver ───────────────────────
# Prior versions wrote a modesetting config; fbdev is correct for RPi OS in VM.
sudo rm -f /etc/X11/xorg.conf.d/99-client-sim-resolution.conf 2>/dev/null || true

# ── Set framebuffer resolution in /boot/config.txt (Raspberry Pi OS) ─────────
# On RPi OS the framebuffer is controlled by the firmware at boot, not by the
# kernel driver. xrandr and X11 configs have no effect until this is set.
# We update config.txt once and log that a reboot is needed.
for BOOT_CONF in /boot/firmware/config.txt /boot/config.txt; do
  [[ -f "$BOOT_CONF" ]] || continue
  NEEDS_REBOOT=false
  for PARAM in "framebuffer_width=${TARGET_W}" "framebuffer_height=${TARGET_H}"; do
    KEY="${PARAM%%=*}"
    if grep -q "^${KEY}=" "$BOOT_CONF" 2>/dev/null; then
      sudo sed -i "s|^${KEY}=.*|${PARAM}|" "$BOOT_CONF" 2>/dev/null && NEEDS_REBOOT=true
    else
      echo "$PARAM" | sudo tee -a "$BOOT_CONF" >/dev/null && NEEDS_REBOOT=true
    fi
  done
  if $NEEDS_REBOOT; then
    echo "$(date) launch-terminals: updated ${BOOT_CONF} with ${TARGET_W}x${TARGET_H} — reboot required" >>"$LOG"
  fi
  break  # only update the first config.txt found
done

# ── Write X11 resolution config (takes effect on next X session start) ───────
# Use the fbdev driver — Raspberry Pi OS ARM kernel does not ship bochs-drm so
# the modesetting driver has no DRM device to attach to.  fbdev reads from
# /dev/fb0 whose resolution is set by /boot/config.txt above.
XCONF_DIR="/etc/X11/xorg.conf.d"
XCONF_FILE="$XCONF_DIR/99-client-sim-resolution.conf"
if [[ ! -f "$XCONF_FILE" ]]; then
  sudo mkdir -p "$XCONF_DIR" 2>/dev/null
  sudo tee "$XCONF_FILE" >/dev/null <<EOF
# Client-Sim: force ${TARGET_W}x${TARGET_H} — written by launch-terminals.sh
# Delete this file to regenerate.
Section "Device"
    Identifier  "RPi VGA"
    Driver      "fbdev"
    Option      "fbdev" "/dev/fb0"
EndSection

Section "Screen"
    Identifier  "Default Screen"
    Device      "RPi VGA"
    DefaultDepth 24
    SubSection "Display"
        Depth   24
        Virtual ${TARGET_W} ${TARGET_H}
        Modes   "${TARGET_W}x${TARGET_H}"
    EndSubSection
EndSection
EOF
  echo "$(date) launch-terminals: wrote fbdev X11 config ${XCONF_FILE}" >>"$LOG"
fi

# ── Auto-detect connected display output ─────────────────────────────────────
# Covers: Virtual-1 (QEMU/Proxmox VM), HDMI-A-1 (RPi), HDMI-1, DP-1, eDP-1
OUTPUT=$(xrandr --query 2>/dev/null | awk '/ connected/ {print $1; exit}')
if [[ -z "$OUTPUT" ]]; then
  echo "$(date) launch-terminals: WARNING — no connected display found, skipping xrandr" \
    >>"$LOG"
else
  MODE_NAME="${TARGET_W}x${TARGET_H}"

  # Create the mode if it isn't already listed (needed on QEMU Virtual-1 displays)
  if ! xrandr --query 2>/dev/null | grep -q "   ${TARGET_W}x${TARGET_H}"; then
    if command -v cvt &>/dev/null; then
      MODELINE=$(cvt "$TARGET_W" "$TARGET_H" 60 | awk '/Modeline/{$1=$2=""; print $0}' | xargs)
    else
      MODELINE="173.00 1920 2048 2248 2576 1080 1083 1088 1120 -hsync +vsync"
    fi
    xrandr --newmode "$MODE_NAME" $MODELINE 2>/dev/null || true
    xrandr --addmode "$OUTPUT" "$MODE_NAME" 2>/dev/null || true
    echo "$(date) launch-terminals: created mode ${MODE_NAME} on ${OUTPUT}" >>"$LOG"
  fi

  # Set the mode, then force the framebuffer size.
  # --fb forces the virtual framebuffer to the target dimensions even if the
  # underlying driver reports a smaller preferred size (common on Raspberry Pi OS).
  if xrandr --output "$OUTPUT" --mode "$MODE_NAME" --fb "${TARGET_W}x${TARGET_H}" 2>/dev/null; then
    echo "$(date) launch-terminals: set ${OUTPUT} to ${MODE_NAME}" >>"$LOG"
  else
    # Last resort: just force the framebuffer size without changing the named mode
    xrandr --fb "${TARGET_W}x${TARGET_H}" 2>/dev/null || true
    xrandr --output "$OUTPUT" --auto 2>/dev/null || true
    echo "$(date) launch-terminals: WARNING — mode set failed, forced --fb ${TARGET_W}x${TARGET_H}" \
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
