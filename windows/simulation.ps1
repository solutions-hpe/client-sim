# =========================================================
# Simulation Network State Engine (Production Clean Version)
# =========================================================

$version = "2.0-state-engine"
$logPath = "C:\Scripts\sim.log"
$maxLogSize = 10MB

# -------------------------
# CONFIG SAFE DEFAULTS
# -------------------------

$script:sim_phy = if ($sim_phy) { $sim_phy } else { "wireless" }
$script:ssid    = if ($ssid) { $ssid } else { "" }

# -------------------------
# STATE MACHINE
# -------------------------

$script:State = "Init"

# -------------------------
# LOGGING
# -------------------------

function Rotate-LogIfNeeded {
    if (Test-Path $logPath) {
        try {
            if ((Get-Item $logPath).Length -ge $maxLogSize) {
                $content = Get-Content $logPath -Tail 5000
                Set-Content -Path $logPath -Value $content
            }
        } catch {}
    }
}

function Log($msg) {
    Rotate-LogIfNeeded
    $msg | Tee-Object -FilePath $logPath -Append
}

# -------------------------
# NETWORK CHECKS
# -------------------------

function Test-Network {
    try {
        return Test-NetConnection -ComputerName "8.8.8.8" -InformationLevel Quiet -WarningAction SilentlyContinue
    } catch {
        return $false
    }
}

function Test-WifiConnected {
    try {
        return (netsh wlan show interfaces) -match "State\s*:\s*connected"
    } catch {
        return $false
    }
}

# -------------------------
# ADAPTER DETECTION
# -------------------------

function Detect-Adapters {

    $script:wladapter = Get-NetAdapter |
        Where-Object {
            $_.InterfaceDescription -match "Wi-Fi|Wireless" -or
            $_.Name -match "Wi-Fi|WLAN|Wireless"
        } |
        Select-Object -First 1 -ExpandProperty Name

    $script:eadapter = Get-NetAdapter |
        Where-Object { $_.Name -match "Ethernet|eth" } |
        Select-Object -First 1 -ExpandProperty Name
}

# -------------------------
# WIFI CONNECT
# -------------------------

function Connect-Wifi {

    if (-not $script:wladapter -or -not $script:ssid) {
        return $false
    }

    for ($i = 1; $i -le 3; $i++) {

        Log ("Wi-Fi attempt {0} → {1}" -f $i, $script:ssid)

        Disable-NetAdapter -Name $script:wladapter -Confirm:$false -ErrorAction SilentlyContinue
        Start-Sleep 2
        Enable-NetAdapter -Name $script:wladapter -ErrorAction SilentlyContinue

        Start-Sleep 5

        netsh wlan connect name="$script:ssid" | Out-Null
        Start-Sleep 6

        if (Test-WifiConnected) {
            Log "Wi-Fi connected"
            return $true
        }

        Start-Sleep (5 * $i)
    }

    return $false
}

# -------------------------
# STATE ACTIONS
# -------------------------

function Enter-WirelessState {

    Detect-Adapters

    if (-not $script:wladapter) {
        Log "Wireless requested but adapter missing → fallback Ethernet"
        $script:State = "EthernetActive"
        return
    }

    if ($script:eadapter) {
        Disable-NetAdapter -Name $script:eadapter -Confirm:$false -ErrorAction SilentlyContinue
    }

    if (Connect-Wifi) {
        Log "STATE → WirelessActive"
        $script:State = "WirelessActive"
    }
    else {
        Log "Wi-Fi failed → entering Recovery"
        $script:State = "Recovery"
    }
}

function Enter-EthernetState {

    Detect-Adapters

    if ($script:eadapter) {
        Enable-NetAdapter -Name $script:eadapter -ErrorAction SilentlyContinue
    }

    if ($script:wladapter) {
        Disable-NetAdapter -Name $script:wladapter -Confirm:$false -ErrorAction SilentlyContinue
    }

    Log "STATE → EthernetActive"
    $script:State = "EthernetActive"
}

function Enter-RecoveryState {

    Log "STATE → Recovery"

    Detect-Adapters

    if (Connect-Wifi) {
        Log "Recovery success → WirelessActive"
        $script:State = "WirelessActive"
        return
    }

    if ($script:eadapter) {
        Enable-NetAdapter -Name $script:eadapter -ErrorAction SilentlyContinue
    }

    $script:State = "EthernetActive"
}

# -------------------------
# STATE ROUTER
# -------------------------

function State-Engine {

    switch ($script:State) {

        "Init" {
            Log "STATE → Init"
            if ($script:sim_phy -eq "wireless") {
                Enter-WirelessState
            } else {
                Enter-EthernetState
            }
        }

        "WirelessActive" {

            if (Test-Network -and Test-WifiConnected) {
                Log "Wireless OK"
                return
            }

            Log "Wireless degraded → Recovery"
            $script:State = "Recovery"
        }

        "EthernetActive" {

            if ($script:sim_phy -eq "wireless") {
                Enter-WirelessState
            }
        }

        "Recovery" {
            Enter-RecoveryState
        }
    }
}

# -------------------------
# MAIN LOOP
# -------------------------

Log "================================"
Log ("State Engine Simulation {0}" -f $version)
Log ("Start: {0}" -f (Get-Date))

$cycle = 1

while ($true) {

    if (Test-Path "C:\Scripts\kill.flag") {
        Log "Kill switch activated"
        break
    }

    State-Engine

    if ($script:State -eq "WirelessActive") {

        if (-not (Test-Network)) {
            Log ("Cycle {0}: network unstable" -f $cycle)
        }

        foreach ($scriptName in @("dns_fail.ps1","download.ps1","iperf.ps1")) {
            if (Test-Path $scriptName) {
                try { & ".\$scriptName" } catch {}
            }
        }
    }
    else {
        Log ("Cycle {0}: system in {1} (no simulation)" -f $cycle, $script:State)
    }

    Start-Sleep (Get-Random -Minimum 3 -Maximum 10)

    $cycle++
}

Log "Simulation stopped"