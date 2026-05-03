#!/bin/bash
version=.24
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
 git config --global http.lowSpeedLimit 1000
 git config --global http.lowSpeedTime 300
 git config --global http.maxRequests 2
 git config pull.rebase true
 #switching the branch to the one designated in the simulation.conf file
 git switch $repo_branch
 #updating the local repo with fast forward option
 git pull --ff-only
 cd linux
 #Copying config file template for syslog messages of simulation
 echo "Copying rsyslog config..."
 if [[ -f "10-rsyslog.conf" ]]; then
  sudo cp -v 10-rsyslog.conf /etc/rsyslog.d/10-rsyslog.conf
 else
  echo "No rsyslog config file found"
 fi
 #copying startup files to autostart
 echo "Copying desktop startup files..."
 desktop_files=( *.desktop )
 if (( ${#desktop_files[@]} )); then
  sudo cp -v "${desktop_files[@]}" /etc/xdg/autostart/
 else
  echo "No .desktop files found to copy"
 fi
 #copying shell scripts to the active script repo
 echo "Copying shell scripts..."
 sh_files=( *.sh )
 if (( ${#sh_files[@]} )); then
  sudo cp -v "${sh_files[@]}" /usr/local/scripts/
 else
  echo "No .sh files found to copy"
 fi
 #copying flat files for simulation to active script repo
 echo "Copying text files..."
 txt_files=( *.txt )
 if (( ${#txt_files[@]} )); then
  sudo cp -v "${txt_files[@]}" /usr/local/scripts/
 else
  echo "No .txt files found to copy"
 fi
 cd ..
 cd configs
 #copying latest config file to active repository
 sudo cp simulation.conf /usr/local/scripts/simulation.conf
 #making all simulation scripts executable
 sudo chmod -R 777 /usr/local/scripts
else
 #Local repo defined in the conf file
 smbclient $smb_location -N -c 'lcd /usr/local/scripts/; cd Scripts; prompt; mget *'
fi
#------------------------------------------------------------
#End Updating Scripts
#------------------------------------------------------------