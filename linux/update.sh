#!/bin/bash
version=.01
pkill -f firefox
log="/usr/local/scripts/sim.log"
debug="/usr/local/scripts/debug-update.log"
echo "Update Script Version $version" | tee "$debug"
echo "$(date)" | tee -a "$debug"
source '/usr/local/scripts/ini-parser.sh'
process_ini_file '/usr/local/scripts/simulation.conf'

#------------------------------------------------------------
# Read config values
#------------------------------------------------------------
web_server=$(get_value 'simulation' 'web_server')
server_url=$(get_value 'simulation' 'server_url')
smb_repo=$(get_value 'simulation' 'smb_repo')
smb_address=$(get_value 'address' 'smb_address')
public_repo=$(get_value 'simulation' 'public_repo')
repo_location=$(get_value 'simulation' 'repo_location')
repo_branch=$(get_value 'simulation' 'repo_branch')

source_found=false

#------------------------------------------------------------
# Helper: copy files from a local directory into /usr/local/scripts
# Called after a successful web or SMB sync
#------------------------------------------------------------
copy_local_files() {
    local src_dir="$1"
    echo "Copying files from $src_dir..." | tee -a "$debug"
    shopt -s nullglob
    local sh_files=( "$src_dir"/*.sh )
    local txt_files=( "$src_dir"/*.txt )
    local desktop_files=( "$src_dir"/*.desktop )
    local conf_files=( "$src_dir"/simulation.conf )

    (( ${#sh_files[@]} ))      && sudo cp "${sh_files[@]}"      /usr/local/scripts/
    (( ${#txt_files[@]} ))     && sudo cp "${txt_files[@]}"     /usr/local/scripts/
    (( ${#desktop_files[@]} )) && sudo cp "${desktop_files[@]}" /etc/xdg/autostart/
    (( ${#conf_files[@]} ))    && sudo cp "${conf_files[@]}"    /usr/local/scripts/

    if [[ -f "$src_dir/10-rsyslog.conf" ]]; then
        sudo cp "$src_dir/10-rsyslog.conf" /etc/rsyslog.d/10-rsyslog.conf
    fi
    sudo chmod -R 777 /usr/local/scripts
}

#------------------------------------------------------------
# Helper: check if the web server API is genuinely up
# Step 1 - TCP port reachable (rules out ICMP-only responses and dead IPs)
# Step 2 - HTTP 200 + JSON body contains "status":"ok"
# Ping is intentionally NOT used; a pingable IP does not mean the API is up.
#------------------------------------------------------------
check_api_up() {
    local url="$1"
    # Parse host and port from URL (http://host:port[/path])
    local host port
    host=$(echo "$url" | sed -E 's|https?://([^:/]+).*|\1|')
    port=$(echo "$url" | sed -E 's|https?://[^:]+:([0-9]+).*|\1|')
    [[ -z "$port" ]] && port=80

    echo "Checking TCP $host:$port ..." | tee -a "$debug"
    if ! timeout 3 bash -c "cat < /dev/null > /dev/tcp/$host/$port" 2>/dev/null; then
        echo "TCP port $port on $host is not open — API is DOWN" | tee -a "$debug" "$log"
        return 1
    fi

    echo "TCP open. Checking HTTP response..." | tee -a "$debug"
    local tmp
    tmp=$(mktemp)
    local http_code
    http_code=$(curl -sS --max-time 5 -o "$tmp" -w "%{http_code}" "$url/health" 2>/dev/null)
    local body
    body=$(cat "$tmp")
    rm -f "$tmp"

    if [[ "$http_code" != "200" ]]; then
        echo "HTTP check failed (code: $http_code) — API is DOWN" | tee -a "$debug" "$log"
        return 1
    fi
    if ! echo "$body" | grep -q '"status"[[:space:]]*:[[:space:]]*"ok"'; then
        echo "HTTP 200 but body missing status:ok — API is DOWN" | tee -a "$debug" "$log"
        return 1
    fi

    echo "API confirmed UP" | tee -a "$debug"
    return 0
}

#============================================================
# TIER 1 — Web Server
#============================================================
echo "Updating Scripts" | tee -a "$debug" "$log"

if [[ "$web_server" == "on" && -n "$server_url" ]]; then
    echo "Tier 1: Trying Web Server ($server_url)..." | tee -a "$debug"

    if check_api_up "$server_url"; then
        tmp_web=$(mktemp -d)
        # Download linux scripts tarball from WebUI
        http_code=$(curl -sS --max-time 30 -o "$tmp_web/scripts.tar.gz" \
            -w "%{http_code}" "$server_url/api/scripts/download" 2>/dev/null)

        if [[ "$http_code" == "200" ]] && tar -xzf "$tmp_web/scripts.tar.gz" -C "$tmp_web" 2>/dev/null; then
            echo "Web server sync succeeded" | tee -a "$debug" "$log"
            copy_local_files "$tmp_web"
            source_found=true
        else
            echo "Web server reachable but file download failed (code: $http_code) — falling through" | tee -a "$debug" "$log"
        fi
        rm -rf "$tmp_web"
    else
        echo "Web server unreachable — skipping Tier 1" | tee -a "$debug" "$log"
    fi
fi

#============================================================
# TIER 2 — SMB Share
#============================================================
if [[ "$source_found" == false && "$smb_repo" == "on" && -n "$smb_address" ]]; then
    echo "Tier 2: Trying SMB ($smb_address)..." | tee -a "$debug"
    tmp_smb=$(mktemp -d)
    if smbclient "$smb_address" -N -c "lcd $tmp_smb; cd Scripts; prompt; mget *" 2>/dev/null; then
        echo "SMB sync succeeded" | tee -a "$debug" "$log"
        copy_local_files "$tmp_smb"
        source_found=true
    else
        echo "SMB sync failed — falling through" | tee -a "$debug" "$log"
    fi
    rm -rf "$tmp_smb"
fi

#============================================================
# TIER 3 — GitHub (last resort)
#============================================================
if [[ "$source_found" == false && "$public_repo" == "on" ]]; then
    echo "Tier 3: Trying GitHub ($repo_location)..." | tee -a "$debug"
    cd ~ || { echo "WARNING: Failed to cd to home directory" | tee -a "$debug"; exit 1; }
    repo_dir="client-sim"
    shopt -s nullglob

    if [[ -d "$repo_dir" && ! -d "$repo_dir/.git" ]]; then
        echo "Directory exists but is not a git repo. Removing..." | tee -a "$debug"
        rm -rf "$repo_dir"
    fi
    if [[ ! -d "$repo_dir" ]]; then
        echo "Cloning repository..." | tee -a "$debug"
        git clone "$repo_location" "$repo_dir" || { echo "ERROR: Clone failed" | tee -a "$debug" "$log"; }
    fi

    if cd "$repo_dir" 2>/dev/null; then
        current_remote=$(git remote get-url origin 2>/dev/null || echo "")
        if [[ "$current_remote" != "$repo_location" ]]; then
            echo "Remote URL mismatch. Fixing..." | tee -a "$debug" "$log"
            git remote set-url origin "$repo_location"
        fi

        if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
            echo "Repo corrupted. Re-cloning..." | tee -a "$debug" "$log"
            cd ~
            rm -rf "$repo_dir"
            git clone "$repo_location" "$repo_dir"
            cd "$repo_dir" || { echo "ERROR: Cannot enter repo" | tee -a "$debug" "$log"; }
        fi

        git config --global http.connectTimeout 5
        git config http.lowSpeedLimit 100
        git config http.lowSpeedTime 30
        git config http.maxRequests 2
        git config pull.rebase true
        git fetch origin

        if git show-ref --verify --quiet "refs/heads/$repo_branch"; then
            git switch "$repo_branch"
        elif git ls-remote --exit-code --heads origin "$repo_branch" >/dev/null 2>&1; then
            git switch -c "$repo_branch" "origin/$repo_branch"
        else
            echo "ERROR: Branch '$repo_branch' not found" | tee -a "$debug" "$log"
        fi

        git reset --hard "origin/$repo_branch"

        if cd linux 2>/dev/null; then
            shopt -s nullglob
            desktop_files=( *.desktop )
            sh_files=( *.sh )
            txt_files=( *.txt )
            [[ -f "10-rsyslog.conf" ]] && sudo cp 10-rsyslog.conf /etc/rsyslog.d/10-rsyslog.conf
            (( ${#desktop_files[@]} )) && sudo cp "${desktop_files[@]}" /etc/xdg/autostart/
            (( ${#sh_files[@]} ))      && sudo cp "${sh_files[@]}"      /usr/local/scripts/
            (( ${#txt_files[@]} ))     && sudo cp "${txt_files[@]}"     /usr/local/scripts/
            cd ..
        else
            echo "WARNING: linux directory not found" | tee -a "$debug"
        fi

        if cd configs 2>/dev/null; then
            [[ -f "simulation.conf" ]] && sudo cp simulation.conf /usr/local/scripts/simulation.conf
            cd ..
        else
            echo "WARNING: configs directory not found" | tee -a "$debug"
        fi

        sudo chmod -R 777 /usr/local/scripts
        echo "GitHub sync succeeded" | tee -a "$debug" "$log"
        source_found=true
    else
        echo "ERROR: Could not enter repo directory" | tee -a "$debug" "$log"
    fi
fi

#============================================================
# Result
#============================================================
if [[ "$source_found" == false ]]; then
    echo "ERROR: All update sources failed — no files updated" | tee -a "$debug" "$log"
fi
echo "Update complete" | tee -a "$debug"