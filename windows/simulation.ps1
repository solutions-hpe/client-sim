
# =========================================================
# HYBRID NETWORK ENGINE (SAFE REAL WIFI + SIM LOGIC)
# =========================================================

$version = "8.1-hybrid-safe"

$script:ssid   = $ssid
$script:ssidpw = $ssidpw

$script:State = "Init"
$script:wifiFailCount = 0
$script:cycle = 0

# -------------------------
# LOGGING
# -------------------------

function Log($msg) {
    "[{0}] {1}" -f (Get-Date -Format "HH:mm:ss"), $msg |
        Tee-Object -FilePath "C:\Scripts\sim.log" -Append
}

function Debug($msg) {
    Log "[DEBUG] $msg"
}

# -------------------------
# HEX SSID
# -------------------------

function Convert-SSIDToHex {
    param ($ssid)

    if ([string]::IsNullOrWhiteSpace($ssid)) { return "" }

    ($ssid.ToCharArray() | ForEach-Object {
        "{0:X2}" -f [int][char]$_
    }) -join ''
}

# -------------------------
# WIFI PROFILE CREATION (RESTORED)
# -------------------------

function Install-WifiProfile {

    Debug "Creating Wi-Fi profile"

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

    $result = netsh wlan delete profile name="$script:ssid" 2>&1
    Debug $result

    $result = netsh wlan add profile filename="$file" user=current 2>&1
    Debug $result

    Remove-Item $file -Force -ErrorAction SilentlyContinue
}

# -------------------------
# WIFI CONNECT (SAFE, NO ADAPTER TOGGLING)
# -------------------------

function Connect-Wifi {

    Install-WifiProfile

    for ($i = 1; $i -le 5; $i++) {

        Debug "Connect attempt $i"

        netsh wlan connect name="$script:ssid" ssid="$script:ssid" | Out-Null

        Start-Sleep 5

        $status = netsh wlan show interfaces

        if ($status -match "State\s*:\s*connected") {
            Log "Wi-Fi CONNECTED"
            return $true
        }

        Start-Sleep (2 * $i)
    }

    return $false
}

# -------------------------
# STATE MACHINE
# -------------------------

function State-Engine {

    $script:cycle++

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

            $status = netsh wlan show interfaces

            if ($status -notmatch "State\s*:\s*connected") {

                $script:wifiFailCount++

                Log "Wi-Fi lost ($script:wifiFailCount)"

                if ($script:wifiFailCount -ge 5) {
                    $script:State = "Recovery"
                }
                else {
                    Start-Sleep (2 * $script:wifiFailCount)
                    Connect-Wifi | Out-Null
                }
            }
        }

        "Recovery" {

            Log "Recovery -> retry cycle"
            Start-Sleep 5

            $script:State = "Init"
        }
    }
}

# -------------------------
# MAIN LOOP
# -------------------------

Log "HYBRID ENGINE STARTED ($version)"

while ($true) {
    try {
        State-Engine
        Start-Sleep (Get-Random -Minimum 2 -Maximum 5)
    }
    catch {
        Log "ERROR: $($_.Exception.Message)"
        $script:State = "Recovery"
    }
}