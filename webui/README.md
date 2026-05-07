# Client-Sim Dashboard

A FastAPI web dashboard for monitoring client-sim beacons, viewing client status, and pushing in-memory simulation overrides without a database or authentication layer.

## Run with Docker

```bash
cd webui
docker compose up --build
```

Open `http://localhost:8000`.

## Run with Python

```bash
cd webui
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
uvicorn server:app --host 0.0.0.0 --port 8000
```

## LXC Installer (Recommended for Production)

```bash
curl -fsSL https://raw.githubusercontent.com/solutions-hpe/client-sim/main/webui/install-lxc.sh | sudo bash
```

Or with options:

```bash
sudo bash install-lxc.sh --branch lrb --port 8000
```

The installer version is displayed in the top-right corner of the dashboard UI.

---

## Environment variables

| Variable | Default | Description |
|---|---|---|
| `REPO_URL` | `https://github.com/solutions-hpe/client-sim.git` | Git repo to sync |
| `REPO_BRANCH` | `main` | Branch to keep synced |
| `REPO_DIR` | `/app/client-sim` | Local checkout path |
| `OFFLINE_TIMEOUT` | `60` | Seconds before a client is shown offline |
| `PORT` | `8000` | TCP port to serve on |

---

## Client connection

Clients should point `simulation.conf` to the dashboard:

```ini
[server]
server_url=http://sim-dashboard:8000
```

Clients POST beacons to `/api/status`, then pull `/api/config?hostname=<hostname>` on update cycles to receive any per-client overrides.

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

## API summary

| Method | Path | Description |
|---|---|---|
| `GET` | `/api/health` | Health check — includes installer version |
| `GET` | `/api/config?hostname=<h>` | Per-client simulation config |
| `GET` | `/api/scripts/list?platform=linux\|windows` | List available scripts |
| `GET` | `/api/scripts/{platform}/{filename}` | Download a script |
| `POST` | `/api/status` | Client beacon (heartbeat) |
| `GET` | `/api/clients` | List all known clients |
| `POST` | `/api/clients/{hostname}/control` | Push override to a client |
| `DELETE` | `/api/clients/{hostname}/control` | Clear client override |
| `POST` | `/api/clients/all/control` | Push override to all clients |
| `GET` | `/api/settings` | Get current dashboard settings |
| `POST` | `/api/settings` | Update dashboard settings |
| `POST` | `/api/central/test-connection` | Test Aruba Central token |
| `GET` | `/api/central/available` | Get available alert types and insight categories |
| `GET` | `/api/central/sites` | Get site list from Central |
| `GET` | `/api/central/site-alerts?site=<name>` | Get active alerts for a specific site |
| `GET` | `/api/central/status` | Current check status for all mapped sites |
| `GET` | `/api/central/history?site=<s>&hours=<h>` | Historical check records |
| `POST` | `/api/central/poll` | Trigger immediate Central poll |
| `GET` | `/api/local-wsites` | Extract wsite values from simulation.conf |
| `WS` | `/ws` | WebSocket for real-time updates |

