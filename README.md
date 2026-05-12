# client-sim

`client-sim` contains the spoke-side runtime for the HPE Client-Sim platform:

- the **spoke backend** (`webui-spoke/`)
- the **Proxmox host agent** (`proxmox/`)
- the **Linux simulation scripts** (`linux/`)
- related configs, Windows equivalents, and installer assets

This repo is the local execution plane. It can run standalone, or relay telemetry and commands to Hub.

---

## Operators

### What this repo provides

At an operational level, this repo gives you:

- a FastAPI spoke dashboard/API inside a Proxmox LXC
- a Proxmox host agent for VM, USB, and reclone operations
- Linux VM scripts that fetch config, run simulations, and report status
- watchdogs for both the spoke service and Proxmox agent
- configuration-driven simulation behavior using INI files

### Spoke installation (`webui-spoke/install-lxc.sh`)

#### What the installer does

`install-lxc.sh` is the spoke installer and updater. In the current repo it:

1. validates OS and flags
2. installs system packages
3. auto-detects a second NIC and configures `dnsmasq` DHCP when present
4. clones or updates the `client-sim` repo cache
5. deploys the spoke app files into `/opt/client-sim-dashboard`
6. fetches shared frontend assets from `cs-webui`
7. creates a Python virtual environment and installs `requirements.txt`
8. writes or updates `.env`
9. installs the `client-sim-dashboard` systemd service and web UI watchdog
10. starts or restarts the service

#### Prerequisites

Before you run it, have:

- a Debian or Ubuntu LXC
- root or `sudo` access
- outbound access to GitHub
- a Proxmox-attached second NIC if you want the isolated DHCP network
- the target branch decided (`lrb` for current development work)

#### Install commands

Standard install/update:

```bash
cd /opt/client-sim-repo/webui-spoke
sudo bash install-lxc.sh --branch lrb
```

Full wipe/reinstall:

```bash
cd /opt/client-sim-repo/webui-spoke
sudo bash install-lxc.sh --reinstall --branch lrb
```

Custom port example:

```bash
sudo bash install-lxc.sh --branch lrb --port 9000
```

#### What to verify after install

```bash
systemctl status client-sim-dashboard
curl http://localhost:8000/api/health
cat /var/log/client-sim-dashboard-install.log
```

### Proxmox agent installation (`proxmox/install-proxmox-agent.sh`)

#### What the installer does

The Proxmox agent installer:

1. downloads the latest agent, watchdog, and installer scripts from GitHub
2. installs the systemd service and timer units
3. writes `/etc/client-sim-proxmox-agent.env`
4. installs the VirtualHere USB client (`vhclientX`) and enables `virtualhereclient.service`
5. prepares watchdog state
6. enables and starts the service and watchdog timer
7. checks spoke API reachability

#### Step-by-step install

Run this on the **Proxmox host**, not inside the LXC.

1. Install from the repo or raw URL.

```bash
cd /opt/client-sim-repo/proxmox
sudo bash install-proxmox-agent.sh --server http://169.253.1.1:8000 --branch lrb
```

2. Check that the service started.

```bash
systemctl status client-sim-proxmox-agent
systemctl status proxmox-watchdog.timer
journalctl -u client-sim-proxmox-agent -f
```

3. Approve the agent from the spoke UI, or by API:

```bash
curl -X POST http://169.253.1.1:8000/api/proxmox/approve/<hostname>
```

4. Confirm the agent received a key and is posting telemetry.

```bash
cat /etc/client-sim-proxmox-agent.env
curl http://169.253.1.1:8000/api/proxmox/status
```

#### Common installer flags

| Flag | Meaning |
|---|---|
| `--server <url>` | Required spoke URL |
| `--key <api_key>` | Pre-seed an API key instead of waiting for approval |
| `--interval <seconds>` | Override poll interval |
| `--branch <name>` | Branch to pull scripts from |
| `--unattended` | Automation-friendly mode |
| `--skip-vh` | Skip VirtualHere client installation |

### VirtualHere auto-use sync

