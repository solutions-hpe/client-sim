#!/bin/bash
uversion=.04
echo --------------------------| tee /usr/local/scripts/sim.log
echo VHConnect Script Version $uversion | tee -a /usr/local/scripts/sim.log
echo $(date) | tee -a /usr/local/scripts/sim.log
#------------------------------------------------------------
#Updating Scripts
#------------------------------------------------------------
echo Updating Scripts | tee -a /usr/local/scripts/sim.log
echo Checking connectivity to GitHub | tee -a /usr/local/scripts/sim.log
github=raw.githubusercontent.com
if [ $public_repo == "on" ]; then
 #Using remote GitHub repo
 ping -c1 $github
  if [ $? -eq 0 ]; then
   echo Successful network connection to Github - updating scripts
   sudo wget --waitretry=1 --read-timeout=20 --timeout=15 https://raw.githubusercontent.com/solutions-hpe/client-sim/main/dns_fail.txt -O /usr/local/scripts/dns_fail.txt
   sudo wget --waitretry=1 --read-timeout=20 --timeout=15 https://raw.githubusercontent.com/solutions-hpe/client-sim/main/kill_switch.txt -O /usr/local/scripts/kill_switch.txt
   sudo wget --waitretry=1 --read-timeout=20 --timeout=15 https://raw.githubusercontent.com/solutions-hpe/client-sim/main/websites.txt -O /usr/local/scripts/websites.txt
   sudo wget --waitretry=1 --read-timeout=20 --timeout=15 https://raw.githubusercontent.com/solutions-hpe/client-sim/main/simulation.sh -O /usr/local/scripts/simulation.sh
   sudo wget --waitretry=1 --read-timeout=20 --timeout=15 https://raw.githubusercontent.com/solutions-hpe/client-sim/main/startup.sh -O /usr/local/scripts/startup.sh
   sudo wget --waitretry=1 --read-timeout=20 --timeout=15 https://raw.githubusercontent.com/solutions-hpe/client-sim/main/ini-parser.sh -O /usr/local/scripts/ini-parser.sh
   sudo wget --waitretry=1 --read-timeout=20 --timeout=15 https://raw.githubusercontent.com/solutions-hpe/client-sim/main/sim-update.sh -O /usr/local/scripts/sim-update.sh
   sudo wget --waitretry=1 --read-timeout=20 --timeout=15 https://raw.githubusercontent.com/solutions-hpe/client-sim/main/update.sh -O /usr/local/scripts/update.sh
   sudo wget --waitretry=1 --read-timeout=20 --timeout=15 https://raw.githubusercontent.com/solutions-hpe/client-sim/main/vhconnect.sh -O /usr/local/scripts/vhconnect.sh
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
echo Exec=gnome-terminal --geometry=115x16+1400+525 -- bash -c /usr/local/scripts/startup.sh | sudo tee -a /etc/xdg/autostart/startup.desktop
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
echo Exec=gnome-terminal --geometry=34x16+0+525 -- tail -f /usr/local/scripts/sim.log | sudo tee -a /etc/xdg/autostart/logview.desktop
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
