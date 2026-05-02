# =========================================================
# Simulation Network State Engine (Hard Ethernet Lock Fix)
# =========================================================

$version = "2.4-state-engine-ethernet-lock"
$logPath = "C:\Scripts\sim.log"
$maxLogSize = 10MB

# -------------------------
# CONFIG
# -------------------------

$script:sim_phy = if ($sim_phy) { $sim_phy } else { "wireless" }
$script:ssid    = $ssid

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

# -------------------------
# NETWORK CHECKS
# -------------------------

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
}

# -------------------------
# HARD ETHERNET LOCK
# -------------------------

function Enforce-EthernetLock {

    Detect-Adapters

    if ($script:wladapter) {
        Disable-NetAdapter -Name $script:wladapter -Confirm:$false -ErrorAction SilentlyContinue
    }

    if ($script:eadapter) {
        Enable-NetAdapter -Name $script:eadapter -ErrorAction SilentlyContinue
    }
}

# -------------------------
# WIFI CONNECT
# -------------------------

function Connect-Wifi {

    if (-not $script:wladapter) { return $false }

    for ($i = 1; $i -le 3; $i++) {

        Log ("Wi-Fi attempt {0} → {1}" -f $i, $script:ssid)

        Disable-NetAdapter -Name $script:wladapter -Confirm:$false -ErrorAction SilentlyContinue
        Start-Sleep 2
        Enable-NetAdapter -Name $script:wladapter -ErrorAction SilentlyContinue
        Start-Sleep 5

        netsh wlan connect name="$script:ssid" | Out-Null
        Start-Sleep 6

        if (Test-WifiConnected) {
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
        Log "STATE → WirelessActive"
        $script:State = "WirelessActive"
        $script:wifiFailCount = 0
    }
    else {
        Log "Wi-Fi failed → Recovery"
        $script:State = "Recovery"
    }
}

function Enter-EthernetState {

    Enforce-EthernetLock

    Log "STATE → EthernetActive"
    $script:State = "EthernetActive"
}

function Enter-RecoveryState {

    Detect-Adapters

    if ($script:eadapter) {
        Enable-NetAdapter -Name $script:eadapter -ErrorAction SilentlyContinue
    }

    Log "STATE → Recovery → Ethernet fallback"
    $script:State = "EthernetActive"
}

# -------------------------
# STATE ENGINE
# -------------------------

function State-Engine {

    switch ($script:State) {

        "Init" {
            Log "STATE → Init"

            if ($script:sim_phy -eq "wireless") {
                Enter-WirelessState
            }
            else {
                Enter-EthernetState
            }
        }

        "WirelessActive" {

            if (Test-Network -and Test-WifiConnected) {
                $script:wifiFailCount = 0
                return
            }

            $script:wifiFailCount++

            if ($script:wifiFailCount -le 5) {

                $delay = [math]::Pow(2, $script:wifiFailCount)
                Log ("Wireless retry {0}/5 → wait {1}s" -f $script:wifiFailCount, $delay)

                Start-Sleep $delay
                Connect-Wifi | Out-Null
                return
            }

            Log "Wireless failed → switching to Ethernet"
            $script:State = "Recovery"
        }

        "EthernetActive" {

            # HARD RULE: never attempt Wi-Fi in ethernet mode
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

        if (Test-Path "C:\Scripts\kill.flag") {
            Log "Kill switch activated"
            break
        }

        State-Engine

        if ($script:State -eq "WirelessActive") {

            if (-not (Test-Network)) {
                Log ("Cycle {0}: unstable network" -f $cycle)
            }

            foreach ($s in @("dns_fail.ps1","download.ps1","iperf.ps1")) {
                if (Test-Path $s) {
                    try { & ".\$s" } catch {}
                }
            }
        }
        else {
            Log ("Cycle {0}: state={1}" -f $cycle, $script:State)
        }

        Start-Sleep (Get-Random -Min 3 -Max 10)
        $cycle++
    }
    catch {
        Log "FATAL ERROR → reset to Init"
        Log $_.Exception.Message
        $script:State = "Init"
        $script:wifiFailCount = 0
        Start-Sleep 2
    }
}