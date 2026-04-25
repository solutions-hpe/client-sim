# PowerShell script to monitor simulation logs in a new window
# Equivalent to tail -f /usr/local/scripts/sim.log in Linux

# Open a new PowerShell window for monitoring with specific size and position
Start-Process powershell -ArgumentList "-NoExit", "-Command", @"
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class Win32 {
    [DllImport("user32.dll")]
    public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);
    [DllImport("user32.dll")]
    public static extern IntPtr GetConsoleWindow();
}
'@
# Set window size (35 columns x 15 rows, approximate pixels)
`$host.UI.RawUI.WindowSize = New-Object System.Management.Automation.Host.Size(35,15)
`$host.UI.RawUI.BufferSize = New-Object System.Management.Automation.Host.Size(35,100)
# Set window position (0,525 in pixels)
[Win32]::SetWindowPos([Win32]::GetConsoleWindow(), 0, 0, 525, 0, 0, 0x0040)
Get-Content -Path 'C:\Scripts\sim.log' -Wait
"@
