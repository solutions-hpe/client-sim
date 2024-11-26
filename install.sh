#!/bin/bash
version=.02
echo Installer Version $version
echo enabling no password for sudo for current user
echo "$USER   ALL=(ALL:ALL) NOPASSWD:ALL" | sudo tee -a /etc/sudoers
echo making scripts directory
sudo mkdir /usr/local/scripts
#------------------------------------------------------------
echo Downloading scripts from source on GitHub
sudo wget https://raw.githubusercontent.com/solutions-hpe/client-sim/main/simulation.sh -O /usr/local/scripts/simulation.sh
sudo wget https://raw.githubusercontent.com/solutions-hpe/client-sim/main/startup.sh -O /usr/local/scripts/startup.sh
sudo wget https://raw.githubusercontent.com/solutions-hpe/client-sim/main/ini-parser.sh -O /usr/local/scripts/ini-parser.sh
sudo wget https://raw.githubusercontent.com/solutions-hpe/client-sim/main/websites.txt -O /usr/local/scripts/websits.txt
sudo wget https://raw.githubusercontent.com/solutions-hpe/client-sim/main/dns_fail.txt -O /usr/local/scripts/dns_fail.txt
sudo wget https://raw.githubusercontent.com/solutions-hpe/client-sim/main/simulation.conf -O /usr/local/scripts/simulation.conf
#------------------------------------------------------------
#------------------------------------------------------------
#Installing SMBClient to sync with local CIFS repo
sudo apt update
sudo apt install smbclient -y
#Creating Startup
echo Creating auto Start files
echo [Desktop Entry] | sudo tee /etc/xdg/scripts/startup.desktop
echo Type=Application | sudo tee -a /etc/xdg/scripts/startup.desktop
echo Name=StartUp | sudo tee -a /etc/xdg/scripts/startup.desktop
echo Comment=Simulation Script Startup | sudo tee -a /etc/xdg/scripts/startup.desktop
echo Exec=bash /usr/local/scripts/startup.sh | sudo tee -a /etc/xdg/scripts/startup.deckop
#End Create Startup
#Create Log Viewer 
echo [Desktop Entry] | sudo tee /etc/xdg/scripts/logview.desktop
echo Type=Application | sudo tee -a /etc/xdg/scripts/logview.desktop
echo Name=StartUpm| sudo tee -a /etc/xdg/scripts/logview.desktop
echo Comment=Simulation Script Startup | sudo tee -a /etc/xdg/scripts/logview.desktop
echo Exec=lxterminal -t SIM-LOG-VIEWER --geometry=80x20 -e tail -f /usr/local/scripts/sim.log | sudo tee -a /etc/xdg/scripts/logview.desktop
#End Log Viewer
