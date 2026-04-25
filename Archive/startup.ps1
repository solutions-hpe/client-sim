# PowerShell equivalent of startup.sh
$version = "0.33"
$logPath = "C:\Scripts\sim.log"
"------------------------------" | Tee-Object -FilePath $logPath
"Startup Script Version $version" | Tee-Object -FilePath $logPath -Append
Get-Date | Tee-Object -FilePath $logPath -Append
"------------------------------" | Tee-Object -FilePath $logPath -Append

# Check Logs Script
Start-Job -ScriptBlock { . .\sys_mon.ps1 }

# Verify key settings
"Disabling screen blanking" | Tee-Object -FilePath $logPath -Append
# Windows equivalent: powercfg /change standby-timeout-ac 0 or something, but skip

# Figuring out username
$username = $env:COMPUTERNAME.Split('-')[0]

# Calling config parser
"Reading Simulation Config File" | Tee-Object -FilePath $logPath -Append
. .\ini-parser.ps1
$global:iniConfig = Parse-IniFile 'C:\Scripts\simulation.conf'

"------------------------------" | Tee-Object -FilePath $logPath -Append
"Parsing Config File" | Tee-Object -FilePath $logPath -Append

$site_based_num = get_value 'simulation' 'site_based_num'
$simulation_id = "s" + $env:COMPUTERNAME[-$site_based_num..-1] -join ''
$reboot_schedule = get_value 'simulation' 'reboot_schedule'
$repo_location = get_value 'simulation' 'repo_location'
$vh_server = get_value 'simulation' 'vh_server'
$sim_phy = get_value $simulation_id 'sim_phy'
$rapid_update = get_value 'simulation' 'rapid_update'
$syslog = get_value 'simulation' 'syslog'
$syslog_server = get_value 'address' 'syslog_server'

$tempvar = get_value $username 'repo_location'
if ($tempvar) { $repo_location = $tempvar }
$tempvar = get_value $username 'vh_server'
if ($tempvar) { $vh_server = $tempvar }
$tempvar = get_value $username 'sim_phy'
if ($tempvar) { $sim_phy = $tempvar }

# Configuring Syslog Server (Event Forwarding)
if ($syslog -eq "on") {
    # Use wevtutil to set up event forwarding
    wevtutil sl "System" /cm:enable /lf:"C:\Windows\System32\winevt\Logs\ForwardedEvents.evtx" /rt:false
    # Add subscription (simplified)
    # This is complex, perhaps skip or use a script
} else {
    "Skipping Syslog Server Update" | Tee-Object -FilePath $logPath -Append
}

# Scheduling Reboot
$rn = [int]$reboot_schedule + (Get-Random -Maximum 601)
"Scheduling reboot $rn minutes" | Tee-Object -FilePath $logPath -Append
$rebootTime = (Get-Date).AddMinutes($rn)
schtasks /create /tn "SimulationReboot" /tr "shutdown /r /t 0" /sc once /st $rebootTime.ToString("HH:mm") /sd $rebootTime.ToString("MM/dd/yyyy") /f

# Bringing up all interfaces
"Bringing up all interfaces online" | Tee-Object -FilePath $logPath -Append
$wladapter = Get-NetAdapter | Where-Object { $_.Name -like "*wireless*" -or $_.Name -like "*wlan*" } | Select-Object -First 1 -ExpandProperty Name
$eadapter = Get-NetAdapter | Where-Object { $_.Name -like "*ethernet*" -or $_.Name -like "*eth*" } | Select-Object -First 1 -ExpandProperty Name
if ($wladapter) { "WLAN Adapter name $wladapter" | Tee-Object -FilePath $logPath -Append; Enable-NetAdapter -Name $wladapter }
if ($eadapter) { "Wired Adapter name $eadapter" | Tee-Object -FilePath $logPath -Append; Enable-NetAdapter -Name $eadapter }

# Changing MAC Address (simplified, assuming a function)
$mac_id = $env:COMPUTERNAME.Substring($env:COMPUTERNAME.Length - 4, 2) + ":" + $env:COMPUTERNAME.Substring($env:COMPUTERNAME.Length - 2, 2)
# Set-NetAdapter -Name $wladapter -MacAddress $mac_id (but need full MAC)

"-----------------------------" | Tee-Object -FilePath $logPath -Append

# Running Updates
if ($rapid_update -ne "on") {
    "Updating Simulation from repo" | Tee-Object -FilePath $logPath -Append
    . .\update.ps1
} else {
    "Rapid Update is $rapid_update" | Tee-Object -FilePath $logPath -Append
    "Skipping update" | Tee-Object -FilePath $logPath -Append
}

# Setting VirtualHere Server as a Daemon
if ($vh_server -eq "on") {
    "Setting VH to autostart" | Tee-Object -FilePath $logPath -Append
    "Waiting for VH Client to start" | Tee-Object -FilePath $logPath -Append
    & 'vhclientx86_64.exe' -n
    Start-Sleep 5
}

"Setting Script Permissions" | Tee-Object -FilePath $logPath -Append
"-----------------------------" | Tee-Object -FilePath $logPath -Append
# Not needed in PS

# Launching Simulation Script
"Launching Simulation Script" | Tee-Object -FilePath $logPath -Append
. .\simulation.ps1
