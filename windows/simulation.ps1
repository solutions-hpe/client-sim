
# =========================================================
# NETWORK ENGINE (PROFILE CREATION + STABLE CONNECT)
# Fixes 80001 by enforcing strict WPA2-Personal schema
# =========================================================

$version = "6.1-profile-create"

$script:ssid   = $ssid
$script:ssidpw = $ssidpw

$script:State = "Init"
$script:wifiFailCount = 0
$script:debug = $true

# =========================================================
# LOGGING
# =========================================================

function Log($msg) {
    Write-Host ("[{0}] {1}" -f (Get-Date -Format "HH:mm:ss"), $msg)
}

function Debug($msg) {
    if ($script:debug) { Log "[DEBUG] $msg" }
}

# =========================================================
# ADAPTER DETECTION
# =========================================================

function Detect-Adapters {

    $adapters = Get-CimInstance Win32_NetworkAdapter |
        Where-Object { $_.NetConnectionID -ne $null }

    $wifi = $adapters | Where-Object { $_.Name -match "Wi-Fi|Wireless|WLAN" } | Select-Object -First 1
    $eth  = $adapters | Where-Object { $_.Name -match "Ethernet|eth" } | Select-Object -First 1

    $script:wladapter = $wifi.NetConnectionID
    $script:eadapter  = $eth.NetConnectionID
}

# =========================================================
# NETWORK CHECKS
# =========================================================

function Test-Internet {
    Test-NetConnection 8.8.8.8 -InformationLevel Quiet -WarningAction SilentlyContinue
}

function Test-WifiConnected {
    (netsh wlan show interfaces) -match "State\s*:\s*connected"
}

# =========================================================
# CLEAN PROFILE RESET
# =========================================================

function Remove-ExistingProfile {

    Debug "Removing existing Wi-Fi profile (if any)"

    try {
        netsh wlan delete profile name="$script:ssid" | Out-Null
    } catch {}
}

# =========================================================
# SAFE WPA2 PROFILE CREATION (NO 80001)
# =========================================================

function Create-WifiProfileXml {

@"
<?xml version="1.0" encoding="UTF-8"?>
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
}

function Install-WifiProfile {

    $tempFile = Join-Path $env:TEMP ("wifi_{0}.xml" -f $script:ssid)

    Debug "Generating Wi-Fi profile XML"

    $xml = Create-WifiProfileXml

    # CRITICAL: UTF8 without BOM (prevents silent schema failure)
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($tempFile, $xml, $utf8NoBom)

    Debug "Installing Wi-Fi profile -> $tempFile"

    $result = netsh wlan add profile filename="$tempFile" user=current 2>&1

    Debug ("netsh result: {0}" -f ($result -join " "))

    Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
}

# =========================================================
# CONNECT FLOW
# =========================================================

function Connect-Wifi {

    Detect-Adapters

    if (-not $script:wladapter) {
        return $false
    }

    for ($i = 1; $i -le 5; $i++) {

        Debug "Attempt $i -> connect $script:ssid"

        Remove-ExistingProfile
        Install-WifiProfile

        Start-Sleep 2

        netsh wlan connect name="$script:ssid" ssid="$script:ssid" | Out-Null

        Start-Sleep 6

        if (Test-WifiConnected -and Test-Internet) {
            Log "CONNECTED SUCCESSFULLY"
            return $true
        }

        Start-Sleep (3 * $i)
    }

    return $false
}

# =========================================================
# ENGINE STATES
# =========================================================

function Run-Engine {

    switch ($script:State) {

        "Init" {

            Log "STATE -> Init"

            if (Connect-Wifi) {
                $script:State = "WirelessActive"
            }
            else {
                $script:State = "Recovery"
            }
        }

        "WirelessActive" {

            if (Test-Internet -and Test-WifiConnected) {
                return
            }

            $script:wifiFailCount++

            Log "Wi-Fi lost -> retry $script:wifiFailCount"

            if ($script:wifiFailCount -le 5) {

                Start-Sleep (2 * $script:wifiFailCount)

                if (Connect-Wifi) {
                    $script:wifiFailCount = 0
                    return
                }
            }

            $script:State = "Recovery"
        }

        "Recovery" {

            Log "Recovery -> resetting WLAN stack"

            Restart-Service WlanSvc -Force -ErrorAction SilentlyContinue
            Start-Sleep 5

            $script:State = "Init"
        }
    }
}

# =========================================================
# MAIN LOOP
# =========================================================

Log "Engine $version"

while ($true) {

    try {
        Run-Engine
        Start-Sleep 3
    }
    catch {
        Log $_.Exception.Message
        $script:State = "Recovery"
    }
}