# PowerShell equivalent of startup.sh
$version = "0.33"
$logPath = "C:\Scripts\sim.log"

"------------------------------" | Tee-Object -FilePath $logPath -Append
"Startup Script Version $version" | Tee-Object -FilePath $logPath -Append
Get-Date | Tee-Object -FilePath $logPath -Append
"------------------------------" | Tee-Object -FilePath $logPath -Append

# Check Logs Script
Start-Job -ScriptBlock { . .\sys_mon.ps1 }

# Disable screen blanking
"Disabling screen blanking" | Tee-Object -FilePath $logPath -Append
powercfg /change standby-timeout-ac 0
powercfg /change monitor-timeout-ac 0

# Username detection
$username = $env:COMPUTERNAME.Split('-')[0]

# Load INI parser
"Reading Simulation Config File" | Tee-Object -FilePath $logPath -Append
. .\ini-parser.ps1
$global:iniConfig = Parse-IniFile 'C:\Scripts\simulation.conf'

"------------------------------" | Tee-Object -FilePath $logPath -Append
"Parsing Config File" | Tee-Object -FilePath $logPath -Append

function Get-SafeInt($v, $default = 0) {
    if ([string]::IsNullOrWhiteSpace($v)) { return $default }
    try { return [int]$v } catch { return $default }
}

function Get-SafeString($v, $default = "") {
    if ([string]::IsNullOrWhiteSpace($v)) { return $default }
    return [string]$v
}

# -----------------------------
# CONFIG VALUES
# -----------------------------

$site_based_num = Get-SafeInt (get_value 'simulation' 'site_based_num') 1

$reboot_schedule = get_value 'simulation' 'reboot_schedule'
$repo_location   = get_value 'simulation' 'repo_location'
$vh_server       = get_value 'simulation' 'vh_server'
$sim_phy         = get_value 'simulation' 'sim_phy'
$rapid_update    = get_value 'simulation' 'rapid_update'
$syslog          = get_value 'simulation' 'syslog'
$syslog_server   = get_value 'address' 'syslog_server'

# -----------------------------
# SAFE SIMULATION ID (FIXED)
# -----------------------------

$hostname = $env:COMPUTERNAME
$digits = ($hostname -replace '\D','')

if ($digits.Length -lt $site_based_num) {
    $subset = $digits
} else {
    $subset = $digits.Substring($digits.Length - $site_based_num, $site_based_num)
}

if ($subset.Length -lt 1) {
    $simulation_id = "s0"
} else {
    $simulation_id = "s" + $subset.Substring(0,1)
}

# -----------------------------
# USER OVERRIDES
# -----------------------------

$tempvar = get_value $username 'repo_location'
if ($tempvar) { $repo_location = $tempvar }

$tempvar = get_value $username 'vh_server'
if ($tempvar) { $vh_server = $tempvar }

$tempvar = get_value $username 'sim_phy'
if ($tempvar) { $sim_phy = $tempvar }

# -----------------------------
# SYSLOG CONFIG
# -----------------------------

if ($syslog -eq "on") {
    wevtutil sl "System" /cm:enable /lf:"C:\Windows\System32\winevt\Logs\ForwardedEvents.evtx" /rt:false
} else {
    "Skipping Syslog Server Update" | Tee-Object -FilePath $logPath -Append
}

# -----------------------------
# REBOOT SCHEDULING
# -----------------------------

$rn = [int]$reboot_schedule + (Get-Random -Maximum 600)
"Scheduling reboot $rn minutes" | Tee-Object -FilePath $logPath -Append
shutdown /r /t ($rn * 60)

# -----------------------------
# NETWORK SETUP
# -----------------------------

"Bringing up all interfaces online" | Tee-Object -FilePath $logPath -Append
Get-NetAdapter | Enable-NetAdapter -ErrorAction SilentlyContinue

$wladapter = Get-NetAdapter |
    Where-Object { $_.Name -match "wireless|wlan|wi-fi" } |
    Select-Object -First 1 -ExpandProperty Name

$eadapter = Get-NetAdapter |
    Where-Object { $_.Name -match "ethernet|eth" } |
    Select-Object -First 1 -ExpandProperty Name

if ($wladapter) { "WLAN Adapter: $wladapter" | Tee-Object -FilePath $logPath -Append }
if ($eadapter)  { "Ethernet Adapter: $eadapter" | Tee-Object -FilePath $logPath -Append }

# -----------------------------
# UPDATE
# -----------------------------

"Updating Simulation from repo" | Tee-Object -FilePath $logPath -Append
. .\update.ps1

# -----------------------------
# VH SERVER
# -----------------------------

if ($vh_server -eq "on") {
    "Starting VH client" | Tee-Object -FilePath $logPath -Append
    Start-Process -FilePath "vhclientx86_64.exe" -ArgumentList "-n" -NoNewWindow
    Start-Sleep 5
}

# -----------------------------
# FINAL STEP
# -----------------------------

"Launching Simulation Script" | Tee-Object -FilePath $logPath -Append
. .\simulation.ps1