# Client-Sim Dashboard

A FastAPI web dashboard for monitoring client-sim beacons, viewing client status, and pushing in-memory simulation overrides without a database or authentication layer.

---

## Deployment on Proxmox (Recommended)

Client-Sim is designed to run on Proxmox VE. The webUI runs inside an LXC container and optionally provides DHCP service to client VMs/LXCs over an isolated internal bridge (`vmbr255`).

### Architecture

```
Proxmox Host
├── vmbr255  (internal bridge — no uplink, isolated)
│   ├── WebUI LXC
│   │   ├── eth0 → management network  (internet, admin access)
│   │   └── eth1 → vmbr255  static 169.253.1.1/24
│   │        └── dnsmasq: hands out 169.253.1.11–254
│   └── Client VMs / LXCs
│       └── NIC → vmbr255  (DHCP → 169.253.1.x)
│                simulation.conf: server_url=http://169.253.1.1:8000
```

### Step 1 — Run the Proxmox host setup script

Run **once** on the Proxmox host itself (not inside an LXC):

```bash
bash proxmox_setup.sh
```

Located at the root of the `client-sim` repo. This does everything needed to prepare a fresh Proxmox host:

1. Creates the `vmbr255` isolated internal bridge (no uplink)
2. Installs `git`
3. Clones the repo and copies all `proxmox/` scripts to `/etc/pve/scripts/`
4. Creates a daily cron job (`/etc/cron.d/client-sim-sync`) that pulls the latest scripts from GitHub every morning at 2am

> **Note:** `/etc/pve` is Proxmox's cluster filesystem (pmxcfs) and does not support execute permissions. All scripts there are always invoked as `bash /etc/pve/scripts/<name>.sh` — never directly.

#### Options

| Flag | Env var | Default | Description |
|---|---|---|---|
| `--branch <name>` | `REPO_BRANCH` | `lrb` | Git branch to sync scripts from |
| `--bridge <name>` | `BRIDGE` | `vmbr255` | Name of the isolated client bridge to create |

All three override methods work:

```bash
# CLI flags
bash proxmox_setup.sh --branch main
bash proxmox_setup.sh --branch main --bridge vmbr100

# Environment variables
REPO_BRANCH=main bash proxmox_setup.sh
BRIDGE=vmbr100 REPO_BRANCH=main bash proxmox_setup.sh
```

The selected branch is written into the cron job so the daily sync continues pulling from the same branch automatically. To change branch after initial setup, re-run the script with the new `--branch` value — the cron file will be updated.

#### Keeping scripts up to date

After initial setup, scripts update themselves automatically via cron. To trigger a manual sync at any time:

```bash
bash /etc/pve/scripts/sync-scripts.sh
```

Sync activity is logged to `/var/log/client-sim-sync.log`.

### Step 2 — Create the WebUI LXC

Run on the Proxmox host to download the latest Debian template and provision the LXC:

```bash
bash proxmox_create_lxc.sh
```

This will prompt for a root password and then create the container with sensible defaults. All options can be passed as flags:

```bash
bash proxmox_create_lxc.sh \
  --id 200 \
  --storage local-lvm \
  --hostname webui \
  --ip 192.168.1.50/24 \
  --gw 192.168.1.1 \
  --memory 2048 \
  --disk 16
```

| Flag | Default | Description |
|---|---|---|
| `--id` | `1000` | Proxmox container ID (CTID) |
| `--storage` | `local-lvm` | Disk storage pool |
| `--tmpl-storage` | `local` | Where to store the downloaded template |
| `--bridge` | `vmbr0` | Management bridge (eth0 — internet/admin) |
| `--client-bridge` | `vmbr255` | Isolated client bridge (eth1) |
| `--hostname` | `client-sim` | Container hostname |
| `--password` | *(prompted)* | Root password |
| `--cores` | `2` | vCPU count |
| `--memory` | `1024` | RAM in MB |
| `--disk` | `8` | Root disk size in GB |
| `--ip` | `dhcp` | eth0 IP — `dhcp` or CIDR e.g. `192.168.1.50/24` |
| `--gw` | *(none)* | Default gateway for eth0 |

The script will:
- Pull the latest **Debian 12 (Bookworm)** template from the Proxmox mirror
- Create an unprivileged LXC with `nesting=1` (required for some tools)
- Attach **eth0** to the management bridge and **eth1** to `vmbr255`
- Start the container and install `curl` + `git`
- Print the exact command to run the Client-Sim installer inside it

