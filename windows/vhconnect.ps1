# PowerShell equivalent of vhconnect.sh
$version = "0.18"
$logPath = "C:\Scripts\sim.log"
"VHConnect Script Version $version" | Tee-Object -FilePath $logPath -Append
Get-Date

"Getting VH device list" | Write-Host
& 'vhclientx86_64.exe' -t LIST -r "C:\Temp\vhactive.txt"

"VH Server is $vh_server" | Write-Host

$r_count = 0
$y_count = 0

$vhactive = @(Get-Content "C:\Temp\vhactive.txt" | Select-String "you" | ForEach-Object { $_ -replace '.*\(', '' -replace '\).*', '' })
$y_count = $vhactive.Count

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
                if ($y_count -gt 1) {
                    "Found multiple devices $y_count in-use" | Write-Host
                    "Clearing out all devices in-use" | Write-Host
                    & 'vhclientx86_64.exe' -t "AUTO USE CLEAR ALL"
                    & 'vhclientx86_64.exe' -t "STOP USING ALL LOCAL"
                }
                $vhserver_device = Get-Content $vhCachePath
                "Cached $vhserver_device" | Write-Host
            } else {
                "No Cached VH Device found" | Write-Host
                "Finding an available adapter" | Write-Host
                $rn_vhactive = Get-Random -Minimum 1 -Maximum ($r_count + 1)
                if ($y_count -gt 1) {
                    "Found multiple devices in-use" | Write-Host
                    "Clearing out all devices in-use" | Write-Host
                    & 'vhclientx86_64.exe' -t "AUTO USE CLEAR ALL"
                    & 'vhclientx86_64.exe' -t "STOP USING ALL LOCAL"
                }
                $r_count = 0
                if ($y_count -ne 1) {
                    foreach ($r in $vhactive) {
                        $r_count++
                        if ($r_count -eq $rn_vhactive) {
                            $vhserver_device = $r
                            "New VH $vhserver_device" | Tee-Object -FilePath $logPath -Append
                            $vhserver_device | Out-File $vhCachePath
                        }
                    }
                }
            }
            # Connect to device (assuming vhclientx86_64.exe handles connection)
            & 'vhclientx86_64.exe' -t "USE $vhserver_device"
        }
    }
}
