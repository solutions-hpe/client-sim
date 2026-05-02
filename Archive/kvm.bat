@echo off

copy \\nas.arubademo.net\storage\scripts\CLIENT_CL\*.* C:\Scripts /y
powershell "unblock-file c:\Scripts\*.*"
powershell -command "start-process powershell 'c:\scripts\Cleanup.ps1' -Verb RunAs"

If /I %1 == password goto password
If /I %1 == hostname goto hostname
If /I %1 == ipv4 goto ipv4
If /I %1 == ipv4_dns goto ipv4_dns
If /I %1 == ipv4_gw goto ipv4_gw
If /I %1 == ipv6 goto ipv6
If /I %1 == ipv6_dns goto ipv6_dns
If /I %1 == ipv6_gw goto ipv6_gw
If /I %1 == reboot goto reboot
If /I %1 == shutdown goto shutdown
If /I %1 == joindomain goto joindomain
If /I %1 == setautologon goto setautologon
If /I %1 == AppUninstall goto AppUninstall
If /I %1 == wslinstall goto wslinstall
If /I %1 == wslsetup goto wslsetup
If /I %1 == wslupdate goto wslupdate
If /I %1 == addroute goto addroute
If /I %1 == wslconfigure goto wslconfigure
If /I %1 == wslrestore goto wslrestore

:ipv4
netsh interface ipv4 set address name="Ethernet" source=static addr=%2 mask=%3
REM exit applications
echo "IPv4: %2 / %3"
exit /B

:ipv4_dns
netsh interface ipv4 set dnsservers "Ethernet" static %2 primary
REM exit applications
echo "IPv4 DNS: %2"
exit /B

:ipv4_gw
netsh interface ipv4 add address "Ethernet" gateway=%2 gwmetric=0
REM exit applications
echo "IPv4 Gateway: %2"
exit /B

:ipv6
netsh interface ipv6 set address Ethernet address=%2/%3
REM exit applications
echo "IPv6: %2 / %3"
exit /B

:ipv6_dns
netsh interface ipv6 set dnsservers "Ethernet" static %2 primary
REM exit applications
echo "IPv6 DNS: %2"
exit /B

:ipv6_gw
netsh interface ipv6 add route ::/0 Ethernet %2
REM exit applications
echo "IPv6 Gateway: %2"
exit /B

:hostname
WMIC computersystem where caption='%COMPUTERNAME%' rename '%2'
REM exit applications
echo "Hostname is now: %2.%3"
exit /B

:password
net user %2 %3
REM exit applications
echo "User: %2 Password is now: %3"
exit /B

:reboot
shutdown /a
shutdown /r /t 0
REM exit applications
echo "VM is rebooting"
exit /B

:shutdown
shutdown /a
shutdown /s /t 0
REM exit applications
echo "VM is shutting down"
exit /B

:joindomain
shutdown -a
powershell -command "start-process powershell 'c:\scripts\JoinDomain.ps1' -Verb RunAs"
echo "Machine Added to Domain"
exit /B

:setautologon
echo "Setting AutoLogon Registry Keys"
reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v DefaultDomainName /d ANYCORP /t REG_SZ /f
reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v DefaultUserName /d %2 /t REG_SZ /f
reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v DefaultPassword /d %3 /t REG_SZ /f
reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v AutoAdminLogon /d 1 /t REG_SZ /f
timeout /t 120
echo "Rebooting"
shutdown /a
shutdown /r /t 0
exit /B

:AppUninstall
powershell -command "start-process powershell 'c:\scripts\AppUninstall.ps1' -Verb RunAs"
timeout /t 480
exit /B

:wslinstall
powershell -command "start-process powershell 'dism.exe /online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux /all /norestart'  -Verb RunAs"
powershell -command "start-process powershell 'dism.exe /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart'  -Verb RunAs"
powershell -command "start-process powershell 'dism.exe /online /enable-feature /featurename:HypervisorPlatform /all /norestart'  -Verb RunAs"

timeout /t 240
exit /B

:wslsetup
powershell -command "start-process powershell 'wsl --set-default-version 2'  -Verb RunAs"
timeout /t 120
exit /B

:wslupdate
powershell -command "start-process powershell 'wsl --update'  -Verb RunAs"
timeout /t 120
exit /B

:wslconfigure
powershell -command "start-process powershell 'wsl --install --no-distribution'  -Verb RunAs"
timeout /t 120
exit /B

:wslrestore
copy \\10.79.254.5\storage\scripts\WSL.tar c:\Scripts
powershell -command "start-process powershell 'wsl --import Ubuntu-22.04 C:\WSL C:\Scripts\WSL.tar'  -Verb RunAs"
timeout /t 120
del C:\Scripts\WSL.tar
wsl -s Ubuntu-22.04 --exec "echo %computername% | sudo tee /etc/hostname"
timeout /t 30
wsl.exe shutdown
type nul > C:\Users\DXPUser\AppData\Local\Temp\ready.txt
exit /B

:addroute
powershell -command "start-process powershell 'cmd /c route add 0.0.0.0 mask 0.0.0.0 10.255.244.1 metric 1'  -Verb RunAs"
exit /B