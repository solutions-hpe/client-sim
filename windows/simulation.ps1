
# =========================================================
# Simulation Network State Engine (Stable / No Stall)
# =========================================================

$version = "7.2-stable"
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
# SAFE ADAPTER DETECTION (CACHED)
# -------------------------

function Detect-Adapters {

    if ($script:wladapter -and $script:eadapter) {
        return
    }

    Debug "Detecting adapters..."

    try {
        $adapters = Get-NetAdapter -ErrorAction SilentlyContinue

        $wifi = $adapters | Where-Object {
            $_.Name -match "Wi-Fi|WLAN|Wireless"
        } | Select-Object -First 1

        $eth = $adapters | Where-Object {
            $_.Name -match "Ethernet|eth"
        } | Select-Object -First 1

        $script:wladapter = if ($wifi) { $wifi.Name } else { $null }
        $script:eadapter  = if ($eth)  { $eth.Name }  else { $null }

        Debug "WiFi Adapter: $script:wladapter"
        Debug "Ethernet Adapter: $script:eadapter"
    }
    catch {
        Debug "Adapter detection failed"
    }
}

# -------------------------
# HEX CONVERSION (SAFE)
# -------------------------

function Convert-SSIDToHex {
    param ($ssid)

    if ([string]::IsNullOrWhiteSpace($ssid)) { return "" }

    return ($ssid.ToCharArray() | ForEach-Object {
        "{0:X2}" -f [int][char]$_
    }) -join ''
}

# -------------------------
# NETWORK TESTS
# -------------------------

function Test-Internet {
    Test-NetConnection 8.8.8.8 -InformationLevel Quiet -WarningAction SilentlyContinue
}

function Test-WifiConnected {
    (netsh wlan show interfaces) -match "State\s*:\s*connected"
}

# -------------------------
# PROFILE CREATION
# -------------------------

function Install-WifiProfile {

    $hex = Convert-SSIDToHex $script:ssid

    $xml = @"
<?xml version="1.0"?>
<WLANProfile xmlns="http://www.microsoft.com/networking/WLAN/profile/v1">
    <name>$script:ssid</name>
    <SSIDConfig>
        <SSID>
            <hex>$hex</hex>
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

    netsh wlan delete profile name="$script:ssid" | Out-Null
    netsh wlan add profile filename="$file" user=current | Out-Null

    Remove-Item $file -Force -ErrorAction SilentlyContinue
}

# -------------------------
# CONNECT LOGIC (LESS AGGRESSIVE)
# -------------------------

function Connect-Wifi {

    if (-not $script:wladapter) { return $false }

    for ($i = 1; $i -le 5; $i++) {

        Debug "Wi-Fi attempt $i"

        if ($i -eq 1) {
            Disable-NetAdapter -Name $script:wladapter -Confirm:$false -ErrorAction SilentlyContinue
            Start-Sleep 2
            Enable-NetAdapter -Name $script:wladapter -ErrorAction SilentlyContinue
            Start-Sleep 5
        }

        Install-WifiProfile

        netsh wlan connect name="$script:ssid" ssid="$script:ssid" | Out-Null

        Start-Sleep 6

        if (Test-WifiConnected -and Test-Internet) {
            Log "Wi-Fi connected"
            return $true
        }

        Start-Sleep (3 * $i)
    }

    return $false
}

# -------------------------
# STATES
# -------------------------

function Enter-WirelessState {

    Detect-Adapters

    if ($script:eadapter) {
        Debug "Disabling Ethernet"
        Disable-NetAdapter -Name $script:eadapter -Confirm:$false -ErrorAction SilentlyContinue
    }

    if (Connect-Wifi) {
        Log "STATE -> WirelessActive"
        $script:State = "WirelessActive"
    }
    else {
        Log "Wi-Fi failed -> Recovery"
        $script:State = "Recovery"
    }
}

function Enter-EthernetState {

    Detect-Adapters

    if ($script:eadapter) {
        Enable-NetAdapter -Name $script:eadapter -ErrorAction SilentlyContinue
    }

    if ($script:wladapter) {
        Disable-NetAdapter -Name $script:wladapter -Confirm:$false -ErrorAction SilentlyContinue
    }

    Log "STATE -> EthernetActive"
    $script:State = "EthernetActive"
}

function Enter-RecoveryState {

    Log "STATE -> Recovery"

    if ($script:eadapter) {
        Enable-NetAdapter -Name $script:eadapter -ErrorAction SilentlyContinue
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
            Log "STATE -> Init"

            if ($script:sim_phy -eq "wireless") {
                Enter-WirelessState
            } else {
                Enter-EthernetState
            }
        }

        "WirelessActive" {
            if (Test-Internet -and Test-WifiConnected) { return }

            $script:wifiFailCount++

            if ($script:wifiFailCount -le 5) {
                Log "Retry $script:wifiFailCount"
                Enter-WirelessState
            }
            else {
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

Log "Engine $version"

while ($true) {
    try {
        State-Engine
        Start-Sleep 5
    }
    catch {
        Log $_.Exception.Message
        Start-Sleep 5
    }
}