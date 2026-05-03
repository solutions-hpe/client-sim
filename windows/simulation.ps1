
# =========================================================
# PRODUCTION WIFI SIMULATION ENGINE v3.0
# - WlanSetProfile (correct usage)
# - WlanConnect (PROFILE MODE ONLY - STABLE)
# - NO netsh
# - NO SSID STRUCT MANIPULATION
# =========================================================

$version = "3.0-wlan-production"

$script:ssid   = $ssid
$script:ssidpw = $ssidpw

$script:State = "Init"
$script:cycle = 0
$script:failCount = 0
$script:maxRetries = 5

$logPath = "C:\Scripts\sim.log"

# -------------------------
# LOGGING
# -------------------------

function Log($msg) {
    $line = "[{0}] {1}" -f (Get-Date -Format "HH:mm:ss"), $msg
    $line | Tee-Object -FilePath $logPath -Append
}

function Debug($msg) {
    Log "[DEBUG] $msg"
}

# =========================================================
# WLAN API DEFINITIONS
# =========================================================

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public class WlanApi
{
    [DllImport("wlanapi.dll")]
    public static extern int WlanOpenHandle(
        uint clientVersion,
        IntPtr reserved,
        out uint negotiatedVersion,
        out IntPtr clientHandle
    );

    [DllImport("wlanapi.dll")]
    public static extern int WlanCloseHandle(
        IntPtr clientHandle,
        IntPtr reserved
    );

    [DllImport("wlanapi.dll", CharSet = CharSet.Unicode)]
    public static extern int WlanSetProfile(
        IntPtr clientHandle,
        ref Guid interfaceGuid,
        uint flags,
        string profileXml,
        string allUserProfileSecurity,
        bool overwrite,
        IntPtr reserved,
        out uint reasonCode
    );

    [DllImport("wlanapi.dll", CharSet = CharSet.Unicode)]
    public static extern int WlanConnect(
        IntPtr clientHandle,
        ref Guid interfaceGuid,
        IntPtr connectionParams,
        IntPtr reserved
    );
}
"@

# =========================================================
# INTERFACE DETECTION
# =========================================================

function Get-WifiInterface {

    $iface = Get-NetAdapter |
        Where-Object {
            $_.Status -ne "Disabled" -and
            $_.InterfaceDescription -match "Wi-Fi|Wireless|WLAN"
        } |
        Select-Object -First 1

    if (-not $iface) {
        throw "No Wi-Fi interface found"
    }

    return $iface
}

# =========================================================
# PROFILE XML BUILDER
# =========================================================

function New-WifiProfileXml {

    param($ssid, $password)

    $hex = ($ssid.ToCharArray() | ForEach-Object {
        "{0:X2}" -f [int][char]$_
    }) -join ''

    return @"
<?xml version="1.0"?>
<WLANProfile xmlns="http://www.microsoft.com/networking/WLAN/profile/v1">
    <name>$ssid</name>

    <SSIDConfig>
        <SSID>
            <hex>$hex</hex>
            <name>$ssid</name>
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
                <keyMaterial>$password</keyMaterial>
            </sharedKey>
        </security>
    </MSM>

</WLANProfile>
"@
}

# =========================================================
# PROFILE CREATION (FIXED RELIABLE VERSION)
# =========================================================

function Set-WifiProfile {

    try {
        $handle = [IntPtr]::Zero
        $version = 0

        $res = [WlanApi]::WlanOpenHandle(2, [IntPtr]::Zero, [ref]$version, [ref]$handle)

        if ($res -ne 0) {
            Log "WlanOpenHandle failed: $res"
            return $false
        }

        $iface = Get-WifiInterface
        $guid = $iface.InterfaceGuid

        $xml = New-WifiProfileXml $script:ssid $script:ssidpw

        $reason = 0

        $result = [WlanApi]::WlanSetProfile(
            $handle,
            [ref]$guid,
            0,
            $xml,
            $null,
            $true,
            [IntPtr]::Zero,
            [ref]$reason
        )

        [void][WlanApi]::WlanCloseHandle($handle, [IntPtr]::Zero)

        if ($result -ne 0) {
            Log "PROFILE CREATION FAILED HRESULT=$result Reason=$reason"
            return $false
        }

        Log "PROFILE CREATED SUCCESSFULLY -> $script:ssid"
        return $true
    }
    catch {
        Log "PROFILE EXCEPTION: $($_.Exception.Message)"
        return $false
    }
}

# =========================================================
# WIFI CONNECT (PROFILE MODE - STABLE)
# =========================================================

function Connect-Wifi {

    try {
        $iface = Get-WifiInterface

        $handle = [IntPtr]::Zero
        $version = 0

        [void][WlanApi]::WlanOpenHandle(2, [IntPtr]::Zero, [ref]$version, [ref]$handle)

        # IMPORTANT:
        # We pass NULL connection params pointer for PROFILE MODE
        # Windows resolves profile internally

        $result = [WlanApi]::WlanConnect(
            $handle,
            [ref]$iface.InterfaceGuid,
            [IntPtr]::Zero,
            [IntPtr]::Zero
        )

        [void][WlanApi]::WlanCloseHandle($handle, [IntPtr]::Zero)

        if ($result -ne 0) {
            Log "CONNECT FAILED HRESULT=$result"
            return $false
        }

        Start-Sleep 6

        $status = netsh wlan show interfaces

        if ($status -match "State\s*:\s*connected") {
            Log "WI-FI CONNECTED SUCCESSFULLY"
            return $true
        }

        Log "CONNECT INITIATED BUT NOT VERIFIED"
        return $false
    }
    catch {
        Log "CONNECT EXCEPTION: $($_.Exception.Message)"
        return $false
    }
}

# =========================================================
# STATE MACHINE
# =========================================================

function State-Engine {

    $script:cycle++

    switch ($script:State) {

        "Init" {

            Log "STATE -> INIT"

            if (Set-WifiProfile) {
                $script:State = "Connect"
            }
            else {
                $script:State = "Recovery"
            }
        }

        "Connect" {

            if (Connect-Wifi) {
                $script:State = "WirelessActive"
                $script:failCount = 0
            }
            else {
                $script:failCount++

                if ($script:failCount -ge $script:maxRetries) {
                    $script:State = "Recovery"
                }
                else {
                    Start-Sleep ($script:failCount * 2)
                }
            }
        }

        "WirelessActive" {

            Start-Sleep 3

            $status = netsh wlan show interfaces

            if ($status -notmatch "State\s*:\s*connected") {
                Log "WIRELESS LOST CONNECTION"
                $script:State = "Connect"
            }
        }

        "Recovery" {

            Log "STATE -> RECOVERY"
            Start-Sleep 3
            $script:State = "Init"
        }
    }
}

# =========================================================
# MAIN LOOP
# =========================================================

Log "========================================"
Log "WLAN PRODUCTION ENGINE v$version STARTED"
Log "SSID: $script:ssid"
Log "========================================"

while ($true) {

    try {
        State-Engine
        Start-Sleep (Get-Random -Minimum 2 -Maximum 4)
    }
    catch {
        Log "FATAL ERROR: $($_.Exception.Message)"
        $script:State = "Recovery"
    }
}