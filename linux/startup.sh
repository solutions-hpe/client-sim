#!/bin/bash
version=.03
log="/usr/local/scripts/sim.log"
debug="/usr/local/scripts/debug-startup.log"
sudo touch "$log" "$debug" 2>/dev/null && sudo chmod a+w "$log" "$debug" 2>/dev/null || true

# Instance guard — prevent multiple concurrent startups from racing.
# Lock lives in /run/ (tmpfs) which is cleared on every boot, so stale
# locks from the previous session are physically impossible. This is safer
# than a persistent-path lock + rmdir approach: even if exec bash replaces
# this process (voiding the EXIT trap), the lock vanishes on the next reboot.
# NOTE: startup.desktop in /etc/xdg/autostart/ is intentional — it is the
# authoritative launcher for this terminal window.  update.sh was previously
# redeploying it on every update (fixed in v2.48), but we must NOT remove it
# here or the terminal window will be permanently lost after the first run.
_LOCK_FILE="/run/client-sim-startup.lock"
if ! mkdir "$_LOCK_FILE" 2>/dev/null; then
    simdebug="/usr/local/scripts/debug-simulation.log"
    sudo touch "$simdebug" 2>/dev/null || true
    echo "$(date): startup.sh already running — this window is a duplicate." >> "$debug"
    # DO NOT exit here. The parent shell is: bash -c "startup.sh ; systemctl reboot"
    # Exiting would trigger the reboot even though the real simulation is still healthy.
    # Follow debug-simulation.log so this window shows the live simulation output
    # (what the user wants to watch) instead of the startup debug log.
    echo "=== Simulation running in another session — following simulation output ==="
    exec tail -f "$simdebug"
fi
trap 'rmdir "$_LOCK_FILE" 2>/dev/null || true' EXIT INT TERM

echo Startup Script Version $version
echo Clearing Log File | tee "$debug" "$log"
echo $(date) | tee -a "$debug"
#------------------------------------------------------------
#Check Logs Script
#------------------------------------------------------------
source /usr/local/scripts/sys_mon.sh &
#------------------------------------------------------------
#Verify key settings changed - since this script is ran at startup
#this is where you should put system changes you want to make sure 
#are applied. Some of these may be set during the installer but the 
#installer is only ran one time.
#------------------------------------------------------------
gsettings set org.gnome.desktop.session idle-delay 0 2>/dev/null || true
xset s noblank
xset -dpms
xset s off
sudo rfkill unblock wifi; sudo rfkill unblock all
# Kill nm-applet so it never pops up auth dialogs — WiFi is managed by scripts
pkill -f nm-applet 2>/dev/null || true
# Suppress nm-applet autostart for this user session
mkdir -p "$HOME/.config/autostart"
cat > "$HOME/.config/autostart/nm-applet.desktop" <<'NMEOF'
[Desktop Entry]
Hidden=true
NMEOF
# Suppress nm-applet in lxsession autostart (Raspberry Pi OS / LXDE-pi)
# lxsession reads its own autostart files directly — XDG Hidden=true doesn't apply.
# Copy the system autostart to user override and strip nm-applet from it.
_lxsession_sys="/etc/xdg/lxsession/LXDE-pi/autostart"
_lxsession_user="$HOME/.config/lxsession/LXDE-pi/autostart"
if [ -f "$_lxsession_sys" ] && [ ! -f "$_lxsession_user" ]; then
  mkdir -p "$(dirname "$_lxsession_user")"
  grep -v 'nm-applet' "$_lxsession_sys" > "$_lxsession_user" || true
elif [ -f "$_lxsession_user" ] && grep -q 'nm-applet' "$_lxsession_user"; then
  sed -i '/nm-applet/d' "$_lxsession_user"
fi
# Also kill any auth agents that may show WiFi password popups
pkill -f nm-applet 2>/dev/null || true
pkill -f lxpolkit 2>/dev/null || true
pkill -f 'polkit-gnome-authentication-agent' 2>/dev/null || true
# Kill any pending nmcli secret agents that are waiting for interactive input
pkill -f 'nm-applet.*--sm-disable' 2>/dev/null || true
# NOTE: xrandr / display setup is handled exclusively by launch-terminals.sh,
# which runs before this script and owns the resolution.  Do NOT call xrandr
# here — a mode-switch event after terminals are placed causes the window
# manager to reposition every window.
#------------------------------------------------------------
#Figuring out username from hostname used to parse config
#------------------------------------------------------------
username=$(echo $HOSTNAME | cut -d "-" -f 1)
#------------------------------------------------------------
#Calling config parser script
#------------------------------------------------------------
#Calling config parser script - reads the simulation.conf file
#For values assinged to script variables
#------------------------------------------------------------
source '/usr/local/scripts/ini-parser.sh'
#------------------------------------------------------------
#Setting config file location
#------------------------------------------------------------
process_ini_file '/usr/local/scripts/simulation.conf'
#------------------------------------------------------------
#Loading user-specific overrides (keys here win over simulation.conf)
#------------------------------------------------------------
if [[ -f '/usr/local/scripts/user-overrides.conf' ]]; then
  process_ini_file '/usr/local/scripts/user-overrides.conf'
