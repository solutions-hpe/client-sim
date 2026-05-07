# Client Simulation — Reporting API

This document describes how simulation clients communicate with the Client-Sim Dashboard webserver. Clients use this API to:

1. **Report status** (heartbeat/beacon) so the dashboard knows they are alive
2. **Pull configuration** to receive their `simulation.conf` (including any in-dashboard overrides)
3. **Pull scripts** to stay up to date with the latest simulation scripts

---

## Quick Start

### 1. Point clients at the webserver

Set `server_url` in `simulation.conf` on each client:

```ini
[server]
server_url=http://169.253.1.1:8000
```

Replace `169.253.1.1` with the dashboard server's IP address. For the standard Proxmox deployment this is the `eth1` address of the WebUI LXC on `vmbr255`. For a development/test server use the host IP and port `8000`.

If `server_url` is blank or unreachable, all API calls are skipped and the client runs in standalone mode — it continues to use whatever scripts and config it last downloaded.

### 2. Verify the server is reachable

```bash
curl http://169.253.1.1:8000/api/health
```

Expected response:

```json
{
  "status": "ok",
  "clients": 0,
  "repo_synced": true,
  "repo_error": null,
  "installer_version": "0.03"
}
```

`repo_synced: true` confirms the server has successfully cloned the git repo and can serve scripts and config. If `repo_synced` is `false`, check the **Setup** tab in the dashboard for the sync error — clients cannot pull scripts until the repo is ready.

### 3. Confirm config is being served

```bash
curl "http://169.253.1.1:8000/api/config?hostname=$(hostname)"
```

This returns the INI-format `simulation.conf` with any per-client overrides already merged in. If the output looks correct, the client is ready to sync automatically.

---

## Endpoints Used by Clients

### 1. Health Check

**Before doing anything**, check the server is up:

```
GET /api/health
```

**Response:**

```json
{
  "status": "ok",
  "clients": 4,
  "repo_synced": true,
  "repo_error": null,
  "installer_version": "0.01"
}
```

A `200 OK` with `"status": "ok"` means the server is ready. If this fails, skip all further API calls for this cycle.

**Shell example:**

```bash
curl -sf "${server_url}/api/health" > /dev/null || exit 0
```

---

### 2. Report Status (Heartbeat)

Clients POST a JSON beacon on every simulation cycle so the dashboard can track their state.

```
POST /api/status
Content-Type: application/json
```

**Request body:**

```json
{
  "hostname":           "client-01",
  "simulation_id":      "slynch",
  "platform":           "linux",
  "iteration":          42,
  "connected_ssid":     "HPE-Corp",
  "gateway_reachable":  true,
  "vh_connected":       false,
  "active_simulations": ["dns_fail", "www_traffic"],
  "errors":             ["SSID not found after 30s scan", "Gateway unreachable"],
  "config": {
    "sim_phy":     "on",
    "kill_switch": "off",
    "dns_fail":    "on",
    "iperf":       "off",
    "www_traffic": "on",
    "download":    "off",
    "ping_test":   "off",
    "ssidpw_fail": "off",
    "auth_fail":   "off",
    "dhcp_fail":   "off"
  }
}
```

| Field | Type | Description |
|---|---|---|
| `hostname` | string | Device hostname — used as the unique client key |
| `simulation_id` | string | Section name from `simulation.conf` (e.g. `s0`, `slynch`) |
| `platform` | string | `linux` or `windows` |
| `iteration` | int | Simulation loop counter |
| `connected_ssid` | string \| null | Currently associated SSID (blank if disconnected) |
| `gateway_reachable` | bool | Whether the default gateway responded to ping |
| `vh_connected` | bool | Whether VH (VirtualHub) connection is active |
| `active_simulations` | array of strings | Which simulations are currently running |
| `errors` | array of strings | *(optional)* Error messages accumulated since the last beacon. The server stores the last 50 per client (circular buffer) and displays them in the dashboard error log. Cleared from the client buffer only after a successful POST. |
| `config` | object | Key/value pairs from the client's active `simulation.conf` section |

**Response:**

