. .\ini-parser.ps1

$version = "0.91"
$logPath = "C:\Scripts\sim.log"

function Log($msg) {
    $msg | Tee-Object -FilePath $logPath -Append
}

function Get-SafeInt($v, $default = 0) {
    try {
        if ($null -eq $v -or $v -eq "") { return $default }
        return [int]$v
    } catch {
        return $default
    }
}

function Get-SafeString($v, $default = "") {
    if ([string]::IsNullOrWhiteSpace($v)) { return $default }
    return [string]$v
}

Get-Date | Log
"------------------------------" | Log
"Simulation Script Version $version" | Log

$iniConfig = Parse-IniFile 'C:\Scripts\simulation.conf'

$hostname = $env:COMPUTERNAME
if ([string]::IsNullOrWhiteSpace($hostname)) { $hostname = $env:HOSTNAME }
if ([string]::IsNullOrWhiteSpace($hostname)) { $hostname = [System.Net.Dns]::GetHostName() }
if ([string]::IsNullOrWhiteSpace($hostname)) { $hostname = "UNKNOWN" }

Log "Hostname: $hostname"

$wladapter = Get-NetAdapter | Where-Object { $_.Name -match "wireless|wlan|wi-fi" } | Select-Object -First 1 -ExpandProperty Name
$eadapter  = Get-NetAdapter | Where-Object { $_.Name -match "ethernet|eth|enp|eno|ens" } | Select-Object -First 1 -ExpandProperty Name

if ($wladapter) { Log "WLAN Adapter name $wladapter" }
if ($eadapter) { Log "Wired Adapter name $eadapter" }

Log "Parsing Config File"

$kill_switch = Get-SafeString (get_value 'simulation' 'kill_switch') "off"
$rapid_update = Get-SafeString (get_value 'simulation' 'rapid_update') "off"
$sim_load = Get-SafeInt (get_value 'simulation' 'sim_load') 100
$vh_server = Get-SafeString (get_value 'simulation' 'vh_server') "off"
$site_based_ssid = Get-SafeString (get_value 'simulation' 'site_based_ssid') "off"
$ssidpw_fail = Get-SafeString (get_value 'simulation' 'ssidpw_fail') "off"
$auth_fail = Get-SafeString (get_value 'simulation' 'auth_fail') "off"
$dns_fail = Get-SafeString (get_value 'simulation' 'dns_fail') "off"
$download = Get-SafeString (get_value 'simulation' 'download') "off"
$iperf = Get-SafeString (get_value 'simulation' 'iperf') "off"
$www_traffic = Get-SafeString (get_value 'simulation' 'www_traffic') "off"

$wsite = Get-SafeString (get_value $simulation_id 'wsite')
$sim_phy = Get-SafeString (get_value $simulation_id 'sim_phy') "wireless"
$ssid = Get-SafeString (get_value $simulation_id 'ssid')
$ssidpw = Get-SafeString (get_value $simulation_id 'ssidpw')

$ping_address = Get-SafeString (get_value 'address' 'ping_address')
$iperf_server = Get-SafeString (get_value 'address' 'iperf_server')

$dfgw = Get-NetRoute -DestinationPrefix "0.0.0.0/0" |
        Sort-Object RouteMetric |
        Select-Object -First 1 -ExpandProperty NextHop

$network_ok = $false

if ([string]::IsNullOrWhiteSpace($dfgw)) {
    Log "No default gateway detected"
    $network_ok = $false
}
else {
    try {
        $network_ok = Test-Connection -ComputerName $dfgw -Count 2 -Quiet -ErrorAction Stop
    } catch {
        Log "Gateway test failed: $($_.Exception.Message)"
        $network_ok = $false
    }
}

