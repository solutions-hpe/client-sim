
# =========================================================
# Simulation Network Engine (DEEP DEBUG / HANG TRACE)
# =========================================================

$version = "7.4-debug-trace"
$logPath = "C:\Scripts\sim.log"

$script:sim_phy = if ($sim_phy) { $sim_phy } else { "wireless" }

$script:ssid   = $ssid
$script:ssidpw = $ssidpw

$script:State = "Init"
$script:wifiFailCount = 0
$script:debug = $true

# -------------------------
# LOGGING
# -------------------------

function Log($msg) {
    $line = "[{0}] {1}" -f (Get-Date -Format "HH:mm:ss"), $msg
    $line | Tee-Object -FilePath $logPath -Append
}

function Debug($msg) {
    if ($script:debug) { Log "[DEBUG] $msg" }
}

# -------------------------
# TIMING WRAPPER (CRITICAL)
# -------------------------

function Invoke-Traced {
    param(
        [string]$Label,
        [scriptblock]$Action
    )

    Debug "START: $Label"
    $t0 = Get-Date

    try {
        & $Action
    }
    catch {
        Log "ERROR in $Label : $($_.Exception.Message)"
    }

    $t1 = Get-Date
    Debug "END: $Label (took $([math]::Round(($t1-$t0).TotalSeconds,2))s)"
}

# -------------------------
# RAW ADAPTER DUMP
# -------------------------

function Dump-Interfaces {

    Debug "Dumping interfaces (netsh)"

    $out = netsh interface show interface 2>&1

    foreach ($line in $out) {
        Debug "IFACE: $line"
    }
}

# -------------------------
# SAFE ADAPTER DETECTION
# -------------------------

function Detect-Adapters {

    Dump-Interfaces

    $out = netsh interface show interface

    $wifiLine = $out | Where-Object { $_ -match "Wi-Fi|Wireless|WLAN" } | Select-Object -First 1
    $ethLine  = $out | Where-Object { $_ -match "Ethernet" } | Select-Object -First 1

    if ($wifiLine) {
        $script:wladapter = ($wifiLine -split '\s+')[-1]
    }

    if ($ethLine) {
        $script:eadapter = ($ethLine -split '\s+')[-1]
    }

    Debug "WiFi Adapter parsed: $script:wladapter"
    Debug "Ethernet Adapter parsed: $script:eadapter"
}

# -------------------------
# NETWORK CHECKS
# -------------------------

function Test-Internet {
    Test-NetConnection 8.8.8.8 -InformationLevel Quiet -WarningAction SilentlyContinue
}

function Test-WifiConnected {
    (netsh wlan show interfaces) -match "State\s*:\s*connected"
}

# -------------------------
# SAFE NETSH EXECUTION (TIMEOUT GUARD)
# -------------------------

function Run-Netsh {
    param(
        [string]$cmd,
        [int]$timeoutSec = 5
    )

    $job = Start-Job -ScriptBlock {
        param($c)
        netsh $c
    } -ArgumentList $cmd

    if (Wait-Job $job -Timeout $timeoutSec) {
        Receive-Job $job
    }
    else {
        Log "TIMEOUT: netsh $cmd"
        Stop-Job $job | Out-Null
    }

    Remove-Job $job -Force | Out-Null
}

# -------------------------
# WIFI PROFILE
# -------------------------

function Install-WifiProfile {

    $xml = @"
<?xml version="1.0"?>
<WLANProfile xmlns="http://www.microsoft.com/networking/WLAN/profile/v1">
    <name>$script:ssid</name>
    <SSIDConfig>
        <SSID>
            <name>$script:ssid</name>
        </SSID>
    </SSIDConfig>
    <connectionType>ESS</connectionType>
    <connectionMode>auto</connectionMode>
    <MSM>
        <security>
            <authEncryption>
                <authentication>WPA2PSK</authentication>
                <encryption>AES</encryption>
                <useOneX>false</useOneX>
                <transitionMode xmlns="http://www.microsoft.com/networking/WLAN/profile/v4">true</transitionMode>
            </authEncryption>
            <sharedKey>
                <keyType>passPhrase</keyType>
                <protected>false</protected>
                <keyMaterial>$script:ssidpw</keyMaterial>
            </sharedKey>
        </security>
    </MSM>
</WLANProfile>
"@

    $file = "$env:TEMP\wifi.xml"

    [System.IO.File]::WriteAllText($file, $xml, (New-Object System.Text.UTF8Encoding($false)))

    Invoke-Traced "Delete Profile" { netsh wlan delete profile name="$script:ssid" | Out-Null }
    Invoke-Traced "Add Profile"    { netsh wlan add profile filename="$file" user=current }

    Remove-Item $file -Force -ErrorAction SilentlyContinue
}

# -------------------------
# CONNECT
# -------------------------

function Connect-Wifi {

    for ($i = 1; $i -le 5; $i++) {

        Log "CONNECT ATTEMPT $i"

        Invoke-Traced "Connect WiFi" {
            netsh wlan connect name="$script:ssid" ssid="$script:ssid"
        }

        Start-Sleep 5

        if (Test-WifiConnected) {
            Log "Wi-Fi connected"
            return $true
        }

        Start-Sleep (2 * $i)
    }

    return $false
}

# -------------------------
# STATE HANDLERS
# -------------------------

function Enter-WirelessState {

    Invoke-Traced "Detect Adapters" { Detect-Adapters }

    if ($script:eadapter) {
        Invoke-Traced "Disable Ethernet" {
            netsh interface set interface name="$script:eadapter" admin=disabled
        }
    }

    if (Connect-Wifi) {
        $script:State = "WirelessActive"
    }
    else {
        $script:State = "Recovery"
    }
}

function Enter-RecoveryState {

    Log "RECOVERY"

    if ($script:eadapter) {
        Invoke-Traced "Enable Ethernet" {
            netsh interface set interface name="$script:eadapter" admin=enabled
        }
    }

    Start-Sleep 5
    $script:State = "Init"
}

# -------------------------
# ENGINE
# -------------------------

function State-Engine {

    switch ($script:State) {

        "Init" {
            Log "STATE INIT"

            if ($script:sim_phy -eq "wireless") {
                Enter-WirelessState
            }
        }

        "WirelessActive" {
            if (-not (Test-Internet)) {
                Log "Lost internet"
                $script:State = "Recovery"
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

Log "ENGINE $version"

while ($true) {
    try {
        State-Engine
        Start-Sleep 5
    }
    catch {
        Log $_.Exception.Message
    }
}