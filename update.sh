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
 git clone https://github.com/solutions-hpe/client-sim
 cd client-sim
 git switch lrb
 git pull origin --ff-only
 sudo cp *.desktop /etc/xdg/autostart/
 sudo cp *.sh /usr/local/scripts/
 sudo cp *.txt /usr/local/scripts/
 cd configs
 sudo cp simulation.conf /usr/local/scripts/simulation.conf
 sudo chmod -R 777 /usr/local/scripts
else
 #Local repo defined in the conf file
 smbclient $smb_location -N -c 'lcd /usr/local/scripts/; cd Scripts; prompt; mget *'
fi
#------------------------------------------------------------
#End Updating Scripts
#------------------------------------------------------------
