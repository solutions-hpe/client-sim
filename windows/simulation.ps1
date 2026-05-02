$version = "0.91-safe"
$logPath = "C:\Scripts\sim.log"

function Log($msg) {
    $msg | Tee-Object -FilePath $logPath -Append
}

function Safe($msg, $args) {
    if ($args -ne $null) {
        return ($msg -f $args)
    }
    return $msg
}

function Test-Network {
    try {
        return Test-NetConnection -ComputerName "8.8.8.8" -InformationLevel Quiet
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
# MAIN LOOP
# -------------------------

Log "------------------------------"
Log ("Simulation Script {0}" -f $version)

for ($i = 1; $i -le 100; $i++) {

    $network_ok = Network-Controller

    if (-not $network_ok) {
        Log ("cycle {0}: network unstable" -f $i)
    }

    Start-Sleep (Get-Random -Minimum 2 -Maximum 8)
}

Log "Simulation complete"