# webui-spoke — Client-Sim Spoke Server

`webui-spoke` is the local Client-Sim **spoke** server used in the HPE hub/spoke architecture.

It runs close to the simulation environment — typically in a **Proxmox LXC container** — and provides the local control plane for up to **24 client simulation VMs**. The spoke:

- monitors client VM heartbeats, errors, and simulation state
- serves config and scripts to simulation clients
- connects to **Aruba Central** for site, alert, and telemetry context
- relays telemetry and receives commands from **webui-hub** using the hub registration + inbox/ack workflow

`webui-hub` is the central management platform. A superadmin approves each spoke, after which the hub can manage it through tenant-scoped relay endpoints.

---

## Architecture

```text
webui-hub (central)
      |
 HTTPS relay (registration -> approval -> inbox/ack)
      |
webui-spoke (this server — Proxmox LXC)
      |
Proxmox VMs (24x client simulation VMs)
      |
Aruba Central (AP/switch telemetry)
```

### Local responsibilities

- Host the browser UI and local API for the site/lab
- Track simulation client health, overrides, logs, and command state
- Poll Aruba Central and correlate Central status with local client/site mappings
- Act as the tenant-approved relay endpoint consumer for hub-issued commands

### Hub/spoke responsibilities

- **webui-hub**: multi-tenant central management, approval workflow, fleet view, tenant-scoped relay API
- **webui-spoke**: local execution, local monitoring, local client API, Aruba Central polling, command acknowledgements

> User-facing docs should call this component **webui-spoke** or **spoke**. Current settings and API payloads use `relay_spoke_id` naming.

---

## Quick Start

### Recommended deployment: Proxmox LXC

1. **Create or prepare a Debian 12 LXC**
   - `eth0`: management network / internet access
   - `eth1`: isolated client network for the simulation VMs
2. **Enter the container and run the installer**:

   ```bash
   sudo bash install-lxc.sh --branch lrb --port 8000
   ```

   Common alternatives:

   ```bash
   sudo bash install-lxc.sh --branch lrb --port 9000
   sudo bash install-lxc.sh --reinstall
   ```

3. **Attach client VMs to the isolated bridge** used by the spoke.
4. **Point clients at the spoke**:

   ```ini
   [server]
   server_url=http://169.253.1.1:8000
   ```

5. Open the UI in a browser and complete:
   - Aruba Central configuration
   - relay configuration to `webui-hub`
   - notification settings

### What `install-lxc.sh` does

The LXC installer:

1. installs Python, git, and dnsmasq
2. assigns `169.253.1.1/24` to the client-side NIC by default
3. configures dnsmasq to serve DHCP on the client-side NIC only
4. downloads the shared `cs-webui` frontend on the selected branch and injects `WEBUI_MODE=spoke`
5. deploys the FastAPI app and systemd service
6. prints health information and the `server_url` clients should use

By default, DHCP serves `169.253.1.11`–`169.253.1.254` on the isolated client network.

### Unified frontend (`cs-webui`)

`webui-spoke` serves the shared frontend from the `cs-webui` repo rather than maintaining a separate spoke-only UI.

- `install-lxc.sh` fetches `static/app.js`, `static/style.css`, and `templates/index.html` from `cs-webui` on the same branch selected for the spoke install.
- `server.py` serves the shared HTML template and injects `WEBUI_MODE=spoke` at runtime.
- Use `--branch <name>` to keep the spoke backend and shared frontend aligned (`lrb` for development, `main` for production).

---

## Hub Relay Integration

This is the key spoke-to-hub integration that connects a local `webui-spoke` instance to `webui-hub`.

### Enable relay

Configure the spoke in the UI or through `POST /api/settings`:

- set `relay_server_url` to the base URL of `webui-hub`
- set `relay_enabled` to `on`
- optionally set `relay_poll_interval` (default: `60` seconds)

Example settings payload:

```json
{
  "relay_enabled": "on",
  "relay_server_url": "https://hub.example.com",
  "relay_poll_interval": 60
}
```

### Registration and approval flow

