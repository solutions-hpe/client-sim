# -------------------------
# Simulation Script (Debug + Self-Diagnosing Fix)
# -------------------------

$version = "1.02-debug"
$logPath = "C:\Scripts\sim.log"
$maxLogSize = 10MB

$script:RecoveryMode = $false

# -------------------------
# SAFE CONFIG BOOTSTRAP
# -------------------------

$script:sim_phy = if ($sim_phy) { $sim_phy } else { "wireless" }
$script:ssid    = if ($ssid) { $ssid } else { "" }

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
# DEBUG STATE SNAPSHOT
# -------------------------

function Debug-State {

    Log "----- DEBUG STATE -----"
    Log ("PHY MODE     : {0}" -f $script:sim_phy)
    Log ("SSID         : {0}" -f ($(if ($script:ssid) { $script:ssid } else { "NOT SET" })))
    Log ("RecoveryMode : {0}" -f $script:RecoveryMode)
    Log ("WiFi Adapter : {0}" -f ($(if ($script:wladapter) { $script:wladapter } else { "NOT FOUND" })))
    Log ("Ethernet     : {0}" -f ($(if ($script:eadapter) { $script:eadapter } else { "NOT FOUND" })))
}

# -------------------------
# NETWORK TEST
# -------------------------

function Test-Network {
    try {
        return Test-NetConnection -ComputerName "8.8.8.8" -InformationLevel Quiet -WarningAction SilentlyContinue
    } catch {
        return $false
    }
}

# -------------------------
# WIFI CHECK
# -------------------------

function Test-WifiConnected {
    try {
        return (netsh wlan show interfaces) -match "State\s*:\s*connected"
    } catch {
        return $false
    }
}

# -------------------------
# ADAPTER DETECTION (IMPROVED)
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
# WIFI CONNECT (WITH FULL DEBUG)
# -------------------------

function Connect-Wifi {

    Log ">>> Entering Wi-Fi connect routine"

    if (-not $script:wladapter) {
        Log "❌ Wi-Fi adapter missing"
        Log "💡 Suggestion: check device manager or USB Wi-Fi dongle"
        return $false
    }

    if (-not $script:ssid -or $script:ssid -eq "") {
        Log "❌ SSID not configured"
        Log "💡 Suggestion: verify simulation.conf contains SSID for this node"
        return $false
    }

    for ($i = 1; $i -le 4; $i++) {

        Log ("Wi-Fi attempt {0} → SSID: {1}" -f $i, $script:ssid)

        try {
            Disable-NetAdapter -Name $script:wladapter -Confirm:$false -ErrorAction SilentlyContinue
            Start-Sleep 2
            Enable-NetAdapter -Name $script:wladapter -ErrorAction SilentlyContinue
        } catch {
            Log "⚠ Adapter reset failed"
        }

        Start-Sleep 5

        try {
            netsh wlan connect name="$script:ssid" | Out-Null
        } catch {
            Log "⚠ netsh connect command failed"
        }

        Start-Sleep 6

        if (Test-WifiConnected) {
            Log "✔ Wi-Fi connected successfully"
            return $true
        }

        $delay = [math]::Min(5 * [math]::Pow(2, $i - 1), 60)
        Log ("Wi-Fi not connected — retrying in {0}s" -f $delay)
        Start-Sleep $delay
    }

    Log "❌ Wi-Fi failed after retries"
    Log "💡 Suggestion: verify SSID availability and adapter driver state"

    return $false
}

# -------------------------
# APPLY WIRELESS MODE
# -------------------------

function Apply-WirelessMode {

    Detect-Adapters
    Debug-State

    if (-not $script:wladapter) {

        Log "⚠ No Wi-Fi adapter → switching to Ethernet fallback"

        if ($script:eadapter) {
            Enable-NetAdapter -Name $script:eadapter -ErrorAction SilentlyContinue
        }

        $script:RecoveryMode = $true
        return
    }

    if ($script:eadapter) {
        Disable-NetAdapter -Name $script:eadapter -Confirm:$false -ErrorAction SilentlyContinue
    }

    $wifiOK = Connect-Wifi

    if (-not $wifiOK) {

        Log "⚠ Wi-Fi failed → enabling Ethernet + recovery mode"

        if ($script:eadapter) {
            Enable-NetAdapter -Name $script:eadapter -ErrorAction SilentlyContinue
        }

        if (Test-Path ".\update.ps1") {
            Log "Running update.ps1 (recovery update)"
            try { & ".\update.ps1" } catch { Log "update.ps1 failed" }
        }

        $script:RecoveryMode = $true
    }
    else {
        $script:RecoveryMode = $false
    }
}

# -------------------------
# NETWORK CONTROLLER
# -------------------------

function Network-Controller {

    if (Test-Network) {

        if ($script:RecoveryMode) {
            Log "Network restored → exiting recovery mode"
        }

        $script:RecoveryMode = $false
        return $true
    }

    Log "Network FAILED"

    if ($script:sim_phy -eq "wireless") {
        Apply-WirelessMode
    }

    return $false
}

# -------------------------
# MAIN LOOP
# -------------------------

Log "=============================="
Log ("Simulation Script {0}" -f $version)
Log ("Start Time: {0}" -f (Get-Date))

$cycle = 1

while ($true) {

    if (Test-Path "C:\Scripts\kill.flag") {
        Log "Kill switch detected"
        break
    }

    Detect-Adapters

    Debug-State   # 🔥 live visibility every cycle

    $network_ok = Network-Controller

    if ($script:RecoveryMode) {

        Log ("Cycle {0}: RECOVERY MODE (simulation paused)" -f $cycle)

        Start-Sleep 15
        $cycle++
        continue
    }

    if (-not $network_ok) {
        Log ("Cycle {0}: network unstable" -f $cycle)
    }

    foreach ($scriptName in @("dns_fail.ps1","download.ps1","iperf.ps1")) {

        if (Test-Path $scriptName) {
            try {
                & ".\$scriptName"
            } catch {
                Log ("Script failed: {0}" -f $scriptName)
            }
        }
    }

    Start-Sleep (Get-Random -Minimum 3 -Maximum 10)

    $cycle++
}

Log "Simulation stopped"