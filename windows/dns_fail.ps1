# PowerShell equivalent of dns_fail.sh
. .\ini-parser.ps1

$version = "0.01"
$logPath = "C:\Scripts\sim.log"
"DNS Failure Script Version $version" | Tee-Object -FilePath $logPath -Append
Get-Date | Tee-Object -FilePath $logPath -Append

$global:iniConfig = Parse-IniFile 'C:\Scripts\simulation.conf'
$dnsfile = Get-Content 'C:\Scripts\dns_fail.txt'
$dns_latency_1 = get_value 'address' 'dns_latency_1'
$dns_latency_2 = get_value 'address' 'dns_latency_2'
$dns_latency_3 = get_value 'address' 'dns_latency_3'
$dns_bad_ip_1 = get_value 'address' 'dns_bad_ip_1'
$dns_bad_ip_2 = get_value 'address' 'dns_bad_ip_2'
$dns_bad_ip_3 = get_value 'address' 'dns_bad_ip_3'
$dns_bad_record_1 = get_value 'address' 'dns_bad_record_1'
$dns_bad_record_2 = get_value 'address' 'dns_bad_record_2'
$dns_bad_record_3 = get_value 'address' 'dns_bad_record_3'

$bad_records = @($dns_bad_record_1, $dns_bad_record_2, $dns_bad_record_3)
$bad_ips = @($dns_bad_ip_1, $dns_bad_ip_2, $dns_bad_ip_3)
$latencies = @($dns_latency_1, $dns_latency_2, $dns_latency_3)

for ($i = 1; $i -le 10; $i++) {
    foreach ($r in $dnsfile) {
        Get-Date | Tee-Object -FilePath $logPath -Append
        "------------------------------" | Tee-Object -FilePath $logPath -Append
        "DNS Fail: $dns_fail" | Tee-Object -FilePath $logPath -Append
        "Running DNS Failure:" | Tee-Object -FilePath $logPath -Append
        "Simulation Iteration: $i" | Tee-Object -FilePath $logPath -Append
        $r | Tee-Object -FilePath $logPath -Append
        "------------------------------" | Tee-Object -FilePath $logPath -Append

        foreach ($server in ($bad_records + $bad_ips + $latencies)) {
            Resolve-DnsName -Name $r -Server $server -ErrorAction SilentlyContinue
        }
        Start-Sleep 5
    }
}
