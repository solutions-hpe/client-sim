#!/bin/bash
version=.33
touch /tmp/client-sim.log
echo Installer Version $version | tee /tmp/client-sim.log
gnome-terminal --geometry=80x15+0+477 -- tail -f /tmp/client-sim.log
lxterminal -t Installer --geometry=80x15 -e tail -f /tmp/client-sim.log
#------------------------------------------------------------
#Checking OS
os=$(uname -n)
#------------------------------------------------------------
echo Adding user $USER to sudoers for script simlulations | tee -a /tmp/client-sim.log
if sudo grep -q "$USER   ALL=(ALL:ALL) NOPASSWD:ALL" "/etc/sudoers"; then
  echo User is already setup in sudoers | tee -a /tmp/client-sim.log
else
  echo Enabling no password for sudo for current user | tee -a /tmp/client-sim.log
  echo "$USER   ALL=(ALL:ALL) NOPASSWD:ALL" | sudo tee -a /etc/sudoers
fi
echo Making scripts directory | tee -a /usr/local/scripts/sim.log
sudo mkdir /usr/local/scripts
#Without this - the logging screens at boot will not be pinned to the right x,y coordinates
echo Disabling Wayland so gnome-terminal windows can be pinned | tee -a /tmp/client-sim.log
sudo sed -i '/WaylandEnable=false/s/^#//g' /etc/gdm3/custom.conf
#By default screen will blank and need to log back in after 5 minutes - disabling this as the client is running scripts
echo Disabling screen blanking | tee -a /tmp/client-sim.log
gsettings set org.gnome.desktop.session idle-delay 0
xset s noblank
xset -dpms
xset s off
#Setting Resolution
xrandr --output Virtual-1 --mode 1440x900
#On raspberrypi changing WLAN local to US
#Only applies to raspberrypi
sudo raspi-config nonint do_change_locale en_US.UTF-8
sudo raspi-config nonint do_wifi_country US
#Installing SMBClient to sync with local CIFS repo
#Installing DKMS, DNSUtils, QEMU Agent, GIT, Net Tools
#------------------------------------------------------------
echo Running system updates | tee -a /tmp/client-sim.log
sudo apt update
sudo apt upgrade -y
sudo apt install git -y
sudo apt install wget -y
sudo apt install gnome-terminal -y
sudo apt install network-manager -y
sudo apt install qemu-guest-agent -y
sudo apt install net-tools -y
sudo apt install smbclient -y
sudo apt install dnsutils -y
sudo apt install dkms -y
sudo apt install iperf3 -y
sudo apt install firefox-esr -y
sudo apt autoremove -y
#------------------------------------------------------------
#VirtualHere is coded into the client simulation
#VirtualHere is used to connect to a remote USB dongle (Wired or Wireless)
#No license is required for the client - only the server needs to be licensed
#Installing so the client is ready to connect to a server if configured
echo Downloading VirtualHere client | tee -a /tmp/client-sim.log
wget https://www.virtualhere.com/sites/default/files/usbclient/scripts/virtualhereclient.service
sleep 1
wget https://www.virtualhere.com/sites/default/files/usbclient/vhclientx86_64
sleep 1
chmod +x ./vhclientx86_64
echo Installing VirtualHere client | tee -a /tmp/client-sim.log
sudo mv ./vhclientx86_64 /usr/sbin
sudo mv virtualhereclient.service /etc/systemd/system/virtualhereclient.service
sudo systemctl daemon-reload
sudo systemctl enable virtualhereclient.service
sudo systemctl start virtualhereclient.service
rm /usr/local/scripts/vhcached.txt
smbclient //nas/scripts -N -c 'lcd /usr/local/scripts/; cd /SIM/CONFIG/; prompt off; mget *.conf'
/usr/sbin/vhclientx86_64 -t "AUTO USE CLEAR ALL"
/usr/sbin/vhclientx86_64 -t "STOP USING ALL LOCAL"
#------------------------------------------------------------
echo Downloading scripts from source on GitHub | tee -a /tmp/client-sim.log
sudo wget --waitretry=10 --read-timeout=20 --timeout=15 https://raw.githubusercontent.com/solutions-hpe/client-sim/main/simulation.sh -O /usr/local/scripts/simulation.sh
sleep 1
sudo wget --waitretry=10 --read-timeout=20 --timeout=15 https://raw.githubusercontent.com/solutions-hpe/client-sim/main/startup.sh -O /usr/local/scripts/startup.sh
sleep 1
sudo wget --waitretry=10 --read-timeout=20 --timeout=15 https://raw.githubusercontent.com/solutions-hpe/client-sim/main/ini-parser.sh -O /usr/local/scripts/ini-parser.sh
sleep 1
sudo wget --waitretry=10 --read-timeout=20 --timeout=15 https://raw.githubusercontent.com/solutions-hpe/client-sim/main/sim-update.sh -O /usr/local/scripts/sim-update.sh
sleep 1
sudo wget --waitretry=10 --read-timeout=20 --timeout=15 https://raw.githubusercontent.com/solutions-hpe/client-sim/main/update.sh -O /usr/local/scripts/update.sh
sleep 1
sudo wget --waitretry=10 --read-timeout=20 --timeout=15 https://raw.githubusercontent.com/solutions-hpe/client-sim/main/vhconnect.sh -O /usr/local/scripts/vhconnect.sh
sleep 1
sudo wget --waitretry=10 --read-timeout=20 --timeout=15 https://raw.githubusercontent.com/solutions-hpe/client-sim/main/websites.txt -O /usr/local/scripts/websites.txt
sleep 1
sudo wget --waitretry=10 --read-timeout=20 --timeout=15 https://raw.githubusercontent.com/solutions-hpe/client-sim/main/dns_fail.txt -O /usr/local/scripts/dns_fail.txt
sleep 1
sudo wget --waitretry=10 --read-timeout=20 --timeout=15 https://raw.githubusercontent.com/solutions-hpe/client-sim/main/public_kill_switch.txt -O /usr/local/scripts/public_kill_switch.txt
sleep 1
if [ -e "/usr/local/scripts/simulation.conf" ]; then
  echo Local simulation config exists | tee -a /tmp/client-sim.log
