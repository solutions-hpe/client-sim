# PowerShell equivalent of apt_update.sh
$version = "0.02"
$logPath = "C:\Scripts\sim.log"
"apt update Script Version $version" | Tee-Object -FilePath $logPath -Append
Get-Date | Tee-Object -FilePath $logPath -Append

# Update packages (using winget)
winget upgrade --all

# Install packages (equivalents for Linux tools)
winget install Git.Git
winget install wget
winget install Microsoft.WindowsTerminal  # gnome-terminal equivalent
# network-manager: Windows built-in network settings
# qemu-guest-agent: Not applicable on Windows
# net-tools: Windows built-in (e.g., netstat, ipconfig)
# smbclient: Windows built-in (SMB via PowerShell or net use)
# dnsutils: Windows built-in (nslookup, Resolve-DnsName)
winget install iperf3
winget install Mozilla.Firefox  # firefox-esr equivalent
# rsyslog: Windows Event Viewer built-in

# Autoremove not directly applicable; winget handles cleanup
