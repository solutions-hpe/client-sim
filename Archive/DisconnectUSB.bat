@echo off
	C:\Progra~1\VirtualHere\vhui64.exe -t "AUTO USE CLEAR ALL" -r %temp%\vhdisconnect.txt
	C:\Progra~1\VirtualHere\vhui64.exe -t "STOP USING ALL LOCAL" -r %temp%\vhdisconnect.txt
	del \\10.79.254.5\storage\scripts\CLIENT_CL\SIMCONFIGS\%computername%.txt 
	del C:\Scripts\%computername%.txt