### Step 3 — Run the LXC installer

Inside the WebUI LXC:

```bash
curl -fsSL https://raw.githubusercontent.com/solutions-hpe/client-sim/lrb/webui/install-lxc.sh | sudo bash
```

Or download and run with custom options:

```bash
sudo bash install-lxc.sh --branch lrb --port 8000
```

The installer will:
1. Install Python, git, and dnsmasq
2. Assign `169.253.1.1/24` to `eth1`
3. Configure dnsmasq to serve DHCP `169.253.1.11–254` on `eth1` only
4. Deploy the FastAPI dashboard and set up a systemd service
5. Print a health check summary and the `server_url` to use in `simulation.conf`

The **installer version** is written to `INSTALLER_VERSION` and displayed in the top-right corner of the dashboard UI.

### Step 4 — Attach client VMs/LXCs to vmbr255

For each client VM or LXC:
- Add a NIC on bridge `vmbr255`, set to DHCP
- It will receive an IP in `169.253.1.11–254`
- Set in `simulation.conf`:

```ini
[server]
server_url=http://169.253.1.1:8000
```

---

## Self-Update System

The dashboard checks GitHub every 24 hours by comparing the installed `INSTALLER_VERSION` with the `VERSION=` value in the synced `webui/install-lxc.sh`.

If a newer version is available, the self-update flow runs automatically:
1. Pull the latest repo content
2. Run the installer again in place
3. Restart the dashboard service

You can also trigger the same flow manually from **Setup** → **Check & Update Now**. The update log streams live in the UI, and any failure is surfaced there as an error.

Self-update requires the sudoers rule written by the installer:

```bash
dashboard ALL=(root) NOPASSWD: /bin/bash /opt/client-sim-repo/webui/install-lxc.sh *
```

---

## DHCP Configuration

All DHCP settings are configurable via environment variables before running the installer:

| Variable | Default | Description |
|---|---|---|
| `DHCP_IFACE` | `eth1` | Interface connected to vmbr255. Set to `""` to skip DHCP setup |
| `DHCP_GATEWAY` | `169.253.1.1` | Static IP assigned to this LXC on vmbr255 (also the gateway clients receive) |
| `DHCP_SUBNET` | `169.253.1.0` | Network address |
| `DHCP_PREFIX` | `24` | Subnet prefix length |
| `DHCP_RANGE_START` | `169.253.1.11` | First DHCP address (first 10 IPs reserved) |
| `DHCP_RANGE_END` | `169.253.1.254` | Last DHCP address |
| `DHCP_LEASE_TIME` | `1h` | DHCP lease duration |

Example — custom subnet:

```bash
DHCP_GATEWAY=192.168.99.1 \
DHCP_SUBNET=192.168.99.0 \
DHCP_RANGE_START=192.168.99.50 \
DHCP_RANGE_END=192.168.99.150 \
bash install-lxc.sh
```

To install the webUI **without** DHCP (e.g. if another device handles DHCP):

```bash
DHCP_IFACE="" bash install-lxc.sh
```

dnsmasq is scoped **only** to `eth1` — it never touches `eth0` or any other interface.

---

## General Installer Options

| Variable | Default | Description |
|---|---|---|
| `REPO_URL` | `https://github.com/solutions-hpe/client-sim.git` | Git repo to sync |
| `REPO_BRANCH` | `main` | Branch to keep synced |
| `INSTALL_DIR` | `/opt/client-sim-dashboard` | Where the app is deployed |
| `REPO_CACHE` | `/opt/client-sim-repo` | Local git checkout |
| `SERVICE_USER` | `dashboard` | System user the service runs as |
| `PORT` | `8000` | TCP port to serve on |
| `OFFLINE_TIMEOUT` | `60` | Seconds before a client is shown as offline |

CLI flags (override env vars):

```bash
sudo bash install-lxc.sh --branch lrb --port 9000
sudo bash install-lxc.sh --reinstall          # full wipe and fresh install
```

---

## Run with Docker (Development)

```bash
cd webui
docker compose up --build
```

Open `http://localhost:8000`.

## Run with Python (Development)

```bash
cd webui
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
uvicorn server:app --host 0.0.0.0 --port 8000
```

---

## Webserver as Sync Hub

The dashboard server acts as a **central sync point** for all client devices. It serves scripts and configuration files to clients automatically, so you never need to push files to each client individually. Changes pushed to git become available to all clients within 5 minutes.

### How it works

