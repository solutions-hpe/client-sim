#!/bin/bash
version=.30
pkill -f firefox
log="/usr/local/scripts/sim.log"
debug="/usr/local/scripts/debug-update.log"
echo Update Script Version $version | tee "$debug"
echo "$(date)" | tee -a "$debug"
source '/usr/local/scripts/ini-parser.sh'
process_ini_file '/usr/local/scripts/simulation.conf'
#------------------------------------------------------------
public_repo=$(get_value 'simulation' 'public_repo')
repo_location=$(get_value 'simulation' 'repo_location')
repo_branch=$(get_value 'simulation' 'repo_branch')
web_server=$(get_value 'simulation' 'web_server')
server_url=$(get_value 'server' 'server_url')
#------------------------------------------------------------
echo "Updating Scripts" | tee -a "$debug" "$log"

#------------------------------------------------------------
# Source priority:
#   1. Web server (web_server=on and server reachable) — preferred
#   2. GitHub (public_repo=on) — fallback when web server is off/unreachable
#   3. SMB — fallback when public_repo is off
#
# If the web server is enabled and reachable, GitHub clone is skipped entirely.
# The web server is the source of truth (it already mirrors GitHub).
#------------------------------------------------------------

web_server_used=false

if [[ "$web_server" == "on" && -n "$server_url" ]]; then
    echo "Web server enabled — checking reachability: $server_url" | tee -a "$debug"

    if curl -fsSL --connect-timeout 5 --max-time 10 \
            "${server_url}/api/health" >/dev/null 2>>"$debug"; then

        echo "Web server reachable — using as primary source, skipping GitHub clone" | tee -a "$debug" "$log"
        web_server_used=true

        # ── simulation.conf ──────────────────────────────────────────────────
        if curl -fsSL --connect-timeout 5 --max-time 15 \
                "${server_url}/api/config" \
                -o /tmp/simulation.conf.webserver 2>>"$debug"; then
            sudo cp /tmp/simulation.conf.webserver /usr/local/scripts/simulation.conf
            rm -f /tmp/simulation.conf.webserver
            echo "simulation.conf synced from web server" | tee -a "$debug" "$log"
        else
            echo "WARNING: Failed to fetch simulation.conf from web server" | tee -a "$debug" "$log"
        fi

        # ── Linux scripts (.sh, .txt) ────────────────────────────────────────
        file_list=$(curl -fsSL --connect-timeout 5 --max-time 10 \
            "${server_url}/api/scripts/list?platform=linux" 2>>"$debug" || echo "")

        if [[ -n "$file_list" ]]; then
            echo "Syncing linux scripts from web server..." | tee -a "$debug"
            for filename in $file_list; do
                if curl -fsSL --connect-timeout 5 --max-time 30 \
                        "${server_url}/api/scripts/linux/${filename}" \
                        -o "/usr/local/scripts/${filename}" 2>>"$debug"; then
                    echo "  ✓ $filename" | tee -a "$debug"
                else
                    echo "  ✗ WARNING: Failed to fetch $filename" | tee -a "$debug" "$log"
                fi
            done
            sudo chmod +x /usr/local/scripts/*.sh 2>/dev/null || true
            echo "Linux script sync complete" | tee -a "$debug" "$log"
        else
            echo "WARNING: Could not get script list from web server" | tee -a "$debug" "$log"
        fi

    else
        echo "WARNING: Web server not reachable — falling back to GitHub/SMB" | tee -a "$debug" "$log"
    fi
fi

#------------------------------------------------------------
# GitHub / SMB fallback — only used when web server is off or unreachable
#------------------------------------------------------------
if [[ "$web_server_used" == false ]]; then
    if [[ "$public_repo" == "on" ]]; then
        echo "Using remote GitHub repo" | tee -a "$debug"
        cd ~ || echo "WARNING: Failed to cd to home directory" | tee -a "$debug"
        repo_dir="client-sim"
        shopt -s nullglob
        if [[ -d "$repo_dir" && ! -d "$repo_dir/.git" ]]; then
            echo "Directory exists but is not a git repo. Removing directory" | tee -a "$debug"
            rm -rf "$repo_dir"
        fi
        if [[ ! -d "$repo_dir" ]]; then
            echo "Cloning repository..." | tee -a "$debug"
            git clone "$repo_location" "$repo_dir" || echo "ERROR: Clone failed" | tee -a "$debug" "$log"
        else
            echo "Repository already exists, skipping clone" | tee -a "$debug"
        fi
        #------------------------------------------------------------
        #Checking to see if the URL is mis-matched
        if cd "$repo_dir"; then
            current_remote=$(git remote get-url origin 2>/dev/null || echo "")
            if [[ "$current_remote" != "$repo_location" ]]; then
                echo "Remote URL mismatch. Fixing..." | tee -a "$debug" "$log"
                git remote set-url origin "$repo_location"
            fi
            #------------------------------------------------------------
            #Checking to see if the repo is corrupted
            if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
                echo "Repo appears corrupted. Re-cloning..." | tee -a "$debug" "$log"
                cd ~
                rm -rf "$repo_dir"
                git clone "$repo_location" "$repo_dir"
                cd "$repo_dir" || echo "ERROR: Failed to re-enter repo" | tee -a "$debug" "$log"
            fi
            git config --global http.connectTimeout 5
            git config http.lowSpeedLimit 100
            git config http.lowSpeedTime 30
            git config http.maxRequests 2
            git config pull.rebase true
            git fetch origin
            if git show-ref --verify --quiet "refs/heads/$repo_branch"; then
                echo "Switching to branch: $repo_branch" | tee -a "$debug"
                git switch "$repo_branch"
            elif git ls-remote --exit-code --heads origin "$repo_branch" >/dev/null 2>&1; then
                echo "Creating branch: $repo_branch" | tee -a "$debug"
                git switch -c "$repo_branch" "origin/$repo_branch"
            else
                echo "ERROR: Branch '$repo_branch' not found" | tee -a "$debug" "$log"
            fi
            #------------------------------------------------------------
            #Updating the Repository based on the Branch configured in simulation.conf
            echo "Updating repository..." | tee -a "$debug"
            git reset --hard "origin/$repo_branch"
            if cd linux; then
                echo "Copying rsyslog config..." | tee -a "$debug"
                if [[ -f "10-rsyslog.conf" ]]; then
                    sudo cp 10-rsyslog.conf /etc/rsyslog.d/10-rsyslog.conf
                else
                    echo "No rsyslog config file found" | tee -a "$debug" "$log"
                fi
                echo "Copying desktop startup files..." | tee -a "$debug"
                desktop_files=( *.desktop )
                if (( ${#desktop_files[@]} )); then
                    sudo cp "${desktop_files[@]}" /etc/xdg/autostart/
                else
                    echo "No .desktop files found to copy" | tee -a "$debug" "$log"
                fi
                echo "Copying shell scripts..." | tee -a "$debug"
                sh_files=( *.sh )
                if (( ${#sh_files[@]} )); then
                    sudo cp "${sh_files[@]}" /usr/local/scripts/
                else
                    echo "No .sh files found to copy" | tee -a "$debug" "$log"
                fi
                echo "Copying text files..." | tee -a "$debug"
                txt_files=( *.txt )
                if (( ${#txt_files[@]} )); then
                    sudo cp "${txt_files[@]}" /usr/local/scripts/
                else
                    echo "No .txt files found to copy" | tee -a "$debug" "$log"
                fi
                cd ..
            else
                echo "WARNING: linux directory not found, skipping file copy section" | tee -a "$debug"
            fi
            if cd configs; then
                echo "Updating simulation.conf..." | tee -a "$debug"
                if [[ -f "simulation.conf" ]]; then
                    sudo cp simulation.conf /usr/local/scripts/simulation.conf
                else
                    echo "No simulation.conf found in configs" | tee -a "$debug" "$log"
                fi
                cd ..
            else
                echo "WARNING: configs directory not found" | tee -a "$debug" "$log"
            fi
            echo "Setting permissions..." | tee -a "$debug"
            sudo chmod -R 777 /usr/local/scripts
        else
            echo "ERROR: Could not enter repo directory" | tee -a "$debug" "$log"
        fi
    else
        echo "Using local SMB repository" | tee -a "$debug"
        smbclient "$smb_location" -N -c 'lcd /usr/local/scripts/; cd Scripts; prompt; mget *'
    fi
fi

echo "Update complete" | tee -a "$debug"