Once the Proxmox agent is approved and polling, it automatically syncs the VirtualHere client auto-use list from the hub's approved USB device list.

**How it works:**

1. The hub includes a `vh_auto_use_vidpids` list (sorted `vid:pid` strings) in the `/api/proxmox/usb-config` payload.
2. On each config poll, the agent computes a SHA-256 of the current list and compares it to the stored hash at `/var/lib/client-sim/vh-vidpid.hash`.
3. If the list changed, the agent:
   - stops `virtualhereclient.service`
   - writes `/root/.config/virtualhere/client.conf` with the new auto-use entries in Qt INI format
   - restarts `virtualhereclient.service`
   - saves the new hash

**Config file format** (`/root/.config/virtualhere/client.conf`):

```ini
[AutoUse]
1\VidPid=0451:16b6
2\VidPid=0451:16b7
size=2
```

To add VID:PID pairs, add them to the approved USB device list in the spoke UI under **VM Server → USB Config**. The agent picks up the change on its next config poll (default: 60 seconds).

To skip VH installation entirely, pass `--skip-vh` to the installer. The auto-use sync is a no-op if `virtualhereclient.service` is not installed.

### Configuration files

The two main operator-edited files are:

- `configs/simulation.conf`
- `configs/user-overrides.conf`

Resolution order on a client VM is:

```text
[simulation] globals
  -> [s0]-[s9] bucket profile selected from VMID digits
  -> [username] override from user-overrides.conf
  -> usb-phy-override.conf for sim_phy when provisioned by Proxmox agent
```

#### `simulation.conf` global keys

| Section | Key | Default in repo | Description |
|---|---|---:|---|
| `[simulation]` | `kill_switch` | `off` | Local emergency stop for the client loop |
| `[simulation]` | `rapid_update` | `on` | Run `update.sh` every loop instead of only at exec-restart checkpoints |
| `[simulation]` | `sim_load` | `100` | Probability/CPU-style load gate for enabled simulations |
| `[simulation]` | `github_repo` | `on` | Allow GitHub as an update source |
| `[simulation]` | `repo_location` | `https://github.com/solutions-hpe/client-sim/` | Git repo used by update logic |
| `[simulation]` | `repo_branch` | `lrb` | Branch used by client update logic |
| `[simulation]` | `smb_repo` | `off` | Enable SMB as a fallback update source |
| `[simulation]` | `vh_server` | `off` | Start/use VirtualHere workflow |
| `[simulation]` | `site_based_ssid` | `on` | Prefix `wsite-` to the SSID when connecting |
| `[simulation]` | `site_based_num` | `2` | Which VMID digit selects bucket `s0`-`s9` |
| `[simulation]` | `reboot_schedule` | `300` | Base reboot schedule in minutes |
| `[simulation]` | `allow_offline` | `no` | Take interfaces down for a random offline period between 100-iteration cycles |
| `[simulation]` | `ssidpw_fail` | `off` | Global default for wrong-PSK simulation |
| `[simulation]` | `auth_fail` | `off` | Global default for 802.1X auth-failure simulation |
| `[simulation]` | `dot1x_password` | `password` | Base 802.1X password |
| `[simulation]` | `dot1x_eap` | `peap` | 802.1X EAP method used by the DOT1X helper |
| `[simulation]` | `iperf_bw` | `1k` | iPerf target bandwidth |
| `[simulation]` | `syslog` | `on` | Forward logs to the configured syslog target |
| `[simulation]` | `web_server` | `on` | Use the spoke API as the primary source for config/scripts |

#### `simulation.conf` server and address keys

