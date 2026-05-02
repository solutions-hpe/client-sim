# ------------------------------
# Startup Script (Hardened)
# ------------------------------

$version = "0.33"
$logPath = "C:\Scripts\sim.log"

function Log($msg) {
    $msg | Tee-Object -FilePath $logPath -Append
}

function SafeFormat([string]$msg, $args) {
    if ($args -ne $null) {
        return ($msg -f $args)
    }
    return $msg
}

"------------------------------" | Tee-Object -FilePath $logPath -Append
Log "Startup Script Version $version"
Log ("Started at {0}" -f (Get-Date))
"------------------------------" | Tee-Object -FilePath $logPath -Append

Start-Job -ScriptBlock { . .\sys_mon.ps1 }

Log "Disabling screen blanking"
powercfg /change standby-timeout-ac 0
powercfg /change monitor-timeout-ac 0

$username = $env:COMPUTERNAME.Split('-')[0]

Log "Reading Simulation Config File"
. .\ini-parser.ps1
$global:iniConfig = Parse-IniFile 'C:\Scripts\simulation.conf'

Log "Parsing Config File"

# Safe config retrieval assumed unchanged
$site_based_num = get_value 'simulation' 'site_based_num'

# ------------------------------
# SAFE SIMULATION ID
# ------------------------------

$hostname = $env:COMPUTERNAME
$digits = ($hostname -replace '\D','')

if ($digits.Length -lt $site_based_num) {
    $subset = $digits
} else {
    $subset = $digits.Substring($digits.Length - $site_based_num, $site_based_num)
}

$simulation_id = if ($subset.Length -gt 0) { "s$($subset[0])" } else { "s0" }

Log ("Simulation ID resolved: {0}" -f $simulation_id)

# ------------------------------
# CONFIG VALUES
# ------------------------------

$reboot_schedule = get_value 'simulation' 'reboot_schedule'
$vh_server       = get_value 'simulation' 'vh_server'
$sim_phy         = get_value 'simulation' 'sim_phy'

# ------------------------------
# NETWORK SETUP
# ------------------------------

Log "Bringing up interfaces"
Get-NetAdapter | Enable-NetAdapter -ErrorAction SilentlyContinue

$wladapter = Get-NetAdapter | Where-Object { $_.Name -match "wireless|wlan|wi-fi" } | Select-Object -First 1 -ExpandProperty Name
$eadapter  = Get-NetAdapter | Where-Object { $_.Name -match "ethernet|eth" } | Select-Object -First 1 -ExpandProperty Name

if ($wladapter) { Log ("Wi-Fi Adapter: {0}" -f $wladapter) }
if ($eadapter)  { Log ("Ethernet Adapter: {0}" -f $eadapter) }

# ------------------------------
# UPDATE
# ------------------------------

Log "Updating Simulation from repo"
. .\update.ps1

# ------------------------------
# VH SERVER
# ------------------------------

if ($vh_server -eq "on") {
    Log "Starting VH client"
    Start-Process "vhclientx86_64.exe" -ArgumentList "-n" -NoNewWindow
}

Log "Launching Simulation Script"
. .\simulation.ps1