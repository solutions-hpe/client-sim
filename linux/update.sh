#!/bin/bash

version=.26
LOG_FILE="/usr/local/scripts/sim.log"

echo "Update Script Version $version" | tee -a "$LOG_FILE"
echo "$(date)" | tee -a "$LOG_FILE"

echo "Reading Simulation Config File" | tee -a "$LOG_FILE"

source '/usr/local/scripts/ini-parser.sh'
process_ini_file '/usr/local/scripts/simulation.conf'

public_repo=$(get_value 'simulation' 'public_repo')
repo_location=$(get_value 'simulation' 'repo_location')
repo_branch=$(get_value 'simulation' 'repo_branch')

echo "Updating Scripts" | tee -a "$LOG_FILE"

if [[ "$public_repo" == "on" ]]; then
    echo "Using remote GitHub repo" | tee -a "$LOG_FILE"

    cd ~ || echo "WARNING: Failed to cd to home directory" | tee -a "$LOG_FILE"

    repo_dir="client-sim"
    shopt -s nullglob

    if [[ -d "$repo_dir" && ! -d "$repo_dir/.git" ]]; then
        echo "Directory exists but is not a git repo. Removing..." | tee -a "$LOG_FILE"
        rm -rf "$repo_dir"
    fi

    if [[ ! -d "$repo_dir" ]]; then
        echo "Cloning repository..." | tee -a "$LOG_FILE"
        git clone "$repo_location" "$repo_dir" || echo "ERROR: Clone failed" | tee -a "$LOG_FILE"
    else
        echo "Repository already exists, skipping clone" | tee -a "$LOG_FILE"
    fi

    if cd "$repo_dir"; then

        current_remote=$(git remote get-url origin 2>/dev/null || echo "")
        if [[ "$current_remote" != "$repo_location" ]]; then
            echo "Remote URL mismatch. Fixing..." | tee -a "$LOG_FILE"
            git remote set-url origin "$repo_location"
        fi

        if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
            echo "Repo appears corrupted. Re-cloning..." | tee -a "$LOG_FILE"
            cd ~
            rm -rf "$repo_dir"
            git clone "$repo_location" "$repo_dir"
            cd "$repo_dir" || echo "ERROR: Failed to re-enter repo" | tee -a "$LOG_FILE"
        fi

        git config http.lowSpeedLimit 1000
        git config http.lowSpeedTime 300
        git config http.maxRequests 2
        git config pull.rebase true

        git fetch origin

        if git show-ref --verify --quiet "refs/heads/$repo_branch"; then
            echo "Switching to branch: $repo_branch" | tee -a "$LOG_FILE"
            git switch "$repo_branch"
        elif git ls-remote --exit-code --heads origin "$repo_branch" >/dev/null 2>&1; then
            echo "Creating branch: $repo_branch" | tee -a "$LOG_FILE"
            git switch -c "$repo_branch" "origin/$repo_branch"
        else
            echo "ERROR: Branch '$repo_branch' not found" | tee -a "$LOG_FILE"
        fi

        echo "Updating repository..." | tee -a "$LOG_FILE"
        git reset --hard "origin/$repo_branch"
        git pull --ff-only

        # -------- linux section guarded --------
        if cd linux; then

            echo "Copying rsyslog config..." | tee -a "$LOG_FILE"
            if [[ -f "10-rsyslog.conf" ]]; then
                sudo cp -v 10-rsyslog.conf /etc/rsyslog.d/10-rsyslog.conf
            else
                echo "No rsyslog config file found" | tee -a "$LOG_FILE"
            fi

            echo "Copying desktop startup files..." | tee -a "$LOG_FILE"
            desktop_files=( *.desktop )
            if (( ${#desktop_files[@]} )); then
                sudo cp -v "${desktop_files[@]}" /etc/xdg/autostart/
            else
                echo "No .desktop files found to copy" | tee -a "$LOG_FILE"
            fi

            echo "Copying shell scripts..." | tee -a "$LOG_FILE"
            sh_files=( *.sh )
            if (( ${#sh_files[@]} )); then
                sudo cp -v "${sh_files[@]}" /usr/local/scripts/
            else
                echo "No .sh files found to copy" | tee -a "$LOG_FILE"
            fi

            echo "Copying text files..." | tee -a "$LOG_FILE"
            txt_files=( *.txt )
            if (( ${#txt_files[@]} )); then
                sudo cp -v "${txt_files[@]}" /usr/local/scripts/
            else
                echo "No .txt files found to copy" | tee -a "$LOG_FILE"
            fi

            cd ..
        else
            echo "WARNING: linux directory not found, skipping file copy section" | tee -a "$LOG_FILE"
        fi

        if cd configs; then
            echo "Updating simulation.conf..." | tee -a "$LOG_FILE"
            if [[ -f "simulation.conf" ]]; then
                sudo cp simulation.conf /usr/local/scripts/simulation.conf
            else
                echo "No simulation.conf found in configs" | tee -a "$LOG_FILE"
            fi
            cd ..
        else
            echo "WARNING: configs directory not found" | tee -a "$LOG_FILE"
        fi

        echo "Setting permissions..." | tee -a "$LOG_FILE"
        sudo chmod -R 777 /usr/local/scripts

    else
        echo "ERROR: Could not enter repo directory" | tee -a "$LOG_FILE"
    fi

else
    echo "Using local SMB repository" | tee -a "$LOG_FILE"
    smbclient "$smb_location" -N -c 'lcd /usr/local/scripts/; cd Scripts; prompt; mget *'
fi

echo "Update complete" | tee -a "$LOG_FILE"