| Section | Key | Default in repo | Description |
|---|---|---:|---|
| `[server]` | `server_url` | `http://169.253.1.1:8000` | Spoke URL used by clients for health/config/scripts/status/inbox |
| `[address]` | `smb_address` | `//nas/scripts` | SMB fallback path for updates |
| `[address]` | `ping_address` | `172.31.201.3` | Ping target for traffic testing |
| `[address]` | `dns_latency_1` | `13.239.88.95` | DNS latency target 1 |
| `[address]` | `dns_latency_2` | `27.110.152.250` | DNS latency target 2 |
| `[address]` | `dns_latency_3` | `165.246.10.2` | DNS latency target 3 |
| `[address]` | `dns_bad_ip_1` | `10.0.0.1` | Bad DNS response IP 1 |
| `[address]` | `dns_bad_ip_2` | `172.16.0.1` | Bad DNS response IP 2 |
| `[address]` | `dns_bad_ip_3` | `192.168.0.1` | Bad DNS response IP 3 |
| `[address]` | `dns_bad_record_1` | `172.31.201.1` | Wrong-record target 1 |
| `[address]` | `dns_bad_record_2` | `172.31.202.2` | Wrong-record target 2 |
| `[address]` | `dns_bad_record_3` | `100.100.0.1` | Wrong-record target 3 |
| `[address]` | `iperf_server` | `172.31.201.135` | iPerf target |
| `[address]` | `syslog_server` | `169.253.1.5` | Remote syslog target |

#### Bucket-profile and user-override keys

These keys are valid in `[s0]`-`[s9]` bucket sections and in `[username]` sections inside `user-overrides.conf`.

| Key | Shipped example/default | Description |
|---|---|---|
| `central_check` | blank | Aruba Central alert/check id expected for this simulation |
| `wsite` | `DFW` or `MIA` in shipped sample | Site name used for SSID prefixing and Central correlation |
| `ssid` | `PSK` | Base SSID name |
| `ssidpw` | `PassW0rd!` | WPA PSK |
| `dhcp_fail` | `off` | DHCP-failure simulation |
| `dns_fail` | `on` in most shipped buckets | DNS-failure simulation |
| `ssidpw_fail` | `on` in the shipped user examples | Wrong-PSK authentication failure simulation |
| `auth_fail` | `off` in the shipped user examples | 802.1X authentication-failure simulation |
| `assoc_fail` | `off` | Association-failure simulation |
| `port_flap` | `off` | Wired port flap simulation |
| `ping_test` | `on` | ICMP traffic generation |
| `download` | `on` | HTTP download traffic generation |
| `www_traffic` | `on` | Browser/web traffic generation |
| `iperf` | `off` except `s2=on` in shipped sample | iPerf bandwidth generation |
| `sim_phy` | `wireless` | Expected physical medium |
| `l1` | `no` | If `yes`, Proxmox agent adds an L1 VLAN NIC for that bucket |
| `kill_switch` | `off` in user override examples | User-specific local kill switch override |
| `sim_load` | `100` in user override examples | User-specific load override |
| `github_repo` | `on` in user override examples | User-specific GitHub-source override |
| `repo_location` | repo URL in examples | User-specific update source override |
| `repo_branch` | `lrb` in examples | User-specific branch override |
| `vh_server` | `off` in examples | User-specific VirtualHere override |
| `site_based_ssid` | `on` in examples | User-specific SSID prefix override |
| `site_based_num` | `2` in examples | User-specific bucket-digit override |
| `reboot_schedule` | `300` in examples | User-specific reboot timing override |
| `iperf_bw` | `1k` in examples | User-specific iPerf target |
| `smb_address` | `//nas/scripts` in examples | User-specific SMB fallback path override |
| `ping_address` | `172.31.201.1` in examples | User-specific ping target override |
| `dns_latency_1` | `13.239.88.95` in examples | User-specific DNS latency target 1 override |
| `dns_latency_2` | `27.110.152.250` in examples | User-specific DNS latency target 2 override |
| `dns_latency_3` | `165.246.10.2` in examples | User-specific DNS latency target 3 override |
| `dns_bad_ip_1` | `10.0.0.2` in examples | User-specific bad DNS IP 1 override |
| `dns_bad_ip_2` | `172.16.0.2` in examples | User-specific bad DNS IP 2 override |
| `dns_bad_ip_3` | `192.168.0.2` in examples | User-specific bad DNS IP 3 override |
| `dns_bad_record_1` | `172.31.201.1` in examples | User-specific wrong-record target 1 override |
| `dns_bad_record_2` | `172.31.202.2` in examples | User-specific wrong-record target 2 override |
| `dns_bad_record_3` | `100.100.0.1` in examples | User-specific wrong-record target 3 override |
| `iperf_server` | `172.31.201.135` in examples | User-specific iPerf target override |
| `dot1x_password` | commented example | User-specific 802.1X password |
| `dot1x_eap` | commented example | User-specific 802.1X EAP method |

