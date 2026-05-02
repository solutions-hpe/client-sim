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

function Test-Network {
    $gw = Get-NetRoute -DestinationPrefix "0.0.0.0/0" |
        Sort-Object RouteMetric |
        Select-Object -First 1 -ExpandProperty NextHop

    if ([string]::IsNullOrWhiteSpace($gw)) { return $false }

    try {
        return Test-Connection -ComputerName $gw -Count 2 -Quiet -ErrorAction SilentlyContinue
    } catch {
        return $false
    }
}

function Ensure-NetworkSafety {

    $wifiUp = $false
    $ethUp = $false

    if ($wladapter) {
        $wifiUp = (Get-NetAdapter -Name $wladapter -ErrorAction SilentlyContinue).Status -eq "Up"
    }

    if ($eadapter) {
        $ethUp = (Get-NetAdapter -Name $eadapter -ErrorAction SilentlyContinue).Status -eq "Up"
    }

    if (-not $wifiUp -and -not $ethUp) {

        Log "CRITICAL: No interfaces up — forcing recovery"

        if ($wladapter) { Enable-NetAdapter -Name $wladapter -ErrorAction SilentlyContinue }
        if ($eadapter)  { Enable-NetAdapter -Name $eadapter -ErrorAction SilentlyContinue }

        Start-Sleep 5
    }
}

function Apply-PhyMode {

    if ($sim_phy -eq "ethernet") {

        if ($eadapter) {
            Enable-NetAdapter -Name $eadapter -ErrorAction SilentlyContinue
        }

        if ($wladapter) {
            Disable-NetAdapter -Name $wladapter -Confirm:$false -ErrorAction SilentlyContinue
        }

        Log "PHY MODE: Ethernet only"
    }

    elseif ($sim_phy -eq "wireless") {

        if ($wladapter) {
            Enable-NetAdapter -Name $wladapter -ErrorAction SilentlyContinue
        }

        Log "PHY MODE: Wireless primary"
    }

    Ensure-NetworkSafety
}

function Connect-Wifi {

    param (
        [int]$waitTime = 15,
        [int]$timeout = 30
    )

    if (-not $wladapter) {
        Log "Wi-Fi adapter missing"
        return
    }

    Disable-NetAdapter -Name $wladapter -Confirm:$false -ErrorAction SilentlyContinue
    Start-Sleep 2
    Enable-NetAdapter -Name $wladapter -ErrorAction SilentlyContinue

    Start-Sleep $waitTime

    $ssidToUse = if ($site_based_ssid -eq "on") { "$wsite-$ssid" } else { $ssid }

    if (-not [string]::IsNullOrWhiteSpace($ssidToUse)) {
        $job = Start-Job { param($n) netsh wlan connect name="$n" } -ArgumentList $ssidToUse
        Wait-Job $job -Timeout $timeout | Out-Null
        Remove-Job $job -Force -ErrorAction SilentlyContinue
    }

    Start-Sleep $waitTime
}

function Network-Controller {

    param([switch]$ForceRecovery)

    $network_ok = Test-Network

    if ($network_ok) {
        Log "Network OK"
        return $true
    }

    Log "Network FAILED"

    if ($vh_server -eq "on" -and (Test-Path .\vhconnect.ps1)) {
        . .\vhconnect.ps1
    }

    Log "Attempting Wi-Fi recovery"
    Connect-Wifi -waitTime 15

    $network_ok = Test-Network

    if ($network_ok) {
        Log "Recovery successful (Wi-Fi)"
        return $true
    }

    if ($sim_phy -eq "wireless" -and $eadapter) {

        Log "Switching to Ethernet recovery"

        Enable-NetAdapter -Name $eadapter -ErrorAction SilentlyContinue

        if ($wladapter) {
            Disable-NetAdapter -Name $wladapter -ErrorAction SilentlyContinue
        }

        Start-Sleep 5

        $network_ok = Test-Network

        if ($network_ok) {
            Log "Recovery successful (Ethernet)"
            return $true
        }
    }

    Log "Full recovery failed"
    return $false
}

# -------------------------
# STARTUP
# -------------------------

Get-Date | Log
"------------------------------" | Log
"Simulation Script Version $version" | Log

$iniConfig = Parse-IniFile 'C:\Scripts\simulation.conf'

$hostname = $env:COMPUTERNAME
if ([string]::IsNullOrWhiteSpace($hostname)) {
    $hostname = $env:HOSTNAME
}
if ([string]::IsNullOrWhiteSpace($hostname)) {
    $hostname = [System.Net.Dns]::GetHostName()
}
if ([string]::IsNullOrWhiteSpace($hostname)) {
    $hostname = "UNKNOWN"
}

Log "Hostname: $hostname"

$wladapter = Get-NetAdapter | Where-Object { $_.Name -match "wireless|wlan|wi-fi" } | Select-Object -First 1 -ExpandProperty Name
$eadapter  = Get-NetAdapter | Where-Object { $_.Name -match "ethernet|eth|enp|eno|ens" } | Select-Object -First 1 -ExpandProperty Name

if ($wladapter) { Log "Wi-Fi Adapter: $wladapter" }
if ($eadapter)  { Log "Ethernet Adapter: $eadapter" }

$kill_switch = Get-SafeString (get_value 'simulation' 'kill_switch') "off"
$rapid_update = Get-SafeString (get_value 'simulation' 'rapid_update') "off"
$sim_load = Get-SafeInt (get_value 'simulation' 'sim_load') 100
$vh_server = Get-SafeString (get_value 'simulation' 'vh_server') "off"
$site_based_ssid = Get-SafeString (get_value 'simulation' 'site_based_ssid') "off"

$ssid = Get-SafeString (get_value $simulation_id 'ssid')
$wsite = Get-SafeString (get_value $simulation_id 'wsite')
$sim_phy = Get-SafeString (get_value $simulation_id 'sim_phy') "wireless"

Apply-PhyMode

$network_ok = Network-Controller

if ($rapid_update -eq "on" -and (Test-Path .\update.ps1)) {
    . .\update.ps1
}

$rn_sim_load = Get-Random -Minimum 1 -Maximum 100

if ($sim_load -lt $rn_sim_load) {
    Log "Low simulation load"
    Start-Sleep (Get-Random -Minimum 1 -Maximum 10)
}

Log "Kill Switch: $kill_switch"

if ($kill_switch -eq "off") {

    for ($z = 1; $z -le 100; $z++) {

        $network_ok = Network-Controller

        if (-not $network_ok) {
            Log "Recovery attempt cycle $z failed"
        }

        if ($dns_fail -eq "on" -and (Test-Path .\dns_fail.ps1)) { . .\dns_fail.ps1 }
        if ($download -eq "on" -and (Test-Path .\download.ps1)) { . .\download.ps1 }
        if ($iperf -eq "on" -and (Test-Path .\iperf.ps1)) { . .\iperf.ps1 }

        Start-Sleep (Get-SafeInt $rn_sim_load 5)
    }
}