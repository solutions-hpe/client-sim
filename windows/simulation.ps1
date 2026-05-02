
# =========================================================
# NETWORK STATE ENGINE (STABLE MODE - NO XML IMPORT)
# Fixes persistent 80001 by removing profile injection path
# =========================================================

$version = "5.1-stable-no-xml"
$logPath = "C:\Scripts\sim.log"

# -------------------------
# CONFIG
# -------------------------

$script:sim_phy = if ($sim_phy) { $sim_phy } else { "wireless" }

$script:ssid    = $ssid
$script:ssidpw  = $ssidpw

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
    if ($script:debug) {
        Log "[DEBUG] $msg"
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

        Debug "WiFi = $($script:wladapter)"
        Debug "ETH  = $($script:eadapter)"
    }
    catch {
        Debug "Adapter detection failed"
        $script:wladapter = $null
        $script:eadapter  = $null
    }
}

# =========================================================
# NETWORK CHECKS
# =========================================================

function Test-Internet {
    try {
        Test-NetConnection 8.8.8.8 -InformationLevel Quiet -WarningAction SilentlyContinue
    } catch {
        $false
    }
}

function Test-WifiConnected {
    (netsh wlan show interfaces) -match "State\s*:\s*connected"
}

# =========================================================
# HARD ETHERNET CONTROL
# =========================================================

function Disable-Ethernet {

    Detect-Adapters

    if ($script:eadapter) {
        Debug "Disabling Ethernet"
        Disable-NetAdapter -Name $script:eadapter -Confirm:$false -ErrorAction SilentlyContinue
        Start-Sleep 2
    }
}

function Enable-Ethernet {

    Detect-Adapters

    if ($script:eadapter) {
        Debug "Enabling Ethernet"
        Enable-NetAdapter -Name $script:eadapter -ErrorAction SilentlyContinue
    }
}

# =========================================================
# WIFI CONNECT (NO PROFILE CREATION)
# RELIES ON EXISTING WINDOWS PROFILE OR STORED CREDS
# =========================================================

function Connect-Wifi {

    if (-not $script:wladapter) {
        Debug "No Wi-Fi adapter"
        return $false
    }

    for ($i = 1; $i -le 5; $i++) {

        Debug "Wi-Fi attempt $i -> $script:ssid"

        Disable-NetAdapter -Name $script:wladapter -Confirm:$false -ErrorAction SilentlyContinue
        Start-Sleep 2
        Enable-NetAdapter -Name $script:wladapter -ErrorAction SilentlyContinue
        Start-Sleep 5

        # IMPORTANT: no profile creation, only connect attempt
        netsh wlan connect name="$script:ssid" ssid="$script:ssid" | Out-Null

        Start-Sleep 6

        if (Test-WifiConnected -and Test-Internet) {
            Debug "Wi-Fi CONNECTED"
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

    # STEP 1: ETH OFF
    Disable-Ethernet

    # STEP 2: detect
    Detect-Adapters

    if (-not $script:wladapter) {
        Log "No Wi-Fi adapter -> fallback"
        $script:State = "Recovery"
        return
    }

    # STEP 3: connect (NO XML, NO PROFILE INJECTION)
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

    Enable-Ethernet

    Log "STATE -> EthernetActive"
    $script:State = "EthernetActive"
}

function Enter-RecoveryState {

    Enable-Ethernet

    Log "STATE -> Recovery"
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

            if (Test-WifiConnected -and Test-Internet) {
                return
            }

            $script:wifiFailCount++

            if ($script:wifiFailCount -le 5) {

                $delay = [math]::Pow(2, $script:wifiFailCount)

                Log "Retry $script:wifiFailCount/5 -> $delay sec"
                Start-Sleep $delay

                Enter-WirelessState
                return
            }

            Log "Wireless failed -> Recovery"
            $script:State = "Recovery"
        }

        "EthernetActive" {
            return
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
Log "Engine $version"

while ($true) {

    try {
        State-Engine
        Start-Sleep (Get-Random -Min 3 -Max 8)
    }
    catch {
        Log "ERROR: $($_.Exception.Message)"
        $script:State = "Init"
        Start-Sleep 2
    }
}