1. On the first relay cycle, the spoke calls:

   ```text
   POST {relay_server_url}/api/spokes/register
   ```

2. The spoke sends its hostname/label plus seed configuration (repo branch, site mappings, monitored checks, hardware checks, USB/reclone settings, etc.).
3. The hub returns an initial registration record.
4. The spoke stores `relay_spoke_id` automatically when the hub returns it.
5. A **superadmin approves the spoke** in `webui-hub`.
6. After approval, the hub returns:
   - `relay_tenant_id`
   - `relay_api_key`
7. The spoke saves both values automatically and switches into approved relay mode.

### Relay settings

| Key | Purpose | How it is set |
|---|---|---|
| `relay_server_url` | Base URL for `webui-hub` | Set by operator |
| `relay_enabled` | Turns relay on/off | Set by operator |
| `relay_poll_interval` | Relay loop interval in seconds | Set by operator |
| `relay_spoke_id` | Spoke ID assigned by hub | Auto-set after registration |
| `relay_tenant_id` | Tenant scope assigned by hub | Auto-set after approval |
| `relay_api_key` | API key used for tenant relay calls | Auto-set after approval |

### Approved relay mode

After approval, all hub relay traffic uses tenant-scoped URLs:

```text
/api/{tenant_id}/spokes/{spoke_id}/telemetry
/api/{tenant_id}/spokes/{spoke_id}/inbox
/api/{tenant_id}/spokes/{spoke_id}/ack
```

The spoke relay cycle then:

1. sends telemetry for the current local client state
2. fetches hub inbox commands
3. applies or queues each command locally
4. sends an acknowledgement with status/result payload

### Hub-pushed commands

The hub can push these command types through the inbox:

- `config_update` — updates supported spoke settings such as relay config, repo branch, mappings, monitored checks, and selected provisioning settings
- `gkill_switch` — updates the global kill switch state on the spoke
- regular device/proxmox commands — queued into the local command system for clients or the Proxmox agent

Every inbox command receives an ack. For example:

- `config_update` → ack with `status: executed` and a result payload describing the changes applied
- `gkill_switch` → ack with `status: executed` and the resulting switch value
- queued client/proxmox command → ack with `status: queued`

### Local relay endpoints

| Method | Path | Purpose |
|---|---|---|
| `POST` | `/api/relay/trigger` | Manually trigger an immediate relay sync |
| `GET` | `/api/relay/status` | Return current relay state |
| `GET` | `/api/settings` | View current relay-related settings |
| `POST` | `/api/settings` | Update relay configuration |

---

## Configuration

The spoke persists its configuration in `settings.json` and exposes it through `GET /api/settings` and `POST /api/settings`.

### Common top-level settings

| Key | Description |
|---|---|
| `repo_branch` | Git branch used for the synced Client-Sim repo |
| `repo_sync_interval` | Repo pull interval in seconds |
| `relay_enabled` | `on` or `off` |
| `relay_server_url` | Hub URL |
| `relay_spoke_id` | Hub-assigned spoke ID |
| `relay_tenant_id` | Hub-assigned tenant ID |
| `relay_poll_interval` | Relay polling interval in seconds |
| `site_mappings` | Local `wsite` to Aruba Central site name mapping |
| `monitored_checks` | Central checks to watch per site |
| `hardware_checks` | Hardware alert checks to watch |

### Aruba Central settings (`central_config`)

| Key | Description |
|---|---|
| `api_version` | `classic` or `new_central` |
| `cluster_url` | Central API base URL |
| `access_token` | Classic Central access token |
| `refresh_token` | Optional Classic Central refresh token |
| `client_id` | OAuth client ID / GreenLake API client ID |
| `client_secret` | OAuth client secret |
| `customer_id` | Optional Classic Central customer/tenant ID |

### Notification settings (`notifications`)

| Key | Description |
|---|---|
| `email_enabled` | Enable SMTP email notifications |
| `smtp_host` | SMTP server hostname |
| `smtp_port` | SMTP server port (default `587`) |
| `smtp_user` | SMTP username |
| `smtp_password` | SMTP password |
| `smtp_from` | Sender address |
| `smtp_to` | Recipient list |
| `teams_enabled` | Enable Microsoft Teams notifications |
| `teams_webhook_url` | Teams incoming webhook URL |

