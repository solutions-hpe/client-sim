# =========================================================
# Simulation Network State Engine (WPA2 Transition Safe)
# =========================================================

$version = "7.0-transition-safe"
$logPath = "C:\Scripts\sim.log"
$maxLogSize = 10MB

# -------------------------
# CONFIG
# -------------------------

$script:sim_phy = if ($sim_phy) { $sim_phy } else { "wireless" }

$script:ssid   = $ssid
$script:ssidpw = $ssidpw

$script:State = "Init"
$script:wifiFailCount = 0
$script:debug = $true

# -------------------------
# LOGGING
# -------------------------

function Rotate-LogIfNeeded {
    if (Test-Path $logPath) {
        try {
            if ((Get-Item $logPath).Length -ge $maxLogSize) {
                Get-Content $logPath -Tail 5000 | Set-Content $logPath
            }
        } catch {}
    }
}

function Log($msg) {
    Rotate-LogIfNeeded
    $line = "[{0}] {1}" -f (Get-Date -Format "HH:mm:ss"), $msg
    $line | Tee-Object -FilePath $logPath -Append
}

function Debug($msg) {
    if ($script:debug) { Log "[DEBUG] $msg" }
}

# -------------------------
# HELPERS
# -------------------------

function Convert-SSIDToHex {
    param ($ssid)
    ($ssid.ToCharArray() | ForEach-Object {
        [System.String]::Format("{0:X2}", [int][char]$_)
    }) -join ''
}

# -------------------------
# NETWORK CHECKS
# -------------------------

function Test-Internet {
    try {
        Test-NetConnection 8.8.8.8 -InformationLevel Quiet -WarningAction SilentlyContinue
    } catch { $false }
}

function Test-WifiConnected {
    try {
        (netsh wlan show interfaces) -match "State\s*:\s*connected"
    } catch { $false }
}

# -------------------------
# ADAPTER DETECTION
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

    Debug "WiFi Adapter: $script:wladapter"
    Debug "Ethernet Adapter: $script:eadapter"
}

# -------------------------
# WIFI PROFILE (FIXED)
# -------------------------

function Create-WifiProfileXml {

    $hex = Convert-SSIDToHex $script:ssid

@"
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

    <MacRandomization xmlns="http://www.microsoft.com/networking/WLAN/profile/v3">
        <enableRandomization>false</enableRandomization>
    </MacRandomization>
</WLANProfile>
"@
}

function Install-WifiProfile {

    $file = Join-Path $env:TEMP "wifi_profile.xml"

    Debug "Creating Wi-Fi profile XML"

    $xml = Create-WifiProfileXml

    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($file, $xml, $utf8)

    Debug "Deleting existing profile"
    netsh wlan delete profile name="$script:ssid" | Out-Null

    Debug "Adding new profile"
    $result = netsh wlan add profile filename="$file" user=current 2>&1
    Debug ($result -join " ")

    Remove-Item $file -Force -ErrorAction SilentlyContinue
}

# -------------------------
# WIFI CONNECT
# -------------------------

function Connect-Wifi {

    if (-not $script:wladapter) {
        Debug "No Wi-Fi adapter"
        return $false
    }

    for ($i = 1; $i -le 5; $i++) {

        Debug "Wi-Fi attempt $i"

        Disable-NetAdapter -Name $script:wladapter -Confirm:$false -ErrorAction SilentlyContinue
        Start-Sleep 2
        Enable-NetAdapter -Name $script:wladapter -ErrorAction SilentlyContinue

        Start-Sleep 5

        Install-WifiProfile

        netsh wlan connect name="$script:ssid" ssid="$script:ssid" | Out-Null

        Start-Sleep 6

        if (Test-WifiConnected -and Test-Internet) {
            Log "Wi-Fi connected"
            return $true
        }

        Debug "Attempt $i failed"
        Start-Sleep (5 * $i)
    }

    return $false
}

# -------------------------
# STATE HANDLERS
# -------------------------

function Enter-WirelessState {

    Detect-Adapters

    if ($script:eadapter) {
        Debug "Disabling Ethernet"
        Disable-NetAdapter -Name $script:eadapter -Confirm:$false -ErrorAction SilentlyContinue
    }

    if (Connect-Wifi) {
        Log "STATE → WirelessActive"
        $script:State = "WirelessActive"
        $script:wifiFailCount = 0
    }
    else {
        Log "Wi-Fi failed → Recovery"
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

    Log "STATE → EthernetActive"
    $script:State = "EthernetActive"
}

function Enter-RecoveryState {

    Log "STATE → Recovery"

    if ($script:eadapter) {
        Enable-NetAdapter -Name $script:eadapter -ErrorAction SilentlyContinue
    }

    Start-Sleep 5

    $script:State = "Init"
}

# -------------------------
# STATE ENGINE
# -------------------------

function State-Engine {

    switch ($script:State) {

        "Init" {
            Log "STATE → Init"

            if ($script:sim_phy -eq "wireless") {
                Enter-WirelessState
            }
            else {
                Enter-EthernetState
            }
        }

        "WirelessActive" {

            if (Test-Internet -and Test-WifiConnected) {
                return
            }

            $script:wifiFailCount++

            if ($script:wifiFailCount -le 5) {

                Log "Wireless retry $script:wifiFailCount"
                Start-Sleep (2 * $script:wifiFailCount)

                Enter-WirelessState
            }
            else {
                Log "Wireless failed → Recovery"
                $script:State = "Recovery"
            }
        }

        "EthernetActive" {
            return
        }

        "Recovery" {
            Enter-RecoveryState
        }
    }
}

# -------------------------
# MAIN LOOP
# -------------------------

Log "================================"
Log ("Simulation Engine {0}" -f $version)
Log ("Start: {0}" -f (Get-Date))

while ($true) {

    if (Test-Path "C:\Scripts\kill.flag") {
        Log "Kill switch activated"
        break
    }

    try {
        State-Engine
    }
    catch {
        Log ("ERROR: {0}" -f $_.Exception.Message)
        $script:State = "Recovery"
    }

    Start-Sleep (Get-Random -Minimum 3 -Maximum 10)
}

Log "Simulation stopped"