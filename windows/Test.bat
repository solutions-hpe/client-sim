@echo off
setlocal enabledelayedexpansion
Echo Starting 802.1x Service
powershell -command "start-process powershell 'net start dot3svc' -Verb RunAs -WindowStyle Minimized"
Echo Cleaning up WLAN SSID Profiles
rem Deleting profile for Production Central SSID from Internal Central Clients (CNX)
start /min c:\scripts\cleanup.bat
rem Setting device type to generic - client will not do anything special just connect and basic traffic
set sim="generic"
rem creating random number to trigger DHCP failures - this variable is regenerated in main loop on purpose
Echo Setting Variation to a random number
set /a variation=%random% %%59+1
rem OK TO EDIT BELOW
rem --------------------------------------------------------------------------
rem OK TO EDIT BELOW
rem Global Kill Switch
set kill_switch=off
rem Global Kill Switch
set shutdown_switch=off
rem Simulation Threshold 0/25/50/75/100
set /a simulation_load=100
rem Set to "ON" to trigger AI Insights "OFF" will not trigger the insight
set dhcp_fail_sim=on
set dns_fail_sim=on
set wired_fail_sim=on
set assoc_fail_sim=on
set pflap_sim=on
if %username%==DXPUser set domain_join=false & set auth_method=PSK
if not %username%==DXPUser set domain_join=true & set auth_method=1X
Echo Setting Variables
if not x%computername:ACLI-=%==x%computername% set env=acli

