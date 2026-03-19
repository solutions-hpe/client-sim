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

& 'iperf3.exe' -c $iperf_server -p $rn_iperf_port -b 1k -t $rn_iperf_time
& 'iperf3.exe' -c $iperf_server -p 443 -b 1k -t $rn_iperf_time
& 'iperf3.exe' -c $iperf_server -p 3260 -b 1k -t $rn_iperf_time
& 'iperf3.exe' -c $iperf_server -p 2049 -b 1k -t $rn_iperf_time
& 'iperf3.exe' -c $iperf_server -p 1194 -b 1k -t $rn_iperf_time
& 'iperf3.exe' -c $iperf_server -p 3389 -b 1k -t $rn_iperf_time
& 'iperf3.exe' -c $iperf_server -p 445 -b 1k -t $rn_iperf_time
& 'iperf3.exe' -c $iperf_server -p 80 -b 1k -t $rn_iperf_time
& 'iperf3.exe' -c $iperf_server -p 1433 -b 1k -t $rn_iperf_time