fi
#------------------------------------------------------------
# Settings read from the local config file
#Global Simulation settings
#------------------------------------------------------------
site_based_num=$(get_value 'simulation' 'site_based_num')
simulation_id=s
simulation_id+=$(echo $HOSTNAME | rev | cut -c 1-$site_based_num | rev | cut -c 1-1)
reboot_schedule=$(get_value 'simulation' 'reboot_schedule')
repo_location=$(get_value 'simulation' 'repo_location')
vh_server=$(get_value 'simulation' 'vh_server')
sim_phy=$(get_value $simulation_id 'sim_phy')
rapid_update=$(get_value 'simulation' 'rapid_update')
syslog=$(get_value 'simulation' 'syslog')
syslog_server=$(get_value 'address' 'syslog_server')
tempvar=$(get_value $username 'repo_location')
#------------------------------------------------------------
#Checking to see if this device/user has an override
#------------------------------------------------------------
if [[ -n ${tempvar} ]]; then repo_location=$tempvar; fi
tempvar=$(get_value $username 'vh_server')
if [[ -n ${tempvar} ]]; then vh_server=$tempvar; fi
tempvar=$(get_value $username 'sim_phy')
if [[ -n ${tempvar} ]]; then sim_phy=$tempvar; fi
# USB device physical-layer override — written by Proxmox agent at provisioning
# time based on the certified USB device type (wireless/wired). Highest priority.
if [[ -f '/usr/local/scripts/usb-phy-override.conf' ]]; then
  source '/usr/local/scripts/usb-phy-override.conf'
fi
#------------------------------------------------------------
#Configuring Syslog Server
#------------------------------------------------------------
if [ "$syslog" == "on" ]; then
  #Ensure the remote syslog line exists, replace if different
  if grep -q '^\*\.\*@' /etc/rsyslog.conf; then
    sudo sed -i "s|^\*\.\*@.*|*.*@${syslog_server}|" /etc/rsyslog.conf
  else
    # Insert before imuxsock if no syslog line exists
    sudo sed -i "/module(load=\"imuxsock\")/i *.*@${syslog_server}" /etc/rsyslog.conf
  fi
  #Add the comment line before the syslog line, if it doesn't exist
  if ! grep -Fxq "#Syslog Server" /etc/rsyslog.conf; then
    sudo sed -i "/\*\.\*@${syslog_server}/i #Syslog Server" /etc/rsyslog.conf
  fi
  #Ensure the imfile module exists before imuxsock
  if ! grep -Eq '^\s*(\$ModLoad\s+imfile|module\(load="imfile"\))' /etc/rsyslog.conf; then
    sudo sed -i '/module(load="imuxsock")/i $ModLoad imfile' /etc/rsyslog.conf
  fi
else
 echo Skipping Syslog Server Update | tee -a "$debug"
fi
#------------------------------------------------------------
#Scheduling Reboot
#------------------------------------------------------------
reboot_schedule=$(get_value 'simulation' 'reboot_schedule')
# Guard: an empty, zero, or non-numeric reboot_schedule would produce
# "shutdown -r +0" which reboots immediately — often mid update.sh.
# Default to 300 minutes (5 hours) if the value is missing or too small.
if [[ -z "$reboot_schedule" || ! "$reboot_schedule" =~ ^[0-9]+$ || "$reboot_schedule" -lt 60 ]]; then
    echo "WARNING: reboot_schedule='$reboot_schedule' is missing or too small — defaulting to 300 minutes" | tee -a "$debug"
    reboot_schedule=300