### Installer and deployment variables

| Variable | Default | Description |
|---|---|---|
| `REPO_URL` | `https://github.com/solutions-hpe/client-sim.git` | Git repo to sync |
| `REPO_BRANCH` | `main` | Branch to sync |
| `INSTALL_DIR` | `/opt/client-sim-dashboard` | App install directory |
| `REPO_CACHE` | `/opt/client-sim-repo` | Local git checkout |
| `SERVICE_USER` | `dashboard` | Service account |
| `PORT` | `8000` | Web server port |
| `OFFLINE_TIMEOUT` | `60` | Seconds before a client is considered offline |
| `DHCP_IFACE` | auto-detect second NIC | Interface used for DHCP |
| `DHCP_GATEWAY` | `169.253.1.1` | Spoke IP on the client network |
| `DHCP_SUBNET` | `169.253.1.0` | Client network subnet |
| `DHCP_PREFIX` | `24` | Client network prefix |
| `DHCP_RANGE_START` | `169.253.1.11` | First DHCP address |
| `DHCP_RANGE_END` | `169.253.1.254` | Last DHCP address |
| `DHCP_LEASE_TIME` | `1h` | DHCP lease duration |

If another device provides DHCP, install without local DHCP:

```bash
DHCP_IFACE="" bash install-lxc.sh
```

---

## API Reference

These are the main local endpoints exposed by `webui-spoke`.

### Core spoke endpoints

| Method | Path | Description |
|---|---|---|
| `GET` | `/api/health` | Basic health check, including installer version |
| `GET` | `/api/settings` | Current spoke settings |
| `POST` | `/api/settings` | Update spoke settings |
| `GET` | `/api/clients` | Current client inventory/state. Each client includes `has_usb: bool` for T1/T2 classification |
| `GET` | `/api/simulations` | Grouped simulation view |
| `GET` | `/api/simulations/{sim_id}/clients` | Client list for one simulation/site bucket |
| `GET` | `/api/hardware-alerts` | Current hardware alert summary |
| `POST` | `/api/status` | Client heartbeat/beacon endpoint |
| `GET` | `/api/config?hostname=<h>` | Render effective `simulation.conf` |
| `GET` | `/api/scripts/list?platform=linux|windows` | List available scripts |
| `GET` | `/api/scripts/{platform}/{filename}` | Download a script |

### Command and relay-adjacent endpoints

| Method | Path | Description |
|---|---|---|
| `POST` | `/api/commands` | Queue a command for one client, all clients, or the Proxmox agent |
| `GET` | `/api/commands` | Full local command history |
| `GET` | `/api/inbox?hostname=<h>` | Device/agent poll endpoint for pending commands |
| `POST` | `/api/inbox/ack` | Device/agent ack endpoint for command results |
| `POST` | `/api/relay/trigger` | Trigger immediate spoke↔hub relay sync |
| `GET` | `/api/relay/status` | Current relay registration/connection state |
| `GET` | `/api/kill-switch` | Current global kill switch value for clients |
| `GET` | `/api/kill-switch/status` | Detailed kill switch state for UI/debugging |
| `WS` | `/ws` | Real-time browser updates |

For the client-specific request/response details used by simulation VMs, see [`CLIENT_API.md`](CLIENT_API.md).

---

## Deployment

### Proxmox LXC (primary)

This is the intended production deployment model.

- Run the spoke in an LXC container on a Proxmox host
- Use one interface for management and one for the isolated simulation network
- Attach up to 24 simulation VMs to the client-side bridge/network
- Let the spoke provide DHCP on the isolated client segment unless your environment already provides it

#### Common installer commands

```bash
sudo bash install-lxc.sh
sudo bash install-lxc.sh --branch main --port 8000
sudo bash install-lxc.sh --branch lrb --port 9000
sudo bash install-lxc.sh --reinstall
```

