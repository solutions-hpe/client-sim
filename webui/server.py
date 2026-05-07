from __future__ import annotations

import asyncio
import contextlib
import json
import logging
import os
import re
import time
from contextlib import asynccontextmanager
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import httpx
from fastapi import FastAPI, HTTPException, Query, WebSocket, WebSocketDisconnect
from fastapi.responses import FileResponse, PlainTextResponse
from fastapi.staticfiles import StaticFiles
from git import InvalidGitRepositoryError, Repo
from pydantic import BaseModel, Field

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("client_sim_dashboard")

BASE_DIR = Path(__file__).resolve().parent
STATIC_DIR = BASE_DIR / "static"
SETTINGS_FILE = BASE_DIR / "settings.json"
HISTORY_FILE = BASE_DIR / "central_history.jsonl"
REPO_DIR = Path(os.getenv("REPO_DIR", "/app/client-sim")).resolve()
REPO_URL = os.getenv("REPO_URL", "https://github.com/solutions-hpe/client-sim.git")

# Installer version — written by install-lxc.sh at install time
_version_file = BASE_DIR / "INSTALLER_VERSION"
INSTALLER_VERSION: str = _version_file.read_text().strip() if _version_file.exists() else "dev"
REPO_BRANCH = os.getenv("REPO_BRANCH", "main")
OFFLINE_TIMEOUT = int(os.getenv("OFFLINE_TIMEOUT", "60"))
# Max error entries kept per client in memory.
# WHY: errors accumulate over a long run; capping prevents unbounded memory growth.
MAX_CLIENT_ERRORS = 50
SYNC_INTERVAL = 300
HEARTBEAT_INTERVAL = 30
CENTRAL_POLL_INTERVAL = 900   # 15 minutes
HISTORY_HOURS = 24
UPDATE_CHECK_INTERVAL = 86400  # 24 hours

# Self-update: the installer lives inside the synced repo
_INSTALLER_PATH = REPO_DIR / "webui" / "install-lxc.sh"

update_state: dict[str, Any] = {
    "current_version": INSTALLER_VERSION,
    "available_version": None,
    "update_available": False,
    "last_checked": None,
    "update_in_progress": False,
    "update_log": [],
}


# ── Runtime settings (persisted to settings.json) ────────────────────────────
def _load_persisted_settings() -> dict[str, Any]:
    try:
        return json.loads(SETTINGS_FILE.read_text(encoding="utf-8"))
    except Exception:
        return {}


def _save_settings() -> None:
    try:
        SETTINGS_FILE.write_text(json.dumps(settings, indent=2), encoding="utf-8")
    except Exception as exc:
        logger.warning("Could not persist settings to %s: %s", SETTINGS_FILE, exc)


_persisted = _load_persisted_settings()
settings: dict[str, Any] = {
    "repo_branch": _persisted.get("repo_branch", REPO_BRANCH),
    "central_config": _persisted.get("central_config", {
        "api_version": "classic",   # "classic" | "new_central"
        "cluster_url": "",
        "access_token": "",
        "refresh_token": "",
        "client_id": "",
        "client_secret": "",
        "customer_id": "",
    }),
    # {wsite_value: central_site_name}
    "site_mappings": _persisted.get("site_mappings", {}),
    # [{type: "alert"|"insight", id: "...", name: "..."}]
    "monitored_checks": _persisted.get("monitored_checks", []),
}

# Initialise in-memory token from persisted values so a restart
# doesn't require the user to re-enter credentials.
_stored_cfg = settings["central_config"]
_is_new_central = _stored_cfg.get("api_version") == "new_central"
if not _is_new_central and _stored_cfg.get("access_token"):
    # Classic: restore pasted token from disk
    central_token: dict[str, Any] = {
        "access_token": _stored_cfg["access_token"],
        "refresh_token": _stored_cfg.get("refresh_token"),
        "expires_at": time.time() + 7200,
    }
else:
    # New Central: token will be fetched automatically via client_credentials
    central_token: dict[str, Any] = {
        "access_token": None,
        "refresh_token": None,
        "expires_at": 0.0,
    }

ALLOWED_PLATFORMS = {"linux", "windows"}
SIMULATION_SECTION_KEYS = {
    "wsite",
    "ssid",
    "ssidpw",
    "dhcp_fail",
    "dns_fail",
    "assoc_fail",
    "port_flap",
    "ping_test",
    "download",
    "www_traffic",
    "iperf",
    "sim_phy",
}
GLOBAL_SECTION_KEYS = {
    "kill_switch",
    "rapid_update",
    "sim_load",
    "public_repo",
    "repo_location",
    "repo_branch",
    "vh_server",
    "site_based_ssid",
    "site_based_num",
    "reboot_schedule",
    "allow_offline",
    "ssidpw_fail",
    "auth_fail",
    "iperf_bw",
    "syslog",
    "web_server",
}
SERVER_SECTION_KEYS = {"server_url"}
ADDRESS_SECTION_KEYS = {
    "smb_address",
    "ping_address",
    "dns_latency_1",
    "dns_latency_2",
    "dns_latency_3",
    "dns_bad_ip_1",
    "dns_bad_ip_2",
    "dns_bad_ip_3",
    "dns_bad_record_1",
    "dns_bad_record_2",
    "dns_bad_record_3",
    "iperf_server",
    "syslog_server",
    "vh_server_addr",
}


# ── Aruba Central state ───────────────────────────────────────────────────────
# central_token is declared above, initialised from persisted settings.
# {wsite: {check_id: {status, count, ts, check_name, check_type}}}
central_status: dict[str, dict[str, Any]] = {}
central_history: list[dict[str, Any]] = []   # in-memory 24-h window
history_lock = asyncio.Lock()


# ── History file helpers ──────────────────────────────────────────────────────
def _history_cutoff() -> float:
    return time.time() - HISTORY_HOURS * 3600


def _load_history() -> list[dict[str, Any]]:
    """Load last 24 h from the JSONL file into memory."""
    if not HISTORY_FILE.exists():
        return []
    cutoff = _history_cutoff()
    result: list[dict[str, Any]] = []
    try:
        for line in HISTORY_FILE.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                record = json.loads(line)
                if record.get("ts", 0) >= cutoff:
                    result.append(record)
            except json.JSONDecodeError:
                pass
    except Exception as exc:
        logger.warning("Could not read history file: %s", exc)
    return result


def _append_and_trim_history(new_records: list[dict[str, Any]]) -> None:
    """Append new records to the JSONL file and remove lines older than 24 h."""
    cutoff = _history_cutoff()
    existing: list[str] = []
    if HISTORY_FILE.exists():
        try:
            for line in HISTORY_FILE.read_text(encoding="utf-8").splitlines():
                line = line.strip()
                if not line:
                    continue
                try:
                    rec = json.loads(line)
                    if rec.get("ts", 0) >= cutoff:
                        existing.append(line)
                except json.JSONDecodeError:
                    pass
        except Exception as exc:
            logger.warning("Could not read history file for trimming: %s", exc)

    for record in new_records:
        existing.append(json.dumps(record))

    try:
        HISTORY_FILE.write_text("\n".join(existing) + "\n", encoding="utf-8")
    except Exception as exc:
        logger.warning("Could not write history file: %s", exc)


# ── Aruba Central OAuth helpers ───────────────────────────────────────────────
def _central_cfg() -> dict[str, str]:
    return settings.get("central_config", {})


def _is_new_central_api() -> bool:
    return _central_cfg().get("api_version") == "new_central"


def _central_ready() -> bool:
    """Minimum config needed to make API calls."""
    cfg = _central_cfg()
    if not cfg.get("cluster_url"):
        return False
    if _is_new_central_api():
        # New Central: need client_id + client_secret to auto-fetch tokens
        return bool(cfg.get("client_id") and cfg.get("client_secret"))
    # Classic: need a token already loaded or stored
    return bool(cfg.get("access_token") or central_token.get("access_token"))


