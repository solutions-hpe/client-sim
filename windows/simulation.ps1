
# =========================================================
# WLAN SIMULATION ENGINE v4.0 (NO PROFILE CREATION)
# - Uses existing Windows Wi-Fi profile only
# - WlanConnect only
# =========================================================

$version = "4.0-profileless-connect"

$script:ssid = $ssid

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
# WLAN API
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

    [DllImport("wlanapi.dll")]
    public static extern int WlanConnect(
        IntPtr clientHandle,
        ref Guid interfaceGuid,
        IntPtr connectionParams,
        IntPtr reserved
    );
}
"@

# =========================================================
# WIFI INTERFACE
# =========================================================

function Get-WifiInterface {

    $iface = Get-NetAdapter |
        Where-Object {
            $_.Status -ne "Disabled" -and
            $_.InterfaceDescription -match "Wi-Fi|Wireless|WLAN"
        } |
        Select-Object -First 1

    if (-not $iface) {
        throw "No Wi-Fi adapter found"
    }

    return $iface
}

# =========================================================
# CONNECT ONLY (NO PROFILE MANAGEMENT)
# =========================================================

function Connect-Wifi {

    try {
        $iface = Get-WifiInterface

        $handle = [IntPtr]::Zero
        $version = 0

        $res = [WlanApi]::WlanOpenHandle(2, [IntPtr]::Zero, [ref]$version, [ref]$handle)

        if ($res -ne 0) {
            Log "WlanOpenHandle failed: $res"
            return $false
        }

        Log "Attempting connection to SSID -> $script:ssid"

        # KEY POINT:
        # We rely entirely on existing Windows profile
        $result = [WlanApi]::WlanConnect(
            $handle,
            [ref]$iface.InterfaceGuid,
            [IntPtr]::Zero,
            [IntPtr]::Zero
        )

        [void][WlanApi]::WlanCloseHandle($handle, [IntPtr]::Zero)

        if ($result -ne 0) {
            Log "WlanConnect FAILED HRESULT=$result"
            return $false
        }

        Start-Sleep 6

        $status = netsh wlan show interfaces

        if ($status -match "State\s*:\s*connected") {
            Log "Wi-Fi CONNECTED SUCCESSFULLY"
            return $true
        }

        Log "Wi-Fi NOT CONNECTED after attempt"
        return $false
    }
    catch {
        Log "CONNECT EXCEPTION: $($_.Exception.Message)"
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
            $script:State = "Connect"
        }

        "Connect" {

            if (Connect-Wifi) {
                $script:State = "WirelessActive"
                $script:failCount = 0
            }
            else {
                $script:failCount++

                Log "CONNECT FAIL COUNT = $script:failCount"

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
                Log "WIRELESS LOST CONNECTION"
                $script:State = "Connect"
            }
            else {
                Debug "Wireless stable"
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
Log "PROFILELESS WLAN ENGINE v$version STARTED"
Log "TARGET SSID: $script:ssid"
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