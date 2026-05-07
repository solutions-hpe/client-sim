$version = '.02'
$logPath = 'C:\Scripts\sim.log'
$debugPath = 'C:\Scripts\debug-vhconnect.log'
$tempDir = 'C:\Temp'
$vhActivePath = Join-Path $tempDir 'vhactive.txt'
$vhCachePath = 'C:\Scripts\vhcached.txt'

"VHConnect Script Version $version" | Tee-Object -FilePath $debugPath
"VHConnect Script Version $version" | Tee-Object -FilePath $logPath -Append | Out-Null
Get-Date | Tee-Object -FilePath $debugPath -Append | Tee-Object -FilePath $logPath -Append | Out-Null

if (-not (Test-Path -LiteralPath $tempDir)) {
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
}

try {
    & 'vhclientx86_64.exe' -t LIST -r $vhActivePath 2>&1 | Tee-Object -FilePath $debugPath -Append | Out-Null
} catch {
    "Failed to query VirtualHere devices: $($_.Exception.Message)" | Tee-Object -FilePath $debugPath -Append | Tee-Object -FilePath $logPath -Append | Out-Null
    exit 0
}

if (-not (Test-Path -LiteralPath $vhActivePath)) {
    'VirtualHere device list was not created.' | Tee-Object -FilePath $debugPath -Append | Tee-Object -FilePath $logPath -Append | Out-Null
    exit 0
}

$lines = @(Get-Content -LiteralPath $vhActivePath)
$y_count = @($lines | Where-Object { $_ -match 'you' }).Count

if ($sim_phy -eq 'wireless') {
    $availableLines = @($lines | Where-Object { $_ -match '802\.11|ACLUSB-WIRELESS' -and $_ -notmatch 'In-use' })
} else {
    $availableLines = @($lines | Where-Object { $_ -match 'AX88|ACLUSB-STATIC' -and $_ -notmatch 'In-use' })
}

$availableDevices = @(
    $availableLines |
        ForEach-Object {
            if ($_ -match '\(([^)]+)\)') {
                $matches[1]
            }
        } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
)

$r_count = $availableDevices.Count
"VH Available Adapters $r_count" | Tee-Object -FilePath $debugPath -Append | Tee-Object -FilePath $logPath -Append | Out-Null
"Adapters in use by you $y_count" | Tee-Object -FilePath $debugPath -Append | Tee-Object -FilePath $logPath -Append | Out-Null

$wladapter = Get-NetAdapter -ErrorAction SilentlyContinue |
    Where-Object {
        $_.Name -match 'wireless|wlan|wi-fi' -or $_.InterfaceDescription -match 'wireless|wlan|wi-fi|802\.11'
    } |
    Select-Object -First 1 -ExpandProperty Name

if ($wladapter) {
    "Adapter Found $wladapter" | Tee-Object -FilePath $debugPath -Append | Tee-Object -FilePath $logPath -Append | Out-Null
    exit 0
}

if ($r_count -eq 0 -and $y_count -ne 1) {
    'No Available Adapters' | Tee-Object -FilePath $debugPath -Append | Tee-Object -FilePath $logPath -Append | Out-Null
    'Sleeping for 300 seconds' | Tee-Object -FilePath $debugPath -Append | Tee-Object -FilePath $logPath -Append | Out-Null
    Start-Sleep -Seconds 300
    exit 0
}

if ($vh_server -ne 'on') {
    'VH server is disabled. Skipping connect.' | Tee-Object -FilePath $debugPath -Append | Tee-Object -FilePath $logPath -Append | Out-Null
    exit 0
}

if ($y_count -gt 1) {
    "Found multiple devices $y_count in-use" | Tee-Object -FilePath $debugPath -Append | Out-Null
    'Clearing out all devices in-use' | Tee-Object -FilePath $debugPath -Append | Out-Null
    & 'vhclientx86_64.exe' -t 'AUTO USE CLEAR ALL' 2>&1 | Tee-Object -FilePath $debugPath -Append | Out-Null
    & 'vhclientx86_64.exe' -t 'STOP USING ALL LOCAL' 2>&1 | Tee-Object -FilePath $debugPath -Append | Out-Null
}

$vhserver_device = $null
if (Test-Path -LiteralPath $vhCachePath) {
    $cachedDevice = Get-Content -LiteralPath $vhCachePath | Select-Object -First 1
    $vhserver_device = [string]$cachedDevice
    if ($vhserver_device) {
        $vhserver_device = $vhserver_device.Trim()
    }
    "Cached $vhserver_device" | Tee-Object -FilePath $debugPath -Append | Out-Null
} else {
    'No Cached VH Device found' | Tee-Object -FilePath $debugPath -Append | Out-Null
    if ($r_count -gt 0) {
        $vhserver_device = Get-Random -InputObject $availableDevices
        "New VH $vhserver_device" | Tee-Object -FilePath $debugPath -Append | Tee-Object -FilePath $logPath -Append | Out-Null
        $vhserver_device | Set-Content -LiteralPath $vhCachePath
    }
}

if ([string]::IsNullOrWhiteSpace($vhserver_device)) {
    'No VirtualHere device selected.' | Tee-Object -FilePath $debugPath -Append | Tee-Object -FilePath $logPath -Append | Out-Null
    exit 0
}

'Connecting to USB Adapter' | Tee-Object -FilePath $debugPath -Append | Tee-Object -FilePath $logPath -Append | Out-Null
& 'vhclientx86_64.exe' -t "AUTO USE PORT,$vhserver_device" 2>&1 | Tee-Object -FilePath $debugPath -Append | Out-Null
'Waiting for Adapter' | Tee-Object -FilePath $debugPath -Append | Tee-Object -FilePath $logPath -Append | Out-Null
'------------------------------' | Tee-Object -FilePath $debugPath -Append | Out-Null