def _can_refresh() -> bool:
    """True when we can obtain a fresh token automatically."""
    cfg = _central_cfg()
    if not cfg.get("cluster_url") or not cfg.get("client_id") or not cfg.get("client_secret"):
        return False
    if _is_new_central_api():
        return True  # New Central uses client_credentials — no refresh token needed
    return bool(cfg.get("refresh_token") or central_token.get("refresh_token"))


# New Central GLP SSO token endpoint
_NEW_CENTRAL_TOKEN_URL = "https://sso.common.cloud.hpe.com/as/token.oauth2"


async def _fetch_new_central_token(client: httpx.AsyncClient) -> tuple[bool, str]:
    """Obtain a token for New Central via HPE GreenLake client_credentials grant."""
    cfg = _central_cfg()
    try:
        resp = await client.post(
            _NEW_CENTRAL_TOKEN_URL,
            data={
                "grant_type": "client_credentials",
                "client_id": cfg["client_id"],
                "client_secret": cfg["client_secret"],
            },
            headers={"Content-Type": "application/x-www-form-urlencoded"},
            timeout=15,
        )
        if not resp.is_success:
            return False, f"Token request failed (HTTP {resp.status_code}): {resp.text[:300]}"
        payload = resp.json()
        token = payload.get("access_token")
        if not token:
            return False, f"No access_token in GLP response: {resp.text[:300]}"
        expires_in = payload.get("expires_in", 7200)
        central_token["access_token"] = token
        central_token["refresh_token"] = None
        central_token["expires_at"] = time.time() + expires_in - 60
        logger.info("New Central token obtained via client_credentials (expires in %ss)", expires_in)
        return True, "Token obtained via client_credentials."
    except Exception as exc:
        return False, f"GLP token request error: {exc}"


async def _fetch_central_token(client: httpx.AsyncClient) -> tuple[bool, str]:
    """Load/obtain the access token and verify it against a probe endpoint.

    For New Central: obtains a token via GLP client_credentials grant.
    For Classic: loads the user-pasted token from settings and probes the API.
    Returns (success, detail_message).
    """
    if _is_new_central_api():
        ok, msg = await _fetch_new_central_token(client)
        if not ok:
            return False, msg
        # Probe to confirm the token works against the base URL
        return await _probe_central_token(client)

    cfg = _central_cfg()
    token = cfg.get("access_token", "").strip()
    if not token:
        return False, "No access token configured."

    central_token["access_token"] = token
    if cfg.get("refresh_token"):
        central_token["refresh_token"] = cfg["refresh_token"]
    central_token["expires_at"] = time.time() + 7200

    return await _probe_central_token(client)


async def _probe_central_token(client: httpx.AsyncClient) -> tuple[bool, str]:
    """Probe the Central API to confirm the in-memory token is accepted."""
    cfg = _central_cfg()
    base_url = cfg["cluster_url"].rstrip("/")
    token = central_token.get("access_token", "")
    headers = {"Authorization": f"Bearer {token}"}

    if _is_new_central_api():
        # New Central v1alpha1 — sites-health is the lightest reliable endpoint
        probe_urls = [
            (f"{base_url}/network-monitoring/v1alpha1/sites-health", {}),
            (f"{base_url}/network-monitoring/v1alpha1/devices", {"limit": 1}),
        ]
    else:
        # Classic Central
        probe_urls = [
            (f"{base_url}/configuration/v2/groups", {"limit": 1, "offset": 0}),
            (f"{base_url}/monitoring/v1/alerts", {"limit": 1}),
            (f"{base_url}/monitoring/v2/alerts", {"limit": 1}),
            (f"{base_url}/platform/v1/customer_id", {}),
        ]
    last_status: int = 0
    last_body: str = ""
    for url, params in probe_urls:
        try:
            logger.info("Central probe → GET %s params=%s", url, params)
            resp = await client.get(url, headers=headers, params=params, timeout=15)
            last_status = resp.status_code
            last_body = resp.text[:400]
            logger.info("Central probe ← %s: %s", resp.status_code, last_body[:200])
            if resp.status_code == 200:
                logger.info("Aruba Central token validated via %s", url)
                return True, "Token validated successfully."
            if resp.status_code == 401:
                # Token is definitely invalid — try refresh before giving up
                central_token["access_token"] = None
                ok, msg = await _refresh_central_token(client)
                if ok:
                    return True, f"Access token was expired; successfully refreshed. {msg}"
                return False, f"Token rejected (401). Central response: {last_body}"
            if resp.status_code == 400:
                # 400 means the endpoint exists and accepted our token but wants different params.
                # That's enough to confirm the token is valid.
                logger.info("Central token confirmed via %s (400 = endpoint live, token accepted)", url)
                return True, "Token validated successfully (endpoint reachable, token accepted)."
            # 403/404 = wrong scope or endpoint missing — try next probe
            logger.info("Central probe %s returned %s — trying next", url, resp.status_code)
        except Exception as exc:
            return False, f"Connection error reaching {base_url}: {exc}"

    return False, (
        f"Could not confirm token with Central (last HTTP status: {last_status}). "
        f"Response: {last_body}. "
        "Check the Cluster URL and that the token has monitoring or configuration scope."
    )


async def _refresh_central_token(client: httpx.AsyncClient) -> tuple[bool, str]:
    """Refresh/renew the access token.

    New Central: re-requests via GLP client_credentials (no refresh token).
    Classic: uses refresh_token grant against Central's OAuth endpoint.
    Returns (success, detail_message).
    """
    if not _can_refresh():
        return False, "Cannot refresh: missing client_id or client_secret."
    if _is_new_central_api():
        return await _fetch_new_central_token(client)
    cfg = _central_cfg()
    token_url = cfg["cluster_url"].rstrip("/") + "/oauth2/token"
    refresh_tok = cfg.get("refresh_token") or central_token.get("refresh_token", "")
    data: dict[str, str] = {
        "grant_type": "refresh_token",
        "client_id": cfg["client_id"],
        "client_secret": cfg["client_secret"],
        "refresh_token": refresh_tok,
    }
    if cfg.get("customer_id"):
        data["customer_id"] = cfg["customer_id"]
    try:
        resp = await client.post(token_url, data=data, timeout=15)
        if not resp.is_success:
            return False, f"Refresh failed (HTTP {resp.status_code}): {resp.text[:300]}"
        payload = resp.json()
        new_access = payload["access_token"]
        new_refresh = payload.get("refresh_token", refresh_tok)
        central_token["access_token"] = new_access
        central_token["refresh_token"] = new_refresh
        central_token["expires_at"] = time.time() + payload.get("expires_in", 7200) - 60
        settings["central_config"]["access_token"] = new_access
        settings["central_config"]["refresh_token"] = new_refresh
        _save_settings()
        logger.info("Aruba Central token refreshed successfully")
        return True, "Token refreshed successfully."
    except Exception as exc:
        return False, f"Refresh request failed: {exc}"


def _central_headers() -> dict[str, str]:
    token = central_token.get("access_token")
    if not token:
        raise HTTPException(status_code=503, detail="Aruba Central token not available — check connection settings")
    return {"Authorization": f"Bearer {token}"}


async def central_token_manager() -> None:
    """Background task: keep token valid. Runs every 5 minutes."""
    async with httpx.AsyncClient() as client:
        while True:
            try:
                if _central_ready():
                    no_token = not central_token.get("access_token")
                    expiring = time.time() >= central_token.get("expires_at", 0) - 300
                    if no_token:
                        ok, msg = await _fetch_central_token(client)
                        if not ok:
                            logger.warning("Central token load failed: %s", msg)
                    elif expiring and _can_refresh():
                        ok, msg = await _refresh_central_token(client)
                        if not ok:
                            logger.warning("Central token refresh failed: %s", msg)
            except asyncio.CancelledError:
                raise
            except Exception as exc:
                logger.exception("Central token manager error: %s", exc)
            await asyncio.sleep(300)