```
GitHub repo  ──git pull──►  WebUI server  ──/api/config──►  Client
 (configs/                  (every 5 min)  ──/api/scripts──► Client
  linux/                                   ──/api/status◄──  Client
  windows/)                                    (beacon)
```

1. The dashboard server clones the configured git repo on first start and **pulls every 5 minutes** automatically.
2. Clients call `GET /api/config?hostname=<hostname>` on each update cycle to receive the latest `simulation.conf` (with any in-dashboard per-client overrides merged in).
3. Clients call `GET /api/scripts/list` + `GET /api/scripts/{platform}/{filename}` to download updated scripts.
4. Clients POST a beacon to `POST /api/status` each cycle so the dashboard can track their state.

### Sync status indicator

The **top-right corner** of the dashboard UI shows the current repo sync state:

| Indicator | Meaning |
|---|---|
| 🟢 Synced | Repo pulled successfully; scripts and configs are current |
| 🔄 Syncing | First clone or pull in progress |
| 🔴 Disconnected | Last sync attempt failed (see error in Setup tab → Repo section) |

A **Disconnected** status means clients will continue running with whatever scripts they last downloaded, but they will not receive updates until the server can reach the repo again. Check network connectivity and the repo URL/branch in the Setup tab.

### Configuring the git repo

The repo URL is baked in at install time via the `REPO_URL` environment variable (default: `https://github.com/solutions-hpe/client-sim.git`). The **branch** can be changed at any time without restarting:

**Via the Setup tab:**
1. Open the dashboard → **Setup** tab
2. Find the **Sync / Repository** card
3. Change the **Branch** field and click **Save**
4. The server cancels the current sync loop and immediately starts a fresh pull of the new branch

**Via environment variable (install time):**
```bash
REPO_URL=https://github.com/your-org/client-sim.git \
REPO_BRANCH=my-branch \
bash install-lxc.sh
```

**Via CLI flag:**
```bash
bash install-lxc.sh --branch my-branch
```

The active branch is persisted in `settings.json` and survives service restarts.

### GitHub sync interval

The repo pull interval is configurable in **Setup** → **GitHub Sync**:
- **Default**: `300` seconds
- **Allowed range**: `60-86400` seconds
- **Persistence**: Saved in `settings.json`

### Private repository access

If your repo requires authentication, configure git credentials **before** installing or starting the service. The recommended approach for a private GitHub repo is a [Personal Access Token](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens):

```bash
# Store credentials for the dashboard service user
git config --global credential.helper store
echo "https://<username>:<token>@github.com" > ~/.git-credentials
chmod 600 ~/.git-credentials
```

Then set `REPO_URL` to include the token inline (if credential store is not available):
```bash
REPO_URL=https://<token>@github.com/your-org/client-sim.git bash install-lxc.sh
```

> ⚠️ Tokens embedded in URLs are visible in process listings. The credential store approach is preferred for production use.

### What is served from the repo

| API endpoint | Served from repo path |
|---|---|
| `GET /api/config?hostname=<h>` | `configs/simulation.conf` |
| `GET /api/scripts/list?platform=linux` | `linux/` directory listing |
| `GET /api/scripts/linux/<file>` | `linux/<file>` |
| `GET /api/scripts/list?platform=windows` | `windows/` directory listing |
| `GET /api/scripts/windows/<file>` | `windows/<file>` |

Scripts are served as-is (raw file content). Config is served with any in-dashboard per-client overrides merged in before delivery.

---

## Notifications Setup

Notifications are configured from **Setup** and support both email and Microsoft Teams.

### Email
- Enable/disable toggle
- SMTP host, port, username, password
- From and To addresses
- **Save** plus **Send Test** action

### Teams
- Enable/disable toggle
- Incoming webhook URL
- **Save** plus **Send Test** action

---

## Client connection

Clients connect to the dashboard by setting `server_url` in their `simulation.conf`:

```ini
[server]
server_url=http://169.253.1.1:8000
```

Replace `169.253.1.1` with the dashboard IP on your network. If using the standard Proxmox deployment (Step 4 above), this is the `eth1` address of the WebUI LXC on `vmbr255`.

If `server_url` is blank or the server is unreachable, clients skip all sync calls and run in **standalone mode** using their local scripts and config — no crash, no error loop.

### Client update cycle

Every iteration, a client (`update.sh` + `simulation.sh`) performs:

