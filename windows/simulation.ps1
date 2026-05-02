# =========================================================
# Simulation Network State Engine (Debug Enabled Wi-Fi Fix)
# =========================================================

$version = "2.6-state-engine-debug"
$logPath = "C:\Scripts\sim.log"
$maxLogSize = 10MB

# -------------------------
# CONFIG
# -------------------------

$script:sim_phy = if ($sim_phy) { $sim_phy } else { "wireless" }
$script:ssid    = $ssid
$script:debug   = $true

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# -------------------------
# STATE
# -------------------------

$script:State = "Init"
$script:wifiFailCount = 0

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
    $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $msg
    $line | Tee-Object -FilePath $logPath -Append
}

function Debug($msg) {
    if ($script:debug) {
        Log ("[DEBUG] " + $msg)
    }
}

# -------------------------
# DIAGNOSTICS
# -------------------------

function Show-WifiDiagnostics {

    try {
        $info = netsh wlan show interfaces

        Debug "---- WiFi Interface Dump ----"
        $info | ForEach-Object { Debug $_ }

    } catch {
        Debug "Failed to read wlan interface"
    }
}

function Test-Network {
    try {
        Test-NetConnection -ComputerName "8.8.8.8" -InformationLevel Quiet -WarningAction SilentlyContinue
    } catch {
        $false
    }
}

function Test-WifiConnected {
    try {
        $out = netsh wlan show interfaces
        return ($out -match "State\s*:\s*connected")
    } catch {
        return $false
    }
}

# -------------------------
# ADAPTERS
# -------------------------

function Detect-Adapters {

    $wifi = Get-NetAdapter |
        Where-Object { $_.InterfaceDescription -match "Wi-Fi|Wireless|WLAN" } |
        Select-Object -First 1

    $eth = Get-NetAdapter |
        Where-Object { $_.Name -match "Ethernet|eth" } |
        Select-Object -First 1

    $script:wladapter = $wifi.Name
    $script:eadapter   = $eth.Name

    Debug "WiFi Adapter = $($script:wladapter)"
    Debug "Ethernet Adapter = $($script:eadapter)"
}

# -------------------------
# HARD ETHERNET LOCK
# -------------------------

function Enforce-EthernetLock {

    Detect-Adapters

    if ($script:wladapter) {
        Debug "Disabling Wi-Fi adapter"
        Disable-NetAdapter -Name $script:wladapter -Confirm:$false -ErrorAction SilentlyContinue
    }

    if ($script:eadapter) {
        Debug "Enabling Ethernet adapter"
        Enable-NetAdapter -Name $script:eadapter -ErrorAction SilentlyContinue
    }
}

# -------------------------
# WIFI CONNECT
# -------------------------

function Connect-Wifi {

    if (-not $script:wladapter) {
        Debug "No Wi-Fi adapter found"
        return $false
    }

    for ($i = 1; $i -le 3; $i++) {

        Debug "Wi-Fi attempt $i connecting to SSID: $script:ssid"

        Disable-NetAdapter -Name $script:wladapter -Confirm:$false -ErrorAction SilentlyContinue
        Start-Sleep 2
        Enable-NetAdapter -Name $script:wladapter -ErrorAction SilentlyContinue
        Start-Sleep 5

        $netshOutput = netsh wlan connect name="$script:ssid" 2>&1
        Debug "netsh output: $netshOutput"

        Start-Sleep 6

        Show-WifiDiagnostics

        if (Test-WifiConnected) {

            if (Test-Network) {
                Debug "Wi-Fi + Internet confirmed OK"
                return $true
            }
            else {
                Debug "Wi-Fi connected but NO internet"
            }
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

    if ($script:eadapter) {
        Disable-NetAdapter -Name $script:eadapter -Confirm:$false -ErrorAction SilentlyContinue
    }

    if (Connect-Wifi) {
        Log "STATE -> WirelessActive"
        $script:State = "WirelessActive"
        $script:wifiFailCount = 0
    }
    else {
        Log "Wi-Fi failed -> Recovery"
        $script:State = "Recovery"
    }
}

function Enter-EthernetState {

    Enforce-EthernetLock

    Log "STATE -> EthernetActive"
    $script:State = "EthernetActive"
}

function Enter-RecoveryState {

    Detect-Adapters

    if ($script:eadapter) {
        Enable-NetAdapter -Name $script:eadapter -ErrorAction SilentlyContinue
    }

    Log "STATE -> Recovery -> Ethernet fallback"
    $script:State = "EthernetActive"
}

# -------------------------
# STATE ENGINE
# -------------------------

function State-Engine {

    switch ($script:State) {

        "Init" {
            Log "STATE -> Init"

            if ($script:sim_phy -eq "wireless") {
                Enter-WirelessState
            }
            else {
                Enter-EthernetState
            }
        }

        "WirelessActive" {

            if (Test-Network -and Test-WifiConnected) {
                return
            }

            $script:wifiFailCount++

            if ($script:wifiFailCount -le 5) {

                $delay = [math]::Pow(2, $script:wifiFailCount)
                Log "Wireless retry $script:wifiFailCount/5 -> wait ${delay}s"

                Start-Sleep $delay
                Connect-Wifi | Out-Null
                return
            }

            Log "Wireless failed after retries -> Ethernet failover"
            $script:State = "Recovery"
        }

        "EthernetActive" {

            if ($script:sim_phy -eq "ethernet") {
                Enforce-EthernetLock
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
Log ("State Engine {0}" -f $version)

$cycle = 1

while ($true) {

    try {

        State-Engine

        if ($script:State -eq "WirelessActive") {

            if (-not (Test-Network)) {
                Log "Cycle $cycle: network unstable"
            }
        }

        Start-Sleep (Get-Random -Min 3 -Max 10)
        $cycle++
    }
    catch {
        Log "FATAL ERROR -> resetting state machine"
        Log $_.Exception.Message
        $script:State = "Init"
        $script:wifiFailCount = 0
        Start-Sleep 2
    }
}