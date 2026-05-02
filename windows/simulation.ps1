# -------------------------
# Simulation Script (Stable Production Fix)
# -------------------------

$version = "1.01"
$logPath = "C:\Scripts\sim.log"
$maxLogSize = 10MB

# -------------------------
# SAFE DEFAULTS (CRITICAL FIX)
# -------------------------

$script:sim_phy = if ($sim_phy) { $sim_phy } else { "wireless" }
$script:ssid    = if ($ssid) { $ssid } else { "" }

$script:RecoveryMode = $false

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
# WIFI STATUS CHECK
# -------------------------

function Test-WifiConnected {
    try {
        return (netsh wlan show interfaces) -match "State\s*:\s*connected"
    } catch {
        return $false
    }
}

# -------------------------
# ADAPTER DETECTION (RE-RUN SAFE)
# -------------------------

function Detect-Adapters {

    $script:wladapter = Get-NetAdapter |
        Where-Object { $_.Name -match "wireless|wlan|wi-fi" } |
        Select-Object -First 1 -ExpandProperty Name

    $script:eadapter = Get-NetAdapter |
        Where-Object { $_.Name -match "ethernet|eth" } |
        Select-Object -First 1 -ExpandProperty Name
}

# -------------------------
# WIFI CONNECT (RETRY + BACKOFF)
# -------------------------

function Connect-Wifi {

    if (-not $script:wladapter -or -not $script:ssid) {
        return $false
    }

    for ($i = 1; $i -le 4; $i++) {

        Log ("Wi-Fi attempt {0} → {1}" -f $i, $script:ssid)

        try {
            Disable-NetAdapter -Name $script:wladapter -Confirm:$false -ErrorAction SilentlyContinue
            Start-Sleep 2
            Enable-NetAdapter -Name $script:wladapter -ErrorAction SilentlyContinue
        } catch {}

        Start-Sleep 5

        try {
            netsh wlan connect name="$script:ssid" | Out-Null
        } catch {}

        Start-Sleep 6

        if (Test-WifiConnected) {
            Log "Wi-Fi connected successfully"
            return $true
        }

        $delay = [math]::Min(5 * [math]::Pow(2, $i - 1), 60)
        Log ("Retrying Wi-Fi in {0}s" -f $delay)
        Start-Sleep $delay
    }

    Log "Wi-Fi failed after retries"
    return $false
}

# -------------------------
# APPLY WIRELESS MODE
# -------------------------

function Apply-WirelessMode {

    Detect-Adapters

    if (-not $script:wladapter) {

        Log "No Wi-Fi adapter → fallback to Ethernet"

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

        Log "Wi-Fi failed → enabling Ethernet + recovery mode"

        if ($script:eadapter) {
            Enable-NetAdapter -Name $script:eadapter -ErrorAction SilentlyContinue
        }

        if (Test-Path ".\update.ps1") {
            Log "Running update.ps1"
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
# INITIALIZATION
# -------------------------

Log "------------------------------"
Log ("Simulation Script {0}" -f $version)
Log ("Start Time: {0}" -f (Get-Date))

Detect-Adapters
Apply-WirelessMode

# -------------------------
# MAIN LOOP (INFINITE)
# -------------------------

$cycle = 1

while ($true) {

    if (Test-Path "C:\Scripts\kill.flag") {
        Log "Kill switch detected"
        break
    }

    Detect-Adapters

    $network_ok = Network-Controller

    # Recovery mode = NO simulation allowed
    if ($script:RecoveryMode) {

        Log ("Cycle {0}: recovery mode active (skipping simulation)" -f $cycle)

        Start-Sleep 15
        $cycle++
        continue
    }

    if (-not $network_ok) {
        Log ("Cycle {0}: network unstable" -f $cycle)
    }

    # Simulation workloads ONLY when healthy
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