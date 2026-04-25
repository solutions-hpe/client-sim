# PowerShell script to monitor system logs in a new window
# Equivalent to journalctl -f in Linux

# Open a new PowerShell window for monitoring with specific size and position
Start-Process powershell -ArgumentList "-NoExit", "-Command", @"
# Set window size using mode command
cmd /c 'mode con: cols=140 lines=20'
Start-Sleep 1
try {
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
    # Set window position (0,0 in pixels)
    [Win32]::SetWindowPos([Win32]::GetConsoleWindow(), 0, 0, 0, 0, 0, 0x0040)
} catch {
    Write-Host "Failed to set window position: $_"
}
while (`$true) {
    Get-WinEvent -LogName System -MaxEvents 10 | Select-Object TimeCreated, LevelDisplayName, Message | Format-Table -AutoSize
    Start-Sleep 5
}
"@
