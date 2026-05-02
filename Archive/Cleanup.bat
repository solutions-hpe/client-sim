@Echo off
rem cleaning up old wifi information
rem if not x%computername:ACLI-WAC=%==x%computername% netsh wlan delete profile AnyCorpInc-MIA-PSK
rem if not x%computername:ACLI-WAC=%==x%computername% netsh wlan delete profile AnyCorpInc-DFW-PSK
rem if not x%computername:ACLI-WAC=%==x%computername% netsh wlan delete profile AnyCorp-PSK
netsh wlan delete profile AnyCorpInc-MIA-PSK
netsh wlan delete profile AnyCorpInc-DFW-PSK
netsh wlan delete profile AnyCorpInc-IND-PSK
netsh wlan delete profile AnyCorpInc-BOM-PSK
netsh wlan delete profile AnyCorpInc-SEA-PSK
netsh wlan delete profile AnyCorpInc-CDG-PSK
netsh wlan delete profile AnyCorpInc-BSB-PSK
netsh wlan delete profile ANyCorpInc-BSB-PSK
netsh wlan delete profile AnyCorpInc-ICN-PSK
netsh wlan delete profile AnyCorpInc-LHR-PSK
netsh wlan delete profile AnyCorpInc-MB-PSK
netsh wlan delete profile AnyCorp-PSK
netsh wlan delete profile AnyCorp-DEN-PSK
rem Deleting Old Scripts
del C:\Scripts\iperf.bat
del C:\Scripts\test.zip
del C:\Scripts\ACLI*.xml
del C:\Scripts\ACL-DEN*.xml
del C:\Scripts\ACL-PSK.xml
del C:\ProgramData\Microsoft\Windows\StartM~1\Programs\Startup\VirtualHere.lnk
exit