echo "$USER   ALL=(ALL:ALL) NOPASSWD:ALL" | sudo tee -a /etc/sudoers
mkdir /usr/local/scripts
#------------------------------------------------------------
sudo wget https://raw.githubusercontent.com/solutions-hpe/client-sim/main/simulation.sh -O /usr/local/scripts/simulation.sh
sudo wget https://raw.githubusercontent.com/solutions-hpe/client-sim/main/startup.sh -O /usr/local/scripts/startup.sh
sudo wget https://raw.githubusercontent.com/solutions-hpe/client-sim/main/ini-parser.sh -O /usr/local/scripts/ini-parser.sh
sudo wget https://raw.githubusercontent.com/solutions-hpe/client-sim/main/websites.txt -O /usr/local/scripts/websits.txt
sudo wget https://raw.githubusercontent.com/solutions-hpe/client-sim/main/dns_fail.txt -O /usr/local/scripts/dns_fail.txt
sudo wget https://raw.githubusercontent.com/solutions-hpe/client-sim/main/simulation.conf -O /usr/local/scripts/simulation.conf
#------------------------------------------------------------
#Creating Startup
echo [Desktop Entry] | sudo tee /etc/xdg/scripts/startup.desktop
echo Type=Application | sudo tee -a /etc/xdg/scripts/startup.desktop
echo Name=StartUp | sudo tee -a /etc/xdg/scripts/startup.desktop
echo Comment=Simulation Script Startup | sudo tee -a /etc/xdg/scripts/startup.desktop
echo Exec=bash /usr/local/scripts/startup.sh | sudo tee -a /etc/xdg/scripts/startup.desktop
#End Create Startup
