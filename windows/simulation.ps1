# -------------------------
# Simulation Script (Infinite Loop - Safe)
# -------------------------

$version = "0.92"
$logPath = "C:\Scripts\sim.log"

function Log($msg) {
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

    # ---- Kill switch (file-based) ----
    if (Test-Path "C:\Scripts\kill.flag") {
        Log "Kill switch detected. Exiting simulation loop."
        break
    }

    $network_ok = Network-Controller

    if (-not $network_ok) {
        Log ("Cycle {0}: network unstable" -f $cycle)
    }

    # ---- Optional workload scripts (safe execution) ----
    foreach ($script in @("dns_fail.ps1","download.ps1","iperf.ps1")) {
        if (Test-Path $script) {
            try {
                . .\$script
            } catch {
                Log ("Script {0} failed: {1}" -f $script, $_.Exception.Message)
            }
        }
    }

    # ---- Sleep control ----
    Start-Sleep (Get-Random -Minimum 3 -Maximum 10)

    $cycle++
}

Log "Simulation stopped"