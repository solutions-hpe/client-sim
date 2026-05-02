# -------------------------
# Simulation Script (Infinite + Log Rotation)
# -------------------------

$version = "0.93"
$logPath = "C:\Scripts\sim.log"
$maxLogSize = 10MB   # 10 MB limit

function Rotate-LogIfNeeded {

    if (Test-Path $logPath) {
        try {
            $size = (Get-Item $logPath).Length

            if ($size -ge $maxLogSize) {

                # Keep last 50% of file
                $content = Get-Content $logPath -Tail 5000

                Set-Content -Path $logPath -Value $content

            }
        } catch {
            # If rotation fails, don't crash simulation
        }
    }
}

function Log($msg) {

    Rotate-LogIfNeeded

    $msg | Tee-Object -FilePath $logPath -Append
}

function Test-Network {
    try {
        return Test-NetConnection -ComputerName "8.8.8.8" -InformationLevel Quiet -WarningAction SilentlyContinue
    } catch {
        return $false
    }
}

# -------------------------
# NETWORK CONTROLLER
# -------------------------

function Network-Controller {

    $ok = Test-Network

    if ($ok) {
        Log "Network OK"
        return $true
    }

    Log "Network FAILED"
    return $false
}

# -------------------------
# MAIN LOOP (INFINITE)
# -------------------------

Log "------------------------------"
Log ("Simulation Script {0}" -f $version)
Log ("Start Time: {0}" -f (Get-Date))

$cycle = 1

while ($true) {

    # ---- Kill switch ----
    if (Test-Path "C:\Scripts\kill.flag") {
        Log "Kill switch detected. Exiting simulation loop."
        break
    }

    $network_ok = Network-Controller

    if (-not $network_ok) {
        Log ("Cycle {0}: network unstable" -f $cycle)
    }

    # ---- Optional scripts ----
    foreach ($script in @("dns_fail.ps1","download.ps1","iperf.ps1")) {
        if (Test-Path $script) {
            try {
                . .\$script
            } catch {
                Log ("Script {0} failed: {1}" -f $script, $_.Exception.Message)
            }
        }
    }

    Start-Sleep (Get-Random -Minimum 3 -Maximum 10)

    $cycle++
}

Log "Simulation stopped"