# PowerShell equivalent of sys_mon.sh
$version = "0.06"
$logPath = "C:\Scripts\sim_reboot.log"

# Monitor Event Log for failures
$lastEventId = 0
while ($true) {
    $events = Get-WinEvent -LogName System -MaxEvents 10 | Where-Object { $_.Id -gt $lastEventId -and $_.Level -le 2 }
    foreach ($event in $events) {
        if ($event.Message -like "*Call Trace*" -or $event.Message -like "*failure*") {
            "Failure message Found" | Tee-Object -FilePath $logPath -Append
            "Rebooting system" | Tee-Object -FilePath $logPath -Append
            Get-Date | Tee-Object -FilePath $logPath -Append
            "--------------------------" | Tee-Object -FilePath $logPath -Append
            Restart-Computer -Force
        }
        $lastEventId = $event.Id
    }
    Start-Sleep 10
}
