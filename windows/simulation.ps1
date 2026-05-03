
# =========================================================
# NETWORK SIMULATION CORE (FIXED STATE CONSISTENCY)
# =========================================================

$version = "1.1-fixed-state"

$script:State = "Init"
$script:cycle = 0
$script:failCount = 0
$script:maxRetries = 5

# -------------------------
# LOGGING
# -------------------------

$logPath = "C:\Scripts\sim.log"

function Log($msg) {
    "[{0}] {1}" -f (Get-Date -Format "HH:mm:ss"), $msg |
        Tee-Object -FilePath $logPath -Append
}

# -------------------------
# SIMULATION OF NETWORK QUALITY
# -------------------------

function Get-NetworkHealth {

    $roll = Get-Random -Minimum 1 -Maximum 100

    return ($roll -le 75)
}

# -------------------------
# WIFI EXECUTOR (REAL WORLD BUT SAFE)
# -------------------------

function Invoke-WifiConnect {

    param(
        [string]$ssid
    )

    try {
        Log "Attempting Wi-Fi connect to $ssid"

        # NOTE: we DO NOT assume success
        $job = Start-Job -ScriptBlock {
            param($s)
            netsh wlan connect name="$s" ssid="$s"
        } -ArgumentList $ssid

        if (Wait-Job $job -Timeout 8) {
            Receive-Job $job | Out-Null
            Remove-Job $job | Out-Null
            return $true
        }
        else {
            Stop-Job $job | Out-Null
            Remove-Job $job | Out-Null
            Log "Wi-Fi connect timeout"
            return $false
        }
    }
    catch {
        Log "Wi-Fi connect error: $($_.Exception.Message)"
        return $false
    }
}

# -------------------------
# STATE ENGINE
# -------------------------

function Enter-Init {

    Log "STATE -> INIT"

    $script:failCount = 0

    if ($script:sim_phy -eq "ethernet") {
        $script:State = "Ethernet"
    }
    else {
        $script:State = "WiFiConnect"
    }
}

function Enter-WiFiConnect {

    Log "STATE -> WiFiConnect"

    $ok = Invoke-WifiConnect -ssid $script:ssid

    if ($ok) {
        $script:State = "WirelessActive"
    }
    else {
        $script:State = "Recovery"
    }
}

function Enter-WirelessActive {

    $healthy = Get-NetworkHealth

    if ($healthy) {
        Log "Wireless OK"
    }
    else {
        $script:failCount++
        Log "Wireless FAIL #$script:failCount"

        if ($script:failCount -ge $script:maxRetries) {
            $script:State = "Recovery"
        }
        else {
            $script:State = "WiFiConnect"
        }
    }
}

function Enter-Ethernet {

    Log "Ethernet ACTIVE (simulated)"
}

function Enter-Recovery {

    Log "STATE -> RECOVERY"
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

        "WiFiConnect" {
            Enter-WiFiConnect
        }

        "WirelessActive" {
            Enter-WirelessActive
        }

        "Ethernet" {
            Enter-Ethernet
        }

        "Recovery" {
            Enter-Recovery
        }
    }
}

# -------------------------
# MAIN LOOP
# -------------------------

Log "ENGINE STARTED v$version"

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