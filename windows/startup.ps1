# PowerShell equivalent of startup.sh
$version = "0.33"
$logPath = "C:\Scripts\sim.log"
"------------------------------" | Tee-Object -FilePath $logPath
"Startup Script Version $version" | Tee-Object -FilePath $logPath -Append
Get-Date | Tee-Object -FilePath $logPath -Append
"------------------------------" | Tee-Object -FilePath $logPath -Append

# Check Logs Script
Start-Job -ScriptBlock { . .\sys_mon.ps1 }

# Verify key settings changed
"Disabling screen blanking" | Tee-Object -FilePath $logPath -Append
powercfg /change standby-timeout-ac 0
powercfg /change monitor-timeout-ac 0
# Windows equivalent for xset: already handled by powercfg

# Figuring out username
$username = $env:COMPUTERNAME.Split('-')[0]

# Calling config parser
"Reading Simulation Config File" | Tee-Object -FilePath $logPath -Append
. .\ini-parser.ps1
$global:iniConfig = Parse-IniFile 'C:\Scripts\simulation.conf'

"------------------------------" | Tee-Object -FilePath $logPath -Append
"Parsing Config File" | Tee-Object -FilePath $logPath -Append

$site_based_num = get_value 'simulation' 'site_based_num'
$simulation_id = "s" + ($env:COMPUTERNAME[-$site_based_num..-1] -join '')
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

# Configuring Syslog Server
if ($syslog -eq "on") {
    wevtutil sl "System" /cm:enable /lf:"C:\Windows\System32\winevt\Logs\ForwardedEvents.evtx" /rt:false
    # Add subscription (simplified)
} else {
    "Skipping Syslog Server Update" | Tee-Object -FilePath $logPath -Append
}

# Scheduling Reboot
$rn = [int]$reboot_schedule + (Get-Random -Maximum 600)
"Scheduling reboot $rn minutes" | Tee-Object -FilePath $logPath -Append
shutdown /r /t ($rn * 60)

# Bringing up all interfaces
"Bringing up all interfaces online" | Tee-Object -FilePath $logPath -Append
Get-NetAdapter | Enable-NetAdapter

# Finding adapter names
$wladapter = Get-NetAdapter | Where-Object { $_.Name -like "*wireless*" -or $_.Name -like "*wlan*" } | Select-Object -First 1 -ExpandProperty Name
if ($wladapter) { "WLAN Adapter name $wladapter" | Tee-Object -FilePath $logPath -Append }
$eadapter = Get-NetAdapter | Where-Object { $_.Name -like "*ethernet*" -or $_.Name -like "*eth*" } | Select-Object -First 1 -ExpandProperty Name
if ($eadapter) { "Wired Adapter name $eadapter" | Tee-Object -FilePath $logPath -Append }

# Changing the MAC Address (Windows equivalent - requires admin and specific adapter)
# Note: Changing MAC in Windows is more complex; skipping for now or use third-party tools

"-----------------------------" | Tee-Object -FilePath $logPath -Append
# Running Updates
"Updating Simulation from repo" | Tee-Object -FilePath $logPath -Append
. .\update.ps1

# Setting VirtualHere Server as a Daemon
if ($vh_server -eq "on") {
    "Setting VH to autostart" | Tee-Object -FilePath $logPath -Append
    "Waiting for VH Client to start" | Tee-Object -FilePath $logPath -Append
    # Start vhclientx86_64.exe as service or process
    Start-Process -FilePath "vhclientx86_64.exe" -ArgumentList "-n" -NoNewWindow
    Start-Sleep 5
}

# Setting Script Permissions
"Setting Script Permissions" | Tee-Object -FilePath $logPath -Append
"-----------------------------" | Tee-Object -FilePath $logPath -Append
# In Windows, permissions are set via ACL, but assuming scripts are executable

# Launching Simulation Script
"Launching Simulation Script" | Tee-Object -FilePath $logPath -Append
. .\simulation.ps1