# ── Aruba Central poll loop ───────────────────────────────────────────────────
async def _poll_central_once(client: httpx.AsyncClient) -> None:
    """Single poll cycle: fetch alerts + insights per mapped site, evaluate checks."""
    if not _central_ready() or not central_token.get("access_token"):
        return

    site_mappings: dict[str, str] = settings.get("site_mappings", {})
    monitored: list[dict[str, Any]] = settings.get("monitored_checks", [])
    if not site_mappings or not monitored:
        return

    cfg = _central_cfg()
    base_url = cfg["cluster_url"].rstrip("/")
    headers = _central_headers()
    now = time.time()
    new_records: list[dict[str, Any]] = []

    for wsite, central_site in site_mappings.items():
        site_check_status: dict[str, Any] = {}

        # ── Fetch alerts for this site ────────────────────────────
        alert_type_counts: dict[str, int] = {}
        site_health: dict[str, Any] = {}

        if _is_new_central_api():
            # New Central v1alpha1: no alerts endpoint yet — use sites-health
            # and AP status per site for monitoring
            try:
                resp = await client.get(
                    f"{base_url}/network-monitoring/v1alpha1/sites-health",
                    headers=headers,
                    timeout=20,
                )
                if resp.status_code == 401 and _can_refresh():
                    ok, _ = await _refresh_central_token(client)
                    if ok:
                        headers = _central_headers()
                    resp = await client.get(
                        f"{base_url}/network-monitoring/v1alpha1/sites-health",
                        headers=headers,
                        timeout=20,
                    )
                if resp.status_code == 200:
                    for item in resp.json().get("items", []):
                        sname = item.get("siteName") or item.get("site_name") or ""
                        if sname.lower() == central_site.lower():
                            site_health = item
                            # Map health fields to synthetic alert_type_counts
                            # so existing check evaluation logic still works
                            score = item.get("healthScore", item.get("health_score", 100))
                            ap_count = item.get("apCount", item.get("ap_count", 0))
                            alert_type_counts["SITE_HEALTH"] = int(score)
                            alert_type_counts["AP_COUNT"] = int(ap_count)
                            break
            except Exception as exc:
                logger.warning("New Central sites-health fetch failed for site %s: %s", central_site, exc)

            # New Central: no insights endpoint either — skip
            insight_cat_counts: dict[str, int] = {}
        else:
            for alerts_path in ["/monitoring/v1/alerts", "/monitoring/v2/alerts"]:
                try:
                    resp = await client.get(
                        f"{base_url}{alerts_path}",
                        headers=headers,
                        params={"site": central_site, "limit": 1000},
                        timeout=20,
                    )
                    if resp.status_code == 401 and _can_refresh():
                        ok, _ = await _refresh_central_token(client)
                        if ok:
                            headers = _central_headers()
                        resp = await client.get(
                            f"{base_url}{alerts_path}",
                            headers=headers,
                            params={"site": central_site, "limit": 1000},
                            timeout=20,
                        )
                    if resp.status_code == 200:
                        data = resp.json()
                        for alert in data.get("alerts", []):
                            atype = alert.get("alert_type") or alert.get("type", "")
                            if atype:
                                alert_type_counts[atype] = alert_type_counts.get(atype, 0) + 1
                        break
                    if resp.status_code == 404:
                        continue
                except Exception as exc:
                    logger.warning("Central alerts fetch failed for site %s: %s", central_site, exc)
                    break

            # ── Fetch insights for this site ──────────────────────────
            insight_cat_counts: dict[str, int] = {}
            try:
                resp = await client.get(
                    f"{base_url}/aiops/v1/insights",
                    headers=headers,
                    params={"site_name": central_site, "limit": 1000},
                    timeout=20,
                )
                if resp.status_code == 200:
                    data = resp.json()
                    for insight in data.get("insights", []):
                        cat = insight.get("category") or insight.get("type", "")
                        if cat:
                            insight_cat_counts[cat] = insight_cat_counts.get(cat, 0) + 1
            except Exception as exc:
                logger.warning("Central insights fetch failed for site %s: %s", central_site, exc)

        # ── Evaluate each monitored check ─────────────────────────
        for check in monitored:
            check_type = check.get("type", "")
            check_id = check.get("id", "")
            check_name = check.get("name", check_id)
            if not check_id:
                continue

            if check_type == "alert":
                count = alert_type_counts.get(check_id, 0)
            elif check_type == "insight":
                count = insight_cat_counts.get(check_id, 0)
            else:
                continue

            status = "OK" if count > 0 else "ERROR"
            site_check_status[check_id] = {
                "status": status,
                "count": count,
                "check_name": check_name,
                "check_type": check_type,
                "ts": now,
            }
            new_records.append({
                "ts": now,
                "wsite": wsite,
                "central_site": central_site,
                "check_type": check_type,
                "check_id": check_id,
                "check_name": check_name,
                "status": status,
                "count": count,
            })

        central_status[wsite] = site_check_status

    # ── Persist history ───────────────────────────────────────────
    if new_records:
        cutoff = _history_cutoff()
        async with history_lock:
            central_history[:] = [r for r in central_history if r["ts"] >= cutoff]
            central_history.extend(new_records)
        await asyncio.to_thread(_append_and_trim_history, new_records)

    await broadcast({"type": "central_update", "status": _central_status_payload(), "ts": now})


def _central_status_payload() -> dict[str, Any]:
    """Serialize current central_status for WS / API responses."""
    return {
        wsite: {
            check_id: {
                "status": info["status"],
                "count": info["count"],
                "check_name": info["check_name"],
                "check_type": info["check_type"],
                "ts": info["ts"],
            }
            for check_id, info in checks.items()
        }
        for wsite, checks in central_status.items()
    }


async def central_poller() -> None:
    """Background task: poll Central every CENTRAL_POLL_INTERVAL seconds."""
    async with httpx.AsyncClient() as client:
        while True:
            try:
                await _poll_central_once(client)
            except asyncio.CancelledError:
                raise
            except Exception as exc:
                logger.exception("Central poll error: %s", exc)
            await asyncio.sleep(CENTRAL_POLL_INTERVAL)


@asynccontextmanager
async def lifespan(app: FastAPI):  # noqa: ARG001
    global central_history
    logger.info("=" * 60)
    logger.info("Client-Sim Dashboard  v%s  starting up", INSTALLER_VERSION)
    logger.info("=" * 60)
    central_history = await asyncio.to_thread(_load_history)
    background_tasks["repo_sync"] = asyncio.create_task(sync_repo())
    background_tasks["heartbeat"] = asyncio.create_task(heartbeat_check())
    background_tasks["central_token"] = asyncio.create_task(central_token_manager())
    background_tasks["central_poller"] = asyncio.create_task(central_poller())
    background_tasks["update_checker"] = asyncio.create_task(check_for_update())
    yield
    for task in background_tasks.values():
        task.cancel()
    for task in background_tasks.values():
        with contextlib.suppress(asyncio.CancelledError):
            await task


app = FastAPI(title="Client-Sim Dashboard", lifespan=lifespan)
clients: dict[str, dict[str, Any]] = {}
ws_connections: list[WebSocket] = []
state_lock = asyncio.Lock()
repo_state = {"synced": False, "error": None}
background_tasks: dict[str, asyncio.Task[Any]] = {}