fi
rn=$(($reboot_schedule + RANDOM % 600))
echo Scheduling reboot in $rn minutes | tee -a "$debug"
shutdown -r +$rn
#Making sure eth0 and wlan0 are online
echo Bringing up all interfaces online | tee -a "$debug"
#------------------------------------------------------------
#Finding adapter names and setting usable variables for interfaces
#When using a physical piece of hardware we want to diable the
#interface not in use. So that we force the traffic out the interface
#set int he simulation.conf
#------------------------------------------------------------
#------------------------------------------------------------
#Finding adapter names and setting usable variables for interfaces
#------------------------------------------------------------
wladapter=$(ip -br a | grep "wlx\|wlan" | cut -d ' ' -f '1')
eadapter=$(ip -br a | grep "enp\|eno\|eth0\|eth1\|eth2\|eth3\|eth4\|eth5\|eth6\|ens\|end0" | cut -d ' ' -f '1')
if [[ -n ${wladapter} ]]; then echo WLAN Adapter name $wladapter | tee -a "$debug"; fi
if [[ -n ${eadapter} ]]; then echo Wired Adapter name $eadapter | tee -a "$debug"; fi
#------------------------------------------------------------
#Changing the MAC Address of the wireless adapter
#------------------------------------------------------------
mac_id=$(echo $HOSTNAME | rev | cut -c 3-4 | rev)
mac_id="${mac_id}:$(echo $HOSTNAME | rev | cut -c 1-2 | rev)"
if [[ -n ${wladapter} ]]; then sudo ip link set dev $wladapter up; fi
if [[ -n ${eadapter} ]]; then sudo ip link set dev $eadapter up; fi
echo -----------------------------| tee -a "$debug"
#------------------------------------------------------------
#Running Updates
#------------------------------------------------------------
echo Updating Simulation from repo | tee -a "$debug"
source '/usr/local/scripts/update.sh'
#------------------------------------------------------------
# Pre-store WiFi credentials into NetworkManager after update.sh has run.
# WHY: update.sh may have deployed a newer simulation.conf with updated
# credentials. Re-reading the conf here and registering the NM keyfile
# profile ensures NM can connect silently — no graphical agent, no popup —
# even before simulation.sh's connect_wifi() is called.
# This closes the race where nm-applet (via lxsession) pops up because NM
# has no stored profile during the startup phase.
process_ini_file '/usr/local/scripts/simulation.conf'
if [[ -f '/usr/local/scripts/user-overrides.conf' ]]; then
  process_ini_file '/usr/local/scripts/user-overrides.conf'
fi
_nm_sim_id="s$(echo "$HOSTNAME" | rev | cut -c 1-"$site_based_num" | rev | cut -c 1-1)"
_nm_target_ssid=$(get_value "$_nm_sim_id" 'ssid')
_nm_ssidpw=$(get_value "$_nm_sim_id" 'ssidpw')
_nm_site_based=$(get_value 'simulation' 'site_based_ssid')
# WHY: wsite lives under the simulation bucket section (e.g. [s1]), NOT [address].
# Reading from [address] returned an empty string, which made the pre-stored profile
# name "-PSK" instead of "DFW-PSK" — NM couldn't find it and called the graphical
# secret agent, producing the "Authentication Required" popup every boot.
_nm_wsite=$(get_value "$_nm_sim_id" 'wsite')
# Apply per-user wsite override if present (mirrors simulation.sh's apply_override logic)
_nm_username=$(echo "$HOSTNAME" | cut -d "-" -f 1)
_nm_wsite_override=$(get_value "$_nm_username" 'wsite')
[[ -n "$_nm_wsite_override" ]] && _nm_wsite="$_nm_wsite_override"
[[ "$_nm_site_based" == "on" ]] && _nm_target_ssid="${_nm_wsite}-${_nm_target_ssid}"
_nm_wladapter=$(ip -br a | grep "wlx\|wlan" | awk '{print $1}' | head -n1)
# Kill any graphical secret agent right before pre-storing so nothing intercepts NM
pkill -f nm-applet 2>/dev/null || true
pkill -f lxpolkit 2>/dev/null || true
pkill -f 'polkit-gnome-authentication-agent' 2>/dev/null || true
if [[ -n "$_nm_target_ssid" && -n "$_nm_ssidpw" && -n "$_nm_wladapter" ]]; then
  nmcli connection delete "$_nm_target_ssid" >/dev/null 2>&1 || true
  if nmcli connection add type wifi \
      con-name "$_nm_target_ssid" \
      ssid "$_nm_target_ssid" \
      wifi-sec.key-mgmt wpa-psk \
      wifi-sec.psk "$_nm_ssidpw" \
      ifname "$_nm_wladapter" >/dev/null 2>&1; then
    echo "WiFi profile pre-stored for '$_nm_target_ssid' ($wladapter)" | tee -a "$debug"
  else
    echo "WARNING: WiFi profile pre-store failed — check ssid/ssidpw in simulation.conf" | tee -a "$debug"
  fi
else
  echo "Skipping WiFi pre-store: ssid='$_nm_target_ssid' pw=$([ -n "$_nm_ssidpw" ] && echo set || echo missing) adapter='$_nm_wladapter'" | tee -a "$debug"
fi
unset _nm_sim_id _nm_target_ssid _nm_ssidpw _nm_site_based _nm_wsite _nm_wsite_override _nm_username _nm_wladapter
#------------------------------------------------------------
#Setting VirtualHere Server as a Daemon
#------------------------------------------------------------
if [ $vh_server == "on" ]; then
  echo Setting VH to autostart | tee -a "$debug"
  echo Waiting for VH Client to start | tee -a "$debug"
  sudo /usr/sbin/vhclientx86_64 -n
  sleep 5
fi
#------------------------------------------------------------
echo Setting Script Permissions | tee -a "$debug"
echo -----------------------------
cd /usr/local/scripts/ && sudo chmod +x *.sh &
#------------------------------------------------------------
#Looping Script
#------------------------------------------------------------
echo Launching Simulation Script | tee -a "$debug"
source /usr/local/scripts/simulation.sh
