# PowerShell equivalent of simulation.sh
. .\ini-parser.ps1

$version = "0.91"
$logPath = "C:\Scripts\sim.log"
Get-Date | Tee-Object -FilePath $logPath -Append
"------------------------------" | Tee-Object -FilePath $logPath -Append
"Simulation Script Version $version" | Tee-Object -FilePath $logPath -Append

# Finding adapter names
$wladapter = Get-NetAdapter | Where-Object { $_.Name -like "*wireless*" -or $_.Name -like "*wlan*" } | Select-Object -First 1 -ExpandProperty Name
if ($wladapter) { "WLAN Adapter name $wladapter" | Tee-Object -FilePath $logPath -Append }
$eadapter = Get-NetAdapter | Where-Object { $_.Name -like "*ethernet*" -or $_.Name -like "*eth*" } | Select-Object -First 1 -ExpandProperty Name
if ($eadapter) { "Wired Adapter name $eadapter" | Tee-Object -FilePath $logPath -Append }

"Parsing Config File" | Tee-Object -FilePath $logPath -Append
$global:iniConfig = Parse-IniFile 'C:\Scripts\simulation.conf'

# Global Simulation settings
$kill_switch = get_value 'simulation' 'kill_switch'
$rapid_update = get_value 'simulation' 'rapid_update'
$sim_load = get_value 'simulation' 'sim_load'
$public_repo = get_value 'simulation' 'public_repo'
$repo_location = get_value 'simulation' 'repo_location'
$vh_server = get_value 'simulation' 'vh_server'
$site_based_ssid = get_value 'simulation' 'site_based_ssid'
$iperf_bw = get_value 'simulation' 'iperf_bw'
$auth_fail = get_value 'simulation' 'auth_fail'
$ssidpw_fail = get_value 'simulation' 'ssidpw_fail'
$allow_offline = get_value 'simulation' 'allow_offline'

# Device Specific
$wsite = get_value $simulation_id 'wsite'
$sim_phy = get_value $simulation_id 'sim_phy'
$ssid = get_value $simulation_id 'ssid'
$ssidpw = get_value $simulation_id 'ssidpw'
$dhcp_fail = get_value $simulation_id 'dhcp_fail'
$dns_fail = get_value $simulation_id 'dns_fail'
$assoc_fail = get_value $simulation_id 'assoc_fail'
$port_flap = get_value $simulation_id 'port_flap'
$ping_test = get_value $simulation_id 'ping_test'
$download = get_value $simulation_id 'download'
$iperf = get_value $simulation_id 'iperf'
$www_traffic = get_value $simulation_id 'www_traffic'

# Simulation IP
$smb_address = get_value 'address' 'smb_address'
$ping_address = get_value 'address' 'ping_address'
$dns_latency_1 = get_value 'address' 'dns_latency_1'
$dns_latency_2 = get_value 'address' 'dns_latency_2'
$dns_latency_3 = get_value 'address' 'dns_latency_3'
$dns_bad_ip_1 = get_value 'address' 'dns_bad_ip_1'
$dns_bad_ip_2 = get_value 'address' 'dns_bad_ip_2'
$dns_bad_ip_3 = get_value 'address' 'dns_bad_ip_3'
$dns_bad_record_1 = get_value 'address' 'dns_bad_record_1'
$dns_bad_record_2 = get_value 'address' 'dns_bad_record_2'
$dns_bad_record_3 = get_value 'address' 'dns_bad_record_3'
$vh_server_address = get_value 'address' 'vh_server_addr'
$iperf_server = get_value 'address' 'iperf_server'

# User overrides (assuming $username is set)
$tempvar = get_value $username 'kill_switch'
if ($tempvar) { $kill_switch = $tempvar }
# ... similarly for others

Get-Date | Tee-Object -FilePath $logPath -Append
"------------------------------" | Tee-Object -FilePath $logPath -Append
"Simulation Details:" | Tee-Object -FilePath $logPath -Append
"Hostname: $env:COMPUTERNAME" | Tee-Object -FilePath $logPath -Append
"Site: $wsite" | Tee-Object -FilePath $logPath -Append
"Site Based SSID: $site_based_ssid" | Tee-Object -FilePath $logPath -Append
if ($vh_server -eq "off") { "Phy: $sim_phy" | Tee-Object -FilePath $logPath -Append }
if ($sim_phy -eq "wireless" -and $wladapter) { "Adapter: $wladapter" | Tee-Object -FilePath $logPath -Append }
"Simulation Load: $sim_load" | Tee-Object -FilePath $logPath -Append
"Kill Switch: $kill_switch" | Tee-Object -FilePath $logPath -Append
"DHCP Fail: $dhcp_fail" | Tee-Object -FilePath $logPath -Append
"DNS Fail: $dns_fail" | Tee-Object -FilePath $logPath -Append
"WWW Traffic: $www_traffic" | Tee-Object -FilePath $logPath -Append
"iPerf: $iperf" | Tee-Object -FilePath $logPath -Append
"Download: $download" | Tee-Object -FilePath $logPath -Append
"Port Flap: $port_flap" | Tee-Object -FilePath $logPath -Append
"Incorrect SSID PW: $ssidpw_fail" | Tee-Object -FilePath $logPath -Append
"------------------------------" | Tee-Object -FilePath $logPath -Append
Start-Sleep 5

# Global kill switch
$gkill_switch = Get-Content 'C:\Scripts\kill_switch.txt'

