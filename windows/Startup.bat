@echo off
set /a rn=%random% %%21600+21600
Echo Scheduling Reboot
shutdown -f -r -t %rn%
Echo Removing Block from files copied
powershell "unblock-file c:\Scripts\*.*"
Echo Updating Group Policy
gpupdate /force
Echo Updating local scripts and stopping services that drain CPU
call c:\scripts\updatescripts.bat
Echo Waiting for Scripts to copy
Echo Removing Block from files copied
timeout /t 5
powershell "unblock-file c:\Scripts\*.*"
Echo Running cleanup process
powershell -command "start-process powershell 'c:\scripts\Cleanup.ps1' -Verb RunAs -WindowStyle Minimized"
powershell -command "start-process powershell 'rename-netadapter -Name "Eth*" -NewName "MGMT"' -Verb RunAs -WindowStyle Minimized"
Echo Setting menu context back to classic style and disabling news feed
powershell -command "start-process powershell 'reg.exe add "HKCU\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32" /f /ve' -Verb RunAs -WindowStyle Minimized"
powershell -command "start-process powershell 'reg.exe add "HKLM\SOFTWARE\Microsoft\PolicyManager\default\NewsAndInterests" /v "AllowNewsAndInterests" /t REG_DWORD /d "0" /f' -Verb RunAs -WindowStyle Minimized"
powershell -command "start-process powershell 'reg.exe add "HKLM\SOFTWARE\Policies\Microsoft\Dsh" /v "AllowNewsAndInterests" /t REG_DWORD /d "0" /f' -Verb RunAs -WindowStyle Minimized"
powershell -command "start-process powershell 'reg.exe add "HKCU\Software\Microsoft\Windows\CurrentVersion\Feeds" /v "IsFeedsAvailable"  /t REG_DWORD /d "0" /f' -Verb RunAs -WindowStyle Minimized"
powershell -command "start-process powershell 'reg.exe add "HKCU\Software\Microsoft\Windows\CurrentVersion\Feeds\FeedRepositoryState" /v "FeedEnabled"  /t REG_DWORD /d "0" /f' -Verb RunAs -WindowStyle Minimized"
powershell -command "start-process powershell 'reg.exe add "HKCU\Software\Microsoft\Windows\CurrentVersion\Policies\Attachments" /v "SaveZoneInformation"  /t REG_DWORD /d "1" /f' -Verb RunAs -WindowStyle Minimized"
Echo Checking for ready.txt - if exists this is a CC clients and launch CC WSL process
if exist "C:\Scripts\ready.txt" (
	echo Starting WSL
	powershell -command "start-process powershell 'wsl' -Verb RunAs -WindowStyle Minimized"
	exit /b
	)
Echo ready.txt does not exist - legacy scripts launching (no CC)
Echo Connecting Adapter
call c:\scripts\ConnectUSB.bat
if not x%computername:DXP-IMAGE=%==x%computername% goto exit_script
if not x%computername:USER-=%==x%computername% goto exit_script
if not x%computername:DXPADMI=%==x%computername% goto exit_script
if not x%computername:ACLI-WAC1=%==x%computername% goto test_loop
:test_loop
rem Initial Powershell Startup script takes a while to cleanup the device manager, less than 2 minutes and the scripts will step on each other
Echo Waiting for System Start - 2 Minutes
timeout /t 120
Echo Launching testing loop
start /wait C:\Scripts\test.bat
goto test_loop