```json
{
  "status": "ok",
  "client": { ... }
}
```

The `client` object is the full serialized client record as stored in the dashboard.

**Shell example (from `simulation.sh`):**

```bash
curl -m 5 -s -o /dev/null \
  -H "Content-Type: application/json" \
  -X POST \
  --data "$payload" \
  "${server_url}/api/status"
```

The response is ignored — if the POST fails the simulation continues normally.

---

### 3. Pull Configuration

Clients fetch their effective `simulation.conf` from the server. The server returns the file from the synced git repo, with any active in-dashboard overrides applied for this hostname.

```
GET /api/config?hostname=<hostname>
```

| Parameter | Required | Description |
|---|---|---|
| `hostname` | No | If provided, any overrides set via the dashboard for this client are merged in. If omitted, the raw file is returned. |

**Response:** Plain text — the full contents of `configs/simulation.conf` (INI format), with overrides applied as key=value replacements in the client's section.

**Shell example (from `update.sh`):**

```bash
curl -sf \
  "${server_url}/api/config?hostname=${HOSTNAME}" \
  -o /tmp/simulation.conf

# If successful, replace the local config
if [[ -s /tmp/simulation.conf ]]; then
  cp /tmp/simulation.conf /path/to/configs/simulation.conf
fi
```

If the server is unreachable or returns an error, keep the existing local `simulation.conf`.

---

### 4. Pull Script List

Clients can check what scripts are available on the server for their platform:

```
GET /api/scripts/list?platform=linux
GET /api/scripts/list?platform=windows
```

**Response:** JSON array of filenames:

```json
["simulation.sh", "startup.sh", "update.sh", "dashboard.sh"]
```

---

### 5. Download a Script

Download an individual script file:

```
GET /api/scripts/{platform}/{filename}
```

| Parameter | Description |
|---|---|
| `platform` | `linux` or `windows` |
| `filename` | Script filename (e.g. `simulation.sh`) |

**Response:** Raw file content (`application/octet-stream`).

**Shell example (from `update.sh`):**

```bash
# Get list of scripts
scripts=$(curl -sf "${server_url}/api/scripts/list?platform=linux" || echo "")

# Download each one
for filename in $scripts; do
  curl -sf "${server_url}/api/scripts/linux/${filename}" \
    -o "/path/to/scripts/${filename}"
done
```

---

## Typical Client Cycle

Every simulation loop, a client should:

```
1.  Read local simulation.conf
2.  Check /api/health  →  server up?
3.    Yes → GET /api/config?hostname=<h>  →  apply updated config
4.         GET /api/scripts/list          →  download any new/changed scripts
5.  Run simulations based on active config
6.  POST /api/status                      →  report current state to dashboard
7.  Sleep, repeat
```

Steps 2–4 are performed by `update.sh`. Step 6 is performed by `simulation.sh` on every iteration.

---

## Dashboard-Side Controls (Optional)

The dashboard can push overrides to individual clients or all clients at once. Clients receive these overrides automatically when they next call `GET /api/config?hostname=<h>` — no polling required.

| Endpoint | Description |
|---|---|
| `POST /api/clients/{hostname}/control` | Push key/value overrides to a specific client |
| `DELETE /api/clients/{hostname}/control` | Clear all overrides for a specific client |
| `POST /api/clients/all/control` | Push overrides to every connected client |

**Override request body:**

```json
{
  "dns_fail": "on",
  "www_traffic": "off"
}
```

Overrides are in-memory only — they are cleared when the dashboard restarts, or when explicitly deleted.

---

## WebSocket (Real-Time)

The dashboard streams live updates over WebSocket at `ws://<host>:<port>/ws`. Clients do not need to use this — it is intended for the browser UI.

Message types broadcast by the server:
- `full_state` — snapshot of all clients (sent on connect)
- `status_update` — one client's state changed
- `overrides_update` — overrides were applied to a client
- `overrides_cleared` — overrides were removed from a client
- `repo_status` — git sync status changed
- `settings_update` — dashboard settings changed
- `central_update` — Aruba Central poll completed
