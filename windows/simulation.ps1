# =========================================================
# Simulation Network State Engine (NULL SAFE)
# =========================================================

$version = "7.1-null-safe"
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

function Log($msg) {
    $line = "[{0}] {1}" -f (Get-Date -Format "HH:mm:ss"), $msg
    $line | Tee-Object -FilePath $logPath -Append
}

function Debug($msg) {
    if ($script:debug) { Log "[DEBUG] $msg" }
}

# -------------------------
# VALIDATION (NEW)
# -------------------------

function Validate-Config {

    if ([string]::IsNullOrWhiteSpace($script:ssid)) {
        Log "ERROR: SSID is null or empty"
        return $false
    }

    if ([string]::IsNullOrWhiteSpace($script:ssidpw)) {
        Log "ERROR: SSID password is null or empty"
        return $false
    }

    return $true
}

# -------------------------
# SAFE HEX CONVERSION (FIXED)
# -------------------------

function Convert-SSIDToHex {
    param ($ssid)

    if ([string]::IsNullOrWhiteSpace($ssid)) {
        return ""
    }

    return ($ssid.ToCharArray() | ForEach-Object {
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
# ADAPTER DETECTION (SAFE)
# -------------------------

function Detect-Adapters {

    try {
        $wifi = Get-NetAdapter |
            Where-Object {
                $_.InterfaceDescription -match "Wi-Fi|Wireless" -or
                $_.Name -match "Wi-Fi|WLAN|Wireless"
            } |
            Select-Object -First 1

        $eth = Get-NetAdapter |
            Where-Object { $_.Name -match "Ethernet|eth" } |
            Select-Object -First 1

        $script:wladapter = if ($wifi) { $wifi.Name } else { $null }
        $script:eadapter  = if ($eth)  { $eth.Name }  else { $null }

        Debug "WiFi Adapter: $script:wladapter"
        Debug "Ethernet Adapter: $script:eadapter"
    }
    catch {
        Debug "Adapter detection failed"
        $script:wladapter = $null
        $script:eadapter  = $null
    }
}

# -------------------------
# WIFI PROFILE
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

    $xml = Create-WifiProfileXml

    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($file, $xml, $utf8)

    netsh wlan delete profile name="$script:ssid" | Out-Null
    $result = netsh wlan add profile filename="$file" user=current 2>&1

    Debug ($result -join " ")

    Remove-Item $file -Force -ErrorAction SilentlyContinue
}

# -------------------------
# CONNECT
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

        Start-Sleep (5 * $i)
    }

    return $false
}

# -------------------------
# STATE ENGINE
# -------------------------

function State-Engine {

    switch ($script:State) {

        "Init" {

            Log "STATE → Init"

            if (-not (Validate-Config)) {
                Start-Sleep 10
                return
            }

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
# STATE HANDLERS
# -------------------------

function Enter-WirelessState {
    Detect-Adapters
    Connect-Wifi | Out-Null
    $script:State = "WirelessActive"
}

function Enter-EthernetState {
    Detect-Adapters
    if ($script:eadapter) {
        Enable-NetAdapter -Name $script:eadapter -ErrorAction SilentlyContinue
    }
    $script:State = "EthernetActive"
}

function Enter-RecoveryState {
    Log "Recovery"
    Start-Sleep 5
    $script:State = "Init"
}

# -------------------------
# MAIN LOOP
# -------------------------

Log "Engine $version"

while ($true) {
    try {
        State-Engine
        Start-Sleep 3
    }
    catch {
        Log $_.Exception.Message
        Start-Sleep 5
    }
}