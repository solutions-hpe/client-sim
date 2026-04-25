# PowerShell equivalent of update.sh
$version = "0.24"
$logPath = "C:\Scripts\sim.log"
"Update Script Version $version" | Tee-Object -FilePath $logPath -Append
Get-Date | Tee-Object -FilePath $logPath -Append

"Reading Simulation Config File" | Tee-Object -FilePath $logPath -Append
. .\ini-parser.ps1
$global:iniConfig = Parse-IniFile 'C:\Scripts\simulation.conf'

$public_repo = get_value 'simulation' 'public_repo'
$repo_location = get_value 'simulation' 'repo_location'
$repo_branch = get_value 'simulation' 'repo_branch'

"Updating Scripts" | Tee-Object -FilePath $logPath -Append
if ($public_repo -eq "on") {
    Push-Location $env:USERPROFILE
    if (Test-Path "client-sim") {
        Push-Location client-sim
        git config --global http.lowSpeedLimit 1000
        git config --global http.lowSpeedTime 60
        git switch $repo_branch
        git pull --ff-only
    } else {
        git clone $repo_location
        Push-Location client-sim
        git switch $repo_branch
    }
    Push-Location windows
    Copy-Item "*.ps1" "C:\Scripts\" -Force
    Copy-Item "*.txt" "C:\Scripts\" -Force
    Copy-Item "*.conf" "C:\Scripts\" -Force
    Copy-Item "*.xml" "C:\Scripts\" -Force
    Pop-Location
    Push-Location configs
    Copy-Item "simulation.conf" "C:\Scripts\simulation.conf" -Force
    Pop-Location
    $acl = Get-Acl "C:\Scripts"
    $acl.Access | ForEach-Object { $acl.RemoveAccessRule($_) }
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule("BUILTIN\Users", "Modify", "ContainerInherit,ObjectInherit", "None", "Allow")
    $acl.AddAccessRule($rule)
    Set-Acl "C:\Scripts" $acl
    Pop-Location
    Pop-Location
} else {
    # Local SMB repo
    # Equivalent to smbclient: Use PowerShell SMB cmdlets or net use
    # Example: Copy-Item from SMB share
}