#### Shipped bucket summary

| Bucket | wsite | Key behavior in shipped repo |
|---|---|---|
| `s0` | `DFW` | DNS fail + ping/download/web |
| `s1` | `DFW` | Normal traffic profile |
| `s2` | `DFW` | DNS fail + iPerf + traffic |
| `s3` | `DFW` | DNS fail + traffic |
| `s4` | `MIA` | DNS fail + traffic |
| `s5` | `DFW` | DNS fail + traffic |
| `s6` | `MIA` | DNS fail + traffic |
| `s7` | `DFW` | DNS fail + traffic |
| `s8` | `MIA` | DNS fail + traffic |
| `s9` | `DFW` | Normal traffic profile |

#### `user-overrides.conf`

`user-overrides.conf` is optional and loaded after `simulation.conf`. Only set keys you want to override.

Example:

```ini
[slynch]
dns_fail=off
ssidpw_fail=on
wsite=DFW
```

### Watchdogs

#### Spoke watchdog

- timer unit: `webui-watchdog.timer`
- service unit: `webui-watchdog.service`
- log file: `/var/log/webui-watchdog.log`
- state counter: `/var/lib/webui-watchdog/state`

Checks:

```bash
systemctl status webui-watchdog.timer
systemctl status webui-watchdog.service
cat /var/log/webui-watchdog.log
```

Behavior:

- failure 1: log only
- failure 2: restart `client-sim-dashboard`
- failure 5+: rerun `install-lxc.sh --unattended`

#### Proxmox watchdog

- timer unit: `proxmox-watchdog.timer`
- service unit: `proxmox-watchdog.service`
- log file: `/var/log/proxmox-watchdog.log`
- state counter: `/var/lib/proxmox-watchdog/state`

Checks:

```bash
systemctl status proxmox-watchdog.timer
systemctl status proxmox-watchdog.service
cat /var/log/proxmox-watchdog.log
```

Behavior:

- failure 1: log/report failure
- failure 2: restart `client-sim-proxmox-agent`
- failure 5+: rerun the Proxmox agent installer

### Spoke WebUI and operator-useful API endpoints

#### Health and status

```bash
curl http://localhost:8000/api/health
curl http://localhost:8000/api/services/status
curl http://localhost:8000/api/system/health
curl http://localhost:8000/api/version
```

#### Client and config views

```bash
curl http://localhost:8000/api/clients
curl "http://localhost:8000/api/config?hostname=<client-hostname>"
curl http://localhost:8000/api/config/overrides
curl http://localhost:8000/api/config/parsed
curl "http://localhost:8000/api/scripts/list?platform=linux"
```

#### Proxmox views

```bash
curl http://localhost:8000/api/proxmox/status
curl http://localhost:8000/api/proxmox/pending
curl http://localhost:8000/api/proxmox/approved
curl http://localhost:8000/api/proxmox/reclone-status
curl http://localhost:8000/api/proxmox/usb-config
```

#### Relay and repo views

```bash
curl http://localhost:8000/api/repo/status
curl http://localhost:8000/api/relay/status
curl http://localhost:8000/api/relay/diag
```

#### Logs and maintenance

```bash
curl "http://localhost:8000/api/logs/history?lines=200&source=service"
curl -X POST http://localhost:8000/api/sync-now
curl -X POST http://localhost:8000/api/self-update
curl -X POST http://localhost:8000/api/update-all
```

### Troubleshooting

