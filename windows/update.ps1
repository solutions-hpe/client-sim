# PowerShell equivalent of update.sh
$version = "0.21"
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
    # Using remote GitHub repo
    Push-Location (Get-Item $PROFILE).Directory

    # Clone or update the repo
    if (Test-Path "client-sim") {
        Push-Location client-sim
        git switch $repo_branch
        git pull origin --ff-only
    } else {
        git clone $repo_location
        Push-Location client-sim
        git switch $repo_branch
    }

    # Copy files from windows folder to active script repo
    Copy-Item "windows\*.ps1" "C:\Scripts\" -Force
    Copy-Item "windows\*.txt" "C:\Scripts\" -Force
    Copy-Item "windows\*.conf" "C:\Scripts\" -Force
    Copy-Item "windows\*.xml" "C:\Scripts\" -Force

    # Copy simulation config
    Copy-Item "configs\simulation.conf" "C:\Scripts\simulation.conf" -Force

    # Set permissions (Windows ACL)
    $acl = Get-Acl "C:\Scripts"
    $acl.Access | ForEach-Object { $acl.RemoveAccessRule($_) }
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule("BUILTIN\Users", "Modify", "ContainerInherit,ObjectInherit", "None", "Allow")
    $acl.AddAccessRule($rule)
    Set-Acl "C:\Scripts" $acl

    Pop-Location
    Pop-Location
} else {
    # Local SMB repo
    $smb_location = get_value 'address' 'smb_location'
    # Using New-PSDrive for SMB
    New-PSDrive -Name S -PSProvider FileSystem -Root $smb_location -Credential (Get-Credential -Message "SMB Credentials") -ErrorAction SilentlyContinue
    Copy-Item "S:\Scripts\*" "C:\Scripts\" -Recurse -Force
}

"End Updating Scripts" | Tee-Object -FilePath $logPath -Append
