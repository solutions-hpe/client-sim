#!/bin/bash
version=.09
#------------------------------------------------------------
echo Installer Version $version
if sudo grep -q "$USER   ALL=(ALL:ALL) NOPASSWD:ALL" "/etc/sudoers"; then
  echo User is already setup in sudoers
else
  echo enabling no password for sudo for current user
  echo "$USER   ALL=(ALL:ALL) NOPASSWD:ALL" | sudo tee -a /etc/sudoers
fi
echo making scripts directory
sudo mkdir /usr/local/scripts
sudo chmod -R 777 /usr/local/scripts
#On raspberrypi changing WLAN local to US
#Only applies to raspberrypi
sudo raspi-config nonint do_change_locale en_US.UTF-8
sudo raspi-config nonint do_wifi_country US
#Installing SMBClient to sync with local CIFS repo
#Installing DKMS, DNSUtils, QEMU Agent, GIT, Net Tools
#------------------------------------------------------------
sudo apt update
sudo apt upgrade -y
sudo apt install git -y
sudo apt install qemu-guest-agent -y
sudo apt install net-tools -y
sudo apt install smbclient -y
sudo apt install dnsutils -y
sudo apt install dkms -y
#------------------------------------------------------------
echo Downloading scripts from source on GitHub
sudo wget https://raw.githubusercontent.com/solutions-hpe/client-sim/main/simulation.sh -O /usr/local/scripts/simulation.sh
sudo wget https://raw.githubusercontent.com/solutions-hpe/client-sim/main/startup.sh -O /usr/local/scripts/startup.sh
sudo wget https://raw.githubusercontent.com/solutions-hpe/client-sim/main/ini-parser.sh -O /usr/local/scripts/ini-parser.sh
sudo wget https://raw.githubusercontent.com/solutions-hpe/client-sim/main/websites.txt -O /usr/local/scripts/websits.txt
sudo wget https://raw.githubusercontent.com/solutions-hpe/client-sim/main/dns_fail.txt -O /usr/local/scripts/dns_fail.txt
sudo wget https://raw.githubusercontent.com/solutions-hpe/client-sim/main/simulation.conf -O /usr/local/scripts/simulation.conf
#------------------------------------------------------------
echo Getting Network Adapter Drivers from GitHub
git clone https://github.com/morrownr/8821au-20210708.git
git clone https://github.com/morrownr/8821cu-20210916.git
git clone https://github.com/morrownr/8814au.git
git clone https://github.com/morrownr/8812au-20210820.git
git clone https://github.com/morrownr/88x2bu-20210702.git
#------------------------------------------------------------
echo Installing Network Adapter Drivers
cd 8821au-20210708
sudo ./install-driver.sh NoPrompt
cd ..
cd 8821cu-20210916
sudo ./install-driver.sh NoPrompt
cd ..
cd 8814au
sudo ./install-driver.sh NoPrompt
cd ..
cd 8812au-20210820
sudo ./install-driver.sh NoPrompt
cd ..
cd 88x2bu-20210702
sudo ./install-driver.sh NoPrompt
cd ..
#------------------------------------------------------------
#Creating Startup
echo Creating auto Start files
echo [Desktop Entry] | sudo tee /etc/xdg/autostart/startup.desktop
echo Type=Application | sudo tee -a /etc/xdg/autostart/startup.desktop
echo Name=StartUp | sudo tee -a /etc/xdg/autostart/startup.desktop
echo Comment=Simulation Script Startup | sudo tee -a /etc/xdg/autostart/startup.desktop
#rasberrypi uses lxterminal
echo Exec=lxterminal -e bash /usr/local/scripts/startup.sh | sudo tee -a /etc/xdg/autostart/startup.desktop
#Ubuntu/Debian with gnome
echo Exec=gnome-terminal --geometry=125x15+0+0 -- bash -c /usr/local/scripts/startup.sh | sudo tee -a /etc/xdg/autostart/startup.desktop
#End Create Startup
#------------------------------------------------------------
#Create Log Viewer 
echo [Desktop Entry] | sudo tee /etc/xdg/autostart/logview.desktop
echo Type=Application | sudo tee -a /etc/xdg/autostart/logview.desktop
echo Name=StartUp | sudo tee -a /etc/xdg/autostart/logview.desktop
echo Comment=Simulation Script Startup | sudo tee -a /etc/xdg/autostart/logview.desktop
#rasberrypi uses lxterminal
echo Exec=lxterminal -t SIM-LOG-VIEWER --geometry=80x20 -e tail -f /usr/local/scripts/sim.log | sudo tee -a /etc/xdg/autostart/logview.desktop
#Ubuntu/Debian with gnome
echo Exec=gnome-terminal --geometry=15x15+0+477 -- tail -f /usr/local/scripts/sim.log | sudo tee -a /etc/xdg/autostart/logview.desktop
#End Log Viewer
#------------------------------------------------------------
#Create journalctl Viewer 
echo [Desktop Entry] | sudo tee /etc/xdg/autostart/journalctl.desktop
echo Type=Application | sudo tee -a /etc/xdg/autostart/journalctl.desktop
echo Name=StartUp | sudo tee -a /etc/xdg/autostart/journalctl.desktop
echo Comment=Simulation Script Startup | sudo tee -a /etc/xdg/autostart/journalctl.desktop
#rasberrypi uses lxterminal
echo Exec=lxterminal -t SIM-LOG-VIEWER --geometry=80x20 -e tail -f /usr/local/scripts/sim.log | sudo tee -a /etc/xdg/autostart/journalctl.desktop
#Ubuntu/Debian with gnome
echo Exec=gnome-terminal --geometry=95x15+1400+477 -- journalctl -f | sudo tee -a /etc/xdg/autostart/journalctl.desktop
#End Log Viewer#------------------------------------------------------------
sudo chmod -R 777 /usr/local/scripts
echo Please reboot - install is complete
