
# =========================================================
# NETWORK SIMULATION ENGINE v2.0 (CLEAN REBUILD)
# - WLAN API ONLY (NO NETSH)
# - STATE MACHINE DRIVEN
# - NO ADAPTER TOGGLING
# =========================================================

$version = "2.0-clean-rebuild"

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
# WLAN API LAYER
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

    [DllImport("wlanapi.dll")]
    public static extern int WlanConnect(
        IntPtr clientHandle,
        ref Guid interfaceGuid,
        ref WLAN_CONNECTION_PARAMETERS connectionParams,
        IntPtr reserved
    );

    public enum WLAN_CONNECTION_MODE
    {
        Profile = 0
    }

    public enum DOT11_BSS_TYPE
    {
        Any = 3
    }

    public struct WLAN_CONNECTION_PARAMETERS
    {
        public WLAN_CONNECTION_MODE wlanConnectionMode;
        public string strProfile;
        public IntPtr pDot11Ssid;
        public DOT11_BSS_TYPE dot11BssType;
        public bool bSecurityEnabled;
    }
}
"@

# =========================================================
# WIFI INTERFACE
# =========================================================

function Get-WifiInterface {

    $adapter = Get-NetAdapter |
        Where-Object {
            $_.Status -ne "Disabled" -and
            $_.InterfaceDescription -match "Wi-Fi|Wireless|WLAN"
        } |
        Select-Object -First 1

    if (-not $adapter) {
        throw "No Wi-Fi adapter found"
    }

    return $adapter
}

# =========================================================
# PROFILE CREATION
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
# WLAN PROFILE SET
# =========================================================

function Set-WifiProfile {

    try {
        $handle = [IntPtr]::Zero
        $version = 0

        $result = [WlanApi]::WlanOpenHandle(2, [IntPtr]::Zero, [ref]$version, [ref]$handle)

        if ($result -ne 0) {
            Log "WlanOpenHandle failed: $result"
            return $false
        }

        $iface = Get-WifiInterface
        $guid = $iface.InterfaceGuid

        $xml = New-WifiProfileXml $script:ssid $script:ssidpw

        $reason = 0

        $res = [WlanApi]::WlanSetProfile(
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

        if ($res -ne 0) {
            Log "Profile creation failed: HRESULT=$res Reason=$reason"
            return $false
        }

        Log "Wi-Fi profile created/updated successfully"
        return $true
    }
    catch {
        Log "Profile exception: $($_.Exception.Message)"
        return $false
    }
}

# =========================================================
# WLAN CONNECT
# =========================================================

function Connect-Wifi {

    try {
        $iface = Get-WifiInterface

        $handle = [IntPtr]::Zero
        $version = 0

        [void][WlanApi]::WlanOpenHandle(2, [IntPtr]::Zero, [ref]$version, [ref]$handle)

        $params = New-Object WlanApi+WLAN_CONNECTION_PARAMETERS
        $params.wlanConnectionMode = [WlanApi+WLAN_CONNECTION_MODE]::Profile
        $params.strProfile = $script:ssid
        $params.dot11BssType = [WlanApi+DOT11_BSS_TYPE]::Any
        $params.bSecurityEnabled = $true

        Log "Attempting WLAN connect -> $script:ssid"

        $result = [WlanApi]::WlanConnect(
            $handle,
            [ref]$iface.InterfaceGuid,
            [ref]$params,
            [IntPtr]::Zero
        )

        [void][WlanApi]::WlanCloseHandle($handle, [IntPtr]::Zero)

        if ($result -ne 0) {
            Log "WlanConnect failed: $result"
            return $false
        }

        Start-Sleep 5

        $status = netsh wlan show interfaces

        if ($status -match "State\s*:\s*connected") {
            Log "Wi-Fi CONNECTED"
            return $true
        }

        Log "Wi-Fi not connected after attempt"
        return $false
    }
    catch {
        Log "Connect exception: $($_.Exception.Message)"
        return $false
    }
}

# =========================================================
# STATE ENGINE
# =========================================================

function State-Engine {

    $script:cycle++

    switch ($script:State) {

        "Init" {

            Log "STATE -> INIT"

            $profileOk = Set-WifiProfile

            if ($profileOk) {
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

            $status = netsh wlan show interfaces

            if ($status -notmatch "State\s*:\s*connected") {
                Log "Wi-Fi lost connection"
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

Log "===================================="
Log "SIMULATION ENGINE v$version STARTED"
Log "SSID: $script:ssid"
Log "===================================="

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