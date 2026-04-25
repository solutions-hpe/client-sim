# PowerShell equivalent of apt_update.sh
$version = "0.02"
$logPath = "C:\Scripts\sim.log"
"apt update Script Version $version" | Tee-Object -FilePath $logPath -Append
Get-Date | Tee-Object -FilePath $logPath -Append

# Update packages (using winget)
winget upgrade --all

# Install packages
winget install Git.Git
winget install wget
# gnome-terminal equivalent: Windows Terminal
winget install Microsoft.WindowsTerminal
# network-manager: Windows built-in
# qemu-guest-agent: not applicable
# net-tools: Windows built-in
# smbclient: Windows built-in
# dnsutils: Windows built-in
winget install iperf3
winget install Mozilla.Firefox
# rsyslog: Windows Event Viewer built-in

# Autoremove not directly applicable