# Random numbers
$rn = Get-Random -Minimum 1 -Maximum 61
$rn_iperf_port = 5201 + (Get-Random -Minimum 0 -Maximum 11)
$rn_iperf_time = Get-Random -Minimum 1 -Maximum 301
$rn_ping_size = Get-Random -Minimum 1 -Maximum 65001
$rn_offline_time = Get-Random -Minimum 1 -Maximum 14401
$rn_sim_load = Get-Random -Minimum 1 -Maximum 100

# Running update if rapid_update on
if ($rapid_update -eq "on") { . .\update.ps1 }

# Disabling unused interface
"Disabling unused interface" | Tee-Object -FilePath $logPath -Append
if ($sim_phy -eq "ethernet") { Disable-NetAdapter -Name $wladapter -Confirm:$false }
if ($sim_phy -eq "wireless" -and $vh_server -eq "off") { Disable-NetAdapter -Name $eadapter -Confirm:$false }

# MAC ID (simplified)
$mac_id = $env:COMPUTERNAME.Substring($env:COMPUTERNAME.Length - 4, 2) + ":" + $env:COMPUTERNAME.Substring($env:COMPUTERNAME.Length - 2, 2)

# Connecting to VHServer (simplified)
$dfgw = (Get-NetRoute | Where-Object { $_.DestinationPrefix -eq '0.0.0.0/0' }).NextHop
if (Test-Connection -ComputerName $dfgw -Count 2 -Quiet) {
    "Successful network connection" | Tee-Object -FilePath $logPath -Append
} else {
    "Network connection failed" | Tee-Object -FilePath $logPath -Append
    if ($vh_server -eq "on") { . .\vhconnect.ps1 }
    Start-Sleep 15
    # Connect WiFi using netsh
    if ($site_based_ssid -eq "on") { netsh wlan connect name="$wsite-$ssid" }
    else { netsh wlan connect name="$ssid" }
    Start-Sleep 15
    $dfgw = (Get-NetRoute | Where-Object { $_.DestinationPrefix -eq '0.0.0.0/0' }).NextHop
}

# Simulation load
if ([int]$sim_load -lt $rn_sim_load) {
    "Simulation load under threshold" | Tee-Object -FilePath $logPath -Append
    "Skipping Simulations but staying associated" | Tee-Object -FilePath $logPath -Append
    netsh wlan set hostednetwork mode=disallow
    Start-Sleep $rn_offline_time
    netsh wlan set hostednetwork mode=allow
    Start-Sleep 5
    if ($site_based_ssid -eq "on" -and $ssidpw_fail -ne "on" -and $wladapter) { netsh wlan connect name="$wsite-$ssid" }
    if ($site_based_ssid -ne "on" -and $ssidpw_fail -ne "on" -and $wladapter) { netsh wlan connect name="$ssid" }
    Start-Sleep 5
}

"Kill Switch is $kill_switch" | Tee-Object -FilePath $logPath -Append
if ($kill_switch -eq "off") {
    for ($z = 1; $z -le 100; $z++) {
        # SSID PW Fail or Auth Fail
        if (($ssidpw_fail -eq "on" -or $auth_fail -eq "on") -and $wladapter) {
            if ($ssidpw_fail -eq "on") {
                for ($i = 1; $i -le 100; $i++) {
                    "Running SSID Incorrect Password" | Tee-Object -FilePath $logPath -Append
                    "Iteration $i of 100" | Tee-Object -FilePath $logPath -Append
                    # Delete connections (simplified)
                    if ($site_based_ssid -eq "on" -or $ssidpw_fail -eq "on") { netsh wlan connect name="$wsite-$ssid" }
                    else { netsh wlan connect name="$ssid" }
                }
            }
            if ($auth_fail -eq "on") {
                "Running Auth Failure" | Tee-Object -FilePath $logPath -Append
                for ($i = 1; $i -le 100; $i++) {
                    "Enable/Disable WLAN interface" | Tee-Object -FilePath $logPath -Append
                    "Iteration $i of 100" | Tee-Object -FilePath $logPath -Append
                    Disable-NetAdapter -Name $wladapter -Confirm:$false
                    Start-Sleep 5
                    Enable-NetAdapter -Name $wladapter
                }
            }
        } else {
            if (Test-Connection -ComputerName $dfgw -Count 2 -Quiet) {
                "Successful network connection" | Tee-Object -FilePath $logPath -Append
            } else {
                "Network connection failed" | Tee-Object -FilePath $logPath -Append
                "Attempting to reset adapter" | Tee-Object -FilePath $logPath -Append
                if ($vh_server -eq "on") { . .\vhconnect.ps1 }
                Start-Sleep 15
                # Reconnect
                if ($site_based_ssid -eq "on") { netsh wlan connect name="$wsite-$ssid" }
                else { netsh wlan connect name="$ssid" }
                Start-Sleep 15
            }
            $dfgw = (Get-NetRoute | Where-Object { $_.DestinationPrefix -eq '0.0.0.0/0' }).NextHop
            if (Test-Connection -ComputerName $dfgw -Count 2 -Quiet) {
                "Successful network connection" | Tee-Object -FilePath $logPath -Append
            } else {
                "Connection failed multiple times" | Tee-Object -FilePath $logPath -Append
                "Resetting configuration" | Tee-Object -FilePath $logPath -Append
                "Purging VHConfig" | Tee-Object -FilePath $logPath -Append
                # VH commands
                & 'vhclientx86_64.exe' -t "STOP USING ALL LOCAL"
                & 'vhclientx86_64.exe' -t "AUTO USE CLEAR ALL"
            }
        }

        # Other simulations
        if ($dns_fail -eq "on") { . .\dns_fail.ps1 }
        if ($download -eq "on") { . .\download.ps1 }
        if ($iperf -eq "on") { . .\iperf.ps1 }
        # Add others as needed

        Start-Sleep $rn
    }
}
