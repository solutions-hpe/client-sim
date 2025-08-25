#!/bin/bash
version=.42
touch /tmp/client-sim.log
echo Installer Version $version | tee /tmp/client-sim.log
sudo apt install gnome-terminal -y
gnome-terminal --geometry=80x15+0+477 -- tail -f /tmp/client-sim.log
#lxterminal -t Installer --geometry=80x15 -e tail -f /tmp/client-sim.log
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
sudo DEBIAN_FRONTEND=noninteractive apt update
sudo DEBIAN_FRONTEND=noninteractive apt upgrade -y
sudo DEBIAN_FRONTEND=noninteractive apt remote sysstat -y
sudo DEBIAN_FRONTEND=noninteractive apt install git -y
sudo DEBIAN_FRONTEND=noninteractive apt install wget -y
sudo DEBIAN_FRONTEND=noninteractive apt install network-manager -y
sudo DEBIAN_FRONTEND=noninteractive apt install qemu-guest-agent -y
sudo DEBIAN_FRONTEND=noninteractive apt install net-tools -y
sudo DEBIAN_FRONTEND=noninteractive apt install smbclient -y
sudo DEBIAN_FRONTEND=noninteractive apt install dnsutils -y
sudo DEBIAN_FRONTEND=noninteractive apt install dkms -y
sudo DEBIAN_FRONTEND=noninteractive apt install iperf3 -y
sudo DEBIAN_FRONTEND=noninteractive apt install firefox-esr -y
sudo DEBIAN_FRONTEND=noninteractive apt autoremove -y
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
cd ~
git clone https://github.com/solutions-hpe/client-sim.git
cd client-sim
#switching the branch to the one designated in the simulation.conf file
#copying startup files to autostart
sudo cp *.desktop /etc/xdg/autostart/
#copying shell scripts to the active script repo
sudo mkdir /usr/local/scripts
sudo cp *.sh /usr/local/scripts/
#copying flat files for simulation to active script repo
sudo cp *.txt /usr/local/scripts/
#making all simulation scripts executable
sudo chmod -R 777 /usr/local/scripts
if [ -e "/usr/local/scripts/simulation.conf" ]; then
 echo Local simulation config exists | tee -a /tmp/client-sim.log
else
 #copying latest config file to active repository
 echo Coying config from local repo | tee -a /tmp/client-sim.log
 cd configs
 sudo cp simulation.conf /usr/local/scripts/simulation.conf
fi
touch /usr/local/scripts/sim.log
echo Installer Version $version | tee /usr/local/scripts/sim.log
sudo chmod -R 777 /usr/local/scripts
#------------------------------------------------------------
echo Getting Network Adapter Drivers from GitHub | tee -a /tmp/client-sim.log
rm -Rf 8821au-20210708
git clone https://github.com/morrownr/8821au-20210708.git
rm -Rf 8821cu-20210916
git clone https://github.com/morrownr/8821cu-20210916.git
rm -Rf rtw89
git clone https://github.com/morrownr/rtw89
rm -Rf 8814au
git clone https://github.com/morrownr/8814au.git
rm -Rf rtl8852cu-20240510
git clone https://github.com/morrownr/rtl8852cu-20240510.git
rm -Rf 8812au-20210820
git clone https://github.com/morrownr/8812au-20210820.git
rm -Rf rtl8852bu-20240418
git clone https://github.com/morrownr/rtl8852bu-20240418.git
rm -Rf rtl8812au
git clone https://github.com/aircrack-ng/rtl8812au.git
rm -Rf 88x2bu-20210702
git clone https://github.com/morrownr/88x2bu-20210702.git
rm -Rf rtl8852au
git clone https://github.com/lwfinger/rtl8852au.git
rm -Rf rtl8188eu
git clone https://github.com/lwfinger/rtl8188eu.git
rm -Rf rtl8723au
git clone https://github.com/lwfinger/rtl8723au.git
#------------------------------------------------------------
echo Installing Network Adapter Drivers | tee -a /tmp/client-sim.log
echo Installing Wireless Adapter 8821au | tee -a /tmp/client-sim.log
cd 8821au-20210708
sudo ./install-driver.sh NoPrompt
cd ..
echo Installing Wireless Adapter 8821cu | tee -a /tmp/client-sim.log
cd 8821cu-20210916
sudo ./install-driver.sh NoPrompt
cd ..
echo Installing Wireless Adapter 8814au | tee -a /tmp/client-sim.log
cd 8814au
sudo ./install-driver.sh NoPrompt
cd ..
echo Installing Wireless Adapter 8812au | tee -a /tmp/client-sim.log
cd 8812au-20210820
sudo ./install-driver.sh NoPrompt
cd ..
echo Installing Wireless Adapter 8852bu | tee -a /tmp/client-sim.log
cd rtl8852bu-20240418
sudo ./install-driver.sh NoPrompt
cd ..
echo Installing Wireless Adapter 8852cu | tee -a /tmp/client-sim.log
cd rtl8852cu-20240510
sudo ./install-driver.sh NoPrompt
cd ..
echo Installing Wireless Adapter 88x2bu | tee -a /tmp/client-sim.log
cd 88x2bu-20210702
sudo ./install-driver.sh NoPrompt
cd ..
echo Installing Wireless Adapter 8188eu | tee -a /tmp/client-sim.log
cd rtl8188eu
sudo make all
sudo make install
sudo dkms add .
cd ..
echo Installing Wireless Adapter 8852au | tee -a /tmp/client-sim.log
cd rtl8852au
sudo make all
sudo make install
sudo dkms add .
cd ..
echo Installing Wireless Adpater rtw89 | tee -a /tmp/client-sim.log
cd rtw89
sudo make all
sudo make install
sudo kdms add .
cd ..
echo Installing Wireless Adapter 8723au | tee -a /tmp/client-sim.log
cd rtl8723au
sudo make all
sudo make install
sudo modprobe 8723au
sudo dkms add .
#------------------------------------------------------------
echo install is complete | tee -a /tmp/client-sim.log