#### CLI flags

| Flag | Description |
|---|---|
| `--branch <name>` | Override `REPO_BRANCH` |
| `--port <number>` | Override `PORT` |
| `--reinstall` | Full wipe and fresh install while preserving backed-up settings |

#### Self-update

The installer version is written to `INSTALLER_VERSION` and shown in the UI. The spoke can check for newer installer versions and re-run the installer in place during self-update.

### Docker (development / lab use)

`docker-compose.yml` builds the local image and exposes port `8000`:

```bash
docker compose up --build
```

Default Docker behavior in this repo:

- builds from the included `Dockerfile`
- exposes `8000:8000`
- sets `REPO_URL`, `REPO_BRANCH`, `REPO_DIR`, and `OFFLINE_TIMEOUT`
- mounts a persistent `repo-cache` volume at `/app/client-sim`

### Python (development)

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
uvicorn server:app --host 0.0.0.0 --port 8000
```

---

## Aruba Central Integration

`webui-spoke` can correlate local simulation state with Aruba Central telemetry.

### Configure Aruba Central

Use **Setup → Aruba Central Connection** and choose one of the supported modes.

#### Classic Central API

Use for standard Aruba Central deployments.

Required/optional fields:

- `api_version=classic`
- `cluster_url`
- `access_token`
- `refresh_token` *(optional but recommended if available)*
- `customer_id` *(optional)*
- `client_id` / `client_secret` *(optional, depending on token refresh model)*

Example cluster URLs:

- US: `https://apigw-uswest4.central.arubanetworks.com`
- EU: `https://apigw-eucentral3.central.arubanetworks.com`
- APAC: `https://apigw-apacsoutheast1.central.arubanetworks.com`
- Internal: `https://internal-apigw.central.arubanetworks.com`

#### New Central (CNX) API

Use for the HPE GreenLake-based Central platform.

Required fields:

- `api_version=new_central`
- `cluster_url`
- `client_id`
- `client_secret`

Example cluster URLs:

- US: `https://us1.api.central.arubanetworks.com`
- EU: `https://eu1.api.central.arubanetworks.com`
- Internal: `https://internal.api.central.arubanetworks.com`

### Site mapping and checks

After Central connectivity works:

1. load local `wsite` values from `simulation.conf`
2. load Central sites
3. map local `wsite` values to Central site names
4. select monitored checks and hardware checks
5. save the configuration so the spoke can poll and display results locally

Useful Central endpoints:

| Method | Path | Description |
|---|---|---|
| `POST` | `/api/central/test-connection` | Validate configured Central credentials |
| `GET` | `/api/central/available` | Available Central checks/alert types |
| `GET` | `/api/central/sites` | Site list from Central |
| `GET` | `/api/central/status` | Current status for monitored sites/checks |
| `GET` | `/api/central/history` | Historical Central check data |
| `GET` | `/api/central/site-alerts?site=<name>` | Active alerts for a site |

---

## Notification Setup

Notifications are configured in **Setup** and stored under `notifications` in `settings.json`.

### Microsoft Teams

Configure:

- `teams_enabled=true`
- `teams_webhook_url=<incoming webhook URL>`

### Email / SMTP

Configure:

- `email_enabled=true`
- `smtp_host`
- `smtp_port`
- `smtp_user`
- `smtp_password`
- `smtp_from`
- `smtp_to`

### Test notifications

Use the local API to send a validation message:

```text
POST /api/notifications/test
```

Request field `channel` must be either `email` or `teams`.

---

## Client Connectivity

Simulation clients continue to talk to the **local spoke**, not directly to the hub.

Typical client cycle:

1. `GET /api/health`
2. `GET /api/config?hostname=<hostname>`
3. `GET /api/scripts/list`
4. `GET /api/scripts/{platform}/{filename}` as needed
5. run simulations locally
6. `POST /api/status`
7. optionally poll `/api/kill-switch`

That local-first design keeps the simulation environment working even if the hub is unavailable. Relay sync to `webui-hub` is additive and separate from the client VM API.

