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

# Device Specific Simulation settings
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

# User/Device Specific Overrides
function apply_override {
    param([string]$var)
    $val = get_value $username $var
    if ($val) { Set-Variable -Name $var -Value $val -Scope Global }
}

$override_keys = @('kill_switch', 'sim_load', 'public_repo', 'repo_location', 'vh_server', 'site_based_ssid', 'iperf_bw', 'wsite', 'sim_phy', 'ssid', 'ssidpw', 'dhcp_fail', 'dns_fail', 'assoc_fail', 'port_flap', 'ping_test', 'download', 'iperf', 'www_traffic', 'ssidpw_fail', 'auth_fail', 'smb_address', 'ping_address', 'dns_latency_1', 'dns_latency_2', 'dns_latency_3', 'dns_bad_ip_1', 'dns_bad_ip_2', 'dns_bad_ip_3', 'dns_bad_record_1', 'dns_bad_record_2', 'dns_bad_record_3', 'vh_server_addr', 'iperf_server')

foreach ($key in $override_keys) {
    apply_override $key
}

Get-Date | Tee-Object -FilePath $logPath -Append
"------------------------------" | Tee-Object -FilePath $logPath -Append
"Simulation Details:" | Tee-Object -FilePath $logPath -Append
"Hostname: $env:COMPUTERNAME" | Tee-Object -FilePath $logPath -Append
"Site: $wsite" | Tee-Object -FilePath $logPath -Append
"Site Based SSID: $site_based_ssid" | Tee-Object -FilePath $logPath -Append
"VHServer: $vh_server" | Tee-Object -FilePath $logPath -Append
if ($vh_server -eq "off") { "Phy: $sim_phy" | Tee-Object -FilePath $logPath -Append }
if ($sim_phy -eq "wireless" -and $wladapter) { "Adapter: $wladapter" | Tee-Object -FilePath $logPath -Append }
"Simulation Load: $sim_load" | Tee-Object -FilePath $logPath -Append
"Kill Switch: $kill_switch" | Tee-Object -FilePath $logPath -Append
"DHCP Fail: $dhcp_fail" | Tee-Object -FilePath $logPath -Append
"DNS Fail: $dns_fail" | Tee-Object -FilePath $logPath -Append
"WWW Traffic: $www_traffic" | Tee-Object -FilePath $logPath -Append
