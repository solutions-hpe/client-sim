# -------------------------
# Simulation Script (Fixed)
# Version 0.91-safe
# -------------------------

$version = "0.91-safe"
$logPath = "C:\Scripts\sim.log"

function Log($msg) {
    $msg | Tee-Object -FilePath $logPath -Append
}

function Get-SafeInt($v, $default = 0) {
    if ([string]::IsNullOrWhiteSpace($v)) { return $default }
    try { return [int]$v } catch { return $default }
}

function Get-SafeString($v, $default = "") {
    if ([string]::IsNullOrWhiteSpace($v)) { return $default }
    return [string]$v
}

# -------------------------
# NETWORK TEST (FIXED)
# -------------------------

function Test-Network {
    try {
        return Test-NetConnection -ComputerName "8.8.8.8" -InformationLevel Quiet -WarningAction SilentlyContinue
    } catch {
        return $false
    }
}

# -------------------------
# SAFE ADAPTER HANDLING
# -------------------------

function Ensure-NetworkSafety {

    if (-not $wladapter -and -not $eadapter) {
        Log "WARNING: No adapters detected"
        return
    }

    $wifiUp = $false
    $ethUp = $false

    if ($wladapter) {
        $wifiUp = (Get-NetAdapter -Name $wladapter -ErrorAction SilentlyContinue).Status -eq "Up"
    }

    if ($eadapter) {
        $ethUp = (Get-NetAdapter -Name $eadapter -ErrorAction SilentlyContinue).Status -eq "Up"
    }

    if (-not $wifiUp -and -not $ethUp) {
        Log "CRITICAL: No active interfaces — attempting recovery"

        if ($wladapter) { Enable-NetAdapter -Name $wladapter -ErrorAction SilentlyContinue }
        if ($eadapter)  { Enable-NetAdapter -Name $eadapter -ErrorAction SilentlyContinue }

        Start-Sleep 5
    }
}

# -------------------------
# PHY MODE CONTROL
# -------------------------

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

# -------------------------
# WIFI CONNECT (SAFE)
# -------------------------

function Connect-Wifi {

    param (
        [int]$waitTime = 10,
        [int]$timeout = 20
    )

    if (-not $wladapter) {
        Log "Wi-Fi adapter missing"
        return
    }

    try {
        Disable-NetAdapter -Name $wladapter -Confirm:$false -ErrorAction SilentlyContinue
        Start-Sleep 2
        Enable-NetAdapter -Name $wladapter -ErrorAction SilentlyContinue
    } catch {
        Log "Wi-Fi toggle failed"
    }

    Start-Sleep $waitTime

    $ssidToUse = if ($site_based_ssid -eq "on") { "$wsite-$ssid" } else { $ssid }

    if (-not [string]::IsNullOrWhiteSpace($ssidToUse)) {
        try {
            $job = Start-Job -ScriptBlock {
                param($n)
                netsh wlan connect name=$n
            } -ArgumentList $ssidToUse

            Wait-Job $job -Timeout $timeout | Out-Null
            Remove-Job $job -Force -ErrorAction SilentlyContinue
        } catch {
            Log "Wi-Fi connect failed"
        }
    }

    Start-Sleep $waitTime
}

# -------------------------
# NETWORK CONTROLLER
# -------------------------

function Network-Controller {

    $network_ok = Test-Network

    if ($network_ok) {
        Log "Network OK"
        return $true
    }

    Log "Network FAILED"

    # optional VH hook
    if ($vh_server -eq "on" -and (Test-Path .\vhconnect.ps1)) {
        try { . .\vhconnect.ps1 } catch { Log "VH script failed" }
    }

    Log "Attempting Wi-Fi recovery"
    Connect-Wifi

    if (Test-Network) {
        Log "Recovery successful (Wi-Fi)"
        return $true
    }

    # Ethernet fallback
    if ($eadapter) {

        Log "Trying Ethernet fallback"

        try {
            Enable-NetAdapter -Name $eadapter -ErrorAction SilentlyContinue
            if ($wladapter) {
                Disable-NetAdapter -Name $wladapter -ErrorAction SilentlyContinue
            }
        } catch {
            Log "Ethernet switch failed"
        }

        Start-Sleep 5

        if (Test-Network) {
            Log "Recovery successful (Ethernet)"
            return $true
        }
    }

    Log "Recovery failed"
    return $false
}

# -------------------------
# MAIN LOOP
# -------------------------

Log "------------------------------"
Log "Simulation Script $version"

$cycleLimit = 100
$i = 1

while ($i -le $cycleLimit) {

    $ok = Network-Controller

    if (-not $ok) {
        Log "Cycle $i: network unstable"
    }

    # optional feature hooks (SAFE CHECKED)
    foreach ($script in @("dns_fail.ps1","download.ps1","iperf.ps1")) {
        if (Test-Path $script) {
            try { . .\$script } catch { Log "$script failed" }
        }
    }

    Start-Sleep (Get-Random -Minimum 3 -Maximum 10)

    $i++
}

Log "Simulation complete"