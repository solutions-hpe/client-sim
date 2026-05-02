powershell "unblock-file C:\Scripts*.*"
cmd /c sc config dps start= disabled
cmd /c sc config DiagTrack start= disabled
cmd /c sc config dot3svc start= auto
net stop dps
net stop DiagTrack
start-sleep -Seconds 15
#Only enable when new version of VH needs to be deployed or when core VirtualHere changes need to be pushed
#Enabling this will cause a long delay in connecting to Virtual Here and make the scripts slow
#net stop vhclient
#cmd /c copy \\10.79.254.5\storage\scripts\vhui64.exe c:\progra~1\VirtualHere\ /Y
#cmd /c copy \\10.79.254.5\storage\scripts\vhui.ini c:\users\dxpuse~1\appdata\Roaming\ /Y
#net start vhclient
powershell "unblock-file c:\progra~1\VirtualHere\*.*"
powershell "unblock-file c:\users\dxpuse~1\appdata\Roaming\*.*"
net start dot3svc
start-sleep -Seconds 30

pnputil /remove-device /deviceid "USB\VID_2357&PID_012D"
pnputil /remove-device /deviceid "USB\VID_0B95&PID_1790"

$Devs = Get-PnpDevice | ? Status -eq Unknown | Select FriendlyName,InstanceId

ForEach ($Dev in $Devs) {
$RemoveKey = "HKLM:\SYSTEM\CurrentControlSet\Enum\$($Dev.InstanceId)"
Get-Item $RemoveKey | Select-Object -ExpandProperty Property | %{ Remove-ItemProperty -Path $RemoveKey -Name $_ -Verbose }
}

$Devs = Get-PnpDevice | ? Status -eq error | Select FriendlyName,InstanceId

ForEach ($Dev in $Devs) {
$RemoveKey = "HKLM:\SYSTEM\CurrentControlSet\Enum\$($Dev.InstanceId)"
Get-Item $RemoveKey | Select-Object -ExpandProperty Property | %{ Remove-ItemProperty -Path $RemoveKey -Name $_ -Verbose }
}

pnputil /scan-devices

#cmd /c sfc /scannow
#cmd /c dism /online /cleanup-image /restorehealth
