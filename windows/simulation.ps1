
# =========================================================
# STRICT ORDER NETWORK STATE ENGINE
# Wi-Fi deterministic pipeline (no race conditions)
# =========================================================

$version = "4.0-strict-engine"
$logPath = "C:\Scripts\sim.log"
$maxLogSize = 10MB

# -------------------------
# CONFIG
# -------------------------

$script:sim_phy = if ($sim_phy) { $sim_phy } else { "wireless" }

$script:ssid    = $ssid
$script:ssidpw  = $ssidpw

$script:debug = $true

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# -------------------------
# STATE
# -------------------------

$script:State = "Init"
$script:wifiFailCount = 0

# =========================================================
# LOGGING
# =========================================================

function Rotate-LogIfNeeded {
    if (Test-Path $logPath) {
        try {
            if ((Get-Item $logPath).Length -ge $maxLogSize) {
                Set-Content -Path $logPath -Value (Get-Content $logPath -Tail 5000)
            }
        } catch {}
    }
}

function Log($msg) {
    Rotate-LogIfNeeded
    $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $msg
    $line | Tee-Object -FilePath $logPath -Append
}

function Debug($msg) {
    if ($script:debug) {
        Log ("[DEBUG] {0}" -f $msg)
    }
}

# =========================================================
# NETWORK CHECKS
# =========================================================

function Test-Network {
    try {
        Test-NetConnection -ComputerName "8.8.8.8" -InformationLevel Quiet -WarningAction SilentlyContinue
    } catch {
        $false
    }
}

function Test-WifiConnected {
    try {
        (netsh wlan show interfaces) -match "State\s*:\s*connected"
    } catch {
        $false
    }
}

# =========================================================
# ADAPTER DETECTION (SAFE)
# =========================================================

function Detect-Adapters {

    try {
        $adapters = Get-CimInstance Win32_NetworkAdapter |
            Where-Object { $_.NetConnectionID -ne $null }

        $wifi = $adapters | Where-Object { $_.Name -match "Wi-Fi|Wireless|WLAN" } | Select-Object -First 1
        $eth  = $adapters | Where-Object { $_.Name -match "Ethernet|eth" } | Select-Object -First 1

        $script:wladapter = $wifi.NetConnectionID
        $script:eadapter  = $eth.NetConnectionID

        Debug ("WiFi Adapter = {0}" -f $script:wladapter)
        Debug ("Ethernet Adapter = {0}" -f $script:eadapter)
    }
    catch {
        Debug "Adapter detection failed safely"
        $script:wladapter = $null
        $script:eadapter  = $null
    }
}

# =========================================================
# WIFI SECURITY DETECTION
# =========================================================

function Get-WifiSecurityType {

    try {
        $scan = netsh wlan show networks mode=bssid

        if ($scan -match "WPA3") { return "WPA3" }
        if ($scan -match "WPA2") { return "WPA2" }
        if ($scan -match "WPA")  { return "WPA" }

        return "UNKNOWN"
    }
    catch {
        return "UNKNOWN"
    }
}

# =========================================================
# WIFI PROFILE XML
# =========================================================

function New-WifiProfileXml {

    param(
        [string]$ssid,
        [string]$password,
        [string]$securityType
    )

    $auth = "WPA2PSK"
    $enc  = "AES"

    switch ($securityType) {
        "WPA" {
            $auth = "WPAPSK"
            $enc  = "TKIP"
        }
        default {
            $auth = "WPA2PSK"
            $enc  = "AES"
        }
    }

@"
<?xml version="1.0"?>
<WLANProfile xmlns="http://www.microsoft.com/networking/WLAN/profile/v1">
    <name>$ssid</name>

    <SSIDConfig>
        <SSID>
            <name>$ssid</name>
        </SSID>
    </SSIDConfig>

    <connectionType>ESS</connectionType>
    <connectionMode>auto</connectionMode>

    <MSM>
        <security>
            <authEncryption>
                <authentication>$auth</authentication>
                <encryption>$enc</encryption>
                <useOneX>false</useOneX>
            </authEncryption>

            <sharedKey>
                <keyType>passPhrase</keyType>
                <protected>false</protected>
                <keyMaterial>$password</keyMaterial>
            </sharedKey>
        </security>
    </MSM>
</WLANProfile>
"@
}

# =========================================================
# PROFILE INSTALL (STRICT PHASE 2)
# =========================================================

function Install-WifiProfile {

    $security = Get-WifiSecurityType
    $tempFile = Join-Path $env:TEMP ("wifi_{0}.xml" -f $script:ssid)

    try {
        Debug ("Security detected: {0}" -f $security)

        $xml = New-WifiProfileXml -ssid $script:ssid -password $script:ssidpw -securityType $security
        $xml | Set-Content -Path $tempFile -Encoding UTF8

        Debug ("Creating profile XML: {0}" -f $tempFile)

        $result = netsh wlan add profile filename="$tempFile" user=current 2>&1

        Debug ("Profile import result: {0}" -f ($result -join " "))
    }
    finally {
        if (Test-Path $tempFile) {
            Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
            Debug "Temp XML removed"
        }
    }
}

