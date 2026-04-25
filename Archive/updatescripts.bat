@Echo off
copy \\nas.arubademo.net\storage\scripts\KVM_CL\*.* C:\Scripts /y
copy \\nas.arubademo.net\storage\scripts\CLIENT_CL\*.* C:\Scripts /y
Echo Removing Block from files copied
timeout /t 5
powershell "unblock-file c:\Scripts\*.*"
Echo Stopping windows processes that take up extra CPU
net stop dps
net stop DiagTrack