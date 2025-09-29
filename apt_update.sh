#!/bin/bash
version=.01
echo apt update Script Version $version | tee -a /usr/local/scripts/sim.log
echo $(date) | tee -a /usr/local/scripts/sim.log
#------------------------------------------------------------
sudo apt update
sudo dpkg --configure -a
sudo apt remove sysstat -y
sudo apt upgrade -y -o Dpkg::Options::="--force-confdef"
sudo apt full-upgrade -y
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
