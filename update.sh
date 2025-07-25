#!/bin/bash
version=.14
echo ------------------------------| tee -a /usr/local/scripts/sim.log
echo Update Script Version $version | tee -a /usr/local/scripts/sim.log
echo $(date) | tee -a /usr/local/scripts/sim.log
#------------------------------------------------------------
#Updating Scripts
#------------------------------------------------------------
#$repo_location=https://raw.githubusercontent.com/solutions-hpe/main/
echo Updating Scripts | tee -a /usr/local/scripts/sim.log
github=raw.githubusercontent.com
if [ $public_repo == "on" ]; then
 #Using remote GitHub repo
 ping -c1 $github
  if [ $? -eq 0 ]; then
   echo Successful network connection to Github - updating scripts
   sudo wget --waitretry=10 --read-timeout=20 --timeout=15 $repo_location"dns_fail.txt" -O /usr/local/scripts/dns_fail.txt
   sleep 1
   sudo wget --waitretry=10 --read-timeout=20 --timeout=15 $repo_location"kill_switch.txt" -O /usr/local/scripts/kill_switch.txt
   sleep 1
   sudo wget --waitretry=10 --read-timeout=20 --timeout=15 $repo_location"websites.txt" -O /usr/local/scripts/websites.txt
   sleep 1
   sudo wget --waitretry=10 --read-timeout=20 --timeout=15 $repo_location"downloads.txt" -O /usr/local/scripts/downloads.txt
   sleep 1
   sudo wget --waitretry=10 --read-timeout=20 --timeout=15 $repo_location"simulation.sh" -O /usr/local/scripts/simulation.sh
   sleep 1
   sudo wget --waitretry=10 --read-timeout=20 --timeout=15 $repo_location"startup.sh" -O /usr/local/scripts/startup.sh
   sleep 1
   sudo wget --waitretry=10 --read-timeout=20 --timeout=15 $repo_location"ini-parser.sh" -O /usr/local/scripts/ini-parser.sh
   sleep 1
   sudo wget --waitretry=10 --read-timeout=20 --timeout=15 $repo_location"sim-update.sh" -O /usr/local/scripts/sim-update.sh
   sleep 1
   sudo wget --waitretry=10 --read-timeout=20 --timeout=15 $repo_location"update.sh" -O /usr/local/scripts/update.sh
   sleep 1
   sudo wget --waitretry=10 --read-timeout=20 --timeout=15 $repo_location"vhconnect.sh" -O /usr/local/scripts/vhconnect.sh
   sleep 1
   sudo wget --waitretry=10 --read-timeout=20 --timeout=15 $repo_location"sys_mon.sh" -O /usr/local/scripts/sys_mon.sh
   sleep 1
   sudo wget --waitretry=10 --read-timeout=20 --timeout=15 $repo_location"configs/simulation.conf" -O /usr/local/scripts/simulation.conf
   sleep 1
   sudo chmod -R 777 /usr/local/scripts
  else
   echo Network connection failed to GitHub - skipping script updates
  fi
 else
  #Local repo defined in the conf file
  smbclient $smb_location -N -c 'lcd /usr/local/scripts/; cd Scripts; prompt; mget *'
fi
#------------------------------------------------------------
#End Updating Scripts
#------------------------------------------------------------
echo Creating auto Start files | tee -a /tmp/client-sim.log
#Creating Startup
echo [Desktop Entry] | sudo tee /etc/xdg/autostart/startup.desktop
echo Type=Application | sudo tee -a /etc/xdg/autostart/startup.desktop
echo Name=StartUp | sudo tee -a /etc/xdg/autostart/startup.desktop
echo Comment=Simulation Script Startup | sudo tee -a /etc/xdg/autostart/startup.desktop
#rasberrypi uses lxterminal
#echo Exec=lxterminal -e bash /usr/local/scripts/startup.sh | sudo tee -a /etc/xdg/autostart/startup.desktop
#Ubuntu/Debian with gnome
#echo Exec=gnome-terminal --geometry=104x15+1400+477 -- bash -c /usr/local/scripts/startup.sh | sudo tee -a /etc/xdg/autostart/startup.desktop
echo Exec=gnome-terminal --geometry=103x15+1400+525 -- bash -c "/usr/local/scripts/startup.sh ; systemctl reboot" | sudo tee -a /etc/xdg/autostart/startup.desktop
#End Create Startup
#------------------------------------------------------------
#Create Log Viewer 
echo [Desktop Entry] | sudo tee /etc/xdg/autostart/logview.desktop
echo Type=Application | sudo tee -a /etc/xdg/autostart/logview.desktop
echo Name=StartUp | sudo tee -a /etc/xdg/autostart/logview.desktop
echo Comment=Simulation Script Startup | sudo tee -a /etc/xdg/autostart/logview.desktop
#rasberrypi uses lxterminal
#echo Exec=lxterminal -t SIM-LOG-VIEWER --geometry=80x20 -e tail -f /usr/local/scripts/sim.log | sudo tee -a /etc/xdg/autostart/logview.desktop
#Ubuntu/Debian with gnome
#echo Exec=gnome-terminal --geometry=20x15+0+477 -- tail -f /usr/local/scripts/sim.log | sudo tee -a /etc/xdg/autostart/logview.desktop
echo Exec=gnome-terminal --geometry=35x15+0+525 -- tail -f /usr/local/scripts/sim.log | sudo tee -a /etc/xdg/autostart/logview.desktop
#End Log Viewer
#------------------------------------------------------------
#Create journalctl Viewer 
echo [Desktop Entry] | sudo tee /etc/xdg/autostart/journalctl.desktop
echo Type=Application | sudo tee -a /etc/xdg/autostart/journalctl.desktop
echo Name=StartUp | sudo tee -a /etc/xdg/autostart/journalctl.desktop
echo Comment=Simulation Script Startup | sudo tee -a /etc/xdg/autostart/journalctl.desktop
#rasberrypi uses lxterminal
#echo Exec=lxterminal -t SIM-LOG-VIEWER --geometry=80x20 -e tail -f /usr/local/scripts/sim.log | sudo tee -a /etc/xdg/autostart/journalctl.desktop
#Ubuntu/Debian with gnome
echo Exec=gnome-terminal --geometry=140x20+0+0 -- journalctl -f | sudo tee -a /etc/xdg/autostart/journalctl.desktop
#End Log Viewer#------------------------------------------------------------
#Create journalctl Viewer 
echo [Desktop Entry] | sudo tee /etc/xdg/autostart/sim_update.desktop
echo Type=Application | sudo tee -a /etc/xdg/autostart/sim_update.desktop
echo Name=StartUp | sudo tee -a /etc/xdg/autostart/sim_update.desktop
echo Comment=Simulation Update | sudo tee -a /etc/xdg/autostart/sim_update.desktop
#rasberrypi uses lxterminal
#echo Exec=lxterminal -t SIM-LOG-VIEWER --geometry=80x20 -e tail -f /usr/local/scripts/sim.log | sudo tee -a /etc/xdg/autostart/journalctl.desktop
#Ubuntu/Debian with gnome
echo Exec=gnome-terminal -- bash -c /usr/local/scripts/sim_update.sh | sudo tee -a /etc/xdg/autostart/sim_update.desktop
#End Log Viewer#------------------------------------------------------------
