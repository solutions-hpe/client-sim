
# =========================================================
# TRUE NETWORK SIMULATION ENGINE (NO OS TOGGLE)
# =========================================================

$version = "8.0-simulation-only"

$script:ssid   = $ssid
$script:ssidpw = $ssidpw
$script:sim_phy = if ($sim_phy) { $sim_phy } else { "wireless" }

# -------------------------
# SIMULATION STATE
# -------------------------

$script:State = "Init"
$script:cycle = 0
$script:wifiFailCount = 0

# -------------------------
# LOGGING
# -------------------------

function Log($msg) {
    "[{0}] {1}" -f (Get-Date -Format "HH:mm:ss"), $msg |
        Tee-Object -FilePath "C:\Scripts\sim.log" -Append
}

function Debug($msg) {
    Log "[DEBUG] $msg"
}

# -------------------------
# "VIRTUAL NETWORK MODEL"
# -------------------------

function Get-VirtualNetworkState {

    # This simulates real-world randomness instead of hardware control

    if ($script:sim_phy -eq "ethernet") {
        return @{
            Link     = "Ethernet"
            Connected = $true
            Latency   = 1
        }
    }

    # wireless simulation model
    $rand = Get-Random -Minimum 1 -Maximum 100

    if ($rand -lt 70) {
        return @{
            Link      = "WiFi"
            Connected = $true
            Latency   = (Get-Random -Minimum 10 -Maximum 80)
        }
    }
    elseif ($rand -lt 85) {
        return @{
            Link      = "WiFi"
            Connected = $false
            Latency   = 0
        }
    }
    else {
        return @{
            Link      = "WiFi"
            Connected = $false
            Latency   = 0
        }
    }
}

# -------------------------
# SIMULATED CONNECT LOGIC
# -------------------------

function Test-SimulatedInternet {

    $state = Get-VirtualNetworkState

    Debug "SIM LINK: $($state.Link) CONNECTED: $($state.Connected) LATENCY: $($state.Latency)ms"

    return $state.Connected
}

# -------------------------
# SIMULATED WIFI CONNECT
# -------------------------

function Simulate-WifiConnect {

    for ($i = 1; $i -le 5; $i++) {

        Debug "CONNECT ATTEMPT $i to SSID $script:ssid"

        Start-Sleep (Get-Random -Minimum 1 -Maximum 3)

        if (Test-SimulatedInternet) {
            Log "SIMULATION: Wi-Fi CONNECTED"
            return $true
        }

        $backoff = 2 * $i
        Debug "Retry backoff $backoff sec"
        Start-Sleep $backoff
    }

    return $false
}

# -------------------------
# STATE HANDLERS
# -------------------------

function Enter-Init {

    Log "STATE -> INIT"

    $script:cycle = 0
    $script:wifiFailCount = 0

    if ($script:sim_phy -eq "wireless") {
        $script:State = "WirelessActive"
    }
    else {
        $script:State = "EthernetActive"
    }
}

function Enter-Wireless {

    Log "STATE -> WirelessActive"

    if (Simulate-WifiConnect) {
        $script:State = "WirelessActive_OK"
    }
    else {
        $script:State = "Recovery"
    }
}

function Enter-Ethernet {

    Log "STATE -> EthernetActive (SIM)"

    $script:State = "EthernetActive_OK"
}

function Enter-Recovery {

    Log "STATE -> Recovery"

    Start-Sleep 2
    $script:State = "Init"
}

# -------------------------
# ENGINE
# -------------------------

function State-Engine {

    $script:cycle++

    switch ($script:State) {

        "Init" {
            Enter-Init
        }

        "WirelessActive" {
            Enter-Wireless
        }

        "EthernetActive" {
            Enter-Ethernet
        }

        "WirelessActive_OK" {

            if (-not (Test-SimulatedInternet)) {

                $script:wifiFailCount++

                Log "WiFi failure #$script:wifiFailCount"

                if ($script:wifiFailCount -ge 5) {
                    $script:State = "Recovery"
                }
                else {
                    Start-Sleep (2 * $script:wifiFailCount)
                }
            }
        }

        "EthernetActive_OK" {
            # stable state, do nothing
        }

        "Recovery" {
            Enter-Recovery
        }
    }
}

# -------------------------
# MAIN LOOP
# -------------------------

Log "================================"
Log "TRUE SIMULATION ENGINE STARTED"
Log ("Version: {0}" -f $version)

while ($true) {

    try {
        State-Engine
        Start-Sleep (Get-Random -Minimum 2 -Maximum 5)
    }
    catch {
        Log "ERROR: $($_.Exception.Message)"
        $script:State = "Recovery"
    }
}