else
  echo Downloading simulation config | tee -a /tmp/client-sim.log
  sudo wget https://raw.githubusercontent.com/solutions-hpe/client-sim/main/simulation.conf -O /usr/local/scripts/simulation.conf
fi
touch /usr/local/scripts/sim.log
echo Installer Version $version | tee /usr/local/scripts/sim.log
sudo chmod -R 777 /usr/local/scripts
#------------------------------------------------------------
echo Getting Network Adapter Drivers from GitHub | tee -a /tmp/client-sim.log
#git clone https://github.com/morrownr/8821au-20210708.git
#git clone https://github.com/morrownr/8821cu-20210916.git
#git clone https://github.com/morrownr/8814au.git
#git clone https://github.com/morrownr/8812au-20210820.git
rm -Rf rtl8812au
git clone https://github.com/aircrack-ng/rtl8812au.git
#git clone https://github.com/morrownr/88x2bu-20210702.git
rm -Rf rtl8852au
git clone https://github.com/lwfinger/rtl8852au.git
#git clone https://github.com/lwfinger/rtl8188eu.git
#git clone https://github.com/lwfinger/rtw89.git
#git clone https://github.com/lwfinger/rtl8723au.git
#------------------------------------------------------------
echo Installing Network Adapter Drivers | tee -a /tmp/client-sim.log
#echo Installing Wireless Adapter 8821au | tee -a /tmp/client-sim.log
#cd 8821au-20210708
#sudo ./install-driver.sh NoPrompt
#cd ..
#echo Installing Wireless Adapter 8821cu | tee -a /tmp/client-sim.log
#cd 8821cu-20210916
#sudo ./install-driver.sh NoPrompt
#cd ..
#echo Installing Wireless Adapter 8814au | tee -a /tmp/client-sim.log
#cd 8814au
#sudo ./install-driver.sh NoPrompt
#cd ..
#echo Installing Wireless Adapter 8812au | tee -a /tmp/client-sim.log
#cd 8812au-20210820
#sudo ./install-driver.sh NoPrompt
#cd ..
echo Installing Wireless Adapter 8812au TP-Link T3 Archer | tee -a /tmp/client-sim.log
cd rtl8812au
sudo make
sudo make install
cd ..
#echo Installing Wireless Adapter 88x2bu | tee -a /tmp/client-sim.log
#cd 88x2bu-20210702
#sudo ./install-driver.sh NoPrompt
#cd ..
#echo Installing Wireless Adapter 8188eu | tee -a /tmp/client-sim.log
#cd rtl8188eu
#make all
#sudo make install
#cd ..
echo Installing Wireless Adapter 8852au | tee -a /tmp/client-sim.log
cd rtl8852au
sudo make
sudo make install
cd ..
#echo Installing Wireless Adpater rtw89 | tee -a /tmp/client-sim.log
#cd rtw89
#make
#sudo make install
#cd ..
#echo Installing Wireless Adapter 8723au | tee -a /tmp/client-sim.log
#cd rtl8723au
#make
#sudo make install
#sudo modprobe 8723au
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
echo Exec=gnome-terminal --geometry=103x15+1400+525 -- bash -c /usr/local/scripts/startup.sh | sudo tee -a /etc/xdg/autostart/startup.desktop
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
echo Exec=gnome-terminal --geometry=34x15+0+525 -- tail -f /usr/local/scripts/sim.log | sudo tee -a /etc/xdg/autostart/logview.desktop
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
echo install is complete shutdown now | tee -a /tmp/client-sim.log