```
1. curl GET /api/health          ← is the server up?
2. curl GET /api/config          ← pull latest simulation.conf (with overrides)
3. curl GET /api/scripts/list    ← check for updated scripts
4. curl GET /api/scripts/<file>  ← download any changed files
5. [run simulations]
6. curl POST /api/status         ← send beacon (hostname, SSID, counters, errors)
```

Steps 1–4 are handled by `update.sh` at startup and on a configurable interval. Step 6 runs inside `simulation.sh` every loop.

See [`CLIENT_API.md`](CLIENT_API.md) for the full API reference including all request/response schemas.

---

## Aruba Central Integration

The Setup tab → **Aruba Central Connection** card lets the dashboard monitor your Central environment alongside the client simulation. It supports two API modes.

---

### Classic Central API

Use this for standard Aruba Central deployments (on-premises or hosted at `*.central.arubanetworks.com`).

#### Step 1 — Select Classic

In the **Aruba Central Connection** card, select **Classic Central API**.

#### Step 2 — Enter Cluster URL

Enter the base URL of your Central cluster — the hostname only, no path:

```
https://internal-apigw.central.arubanetworks.com
```

Common cluster URLs by region:

| Region | Cluster URL |
|---|---|
| US | `https://apigw-uswest4.central.arubanetworks.com` |
| EU | `https://apigw-eucentral3.central.arubanetworks.com` |
| APAC | `https://apigw-apacsoutheast1.central.arubanetworks.com` |
| Internal/Private | `https://internal-apigw.central.arubanetworks.com` |

#### Step 3 — Get your Access Token

1. Log in to **Aruba Central**
2. Go to **Account Home** → **Global Settings** → **API Gateway**
3. Click **System Apps & Tokens** (or **My Apps & Tokens**)
4. Find or create an app with **Monitoring** or **Configuration** scope
5. Click **Generate Token** — copy the **Access Token** value

> ⚠️ Tokens expire. If you also copy the **Refresh Token**, the dashboard can auto-renew the access token without manual intervention.

#### Step 4 — Enter tokens

- **Access Token** — paste the bearer token copied from Central
- **Refresh Token** *(optional)* — paste the refresh token; enables auto-renewal when the access token expires
- **Customer ID** *(optional)* — your Central customer/tenant ID (visible in the API Gateway page)

#### Step 5 — Enter Client Credentials *(optional)*

- **Client ID** / **Client Secret** — only required if your Central instance uses OAuth client credentials for token refresh. Leave blank if using a manually pasted token with a refresh token.

#### Step 6 — Save & Test Connection

Click **Save & Test Connection**. The dashboard will probe several API endpoints to confirm the token is accepted. A green ✓ confirmation means the token is valid.

If you see HTTP 404 errors in the test output, this is normal — the probe tries multiple endpoints and needs only one to succeed.

---

### New Central (CNX) API

Use this for the next-generation HPE GreenLake-based Central (also called CNX). Authentication uses OAuth2 client credentials — there is no manually pasted bearer token.

#### Step 1 — Select New Central API

In the **Aruba Central Connection** card, select **New Central API**.

#### Step 2 — Enter Cluster URL

Use your region's CNX API base URL:

| Region | Cluster URL |
|---|---|
| US | `https://us1.api.central.arubanetworks.com` |
| EU | `https://eu1.api.central.arubanetworks.com` |
| Internal | `https://internal.api.central.arubanetworks.com` |

#### Step 3 — Get Client Credentials from HPE GreenLake

1. Log in to **HPE GreenLake** (`common.cloud.hpe.com`)
2. Go to **Manage** → **API Clients**
3. Create a new API client with **Aruba Central** scope
4. Copy the **Client ID** and **Client Secret**

> Tokens are automatically obtained and renewed by the dashboard using the GreenLake SSO endpoint — no manual token management needed. Tokens last 2 hours and are refreshed automatically.

#### Step 4 — Enter credentials

- **Client ID** — from HPE GreenLake API client
- **Client Secret** — from HPE GreenLake API client

#### Step 5 — Save & Test Connection

Click **Save & Test Connection**. The dashboard will authenticate with GreenLake and probe the CNX API.

---

### Site Mapping

Site mappings connect the `wsite` values in `simulation.conf` (which identify where a client is located) to the matching site names in Aruba Central.

1. Go to **Setup** → **Site Mappings**
2. Click **🔄 Load Sites** — this fetches:
   - **Local wsites** from `configs/simulation.conf` (e.g. `DFW`, `MIA`)
   - **Central sites** from the Aruba Central API
3. Use the dropdowns to match each local wsite to its Central site name
4. Click **Save Mappings**

