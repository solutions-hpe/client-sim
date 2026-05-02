# -------------------------
# Simulation Script (PHY FIX + Infinite + Log Rotation)
# -------------------------

$version = "0.94"
$logPath = "C:\Scripts\sim.log"
$maxLogSize = 10MB

# -------------------------
# LOGGING + ROTATION
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
# ADAPTER DETECTION
# -------------------------

$wladapter = Get-NetAdapter | Where-Object { $_.Name -match "wireless|wlan|wi-fi" } | Select-Object -First 1 -ExpandProperty Name
$eadapter  = Get-NetAdapter | Where-Object { $_.Name -match "ethernet|eth" } | Select-Object -First 1 -ExpandProperty Name

if ($wladapter) { Log ("Wi-Fi Adapter: {0}" -f $wladapter) }
if ($eadapter)  { Log ("Ethernet Adapter: {0}" -f $eadapter) }

# -------------------------
# WIFI CONNECT
# -------------------------

function Connect-Wifi {

    if (-not $wladapter) {
        Log "No Wi-Fi adapter found"
        return
    }

    try {
        Disable-NetAdapter -Name $wladapter -Confirm:$false -ErrorAction SilentlyContinue
        Start-Sleep 2
        Enable-NetAdapter -Name $wladapter -ErrorAction SilentlyContinue
    } catch {
        Log "Wi-Fi reset failed"
    }

    Start-Sleep 8

    if ($ssid) {
        try {
            netsh wlan connect name="$ssid" | Out-Null
            Log ("Attempting Wi-Fi connection to {0}" -f $ssid)
        } catch {
            Log "Wi-Fi connection command failed"
        }
    }

    Start-Sleep 10
}

# -------------------------
# PHY MODE CONTROL (FIXED)
# -------------------------

function Apply-PhyMode {

    if ($sim_phy -eq "wireless") {

        Log "Applying Wireless mode"

        if ($eadapter) {
            try {
                Disable-NetAdapter -Name $eadapter -Confirm:$false -ErrorAction SilentlyContinue
                Log "Ethernet disabled"
            } catch {}
        }

        Connect-Wifi
    }

    elseif ($sim_phy -eq "ethernet") {

        Log "Applying Ethernet mode"

        if ($eadapter) {
            Enable-NetAdapter -Name $eadapter -ErrorAction SilentlyContinue
        }

        if ($wladapter) {
            Disable-NetAdapter -Name $wladapter -Confirm:$false -ErrorAction SilentlyContinue
        }
    }
}

# -------------------------
# NETWORK CONTROLLER
# -------------------------

function Network-Controller {

    $ok = Test-Network

    if ($ok) {
        Log "Network OK"
        return $true
    }

    Log "Network FAILED"

    if ($sim_phy -eq "wireless") {
        Log "Attempting Wi-Fi recovery"
        Connect-Wifi
    }
    elseif ($sim_phy -eq "ethernet" -and $eadapter) {
        Enable-NetAdapter -Name $eadapter -ErrorAction SilentlyContinue
    }

    return $false
}

# -------------------------
# MAIN LOOP
# -------------------------

Log "------------------------------"
Log ("Simulation Script {0}" -f $version)
Log ("Start Time: {0}" -f (Get-Date))

Apply-PhyMode

$cycle = 1

while ($true) {

    if (Test-Path "C:\Scripts\kill.flag") {
        Log "Kill switch detected. Exiting simulation loop."
        break
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