| Problem | What to check | Typical fix |
|---|---|---|
| Spoke UI is down | `systemctl status client-sim-dashboard` and `/api/health` | rerun `install-lxc.sh`, inspect `/var/log/client-sim-dashboard-install.log`, check watchdog log |
| Clients are not appearing | `curl /api/health`, `curl /api/clients`, client `server_url` | verify `server_url`, `web_server=on`, and client reachability to `169.253.1.1:8000` |
| Proxmox agent never connects | `systemctl status client-sim-proxmox-agent`, `curl /api/proxmox/pending` | approve the pending host, verify `/etc/client-sim-proxmox-agent.env`, then restart the agent |
| VM Server tab is empty | `curl /api/proxmox/status` | make sure the Proxmox agent is approved and posting telemetry |
| Commands stay queued | `curl /api/commands`, agent/client logs | confirm agent or client can poll `/api/inbox` and POST `/api/inbox/ack` |
| Central panel shows stale/empty data | `curl /api/central/status` | recheck Central credentials, site mappings, and monitored checks in Setup |
| Kill switch will not clear on a client | client `simulation.conf`, `kill_switch.txt`, client logs | turn off local kill switch, rerun update, or send restart; note global kill switch can override local state |
| USB device will not provision | `curl /api/proxmox/usb-config`, agent log, `/etc/client-sim-usb-state.conf` | add VID:PID to certified devices, verify expected `sim_phy`, and confirm the USB device is physically present |

---

## Developers

### Repository structure

```text
client-sim/
├── configs/         # simulation.conf and user-overrides.conf
├── linux/           # Linux client scripts
├── proxmox/         # Proxmox host agent, watchdog, units, installers
├── webui-spoke/     # FastAPI spoke backend, installer, watchdog, docs
├── windows/         # Windows equivalents
├── kill_switch.txt  # Global kill switch source file
└── CHANGELOG.md / VERSION.md / SECURITY.md
```

### `webui-spoke/server.py` architecture

#### Core responsibilities

`server.py` is the spoke control plane. It handles:

- serving the shared UI in `WEBUI_MODE=spoke`
- receiving VM status beacons
- exposing config and script download endpoints
- managing client and Proxmox command queues
- polling Aruba Central
- relaying telemetry to Hub when enabled
- tracking updates, reclones, VM watchdog state, and service logs
- broadcasting real-time state over `/ws`

#### Background tasks

The FastAPI lifespan boot starts these tasks:

- `sync_repo`
- `heartbeat_check`
- `central_token_manager`
- `central_poller`
- `check_for_update`
- `relay_loop`
- `client_history_saver`
- `expire_commands`
- `auto_recovery_check`
- `vm_watchdog_loop`
- `schedule_check`
- `gkill_switch_poller`
- `hourly_baseline_saver`
- `acme_renewal_loop`

#### Important persisted state

| File | Why it exists |
|---|---|
| `settings.json` | durable settings and approved keys |
| `state_cache.json` | restart recovery for last-known proxmox/central state |
| `command_queue.json` | local queued commands |
| `reclone_state.json` | long-running VM operation state |
| `relay_state.json` | hub relay connection state |
| `update_state.json` | installer/app update status |
| `vm_watchdog.json` | VM watchdog/autorecovery state |
| `central_history.jsonl` | Central alert history |
| `client_history.json` | client history persistence |
| `client_count_baseline.json` | client-count monitor baseline |

#### Main in-memory state families

- `clients`
- `proxmox_state`
- `central_status`
- `central_wireless_clients`
- `relay_state`
- `update_state`
- approved/pending Proxmox agent maps
- WebSocket connection list

### Proxmox agent architecture

#### What the agent owns

`proxmox/proxmox-agent.sh` runs on the Proxmox host and owns:

- host registration and API key persistence
- USB certification and assignment tracking
- VM inventory and node telemetry collection
- VM provisioning, recloning, deletion, and updates
- command polling/ACK handling
- self-update scheduling

#### State file format

The agent writes `/etc/client-sim-usb-state.conf` as tab-delimited lines:

```text
<vmid>	<bus_path>	<missing_since>	<image_num>	<vidpid>
```