if ($network_ok) {
    Log "Successful network connection"
}
else {
    Log "Network connection failed"

    if ($vh_server -eq "on" -and (Test-Path .\vhconnect.ps1)) {
        . .\vhconnect.ps1
    }

    Start-Sleep 15

    if ($site_based_ssid -eq "on" -and $ssid -and $wsite) {
        netsh wlan connect name="$wsite-$ssid"
    }
    elseif ($ssid) {
        netsh wlan connect name="$ssid"
    }

    Start-Sleep 15
}

if ($rapid_update -eq "on" -and (Test-Path .\update.ps1)) {
    . .\update.ps1
}

Log "Disabling unused interface"

if ($sim_phy -eq "ethernet" -and $wladapter) {
    Disable-NetAdapter -Name $wladapter -Confirm:$false -ErrorAction SilentlyContinue
}

if ($sim_phy -eq "wireless" -and $vh_server -eq "off" -and $eadapter) {
    Disable-NetAdapter -Name $eadapter -Confirm:$false -ErrorAction SilentlyContinue
}

$rn_sim_load = Get-Random -Minimum 1 -Maximum 100

if ($sim_load -lt $rn_sim_load) {
    Log "Simulation load under threshold"
    Start-Sleep (Get-Random -Minimum 1 -Maximum 10)
}

$kill_switch = Get-SafeString $kill_switch "off"

Log "Kill Switch is $kill_switch"

if ($kill_switch -eq "off") {

    for ($z = 1; $z -le 100; $z++) {

        if (($ssidpw_fail -eq "on" -or $auth_fail -eq "on") -and $wladapter) {

            if ($ssidpw_fail -eq "on" -and $ssid) {
                for ($i = 1; $i -le 100; $i++) {
                    Log "SSID Incorrect Password Simulation"
                    if ($site_based_ssid -eq "on" -and $wsite) {
                        netsh wlan connect name="$wsite-$ssid"
                    }
                    elseif ($ssid) {
                        netsh wlan connect name="$ssid"
                    }
                }
            }

            if ($auth_fail -eq "on" -and $wladapter) {
                for ($i = 1; $i -le 100; $i++) {
                    Disable-NetAdapter -Name $wladapter -Confirm:$false -ErrorAction SilentlyContinue
                    Start-Sleep 2
                    Enable-NetAdapter -Name $wladapter -ErrorAction SilentlyContinue
                }
            }
        }
        else {

            if ($network_ok) {
                Log "Successful network connection"
            }
            else {
                Log "Network connection failed"

                if ($vh_server -eq "on" -and (Test-Path .\vhconnect.ps1)) {
                    . .\vhconnect.ps1
                }

                Start-Sleep 15

                if ($site_based_ssid -eq "on" -and $ssid -and $wsite) {
                    netsh wlan connect name="$wsite-$ssid"
                }
                elseif ($ssid) {
                    netsh wlan connect name="$ssid"
                }

                Start-Sleep 15
            }

            $dfgw = Get-NetRoute -DestinationPrefix "0.0.0.0/0" |
                    Sort-Object RouteMetric |
                    Select-Object -First 1 -ExpandProperty NextHop

            if (-not [string]::IsNullOrWhiteSpace($dfgw)) {
                $network_ok = Test-Connection -ComputerName $dfgw -Count 2 -Quiet -ErrorAction SilentlyContinue
            }
            else {
                $network_ok = $false
            }

            if (-not $network_ok) {
                Log "Connection failed multiple times"

                if (Test-Path vhclientx86_64.exe) {
                    & 'vhclientx86_64.exe' -t "STOP USING ALL LOCAL"
                    & 'vhclientx86_64.exe' -t "AUTO USE CLEAR ALL"
                }
            }
        }

        if ($dns_fail -eq "on" -and (Test-Path .\dns_fail.ps1)) { . .\dns_fail.ps1 }
        if ($download -eq "on" -and (Test-Path .\download.ps1)) { . .\download.ps1 }
        if ($iperf -eq "on" -and (Test-Path .\iperf.ps1)) { . .\iperf.ps1 }

        Start-Sleep (Get-SafeInt $rn_sim_load 5)
    }
}