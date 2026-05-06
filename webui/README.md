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

## Environment variables

- `REPO_URL` - Git repository to clone/pull for served configs and scripts
- `REPO_BRANCH` - Branch to keep synced
- `REPO_DIR` - Local checkout path used by the API
- `OFFLINE_TIMEOUT` - Seconds before a client is shown offline

## Client connection

Clients should point `simulation.conf` to the dashboard:

```ini
[server]
server_url=http://sim-dashboard:8000
```

Clients POST beacons to `/api/status`, then pull `/api/config?hostname=<hostname>` on update cycles to receive any per-client overrides.

## API summary

- `GET /api/health`
- `GET /api/config?hostname=<hostname>`
- `GET /api/scripts/list?platform=linux|windows`
- `GET /api/scripts/{platform}/{filename}`
- `POST /api/status`
- `GET /api/clients`
- `POST /api/clients/{hostname}/control`
- `DELETE /api/clients/{hostname}/control`
- `POST /api/clients/all/control`
- `WS /ws`
