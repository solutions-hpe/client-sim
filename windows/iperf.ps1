# PowerShell equivalent of iperf.sh
$version = "0.01"
$logPath = "C:\Scripts\sim.log"
"iPerf Script Version $version" | Tee-Object -FilePath $logPath -Append
Get-Date | Tee-Object -FilePath $logPath -Append

Get-Date | Tee-Object -FilePath $logPath -Append
"------------------------------" | Tee-Object -FilePath $logPath -Append
"iPerf Server: $iperf_server" | Tee-Object -FilePath $logPath -Append
"iPerf Port: $rn_iperf_port" | Tee-Object -FilePath $logPath -Append
"iPerf Time: $rn_iperf_time" | Tee-Object -FilePath $logPath -Append
"Running iPerf simulation:" | Tee-Object -FilePath $logPath -Append
"------------------------------" | Tee-Object -FilePath $logPath -Append

$ports = @($rn_iperf_port, 443, 3260, 2049, 1194, 3389, 445, 80, 1433)
foreach ($port in $ports) {
    & 'iperf3.exe' -c $iperf_server -p $port -b 1k -t $rn_iperf_time
}