if not x%computername:WAC=%==x%computername% set os=win
if not x%computername:WAC2=%==x%computername% set class=t2
if not x%computername:WAC1=%==x%computername% set class=t1
if not x%computername:ACL=%==x%computername% set wsite=generic
Echo Setting Device type for Central Live Internal
if not x%computername:ACLI-WAC20=%==x%computername% if %simulation_load% GEQ 50 set sim=dns_fail
if not x%computername:ACLI-WAC30=%==x%computername% if %simulation_load% GEQ 75 set sim=dns_fail
if not x%computername:ACLI-WAC40=%==x%computername% if %simulation_load% GEQ 100 set sim=dns_fail
if not x%computername:ACLI-WAC4212=%==x%computername% if %simulation_load% GEQ 100 set sim=wired_fail
if not x%computername:ACLI-WAC4231=%==x%computername% if %simulation_load% GEQ 25 set sim=wired_fail
if not x%computername:ACLI-WAC4245=%==x%computername% if %simulation_load% GEQ 50 set sim=wired_fail
if not x%computername:ACLI-WAC4296=%==x%computername% if %simulation_load% GEQ 75 set sim=wired_fail
if not x%computername:ACLI-WAC4297=%==x%computername% if %simulation_load% GEQ 100 set sim=wired_fail
if not x%computername:ACLI-WAC202=%==x%computername% if %simulation_load% GEQ 75 set sim=assoc_fail
if not x%computername:ACLI-WAC212=%==x%computername% if %simulation_load% GEQ 100 set sim=assoc_fail
if not x%computername:ACLI-WAC229=%==x%computername% if %simulation_load% GEQ 25 set sim=assoc_fail
if not x%computername:ACLI-WAC237=%==x%computername% if %simulation_load% GEQ 50 set sim=assoc_fail
Echo Setting Central Live Variables T2
if not x%computername:ACL-WAC200=%==x%computername% set wsite=DFW
if not x%computername:ACL-WAC201=%==x%computername% set wsite=DFW
if not x%computername:ACL-WAC202=%==x%computername% set wsite=MIA
if not x%computername:ACL-WAC203=%==x%computername% set wsite=LHR
if not x%computername:ACL-WAC204=%==x%computername% set wsite=LHR
if not x%computername:ACL-WAC205=%==x%computername% set wsite=LHR
if not x%computername:ACL-WAC206=%==x%computername% set wsite=LHR
if not x%computername:ACL-WAC207=%==x%computername% set wsite=LHR
if not x%computername:ACL-WAC208=%==x%computername% set wsite=LHR
if not x%computername:ACL-WAC209=%==x%computername% set wsite=LHR
if not x%computername:ACL-WAC210=%==x%computername% set wsite=LHR
if not x%computername:ACL-WAC211=%==x%computername% set wsite=LHR
if not x%computername:ACL-WAC212=%==x%computername% set wsite=MIA
if not x%computername:ACL-WAC213=%==x%computername% set wsite=CDG
if not x%computername:ACL-WAC214=%==x%computername% set wsite=SYN
if not x%computername:ACL-WAC215=%==x%computername% set wsite=DFW
if not x%computername:ACL-WAC216=%==x%computername% set wsite=LHR
if not x%computername:ACL-WAC217=%==x%computername% set wsite=BSB
if not x%computername:ACL-WAC218=%==x%computername% set wsite=MIA
if not x%computername:ACL-WAC219=%==x%computername% set wsite=MIA
if not x%computername:ACL-WAC220=%==x%computername% set wsite=DFW
if not x%computername:ACL-WAC221=%==x%computername% set wsite=MIA
if not x%computername:ACL-WAC222=%==x%computername% set wsite=DFW
if not x%computername:ACL-WAC223=%==x%computername% set wsite=MIA
if not x%computername:ACL-WAC224=%==x%computername% set wsite=DFW
if not x%computername:ACL-WAC225=%==x%computername% set wsite=MIA
if not x%computername:ACL-WAC226=%==x%computername% set wsite=DFW
if not x%computername:ACL-WAC227=%==x%computername% set wsite=MIA
if not x%computername:ACL-WAC228=%==x%computername% set wsite=DFW
if not x%computername:ACL-WAC229=%==x%computername% set wsite=MIA
if not x%computername:ACL-WAC230=%==x%computername% set wsite=DFW
if not x%computername:ACL-WAC231=%==x%computername% set wsite=MIA
if not x%computername:ACL-WAC232=%==x%computername% set wsite=DFW
if not x%computername:ACL-WAC233=%==x%computername% set wsite=MIA
if not x%computername:ACL-WAC234=%==x%computername% set wsite=DFW
if not x%computername:ACL-WAC235=%==x%computername% set wsite=MIA
if not x%computername:ACL-WAC236=%==x%computername% set wsite=DFW
if not x%computername:ACL-WAC237=%==x%computername% set wsite=MIA
if not x%computername:ACL-WAC238=%==x%computername% set wsite=DFW
Echo Setting Simulation Overrides
if not x%computername:ACL-WAC2183=%==x%computername% set sim=pflap
if not x%computername:ACL-WAC2332=%==x%computername% set sim=pflap
Echo Overriding site assignement for AX Reccomender
if not x%computername:ACLI-WAC2305=%==x%computername% set wsite=MIA
if not x%computername:ACLI-WAC2320=%==x%computername% set wsite=MIA
if not x%computername:ACLI-WAC2342=%==x%computername% set wsite=MIA
if not x%computername:ACLI-WAC2423=%==x%computername% set wsite=MIA
if not x%computername:ACLI-WAC2398=%==x%computername% set wsite=MIA
if not x%computername:ACLI-WAC2480=%==x%computername% set wsite=MIA
if not x%computername:ACLI-WAC2312=%==x%computername% set wsite=MIA
if not x%computername:ACLI-WAC2377=%==x%computername% set wsite=MIA
if not x%computername:ACLI-WAC2425=%==x%computername% set wsite=MIA
if not x%computername:ACLI-WAC2449=%==x%computername% set wsite=MIA
if not x%computername:ACLI-WAC2467=%==x%computername% set wsite=MIA
if not x%computername:ACLI-WAC2496=%==x%computername% set wsite=MIA
if not x%computername:ACLI-WAC2304=%==x%computername% set wsite=MIA
rem DO NOT EDIT BELOW
rem --------------------------------------------------------------------------
rem DO NOT EDIT BELOW
Echo Global Kill Switch is set to %kill_switch%
Echo Device Simulation is set to %sim%
Echo Device Environment is set to %env%
Echo Device OS is set to %os%
Echo Device Class is set to %class%
Echo Device WiFi Site is set to %wsite%
Echo Device DHCP Fail sim %dhcp_fail_sim%
Echo Device DNS Fail sim %dns_fail_sim%
Echo Device Port Flapp sim %pflap_sim%
Echo Device Wired Fail sim %wired_fail_sim%
Echo Device Association Fail sim %assoc_fail_sim%
Echo Simulation Load at %simulation_load%
Echo Domain Join Status %domain_join%
Echo Authentication Method %auth_method%
Echo Simulation Variation %variation%
Echo Shutdown Switch %shutdown_switch%
timeout /t 15
:setup_test
rem Updating Scripts after each simulation
Echo Updating local scripts and stopping services that drain CPU
call c:\scripts\updatescripts.bat
rem if random number at is 1 - will turn off DHCP failures - attempt to influence time travel 
if %variation% == 1 set dhcp_fail_sim=off
if %kill_switch% == on goto test_loop
if %shutdown_switch% == on shutdown -a
if %shutdown_switch% == on shutdown -f -s -t 0
echo Setting up WLAN SSID Profiles
rem If client is designated for association fail then go directly to the association loop
if %sim% == assoc_fail if %assoc_fail_sim% == on goto association_loop
rem Adding SSID to Internal Central Clients (CNX)
if %domain_join% == false netsh wlan add profile filename=C:\Scripts\%wsite%-PSK.xml user=all
if %domain_join% == false netsh wlan connect ssid=%wsite%-PSK name=%wsite%-PSK
if %domain_join% == true netsh wlan connect ssid=%wsite%-1x name=%wsite%-1x
echo netsh wlan add profile filename=C:\Scripts\%wsite%-PSK.xml user=all
rem If client is designated for DHCP fail then go directly to the DHCP Fail loop
if %sim% == dhcp_fail if %dhcp_fail_sim% == on goto dhcp_fail_setup
rem If client is set for DHCP Fail but that simulation is off then the mac address is reset back to default
if %sim% == dhcp_fail powershell -command "start-process powershell 'c:\scripts\mac-reset.ps1' -Verb RunAs -WindowStyle Minimized"
Echo Global Kill Switch is set to %kill_switch%
Echo Device Simulation is set to %sim%
Echo Device Environment is set to %env%
Echo Device OS is set to %os%
Echo Device Class is set to %class%
Echo Device WiFi Site is set to %wsite%
Echo Device DHCP Fail sim %dhcp_fail_sim%
Echo Device DNS Fail sim %dns_fail_sim%
Echo Device Port Flap sim %pflap_sim%
Echo Device Wired Fail sim %wired_fail_sim%
Echo Device Association Fail sim %assoc_fail_sim%
Echo Simulation Load at %simulation_load%
Echo Domain Join Status %domain_join%
Echo Authentication Method %auth_method%
Echo Website ID Number %web%
Echo Simulation Variation %variation%
Echo Shutdown Switch %shutdown_switch%
Echo Waiting for network connection
rem If client is designated for port flapping error go directly to port flap loop
if %sim% == pflap if %pflap_sim% == on goto port_flap
:start_test
Echo Killing FireFox Instances
cmd /c taskkill /f /im firefox.exe
rem creating random number to trigger different tests
set /a at=%random% %%14+1
rem Checking Network Connectivity - if fail then reconnect adapter don't use the firewall because of traffic shaping
Echo Pinging Boarder IP Loop Start_Test
ping 10.1.2.2 
ping 10.1.2.3
echo Error Level %ERRORLEVEL%
IF %ERRORLEVEL% == 1 goto connect_adapter
rem Random Number to only have problems sometimes variable is used in many tests
set /a rn=%random% %%30+60
Echo Waiting a random time to vary traffic pattern - %rn% seconds
timeout /t %rn%
goto launch_www
:www_return
Echo Running Random NSLOOKUP on domains
start /min c:\scripts\DNSRecSuccess.bat
rem Skipping DNS Failure tests for DFW Site - MIA should be the site with problems
if not %sim% == dns_fail goto end_dns
Echo Checked DNS sim is on
if %dns_fail_sim% == off goto test_loop
Echo Running NSLOOKUP Failures for AI Insights
set /a count=0
if %wsite% == MIA goto dns_loop
goto end_dns
:dns_loop
set /a count+=1
Echo Running Server Delay Script
start /min c:\scripts\DNSSrvDelay.bat
Echo Running Record Lookup Failure Script
start /min c:\scripts\DNSRecFail.bat
Echo Running Server Failure script
start /min c:\scripts\DNSSrvFail.bat
timeout /t 15
if %count% == 180 (
	goto end_dns
	)
	goto dns_loop
