#!/bin/bash
version=.20
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
repo_branch=$(get_value 'simulation' 'repo_branch')
#------------------------------------------------------------
echo Updating Scripts | tee -a /usr/local/scripts/sim.log
if [ $public_repo == "on" ]; then
 #Using remote GitHub repo
 cd ~
 #just in case the repo has not been cloned yet - attempting to clone the repo
 #this will throw an error most of the time
 git clone $repo_location
 cd client-sim
 #switching the branch to the one designated in the simulation.conf file
 git switch $repo_branch
 #updating the local repo with fast forward option
 git pull origin --ff-only
 #copying startup files to autostart
 sudo cp *.desktop /etc/xdg/autostart/ &
 #copying shell scripts to the active script repo
 sudo cp *.sh /usr/local/scripts/ &
 #copying flat files for simulation to active script repo
 sudo cp *.txt /usr/local/scripts/
 cd configs
 #copying latest config file to active repository
 sudo cp simulation.conf /usr/local/scripts/simulation.conf &
 #making all simulation scripts executable
 sudo chmod -R 777 /usr/local/scripts &
else
 #Local repo defined in the conf file
 smbclient $smb_location -N -c 'lcd /usr/local/scripts/; cd Scripts; prompt; mget *'
fi
#------------------------------------------------------------
#End Updating Scripts
#------------------------------------------------------------