That file is reloaded on every agent restart to reconstruct USB-to-VM mappings.

#### Runtime loops

- background telemetry sender every `TELEMETRY_INTERVAL`
- background inbox processor every `INBOX_INTERVAL`
- USB scan/provision loop in the main process
- periodic self-update check

#### USB tracking model

- certified devices come from spoke `/api/proxmox/usb-config`
- unknown devices are surfaced separately for operator review
- missing USB devices retain state until timeout
- `usb-phy-override.conf` is written inside guests so `sim_phy` matches the assigned USB class

### Simulation script architecture

#### Startup chain

```text
startup.sh
  -> sources ini-parser.sh
  -> loads simulation.conf and user-overrides.conf
  -> runs update.sh
  -> starts helper services
  -> launches simulation.sh
```

#### Main loop

`simulation.sh`:

- re-parses config on each exec restart
- fetches global kill switch live
- runs up to 100 iterations per cycle
- posts status/errors to `/api/status`
- triggers `update.sh` in rapid-update mode or at restart boundaries
- optionally goes offline between cycles when `allow_offline=on`
- finishes by `exec bash /usr/local/scripts/simulation.sh`

#### Kill switch behavior

- local `kill_switch` comes from `simulation.conf`
- global kill switch is fetched live from spoke `/api/kill-switch`, then upstream GitHub fallback
- if either is `on`, the script parks and waits for restart/reload

#### `SIGUSR1` restart model

`simulation.sh` installs a `USR1` trap that sets a restart flag.

`agent.sh` uses that for:

- `restart_sim`
- `kill_switch`

That avoids hard-killing the process and lets the VM loop exit cleanly into its normal exec-restart path.

### Adding a new inbox/agent command

#### VM-side command (`linux/agent.sh`)

1. Add the command producer in the spoke or hub.
2. Ensure it is returned by `/api/inbox`.
3. Add a new `case` branch in `linux/agent.sh`.
4. Perform the local action.
5. POST the result to `/api/inbox/ack`.

#### Proxmox-side command (`proxmox/proxmox-agent.sh`)

1. Add the command producer in the spoke or hub.
2. Teach `process_inbox()` / `execute_vm_command()` how to recognize it.
3. Implement the host action with `qm`, `pct`, or helper functions.
4. ACK success/failure back to the spoke.
5. Refresh telemetry if the command changes host or VM state.

### API reference (key endpoints)

#### Client-facing spoke endpoints

| Endpoint | Use |
|---|---|
| `GET /api/health` | basic reachability check |
| `POST /api/status` | VM heartbeat and error upload |
| `GET /api/config` | hostname-aware effective config download |
| `GET /api/config/overrides` | raw `user-overrides.conf` |
| `GET /api/scripts/list` | list platform files |
| `GET /api/scripts/{platform}/{filename}` | download one script |
| `GET /api/inbox` | VM command polling |
| `POST /api/inbox/ack` | VM command acknowledgement |
| `GET /api/kill-switch` | global/local kill switch value |

#### Operator/spoke UI endpoints

| Endpoint | Use |
|---|---|
| `GET /api/clients` | live client list |
| `POST /api/commands` / `GET /api/commands` | local command queue |
| `GET/POST /api/settings` | spoke settings |
| `GET /api/proxmox/status` | host, VM, USB, and reclone summary |
| `POST /api/proxmox/telemetry` | host telemetry ingest |
| `GET /api/central/status` | Central state summary |
| `GET /api/simulations` | simulation/bucket summary |
| `GET /api/logs/history` | service/install log history |
| `GET /ws` | browser real-time updates |

#### Relay-related spoke endpoints

| Endpoint | Use |
|---|---|
| `POST /api/relay/trigger` | force a relay sync |
| `GET /api/relay/status` | current hub relay state |
| `GET /api/relay/diag` | relay diagnostics |

---

## Summary

`client-sim` is the local execution engine of the platform: it installs and runs the spoke, manages Proxmox automation, distributes configs/scripts to clients, and drives the simulations themselves.
