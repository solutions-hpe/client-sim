# PowerShell equivalent of download.sh
$version = "0.01"
$logPath = "C:\Scripts\sim.log"
"Download Script Version $version" | Tee-Object -FilePath $logPath -Append
Get-Date | Tee-Object -FilePath $logPath -Append

$r_count = 0
"Running Download simulation" | Tee-Object -FilePath $logPath -Append
$dlfile = Get-Content 'C:\Scripts\downloads.txt'
foreach ($r in $dlfile) { $r_count++ }
$rn_dl = Get-Random -Minimum 1 -Maximum ($r_count + 1)
$r_count = 0
foreach ($r in $dlfile) {
    $r_count++
    if ($r_count -eq $rn_dl) {
        Start-Sleep 1
        Get-Date | Tee-Object -FilePath $logPath -Append
        "------------------------------" | Tee-Object -FilePath $logPath -Append
        "Running Download Simulation:" | Tee-Object -FilePath $logPath -Append
        "------------------------------" | Tee-Object -FilePath $logPath -Append
        Invoke-WebRequest -Uri $r -OutFile C:\Temp\file.tmp | Tee-Object -FilePath $logPath -Append
    }
}
