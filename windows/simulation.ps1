# =========================================================
# Simulation Network State Engine (Hardened Logging Pass)
# =========================================================

$version = "2.7-state-engine-hardened"
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
                Set-Content -Path $logPath -Value (Get-Content $logPath -Tail 5000)
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
        Log ("[DEBUG] {0}" -f $msg)
    }
}

# -------------------------
# DIAGNOSTICS
# -------------------------

function Show-WifiDiagnostics {

    try {
        $info = netsh wlan show interfaces

        Debug "---- WiFi Interface Dump ----"
        $info | ForEach-Object {
            Debug ("{0}" -f $_)
        }
    }
    catch {
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
        (netsh wlan show interfaces) -match "State\s*:\s*connected"
    } catch {
        $false
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

    Debug ("WiFi Adapter = {0}" -f $script:wladapter)
    Debug ("Ethernet Adapter = {0}" -f $script:eadapter)
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

        Debug ("Wi-Fi attempt {0} -> SSID {1}" -f $i, $script:ssid)

        Disable-NetAdapter -Name $script:wladapter -Confirm:$false -ErrorAction SilentlyContinue
        Start-Sleep 2
        Enable-NetAdapter -Name $script:wladapter -ErrorAction SilentlyContinue
        Start-Sleep 5

        $netshOutput = netsh wlan connect name="$script:ssid" 2>&1
        Debug ("netsh output: {0}" -f ($netshOutput -join " "))

        Start-Sleep 6

        Show-WifiDiagnostics

        if (Test-WifiConnected -and Test-Network) {
            Debug "Wi-Fi + Internet confirmed"
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

    if ($script:eadapter) {
        Disable-NetAdapter -Name $script:eadapter -Confirm:$false -ErrorAction SilentlyContinue
    }

    if (Connect-Wifi) {
        Log "STATE -> WirelessActive"
        $script:State = "WirelessActive"
        $script:wifiFailCount = 0
    }
    else {
        Log "STATE -> WiFiFailed -> Recovery"
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

                Log ("Wireless retry {0}/5 -> wait {1}s" -f $script:wifiFailCount, $delay)

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
                Log ("Cycle {0}: network unstable" -f $cycle)
            }
        }

        Start-Sleep (Get-Random -Min 3 -Max 10)
        $cycle++
    }
    catch {
        Log "FATAL ERROR -> reset to Init"
        Log ($_.Exception.Message)
        $script:State = "Init"
        $script:wifiFailCount = 0
        Start-Sleep 2
    }
}