# =========================================================
# HARD ETHERNET OFF
# =========================================================

function Disable-Ethernet {

    Detect-Adapters

    if ($script:eadapter) {
        Debug "Disabling Ethernet (STRICT MODE)"
        Disable-NetAdapter -Name $script:eadapter -Confirm:$false -ErrorAction SilentlyContinue
        Start-Sleep 2
    }
}

# =========================================================
# WIFI CONNECT (PHASE 3)
# =========================================================

function Connect-Wifi {

    if (-not $script:wladapter) {
        Debug "No Wi-Fi adapter available"
        return $false
    }

    for ($i = 1; $i -le 5; $i++) {

        Debug ("Wi-Fi attempt {0} -> {1}" -f $i, $script:ssid)

        Disable-NetAdapter -Name $script:wladapter -Confirm:$false -ErrorAction SilentlyContinue
        Start-Sleep 2
        Enable-NetAdapter -Name $script:wladapter -ErrorAction SilentlyContinue
        Start-Sleep 5

        $output = & netsh wlan connect name="$script:ssid" 2>&1
        Debug ("netsh output: {0}" -f ($output -join " "))

        Start-Sleep 6

        if (Test-WifiConnected -and Test-Network) {
            Debug "Wi-Fi CONNECTED + INTERNET OK"
            return $true
        }

        Start-Sleep (5 * $i)
    }

    return $false
}

# =========================================================
# STRICT WIRELESS PIPELINE
# =========================================================

function Enter-WirelessState {

    Debug "WIRELESS PIPELINE START"

    # PHASE 1 - HARD ETH OFF
    Disable-Ethernet

    # PHASE 2 - DETECT WIFI
    Detect-Adapters

    if (-not $script:wladapter) {
        Log "No Wi-Fi adapter -> fallback"
        $script:State = "Recovery"
        return
    }

    # PHASE 3 - BUILD PROFILE
    Install-WifiProfile

    # PHASE 4 - CONNECT
    if (Connect-Wifi) {
        Log "STATE -> WirelessActive"
        $script:State = "WirelessActive"
        $script:wifiFailCount = 0
    }
    else {
        Log "Wi-Fi failed -> Recovery"
        $script:State = "Recovery"
    }
}

# =========================================================
# STATES
# =========================================================

function Enter-EthernetState {

    Detect-Adapters

    if ($script:eadapter) {
        Enable-NetAdapter -Name $script:eadapter -ErrorAction SilentlyContinue
    }

    Log "STATE -> EthernetActive"
    $script:State = "EthernetActive"
}

function Enter-RecoveryState {

    Detect-Adapters

    if ($script:eadapter) {
        Enable-NetAdapter -Name $script:eadapter -ErrorAction SilentlyContinue
    }

    Log "STATE -> Recovery -> Ethernet fallback"
    $script:State = "EthernetActive"
}

# =========================================================
# STATE ENGINE
# =========================================================

function State-Engine {

    switch ($script:State) {

        "Init" {
            Log "STATE -> Init"

            if ($script:sim_phy -eq "wireless") {
                Enter-WirelessState
            }
            else {
                Enter-EthernetState
            }
        }

        "WirelessActive" {

            if (Test-Network -and Test-WifiConnected) {
                return
            }

            $script:wifiFailCount++

            if ($script:wifiFailCount -le 5) {

                $delay = [math]::Pow(2, $script:wifiFailCount)

                Log ("Retry {0}/5 -> wait {1}s" -f $script:wifiFailCount, $delay)

                Start-Sleep $delay
                Enter-WirelessState
                return
            }

            Log "Wireless failed -> Recovery"
            $script:State = "Recovery"
        }

        "EthernetActive" {

            if ($script:sim_phy -eq "ethernet") {
                return
            }
        }

        "Recovery" {
            Enter-RecoveryState
        }
    }
}

# =========================================================
# MAIN LOOP
# =========================================================

Log "================================"
Log ("Engine {0}" -f $version)

$cycle = 1

while ($true) {

    try {
        State-Engine

        if ($script:State -eq "WirelessActive") {
            if (-not (Test-Network)) {
                Log ("Cycle {0}: unstable network" -f $cycle)
            }
        }

        Start-Sleep (Get-Random -Min 3 -Max 10)
        $cycle++
    }
    catch {
        Log "FATAL RESET -> Init"
        Log ($_.Exception.Message)
        $script:State = "Init"
        $script:wifiFailCount = 0
        Start-Sleep 2
    }
}