class ClientStatus(BaseModel):
    hostname: str
    simulation_id: str
    platform: str
    iteration: int
    connected_ssid: str | None = None
    gateway_reachable: bool
    vh_connected: bool = False
    active_simulations: list[str] = Field(default_factory=list)
    config: dict[str, str] = Field(default_factory=dict)
    # errors: list of human-readable error strings that occurred since the last
    # status report. The client accumulates them between reports and sends the
    # whole batch here. WHY: we want errors visible in the dashboard, not buried
    # in client-side log files that no operator can easily read remotely.
    errors: list[str] = Field(default_factory=list)


class ClientControlResponse(BaseModel):
    hostname: str
    overrides: dict[str, str]
    client: dict[str, Any]


class SettingsUpdate(BaseModel):
    repo_branch: str | None = None
    central_config: dict[str, str] | None = None
    site_mappings: dict[str, str] | None = None
    monitored_checks: list[dict[str, str]] | None = None


def utcnow() -> datetime:
    return datetime.now(timezone.utc)


def compute_online(last_seen: datetime) -> bool:
    return (utcnow() - last_seen).total_seconds() <= OFFLINE_TIMEOUT


def serialize_client(hostname: str, client: dict[str, Any]) -> dict[str, Any]:
    config = {key: str(value) for key, value in client.get("config", {}).items()}
    overrides = {key: str(value) for key, value in client.get("overrides", {}).items()}
    effective_config = {**config, **overrides}
    last_seen = client["last_seen"]
    online = compute_online(last_seen)

    return {
        "hostname": hostname,
        "simulation_id": client.get("simulation_id", ""),
        "platform": client.get("platform", ""),
        "iteration": client.get("iteration", 0),
        "connected_ssid": client.get("connected_ssid") or "",
        "gateway_reachable": bool(client.get("gateway_reachable", False)),
        "vh_connected": bool(client.get("vh_connected", False)),
        "active_simulations": list(client.get("active_simulations", [])),
        "config": config,
        "effective_config": effective_config,
        "overrides": overrides,
        "last_seen": last_seen.astimezone(timezone.utc).isoformat().replace("+00:00", "Z"),
        "online": online,
        # recent_errors: circular buffer of the last MAX_CLIENT_ERRORS entries.
        # Each entry has a timestamp and message so operators know when errors occurred.
        "recent_errors": list(client.get("recent_errors", [])),
        "error_count": int(client.get("error_count", 0)),
    }


async def current_clients() -> list[dict[str, Any]]:
    async with state_lock:
        return [serialize_client(hostname, clients[hostname]) for hostname in sorted(clients)]


async def broadcast(message: dict[str, Any]) -> None:
    if not ws_connections:
        return

    payload = json.dumps(message)
    stale: list[WebSocket] = []
    for websocket in list(ws_connections):
        try:
            await websocket.send_text(payload)
        except Exception:
            stale.append(websocket)

    for websocket in stale:
        with contextlib.suppress(ValueError):
            ws_connections.remove(websocket)


async def broadcast_full_state() -> None:
    await broadcast({"type": "full_state", "clients": await current_clients()})


def ensure_repo_ready() -> None:
    if not repo_state["synced"]:
        detail = "Repository has not been synced yet."
        if repo_state["error"]:
            detail = f"Repository not ready: {repo_state['error']}"
        raise HTTPException(status_code=503, detail=detail)


def repo_path(*parts: str) -> Path:
    ensure_repo_ready()
    path = REPO_DIR.joinpath(*parts)
    if not path.exists():
        raise HTTPException(status_code=404, detail=f"Repo file not found: {'/'.join(parts)}")
    return path


def validate_platform(platform: str) -> str:
    if platform not in ALLOWED_PLATFORMS:
        raise HTTPException(status_code=404, detail="Unsupported platform")
    return platform


def override_section_name(key: str, simulation_id: str | None) -> str | None:
    if key in SIMULATION_SECTION_KEYS:
        return simulation_id
    if key in GLOBAL_SECTION_KEYS:
        return "simulation"
    if key in SERVER_SECTION_KEYS:
        return "server"
    if key in ADDRESS_SECTION_KEYS:
        return "address"
    return simulation_id


def apply_overrides(config_text: str, client: dict[str, Any]) -> str:
    overrides = {key: str(value) for key, value in client.get("overrides", {}).items()}
    if not overrides:
        return config_text

    pattern = re.compile(r"^\s*\[(?P<section>[^\]]+)\]\s*$")
    key_pattern = re.compile(r"^\s*(?P<key>[^=\s#;]+)\s*=")
    section_keys: dict[str, set[str]] = {}
    current_section: str | None = None

    for line in config_text.splitlines():
        match = pattern.match(line)
        if match:
            current_section = match.group("section")
            section_keys.setdefault(current_section, set())
            continue
        if current_section:
            key_match = key_pattern.match(line)
            if key_match:
                section_keys.setdefault(current_section, set()).add(key_match.group("key"))

    hostname = str(client.get("hostname", ""))
    user_candidates = [hostname, hostname.split("-")[0] if hostname else ""]
    user_section = next((candidate for candidate in user_candidates if candidate and candidate in section_keys), None)

    simulation_id = client.get("simulation_id")
    replacements: dict[str, dict[str, str]] = {}
    for key, value in overrides.items():
        section = None
        if user_section and key in section_keys.get(user_section, set()):
            section = user_section
        if not section:
            section = override_section_name(key, simulation_id)
        if not section:
            continue
        replacements.setdefault(section, {})[key] = value

    current_section = None
    updated_lines: list[str] = []
    for line in config_text.splitlines():
        match = pattern.match(line)
        if match:
            current_section = match.group("section")
            updated_lines.append(line)
            continue

        if current_section and current_section in replacements:
            for key, value in replacements[current_section].items():
                if re.match(rf"^\s*{re.escape(key)}\s*=", line):
                    line = re.sub(rf"^(\s*{re.escape(key)}\s*=).*$", rf"\1{value}", line)
                    break

        updated_lines.append(line)

    if config_text.endswith("\n"):
        return "\n".join(updated_lines) + "\n"
    return "\n".join(updated_lines)


def sync_repo_once() -> None:
    branch = settings["repo_branch"]
    REPO_DIR.parent.mkdir(parents=True, exist_ok=True)

    if not REPO_DIR.exists() or not any(REPO_DIR.iterdir()):
        logger.info("Cloning %s (%s) into %s", REPO_URL, branch, REPO_DIR)
        Repo.clone_from(REPO_URL, REPO_DIR, branch=branch, single_branch=True)
        return

    try:
        repo = Repo(REPO_DIR)
    except InvalidGitRepositoryError as exc:
        raise RuntimeError(f"{REPO_DIR} exists but is not a git repository") from exc

    origin = repo.remotes.origin
    logger.info("Pulling latest repo state from %s branch %s", REPO_URL, branch)
    origin.fetch(prune=True)
    repo.git.checkout(branch)
    origin.pull(branch)
    repo.git.reset("--hard", f"origin/{branch}")


async def sync_repo() -> None:
    while True:
        try:
            await asyncio.to_thread(sync_repo_once)
            repo_state["synced"] = True
            repo_state["error"] = None
            await broadcast({"type": "repo_status", "synced": True, "error": None})
        except asyncio.CancelledError:
            raise
        except Exception as exc:
            repo_state["error"] = str(exc)
            logger.exception("Repository sync failed")
            await broadcast({"type": "repo_status", "synced": repo_state["synced"], "error": str(exc)})
        await asyncio.sleep(SYNC_INTERVAL)


def _get_repo_version() -> str | None:
    """Read VERSION= from the synced install-lxc.sh in the repo."""
    try:
        text = _INSTALLER_PATH.read_text()
        for line in text.splitlines():
            line = line.strip()
            if line.startswith("VERSION="):
                return line.split("=", 1)[1].strip().strip('"').strip("'")
    except Exception:
        pass
    return None


