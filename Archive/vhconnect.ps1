# PowerShell equivalent of vhconnect.sh
$version = "0.18"
$logPath = "C:\Scripts\sim.log"
"VHConnect Script Version $version" | Tee-Object -FilePath $logPath -Append
Get-Date

# Getting VH device list
"Getting VH device list" | Write-Host
& 'vhclientx86_64.exe' -t LIST -r "C:\Temp\vhactive.txt"

# Checking to see if there is a cache device to connect to
"VH Server is $vh_server" | Write-Host

# Counting & searching records
$r_count = 0
$y_count = 0

# Checking for the number of devices that are currently attached
$vhactive = @(Get-Content "C:\Temp\vhactive.txt" | Select-String "you" | ForEach-Object { $_ -replace '.*\(', '' -replace '\).*', '' })
$y_count = $vhactive.Count

# Checking the number of devices that are available
if ($sim_phy -eq "wireless") {
    $vhactive = @(Get-Content "C:\Temp\vhactive.txt" | Select-String -Pattern "802.11|ACLUSB-WIRELESS" | Select-String "In-use" -NotMatch | ForEach-Object { $_ -replace '.*\(', '' -replace '\).*', '' })
}
if ($sim_phy -eq "wired") {
    $vhactive = @(Get-Content "C:\Temp\vhactive.txt" | Select-String -Pattern "AX88|ACLUSB-STATIC" | Select-String "In-use" -NotMatch | ForEach-Object { $_ -replace '.*\(', '' -replace '\).*', '' })
}
$r_count = $vhactive.Count

"VH Available Adapters $r_count" | Tee-Object -FilePath $logPath -Append
"Adapters in use by you $y_count" | Tee-Object -FilePath $logPath -Append

$wladapter = Get-NetAdapter | Where-Object { $_.Name -like "*wireless*" -or $_.Name -like "*wlan*" } | Select-Object -First 1 -ExpandProperty Name

if ($wladapter) {
    "Adapter Found $wladapter" | Tee-Object -FilePath $logPath -Append
} else {
    if ($r_count -eq 0 -and $y_count -ne 1) {
        "No Available Adapters" | Tee-Object -FilePath $logPath -Append
        "Sleeping for 300 seconds" | Tee-Object -FilePath $logPath -Append
        "Will retry after sleep" | Tee-Object -FilePath $logPath -Append
        "------------------------------" | Tee-Object -FilePath $logPath -Append
        Start-Sleep 300
    } else {
        if ($vh_server -eq "on") {
            $vhCachePath = "C:\Scripts\vhcached.txt"
            if (Test-Path $vhCachePath) {
                # If Client is connected to more than 1 device - disconnecting
                if ($y_count -gt 1) {
                    "Found multiple devices $y_count in-use" | Write-Host
                    "Clearing out all devices in-use" | Write-Host
                    & 'vhclientx86_64.exe' -t "AUTO USE CLEAR ALL"
                    & 'vhclientx86_64.exe' -t "STOP USING ALL LOCAL"
                }

                # Setting value to cached adapter
                $vhserver_device = Get-Content $vhCachePath
                "Cached $vhserver_device" | Write-Host
            } else {
                # No cached device, find a random available one
                "No Cached VH Device found" | Write-Host
                "Finding an available adapter" | Write-Host
                $rn_vhactive = Get-Random -Minimum 1 -Maximum ($r_count + 1)

                # If Client is connected to more than 1 device - disconnecting
                if ($y_count -gt 1) {
                    "Found multiple devices in-use" | Write-Host
                    "Clearing out all devices in-use" | Write-Host
                    & 'vhclientx86_64.exe' -t "AUTO USE CLEAR ALL"
                    & 'vhclientx86_64.exe' -t "STOP USING ALL LOCAL"
                }

                # Looping through records to find an available adapter
                if ($y_count -ne 1) {
                    $r_count = 0
                    foreach ($r in $vhactive) {
                        $r_count++
                        if ($r_count -eq $rn_vhactive) {
                            $vhserver_device = $r
                            "New VH $vhserver_device" | Tee-Object -FilePath $logPath -Append
                            $vhserver_device | Tee-Object -FilePath $vhCachePath
                        }
                    }
                }
            }

            # Connecting to Adapter
            "Connecting to USB Adapter" | Tee-Object -FilePath $logPath -Append
            & 'vhclientx86_64.exe' -t "AUTO USE PORT,$vhserver_device"

            "Waiting for Adapter" | Tee-Object -FilePath $logPath -Append
            "------------------------------" | Tee-Object -FilePath $logPath -Append
        }
    }
}
