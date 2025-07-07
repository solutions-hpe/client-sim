@echo off
set /a count=0
set /a inuse=0
if exist "C:\Scripts\vhadapter.txt" del c:\Scripts\vhadapter.txt
copy \\10.79.254.5\storage\scripts\CLIENT_CL\SIMCONFIGS\%computername%.txt C:\Scripts\
echo Connecting to USB SERVER
 	for /f %%a in (c:\scripts\vhservers.txt) do (
 		C:\Progra~1\VirtualHere\vhui64.exe -t "MANUAL HUB ADD,"%%a -r %temp%\vhsrvconnect.txt
	)

del %temp%\vh*.txt
C:\Progra~1\VirtualHere\vhui64.exe -t LIST -r %temp%\vhactive.txt
setlocal ENABLEDELAYEDEXPANSION

REM Looking to see if there is a device already assigned to client. If so skipping connection.
REM VirtualHere does not seem to play well when there are constant connects/disconnects workaround for that
REM Script is using "ACL" to find adapters that are available or already reserved.  To change use find/replace on the defined string.
	for /f "tokens=2 delims=()" %%a in ('findstr /n "you" %temp%\vhactive.txt') do (
		set /a inuse=inuse+1
		set USB=%%a
		echo !USB! > C:\Scripts\%computername%.txt
)

if %inuse% equ 1 (
	Echo Uploading Config file to Server - Search
	copy C:\Scripts\%computername%.txt \\10.79.254.5\storage\scripts\CLIENT_CL\SIMCONFIGS\
	goto end
	)

if exist "C:\Scripts\%computername%.txt" (
	timeout /t 2
	echo Found Existing Connection
 	for /f %%a in (c:\scripts\%computername%.txt) do (
 		set USB=%%a
		C:\Progra~1\VirtualHere\vhui64.exe -t "AUTO USE DEVICE PORT,"!USB! -r %temp%\vhconnect.txt
		echo Connecting to Previous Adapter !USB!
		echo Uploading Config file to Server - Local Config Found
		copy C:\Scripts\%computername%.txt \\10.79.254.5\storage\scripts\CLIENT_CL\SIMCONFIGS\
		goto end
			)
	)

if %inuse% gtr 1 (
	C:\Progra~1\VirtualHere\vhui64.exe -t "AUTO USE CLEAR ALL" -r %temp%\vhdisconnect.txt
	C:\Progra~1\VirtualHere\vhui64.exe -t "STOP USING ALL LOCAL" -r %temp%\vhdisconnect.txt
	set /a inuse=0
	del C:\Scripts\%computername%.txt
	)

Echo %inuse%

REM Counting the number of devices that are available
for /f "tokens=2 delims=()" %%a in ('findstr /v ": USB2.0 In-use" %temp%\vhactive.txt') do (
	set /a count=count+1
)

set /a rn=%random% %%count%

C:\Progra~1\VirtualHere\vhui64.exe -t "AUTO USE CLEAR ALL" -r %temp%\vhdisconnect.txt
C:\Progra~1\VirtualHere\vhui64.exe -t "STOP USING ALL LOCAL" -r %temp%\vhdisconnect.txt

if %inuse% equ 0 (
	for /f "tokens=2 delims=()" %%a in ('findstr /v ": In-use" %temp%\vhactive.txt') do (
		set USB=%%a
		set /a loop+=1
		Echo Writing Adapter to Config File
		echo !USB! > C:\Scripts\%computername%.txt
		Echo Uploading Config file to Server
		copy C:\Scripts\%computername%.txt \\10.79.254.5\storage\scripts\CLIENT_CL\SIMCONFIGS\
		if %count%==1 C:\Progra~1\VirtualHere\vhui64.exe -t "AUTO USE DEVICE PORT,"!USB! -r %temp%\vhconnect.txt
		if !loop!==%rn% C:\Progra~1\VirtualHere\vhui64.exe -t "AUTO USE DEVICE PORT,"!USB! -r %temp%\vhconnect.txt
	)
	goto end
)
:end
Echo Connection Complete