async def check_for_update() -> None:
    """Background task: check for a new installer version every 24 hours."""
    while True:
        available = await asyncio.to_thread(_get_repo_version)
        import datetime
        update_state["available_version"] = available
        update_state["last_checked"] = datetime.datetime.now().isoformat(timespec="seconds")
        update_state["update_available"] = (
            available is not None
            and available != update_state["current_version"]
        )
        logger.info(
            "Version check: installed=%s repo=%s update_available=%s",
            update_state["current_version"],
            available,
            update_state["update_available"],
        )
        await broadcast({"type": "version_status", **update_state})
        if update_state["update_available"]:
            logger.info("New version %s available — triggering self-update", available)
            await _run_self_update()
        await asyncio.sleep(UPDATE_CHECK_INTERVAL)


async def _run_self_update() -> None:
    """Re-run the installer from the synced repo. Systemd will restart the service."""
    if update_state["update_in_progress"]:
        return
    if not _INSTALLER_PATH.exists():
        logger.error("Self-update: installer not found at %s", _INSTALLER_PATH)
        return
    update_state["update_in_progress"] = True
    update_state["update_log"] = []
    await broadcast({"type": "version_status", **update_state})
    try:
        logger.info("Self-update: running %s", _INSTALLER_PATH)
        proc = await asyncio.create_subprocess_exec(
            "sudo", "bash", str(_INSTALLER_PATH),
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.STDOUT,
        )
        assert proc.stdout is not None
        async for raw in proc.stdout:
            line = raw.decode(errors="replace").rstrip()
            update_state["update_log"].append(line)
            logger.info("self-update: %s", line)
        await proc.wait()
        logger.info("Self-update process exited with code %s", proc.returncode)
        # Systemd will restart us; if we're still running, clear the flag
        update_state["update_in_progress"] = False
        await broadcast({"type": "version_status", **update_state})
    except Exception as exc:
        logger.exception("Self-update failed")
        update_state["update_in_progress"] = False
        update_state["update_log"].append(f"ERROR: {exc}")
        await broadcast({"type": "version_status", **update_state})


async def heartbeat_check() -> None:
    while True:
        await asyncio.sleep(HEARTBEAT_INTERVAL)
        changed = False
        async with state_lock:
            for client in clients.values():
                online = compute_online(client["last_seen"])
                if client.get("online") != online:
                    client["online"] = online
                    changed = True
        if changed:
            await broadcast_full_state()


@app.get("/api/settings")
async def api_settings_get() -> dict[str, Any]:
    cfg = dict(settings["central_config"])
    # Strip all secrets — return only non-sensitive fields + presence flags
    for secret_key in ("client_secret", "access_token", "refresh_token"):
        cfg.pop(secret_key, None)
    cfg["access_token_configured"] = bool(settings["central_config"].get("access_token") or central_token.get("access_token"))
    cfg["refresh_token_configured"] = bool(settings["central_config"].get("refresh_token") or central_token.get("refresh_token"))
    cfg["client_secret_configured"] = bool(settings["central_config"].get("client_secret"))
    return {
        "repo_url": REPO_URL,
        "repo_branch": settings["repo_branch"],
        "central_config": cfg,
        "site_mappings": settings["site_mappings"],
        "monitored_checks": settings["monitored_checks"],
    }


@app.post("/api/settings")
async def api_settings_update(update: SettingsUpdate) -> dict[str, Any]:
    changed_branch = False

    if update.repo_branch is not None:
        branch = update.repo_branch.strip()
        if not branch or not re.match(r'^[a-zA-Z0-9._/\-]+$', branch):
            raise HTTPException(status_code=422, detail="Invalid branch name")
        settings["repo_branch"] = branch
        changed_branch = True

    if update.central_config is not None:
        merged = dict(settings["central_config"])
        # Only update keys that are explicitly provided and non-empty for secrets
        for key in ("cluster_url", "client_id", "customer_id", "api_version"):
            if key in update.central_config:
                merged[key] = update.central_config[key].strip()
        for secret_key in ("client_secret", "access_token", "refresh_token"):
            val = update.central_config.get(secret_key, "").strip()
            if val:  # blank = keep existing
                merged[secret_key] = val
        # Switching to New Central — clear stale classic tokens from runtime
        if merged.get("api_version") == "new_central":
            central_token["access_token"] = None
            central_token["refresh_token"] = None
            central_token["expires_at"] = 0.0
        settings["central_config"] = merged
        # Classic: load new tokens into runtime state immediately
        if merged.get("api_version", "classic") == "classic":
            if merged.get("access_token"):
                central_token["access_token"] = merged["access_token"]
                central_token["expires_at"] = time.time() + 7200
            if merged.get("refresh_token"):
                central_token["refresh_token"] = merged["refresh_token"]

    if update.site_mappings is not None:
        settings["site_mappings"] = {k.strip(): v.strip() for k, v in update.site_mappings.items() if k.strip()}

    if update.monitored_checks is not None:
        settings["monitored_checks"] = [
            {"type": c.get("type", ""), "id": c.get("id", ""), "name": c.get("name", c.get("id", ""))}
            for c in update.monitored_checks
            if c.get("type") and c.get("id")
        ]

    _save_settings()

    if changed_branch:
        if "repo_sync" in background_tasks:
            background_tasks["repo_sync"].cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await background_tasks["repo_sync"]
        background_tasks["repo_sync"] = asyncio.create_task(sync_repo())

    payload = {
        "repo_url": REPO_URL,
        "repo_branch": settings["repo_branch"],
    }
    await broadcast({"type": "settings_update", "settings": payload})
    return {"status": "ok", "settings": payload}


# ── Aruba Central API endpoints ───────────────────────────────────────────────
@app.post("/api/central/test-connection")
async def api_central_test() -> dict[str, Any]:
    if not _central_ready():
        raise HTTPException(
            status_code=422,
            detail="Aruba Central not configured — enter your Cluster URL and Access Token in Setup.",
        )
    async with httpx.AsyncClient() as client:
        ok, detail_msg = await _fetch_central_token(client)
    if ok:
        can_rf = _can_refresh()
        return {
            "status": "ok",
            "message": (
                "Connected to Aruba Central successfully. "
                + ("Auto-refresh enabled (refresh token + client credentials present)."
                   if can_rf else
                   "Auto-refresh not configured — add Refresh Token, Client ID, and Client Secret to enable it.")
            ),
        }
    raise HTTPException(status_code=502, detail=detail_msg)


