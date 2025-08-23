#!/bin/bash
version=.18
echo Update Script Version $version | tee -a /usr/local/scripts/sim.log
echo $(date) | tee -a /usr/local/scripts/sim.log
#------------------------------------------------------------
#Updating Scripts
#------------------------------------------------------------
echo Reading Simulation Config File | tee -a /usr/local/scripts/sim.log
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
public_repo=$(get_value 'simulation' 'public_repo')
repo_location=$(get_value 'simulation' 'repo_location')
#------------------------------------------------------------
echo Updating Scripts | tee -a /usr/local/scripts/sim.log
if [ $public_repo == "on" ]; then
 #Using remote GitHub repo
 cd ~
 cd client-sim
 git pull origin --ff-only
 cp *.sh /usr/local/scripts/
 cp *.txt /usr/local/scripts/
 cd configs
 cp simulation.conf /usr/local/scripts/simulation.conf
 sudo chmod -R 777 /usr/local/scripts
else
 #Local repo defined in the conf file
 smbclient $smb_location -N -c 'lcd /usr/local/scripts/; cd Scripts; prompt; mget *'
fi
#------------------------------------------------------------
#End Updating Scripts
#------------------------------------------------------------
echo Creating auto Start files | tee -a /tmp/client-sim.log
#Creating Startup
echo [Desktop Entry] | sudo tee /tmp/startup.desktop
echo Type=Application | sudo tee -a /tmp/startup.desktop
echo Name=StartUp | sudo tee -a /tmp/startup.desktop
echo Comment=Simulation Script Startup | sudo tee -a /tmp/startup.desktop
#rasberrypi uses lxterminal
#echo Exec=lxterminal -e bash /usr/local/scripts/startup.sh | sudo tee -a /etc/xdg/autostart/startup.desktop
#Ubuntu/Debian with gnome
#echo Exec=gnome-terminal --geometry=104x15+1400+477 -- bash -c /usr/local/scripts/startup.sh | sudo tee -a /etc/xdg/autostart/startup.desktop
echo Exec=gnome-terminal --geometry=103x15+1400+525 -- bash -c "/usr/local/scripts/startup.sh ; systemctl reboot" | sudo tee -a /tmp/startup.desktop
#End Create Startup
#------------------------------------------------------------
#Create Log Viewer 
echo [Desktop Entry] | sudo tee /tmp/logview.desktop
echo Type=Application | sudo tee -a /tmp/logview.desktop
echo Name=StartUp | sudo tee -a /tmp/logview.desktop
echo Comment=Simulation Script Startup | sudo tee -a /tmp/logview.desktop
#rasberrypi uses lxterminal
#echo Exec=lxterminal -t SIM-LOG-VIEWER --geometry=80x20 -e tail -f /usr/local/scripts/sim.log | sudo tee -a /etc/xdg/autostart/logview.desktop
#Ubuntu/Debian with gnome
#echo Exec=gnome-terminal --geometry=20x15+0+477 -- tail -f /usr/local/scripts/sim.log | sudo tee -a /etc/xdg/autostart/logview.desktop
echo Exec=gnome-terminal --geometry=35x15+0+525 -- tail -f /usr/local/scripts/sim.log | sudo tee -a /tmp/logview.desktop
#End Log Viewer
#------------------------------------------------------------
#Create journalctl Viewer 
echo [Desktop Entry] | sudo tee /tmp/journalctl.desktop
echo Type=Application | sudo tee -a /tmp/journalctl.desktop
echo Name=StartUp | sudo tee -a /tmp/journalctl.desktop
echo Comment=Simulation Script Startup | sudo tee -a /tmp/journalctl.desktop
#rasberrypi uses lxterminal
#echo Exec=lxterminal -t SIM-LOG-VIEWER --geometry=80x20 -e tail -f /usr/local/scripts/sim.log | sudo tee -a /etc/xdg/autostart/journalctl.desktop
#Ubuntu/Debian with gnome
echo Exec=gnome-terminal --geometry=140x20+0+0 -- journalctl -f | sudo tee -a /tmp/journalctl.desktop
#End Log Viewer#------------------------------------------------------------
#Create journalctl Viewer 
echo [Desktop Entry] | sudo tee /tmp/sim_update.desktop
echo Type=Application | sudo tee -a /tmp/sim_update.desktop
echo Name=StartUp | sudo tee -a /tmp/sim_update.desktop
echo Comment=Simulation Update | sudo tee -a /tmp/sim_update.desktop
#rasberrypi uses lxterminal
#echo Exec=lxterminal -t SIM-LOG-VIEWER --geometry=80x20 -e tail -f /usr/local/scripts/sim.log | sudo tee -a /etc/xdg/autostart/journalctl.desktop
#Ubuntu/Debian with gnome
echo Exec=gnome-terminal -- bash -c /usr/local/scripts/sim_update.sh | sudo tee -a /tmp/sim_update.desktop
#End Log Viewer#------------------------------------------------------------
cd /tmp
sudo cp *.desktop /etc/xdg/autostart/
