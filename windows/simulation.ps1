
# =========================================================
# NETWORK SIMULATION CORE ENGINE (CLEAN RESTART)
# =========================================================

$version = "1.0-core"

# -------------------------
# CONFIG
# -------------------------

$script:sim_phy = if ($sim_phy) { $sim_phy } else { "wireless" }

$script:State = "Init"
$script:cycle = 0

$script:failCount = 0
$script:maxRetries = 5

# -------------------------
# LOGGING
# -------------------------

$logPath = "C:\Scripts\sim.log"

function Log($msg) {
    $line = "[{0}] {1}" -f (Get-Date -Format "HH:mm:ss"), $msg
    $line | Tee-Object -FilePath $logPath -Append
}

function Debug($msg) {
    Log "[DEBUG] $msg"
}

# -------------------------
# SIMULATION MODEL
# -------------------------
# This replaces ALL real networking

function Get-NetworkSnapshot {

    if ($script:sim_phy -eq "ethernet") {
        return @{
            Link = "Ethernet"
            Up   = $true
            Latency = 1
        }
    }

    # wireless simulation behavior
    $roll = Get-Random -Minimum 1 -Maximum 100

    if ($roll -le 75) {
        return @{
            Link = "WiFi"
            Up   = $true
            Latency = Get-Random -Minimum 10 -Maximum 60
        }
    }
    elseif ($roll -le 90) {
        return @{
            Link = "WiFi"
            Up   = $false
            Latency = 0
        }
    }
    else {
        return @{
            Link = "WiFi"
            Up   = $false
            Latency = 0
        }
    }
}

function Test-SimulatedInternet {
    $net = Get-NetworkSnapshot

    Debug "LINK=$($net.Link) UP=$($net.Up) LATENCY=$($net.Latency)ms"

    return $net.Up
}

# -------------------------
# STATE MACHINE
# -------------------------

function Enter-Init {

    Log "STATE -> INIT"

    $script:cycle = 0
    $script:failCount = 0

    if ($script:sim_phy -eq "wireless") {
        $script:State = "WirelessActive"
    }
    else {
        $script:State = "EthernetActive"
    }
}

function Enter-Wireless {

    Log "STATE -> WirelessActive"

    if (Test-SimulatedInternet) {
        $script:State = "WirelessOK"
        $script:failCount = 0
    }
    else {
        $script:State = "WirelessFail"
    }
}

function Enter-Ethernet {

    Log "STATE -> EthernetActive"

    $script:State = "EthernetOK"
}

function Enter-Recovery {

    Log "STATE -> Recovery"

    Start-Sleep 1
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

        "WirelessOK" {

            if (-not (Test-SimulatedInternet)) {

                $script:failCount++

                Log "WiFi failure #$script:failCount"

                if ($script:failCount -ge $script:maxRetries) {
                    $script:State = "Recovery"
                }
                else {
                    Start-Sleep ($script:failCount * 2)
                    $script:State = "WirelessActive"
                }
            }
        }

        "WirelessFail" {
            $script:State = "Recovery"
        }

        "EthernetOK" {
            # stable state
        }

        "Recovery" {
            Enter-Recovery
        }
    }
}

# -------------------------
# MAIN LOOP
# -------------------------

Log "===================================="
Log "NETWORK SIMULATION CORE STARTED"
Log ("Version: {0}" -f $version)
Log "===================================="

while ($true) {

    try {
        State-Engine
        Start-Sleep (Get-Random -Minimum 1 -Maximum 3)
    }
    catch {
        Log "ERROR: $($_.Exception.Message)"
        $script:State = "Recovery"
    }
}