@app.get("/api/central/available")
async def api_central_available() -> dict[str, Any]:
    """Return available alert types and insight categories from Central. Always returns 200."""
    if not _central_ready():
        return {"alerts": [], "insights": [], "warning": "Central not configured."}
    if not central_token.get("access_token"):
        return {"alerts": [], "insights": [], "warning": "No valid token — save & test connection first."}

    # New Central v1alpha1 has no alerts/insights endpoints — return static synthetic checks
    if _is_new_central_api():
        return {
            "alerts": [
                {"id": "SITE_HEALTH", "name": "Site Health Score"},
                {"id": "AP_COUNT",    "name": "AP Count"},
            ],
            "insights": [],
            "warning": None,
        }

    # Static fallback list of well-known Aruba Central alert types (used when no live alerts exist)
    KNOWN_ALERT_TYPES: dict[str, str] = {
        "AP_DOWN": "AP Down",
        "AP_UP": "AP Up",
        "ACCESS_POINT_DOWN": "Access Point Down",
        "CLIENT_ASSOCIATION_FAILURE": "Client Association Failure",
        "CLIENT_DHCP_FAILURE": "Client DHCP Failure",
        "CLIENT_DISCONNECTED": "Client Disconnected",
        "DHCP_POOL_EXHAUSTED": "DHCP Pool Exhausted",
        "IDS_AP_SPOOFED": "IDS AP Spoofed",
        "PORTAL_DOWN": "Portal Down",
        "RADIO_INTERFERENCE": "Radio Interference",
        "ROGUE_AP_DETECTED": "Rogue AP Detected",
        "SWITCH_DOWN": "Switch Down",
        "SWITCH_PORT_DOWN": "Switch Port Down",
        "TUNNEL_DOWN": "Tunnel Down",
        "UPLINK_FAILURE": "Uplink Failure",
        "VPN_TUNNEL_DOWN": "VPN Tunnel Down",
        "WIRELESS_CLIENT_ROAM": "Wireless Client Roam",
        "WIRELESS_INTERFERENCE": "Wireless Interference",
    }
    KNOWN_INSIGHT_CATEGORIES: dict[str, str] = {
        "CONNECTIVITY": "Connectivity",
        "PERFORMANCE": "Performance",
        "RELIABILITY": "Reliability",
        "SECURITY": "Security",
    }

    headers = _central_headers()
    base_url = _central_cfg()["cluster_url"].rstrip("/")
    alert_types: dict[str, str] = {}
    insight_categories: dict[str, str] = {}
    warnings: list[str] = []

    # 30-day lookback window to catch historical alert types even when none are active now
    thirty_days_ago = int(time.time()) - 30 * 86400

    async with httpx.AsyncClient() as client:
        # Alerts — try v1 then v2 (v2 is 404 on some clusters)
        for alerts_path in ["/monitoring/v1/alerts", "/monitoring/v2/alerts"]:
            try:
                resp = await client.get(
                    f"{base_url}{alerts_path}",
                    headers=headers,
                    params={"limit": 1000, "from_timestamp": thirty_days_ago},
                    timeout=20,
                )
                logger.info("Central available alerts %s → %s", alerts_path, resp.status_code)
                if resp.status_code == 200:
                    for alert in resp.json().get("alerts", []):
                        atype = alert.get("alert_type") or alert.get("type", "")
                        aname = alert.get("alert_type_name") or atype.replace("_", " ").title()
                        if atype:
                            alert_types[atype] = aname
                    break  # success — stop trying
                if resp.status_code == 404:
                    continue  # try next path
                if resp.status_code == 401:
                    warnings.append("Token rejected (401) fetching alerts.")
                    break
            except Exception as exc:
                logger.warning("Could not fetch alert types from %s: %s", alerts_path, exc)
                warnings.append(f"Network error fetching alerts: {exc}")
                break

        # Insights
        try:
            resp = await client.get(
                f"{base_url}/aiops/v1/insights",
                headers=headers,
                params={"limit": 1000, "from_timestamp": thirty_days_ago},
                timeout=20,
            )
            logger.info("Central available insights → %s", resp.status_code)
            if resp.status_code == 200:
                for insight in resp.json().get("insights", []):
                    cat = insight.get("category") or insight.get("type", "")
                    cat_name = insight.get("category_name") or cat.replace("_", " ").title()
                    if cat:
                        insight_categories[cat] = cat_name
            elif resp.status_code not in (404,):
                warnings.append(f"Insights endpoint returned HTTP {resp.status_code}.")
        except Exception as exc:
            logger.warning("Could not fetch insight categories: %s", exc)
            warnings.append(f"Network error fetching insights: {exc}")

    # If live API returned nothing, fall back to the known static list
    using_fallback = False
    if not alert_types:
        alert_types = dict(KNOWN_ALERT_TYPES)
        using_fallback = True
    if not insight_categories:
        insight_categories = dict(KNOWN_INSIGHT_CATEGORIES)
        using_fallback = True
    if using_fallback:
        warnings.append("No live checks returned by Central — showing standard Aruba Central check types.")

    return {
        "alerts": [{"id": k, "name": v} for k, v in sorted(alert_types.items())],
        "insights": [{"id": k, "name": v} for k, v in sorted(insight_categories.items())],
        "warning": "; ".join(warnings) if warnings else None,
    }

    return {
        "alerts": [{"id": k, "name": v} for k, v in sorted(alert_types.items())],
        "insights": [{"id": k, "name": v} for k, v in sorted(insight_categories.items())],
        "warning": "; ".join(warnings) if warnings else None,
    }


@app.get("/api/central/status")
async def api_central_status() -> dict[str, Any]:
    """Current check status for all mapped sites."""
    return {
        "status": _central_status_payload(),
        "site_mappings": settings.get("site_mappings", {}),
        "monitored_checks": settings.get("monitored_checks", []),
        "token_valid": bool(central_token.get("access_token") and time.time() < central_token["expires_at"]),
    }


@app.get("/api/central/history")
async def api_central_history(
    site: str | None = Query(default=None),
    hours: int = Query(default=24, ge=1, le=24),
) -> dict[str, Any]:
    """Return history records, optionally filtered by wsite."""
    cutoff = time.time() - hours * 3600
    async with history_lock:
        records = [
            r for r in central_history
            if r["ts"] >= cutoff and (site is None or r["wsite"] == site)
        ]
    return {"records": records, "count": len(records)}


@app.get("/api/central/site-alerts")
async def api_central_site_alerts(site: str = Query(...)) -> dict[str, Any]:
    """Fetch current alerts from Central for a specific site name. Always returns 200."""
    if not _central_ready() or not central_token.get("access_token"):
        return {"alerts": [], "warning": "Central not configured or no valid token."}
    if _is_new_central_api():
        return {"alerts": [], "warning": "Alert detail not available in New Central v1alpha1 yet."}

    headers = _central_headers()
    base_url = _central_cfg()["cluster_url"].rstrip("/")
    alerts: list[dict[str, Any]] = []
    warning: str | None = None
    thirty_days_ago = int(time.time()) - 30 * 86400

    async with httpx.AsyncClient() as client:
        for path in ["/monitoring/v1/alerts", "/monitoring/v2/alerts"]:
            try:
                resp = await client.get(
                    f"{base_url}{path}",
                    headers=headers,
                    params={"site": site, "limit": 500, "from_timestamp": thirty_days_ago},
                    timeout=20,
                )
                logger.info("site-alerts %s for '%s' → %s", path, site, resp.status_code)
                if resp.status_code == 200:
                    for alert in resp.json().get("alerts", []):
                        alerts.append({
                            "type":     alert.get("alert_type") or alert.get("type", ""),
                            "name":     alert.get("alert_type_name") or alert.get("alert_type", ""),
                            "severity": alert.get("severity", ""),
                            "state":    alert.get("state", ""),
                            "site":     alert.get("site_name") or site,
                            "device":   alert.get("device_name") or alert.get("hostname", ""),
                            "ts":       alert.get("timestamp") or alert.get("raised_at", ""),
                            "message":  alert.get("details") or alert.get("description", ""),
                        })
                    break
                if resp.status_code == 404:
                    continue
                if resp.status_code == 401:
                    warning = "Token rejected (401)."
                    break
            except Exception as exc:
                logger.warning("site-alerts fetch error: %s", exc)
                warning = str(exc)
                break

    if not alerts and not warning:
        warning = "No alerts in the last 30 days for this site."

    return {"alerts": alerts, "count": len(alerts), "warning": warning}


async def api_central_poll() -> dict[str, Any]:
    """Trigger an immediate Central poll cycle."""
    if not _central_ready():
        raise HTTPException(status_code=422, detail="Central not configured.")
    asyncio.create_task(_poll_central_once(httpx.AsyncClient()))
    return {"status": "ok", "message": "Poll started."}