If Central sites fail to load, local wsites still populate so you can type site names manually.

---

### Monitored Checks

Monitored checks define what the dashboard watches for in Central per site.

1. Go to **Setup** → **Monitored Checks**
2. Click **Load Checks** — this fetches alert types and AI insight categories from Central (30-day lookback). If no live alerts have fired, a standard list of known Aruba Central alert types is shown as a fallback.
3. Tick the alert types and insight categories you want to monitor
4. Click **Save Selection**

**Classic Central checks include:**
- Alert types: `AP_DOWN`, `CLIENT_DHCP_FAILURE`, `ROGUE_AP_DETECTED`, `SWITCH_DOWN`, `VPN_TUNNEL_DOWN`, etc.
- AI Insight categories: `CONNECTIVITY`, `PERFORMANCE`, `RELIABILITY`, `SECURITY`

**New Central checks include:**
- `SITE_HEALTH` — overall health score for the site
- `AP_COUNT` — number of APs reported by the site

---

### Central Monitoring Tab

The **🔗 Central** tab shows a card per mapped site. Each card displays:

- **OK** — monitored checks are passing (alerts present in Central as expected)
- **ERROR** — monitored checks are failing (alerts absent when they should be present)
- **Pending** — not yet polled

Click any site card to open the detail view, which shows:
- **Clients at Site** — simulation clients currently assigned to this site
- **Check Status** — per-check OK/ERROR status with last poll time
- **Active Alerts from Central** — real alerts from the Central API for this site (last 30 days), with severity, state, device, and message
- **Last 24 Hours** — historical check status over time

---

## Simulations Tab

### Drill-Down
- **Level 1**: Simulation check tiles for **SIM**, **HW**, **CC**, and **Monitored**
- **Level 2**: Click a sim tile to open the site list (for example `MIA`, `DFW`) with client count and Central status badge
- **Level 3**: Click a site to open the client list, where each client shows two indicators:
  - **SIM dot**: green = simulation running, yellow = online but not running, grey = offline
  - **ALERT dot**: green = Central alert firing, red = not firing, `N/A` = no check configured

### Hardware Alerts
- **Setup**: **Setup** → **Hardware Alerts** card → **Load Available Alert Types** → checkbox list → **Save Hardware Checks**
- **Monitoring**: The **Simulations** tab shows a **Hardware Alerts** section with green/red tiles
- **Drill-down level 1**: Click a tile to see the sites with affected devices
- **Drill-down level 2**: Device details currently render inline under each site

---

## API summary

| Method | Path | Description |
|---|---|---|
| `GET` | `/api/health` | Health check — includes installer version |
| `GET` | `/api/config?hostname=<h>` | Per-client simulation config |
| `GET` | `/api/scripts/list?platform=linux\|windows` | List available scripts |
| `GET` | `/api/scripts/{platform}/{filename}` | Download a script |
| `POST` | `/api/status` | Client beacon (heartbeat) |
| `GET` | `/api/clients` | List all known clients |
| `GET` | `/api/simulations` | Simulation groups with client counts and Central PASS/FAIL |
| `GET` | `/api/simulations/{sim_id}/clients` | Per-client status for one sim bucket |
| `GET` | `/api/hardware-alerts` | Current hardware alert devices merged with check metadata |
| `POST` | `/api/clients/{hostname}/control` | Push override to a client |
| `DELETE` | `/api/clients/{hostname}/control` | Clear client override |
| `POST` | `/api/clients/all/control` | Push override to all clients |
| `GET` | `/api/settings` | Get current dashboard settings |
| `POST` | `/api/settings` | Update dashboard settings |
| `POST` | `/api/notifications/test` | Send a test email or Teams card |
| `POST` | `/api/self-update` | Trigger an immediate self-update check |
| `POST` | `/api/central/test-connection` | Test Aruba Central token |
| `GET` | `/api/central/available` | Get available alert types and insight categories |
| `GET` | `/api/central/sites` | Get site list from Central |
| `GET` | `/api/central/site-alerts?site=<name>` | Get active alerts for a specific site |
| `GET` | `/api/central/status` | Current check status for all mapped sites |
| `GET` | `/api/central/history?site=<s>&hours=<h>` | Historical check records |
| `POST` | `/api/central/poll` | Trigger immediate Central poll |
| `GET` | `/api/local-wsites` | Extract wsite values from simulation.conf |
| `WS` | `/ws` | WebSocket for real-time updates |

