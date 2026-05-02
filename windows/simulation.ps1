# -------------------------
# Simulation Script (Strict Wireless Behavior)
# -------------------------

$version = "0.98"
$logPath = "C:\Scripts\sim.log"
$maxLogSize = 10MB
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
# WIFI STATUS
# -------------------------

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
        Where-Object { $_.Name -match "wireless|wlan|wi-fi" } |
        Select-Object -First 1 -ExpandProperty Name

    $script:eadapter = Get-NetAdapter |
        Where-Object { $_.Name -match "ethernet|eth" } |
        Select-Object -First 1 -ExpandProperty Name
}

# -------------------------
# WIFI CONNECT
# -------------------------

function Connect-Wifi {

    if (-not $script:wladapter -or -not $ssid) {
        return $false
    }

    for ($i = 1; $i -le 4; $i++) {

        Log ("Wi-Fi attempt {0} to {1}" -f $i, $ssid)

        Disable-NetAdapter -Name $script:wladapter -Confirm:$false -ErrorAction SilentlyContinue
        Start-Sleep 2
        Enable-NetAdapter -Name $script:wladapter -ErrorAction SilentlyContinue

        Start-Sleep 5

        netsh wlan connect name="$ssid" | Out-Null
        Start-Sleep 6

        if (Test-WifiConnected) {
            Log "Wi-Fi connected"
            return $true
        }

        $delay = [math]::Min(5 * [math]::Pow(2, $i - 1), 60)
        Log ("Retrying in {0}s" -f $delay)
        Start-Sleep $delay
    }

    Log "Wi-Fi failed after retries"
    return $false
}

# -------------------------
# APPLY WIRELESS MODE
# -------------------------

function Apply-WirelessMode {

    if (-not $script:wladapter) {
        Log "No Wi-Fi adapter → fallback to Ethernet"
        Enable-NetAdapter -Name $script:eadapter -ErrorAction SilentlyContinue
        $script:RecoveryMode = $true
        return
    }

    Disable-NetAdapter -Name $script:eadapter -Confirm:$false -ErrorAction SilentlyContinue

    if (-not (Connect-Wifi)) {

        Log "Wi-Fi unavailable → enabling Ethernet + recovery mode"

        Enable-NetAdapter -Name $script:eadapter -ErrorAction SilentlyContinue

        if (Test-Path ".\update.ps1") {
            Log "Running update.ps1"
            try { . .\update.ps1 } catch {}
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
            Log "Network restored — exiting recovery mode"
        }

        $script:RecoveryMode = $false
        return $true
    }

    Log "Network FAILED"

    if ($sim_phy -eq "wireless") {
        Apply-WirelessMode
    }

    return $false
}

# -------------------------
# MAIN LOOP
# -------------------------

Log "------------------------------"
Log ("Simulation Script {0}" -f $version)

Detect-Adapters
Apply-WirelessMode

$cycle = 1

while ($true) {

    if (Test-Path "C:\Scripts\kill.flag") {
        Log "Kill switch detected"
        break
    }

    Detect-Adapters

    $network_ok = Network-Controller

    if ($script:RecoveryMode) {

        Log ("Cycle {0}: recovery mode active — skipping simulations" -f $cycle)

        Start-Sleep 15
        $cycle++
        continue
    }

    if (-not $network_ok) {
        Log ("Cycle {0}: network unstable" -f $cycle)
    }

    # 🔴 Only runs when NOT in recovery mode
    foreach ($script in @("dns_fail.ps1","download.ps1","iperf.ps1")) {
        if (Test-Path $script) {
            try { . .\$script } catch {}
        }
    }

    Start-Sleep (Get-Random -Minimum 3 -Maximum 10)

    $cycle++
}

Log "Simulation stopped"