:end_dns
Echo Pinging Boarder IP Variation
ping 10.1.2.2 -n %variation%
ping 10.1.2.3 -n %variation%
curl -X POST -H "Content-Type: application/json" -H "Authorization: Bearer 123456789" -d '{"prompt":"Question","max_tokens":150}' https://api.openai.com/v1/engines/davinci/completions
curl -X POST -H "Content-Type: application/json" -H "Authorization: Bearer 123456789" -d '{"query":"Question"}' https://api.perplexity.ai/v1/query
if %variation% == 5 (
	Echo Downloading Ubuntu with curl
	curl -o %temp%\Ubuntu.gz http://archive.ubuntu.com/ubuntu/dists/bionic/Contents-i386.gz
	)
if %variation% == 10 (	
	Echo Downloading PDF File with curl
	curl -o %temp%\PDF10MB.pdf https://link.testfile.org/PDF10MB 
	)
if %variation% == 15 (
	Echo Downloading MP3 File with curl
	curl -o %temp%\Test.mp3 https://files.testfile.org/anime.mp3
	)
if %variation% == 1 goto test_loop
rem Skipping forward past association loop to rerun the test script
goto start_test
:association_loop
Echo Connecting Adapter
call c:\scripts\ConnectUSB.bat
Echo Waiting for VirtualHere adapter
timeout /t 120
netsh wlan delete profile %wsite%-PSK
if %assoc_fail_sim% == off goto test_loop
Echo Adding Failure PSK to interface
netsh wlan add profile filename=C:\Scripts\%wsite%-PSK-FAIL.xml user=all
timeout /t 5
powershell -command "start-process powershell 'c:\scripts\DisableIPv6.ps1' -Verb RunAs"
:association_start
netsh wlan add profile filename=C:\Scripts\%wsite%-PSK.xml user=all
netsh wlan connect ssid=%wsite%-PSK name=%wsite%-PSK
timeout /t 10
set /a count+=1
if %variation% == 1 (
	if %count% == 60 (
		goto start_test
		)
		goto association_loop
)
goto test_loop
:dhcp_fail_setup
if %dhcp_fail_sim% == on powershell -command "start-process powershell 'c:\scripts\mac-change.ps1 %newmac%' -Verb RunAs -WindowStyle Minimized"
:dhcp_fail
if %domain_join% == false netsh wlan add profile filename=C:\Scripts\%wsite%-PSK.xml user=all
if %domain_join% == false netsh wlan connect ssid=%wsite%-PSK name=%wsite%-PSK
if %domain_join% == true netsh wlan connect ssid=%wsite%-1x name=%wsite%-1x
timeout /t 10
ipconfig /release Wi-Fi*
ipconfig /renew Wi-Fi*
set /a count+=1
	if %count% == 980 (
		goto start_test
		)
		goto dhcp_fail