@app.get("/api/central/sites")
async def api_central_sites() -> dict[str, Any]:
    """Fetch site list from Aruba Central API. Always returns 200 with sites[] and optional warning."""
    if not _central_ready():
        return {"sites": [], "warning": "Central not configured — enter Cluster URL and token in Setup first."}
    if not central_token.get("access_token"):
        return {"sites": [], "warning": "No valid token — click 'Save & Test Connection' in Setup first."}

    headers = _central_headers()
    base_url = _central_cfg()["cluster_url"].rstrip("/")
    sites: list[str] = []
    warning: str | None = None

    # Classic Central — try multiple known site endpoints
    CLASSIC_SITE_PATHS = [
        ("/monitoring/v2/sites", {"limit": 1000, "offset": 0}),
        ("/monitoring/v1/sites", {"limit": 1000, "offset": 0}),
        ("/central/v2/sites", {"limit": 1000, "offset": 0}),
    ]

    async with httpx.AsyncClient() as client:
        if _is_new_central_api():
            # New Central: sites come from sites-health
            try:
                resp = await client.get(
                    f"{base_url}/network-monitoring/v1alpha1/sites-health",
                    headers=headers,
                    timeout=20,
                )
                logger.info("New Central sites-health → %s", resp.status_code)
                if resp.status_code == 200:
                    for item in resp.json().get("items", []):
                        name = item.get("siteName") or item.get("site_name") or item.get("name", "")
                        if name:
                            sites.append(name)
                elif resp.status_code == 401:
                    warning = "Token rejected (401) — re-save settings to refresh."
                else:
                    warning = f"sites-health returned HTTP {resp.status_code}."
            except Exception as exc:
                logger.warning("Could not fetch New Central sites-health: %s", exc)
                warning = f"Network error fetching sites: {exc}"
        else:
            # Classic Central: try each known path, stop on first 200
            last_status: int | None = None
            tried: list[str] = []
            for path, params in CLASSIC_SITE_PATHS:
                tried.append(path)
                try:
                    resp = await client.get(
                        f"{base_url}{path}",
                        headers=headers,
                        params=params,
                        timeout=20,
                    )
                    last_status = resp.status_code
                    logger.info("Classic Central sites %s → %s: %s", path, resp.status_code, resp.text[:200])
                    if resp.status_code == 200:
                        data = resp.json()
                        # Response may use "sites", "items", or root list
                        raw = data.get("sites") or data.get("items") or (data if isinstance(data, list) else [])
                        for site in raw:
                            if isinstance(site, str):
                                sites.append(site)
                            else:
                                name = site.get("site_name") or site.get("siteName") or site.get("name", "")
                                if name:
                                    sites.append(name)
                        break
                    elif resp.status_code == 401:
                        warning = "Token rejected (401) — re-save settings."
                        break
                    # 404 = path doesn't exist on this cluster, try next
                except Exception as exc:
                    logger.warning("Could not fetch Classic Central sites from %s: %s", path, exc)
                    warning = f"Network error fetching sites: {exc}"
                    break

            if not sites and not warning:
                warning = f"No sites found — tried {', '.join(tried)} (last HTTP {last_status}). Your cluster may not expose a sites list API."

    return {"sites": sorted(set(sites)), "warning": warning}


@app.get("/api/local-wsites")
async def api_local_wsites() -> dict[str, Any]:
    """Extract unique wsite values from simulation.conf in the repo."""
    import configparser
    config_path = repo_path("configs", "simulation.conf")
    if not config_path.exists():
        return {"wsites": []}
    parser = configparser.ConfigParser()
    try:
        parser.read_string(config_path.read_text(encoding="utf-8"))
    except Exception as exc:
        logger.warning("Could not parse simulation.conf: %s", exc)
        return {"wsites": []}
    wsites: set[str] = set()
    for section in parser.sections():
        if parser.has_option(section, "wsite"):
            val = parser.get(section, "wsite").strip()
            if val:
                wsites.add(val)
    return {"wsites": sorted(wsites)}


@app.get("/api/simulations")
async def api_simulations() -> dict[str, Any]:
    """Return simulation groups with client membership and Central PASS/FAIL status.

    Reads configs/simulation.conf for bucket profiles and proxmox/client-setup.conf
    for VMID→username mappings. Matches configured clients against live heartbeats
    and looks up Central alert status per simulation wsite + central_check.
    """
    import configparser  # already available; re-import is safe inside function

    sim_conf_path = REPO_DIR / "configs" / "simulation.conf"
    client_conf_path = REPO_DIR / "proxmox" / "client-setup.conf"

    simulations: dict[str, dict[str, Any]] = {}
    site_based_num = 2

    # ── Parse simulation.conf ─────────────────────────────────────
    if sim_conf_path.exists():
        try:
            parser = configparser.ConfigParser()
            parser.read_string(sim_conf_path.read_text(encoding="utf-8"))
            site_based_num = int(parser.get("simulation", "site_based_num", fallback="2"))

            sim_section_re = re.compile(r"^s\d$")
            for section in parser.sections():
                if not sim_section_re.match(section):
                    continue
                simulations[section] = {
                    "id": section,
                    "name": parser.get(section, "name", fallback=section),
                    "wsite": parser.get(section, "wsite", fallback=""),
                    "central_check": parser.get(section, "central_check", fallback="").strip(),
                    "configured_clients": [],
                    "active_client_count": 0,
                    "central_pass_fail": None,  # None = not configured
                }
        except Exception as exc:
            logger.warning("api_simulations: could not parse simulation.conf: %s", exc)

    # ── Parse client-setup.conf — build VMID→hostname mapping ────
    if client_conf_path.exists():
        try:
            client_parser = configparser.ConfigParser()
            client_parser.read_string(client_conf_path.read_text(encoding="utf-8"))

            vmid_section_re = re.compile(r"^c(\d+)$")
            for section in client_parser.sections():
                m = vmid_section_re.match(section)
                if not m:
                    continue
                vmid_str = m.group(1)
                vmid = int(vmid_str)
                vm_name = client_parser.get(section, "vm_name", fallback="").strip()
                if not vm_name:
                    continue

                # Extract the Nth-from-last digit (same math as startup.sh)
                digit_idx = -(site_based_num)
                digit = vmid_str[digit_idx] if len(vmid_str) >= site_based_num else vmid_str[-1]
                sim_id = f"s{digit}"

                if sim_id in simulations:
                    simulations[sim_id]["configured_clients"].append({
                        "hostname": f"{vm_name}-{vmid}",
                        "vmid": vmid,
                        "username": vm_name,
                        "reporting": False,
                        "online": False,
                        "last_seen": None,
                    })
        except Exception as exc:
            logger.warning("api_simulations: could not parse client-setup.conf: %s", exc)

    # ── Match active clients + compute Central PASS/FAIL ─────────
    async with state_lock:
        active_snap = {h: dict(c) for h, c in clients.items()}

    for sim in simulations.values():
        active_count = 0
        for client_info in sim["configured_clients"]:
            h = client_info["hostname"]
            if h in active_snap:
                c = active_snap[h]
                online = compute_online(c.get("last_seen", datetime.min.replace(tzinfo=timezone.utc)))
                last_seen_dt = c.get("last_seen")
                client_info["reporting"] = True
                client_info["online"] = online
                client_info["last_seen"] = last_seen_dt.isoformat() if last_seen_dt else None
                if online:
                    active_count += 1
        sim["active_client_count"] = active_count

        # Central PASS/FAIL — look up wsite + central_check in polled status
        wsite = sim["wsite"]
        check_id = sim["central_check"]
        if wsite and check_id:
            site_checks = central_status.get(wsite, {})
            if check_id in site_checks:
                info = site_checks[check_id]
                sim["central_pass_fail"] = {
                    "firing": info["status"] == "OK",
                    "count": info["count"],
                    "check_name": info["check_name"],
                    "ts": info["ts"],
                }
            else:
                sim["central_pass_fail"] = {"firing": False, "count": 0, "check_name": check_id, "ts": None}

    return {
        "site_based_num": site_based_num,
        "simulations": list(simulations.values()),
    }


@app.get("/api/health")
async def api_health() -> dict[str, Any]:
    async with state_lock:
        client_count = len(clients)
    return {
        "status": "ok",
        "clients": client_count,
        "repo_synced": repo_state["synced"],
        "repo_error": repo_state["error"],
        "installer_version": INSTALLER_VERSION,
    }


