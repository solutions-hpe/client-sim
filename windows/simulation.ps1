# -------------------------
# Simulation Script (Auto Re-Detect + Wi-Fi Recovery)
# -------------------------

$version = "0.97"
$logPath = "C:\Scripts\sim.log"
$maxLogSize = 10MB

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
        $output = netsh wlan show interfaces
        return ($output -match "State\s*:\s*connected")
    } catch {
        return $false
    }
}

# -------------------------
# ADAPTER DETECTION
# -------------------------

$script:wladapter = $null
$script:eadapter = $null

function Detect-Adapters {

    $oldWifi = $script:wladapter

    $script:wladapter = Get-NetAdapter |
        Where-Object { $_.Name -match "wireless|wlan|wi-fi" } |
        Select-Object -First 1 -ExpandProperty Name

    $script:eadapter = Get-NetAdapter |
        Where-Object { $_.Name -match "ethernet|eth" } |
        Select-Object -First 1 -ExpandProperty Name

    if ($script:wladapter -and -not $oldWifi) {
        Log ("Wi-Fi adapter detected: {0}" -f $script:wladapter)
        return "wifi_added"
    }

    if (-not $script:wladapter -and $oldWifi) {
        Log "Wi-Fi adapter lost"
        return "wifi_removed"
    }

    return "no_change"
}

# -------------------------
# WIFI CONNECT (RETRY + BACKOFF)
# -------------------------

function Connect-Wifi {

    if (-not $script:wladapter) {
        Log "Wi-Fi adapter missing — cannot connect"
        return $false
    }

    if (-not $ssid) {
        Log "SSID not defined"
        return $false
    }

    $maxAttempts = 4
    $baseDelay = 5

    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {

        Log ("Wi-Fi attempt {0} to connect to {1}" -f $attempt, $ssid)

        try {
            Disable-NetAdapter -Name $script:wladapter -Confirm:$false -ErrorAction SilentlyContinue
            Start-Sleep 2
            Enable-NetAdapter -Name $script:wladapter -ErrorAction SilentlyContinue
        } catch {}

        Start-Sleep 5

        try {
            netsh wlan connect name="$ssid" | Out-Null
        } catch {}

        Start-Sleep 6

        if (Test-WifiConnected) {
            Log "Wi-Fi connected successfully"
            return $true
        }

        $delay = [math]::Min($baseDelay * [math]::Pow(2, $attempt - 1), 60)
        Log ("Wi-Fi retry in {0} seconds" -f $delay)
        Start-Sleep $delay
    }

    Log "Wi-Fi connection failed after retries"
    return $false
}

# -------------------------
# PHY MODE CONTROL
# -------------------------

function Apply-WirelessMode {

    if (-not $script:wladapter) {
        Log "Wireless mode requested but no adapter — fallback to Ethernet"

        if ($script:eadapter) {
            Enable-NetAdapter -Name $script:eadapter -ErrorAction SilentlyContinue
        }

        return
    }

    Log "Switching to Wireless mode"

    if ($script:eadapter) {
        Disable-NetAdapter -Name $script:eadapter -Confirm:$false -ErrorAction SilentlyContinue
    }

    Connect-Wifi | Out-Null
}

function Apply-EthernetMode {

    Log "Switching to Ethernet mode"

    if ($script:eadapter) {
        Enable-NetAdapter -Name $script:eadapter -ErrorAction SilentlyContinue
    }

    if ($script:wladapter) {
        Disable-NetAdapter -Name $script:wladapter -Confirm:$false -ErrorAction SilentlyContinue
    }
}

# -------------------------
# NETWORK CONTROLLER
# -------------------------

function Network-Controller {

    if (Test-Network) {
        Log "Network OK"
        return $true
    }

    Log "Network FAILED"

    if ($sim_phy -eq "wireless") {
        Connect-Wifi | Out-Null
    }
    elseif ($sim_phy -eq "ethernet") {
        if ($script:eadapter) {
            Enable-NetAdapter -Name $script:eadapter -ErrorAction SilentlyContinue
        }
    }

    return $false
}

# -------------------------
# MAIN LOOP
# -------------------------

Log "------------------------------"
Log ("Simulation Script {0}" -f $version)
Log ("Start Time: {0}" -f (Get-Date))

# Initial detection
Detect-Adapters | Out-Null

# Initial mode apply
if ($sim_phy -eq "wireless") {
    Apply-WirelessMode
} else {
    Apply-EthernetMode
}

$cycle = 1

while ($true) {

    if (Test-Path "C:\Scripts\kill.flag") {
        Log "Kill switch detected. Exiting simulation loop."
        break
    }

    # 🔴 NEW: re-detect adapters every cycle
    $change = Detect-Adapters

    if ($sim_phy -eq "wireless" -and $change -eq "wifi_added") {
        Log "Wi-Fi adapter restored — switching back to wireless"
        Apply-WirelessMode
    }

    if ($sim_phy -eq "wireless" -and $change -eq "wifi_removed") {
        Log "Wi-Fi lost — falling back to Ethernet"
        Apply-EthernetMode
    }

    $network_ok = Network-Controller

    if (-not $network_ok) {
        Log ("Cycle {0}: network unstable" -f $cycle)
    }

    foreach ($script in @("dns_fail.ps1","download.ps1","iperf.ps1")) {
        if (Test-Path $script) {
            try {
                . .\$script
            } catch {
                Log ("Script {0} failed: {1}" -f $script, $_.Exception.Message)
            }
        }
    }

    Start-Sleep (Get-Random -Minimum 3 -Maximum 10)

    $cycle++
}

Log "Simulation stopped"