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

for ($i = 1; $i -le 10; $i++) {
    foreach ($r in $dnsfile) {
        Get-Date | Tee-Object -FilePath $logPath -Append
        "------------------------------" | Tee-Object -FilePath $logPath -Append
        "DNS Fail: $dns_fail" | Tee-Object -FilePath $logPath -Append  # Note: $dns_fail not defined, perhaps from config?
        "Running DNS Failure:" | Tee-Object -FilePath $logPath -Append
        "Simulation Iteration: $i" | Tee-Object -FilePath $logPath -Append
        $r | Tee-Object -FilePath $logPath -Append
        "------------------------------" | Tee-Object -FilePath $logPath -Append

        # Simulate dig commands using Resolve-DnsName
        try { Resolve-DnsName -Name $r -Server $dns_bad_record_1 -ErrorAction Stop } catch { }
        try { Resolve-DnsName -Name $r -Server $dns_bad_record_2 -ErrorAction Stop } catch { }
        try { Resolve-DnsName -Name $r -Server $dns_bad_record_3 -ErrorAction Stop } catch { }
        try { Resolve-DnsName -Name $r -Server $dns_bad_ip_1 -ErrorAction Stop } catch { }
        try { Resolve-DnsName -Name $r -Server $dns_bad_ip_2 -ErrorAction Stop } catch { }
        try { Resolve-DnsName -Name $r -Server $dns_bad_ip_3 -ErrorAction Stop } catch { }
        try { Resolve-DnsName -Name $r -Server $dns_latency_1 -ErrorAction Stop } catch { }
        try { Resolve-DnsName -Name $r -Server $dns_latency_2 -ErrorAction Stop } catch { }
        try { Resolve-DnsName -Name $r -Server $dns_latency_3 -ErrorAction Stop } catch { }

        Start-Sleep 5
    }
}