goto test_loop
:port_flap
Echo Flapping Port for CNX Alert in MIA
powershell -command "start-process powershell 'c:\scripts\DisableInterface.ps1' -Verb RunAs -WindowStyle Minimized"
timeout /t 15
set /a count+=1
	if %count% == 980 (
		goto setup_test
		)
		goto port_flap
:connect_adapter
if %class% == t1-psk goto setup_test
if %class% == t1-1x goto setup_test
Echo Connecting Adapter
call c:\scripts\ConnectUSB.bat
Echo Waiting for VirtualHere adapter
timeout /t 120
Echo Setting up WLAN SSID Profiles
if %sim% == wired_fail goto wired_fail
if %wsite% == DEN netsh wlan add profile filename=C:\Scripts\ACL-%wsite%-PSK.xml user=all
if %domain_join% == true netsh wlan connect ssid=%wsite%-1x name=%wsite%-1x
if %domain_join% == false netsh wlan add profile filename=C:\Scripts\ACLI-%wsite%-PSK.xml user=all
if %domain_join% == false timeout /t 5
if %domain_join% == false netsh wlan connect ssid=%wsite%-PSK name=%wsite%-PSK
if %domain_join% == false timeout /t 15
timeout /t 60
rem Checking Network Connectivity - if fail then reboot
Echo Pinging Boarder IP Connect Adapter
ping 10.1.2.2
ping 10.1.2.3
 IF %ERRORLEVEL% == 1 (
  	SHUTDOWN -A
	cmd /c taskkill /f /im firefox.exe
	Echo Resetting Virtual Here Settings to default
	copy \\10.79.254.5\storage\scripts\vhui.ini c:\users\dxpuse~1\appdata\Roaming\ /Y
	Echo Clearing old adatper config file
	del C:\Scripts\vhadapter.txt
	c:\Scripts\DisconnectUSB.bat
    Echo Waiting for reboot
	timeout /t 20
  	SHUTDOWN -R -F -T 0
 )
goto setup_test
:wired_fail
Echo Killing Processes
powershell -command "start-process powershell 'Get-Process -Name "*Edge*" | Stop-Process' -Verb RunAs -WindowStyle Minimized"
set /a count+=1
Echo Starting 802.1x Service
powershell -command "start-process powershell 'net start dot3svc' -Verb RunAs -WindowStyle Minimized"
Echo Sleeping 60 Seconds
timeout /t 60
Echo Stopping 802.1x Service
powershell -command "start-process powershell 'net stop dot3svc' -Verb RunAs -WindowStyle Minimized"
Echo Sleeping 5 Seconds
timeout /t 5
Echo Sleeping 5 Seconds
if %count% == 180 goto test_loop
goto wired_fail
:test_loop
Echo Sleeping for 60 seconds
timeout /t 60
Echo Launching test loop
call c:\scripts\test.bat
:launch_www
rem Counting the records in the www.txt file
rem goto www_return
set /a records=0
for /f %%a in (c:\scripts\www.txt) do (
 		set /a records=records+1
	)
rem Generating a random number from 1 to the number of records in the www.txt file. This will select a random website to open on the client
set /a rnwww=%random% %%records%
rem Launching Firefox in headless mode to a website in the www.txt file
set www=https://www.google.com
echo Launching website
for /f %%a in (c:\scripts\www.txt) do (
		set /a wloop=wloop+1
		if !wloop! == %rnwww% echo %%a
		if !wloop! == %rnwww% start /min cmd /c "C:\Program Files\Mozilla Firefox\FireFox.exe " %%a --headless 
	)
goto www_return
exit /B