@app.post("/api/sync-now")
async def api_sync_now() -> dict[str, Any]:
    """Trigger an immediate GitHub sync outside the normal interval."""
    if "repo_sync" in background_tasks:
        background_tasks["repo_sync"].cancel()
        with contextlib.suppress(asyncio.CancelledError):
            await background_tasks["repo_sync"]
    repo_state["synced"] = False
    repo_state["error"] = None
    background_tasks["repo_sync"] = asyncio.create_task(sync_repo())
    await broadcast({"type": "repo_status", "synced": False, "error": None})
    return {"status": "ok", "message": "GitHub sync started"}


@app.get("/api/version")
async def api_version() -> dict[str, Any]:
    """Return installed and available installer versions."""
    return {
        "status": "ok",
        "current_version": update_state["current_version"],
        "available_version": update_state["available_version"],
        "update_available": update_state["update_available"],
        "last_checked": update_state["last_checked"],
        "update_in_progress": update_state["update_in_progress"],
    }


@app.post("/api/self-update")
async def api_self_update() -> dict[str, Any]:
    """Manually trigger a self-update check and apply if a new version is available."""
    if update_state["update_in_progress"]:
        raise HTTPException(status_code=409, detail="Update already in progress")
    # Refresh the available version first
    available = await asyncio.to_thread(_get_repo_version)
    import datetime
    update_state["available_version"] = available
    update_state["last_checked"] = datetime.datetime.now().isoformat(timespec="seconds")
    update_state["update_available"] = (
        available is not None and available != update_state["current_version"]
    )
    await broadcast({"type": "version_status", **update_state})
    if not update_state["update_available"]:
        return {"status": "ok", "message": f"Already up to date (v{update_state['current_version']})"}
    asyncio.create_task(_run_self_update())
    return {"status": "ok", "message": f"Update to v{available} started — service will restart shortly"}


@app.get("/api/config", response_class=PlainTextResponse)
async def api_config(hostname: str | None = Query(default=None)) -> str:
    config_path = repo_path("configs", "simulation.conf")
    config_text = config_path.read_text(encoding="utf-8")

    if not hostname:
        return config_text

    async with state_lock:
        client = clients.get(hostname)
        if not client or not client.get("overrides"):
            return config_text
        return apply_overrides(config_text, client)


@app.get("/api/config/overrides", response_class=PlainTextResponse)
async def api_config_overrides() -> str:
    overrides_path = repo_path("configs", "user-overrides.conf")
    return overrides_path.read_text(encoding="utf-8")


@app.get("/api/scripts/list")
async def api_scripts_list(platform: str = Query(...)) -> list[str]:
    platform = validate_platform(platform)
    scripts_dir = repo_path(platform)
    if not scripts_dir.is_dir():
        raise HTTPException(status_code=404, detail=f"Script directory not found for {platform}")
    return sorted(path.name for path in scripts_dir.iterdir() if path.is_file())


@app.get("/api/scripts/{platform}/{filename}")
async def api_scripts_get(platform: str, filename: str) -> FileResponse:
    platform = validate_platform(platform)
    scripts_dir = repo_path(platform).resolve()
    candidate = (scripts_dir / filename).resolve()

    if candidate.parent != scripts_dir or not candidate.is_file():
        raise HTTPException(status_code=404, detail="Script file not found")

    return FileResponse(candidate)


@app.post("/api/status")
async def api_status(status: ClientStatus) -> dict[str, Any]:
    now = utcnow()
    async with state_lock:
        existing = clients.get(status.hostname, {})

        # Build timestamped error entries from whatever the client reported this cycle.
        # WHY: clients accumulate errors between reports (e.g. "SSID not found") and
        # flush them here. We stamp them server-side so timestamps are in server time,
        # which is consistent with other log timestamps in the dashboard.
        incoming_errors = [
            {"ts": now.strftime("%Y-%m-%dT%H:%M:%SZ"), "msg": e}
            for e in status.errors
        ]
        existing_errors: list[dict[str, str]] = existing.get("recent_errors", [])
        # Keep a rolling window; oldest entries fall off the front.
        recent_errors = (existing_errors + incoming_errors)[-MAX_CLIENT_ERRORS:]
        total_errors = int(existing.get("error_count", 0)) + len(incoming_errors)

        if incoming_errors:
            logger.warning(
                "Client %s reported %d error(s): %s",
                status.hostname,
                len(incoming_errors),
                "; ".join(e["msg"] for e in incoming_errors),
            )

        clients[status.hostname] = {
            **existing,
            "hostname": status.hostname,
            "simulation_id": status.simulation_id,
            "platform": status.platform,
            "iteration": status.iteration,
            "connected_ssid": status.connected_ssid,
            "gateway_reachable": status.gateway_reachable,
            "vh_connected": status.vh_connected,
            "active_simulations": list(status.active_simulations),
            "config": {key: str(value) for key, value in status.config.items()},
            "overrides": existing.get("overrides", {}),
            "last_seen": now,
            "online": True,
            "recent_errors": recent_errors,
            "error_count": total_errors,
        }
        payload = serialize_client(status.hostname, clients[status.hostname])

    await broadcast({"type": "status_update", "client": payload})
    return {"status": "ok", "client": payload}


@app.get("/api/clients")
async def api_clients() -> list[dict[str, Any]]:
    return await current_clients()


@app.post("/api/clients/{hostname}/control", response_model=ClientControlResponse)
async def api_client_control(hostname: str, overrides: dict[str, str]) -> dict[str, Any]:
    normalized = {key: str(value) for key, value in overrides.items()}
    async with state_lock:
        if hostname not in clients:
            raise HTTPException(status_code=404, detail="Client not found")
        clients[hostname].setdefault("overrides", {}).update(normalized)
        payload = serialize_client(hostname, clients[hostname])

    await broadcast({"type": "overrides_update", "client": payload})
    return {"hostname": hostname, "overrides": payload["overrides"], "client": payload}


@app.delete("/api/clients/{hostname}/control", response_model=ClientControlResponse)
async def api_client_control_clear(hostname: str) -> dict[str, Any]:
    async with state_lock:
        if hostname not in clients:
            raise HTTPException(status_code=404, detail="Client not found")
        clients[hostname]["overrides"] = {}
        payload = serialize_client(hostname, clients[hostname])

    await broadcast({"type": "overrides_cleared", "client": payload})
    return {"hostname": hostname, "overrides": {}, "client": payload}


@app.post("/api/clients/all/control")
async def api_all_clients_control(overrides: dict[str, str]) -> dict[str, Any]:
    normalized = {key: str(value) for key, value in overrides.items()}
    async with state_lock:
        for client in clients.values():
            client.setdefault("overrides", {}).update(normalized)
        updated = len(clients)

    await broadcast_full_state()
    return {"status": "ok", "updated": updated, "overrides": normalized}


@app.websocket("/ws")
async def websocket_endpoint(websocket: WebSocket) -> None:
    await websocket.accept()
    ws_connections.append(websocket)
    await websocket.send_text(json.dumps({"type": "full_state", "clients": await current_clients()}))
    await websocket.send_text(json.dumps({"type": "repo_status", "synced": repo_state["synced"], "error": repo_state["error"]}))
    await websocket.send_text(json.dumps({"type": "settings_update", "settings": {"repo_url": REPO_URL, "repo_branch": settings["repo_branch"]}}))
    await websocket.send_text(json.dumps({"type": "central_update", "status": _central_status_payload(), "ts": time.time()}))

    try:
        while True:
            await websocket.receive_text()
    except WebSocketDisconnect:
        pass
    finally:
        with contextlib.suppress(ValueError):
            ws_connections.remove(websocket)


app.mount("/", StaticFiles(directory=STATIC_DIR, html=True), name="static")
