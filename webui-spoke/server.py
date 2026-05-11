from __future__ import annotations

import asyncio
import configparser
import contextlib
import copy
import hashlib
import json
from dataclasses import asdict
import acme as spoke_acme
import logging
import os
import re
import socket
import subprocess
import time
import uuid
from contextlib import asynccontextmanager
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

try:
    import httpx
    _HTTPX_AVAILABLE = True
except ImportError:
    httpx = None
    _HTTPX_AVAILABLE = False

from fastapi import Body, FastAPI, HTTPException, Query, Request, WebSocket, WebSocketDisconnect
from fastapi.responses import FileResponse, HTMLResponse, JSONResponse, PlainTextResponse, StreamingResponse
from starlette.middleware.base import BaseHTTPMiddleware
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("client_sim_dashboard")
if not _HTTPX_AVAILABLE:
    logger.warning("httpx not installed — network-backed features may be limited. Install with: pip install httpx")

BASE_DIR = Path(__file__).resolve().parent
STATIC_DIR = BASE_DIR / "static"
SETTINGS_FILE = BASE_DIR / "settings.json"
STATE_CACHE_FILE = BASE_DIR / "state_cache.json"
COMMAND_QUEUE_FILE = BASE_DIR / "command_queue.json"
RECLONE_STATE_FILE = BASE_DIR / "reclone_state.json"
RELAY_STATE_FILE = BASE_DIR / "relay_state.json"
UPDATE_STATE_FILE = BASE_DIR / "update_state.json"
VM_WATCHDOG_FILE = BASE_DIR / "vm_watchdog.json"
HISTORY_FILE = BASE_DIR / "central_history.jsonl"
CLIENT_HISTORY_FILE = BASE_DIR / "client_history.json"
CLIENT_COUNT_BASELINE_FILE = BASE_DIR / "client_count_baseline.json"
CLIENT_HISTORY_DAYS = 7          # remove clients not seen within this many days
CLIENT_SAVE_INTERVAL = 60        # seconds between periodic disk saves
REPO_DIR = Path(os.getenv("REPO_DIR", "/app/client-sim")).resolve()
REPO_URL = os.getenv("REPO_URL", "https://github.com/solutions-hpe/client-sim.git")
CLIENT_SIM_REPO_RAW = os.getenv("CLIENT_SIM_REPO_RAW", "https://raw.githubusercontent.com/solutions-hpe/client-sim")
CS_WEBUI_REPO_RAW = os.getenv("CS_WEBUI_REPO_RAW", "https://raw.githubusercontent.com/solutions-hpe/cs-webui")


def _detect_own_vmid() -> int | None:
    """Detect this process's Proxmox container/VM ID from /proc/self/cgroup.
    Returns the integer VMID if running inside a Proxmox LXC container, else None."""
    try:
        cgroup = Path("/proc/self/cgroup").read_text(encoding="utf-8")
        m = re.search(r'/(?:lxc|qemu)/(\d+)', cgroup)
        if m:
            return int(m.group(1))
    except Exception:
        pass
    return None


WEBUI_VMID: int | None = _detect_own_vmid()

# ── Credential encryption ─────────────────────────────────────────────────────
# Fernet symmetric encryption for sensitive fields in settings.json.
# Key is generated once at install time and stored in .secret_key (chmod 600).
# Falls back to plaintext if key file or cryptography package is unavailable.
_ENC_PREFIX = "enc:"
_SENSITIVE_CFG_KEYS = {"access_token", "refresh_token", "client_secret"}
_SENSITIVE_CLASSIC_API_KEYS = {"password"}
_SENSITIVE_CENTRAL_API_KEYS = {"client_secret"}
_SENSITIVE_TOP_KEYS = {"relay_api_key", "github_token"}
_SENSITIVE_TOP_DICT_KEYS = {"proxmox_approved_agents"}
_SENSITIVE_NOTIF_KEYS = {"smtp_password", "teams_webhook_url"}

try:
    from cryptography.fernet import Fernet as _Fernet, InvalidToken as _InvalidToken
    _key_file = BASE_DIR / ".secret_key"
    if _key_file.exists():
        _fernet = _Fernet(_key_file.read_bytes().strip())
    else:
        _fernet = None
        logger.warning("No .secret_key found — credentials stored as plaintext")
except Exception:
    _fernet = None
    logger.warning("cryptography unavailable or key error — credentials stored as plaintext")


def _encrypt_secret(value: str) -> str:
    if not _fernet or not value:
        return value
    return _ENC_PREFIX + _fernet.encrypt(value.encode()).decode()


def _decrypt_secret(value: str) -> str:
    if not value or not value.startswith(_ENC_PREFIX):
        return value  # plaintext or empty — return as-is (legacy compat)
    if not _fernet:
        return value  # no key — return ciphertext unchanged
    try:
        return _fernet.decrypt(value[len(_ENC_PREFIX):].encode()).decode()
    except Exception:
        logger.warning("Failed to decrypt a secret field — may be corrupted or from a different key")
        return ""


def _encrypt_settings(raw: dict) -> dict:
    """Return a deep copy of settings with sensitive fields encrypted for disk storage."""
    out = copy.deepcopy(raw)
    for key in _SENSITIVE_TOP_KEYS:
        if out.get(key):
            out[key] = _encrypt_secret(out[key])
    for key in _SENSITIVE_TOP_DICT_KEYS:
        value = out.get(key)
        if isinstance(value, dict):
            out[key] = {
                str(dict_key): _encrypt_secret(str(dict_value)) if dict_value not in (None, "") else ""
                for dict_key, dict_value in value.items()
            }
    for key in _SENSITIVE_CFG_KEYS:
        if out.get("central_config", {}).get(key):
            out["central_config"][key] = _encrypt_secret(out["central_config"][key])
    for key in _SENSITIVE_CLASSIC_API_KEYS:
        if out.get("central_api", {}).get("classic", {}).get(key):
            out["central_api"]["classic"][key] = _encrypt_secret(out["central_api"]["classic"][key])
    for key in _SENSITIVE_CENTRAL_API_KEYS:
        if out.get("central_api", {}).get("central", {}).get(key):
            out["central_api"]["central"][key] = _encrypt_secret(out["central_api"]["central"][key])
    for key in _SENSITIVE_NOTIF_KEYS:
        if out.get("notifications", {}).get(key):
            out["notifications"][key] = _encrypt_secret(out["notifications"][key])
    return out


def _decrypt_settings(raw: dict) -> dict:
    """Return a deep copy of settings with sensitive fields decrypted into memory."""
    out = copy.deepcopy(raw)
    for key in _SENSITIVE_TOP_KEYS:
        if out.get(key):
            out[key] = _decrypt_secret(out[key])
    for key in _SENSITIVE_TOP_DICT_KEYS:
        value = out.get(key)
        if isinstance(value, dict):
            out[key] = {
                str(dict_key): _decrypt_secret(str(dict_value)) if dict_value not in (None, "") else ""
                for dict_key, dict_value in value.items()
            }
    for key in _SENSITIVE_CFG_KEYS:
        if out.get("central_config", {}).get(key):
            out["central_config"][key] = _decrypt_secret(out["central_config"][key])
    for key in _SENSITIVE_CLASSIC_API_KEYS:
        if out.get("central_api", {}).get("classic", {}).get(key):
            out["central_api"]["classic"][key] = _decrypt_secret(out["central_api"]["classic"][key])
    for key in _SENSITIVE_CENTRAL_API_KEYS:
        if out.get("central_api", {}).get("central", {}).get(key):
            out["central_api"]["central"][key] = _decrypt_secret(out["central_api"]["central"][key])
    for key in _SENSITIVE_NOTIF_KEYS:
        if out.get("notifications", {}).get(key):
            out["notifications"][key] = _decrypt_secret(out["notifications"][key])
    return out


# Installer version — written by install-lxc.sh at install time
_version_file = BASE_DIR / "INSTALLER_VERSION"
INSTALLER_VERSION: str = _version_file.read_text().strip() if _version_file.exists() else "dev"
# App version — from VERSION file in repo root
_app_version_file = BASE_DIR / "VERSION"
APP_VERSION: str = _app_version_file.read_text().strip() if _app_version_file.exists() else INSTALLER_VERSION
REPO_BRANCH = os.getenv("REPO_BRANCH", "main")
OFFLINE_TIMEOUT = int(os.getenv("OFFLINE_TIMEOUT", "60"))
# Max error entries kept per client in memory.
# WHY: errors accumulate over a long run; capping prevents unbounded memory growth.
MAX_CLIENT_ERRORS = 50
SYNC_INTERVAL = 300
HEARTBEAT_INTERVAL = 30
RELAY_INTERVAL_DEFAULT = 60   # 1 minute
CENTRAL_POLL_INTERVAL = 900   # 15 minutes
HISTORY_HOURS = 24
UPDATE_CHECK_INTERVAL = 86400  # 24 hours
VM_WATCHDOG_TIMEOUT_SECS = 86400
VM_WATCHDOG_INTERVAL_SECS = 1800

# Self-update: the installer lives inside the synced repo
_INSTALLER_PATH = REPO_DIR / "webui-spoke" / "install-lxc.sh"

update_state: dict[str, Any] = {
    "current_version": INSTALLER_VERSION,
    "available_version": None,
    "update_available": False,
    "last_checked": None,
    "update_in_progress": False,
    "update_log": [],
    "update_error": None,
}


# ── Runtime settings (persisted to settings.json) ────────────────────────────
def _load_persisted_settings() -> dict[str, Any]:
    try:
        raw = json.loads(SETTINGS_FILE.read_text(encoding="utf-8"))
        return _decrypt_settings(raw)
    except Exception:
        return {}


def _save_settings() -> None:
    try:
        SETTINGS_FILE.write_text(json.dumps(_encrypt_settings(settings), indent=2), encoding="utf-8")
    except Exception as exc:
        logger.warning("Could not persist settings to %s: %s", SETTINGS_FILE, exc)


def _candidate_relay_spoke_id(persisted: dict[str, Any]) -> str:
    return str(
        persisted.get("relay_spoke_id")
        or persisted.get("relay_island_id")
        or persisted.get("relay_site_id")
        or os.getenv("SPOKE_ID", "")
        or ""
    ).strip()


def _is_uuid(value: str) -> bool:
    candidate = str(value or "").strip().lower()
    if not candidate:
        return False
    try:
        return str(uuid.UUID(candidate)) == candidate
    except (TypeError, ValueError, AttributeError):
        return False


def _relay_spoke_id_needs_rotation(value: str, persisted: dict[str, Any] | None = None) -> bool:
    candidate = str(value or "").strip()
    if not candidate:
        return True
    if _is_uuid(candidate):
        return False

    persisted = persisted or _persisted
    bad_values = {"main", "master"}
    repo_branch = str(persisted.get("repo_branch") or REPO_BRANCH or "").strip().lower()
    if repo_branch:
        bad_values.add(repo_branch)
    version_values = {str(APP_VERSION).strip().lower(), str(INSTALLER_VERSION).strip().lower()}
    lowered = candidate.lower()
    if lowered in bad_values:
        logger.warning("Rotating invalid relay_spoke_id '%s' that matched a branch name", candidate)
    elif lowered in version_values or re.fullmatch(r"\d+(?:\.\d+)+", candidate):
        logger.warning("Rotating invalid relay_spoke_id '%s' that matched a version string", candidate)
    else:
        logger.warning("Rotating invalid non-UUID relay_spoke_id '%s'", candidate)
    return True


def _ensure_relay_spoke_id(persisted: dict[str, Any] | None = None) -> str:
    persisted = persisted or _persisted
    candidate = str(settings.get("relay_spoke_id") or _candidate_relay_spoke_id(persisted)).strip()
    if _relay_spoke_id_needs_rotation(candidate, persisted):
        candidate = str(uuid.uuid4())
    if settings.get("relay_spoke_id") != candidate or _candidate_relay_spoke_id(persisted) != candidate:
        settings["relay_spoke_id"] = candidate
        _save_settings()
    else:
        settings["relay_spoke_id"] = candidate
    return candidate


# ── State snapshot cache (JSON file, no DB) ──────────────────────────────────
_state_cache_last_save: float = 0.0
STATE_CACHE_MIN_INTERVAL = 10.0  # max one write per 10 s

# WS delta: skip proxmox broadcast when payload hasn't changed
_last_proxmox_hash: str = ""

# INI cache: avoid re-parsing simulation.conf + client-setup.conf on every request
_sim_conf_cache: dict[str, Any] = {
    "sim_mtime": -1.0,
    "client_mtime": -1.0,
    "simulations": {},
    "site_based_num": 2,
}


def _atomic_write_json(path: Path, payload: Any, *, indent: int | None = None) -> None:
    tmp_path = path.with_name(f"{path.name}.tmp")
    tmp_path.write_text(json.dumps(payload, indent=indent, default=str), encoding="utf-8")
    tmp_path.replace(path)


def _save_state_cache(force: bool = False) -> None:
    global _state_cache_last_save
    now = time.time()
    if not force and (now - _state_cache_last_save) < STATE_CACHE_MIN_INTERVAL:
        return
    try:
        cache = {
            "proxmox_state": {**proxmox_state, "connected": False},
            "central_status": central_status,
            "central_wireless_clients": dict(central_wireless_clients),
            "ts": now,
        }
        _atomic_write_json(STATE_CACHE_FILE, cache)
        _state_cache_last_save = now
    except Exception as exc:
        logger.warning("Could not write state cache: %s", exc)


def _save_commands() -> None:
    try:
        _atomic_write_json(COMMAND_QUEUE_FILE, commands)
    except Exception as exc:
        logger.warning("Could not persist command queue to %s: %s", COMMAND_QUEUE_FILE, exc)


def _save_reclone_state() -> None:
    try:
        _atomic_write_json(RECLONE_STATE_FILE, reclone_state)
    except Exception as exc:
        logger.warning("Could not persist reclone state to %s: %s", RECLONE_STATE_FILE, exc)


def _save_relay_state() -> None:
    try:
        _atomic_write_json(RELAY_STATE_FILE, relay_state)
    except Exception as exc:
        logger.warning("Could not persist relay state to %s: %s", RELAY_STATE_FILE, exc)


def _save_update_state() -> None:
    try:
        _atomic_write_json(UPDATE_STATE_FILE, update_state)
    except Exception as exc:
        logger.warning("Could not persist update state to %s: %s", UPDATE_STATE_FILE, exc)


def _save_vm_watchdog() -> None:
    try:
        _atomic_write_json(VM_WATCHDOG_FILE, vm_watchdog)
    except Exception as exc:
        logger.warning("Could not persist VM watchdog state to %s: %s", VM_WATCHDOG_FILE, exc)


def _load_state_cache() -> None:
    """Restore last-known state from disk so the UI renders immediately on restart
    instead of showing empty state for up to one full agent poll interval (60 s)."""
    try:
        if not STATE_CACHE_FILE.exists():
            return
        cache = json.loads(STATE_CACHE_FILE.read_text(encoding="utf-8"))
        age = time.time() - cache.get("ts", 0)
        cached_px = cache.get("proxmox_state", {})
        if cached_px:
            proxmox_state.update(cached_px)
            proxmox_state["connected"] = False  # never restore as connected
        central_status.update(cache.get("central_status", {}))
        central_wireless_clients.update(cache.get("central_wireless_clients", {}))
        logger.info("Restored state cache from disk (age=%.0fs)", age)
    except Exception as exc:
        logger.warning("Could not load state cache: %s", exc)


def _load_commands() -> None:
    try:
        if not COMMAND_QUEUE_FILE.exists():
            return
        raw = json.loads(COMMAND_QUEUE_FILE.read_text(encoding="utf-8"))
        if not isinstance(raw, list):
            raise ValueError("command queue must be a list")
        now = time.time()
        changed = False
        restored: list[dict[str, Any]] = []
        for entry in raw:
            if not isinstance(entry, dict):
                changed = True
                continue
            cmd = dict(entry)
            if cmd.get("status") == "executing":
                cmd["status"] = "pending"
                cmd["updated_at"] = now
                changed = True
            restored.append(cmd)
        commands[:] = restored
        expired, purged = _cleanup_commands_locked(now)
        if expired or purged:
            changed = True
        if changed:
            _save_commands()
        logger.info("Restored %d command(s) from disk", len(commands))
    except Exception as exc:
        logger.warning("Could not load command queue: %s", exc)


def _load_reclone_state() -> None:
    try:
        if not RECLONE_STATE_FILE.exists():
            return
        raw = json.loads(RECLONE_STATE_FILE.read_text(encoding="utf-8"))
        if not isinstance(raw, dict):
            raise ValueError("reclone state must be an object")
        for key in reclone_state:
            if key in raw:
                reclone_state[key] = raw[key]
        changed = False
        if reclone_state.get("status") == "running":
            reclone_state["status"] = "interrupted"
            reclone_state["current_vm"] = None
            reclone_state["started_at"] = None
            log_entry = {
                "vmid": None,
                "name": "System",
                "status": "interrupted",
                "timestamp": iso_utcnow(),
                "message": "Rolling reclone interrupted by restart",
            }
            reclone_state["log"] = list(reclone_state.get("log") or []) + [log_entry]
            reclone_state["log"] = reclone_state["log"][-200:]
            changed = True
        if changed:
            _save_reclone_state()
        logger.info("Restored reclone state from disk")
    except Exception as exc:
        logger.warning("Could not load reclone state: %s", exc)


def _load_relay_state() -> None:
    global relay_registration_refresh_needed
    try:
        if not RELAY_STATE_FILE.exists():
            return
        raw = json.loads(RELAY_STATE_FILE.read_text(encoding="utf-8"))
        if not isinstance(raw, dict):
            raise ValueError("relay state must be an object")
        for key in relay_state:
            if key in raw:
                relay_state[key] = raw[key]
        relay_state["connected"] = False
        relay_registration_refresh_needed = bool(relay_state.get("enabled"))
        _save_relay_state()
        logger.info("Restored relay state from disk")
    except Exception as exc:
        logger.warning("Could not load relay state: %s", exc)


def _load_update_state() -> None:
    try:
        if not UPDATE_STATE_FILE.exists():
            return
        raw = json.loads(UPDATE_STATE_FILE.read_text(encoding="utf-8"))
        if not isinstance(raw, dict):
            raise ValueError("update state must be an object")
        for key in update_state:
            if key in raw:
                update_state[key] = raw[key]
        if update_state.get("update_in_progress"):
            update_state["update_in_progress"] = False
            update_state["update_error"] = "Update interrupted by restart"
            _save_update_state()
        logger.info("Restored update state from disk")
    except Exception as exc:
        logger.warning("Could not load update state: %s", exc)


def _load_vm_watchdog() -> None:
    try:
        if not VM_WATCHDOG_FILE.exists():
            return
        raw = json.loads(VM_WATCHDOG_FILE.read_text(encoding="utf-8"))
        if not isinstance(raw, dict):
            raise ValueError("vm watchdog state must be an object")
        restored: dict[str, dict[str, Any]] = {}
        changed = False
        for raw_vmid, entry in raw.items():
            if not isinstance(entry, dict):
                changed = True
                continue
            try:
                vmid_key = str(int(raw_vmid))
            except (TypeError, ValueError):
                changed = True
                continue
            clone_completed_at = _parse_ts(entry.get("clone_completed_at"))
            if clone_completed_at is None:
                changed = True
                continue
            try:
                reclone_count = max(0, int(entry.get("reclone_count", 0) or 0))
            except (TypeError, ValueError):
                reclone_count = 0
                changed = True
            normalized = {
                "clone_completed_at": clone_completed_at,
                "reclone_count": reclone_count,
                "hostname": str(entry.get("hostname") or "").strip(),
            }
            if entry != normalized or raw_vmid != vmid_key:
                changed = True
            restored[vmid_key] = normalized
        vm_watchdog.clear()
        vm_watchdog.update(restored)
        if changed:
            _save_vm_watchdog()
        logger.info("Restored VM watchdog state from disk")
    except Exception as exc:
        logger.warning("Could not load VM watchdog state: %s", exc)


def _normalize_relay_enabled(value: Any) -> str:
    if isinstance(value, str):
        return "on" if value.lower() == "on" else "off"
    return "on" if value else "off"


def _clamp_relay_interval(value: Any) -> int:
    try:
        interval = int(value)
    except (TypeError, ValueError):
        interval = RELAY_INTERVAL_DEFAULT
    return max(60, min(86400, interval))


def _relay_registration_status_from_settings() -> str:
    relay_on = settings.get("relay_enabled") == "on" and bool(settings.get("relay_server_url"))
    if not relay_on:
        return "unregistered"
    if settings.get("relay_api_key") and settings.get("relay_tenant_id"):
        return "approved"
    if settings.get("relay_spoke_id"):
        return "pending"
    return "unregistered"


def _default_central_api_settings() -> dict[str, Any]:
    return {
        "mode": "classic",
        "classic": {
            "url": "",
            "username": "",
            "password": "",
        },
        "central": {
            "url": "",
            "client_id": "",
            "client_secret": "",
            "customer_id": "",
        },
    }


def _central_runtime_defaults() -> dict[str, str]:
    return {
        "api_version": "classic",
        "cluster_url": "",
        "access_token": "",
        "refresh_token": "",
        "client_id": "",
        "client_secret": "",
        "customer_id": "",
    }


def _normalize_central_api_settings(raw: Any, legacy: Any = None) -> dict[str, Any]:
    data = raw if isinstance(raw, dict) else {}
    legacy_cfg = legacy if isinstance(legacy, dict) else {}
    defaults = _default_central_api_settings()
    raw_classic = data.get("classic") if isinstance(data.get("classic"), dict) else {}
    raw_central = data.get("central") if isinstance(data.get("central"), dict) else {}

    mode = str(data.get("mode") or ("central" if legacy_cfg.get("api_version") == "new_central" else "classic")).strip().lower()
    if mode not in {"classic", "central"}:
        mode = "classic"

    legacy_central = legacy_cfg if legacy_cfg.get("api_version") == "new_central" else {}
    return {
        "mode": mode,
        "classic": {
            "url": str(raw_classic.get("url", defaults["classic"]["url"])).strip(),
            "username": str(raw_classic.get("username", defaults["classic"]["username"])).strip(),
            "password": str(raw_classic.get("password", defaults["classic"]["password"])),
        },
        "central": {
            "url": str(raw_central.get("url", legacy_central.get("cluster_url", defaults["central"]["url"]))).strip(),
            "client_id": str(raw_central.get("client_id", legacy_central.get("client_id", defaults["central"]["client_id"]))).strip(),
            "client_secret": str(raw_central.get("client_secret", legacy_central.get("client_secret", defaults["central"]["client_secret"]))),
            "customer_id": str(raw_central.get("customer_id", legacy_central.get("customer_id", defaults["central"]["customer_id"]))).strip(),
        },
    }


def _build_runtime_central_config(central_api_cfg: dict[str, Any], legacy_cfg: Any = None) -> dict[str, str]:
    legacy = {**_central_runtime_defaults(), **(legacy_cfg if isinstance(legacy_cfg, dict) else {})}
    mode = str(central_api_cfg.get("mode", "classic")).strip().lower()
    if mode == "central":
        central_cfg = central_api_cfg.get("central", {}) if isinstance(central_api_cfg.get("central"), dict) else {}
        return {
            **_central_runtime_defaults(),
            "api_version": "new_central",
            "cluster_url": str(central_cfg.get("url", "")).strip(),
            "client_id": str(central_cfg.get("client_id", "")).strip(),
            "client_secret": str(central_cfg.get("client_secret", "")),
            "customer_id": str(central_cfg.get("customer_id", "")).strip(),
        }

    classic_cfg = central_api_cfg.get("classic", {}) if isinstance(central_api_cfg.get("classic"), dict) else {}
    classic_has_explicit_values = any(str(classic_cfg.get(key, "")).strip() for key in ("url", "username")) or bool(classic_cfg.get("password"))
    if legacy.get("api_version") == "classic" and not classic_has_explicit_values and (legacy.get("access_token") or legacy.get("refresh_token")):
        return legacy

    return {
        **_central_runtime_defaults(),
        "api_version": "classic",
        "cluster_url": str(classic_cfg.get("url", "")).strip(),
    }


_persisted = _load_persisted_settings()
_persisted_central_api = _normalize_central_api_settings(_persisted.get("central_api", {}), _persisted.get("central_config", {}))
settings: dict[str, Any] = {
    "repo_branch": _persisted.get("repo_branch", REPO_BRANCH),
    "github_token": _persisted.get("github_token", ""),
    "central_api": _persisted_central_api,
    "central_config": _build_runtime_central_config(_persisted_central_api, _persisted.get("central_config", {})),
    # {wsite_value: central_site_name}
    "site_mappings": _persisted.get("site_mappings", {}),
    # [{type: "alert"|"insight", id: "...", name: "..."}]  — sim check monitors
    "monitored_checks": _persisted.get("monitored_checks", []),
    # [{id: "AP_DOWN", name: "AP Down", device_type: "ap"|"gateway"|"switch"}]
    "hardware_checks": _persisted.get("hardware_checks", []),
    # Notification settings
    "notifications": _persisted.get("notifications", {
        "email_enabled": False,
        "smtp_host": "",
        "smtp_port": 587,
        "smtp_user": "",
        "smtp_password": "",
        "smtp_from": "",
        "smtp_to": [],
        "teams_enabled": False,
        "teams_webhook_url": "",
    }),
    "repo_sync_interval": _persisted.get("repo_sync_interval", SYNC_INTERVAL),
    "relay_enabled": _normalize_relay_enabled(_persisted.get("relay_enabled", "off")),
    "relay_server_url": _persisted.get("relay_server_url", _persisted.get("relay_url", "")),
    "relay_spoke_name": _persisted.get("relay_spoke_name", ""),
    "relay_tenant_hint": _persisted.get("relay_tenant_hint", _persisted.get("relay_tenant_id", "")),
    "relay_api_key": _persisted.get("relay_api_key", _persisted.get("relay_token", "")),
    "relay_spoke_id": _candidate_relay_spoke_id(_persisted),
    "relay_tenant_id": _persisted.get("relay_tenant_id", _persisted.get("relay_tenant_hint", "")),
    "relay_poll_interval": _clamp_relay_interval(_persisted.get("relay_poll_interval", _persisted.get("relay_interval", RELAY_INTERVAL_DEFAULT))),
    "proxmox_approved_agents": _persisted.get("proxmox_approved_agents", {}),
    "usb_vidpids": _persisted.get("usb_vidpids", "[]"),
    "usb_missing_timeout": str(_persisted.get("usb_missing_timeout", "60")),
    "vm_image_1_template_id": str(_persisted.get("vm_image_1_template_id", _persisted.get("usb_linux_template_id", _persisted.get("usb_template_id", "100")))),
    "vm_image_2_template_id": str(_persisted.get("vm_image_2_template_id", _persisted.get("usb_windows_template_id", "200"))),
    "vm_image_1_pct": str(_persisted.get("vm_image_1_pct", "50")),
    "usb_auto_provision": _normalize_relay_enabled(_persisted.get("usb_auto_provision", "off")),
    "usb_ignored_vidpids": _persisted.get("usb_ignored_vidpids", "[]"),
    "ignored_hostnames": _persisted.get("ignored_hostnames", '["sim-rpi-0000"]'),
    "vm_silent_timeout": str(_persisted.get("vm_silent_timeout", "24")),
    "reclone_schedule_enabled": _normalize_relay_enabled(_persisted.get("reclone_schedule_enabled", "off")),
    "reclone_schedule_cron": _persisted.get("reclone_schedule_cron", "sunday 02:00"),
    "reclone_concurrency": str(_persisted.get("reclone_concurrency", "1")),
    "l1_vlan_start": str(_persisted.get("l1_vlan_start", "100")),
    "l1_vlan_end": str(_persisted.get("l1_vlan_end", "199")),
    "spoke_tls": _normalize_relay_enabled(_persisted.get("spoke_tls", os.getenv("SPOKE_TLS", "off"))),
}
_ensure_relay_spoke_id(_persisted)

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


def _reset_central_runtime_tokens() -> None:
    global central_auth_error
    central_token["access_token"] = None
    central_token["refresh_token"] = None
    central_token["expires_at"] = 0.0
    central_auth_error = None


def _public_central_api_settings() -> dict[str, Any]:
    cfg = copy.deepcopy(settings.get("central_api", _default_central_api_settings()))
    cfg.setdefault("classic", {})
    cfg.setdefault("central", {})
    cfg["classic"].pop("password", None)
    cfg["central"].pop("client_secret", None)
    cfg["classic"]["password_configured"] = bool(settings.get("central_api", {}).get("classic", {}).get("password"))
    cfg["central"]["client_secret_configured"] = bool(settings.get("central_api", {}).get("central", {}).get("client_secret"))
    return cfg



def _public_notification_settings() -> dict[str, Any]:
    notif = copy.deepcopy(settings.get("notifications", {}))
    smtp_password = str(notif.pop("smtp_password", "") or "")
    teams_webhook_url = str(notif.pop("teams_webhook_url", "") or "")
    notif["smtp_password_configured"] = bool(smtp_password)
    notif["teams_webhook_url_configured"] = bool(teams_webhook_url)
    return notif



def _public_acme_settings(cfg: Any) -> dict[str, Any]:
    data = asdict(cfg)
    credentials = dict(cfg.dns_credentials or {})
    data["dns_credentials"] = {key: "" for key in credentials}
    data["dns_credentials_configured"] = {key: bool(value) for key, value in credentials.items()}
    data["cf_api_token_set"] = bool(credentials.get("cf_api_token"))
    data["he_ddns_key_set"] = bool(credentials.get("he_ddns_key"))
    return data


def _sync_central_runtime_config() -> None:
    settings["central_config"] = _build_runtime_central_config(settings.get("central_api", _default_central_api_settings()), settings.get("central_config", {}))
    _reset_central_runtime_tokens()


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
    "github_repo",
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
ALLOWED_CONFIG_SECTIONS = {"simulation", "address", "server", *(f"s{i}" for i in range(10))}


# ── Aruba Central state ───────────────────────────────────────────────────────
# central_token is declared above, initialised from persisted settings.
# {wsite: {check_id: {status, count, ts, check_name, check_type}}}
central_status: dict[str, dict[str, Any]] = {}
central_wireless_clients: dict[str, int] = {}   # wsite → client count from Central API
# wsite → list of (timestamp_float, client_count_int) samples (rolling 60 min)
_client_count_samples: dict[str, list[tuple[float, int]]] = {}
CLIENT_COUNT_WINDOW = 3600   # seconds of history to keep
CLIENT_COUNT_MIN_SAMPLES = 3  # minimum samples before flagging
CLIENT_COUNT_DROP_PCT = 25.0  # percent drop that triggers alert
central_history: list[dict[str, Any]] = []   # in-memory 24-h window
central_auth_error: str | None = None          # last auth/token failure message
history_lock = asyncio.Lock()
# Serialise all git operations (fetch, reset, add, commit, push) on REPO_DIR.
# Running two git commands concurrently on the same repo creates .git/index.lock
# conflicts that cause the sync background task to hang indefinitely.
_git_lock = asyncio.Lock()

# Load persisted client count baseline so the UI has a reference point
# immediately after a restart instead of showing NO_DATA for an hour.
_client_count_baseline: dict[str, Any] = {}
try:
    _client_count_baseline = json.loads(CLIENT_COUNT_BASELINE_FILE.read_text(encoding="utf-8"))
    # Seed in-memory samples from the persisted baseline so _client_count_payload()
    # can surface the saved average immediately on startup — before enough live samples
    # have been collected to compute a fresh average.  We create CLIENT_COUNT_MIN_SAMPLES
    # synthetic entries spaced 60 s apart in the recent past.  They stay in the
    # CLIENT_COUNT_WINDOW (3600 s) for ~55 min, then age out naturally as real data
    # accumulates and replaces them.
    _seed_now = time.time()
    for _wsite, _saved in _client_count_baseline.items():
        _avg_val = round(_saved["hourly_avg"])
        _client_count_samples[_wsite] = [
            (_seed_now - (CLIENT_COUNT_MIN_SAMPLES - i) * 60, _avg_val)
            for i in range(CLIENT_COUNT_MIN_SAMPLES)
        ]
except Exception:
    pass

# Hardware alert state: {check_id: {wsite: [device_name, ...]}}
# Populated during each Central poll cycle from alert objects.
hardware_alert_devices: dict[str, dict[str, list[str]]] = {}

# Previous check states for transition detection (green→red email/Teams trigger).
# {check_key: "OK"|"ERROR"}  where check_key = f"{check_id}:{wsite}" or just check_id for hw
_prev_check_states: dict[str, str] = {}

# Friendly-name map for known Central alert types
_HW_FRIENDLY: dict[str, str] = {
    "AP_DOWN": "AP Down",
    "AP_DISCONNECTED": "AP Disconnected",
    "AP_REBOOT": "AP Rebooted",
    "AP_FLAP": "AP Flapping",
    "GW_DOWN": "Gateway Down",
    "GW_DISCONNECTED": "Gateway Disconnected",
    "GW_FAILOVER": "Gateway Failover",
    "SWITCH_DOWN": "Switch Down",
    "SWITCH_DISCONNECTED": "Switch Disconnected",
    "SWITCH_PORT_DOWN": "Switch Port Down",
    "UPLINK_DOWN": "Uplink Down",
    "TUNNEL_DOWN": "Tunnel Down",
    "CONTROLLER_DOWN": "Controller Down",
}

# Device-type auto-detection from alert_type prefix
_ALERT_DEVICE_TYPE: dict[str, str] = {
    "AP_": "ap",
    "GW_": "gateway",
    "SWITCH_": "switch",
    "UPLINK_": "gateway",
    "TUNNEL_": "gateway",
    "CONTROLLER_": "gateway",
}


def _auto_device_type(alert_id: str) -> str:
    """Guess device type from alert_type prefix."""
    upper = alert_id.upper()
    for prefix, dtype in _ALERT_DEVICE_TYPE.items():
        if upper.startswith(prefix):
            return dtype
    return "ap"  # sensible default


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


# ── Client history persistence ────────────────────────────────────────────────

def _client_history_cutoff() -> datetime:
    return datetime.now(tz=timezone.utc) - timedelta(days=CLIENT_HISTORY_DAYS)


def _load_client_history() -> dict[str, dict[str, Any]]:
    """Load persisted client records from disk, dropping entries older than 7 days."""
    if not CLIENT_HISTORY_FILE.exists():
        return {}
    try:
        raw = json.loads(CLIENT_HISTORY_FILE.read_text(encoding="utf-8"))
        cutoff = _client_history_cutoff()
        kept: dict[str, dict[str, Any]] = {}
        for hostname, record in raw.items():
            ls = record.get("last_seen")
            if ls:
                try:
                    dt = datetime.fromisoformat(ls)
                    if dt.tzinfo is None:
                        dt = dt.replace(tzinfo=timezone.utc)
                    if dt >= cutoff:
                        record = dict(record)
                        record["last_seen"] = dt  # ensure datetime type for serialize_client
                        kept[hostname] = record
                        continue
                except Exception:
                    pass
        logger.info("Loaded %d client record(s) from history (%d expired)",
                    len(kept), len(raw) - len(kept))
        return kept
    except Exception as exc:
        logger.warning("Could not load client history: %s", exc)
        return {}


def _save_client_history() -> None:
    """Serialise the in-memory clients dict to disk, pruning entries older than 7 days."""
    try:
        cutoff = _client_history_cutoff()
        snapshot: dict[str, Any] = {}
        for hostname, c in clients.items():
            ls = c.get("last_seen")
            if isinstance(ls, datetime):
                if ls.tzinfo is None:
                    ls = ls.replace(tzinfo=timezone.utc)
                if ls < cutoff:
                    continue  # expired — do not persist
                entry = dict(c)
                entry["last_seen"] = ls.isoformat()
            else:
                entry = dict(c)
            snapshot[hostname] = entry
        CLIENT_HISTORY_FILE.write_text(json.dumps(snapshot, default=str), encoding="utf-8")
    except Exception as exc:
        logger.warning("Could not save client history: %s", exc)


async def client_history_saver() -> None:
    """Background task: flush clients to disk every CLIENT_SAVE_INTERVAL seconds."""
    await asyncio.sleep(CLIENT_SAVE_INTERVAL)
    while True:
        try:
            await asyncio.to_thread(_save_client_history)
            _update_service_health("client_history_saver", ok=True)
        except asyncio.CancelledError:
            raise
        except Exception as exc:
            _update_service_health("client_history_saver", ok=False, error=str(exc))
            logger.exception("Client history saver error: %s", exc)
        await asyncio.sleep(CLIENT_SAVE_INTERVAL)



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


def _central_token_state() -> dict[str, str]:
    """Return {state, detail} describing the current Central API auth status.

    States: not_configured | auth_failed | token_expired | connected
    """
    cfg = _central_cfg()
    if not cfg.get("cluster_url"):
        return {"state": "not_configured", "detail": "No cluster URL — configure in Setup tab"}
    if _is_new_central_api():
        if not cfg.get("client_id") or not cfg.get("client_secret"):
            return {"state": "not_configured", "detail": "Client ID / Client Secret required for Central mode"}
    else:
        if not cfg.get("access_token") and not central_token.get("access_token"):
            if settings.get("central_api", {}).get("mode") == "classic":
                return {"state": "not_configured", "detail": "Classic mode is saved separately — use Test Connection in Setup to validate credentials."}
            return {"state": "not_configured", "detail": "No access token — configure in Setup tab"}
    tok = central_token.get("access_token")
    if not tok:
        err = central_auth_error or "Authentication not yet attempted"
        return {"state": "auth_failed", "detail": err}
    if time.time() >= central_token.get("expires_at", 0):
        if central_auth_error:
            return {"state": "auth_failed", "detail": central_auth_error}
        if _can_refresh():
            return {"state": "token_expired", "detail": "Token has expired — will refresh on next poll"}
        return {"state": "token_expired", "detail": "Token has expired — re-enter a valid token in Setup tab"}
    return {"state": "connected", "detail": "Token valid"}


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
    global central_auth_error
    if _is_new_central_api():
        ok, msg = await _fetch_new_central_token(client)
        if not ok:
            central_auth_error = msg
            return False, msg
        # Probe to confirm the token works against the base URL
        ok, msg = await _probe_central_token(client)
        central_auth_error = None if ok else msg
        return ok, msg

    cfg = _central_cfg()
    token = cfg.get("access_token", "").strip()
    if not token:
        return False, "No access token configured."

    central_token["access_token"] = token
    if cfg.get("refresh_token"):
        central_token["refresh_token"] = cfg["refresh_token"]
    central_token["expires_at"] = time.time() + 7200

    ok, msg = await _probe_central_token(client)
    central_auth_error = None if ok else msg
    return ok, msg


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


async def _test_classic_central_connection(client: httpx.AsyncClient) -> tuple[bool, str]:
    classic_cfg = settings.get("central_api", {}).get("classic", {})
    base_url = str(classic_cfg.get("url", "")).strip().rstrip("/")
    username = str(classic_cfg.get("username", "")).strip()
    password = str(classic_cfg.get("password", ""))
    if not base_url or not username or not password:
        return False, "Central API not configured — enter URL, Username, and Password in Setup."
    try:
        resp = await client.get(base_url, auth=(username, password), timeout=15, follow_redirects=True)
    except Exception as exc:
        return False, f"Connection error reaching {base_url}: {exc}"
    if resp.status_code in (401, 403):
        return False, f"Classic credentials rejected (HTTP {resp.status_code})."
    if resp.status_code >= 500:
        return False, f"Classic endpoint returned HTTP {resp.status_code}: {resp.text[:300]}"
    return True, "Connected to Classic API successfully."


def _central_headers() -> dict[str, str]:
    token = central_token.get("access_token")
    if not token:
        raise HTTPException(status_code=503, detail="Aruba Central token not available — check connection settings")
    return {"Authorization": f"Bearer {token}"}


async def central_token_manager() -> None:
    """Background task: keep token valid. Runs every 5 minutes."""
    global central_auth_error
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
                        # Broadcast updated token state regardless of success
                        await broadcast({"type": "central_update", "status": _central_status_payload(), "wireless_clients": dict(central_wireless_clients), "hardware_alerts": _hw_alerts_payload(), "client_count_status": _client_count_payload(), "ts": time.time(), "token_state": _central_token_state()})
                    elif expiring and _can_refresh():
                        ok, msg = await _refresh_central_token(client)
                        if not ok:
                            logger.warning("Central token refresh failed: %s", msg)
                            central_auth_error = f"Token refresh failed: {msg}"
                            central_token["access_token"] = None  # force re-fetch next cycle
                        else:
                            central_auth_error = None
                        await broadcast({"type": "central_update", "status": _central_status_payload(), "wireless_clients": dict(central_wireless_clients), "hardware_alerts": _hw_alerts_payload(), "client_count_status": _client_count_payload(), "ts": time.time(), "token_state": _central_token_state()})
                _update_service_health("central_token", ok=True)
            except asyncio.CancelledError:
                raise
            except Exception as exc:
                _update_service_health("central_token", ok=False, error=str(exc))
                logger.exception("Central token manager error: %s", exc)
            await asyncio.sleep(300)


# ── Aruba Central poll loop ───────────────────────────────────────────────────
async def _poll_central_once(client: httpx.AsyncClient) -> None:
    """Single poll cycle: fetch alerts + insights per mapped site, evaluate checks."""
    if not _central_ready() or not central_token.get("access_token"):
        return

    site_mappings: dict[str, str] = settings.get("site_mappings", {})
    monitored: list[dict[str, Any]] = settings.get("monitored_checks", [])
    hw_checks: list[dict[str, Any]] = settings.get("hardware_checks", [])
    if not site_mappings or (not monitored and not hw_checks):
        return

    hw_check_ids: set[str] = {c["id"] for c in hw_checks}

    cfg = _central_cfg()
    base_url = cfg["cluster_url"].rstrip("/")
    headers = _central_headers()
    now = time.time()
    new_records: list[dict[str, Any]] = []

    # Accumulate hardware alert devices across all sites this cycle
    new_hw_devices: dict[str, dict[str, list[str]]] = {c["id"]: {} for c in hw_checks}

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
                                # Collect device names for hardware checks
                                if atype in hw_check_ids:
                                    dev = (alert.get("device_name") or alert.get("hostname")
                                           or alert.get("name") or "").strip()
                                    if dev:
                                        new_hw_devices.setdefault(atype, {}).setdefault(wsite, [])
                                        if dev not in new_hw_devices[atype][wsite]:
                                            new_hw_devices[atype][wsite].append(dev)
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

        # ── Fetch wireless client count for this site from Central ─
        wl_count = 0
        try:
            if _is_new_central_api():
                # New API: client count lives in site_health payload
                wl_count = int(
                    site_health.get("clientCount")
                    or site_health.get("client_count")
                    or 0
                )
            else:
                # Classic API: query wireless clients with site filter.
                # Try both "site" and "site_name" — Central uses each in
                # different API versions.
                fetched = False
                for clients_path in ["/monitoring/v2/clients/wireless", "/monitoring/v1/clients/wireless"]:
                    for site_param in ["site", "site_name"]:
                        resp = await client.get(
                            f"{base_url}{clients_path}",
                            headers=headers,
                            params={site_param: central_site, "limit": 1},
                            timeout=20,
                        )
                        if resp.status_code == 401 and _can_refresh():
                            ok, _ = await _refresh_central_token(client)
                            if ok:
                                headers = _central_headers()
                            resp = await client.get(
                                f"{base_url}{clients_path}",
                                headers=headers,
                                params={site_param: central_site, "limit": 1},
                                timeout=20,
                            )
                        logger.info(
                            "Central wireless clients %s ?%s=%s → %s body=%s",
                            clients_path, site_param, central_site,
                            resp.status_code, resp.text[:200],
                        )
                        if resp.status_code == 200:
                            body = resp.json()
                            wl_count = int(body.get("total") or body.get("count") or 0)
                            fetched = True
                            break
                        if resp.status_code == 404:
                            continue
                    if fetched:
                        break
        except Exception as exc:
            logger.warning("Central wireless client count fetch failed for site %s: %s", central_site, exc)
        central_wireless_clients[wsite] = wl_count

        _client_count_samples.setdefault(wsite, []).append((now, wl_count))
        cutoff_cc = now - CLIENT_COUNT_WINDOW
        _client_count_samples[wsite] = [
            s for s in _client_count_samples[wsite] if s[0] >= cutoff_cc
        ]

    # ── Commit hardware alert devices + detect transitions ────────
    global hardware_alert_devices
    hardware_alert_devices = new_hw_devices
    await _check_transitions_and_notify(now)

    # ── Persist client count baseline ─────────────────────────────
    _save_client_count_baseline()

    # ── Persist history ───────────────────────────────────────────
    if new_records:
        cutoff = _history_cutoff()
        async with history_lock:
            central_history[:] = [r for r in central_history if r["ts"] >= cutoff]
            central_history.extend(new_records)
        await asyncio.to_thread(_append_and_trim_history, new_records)

    await broadcast({"type": "central_update", "status": _central_status_payload(), "wireless_clients": dict(central_wireless_clients), "hardware_alerts": _hw_alerts_payload(), "client_count_status": _client_count_payload(), "ts": now, "token_state": _central_token_state()})
    _save_state_cache()


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


def _hw_alerts_payload() -> list[dict[str, Any]]:
    """Serialize hardware_alert_devices merged with check metadata for broadcast."""
    hw_checks: list[dict[str, Any]] = settings.get("hardware_checks", [])
    site_mappings: dict[str, str] = settings.get("site_mappings", {})
    result = []
    for check in hw_checks:
        cid = check["id"]
        devices_by_wsite = hardware_alert_devices.get(cid, {})
        total = sum(len(devs) for devs in devices_by_wsite.values())
        sites_out = {}
        for wsite, devs in devices_by_wsite.items():
            sites_out[wsite] = {
                "site_name": site_mappings.get(wsite, wsite),
                "devices": devs,
            }
        result.append({
            "id": cid,
            "name": check.get("name") or _HW_FRIENDLY.get(cid, cid),
            "device_type": check.get("device_type") or _auto_device_type(cid),
            "total": total,
            "sites": sites_out,
        })
    return result


def _save_client_count_baseline() -> None:
    """Persist the current per-site hourly averages to disk so a restart
    can display the last known baseline instead of NO_DATA."""
    snapshot: dict[str, Any] = {}
    now = time.time()
    for wsite, samples in _client_count_samples.items():
        if len(samples) < CLIENT_COUNT_MIN_SAMPLES:
            continue
        avg = sum(s[1] for s in samples) / len(samples)
        snapshot[wsite] = {"hourly_avg": round(avg, 1), "recorded_at": now}
    if snapshot:
        try:
            CLIENT_COUNT_BASELINE_FILE.write_text(json.dumps(snapshot, indent=2), encoding="utf-8")
            _client_count_baseline.update(snapshot)
        except Exception as exc:
            logger.warning("Could not save client count baseline: %s", exc)


async def hourly_baseline_saver() -> None:
    """Background task: recalculate and persist the client count baseline every hour.

    This replaces any stale baseline file with a fresh average computed from the
    last 60 minutes of live samples.  Running independently of the Central poll
    loop means the file is always at most ~1 hour old regardless of poll frequency.
    """
    await asyncio.sleep(3600)   # wait one full hour before first write
    while True:
        try:
            _save_client_count_baseline()
            logger.info("Client count baseline recalculated and persisted (hourly task).")
            _update_service_health("baseline_saver", ok=True)
        except asyncio.CancelledError:
            raise
        except Exception as exc:
            _update_service_health("baseline_saver", ok=False, error=str(exc))
            logger.exception("Hourly baseline saver error: %s", exc)
        await asyncio.sleep(3600)




def _client_count_payload() -> dict[str, Any]:
    """Per-site client count status based on 60-min rolling average.
    Falls back to persisted baseline when live samples are insufficient
    so the UI shows the last known baseline instead of NO_DATA after restart."""
    site_mappings = settings.get("site_mappings", {})
    result: dict[str, Any] = {}
    for wsite, samples in _client_count_samples.items():
        if not samples:
            continue
        current = samples[-1][1]
        site_name = site_mappings.get(wsite, wsite)
        if len(samples) < CLIENT_COUNT_MIN_SAMPLES:
            # Use persisted baseline average if available
            saved = _client_count_baseline.get(wsite)
            if saved:
                avg = saved["hourly_avg"]
                drop_pct = max(0.0, (avg - current) / avg * 100.0) if avg >= 1 else 0.0
                status = "DEGRADED" if drop_pct >= CLIENT_COUNT_DROP_PCT else "OK"
                result[wsite] = {
                    "site_name": site_name,
                    "current": current,
                    "hourly_avg": avg,
                    "drop_pct": drop_pct,
                    "status": status,
                    "ts": samples[-1][0],
                    "baseline_stale": True,
                    "baseline_recorded_at": saved["recorded_at"],
                }
            else:
                result[wsite] = {
                    "site_name": site_name,
                    "current": current,
                    "hourly_avg": current,
                    "drop_pct": 0.0,
                    "status": "NO_DATA",
                    "ts": samples[-1][0],
                    "baseline_stale": False,
                }
            continue
        avg = sum(s[1] for s in samples) / len(samples)
        if avg < 1:
            status = "OK"
            drop_pct = 0.0
        else:
            drop_pct = (avg - current) / avg * 100.0
            status = "DEGRADED" if drop_pct >= CLIENT_COUNT_DROP_PCT else "OK"
        result[wsite] = {
            "site_name": site_name,
            "current": current,
            "hourly_avg": avg,
            "drop_pct": drop_pct,
            "status": status,
            "ts": samples[-1][0],
            "baseline_stale": False,
        }
    return result


async def _check_transitions_and_notify(now: float) -> None:
    """Detect green→red transitions for sim checks and hardware checks, fire notifications."""
    notif = settings.get("notifications", {})
    transitions: list[dict[str, Any]] = []

    # ── Sim check transitions ─────────────────────────────────────
    for wsite, checks in central_status.items():
        for check_id, info in checks.items():
            key = f"sim:{check_id}:{wsite}"
            new_state = info["status"]  # "OK" or "ERROR"
            old_state = _prev_check_states.get(key)
            _prev_check_states[key] = new_state
            if old_state == "OK" and new_state == "ERROR":
                transitions.append({
                    "type": "sim",
                    "name": info.get("check_name", check_id),
                    "wsite": wsite,
                    "detail": f"Check '{info.get('check_name', check_id)}' turned red at site {wsite}",
                })

    # ── Hardware alert transitions ────────────────────────────────
    hw_checks: list[dict[str, Any]] = settings.get("hardware_checks", [])
    for check in hw_checks:
        cid = check["id"]
        total = sum(len(d) for d in hardware_alert_devices.get(cid, {}).values())
        new_state = "ERROR" if total > 0 else "OK"
        key = f"hw:{cid}"
        old_state = _prev_check_states.get(key)
        _prev_check_states[key] = new_state
        if old_state == "OK" and new_state == "ERROR":
            name = check.get("name") or _HW_FRIENDLY.get(cid, cid)
            transitions.append({
                "type": "hardware",
                "name": name,
                "detail": f"Hardware alert '{name}' is now active ({total} device(s) affected)",
            })

    for wsite, info in _client_count_payload().items():
        key = f"cc:{wsite}"
        new_state = info["status"]
        if new_state == "NO_DATA":
            _prev_check_states[key] = new_state
            continue
        old_state = _prev_check_states.get(key)
        _prev_check_states[key] = new_state
        if old_state == "OK" and new_state == "DEGRADED":
            transitions.append({
                "type": "client_count",
                "name": f"Client count — {info['site_name']}",
                "detail": (
                    f"Client count at {info['site_name']} dropped {info['drop_pct']:.1f}% "
                    f"(current: {info['current']}, avg: {info['hourly_avg']:.1f})"
                ),
            })

    if not transitions:
        return

    # ── Send notifications ────────────────────────────────────────
    for t in transitions:
        logger.warning("ALERT TRANSITION: %s", t["detail"])

    if notif.get("teams_enabled") and notif.get("teams_webhook_url"):
        await _send_teams_notifications(notif["teams_webhook_url"], transitions)

    if notif.get("email_enabled") and notif.get("smtp_host") and notif.get("smtp_to"):
        await asyncio.to_thread(_send_email_notifications, notif, transitions)


async def _send_teams_notifications(webhook_url: str, transitions: list[dict]) -> None:
    """POST an Adaptive Card to a Teams incoming webhook for each transition."""
    try:
        async with httpx.AsyncClient(timeout=10) as client:
            for t in transitions:
                card = {
                    "type": "message",
                    "attachments": [{
                        "contentType": "application/vnd.microsoft.card.adaptive",
                        "content": {
                            "$schema": "http://adaptivecards.io/schemas/adaptive-card.json",
                            "type": "AdaptiveCard",
                            "version": "1.4",
                            "body": [
                                {"type": "TextBlock", "size": "Medium", "weight": "Bolder",
                                 "text": f"🔴 Client Simulator Alert: {t['name']}"},
                                {"type": "TextBlock", "text": t["detail"], "wrap": True},
                            ],
                        },
                    }],
                }
                resp = await client.post(webhook_url, json=card)
                if resp.status_code not in (200, 202):
                    logger.warning("Teams webhook returned %s: %s", resp.status_code, resp.text[:200])
    except Exception as exc:
        logger.warning("Teams notification failed: %s", exc)


def _send_email_notifications(notif: dict, transitions: list[dict]) -> None:
    """Send SMTP email for each transition (runs in thread pool)."""
    import smtplib
    from email.mime.text import MIMEText
    from email.mime.multipart import MIMEMultipart

    to_addrs = notif.get("smtp_to", [])
    if isinstance(to_addrs, str):
        to_addrs = [a.strip() for a in to_addrs.split(",") if a.strip()]
    if not to_addrs:
        return

    body_lines = ["Client Simulator Alert\n"]
    for t in transitions:
        body_lines.append(f"• {t['detail']}")
    body = "\n".join(body_lines)

    msg = MIMEMultipart()
    msg["From"] = notif.get("smtp_from", "client-sim@localhost")
    msg["To"] = ", ".join(to_addrs)
    msg["Subject"] = f"[Client Simulator] {len(transitions)} check(s) turned RED"
    msg.attach(MIMEText(body, "plain"))

    try:
        host = notif.get("smtp_host", "")
        port = int(notif.get("smtp_port", 587))
        with smtplib.SMTP(host, port, timeout=15) as smtp:
            smtp.ehlo()
            if port != 25:
                smtp.starttls()
            user = notif.get("smtp_user", "")
            pwd = notif.get("smtp_password", "")
            if user and pwd:
                smtp.login(user, pwd)
            smtp.sendmail(msg["From"], to_addrs, msg.as_string())
        logger.info("Email notification sent to %s", to_addrs)
    except Exception as exc:
        logger.warning("Email notification failed: %s", exc)


async def central_poller() -> None:
    """Background task: poll Central every CENTRAL_POLL_INTERVAL seconds."""
    async with httpx.AsyncClient() as client:
        while True:
            try:
                await _poll_central_once(client)
                _update_service_health("central_poller", ok=True)
            except asyncio.CancelledError:
                raise
            except Exception as exc:
                _update_service_health("central_poller", ok=False, error=str(exc))
                logger.exception("Central poll error: %s", exc)
            await asyncio.sleep(CENTRAL_POLL_INTERVAL)


@asynccontextmanager
async def lifespan(app: FastAPI):  # noqa: ARG001
    global central_history
    logger.info("=" * 60)
    logger.info("Client Simulator  v%s  starting up", INSTALLER_VERSION)
    logger.info("=" * 60)
    central_history = await asyncio.to_thread(_load_history)
    _load_state_cache()
    _load_commands()
    _load_reclone_state()
    _load_relay_state()
    _load_update_state()
    _load_vm_watchdog()
    # Refresh cs-webui frontend files before accepting requests (non-blocking,
    # awaited once so the fix is in place before the first page load).
    await asyncio.wait_for(refresh_webui_frontend(), timeout=60)
    background_tasks["sync_repo"] = asyncio.create_task(sync_repo())
    background_tasks["heartbeat"] = asyncio.create_task(heartbeat_check())
    background_tasks["central_token"] = asyncio.create_task(central_token_manager())
    background_tasks["central_poller"] = asyncio.create_task(central_poller())
    background_tasks["update_checker"] = asyncio.create_task(check_for_update())
    background_tasks["relay"] = asyncio.create_task(relay_loop())
    background_tasks["client_history_saver"] = asyncio.create_task(client_history_saver())
    background_tasks["command_expiry"] = asyncio.create_task(expire_commands())
    background_tasks["auto_recovery"] = asyncio.create_task(auto_recovery_check())
    background_tasks["vm_watchdog"] = asyncio.create_task(vm_watchdog_loop())
    background_tasks["schedule_check"] = asyncio.create_task(schedule_check())
    background_tasks["gkill_switch"] = asyncio.create_task(gkill_switch_poller())
    background_tasks["baseline_saver"] = asyncio.create_task(hourly_baseline_saver())
    background_tasks["acme_renewal"] = asyncio.create_task(acme_renewal_loop())
    yield
    # Flush client history to disk on shutdown
    await asyncio.to_thread(_save_client_history)
    for task in background_tasks.values():
        task.cancel()
    for task in background_tasks.values():
        with contextlib.suppress(asyncio.CancelledError):
            await task


app = FastAPI(title="Client Simulator", lifespan=lifespan)

# Prevent browser caching on all responses
class NoCacheMiddleware(BaseHTTPMiddleware):
    async def dispatch(self, request: Request, call_next):
        response = await call_next(request)
        response.headers["Cache-Control"] = "no-cache, no-store, must-revalidate"
        response.headers["Pragma"] = "no-cache"
        response.headers["Expires"] = "0"
        return response

app.add_middleware(NoCacheMiddleware)
clients: dict[str, dict[str, Any]] = _load_client_history()

# ── Command inbox ──────────────────────────────────────────────────────────────
commands: list[dict[str, Any]] = []
COMMAND_MAX = 100                 # keep last N commands in memory
COMMAND_EXPIRE_SECS = 300         # pending/delivered commands expire after 5 minutes
COMMAND_RESULT_RETENTION_SECS = 60  # keep ACK'd/expired results briefly so the UI can show them

ws_connections: list[WebSocket] = []
_acme_challenges: dict[str, str] = {}
_acme_status: dict[str, Any] = {"running": False, "last_result": None, "last_error": None}
state_lock = asyncio.Lock()
repo_state = {"synced": False, "error": None, "last_sync": None}
gkill_switch_state: dict[str, Any] = {"value": "off", "last_fetched": None, "error": None}
GKILL_SWITCH_URL = "https://raw.githubusercontent.com/solutions-hpe/client-sim/main/kill_switch.txt"
relay_state: dict[str, Any] = {
    "enabled": settings.get("relay_enabled") == "on" and bool(settings.get("relay_server_url")),
    "connected": False,
    "last_sync": None,
    "error": None,
    "registration_status": _relay_registration_status_from_settings(),
}
relay_registration_refresh_needed = bool(relay_state["enabled"])
# Capped registration diagnostic log — last 50 attempts
_RELAY_DIAG_MAX = 50
relay_diag_log: list[dict[str, Any]] = []
_repo_ver: str | None = None


def _relay_diag_append(event: str, **kwargs: Any) -> None:
    """Append one entry to relay_diag_log, keeping the list capped."""
    entry = {"ts": datetime.now().strftime("%Y-%m-%d %H:%M:%S"), "event": event, **kwargs}
    relay_diag_log.append(entry)
    if len(relay_diag_log) > _RELAY_DIAG_MAX:
        del relay_diag_log[:-_RELAY_DIAG_MAX]


def _default_provision_run_state() -> dict[str, Any]:
    return {
        "running": False,
        "started_at": None,
        "updated_at": None,
        "completed_at": None,
        "total": 0,
        "completed": 0,
        "failed": 0,
        "items": [],
    }


proxmox_state: dict[str, Any] = {
    "connected": False,
    "last_seen": None,
    "node": {},
    "vms": [],
    "unknown_usb": [],
    "usb_state": [],
    "present_usb": [],
    "missing_timeout_mins": 60,
    "agent_version": None,
    "pve_version": None,
    "prov_summary": None,   # {"action": "provisioned"|"deleted", "count": N, "at": <unix ts>}
    "prov_run": _default_provision_run_state(),
}
# Previous usb_state vmid→prov_status snapshot for transition detection
_prev_usb_by_vmid: dict[str, str] = {}
# Ring buffer: last 500 agent log lines
proxmox_log_buffer: list[str] = []
PROXMOX_LOG_MAX = 500
proxmox_watchdog_log: list[dict[str, Any]] = []
PROXMOX_WATCHDOG_LOG_MAX = 100
# Pending/approved Proxmox agent registry
pending_proxmox_agents: dict[str, dict[str, Any]] = {}
approved_proxmox_agents: dict[str, str] = dict(settings.get("proxmox_approved_agents", {}))
reclone_state: dict[str, Any] = {
    "status": "idle",
    "type": None,
    "total": 0,
    "completed": 0,
    "failed": 0,
    "current_vm": None,
    "log": [],
    "auto_recovery_log": [],
    "last_run": None,
    "started_at": None,
}
vm_watchdog: dict[str, dict[str, Any]] = {}
update_all_state: dict[str, Any] = {
    "running": False,
    "phase": "idle",
    "total_agents": 0,
    "completed_agents": 0,
    "failed_agents": 0,
    "agent_cmds": [],
    "started_at": None,
    "error": None,
}
relay_sites: dict[str, dict[str, Any]] = {}
background_tasks: dict[str, asyncio.Task[Any]] = {}
service_health: dict[str, dict[str, Any]] = {}
reclone_run_lock = asyncio.Lock()
last_schedule_trigger: str | None = None

class ClientStatus(BaseModel):
    hostname: str
    simulation_id: str
    platform: str
    hw_type: str | None = None
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
    github_token: str | None = None
    central_api: dict[str, Any] | None = None
    central_config: dict[str, str] | None = None
    site_mappings: dict[str, str] | None = None
    monitored_checks: list[dict[str, str]] | None = None
    hardware_checks: list[dict[str, str]] | None = None
    notifications: dict[str, Any] | None = None
    repo_sync_interval: int | None = None
    relay_enabled: str | None = None
    relay_server_url: str | None = None
    relay_spoke_name: str | None = None
    relay_tenant_hint: str | None = None
    relay_api_key: str | None = None
    relay_spoke_id: str | None = None
    relay_tenant_id: str | None = None
    relay_poll_interval: int | None = None
    usb_vidpids: str | None = None
    usb_missing_timeout: str | None = None
    usb_template_id: str | None = None
    vm_image_1_template_id: str | None = None
    vm_image_2_template_id: str | None = None
    vm_image_1_pct: str | None = None
    usb_auto_provision: str | None = None
    usb_ignored_vidpids: str | None = None
    ignored_hostnames: str | None = None
    vm_silent_timeout: str | None = None
    reclone_schedule_enabled: str | None = None
    reclone_schedule_cron: str | None = None
    reclone_concurrency: str | None = None
    l1_vlan_start: str | None = None
    l1_vlan_end: str | None = None
    spoke_tls: str | None = None


class SimulationConfigUpdate(BaseModel):
    section: str
    updates: dict[str, str] = Field(default_factory=dict)


class OverridesSaveRequest(BaseModel):
    username: str
    flags: dict[str, str] = Field(default_factory=dict)


def utcnow() -> datetime:
    return datetime.now(timezone.utc)


def iso_utcnow() -> str:
    return utcnow().isoformat().replace("+00:00", "Z")


def _update_service_health(name: str, *, ok: bool, error: str | None = None) -> None:
    now = iso_utcnow()
    entry = service_health.setdefault(name, {"run_count": 0, "consecutive_errors": 0})
    entry["last_run"] = now
    entry["run_count"] = entry.get("run_count", 0) + 1
    if ok:
        entry["last_success"] = now
        entry["last_error_msg"] = None
        entry["consecutive_errors"] = 0
        entry["status"] = "ok"
    else:
        entry["last_error_msg"] = error or "unknown error"
        entry["consecutive_errors"] = entry.get("consecutive_errors", 0) + 1
        entry["status"] = "error" if entry["consecutive_errors"] >= 3 else "warning"


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
        "hw_type": client.get("hw_type") or "",
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


def _normalize_command_action(value: Any) -> str:
    return str(value or "").strip().lower().replace("-", "_")


def _normalize_command_type(value: Any) -> str | None:
    normalized = str(value or "").strip().replace("-", "_")
    return normalized or None


def _command_args_signature(args: dict[str, Any] | None) -> str:
    try:
        return json.dumps(args or {}, sort_keys=True, separators=(",", ":"), default=str)
    except TypeError:
        safe_args = json.loads(json.dumps(args or {}, default=str))
        return json.dumps(safe_args, sort_keys=True, separators=(",", ":"))


def _trim_commands_locked() -> None:
    if len(commands) <= COMMAND_MAX:
        return
    terminal = {"completed", "failed", "expired"}
    idx = 0
    while len(commands) > COMMAND_MAX and idx < len(commands):
        if commands[idx].get("status") in terminal:
            del commands[idx]
            continue
        idx += 1
    if len(commands) > COMMAND_MAX:
        del commands[:len(commands) - COMMAND_MAX]


def _cleanup_commands_locked(now: float | None = None) -> tuple[int, int]:
    now = now or time.time()
    expired = 0
    for cmd in commands:
        if cmd.get("status") in {"pending", "delivered"} and (now - cmd.get("created_at", now)) > COMMAND_EXPIRE_SECS:
            cmd["status"] = "expired"
            cmd["updated_at"] = now
            cmd["purge_after"] = now + COMMAND_RESULT_RETENTION_SECS
            expired += 1

    before = len(commands)
    commands[:] = [
        cmd for cmd in commands
        if cmd.get("status") not in {"completed", "failed", "expired"}
        or now < float(cmd.get("purge_after") or cmd.get("updated_at", cmd.get("created_at", now)) + COMMAND_RESULT_RETENTION_SECS)
    ]
    purged = before - len(commands)
    _trim_commands_locked()
    if expired or purged:
        _save_commands()
    return expired, purged


def _find_active_duplicate_command_locked(target: str, action: str, args: dict[str, Any]) -> dict[str, Any] | None:
    args_sig = _command_args_signature(args)
    for cmd in commands:
        if cmd.get("target") != target or cmd.get("action") != action:
            continue
        if cmd.get("status") not in {"pending", "delivered"}:
            continue
        if _command_args_signature(cmd.get("args", {})) == args_sig:
            return cmd
    return None


def _enqueue_command_locked(target: str, action: str, args: dict[str, Any] | None = None, command_type: str | None = None) -> tuple[dict[str, Any], bool, int, int]:
    normalized_action = _normalize_command_action(action)
    normalized_type = _normalize_command_type(command_type)
    normalized_args = dict(args or {})
    if target == "proxmox" and normalized_action == "delete_vm":
        normalized_args = _prepare_delete_vm_args(normalized_args)

    now = time.time()
    expired, purged = _cleanup_commands_locked(now)
    existing = _find_active_duplicate_command_locked(target, normalized_action, normalized_args)
    if existing is not None:
        return existing, False, expired, purged

    cmd = _make_command(target, normalized_action, normalized_args, command_type=normalized_type)
    commands.append(cmd)
    _trim_commands_locked()
    _save_commands()
    return cmd, True, expired, purged


def _make_command(target: str, action: str, args: dict | None = None, command_type: str | None = None) -> dict[str, Any]:
    now = time.time()
    return {
        "id": str(uuid.uuid4()),
        "target": target,
        "action": _normalize_command_action(action),
        "args": dict(args or {}),
        "type": _normalize_command_type(command_type),
        "status": "pending",
        "created_at": now,
        "updated_at": now,
        "expires_at": now + COMMAND_EXPIRE_SECS,
        "purge_after": None,
        "result": None,
        "message": None,
    }


def _serialize_commands() -> list[dict[str, Any]]:
    return [
        {**cmd, "age_secs": int(time.time() - cmd["created_at"])}
        for cmd in commands
    ]


def _normalize_toggle(value: Any) -> str:
    if isinstance(value, str):
        return "on" if value.lower() == "on" else "off"
    return "on" if value else "off"


def _parse_json_list(value: Any) -> list[Any]:
    if isinstance(value, list):
        return value
    if value in (None, ""):
        return []
    try:
        parsed = json.loads(str(value))
    except Exception:
        return []
    return parsed if isinstance(parsed, list) else []


def _ensure_json_list(value: str, field_name: str) -> str:
    try:
        parsed = json.loads(value or "[]")
    except Exception as exc:
        raise HTTPException(status_code=422, detail=f"{field_name} must be valid JSON") from exc
    if not isinstance(parsed, list):
        raise HTTPException(status_code=422, detail=f"{field_name} must be a JSON array")
    return json.dumps(parsed)


def _setting_int(key: str, default: int, minimum: int = 0) -> int:
    try:
        value = int(str(settings.get(key, default)).strip())
    except (TypeError, ValueError, AttributeError):
        value = default
    return max(minimum, value)


def _parse_ts(value: Any) -> float | None:
    if value in (None, ""):
        return None
    if isinstance(value, (int, float)):
        return float(value)
    if isinstance(value, str):
        raw = value.strip()
        if not raw:
            return None
        try:
            return float(raw)
        except ValueError:
            pass
        try:
            return datetime.fromisoformat(raw.replace("Z", "+00:00")).timestamp()
        except ValueError:
            return None
    return None


def _vm_watchdog_key(vmid: Any) -> str | None:
    try:
        return str(int(vmid))
    except (TypeError, ValueError):
        return None


def _client_last_seen_for_hostname(hostname: Any, client_seen: dict[str, Any] | None = None) -> datetime | None:
    normalized = str(hostname or "").strip().lower()
    if not normalized:
        return None
    seen_map = client_seen or {name: info.get("last_seen") for name, info in clients.items()}
    for candidate, last_seen in seen_map.items():
        if str(candidate or "").strip().lower() == normalized and isinstance(last_seen, datetime):
            return last_seen
    return None


def _vm_has_checked_in(hostname: Any, clone_completed_at: float | None, client_seen: dict[str, Any] | None = None) -> bool:
    if clone_completed_at is None:
        return False
    last_seen = _client_last_seen_for_hostname(hostname, client_seen)
    return bool(last_seen and last_seen.timestamp() > float(clone_completed_at))


def _record_vm_watchdog_clone_completed(
    vmid: Any,
    hostname: Any,
    *,
    clone_completed_at: float | None = None,
    reclone_count: int | None = None,
) -> bool:
    vmid_key = _vm_watchdog_key(vmid)
    if vmid_key is None:
        return False
    current = vm_watchdog.get(vmid_key) or {}
    if reclone_count is None:
        try:
            reclone_count = max(0, int(current.get("reclone_count", 0) or 0))
        except (TypeError, ValueError):
            reclone_count = 0
    vm_watchdog[vmid_key] = {
        "clone_completed_at": float(clone_completed_at if clone_completed_at is not None else time.time()),
        "reclone_count": max(0, int(reclone_count)),
        "hostname": str(hostname or current.get("hostname") or "").strip(),
    }
    return True


def _vm_pending_checkin(vm: dict[str, Any], client_seen: dict[str, Any] | None = None) -> bool:
    vmid_key = _vm_watchdog_key(vm.get("vmid"))
    if vmid_key is None:
        return False
    entry = vm_watchdog.get(vmid_key)
    if not entry:
        return False
    clone_completed_at = _parse_ts(entry.get("clone_completed_at"))
    hostname = str(entry.get("hostname") or vm.get("name") or "").strip()
    return not _vm_has_checked_in(hostname, clone_completed_at, client_seen)


def _proxmox_usb_config_payload() -> dict[str, Any]:
    # Read sim_phy from the repo's simulation.conf so the agent knows which
    # USB device type (wired/wireless) to provision and assign.
    sim_phy = "wireless"
    try:
        sim_conf = REPO_DIR / "configs" / "simulation.conf"
        if sim_conf.exists():
            parser = configparser.ConfigParser()
            parser.read_string(sim_conf.read_text(encoding="utf-8"))
            sim_phy = parser.get("simulation", "sim_phy", fallback="wireless").strip().lower() or "wireless"
    except Exception:
        pass
    return {
        "vidpids": _parse_json_list(settings.get("usb_vidpids", "[]")),
        "missing_timeout": _setting_int("usb_missing_timeout", 60, 1),
        "image1_template_id": _setting_int("vm_image_1_template_id", _setting_int("usb_linux_template_id", _setting_int("usb_template_id", 100, 1), 1), 1),
        "image2_template_id": _setting_int("vm_image_2_template_id", _setting_int("usb_windows_template_id", 200, 1), 1),
        "image1_pct": max(0, min(100, int(str(settings.get("vm_image_1_pct", "50")).strip() or "50"))),
        "auto_provision": _normalize_toggle(settings.get("usb_auto_provision", "off")),
        "ignored_vidpids": _parse_json_list(settings.get("usb_ignored_vidpids", "[]")),
        "sim_phy": sim_phy,
        "reclone_concurrency": max(1, int(str(settings.get("reclone_concurrency", "1")).strip() or "1")),
        "l1_vlan_start": max(1, min(4094, int(str(settings.get("l1_vlan_start", "100")).strip() or "100"))),
        "l1_vlan_end": max(1, min(4094, int(str(settings.get("l1_vlan_end", "199")).strip() or "199"))),
    }


def _normalize_proxmox_hostname(hostname: Any) -> str:
    return str(hostname or "").strip().rstrip(".").lower()


def _proxmox_hostname_aliases(hostname: Any) -> tuple[str, ...]:
    normalized = _normalize_proxmox_hostname(hostname)
    if not normalized:
        return ()
    aliases = [normalized]
    short = normalized.split(".", 1)[0]
    if short and short not in aliases:
        aliases.append(short)
    return tuple(aliases)


def _proxmox_hostnames_match(left: Any, right: Any) -> bool:
    left_aliases = set(_proxmox_hostname_aliases(left))
    return bool(left_aliases and left_aliases.intersection(_proxmox_hostname_aliases(right)))


def _resolve_proxmox_agent_hostname(hostname: Any, registry: dict[str, Any]) -> str | None:
    if not isinstance(registry, dict):
        return None
    for registered_hostname in registry:
        if _proxmox_hostnames_match(hostname, registered_hostname):
            return registered_hostname
    return None


def _upsert_pending_proxmox_agent(hostname: Any, client_ip: str, now: float) -> str | None:
    resolved_hostname = _resolve_proxmox_agent_hostname(hostname, pending_proxmox_agents)
    if not resolved_hostname:
        resolved_hostname = _normalize_proxmox_hostname(hostname)
    if not resolved_hostname:
        return None
    entry = pending_proxmox_agents.get(resolved_hostname)
    if entry is None:
        pending_proxmox_agents[resolved_hostname] = {"ip": client_ip, "first_seen": now, "last_seen": now}
    else:
        entry["ip"] = client_ip
        entry["last_seen"] = now
    return resolved_hostname


def _pending_proxmox_payload() -> list[dict[str, Any]]:
    now = time.time()
    return [
        {
            "hostname": hostname,
            "ip": info.get("ip", ""),
            "first_seen": info.get("first_seen", now),
            "last_seen": info.get("last_seen", now),
        }
        for hostname, info in pending_proxmox_agents.items()
    ]


def _approved_proxmox_payload() -> list[dict[str, Any]]:
    ver = proxmox_state.get("agent_version")
    return [{"hostname": hostname, "agent_version": ver} for hostname in approved_proxmox_agents]


def _client_os_counts() -> dict[str, int]:
    """Count connected clients by platform (linux/windows)."""
    counts: dict[str, int] = {"linux": 0, "windows": 0}
    for c in clients.values():
        platform = str(c.get("platform", "")).lower()
        if platform in counts:
            counts[platform] += 1
    return counts


def _read_local_kill_switch() -> str:
    """Read kill_switch from the repo's configs/simulation.conf without full parse."""
    try:
        conf = (REPO_DIR / "configs" / "simulation.conf").read_text(encoding="utf-8")
        for line in conf.splitlines():
            if line.strip().startswith("kill_switch"):
                val = line.split("=", 1)[-1].strip()
                return val if val in ("on", "off") else "off"
    except Exception:
        pass
    return "off"


def _proxmox_status_payload() -> dict[str, Any]:
    node = proxmox_state.get("node") or {}
    client_seen = {hostname: client.get("last_seen") for hostname, client in clients.items()}
    vms = []
    for vm in proxmox_state.get("vms", []):
        enriched_vm = dict(vm)
        enriched_vm["pending_checkin"] = _vm_pending_checkin(enriched_vm, client_seen)
        vms.append(enriched_vm)
    return {
        **proxmox_state,
        "vms": vms,
        "hostname": str(node.get("hostname") or "").strip(),
        "pending_proxmox": _pending_proxmox_payload(),
        "approved_proxmox": _approved_proxmox_payload(),
        "reclone_state": dict(reclone_state),
        "client_os_counts": _client_os_counts(),
        "auto_recovery_pending": _auto_recovery_pending_vmids(),
        "webui_vmid": WEBUI_VMID,
    }


def _find_proxmox_vm(vmid: int) -> dict[str, Any] | None:
    for vm in proxmox_state.get("vms", []):
        try:
            if int(vm.get("vmid")) == vmid:
                return dict(vm)
        except (TypeError, ValueError):
            continue
    return None


def _prepare_delete_vm_args(args: dict[str, Any] | None) -> dict[str, Any]:
    if not isinstance(args, dict):
        raise HTTPException(status_code=422, detail="args must be an object")
    try:
        vmid = int(args.get("vmid"))
    except (TypeError, ValueError):
        raise HTTPException(status_code=422, detail="A valid vmid is required") from None

    vm = _find_proxmox_vm(vmid)
    if vm is None:
        if not proxmox_state.get("vms"):
            raise HTTPException(status_code=503, detail="No Proxmox VM inventory is available yet")
        raise HTTPException(status_code=404, detail=f"VM {vmid} was not found in Proxmox inventory")
    if vm.get("is_template"):
        raise HTTPException(status_code=400, detail="Templates cannot be deleted from the VM list")
    if WEBUI_VMID is not None and vmid == WEBUI_VMID:
        raise HTTPException(status_code=403, detail="Cannot delete the container running this service")

    prepared = dict(args)
    prepared["vmid"] = vmid
    vm_type = str(vm.get("type") or "qemu").strip().lower()
    prepared["vm_type"] = vm_type if vm_type in {"qemu", "lxc"} else "qemu"
    if vm.get("name"):
        prepared["vm_name"] = str(vm.get("name"))
    return prepared


async def _broadcast_proxmox_state() -> None:
    global _last_proxmox_hash
    _save_state_cache()
    payload = _proxmox_status_payload()
    h = hashlib.md5(json.dumps(payload, sort_keys=True, default=str).encode()).hexdigest()
    if h == _last_proxmox_hash:
        return
    _last_proxmox_hash = h
    await broadcast({"type": "proxmox_update", **payload})


async def _broadcast_reclone_state() -> None:
    _save_reclone_state()
    await broadcast({"type": "reclone_update", **dict(reclone_state)})


def _update_reclone_log(vmid: int, name: str, status: str, message: str | None = None) -> None:
    timestamp = iso_utcnow()
    for entry in reversed(reclone_state["log"]):
        if entry.get("vmid") == vmid and entry.get("status") in {"queued", "in_progress"}:
            entry.update({"name": name, "status": status, "timestamp": timestamp})
            if message:
                entry["message"] = message
            elif entry.get("message") and status in {"queued", "in_progress"}:
                entry.pop("message", None)
            break
    else:
        entry = {"vmid": vmid, "name": name, "status": status, "timestamp": timestamp}
        if message:
            entry["message"] = message
        reclone_state["log"].append(entry)
    reclone_state["log"] = reclone_state["log"][-200:]
    _save_reclone_state()


def _parse_reclone_schedule(value: Any) -> tuple[str, int, int] | None:
    raw = str(value or "").strip().lower()
    parts = raw.split()
    if len(parts) != 2:
        return None
    day, clock = parts
    if day not in {"monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"}:
        return None
    try:
        hour, minute = (int(piece) for piece in clock.split(":", 1))
    except ValueError:
        return None
    if hour not in range(24) or minute not in range(60):
        return None
    return day, hour, minute


def _has_pending_reclone(vmid: int) -> bool:
    for cmd in commands:
        if cmd.get("action") != "reclone_vm":
            continue
        if int(cmd.get("args", {}).get("vmid", -1)) != vmid:
            continue
        if cmd.get("status") in {"pending", "delivered"}:
            return True
    return False


def _auto_recovery_pending_vmids() -> list[int]:
    """Return VMIDs that have a pending/delivered auto-recovery reclone command."""
    return [
        int(cmd.get("args", {}).get("vmid", -1))
        for cmd in commands
        if cmd.get("action") == "reclone_vm"
        and cmd.get("type") == "auto-recovery"
        and cmd.get("status") in {"pending", "delivered"}
        and cmd.get("args", {}).get("vmid") is not None
    ]


def _proxmox_unassigned_present_usb() -> list[dict[str, Any]]:
    assigned_buses = {
        str(entry.get("bus_path", "")).strip()
        for entry in proxmox_state.get("usb_state", [])
        if str(entry.get("bus_path", "")).strip() and entry.get("vmid") is not None
    }
    return [
        dict(entry)
        for entry in proxmox_state.get("present_usb", [])
        if str(entry.get("bus_path", "")).strip()
        and str(entry.get("bus_path", "")).strip() not in assigned_buses
    ]



def _normalize_proxmox_usb_state(
    usb_state: Any,
    present_usb: Any,
) -> list[dict[str, Any]]:
    present_by_bus = {
        str(entry.get("bus_path", "")).strip(): dict(entry)
        for entry in (present_usb if isinstance(present_usb, list) else [])
        if isinstance(entry, dict) and str(entry.get("bus_path", "")).strip()
    }
    normalized: list[dict[str, Any]] = []
    for raw_entry in usb_state if isinstance(usb_state, list) else []:
        if not isinstance(raw_entry, dict):
            continue
        entry = dict(raw_entry)
        bus_path = str(entry.get("bus_path", "")).strip()
        present_entry = present_by_bus.get(bus_path)
        if present_entry:
            entry["missing_since"] = None
            if entry.get("prov_status") in {None, "", "missing", "tearing_down"}:
                entry["prov_status"] = "active"
            if not entry.get("vidpid") and present_entry.get("vidpid"):
                entry["vidpid"] = present_entry.get("vidpid")
            if not entry.get("name") and present_entry.get("name"):
                entry["name"] = present_entry.get("name")
        normalized.append(entry)
    return normalized


def _derive_provision_run_item_status(
    usb_entry: dict[str, Any],
    vm_by_vmid: dict[str, dict[str, Any]],
) -> str:
    if str(usb_entry.get("prov_status") or "").strip().lower() != "provisioning":
        return "done"
    vm = vm_by_vmid.get(str(usb_entry.get("vmid"))) or {}
    vm_status = str(vm.get("status") or "").strip().lower()
    return "configuring" if vm_status == "running" else "cloning"


def _update_provision_run_state(vms: list[dict[str, Any]], usb_state: list[dict[str, Any]], now: int) -> None:
    run = _default_provision_run_state()
    current = proxmox_state.get("prov_run")
    if isinstance(current, dict):
        for key in ("running", "started_at", "updated_at", "completed_at", "total", "completed", "failed"):
            run[key] = current.get(key)
        run["items"] = [
            dict(item)
            for item in current.get("items", [])
            if isinstance(item, dict) and item.get("vmid") is not None
        ]

    vm_by_vmid = {
        str(vm.get("vmid")): dict(vm)
        for vm in (vms if isinstance(vms, list) else [])
        if isinstance(vm, dict) and vm.get("vmid") is not None
    }
    usb_by_vmid = {
        str(entry.get("vmid")): dict(entry)
        for entry in (usb_state if isinstance(usb_state, list) else [])
        if isinstance(entry, dict) and entry.get("vmid") is not None
    }
    provisioning_vmids = [
        vmid
        for vmid, entry in usb_by_vmid.items()
        if str(entry.get("prov_status") or "").strip().lower() == "provisioning"
    ]
    provisioning_vmids.sort(key=lambda value: int(value) if str(value).isdigit() else value)

    if not run.get("running") and provisioning_vmids:
        run = _default_provision_run_state()
        run["running"] = True
        run["started_at"] = now
        run["updated_at"] = now

    items = run["items"]
    item_by_vmid = {str(item.get("vmid")): item for item in items if item.get("vmid") is not None}

    if run.get("running"):
        for vmid in provisioning_vmids:
            entry = usb_by_vmid[vmid]
            item = item_by_vmid.get(vmid)
            if item is None:
                vm = vm_by_vmid.get(vmid) or {}
                item = {
                    "vmid": entry.get("vmid"),
                    "vm_name": str(vm.get("name") or "").strip() or None,
                    "usb_name": str(entry.get("name") or "").strip() or None,
                    "bus_path": str(entry.get("bus_path") or "").strip() or None,
                    "vidpid": str(entry.get("vidpid") or "").strip() or None,
                    "status": _derive_provision_run_item_status(entry, vm_by_vmid),
                    "started_at": now,
                    "updated_at": now,
                    "completed_at": None,
                }
                items.append(item)
                item_by_vmid[vmid] = item
            elif item.get("status") in {"done", "failed"}:
                item.update({
                    "status": _derive_provision_run_item_status(entry, vm_by_vmid),
                    "started_at": now,
                    "updated_at": now,
                    "completed_at": None,
                })

    for item in items:
        vmid_key = str(item.get("vmid"))
        entry = usb_by_vmid.get(vmid_key)
        vm = vm_by_vmid.get(vmid_key) or {}
        if vm.get("name"):
            item["vm_name"] = str(vm.get("name"))
        if entry:
            if entry.get("name"):
                item["usb_name"] = str(entry.get("name"))
            if entry.get("bus_path"):
                item["bus_path"] = str(entry.get("bus_path"))
            if entry.get("vidpid"):
                item["vidpid"] = str(entry.get("vidpid"))

        previous_status = str(item.get("status") or "pending")
        next_status = previous_status
        if entry and str(entry.get("prov_status") or "").strip().lower() == "provisioning":
            next_status = _derive_provision_run_item_status(entry, vm_by_vmid)
            item["completed_at"] = None
        elif entry and str(entry.get("prov_status") or "").strip().lower() == "active":
            if previous_status != "failed":
                next_status = "done"
                item["completed_at"] = item.get("completed_at") or now
        elif run.get("running") and previous_status not in {"done", "failed"}:
            if _prev_usb_by_vmid.get(vmid_key) == "provisioning":
                next_status = "failed"
                item["completed_at"] = item.get("completed_at") or now

        if next_status != previous_status or (entry and str(entry.get("prov_status") or "").strip().lower() == "provisioning"):
            item["updated_at"] = now
        item["status"] = next_status

    run["total"] = len(items)
    run["completed"] = sum(1 for item in items if item.get("status") == "done")
    run["failed"] = sum(1 for item in items if item.get("status") == "failed")

    active_items = [item for item in items if item.get("status") not in {"done", "failed"}]
    if run.get("running") and items and not active_items:
        run["running"] = False
        run["completed_at"] = now
        run["updated_at"] = now
    elif run.get("running"):
        run["updated_at"] = now

    proxmox_state["prov_run"] = run


def _guest_supports_reclone(vm: dict[str, Any]) -> bool:
    if vm.get("is_template"):
        return False
    if WEBUI_VMID is not None:
        try:
            if int(vm.get("vmid", -1)) == WEBUI_VMID:
                return False
        except (TypeError, ValueError):
            return False
    return bool(vm.get("reclone_supported"))



def _reclone_targets_for_run() -> list[dict[str, Any]]:
    return sorted(
        [
            dict(vm)
            for vm in proxmox_state.get("vms", [])
            if vm.get("vmid") is not None and _guest_supports_reclone(vm)
        ],
        key=lambda vm: int(vm.get("vmid", 0)),
    )



def _reclone_command_args(vm: dict[str, Any]) -> dict[str, Any]:
    args: dict[str, Any] = {
        "vmid": int(vm.get("vmid")),
        "type": str(vm.get("type") or "qemu"),
    }
    if vm.get("reclone_source_vmid") is not None:
        args["source_vmid"] = int(vm["reclone_source_vmid"])
    if vm.get("reclone_bus_path"):
        args["bus_path"] = str(vm["reclone_bus_path"])
    return args


async def _queue_command(target: str, action: str, args: dict[str, Any] | None = None, command_type: str | None = None) -> dict[str, Any]:
    async with state_lock:
        cmd, created, expired, purged = _enqueue_command_locked(target, action, args, command_type=command_type)
        serialized = _serialize_commands()
    if created or expired or purged:
        await broadcast({"type": "commands_update", "commands": serialized})
    return cmd


async def _queue_proxmox_command(action: str, args: dict[str, Any] | None = None, command_type: str | None = None) -> dict[str, Any]:
    return await _queue_command("proxmox", action, args, command_type=command_type)


def _proxmox_update_branch() -> str:
    branch = str(settings.get("repo_branch", REPO_BRANCH) or REPO_BRANCH).strip()
    return branch or REPO_BRANCH


def _proxmox_update_args() -> dict[str, str]:
    branch = _proxmox_update_branch()
    return {
        "branch": branch,
        "repo_raw": f"{CLIENT_SIM_REPO_RAW.rstrip('/')}/{branch}",
    }


def _resolve_proxmox_update_target() -> str:
    hostname = str((proxmox_state.get("node") or {}).get("hostname") or "").strip()
    resolved_hostname = _resolve_proxmox_agent_hostname(hostname, approved_proxmox_agents)
    if resolved_hostname:
        return resolved_hostname
    if len(approved_proxmox_agents) == 1:
        return next(iter(approved_proxmox_agents))
    if not approved_proxmox_agents:
        raise HTTPException(status_code=409, detail="No approved Proxmox agent is available")
    raise HTTPException(status_code=409, detail="Unable to determine which Proxmox host should be updated")


async def _queue_proxmox_agent_update(target: str | None = None) -> dict[str, Any]:
    resolved_target = target or _resolve_proxmox_update_target()
    if resolved_target not in approved_proxmox_agents:
        raise HTTPException(status_code=404, detail="Proxmox agent not approved")
    async with state_lock:
        expired, purged = _cleanup_commands_locked()
        cmd, created, _expired, _purged = _enqueue_command_locked(resolved_target, "update_agent", _proxmox_update_args())
        serialized = _serialize_commands()
    if not created:
        raise HTTPException(status_code=409, detail=f"An agent update is already queued for {resolved_target}")
    if expired or purged or created:
        await broadcast({"type": "commands_update", "commands": serialized})
    return cmd


async def _run_rolling_reclone(trigger_type: str) -> None:
    async with reclone_run_lock:
        if reclone_state["status"] == "running":
            return

        vms = _reclone_targets_for_run()
        reclone_state.update({
            "status": "running",
            "type": trigger_type,
            "total": len(vms),
            "completed": 0,
            "failed": 0,
            "current_vm": None,
            "log": [],
            "started_at": iso_utcnow(),
        })
        logger.info("Rolling reclone (%s): %d eligible VMs: %s", trigger_type, len(vms), [v.get("vmid") for v in vms])
        await _broadcast_reclone_state()
        await _broadcast_proxmox_state()

        concurrency = max(1, int(str(settings.get("reclone_concurrency", "1")).strip() or "1"))

        async def _reclone_one(vm: dict) -> None:
            vmid = int(vm.get("vmid"))
            name = vm.get("name") or f"VM {vmid}"
            _update_reclone_log(vmid, name, "queued")
            await _broadcast_reclone_state()
            await _broadcast_proxmox_state()

            cmd = await _queue_proxmox_command("reclone_vm", _reclone_command_args(vm), command_type=trigger_type)
            deadline = time.time() + 1800
            last_status = "pending"
            while time.time() < deadline:
                current = next((item for item in commands if item["id"] == cmd["id"]), None)
                if current is None:
                    break
                status = current.get("status", "pending")
                if status != last_status and status == "delivered":
                    _update_reclone_log(vmid, name, "in_progress")
                    await _broadcast_reclone_state()
                    await _broadcast_proxmox_state()
                last_status = status
                if status in {"completed", "failed", "expired"}:
                    final_status = "completed" if status == "completed" else "failed"
                    _update_reclone_log(vmid, name, final_status, str(current.get("message") or "").strip() or None)
                    if final_status == "completed":
                        _record_vm_watchdog_clone_completed(vmid, name)
                        _save_vm_watchdog()
                        reclone_state["completed"] += 1
                    else:
                        reclone_state["failed"] += 1
                    await _broadcast_reclone_state()
                    await _broadcast_proxmox_state()
                    return
                await asyncio.sleep(2)
            logger.warning("Rolling reclone: VM %s (%s) timed out", vmid, name)
            _update_reclone_log(vmid, name, "failed", "Timed out waiting for Proxmox agent ACK")
            reclone_state["failed"] += 1
            await _broadcast_reclone_state()
            await _broadcast_proxmox_state()

        try:
            for i in range(0, len(vms), concurrency):
                batch = vms[i:i + concurrency]
                reclone_state["current_vm"] = int(batch[0].get("vmid")) if batch else None
                await _broadcast_reclone_state()
                await asyncio.gather(*(_reclone_one(vm) for vm in batch))

            # After recloning existing VMs, trigger provisioning for any
            # unassigned dongles (present USB device with no VM allocated).
            unassigned = _proxmox_unassigned_present_usb()
            if unassigned:
                logger.info(
                    "Rolling reclone: found %d unassigned dongle(s) — queuing provision_unassigned",
                    len(unassigned),
                )
                await _queue_proxmox_command("provision_unassigned", {}, command_type=trigger_type)

            reclone_state["status"] = "failed" if reclone_state["failed"] else "completed"
        except Exception as exc:
            logger.exception("Rolling reclone failed: %s", exc)
            reclone_state["status"] = "failed"
            reclone_state["failed"] += 1
        finally:
            reclone_state["current_vm"] = None
            reclone_state["last_run"] = {
                "timestamp": iso_utcnow(),
                "completed": reclone_state["completed"],
                "failed": reclone_state["failed"],
                "type": trigger_type,
            }
            if reclone_state["status"] != "running":
                reclone_state["started_at"] = None
            await _broadcast_reclone_state()
            await _broadcast_proxmox_state()


async def auto_recovery_check() -> None:
    await asyncio.sleep(1800)
    while True:
        try:
            timeout_hours = _setting_int("vm_silent_timeout", 24, 1)
            now = time.time()
            triggered: list[int] = []
            for vm in list(proxmox_state.get("vms", [])):
                vmid = vm.get("vmid")
                if vmid is None:
                    continue
                if int(vmid) <= 9000 or vm.get("is_template"):
                    continue
                last_seen = _parse_ts(vm.get("last_seen"))
                if last_seen is None or (now - last_seen) <= timeout_hours * 3600:
                    continue
                vmid_int = int(vmid)
                if _has_pending_reclone(vmid_int):
                    continue
                await _queue_proxmox_command("reclone_vm", {"vmid": vmid_int}, command_type="auto-recovery")
                triggered.append(vmid_int)
            if triggered:
                vmid_list = ", ".join(str(v) for v in triggered)
                for vmid_int in triggered:
                    name = next(
                        (vm.get("name") or f"VM {vmid_int}" for vm in proxmox_state.get("vms", []) if int(vm.get("vmid", -1)) == vmid_int),
                        f"VM {vmid_int}",
                    )
                    reclone_state["auto_recovery_log"].append({
                        "vmid": vmid_int,
                        "name": name,
                        "status": "queued",
                        "timestamp": iso_utcnow(),
                    })
                reclone_state["auto_recovery_log"] = reclone_state["auto_recovery_log"][-50:]
                _save_reclone_state()
                await broadcast({
                    "type": "notification",
                    "level": "warning",
                    "message": f"Auto-recovery: queued reclone for {len(triggered)} silent VM(s) — {vmid_list}",
                })
                await _broadcast_proxmox_state()
            _update_service_health("auto_recovery", ok=True)
        except asyncio.CancelledError:
            raise
        except Exception as exc:
            _update_service_health("auto_recovery", ok=False, error=str(exc))
            logger.exception("Auto recovery check error: %s", exc)
        await asyncio.sleep(1800)




async def vm_watchdog_loop() -> None:
    await asyncio.sleep(VM_WATCHDOG_INTERVAL_SECS)
    while True:
        try:
            now = time.time()
            client_seen = {hostname: client.get("last_seen") for hostname, client in clients.items()}
            vm_names = {
                str(int(vm.get("vmid"))): str(vm.get("name") or "").strip()
                for vm in proxmox_state.get("vms", [])
                if vm.get("vmid") is not None
            }
            changed = False
            broadcast_needed = False
            for vmid_key, entry in list(vm_watchdog.items()):
                clone_completed_at = _parse_ts(entry.get("clone_completed_at"))
                if clone_completed_at is None:
                    vm_watchdog.pop(vmid_key, None)
                    changed = True
                    broadcast_needed = True
                    continue
                hostname = str(entry.get("hostname") or vm_names.get(vmid_key) or "").strip()
                if hostname and hostname != entry.get("hostname"):
                    entry["hostname"] = hostname
                    changed = True
                if _vm_has_checked_in(hostname, clone_completed_at, client_seen):
                    vm_watchdog.pop(vmid_key, None)
                    changed = True
                    broadcast_needed = True
                    continue
                if (now - clone_completed_at) <= VM_WATCHDOG_TIMEOUT_SECS:
                    continue
                vmid_int = int(vmid_key)
                if _has_pending_reclone(vmid_int):
                    continue
                vm = _find_proxmox_vm(vmid_int) or {"vmid": vmid_int}
                await _queue_proxmox_command("reclone_vm", _reclone_command_args(vm), command_type="watchdog")
                reclone_count = max(0, int(entry.get("reclone_count", 0) or 0)) + 1
                _record_vm_watchdog_clone_completed(
                    vmid_int,
                    hostname or vm.get("name"),
                    clone_completed_at=now,
                    reclone_count=reclone_count,
                )
                changed = True
                broadcast_needed = True
                logger.warning("VM watchdog queued reclone for VM %s (%s) after 24h without check-in", vmid_int, hostname or vm.get("name") or f"VM {vmid_int}")
            if changed:
                _save_vm_watchdog()
            if broadcast_needed:
                await _broadcast_proxmox_state()
            _update_service_health("vm_watchdog", ok=True)
        except asyncio.CancelledError:
            raise
        except Exception as exc:
            _update_service_health("vm_watchdog", ok=False, error=str(exc))
            logger.exception("VM watchdog error: %s", exc)
        await asyncio.sleep(VM_WATCHDOG_INTERVAL_SECS)


async def schedule_check() -> None:
    global last_schedule_trigger
    day_names = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]
    await asyncio.sleep(60)
    while True:
        try:
            if _normalize_toggle(settings.get("reclone_schedule_enabled", "off")) == "on" and reclone_state.get("status") != "running":
                parsed = _parse_reclone_schedule(settings.get("reclone_schedule_cron", "sunday 02:00"))
                if parsed:
                    day, hour, minute = parsed
                    now = datetime.now()
                    if day_names[now.weekday()] == day and now.hour == hour and now.minute == minute:
                        trigger_key = now.strftime("%Y-%m-%d %H:%M")
                        if last_schedule_trigger != trigger_key:
                            last_schedule_trigger = trigger_key
                            asyncio.create_task(_run_rolling_reclone("scheduled"))
            _update_service_health("schedule_check", ok=True)
        except asyncio.CancelledError:
            raise
        except Exception as exc:
            _update_service_health("schedule_check", ok=False, error=str(exc))
            logger.exception("Schedule check error: %s", exc)
        await asyncio.sleep(60)




async def gkill_switch_poller() -> None:
    """Fetch the global kill switch from solutions-hpe/main every 5 minutes.
    Serves as the authoritative value for /api/kill-switch — never relies on
    a local file so a forked repo cannot override it."""
    async with httpx.AsyncClient(timeout=10) as client:
        while True:
            try:
                resp = await client.get(GKILL_SWITCH_URL)
                value = resp.text.strip().lower()
                if value not in ("on", "off"):
                    value = "off"
                prev = gkill_switch_state["value"]
                gkill_switch_state["value"] = value
                gkill_switch_state["last_fetched"] = time.time()
                gkill_switch_state["error"] = None
                if value != prev:
                    logger.warning("Global kill switch changed: %s → %s", prev, value)
                    await broadcast({"type": "gkill_switch_update", "value": value})
                _update_service_health("gkill_switch", ok=True)
            except asyncio.CancelledError:
                raise
            except Exception as exc:
                gkill_switch_state["error"] = str(exc)
                _update_service_health("gkill_switch", ok=False, error=str(exc))
                logger.warning("gkill_switch fetch failed: %s", exc)
            await asyncio.sleep(300)




async def expire_commands() -> None:
    """Expire stale active commands and purge terminal results after a short grace period."""
    await asyncio.sleep(15)
    while True:
        try:
            async with state_lock:
                expired, purged = _cleanup_commands_locked()
                serialized = _serialize_commands()
            if expired:
                logger.warning("Expired %d stale command(s) from the in-memory queue", expired)
                await broadcast({"type": "commands_update", "commands": serialized})
                await broadcast({"type": "notification", "level": "warning", "message": "One or more commands expired without being ACKed by the agent."})
            elif purged:
                await broadcast({"type": "commands_update", "commands": serialized})
            _update_service_health("command_expiry", ok=True)
        except asyncio.CancelledError:
            raise
        except Exception as exc:
            _update_service_health("command_expiry", ok=False, error=str(exc))
            logger.exception("Command expiry error: %s", exc)
        await asyncio.sleep(15)




async def broadcast(message: dict[str, Any]) -> None:
    if not ws_connections:
        return

    payload = json.dumps(message, default=str)
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


def _relay_status_payload() -> dict[str, Any]:
    return dict(relay_state)


async def _broadcast_relay_state() -> None:
    _save_relay_state()
    await broadcast({"type": "relay_status", **_relay_status_payload()})


async def _broadcast_update_state() -> None:
    _save_update_state()
    await broadcast({"type": "version_status", **dict(update_state)})


def _build_registration_config() -> dict[str, Any]:
    """Build the seed config payload sent to hub on first registration."""
    return {
        "repo_branch": settings.get("repo_branch") or REPO_BRANCH,
        "repo_url": REPO_URL,
        "site_mappings": settings.get("site_mappings", {}),
        "monitored_checks": settings.get("monitored_checks", []),
        "hardware_checks": settings.get("hardware_checks", []),
        "reclone_schedule_enabled": settings.get("reclone_schedule_enabled", "off"),
        "reclone_schedule_cron": settings.get("reclone_schedule_cron", "sunday 02:00"),
        "reclone_concurrency": settings.get("reclone_concurrency", "1"),
        "vm_image_1_template_id": settings.get("vm_image_1_template_id", "100"),
        "vm_image_2_template_id": settings.get("vm_image_2_template_id", "200"),
        "vm_image_1_pct": settings.get("vm_image_1_pct", "50"),
        "usb_auto_provision": settings.get("usb_auto_provision", "off"),
        "usb_vidpids": settings.get("usb_vidpids", "[]"),
        "usb_missing_timeout": settings.get("usb_missing_timeout", "60"),
        "vm_silent_timeout": settings.get("vm_silent_timeout", "24"),
        "ignored_hostnames": settings.get("ignored_hostnames", '["sim-rpi-0000"]'),
        "l1_vlan_start": settings.get("l1_vlan_start", "100"),
        "l1_vlan_end": settings.get("l1_vlan_end", "199"),
    }


async def _hub_self_register(server_url: str) -> None:
    """POST to hub /api/spokes/register with full config payload.
    Stores the returned spoke_id. If already approved, also stores api_key and tenant_id."""
    global relay_registration_refresh_needed
    hostname = socket.gethostname()
    spoke_name = settings.get("relay_spoke_name", "").strip() or hostname
    spoke_id = _ensure_relay_spoke_id()
    payload = {
        "spoke_id": spoke_id,
        "hostname": hostname,
        "label": hostname,
        "spoke_name": spoke_name,
        "tenant_id_hint": (settings.get("relay_tenant_id") or settings.get("relay_tenant_hint") or "").strip(),
        "config": _build_registration_config(),
    }
    _relay_diag_append("register_attempt", url=f"{server_url}/api/spokes/register",
                       hostname=hostname, spoke_name=spoke_name, spoke_id=spoke_id)
    try:
        async with httpx.AsyncClient(timeout=15, verify=False) as hc:
            resp = await hc.post(f"{server_url}/api/spokes/register", json=payload)
            if resp.status_code == 409:
                data = resp.json()
                conflict = data.get("conflict", "name_in_use")
                msg = data.get("message", f"Spoke name '{spoke_name}' is already in use on the hub. Choose a different name.")
                ts = datetime.now().strftime("%Y-%m-%d %H:%M")
                relay_state.update({
                    "connected": False,
                    "registration_status": "name_conflict",
                    "error": f"{ts} — {msg}",
                })
                relay_registration_refresh_needed = False
                _save_relay_state()
                _relay_diag_append("register_409", conflict=conflict, message=msg)
                logger.warning("Hub registration name conflict: %s", msg)
                return
            resp.raise_for_status()
            data = resp.json()
        spoke_id = str(data.get("spoke_id", "")).strip()
        status = data.get("status", "pending")
        if spoke_id and not _relay_spoke_id_needs_rotation(spoke_id):
            settings["relay_spoke_id"] = spoke_id
        else:
            spoke_id = _ensure_relay_spoke_id()
        if status == "approved":
            tenant_id = data.get("tenant_id", "")
            settings["relay_api_key"] = data.get("api_key", "")
            settings["relay_tenant_id"] = tenant_id
            settings["relay_tenant_hint"] = tenant_id
            relay_state["registration_status"] = "approved"
            relay_state["error"] = ""
            _relay_diag_append("register_ok", status="approved", spoke_id=spoke_id,
                               tenant_id=data.get("tenant_id"))
            logger.info("Hub registration: approved immediately spoke_id=%s tenant_id=%s", spoke_id, data.get("tenant_id"))
        else:
            tenant_hint = str(data.get("tenant_hint", "")).strip()
            settings["relay_api_key"] = ""
            settings["relay_tenant_id"] = ""
            if tenant_hint:
                settings["relay_tenant_hint"] = tenant_hint
            relay_state["registration_status"] = "pending"
            relay_state["error"] = ""
            _relay_diag_append("register_ok", status="pending", spoke_id=spoke_id)
            logger.info("Hub registration submitted: spoke_id=%s status=pending", spoke_id)
        relay_registration_refresh_needed = False
        _save_relay_state()
        _save_settings()
    except Exception as exc:
        relay_registration_refresh_needed = True
        _relay_diag_append("register_error", error=str(exc))
        logger.warning("Hub self-register failed: %s", exc)
        relay_state.update({"connected": False, "error": f"Registration failed: {exc}"})
        _save_relay_state()


async def _hub_check_approval(server_url: str, spoke_id: str) -> None:
    """Re-POST registration to check if spoke has been approved.
    Hub returns 'approved' with api_key and tenant_id once superadmin has approved."""
    global relay_registration_refresh_needed
    hostname = socket.gethostname()
    spoke_name = settings.get("relay_spoke_name", "").strip() or hostname
    tenant_hint = (settings.get("relay_tenant_id") or settings.get("relay_tenant_hint") or "").strip()
    _relay_diag_append("check_approval", spoke_id=spoke_id)
    try:
        async with httpx.AsyncClient(timeout=10, verify=False) as hc:
            resp = await hc.post(f"{server_url}/api/spokes/register", json={
                "spoke_id": spoke_id,
                "hostname": hostname,
                "label": hostname,
                "spoke_name": spoke_name,
                "tenant_id_hint": tenant_hint,
                "config": _build_registration_config(),
            })
            resp.raise_for_status()
            data = resp.json()
        status = data.get("status", "pending")
        updated = False
        returned_spoke_id = str(data.get("spoke_id", "")).strip()
        if returned_spoke_id and not _relay_spoke_id_needs_rotation(returned_spoke_id) and returned_spoke_id != settings.get("relay_spoke_id", ""):
            settings["relay_spoke_id"] = returned_spoke_id
            spoke_id = returned_spoke_id
            updated = True
        if status == "approved":
            tenant_id = data.get("tenant_id", "")
            settings["relay_api_key"] = data.get("api_key", "")
            settings["relay_tenant_id"] = tenant_id
            settings["relay_tenant_hint"] = tenant_id
            relay_state["registration_status"] = "approved"
            updated = True
            _relay_diag_append("approval_received", spoke_id=spoke_id,
                               tenant_id=data.get("tenant_id"))
            logger.info("Hub approval received: spoke_id=%s tenant_id=%s", spoke_id, data.get("tenant_id"))
        else:
            tenant_hint = str(data.get("tenant_hint", "")).strip()
            if settings.get("relay_api_key"):
                settings["relay_api_key"] = ""
                updated = True
            if settings.get("relay_tenant_id"):
                settings["relay_tenant_id"] = ""
                updated = True
            if tenant_hint and tenant_hint != settings.get("relay_tenant_hint", ""):
                settings["relay_tenant_hint"] = tenant_hint
                updated = True
            relay_state["registration_status"] = "pending"
            relay_state["error"] = ""
            _relay_diag_append("still_pending", spoke_id=spoke_id)
            logger.info("Hub registration still pending: spoke_id=%s", spoke_id)
        relay_registration_refresh_needed = False
        _save_relay_state()
        if updated:
            _save_settings()
    except Exception as exc:
        relay_registration_refresh_needed = True
        _relay_diag_append("check_approval_error", error=str(exc))
        logger.warning("Hub approval check failed: %s", exc)


def _relay_hub_base_url(server_url: str, tenant_id: str) -> str:
    url = server_url.rstrip("/")
    if tenant_id:
        url = re.sub(rf"/api/{re.escape(tenant_id)}$", "", url)
    return url.rstrip("/")


async def _apply_hub_config(payload: dict[str, Any]) -> dict[str, Any]:
    """Apply a config_update command payload pushed from hub.
    Returns an ack result dict."""
    global relay_registration_refresh_needed
    changed: list[str] = []
    relay_config_changed = False

    if "relay_server_url" in payload:
        settings["relay_server_url"] = payload["relay_server_url"].strip()
        relay_config_changed = True
        changed.append("relay_server_url")
    if "relay_api_key" in payload:
        settings["relay_api_key"] = payload["relay_api_key"].strip()
        relay_config_changed = True
        changed.append("relay_api_key")
    if "relay_tenant_id" in payload:
        tenant_id = payload["relay_tenant_id"].strip()
        settings["relay_tenant_id"] = tenant_id
        settings["relay_tenant_hint"] = tenant_id
        relay_config_changed = True
        changed.append("relay_tenant_id")
    if "relay_spoke_id" in payload:
        settings["relay_spoke_id"] = payload["relay_spoke_id"].strip()
        relay_config_changed = True
        changed.append("relay_spoke_id")

    for key in (
        "repo_branch", "reclone_schedule_enabled", "reclone_schedule_cron",
        "reclone_concurrency", "vm_silent_timeout", "usb_auto_provision",
        "ignored_hostnames", "l1_vlan_start", "l1_vlan_end",
        "vm_image_1_template_id", "vm_image_2_template_id", "vm_image_1_pct",
    ):
        if key in payload:
            settings[key] = payload[key]
            changed.append(key)

    if relay_config_changed:
        relay_state.update({
            "enabled": settings.get("relay_enabled") == "on" and bool(settings.get("relay_server_url")),
            "connected": False,
            "error": None,
            "registration_status": _relay_registration_status_from_settings(),
        })
        relay_registration_refresh_needed = False
        _save_relay_state()
    _save_settings()
    await broadcast({"type": "settings_update", "settings": await api_settings_get()})
    logger.info("Applied hub config_update: %s", changed)
    return {
        "success": True,
        "task_type": "config_update",
        "detail": f"Applied: {', '.join(changed) if changed else 'no changes'}",
        "timestamp": datetime.now(timezone.utc).isoformat(),
    }


async def relay_sync_once() -> None:
    """One relay cycle: register if needed, check approval if pending,
    then post telemetry, fetch inbox, process commands, and ack each."""
    global relay_registration_refresh_needed
    if settings.get("relay_enabled") != "on" or not settings.get("relay_server_url"):
        relay_state["enabled"] = False
        _save_relay_state()
        return

    if not _HTTPX_AVAILABLE or httpx is None:
        relay_state.update({"enabled": True, "connected": False, "error": "httpx not installed"})
        await _broadcast_relay_state()
        return

    relay_state["enabled"] = True
    server_url = settings["relay_server_url"].rstrip("/")
    spoke_id = _ensure_relay_spoke_id()
    api_key = settings.get("relay_api_key", "")
    tenant_id = settings.get("relay_tenant_id", "")

    # ── Phase 1: Register if no spoke_id yet ──────────────────────────────────
    if not spoke_id:
        await _hub_self_register(server_url)
        await _broadcast_relay_state()
        return

    if relay_registration_refresh_needed:
        await _hub_check_approval(server_url, spoke_id)
        spoke_id = settings.get("relay_spoke_id", spoke_id)
        api_key = settings.get("relay_api_key", "")
        tenant_id = settings.get("relay_tenant_id", "")

    # ── Phase 2: Pending approval — poll hub for approval ──────────────────────
    if not api_key or not tenant_id:
        relay_state["registration_status"] = relay_state.get("registration_status", "pending")
        await _hub_check_approval(server_url, spoke_id)
        spoke_id = settings.get("relay_spoke_id", spoke_id)
        api_key = settings.get("relay_api_key", "")
        tenant_id = settings.get("relay_tenant_id", "")
        if not api_key or not tenant_id:
            await _broadcast_relay_state()
            return

    # ── Phase 3: Approved — full relay cycle ───────────────────────────────────
    relay_state["registration_status"] = "approved"
    headers = {"X-API-Key": api_key}
    hub_base = _relay_hub_base_url(server_url, tenant_id)
    base = f"{hub_base}/api/{tenant_id}/spokes/{spoke_id}"

    try:
        async with state_lock:
            proxmox_vms = list(proxmox_state.get("vms", []))
            usb_state = list(proxmox_state.get("usb_state", []))
            unknown_usb = list(proxmox_state.get("unknown_usb", []))
            clients_snapshot = [serialize_client(hostname, clients[hostname]) for hostname in sorted(clients)]
            telemetry = {
                "spoke_id": spoke_id,
                "spoke_name": settings.get("relay_spoke_name", "").strip() or socket.gethostname(),
                "hostname": socket.gethostname(),
                "clients": clients_snapshot,
                "timestamp": time.time(),
                "proxmox": {
                    "connected": bool(proxmox_state.get("connected", False)),
                    "last_seen": proxmox_state.get("last_seen"),
                    "node": dict(proxmox_state.get("node") or {}),
                    "vm_count": len(proxmox_vms),
                    "running_count": sum(1 for vm in proxmox_vms if vm.get("status") == "running"),
                    "vms": [
                        {
                            "vmid": vm.get("vmid"),
                            "name": vm.get("name", ""),
                            "status": vm.get("status", ""),
                            "type": vm.get("type", ""),
                        }
                        for vm in proxmox_vms
                    ],
                    "usb_state": usb_state,
                    "unknown_usb": unknown_usb,
                    "usb_count": len(usb_state),
                    "agent_version": proxmox_state.get("agent_version"),
                    "pve_version": proxmox_state.get("pve_version"),
                },
                "proxmox_vms": proxmox_vms,
                "usb_devices": usb_state,
                "api_server": {
                    "health": {
                        "status": "ok",
                        "version": APP_VERSION,
                        "clients": len(clients_snapshot),
                        "repo_synced": repo_state["synced"],
                        "repo_error": repo_state["error"],
                        "installer_version": INSTALLER_VERSION,
                    },
                    "services": {name: dict(info) for name, info in service_health.items()},
                    "task_names": list(background_tasks.keys()),
                },
                "central": {
                    "status": _central_status_payload(),
                    "wireless_clients": dict(central_wireless_clients),
                    "hardware_alerts": _hw_alerts_payload(),
                    "client_count_status": _client_count_payload(),
                    "token_valid": bool(central_token.get("access_token") and time.time() < central_token.get("expires_at", 0)),
                    "token_state": _central_token_state(),
                },
            }

        async with httpx.AsyncClient(timeout=10, verify=False) as hc:
            telemetry_resp = await hc.post(f"{base}/telemetry", json=telemetry, headers=headers)
            telemetry_resp.raise_for_status()
            resp = await hc.get(f"{base}/inbox", headers=headers)
            resp.raise_for_status()
            remote_cmds = resp.json()

        if not isinstance(remote_cmds, list):
            remote_cmds = []

        async with state_lock:
            for rc in remote_cmds:
                cmd_id = rc.get("id", "")
                cmd_type = rc.get("type", "")
                payload_data = rc.get("payload", {})
                target = rc.get("target", "")
                action = rc.get("action", "")
                args = rc.get("args", {})

                # ── config_update: apply hub-pushed config and ack ─────────────
                if cmd_type == "config_update":
                    result = await _apply_hub_config(payload_data)
                    if cmd_id:
                        async with httpx.AsyncClient(timeout=10, verify=False) as hc_ack:
                            ack_resp = await hc_ack.post(f"{base}/ack", json={
                                "command_id": cmd_id,
                                "status": "executed",
                                "result": result,
                            }, headers=headers)
                            ack_resp.raise_for_status()
                    continue

                # ── gkill_switch: update local gkill state ─────────────────────
                if cmd_type == "gkill_switch":
                    new_val = (payload_data.get("value") or action or "").strip()
                    if new_val in ("on", "off"):
                        gkill_switch_state["value"] = new_val
                        await broadcast({"type": "gkill_switch", "value": new_val})
                        logger.info("gkill_switch set to %s by hub", new_val)
                    if cmd_id:
                        async with httpx.AsyncClient(timeout=10, verify=False) as hc_ack:
                            ack_resp = await hc_ack.post(f"{base}/ack", json={
                                "command_id": cmd_id,
                                "status": "executed",
                                "result": {
                                    "success": True,
                                    "task_type": "gkill_switch",
                                    "detail": f"gkill set to {gkill_switch_state['value']}",
                                    "timestamp": datetime.now(timezone.utc).isoformat(),
                                },
                            }, headers=headers)
                            ack_resp.raise_for_status()
                    continue

                # ── regular client/proxmox commands ────────────────────────────
                if not target or not action:
                    continue
                if target == "all":
                    for hostname in list(clients.keys()):
                        _enqueue_command_locked(hostname, action, args, command_type=cmd_type)
                else:
                    _enqueue_command_locked(target, action, args, command_type=cmd_type)

                # Ack each queued command
                if cmd_id:
                    async with httpx.AsyncClient(timeout=10, verify=False) as hc_ack:
                        ack_resp = await hc_ack.post(f"{base}/ack", json={
                            "command_id": cmd_id,
                            "status": "queued",
                        }, headers=headers)
                        ack_resp.raise_for_status()

        if remote_cmds:
            await broadcast({"type": "commands_update", "commands": _serialize_commands()})

        relay_state.update({"connected": True, "last_sync": time.time(), "error": None})
    except httpx.HTTPStatusError as exc:
        status_code = exc.response.status_code if exc.response else None
        if status_code in (401, 403, 404):
            relay_registration_refresh_needed = True
            settings["relay_api_key"] = ""
            settings["relay_tenant_id"] = ""
            relay_state.update({
                "connected": False,
                "registration_status": "pending",
                "error": f"Hub returned {status_code}; refreshing registration",
            })
            _relay_diag_append(
                "relay_reauth_required",
                status_code=status_code,
                method=exc.request.method if exc.request else "",
                url=str(exc.request.url) if exc.request else "",
            )
            _save_settings()
            await _hub_check_approval(server_url, spoke_id)
        else:
            relay_state.update({"connected": False, "error": str(exc)})
        logger.warning("Relay sync failed: %s", exc)
    except Exception as exc:
        relay_state.update({"connected": False, "error": str(exc)})
        logger.warning("Relay sync failed: %s", exc)

    await _broadcast_relay_state()


async def relay_loop() -> None:
    while True:
        interval = int(settings.get("relay_poll_interval", RELAY_INTERVAL_DEFAULT))
        try:
            await relay_sync_once()
            _update_service_health("relay", ok=True)
        except asyncio.CancelledError:
            raise
        except Exception as exc:
            _update_service_health("relay", ok=False, error=str(exc))
            logger.exception("Relay loop error: %s", exc)
        await asyncio.sleep(interval)




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


def _push_to_github(files_changed: list[str], commit_message: str) -> bool:
    token = settings.get("github_token", "").strip()
    if not token:
        raise ValueError("GitHub token not configured")

    if not (REPO_DIR / ".git").exists():
        raise RuntimeError(f"{REPO_DIR} exists but is not a git repository")

    # Ensure git identity is set (required for commit)
    try:
        _git("config", "user.name")
    except RuntimeError:
        _git("config", "user.name", "Client Simulator")
    try:
        _git("config", "user.email")
    except RuntimeError:
        _git("config", "user.email", "client-sim@localhost")

    authed_url = REPO_URL.replace("https://", f"https://{token}@", 1)
    _git("remote", "set-url", "origin", authed_url)
    try:
        _git("add", *files_changed)
        # Check if there is anything staged
        status = subprocess.run(
            ["git", "diff", "--cached", "--quiet"],
            cwd=REPO_DIR
        )
        if status.returncode == 0:
            return False  # nothing staged
        _git("commit", "-m", commit_message)
        _git("push")
        return True
    finally:
        _git("remote", "set-url", "origin", REPO_URL)


def _update_ini_section(filepath: Path, section: str, updates: dict[str, str]) -> None:
    text = filepath.read_text(encoding="utf-8") if filepath.exists() else ""
    newline = "\r\n" if "\r\n" in text else "\n"
    lines = text.splitlines()
    normalized_updates = {str(key).strip(): str(value) for key, value in updates.items() if str(key).strip()}

    updated_lines: list[str] = []
    found_keys: set[str] = set()
    section_found = False
    in_target_section = False

    def append_missing_keys() -> None:
        for key, value in normalized_updates.items():
            if key not in found_keys:
                updated_lines.append(f"{key}={value}")

    for line in lines:
        match = re.match(r"^\s*\[(?P<section>[^\]]+)\]\s*$", line)
        if match:
            if in_target_section:
                append_missing_keys()
            current_section = match.group("section")
            in_target_section = current_section == section
            section_found = section_found or in_target_section
            updated_lines.append(line)
            continue

        if in_target_section:
            key_match = re.match(r"^(?P<indent>\s*)(?P<key>[^=\s#;][^=]*?)\s*=.*$", line)
            if key_match:
                key = key_match.group("key").strip()
                if key in normalized_updates:
                    updated_lines.append(f"{key_match.group('indent')}{key}={normalized_updates[key]}")
                    found_keys.add(key)
                    continue

        updated_lines.append(line)

    if in_target_section:
        append_missing_keys()

    if not section_found:
        if updated_lines and updated_lines[-1].strip():
            updated_lines.append("")
        updated_lines.append(f"[{section}]")
        append_missing_keys()

    output = newline.join(updated_lines)
    if updated_lines and (text.endswith("\n") or not text):
        output += newline
    filepath.write_text(output, encoding="utf-8")


def _git(*args: str, cwd: Path | None = None, timeout: int = 120) -> str:
    """Run a git command, raise RuntimeError on failure.

    timeout (default 120 s) prevents git clone/fetch from hanging indefinitely
    when the network is slow or GitHub is temporarily unresponsive.
    GIT_TERMINAL_PROMPT=0 ensures git never blocks waiting for credentials —
    public repos work without a token; private repos fail fast with a clear error.
    """
    git_env = {
        **os.environ,
        "GIT_TERMINAL_PROMPT": "0",
        "GIT_ASKPASS": "/bin/echo",
    }
    try:
        result = subprocess.run(
            ["git", *args],
            cwd=cwd or REPO_DIR,
            capture_output=True,
            text=True,
            timeout=timeout,
            env=git_env,
        )
    except subprocess.TimeoutExpired:
        raise RuntimeError(f"git {' '.join(args)} timed out after {timeout}s")
    if result.returncode != 0:
        raise RuntimeError(f"git {' '.join(args)} failed: {result.stderr.strip()}")
    return result.stdout.strip()


def sync_repo_once() -> None:
    branch = str(settings.get("repo_branch") or REPO_BRANCH).strip()
    REPO_DIR.parent.mkdir(parents=True, exist_ok=True)

    if not REPO_DIR.exists() or not any(REPO_DIR.iterdir()):
        logger.info("Cloning %s (%s) into %s", REPO_URL, branch, REPO_DIR)
        _git("clone", "--branch", branch, "--single-branch", REPO_URL, str(REPO_DIR),
             cwd=REPO_DIR.parent, timeout=300)
        return

    if not (REPO_DIR / ".git").exists():
        raise RuntimeError(f"{REPO_DIR} exists but is not a git repository")

    logger.info("Pulling latest repo state from %s branch %s", REPO_URL, branch)
    _git("remote", "set-url", "origin", REPO_URL)  # ensure no stale authed URL
    _git("fetch", "--prune", "origin")
    _git("checkout", branch)
    _git("reset", "--hard", f"origin/{branch}")


async def sync_repo() -> None:
    while True:
        try:
            async with _git_lock:
                await asyncio.to_thread(sync_repo_once)
            repo_state["synced"] = True
            repo_state["error"] = None
            repo_state["last_sync"] = time.time()
            repo_version = await asyncio.to_thread(_get_repo_version)
            _update_service_health("sync_repo", ok=True)
            await broadcast({"type": "repo_status", "synced": True, "error": None, "last_sync": repo_state["last_sync"], "repo_version": repo_version})
        except asyncio.CancelledError:
            raise
        except Exception as exc:
            repo_state["error"] = str(exc)
            _update_service_health("sync_repo", ok=False, error=str(exc))
            logger.exception("Repository sync failed")
            await broadcast({"type": "repo_status", "synced": repo_state["synced"], "error": str(exc), "last_sync": repo_state["last_sync"]})
        await asyncio.sleep(settings.get("repo_sync_interval", SYNC_INTERVAL))




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


def _cs_webui_branch() -> str:
    branch = str(settings.get("repo_branch", REPO_BRANCH) or REPO_BRANCH).strip()
    return branch or REPO_BRANCH


async def refresh_webui_frontend() -> None:
    """On startup: compare the deployed cs-webui VERSION to the repo and
    download fresh frontend files (app.js, style.css, index.html) if stale.

    This self-heals spoke installs that were created before a cs-webui fix
    was committed — e.g. a broken app.js with a SyntaxError would cause all
    JavaScript to fail, breaking the entire UI.  Running the full installer
    is not required; we only need to swap the three static files."""
    branch = _cs_webui_branch()
    raw_base = f"{CS_WEBUI_REPO_RAW}/{branch}"

    # Read deployed version
    local_ver: str | None = None
    try:
        local_ver = (STATIC_DIR / "VERSION").read_text(encoding="utf-8").strip()
    except Exception:
        pass

    # Fetch remote version (lightweight — just a few bytes)
    remote_ver: str | None = None
    try:
        import urllib.request as _urllib_req
        with _urllib_req.urlopen(f"{raw_base}/VERSION", timeout=10) as resp:
            remote_ver = resp.read().decode(errors="replace").strip()
    except Exception as exc:
        logger.warning("webui refresh: could not fetch remote VERSION: %s", exc)
        return

    if remote_ver == local_ver:
        logger.info("webui refresh: deployed cs-webui %s is current — no update needed", local_ver)
        return

    logger.info("webui refresh: deployed=%s  remote=%s — downloading updated files", local_ver, remote_ver)

    # Download app.js and style.css
    for rel_path in ("static/app.js", "static/style.css"):
        url = f"{raw_base}/{rel_path}"
        dest = STATIC_DIR / Path(rel_path).name
        try:
            with _urllib_req.urlopen(url, timeout=30) as resp:
                dest.write_bytes(resp.read())
            logger.info("webui refresh: updated %s", dest.name)
        except Exception as exc:
            logger.error("webui refresh: failed to download %s: %s", rel_path, exc)
            return  # abort — partial update is worse than stale

    # Download index.html template and inject WEBUI_MODE=spoke
    try:
        with _urllib_req.urlopen(f"{raw_base}/templates/index.html", timeout=30) as resp:
            html = resp.read().decode(errors="replace")
        html = html.replace("{{WEBUI_MODE}}", "spoke")
        (STATIC_DIR / "index.html").write_text(html, encoding="utf-8")
        logger.info("webui refresh: updated index.html (WEBUI_MODE=spoke injected)")
    except Exception as exc:
        logger.error("webui refresh: failed to download index.html: %s", exc)
        return

    # Write updated VERSION so next restart is a no-op
    try:
        (STATIC_DIR / "VERSION").write_text(remote_ver + "\n", encoding="utf-8")
    except Exception:
        pass

    logger.info("webui refresh: cs-webui updated %s → %s — browser reload required", local_ver, remote_ver)


async def check_for_update() -> None:
    """Background task: check for a new installer version every 24 hours.
    Only detects and broadcasts — never auto-applies. Updates are applied
    explicitly via /api/self-update or /api/update-all."""
    while True:
        try:
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
            _update_service_health("update_checker", ok=True)
            await _broadcast_update_state()
        except asyncio.CancelledError:
            raise
        except Exception as exc:
            _update_service_health("update_checker", ok=False, error=str(exc))
            logger.exception("Update checker error: %s", exc)
        await asyncio.sleep(UPDATE_CHECK_INTERVAL)




async def _run_update_all() -> None:
    """Queue the shared Proxmox update command, wait for its ACK, then self-update the WebUI."""
    global update_all_state

    approved = list(approved_proxmox_agents.keys())
    agent_cmd_ids: list[str] = []

    # ── Phase 1: Agent update ────────────────────────────────────────────────
    try:
        async with state_lock:
            update_args = _proxmox_update_args()
            for hostname in approved:
                cmd, _created, _expired, _purged = _enqueue_command_locked(hostname, "update_agent", dict(update_args))
                agent_cmd_ids.append(cmd["id"])

        update_all_state.update({
            "running": True,
            "phase": "agents" if agent_cmd_ids else "webui",
            "total_agents": len(agent_cmd_ids),
            "completed_agents": 0,
            "failed_agents": 0,
            "agent_cmds": agent_cmd_ids,
            "started_at": time.time(),
            "error": None,
        })
        await broadcast({"type": "update_all_progress", **update_all_state})
        await broadcast({"type": "commands_update", "commands": _serialize_commands()})

        if agent_cmd_ids:
            deadline = time.time() + 300
            while time.time() < deadline:
                await asyncio.sleep(5)
                async with state_lock:
                    command_statuses = {
                        c["id"]: c["status"]
                        for c in commands
                        if c["id"] in agent_cmd_ids
                    }
                done = sum(1 for status in command_statuses.values() if status in ("completed", "failed"))
                failed = sum(1 for status in command_statuses.values() if status == "failed")
                update_all_state["completed_agents"] = done
                update_all_state["failed_agents"] = failed
                await broadcast({"type": "update_all_progress", **update_all_state})
                if done >= len(agent_cmd_ids):
                    break
            else:
                logger.warning(
                    "Update All: agent ACK timed out after 300s — proceeding to WebUI update anyway"
                )

        if len(approved) == 0:
            logger.info("Update All: no approved agents, proceeding directly to WebUI update")
        else:
            logger.info(
                "Update All: agents done (%d/%d failed), proceeding to WebUI update",
                update_all_state["completed_agents"],
                update_all_state["failed_agents"],
            )
    except Exception as exc:
        logger.error("Update All: agent phase error (continuing to WebUI update): %s", exc)
        update_all_state["error"] = str(exc)

    # ── Phase 2: WebUI self-update ───────────────────────────────────────────
    try:
        update_all_state["phase"] = "webui"
        update_all_state["error"] = None
        await broadcast({"type": "update_all_progress", **update_all_state})

        # Sync the local repo cache before running the installer so it gets
        # the freshest content from GitHub (same as the /api/self-update path).
        try:
            async with _git_lock:
                await asyncio.to_thread(sync_repo_once)
            logger.info("Update All: repo synced before installer")
        except Exception as sync_exc:
            logger.warning("Update All: repo sync failed (%s) — installer will retry git fetch", sync_exc)

        await _run_self_update()
        if update_state.get("update_error"):
            update_all_state["phase"] = "failed"
            update_all_state["error"] = str(update_state["update_error"])
            logger.error("Update All: WebUI self-update failed: %s", update_state["update_error"])
        else:
            update_all_state["phase"] = "done"
    except Exception as exc:
        update_all_state["phase"] = "failed"
        update_all_state["error"] = str(exc)
        logger.error("Update All: WebUI phase error: %s", exc)
    finally:
        update_all_state["running"] = False
        await broadcast({"type": "update_all_progress", **update_all_state})


async def _run_self_update() -> None:
    """Re-run the installer from the synced repo. Systemd will restart the service."""
    if update_state["update_in_progress"]:
        return
    if not _INSTALLER_PATH.exists():
        msg = f"Self-update: installer not found at {_INSTALLER_PATH}"
        logger.error(msg)
        update_state["update_error"] = msg
        await _broadcast_update_state()
        return
    update_state["update_in_progress"] = True
    update_state["update_log"] = []
    update_state["update_error"] = None
    await _broadcast_update_state()
    try:
        import shlex as _shlex, os as _os
        # Use create_subprocess_shell so /bin/sh resolves bash via its own PATH.
        # This is more robust than exec when systemd strips the PATH env.
        full_path = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
        installer = _shlex.quote(str(_INSTALLER_PATH))
        # Pass --branch and --port so the bootstrap step can curl the right branch.
        _branch = _shlex.quote(os.environ.get("REPO_BRANCH", "lrb"))
        _port   = _shlex.quote(os.environ.get("PORT", "8000"))
        _base     = f'/bin/bash {installer} --branch {_branch} --port {_port}'
        shell_cmd = _base if _os.geteuid() == 0 else f'sudo -n /bin/bash {installer} --branch {_branch} --port {_port}'
        logger.info("Self-update: shell_cmd=%s", shell_cmd)
        proc = await asyncio.create_subprocess_shell(
            shell_cmd,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.STDOUT,
            env={**os.environ, "PATH": full_path},
            start_new_session=True,  # detach from server's process group so SIGTERM on restart doesn't kill installer
        )
        assert proc.stdout is not None
        _ansi_re = re.compile(r'\x1b(?:\[[0-9;]*[a-zA-Z]|\][^\x07\x1b]*(?:\x07|\x1b\\)|[^[\]])')
        async for raw in proc.stdout:
            line = _ansi_re.sub('', raw.decode(errors="replace")).rstrip()
            update_state["update_log"].append(line)
            logger.info("self-update: %s", line)
            await _broadcast_update_state()
        await proc.wait()
        # -15 (SIGTERM) is expected when the installer schedules a deferred
        # `systemctl restart` and asyncio cleans up the subprocess transport
        # when the server is stopped.  If the restart step already ran, treat
        # it as success rather than surfacing a misleading error.
        restart_triggered = any(
            "Restarting client-sim-dashboard" in l for l in update_state["update_log"]
        )
        if proc.returncode != 0 and not (proc.returncode == -15 and restart_triggered):
            logger.error("Self-update installer exited with code %s", proc.returncode)
            update_state["update_in_progress"] = False
            update_state["update_error"] = f"Installer exited with code {proc.returncode} — check logs"
            await _broadcast_update_state()
        else:
            logger.info("Self-update installer completed successfully (rc=%s)", proc.returncode)
            update_state["update_in_progress"] = False
            update_state["update_error"] = None
            await _broadcast_update_state()
    except Exception as exc:
        logger.exception("Self-update failed")
        update_state["update_in_progress"] = False
        update_state["update_error"] = str(exc)
        update_state["update_log"].append(f"ERROR: {exc}")
        await _broadcast_update_state()




async def acme_renewal_loop() -> None:
    while True:
        try:
            renewed = await spoke_acme.renew_if_needed(BASE_DIR)
            if renewed:
                cert_info = spoke_acme.get_cert_info()
                _acme_status["last_result"] = {"success": True, "expires": cert_info.get("expires"), "domain": cert_info.get("domain"), "renewed": True}
                _acme_status["last_error"] = None
                await broadcast({"type": "cert_renewed", "expires": cert_info.get("expires")})
        except asyncio.CancelledError:
            raise
        except Exception as exc:
            logger.exception("ACME renewal loop error: %s", exc)
            _acme_status["last_error"] = str(exc)
        await asyncio.sleep(86400)


async def heartbeat_check() -> None:
    await asyncio.sleep(HEARTBEAT_INTERVAL)
    while True:
        try:
            changed = False
            async with state_lock:
                for client in clients.values():
                    online = compute_online(client["last_seen"])
                    if client.get("online") != online:
                        client["online"] = online
                        changed = True
            if changed:
                await broadcast_full_state()
            _update_service_health("heartbeat", ok=True)
        except asyncio.CancelledError:
            raise
        except Exception as exc:
            _update_service_health("heartbeat", ok=False, error=str(exc))
            logger.exception("Heartbeat check error: %s", exc)
        await asyncio.sleep(HEARTBEAT_INTERVAL)


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
        "repo_branch": settings.get("repo_branch", ""),
        "repo_sync_interval": settings.get("repo_sync_interval", SYNC_INTERVAL),
        "github_token_configured": bool(settings.get("github_token")),
        "central_api": _public_central_api_settings(),
        "central_config": cfg,
        "site_mappings": settings["site_mappings"],
        "monitored_checks": settings["monitored_checks"],
        "hardware_checks": settings.get("hardware_checks", []),
        "usb_vidpids": settings.get("usb_vidpids", "[]"),
        "usb_missing_timeout": settings.get("usb_missing_timeout", "60"),
        "vm_image_1_template_id": settings.get("vm_image_1_template_id", settings.get("usb_linux_template_id", settings.get("usb_template_id", "100"))),
        "vm_image_2_template_id": settings.get("vm_image_2_template_id", settings.get("usb_windows_template_id", "200")),
        "vm_image_1_pct": settings.get("vm_image_1_pct", "50"),
        "usb_auto_provision": settings.get("usb_auto_provision", "off"),
        "usb_ignored_vidpids": settings.get("usb_ignored_vidpids", "[]"),
        "ignored_hostnames": settings.get("ignored_hostnames", '["sim-rpi-0000"]'),
        "vm_silent_timeout": settings.get("vm_silent_timeout", "24"),
        "reclone_schedule_enabled": settings.get("reclone_schedule_enabled", "off"),
        "reclone_schedule_cron": settings.get("reclone_schedule_cron", "sunday 02:00"),
        "reclone_concurrency": settings.get("reclone_concurrency", "1"),
        "l1_vlan_start": settings.get("l1_vlan_start", "100"),
        "l1_vlan_end": settings.get("l1_vlan_end", "199"),
        "notifications": _public_notification_settings(),
        "relay_enabled": settings.get("relay_enabled", "off"),
        "relay_server_url": settings.get("relay_server_url", ""),
        "relay_spoke_name": settings.get("relay_spoke_name", ""),
        "relay_tenant_hint": settings.get("relay_tenant_hint", settings.get("relay_tenant_id", "")),
        "relay_spoke_id": settings.get("relay_spoke_id", ""),
        "relay_tenant_id": settings.get("relay_tenant_id", settings.get("relay_tenant_hint", "")),
        "relay_poll_interval": settings.get("relay_poll_interval", RELAY_INTERVAL_DEFAULT),
        "relay_api_key_configured": bool(settings.get("relay_api_key")),
        "spoke_tls": settings.get("spoke_tls", "off"),
    }


@app.post("/api/settings")
async def api_settings_update(update: SettingsUpdate) -> dict[str, Any]:
    global relay_registration_refresh_needed
    changed_branch = False
    relay_config_changed = False

    if update.repo_branch is not None:
        branch = update.repo_branch.strip()
        if not branch or not re.match(r'^[a-zA-Z0-9._/\-]+$', branch):
            raise HTTPException(status_code=422, detail="Invalid branch name")
        settings["repo_branch"] = branch
        changed_branch = True

    if update.github_token is not None:
        settings["github_token"] = update.github_token.strip()

    if update.relay_server_url is not None:
        settings["relay_server_url"] = update.relay_server_url.strip()
        relay_config_changed = True

    if update.relay_spoke_name is not None:
        settings["relay_spoke_name"] = update.relay_spoke_name.strip()
        relay_config_changed = True

    if update.relay_tenant_hint is not None:
        tenant_id = update.relay_tenant_hint.strip()
        settings["relay_tenant_hint"] = tenant_id
        settings["relay_tenant_id"] = tenant_id
        relay_config_changed = True

    if update.relay_api_key is not None:
        settings["relay_api_key"] = update.relay_api_key.strip()
        relay_config_changed = True

    if update.relay_spoke_id is not None:
        settings["relay_spoke_id"] = update.relay_spoke_id.strip()
        relay_config_changed = True

    if update.relay_tenant_id is not None:
        tenant_id = update.relay_tenant_id.strip()
        settings["relay_tenant_id"] = tenant_id
        settings["relay_tenant_hint"] = tenant_id
        relay_config_changed = True

    if update.relay_enabled is not None:
        settings["relay_enabled"] = _normalize_relay_enabled(update.relay_enabled)
        relay_config_changed = True

    if update.relay_poll_interval is not None:
        settings["relay_poll_interval"] = _clamp_relay_interval(update.relay_poll_interval)
        relay_config_changed = True

    if relay_config_changed:
        relay_state.update({
            "enabled": settings.get("relay_enabled") == "on" and bool(settings.get("relay_server_url")),
            "connected": False,
            "error": None,
            "registration_status": _relay_registration_status_from_settings(),
        })
        relay_registration_refresh_needed = bool(relay_state["enabled"])
        _save_relay_state()

    if update.central_api is not None:
        merged_api = _normalize_central_api_settings(settings.get("central_api", {}), settings.get("central_config", {}))
        mode = str(update.central_api.get("mode", merged_api.get("mode", "classic"))).strip().lower()
        if mode not in {"classic", "central"}:
            raise HTTPException(status_code=422, detail="central_api.mode must be 'classic' or 'central'")
        merged_api["mode"] = mode

        classic_update = update.central_api.get("classic")
        if isinstance(classic_update, dict):
            for key in ("url", "username"):
                if key in classic_update:
                    merged_api["classic"][key] = str(classic_update.get(key, "")).strip()
            if "password" in classic_update:
                merged_api["classic"]["password"] = str(classic_update.get("password", ""))

        central_update = update.central_api.get("central")
        if isinstance(central_update, dict):
            for key in ("url", "client_id", "customer_id"):
                if key in central_update:
                    merged_api["central"][key] = str(central_update.get(key, "")).strip()
            if "client_secret" in central_update:
                merged_api["central"]["client_secret"] = str(central_update.get("client_secret", ""))

        settings["central_api"] = merged_api
        _sync_central_runtime_config()

    if update.central_config is not None:
        merged = dict(settings["central_config"])
        # Only update keys that are explicitly provided so omitted secrets are preserved.
        for key in ("cluster_url", "client_id", "customer_id", "api_version"):
            if key in update.central_config:
                merged[key] = update.central_config[key].strip()
        for secret_key in ("client_secret", "access_token", "refresh_token"):
            if secret_key in update.central_config:
                merged[secret_key] = update.central_config.get(secret_key, "").strip()
        # Switching to New Central — clear stale classic tokens from runtime
        if merged.get("api_version") == "new_central":
            central_token["access_token"] = None
            central_token["refresh_token"] = None
            central_token["expires_at"] = 0.0
        settings["central_config"] = merged
        merged_api = _normalize_central_api_settings(settings.get("central_api", {}), merged)
        if merged.get("api_version") == "new_central":
            merged_api["mode"] = "central"
            merged_api["central"].update({
                "url": merged.get("cluster_url", "").strip(),
                "client_id": merged.get("client_id", "").strip(),
                "client_secret": merged.get("client_secret", ""),
                "customer_id": merged.get("customer_id", "").strip(),
            })
        settings["central_api"] = merged_api
        # Classic: load new tokens into runtime state immediately
        if merged.get("api_version", "classic") == "classic":
            central_token["access_token"] = merged.get("access_token") or None
            central_token["refresh_token"] = merged.get("refresh_token") or None
            central_token["expires_at"] = time.time() + 7200 if merged.get("access_token") else 0.0

    if update.site_mappings is not None:
        settings["site_mappings"] = {k.strip(): v.strip() for k, v in update.site_mappings.items() if k.strip()}

    if update.monitored_checks is not None:
        settings["monitored_checks"] = [
            {"type": c.get("type", ""), "id": c.get("id", ""), "name": c.get("name", c.get("id", ""))}
            for c in update.monitored_checks
            if c.get("type") and c.get("id")
        ]

    if update.hardware_checks is not None:
        settings["hardware_checks"] = [
            {
                "id": c.get("id", ""),
                "name": c.get("name") or _HW_FRIENDLY.get(c.get("id", ""), c.get("id", "")),
                "device_type": c.get("device_type") or _auto_device_type(c.get("id", "")),
            }
            for c in update.hardware_checks
            if c.get("id")
        ]

    if update.notifications is not None:
        merged_notif = dict(settings.get("notifications", {}))
        merged_notif.update(update.notifications)
        # Ensure smtp_to is always a list
        if isinstance(merged_notif.get("smtp_to"), str):
            merged_notif["smtp_to"] = [a.strip() for a in merged_notif["smtp_to"].split(",") if a.strip()]
        settings["notifications"] = merged_notif

    if update.repo_sync_interval is not None:
        interval = max(60, min(86400, update.repo_sync_interval))  # clamp 1min–24hr
        settings["repo_sync_interval"] = interval

    if update.usb_vidpids is not None:
        settings["usb_vidpids"] = _ensure_json_list(update.usb_vidpids.strip(), "usb_vidpids")

    if update.usb_missing_timeout is not None:
        settings["usb_missing_timeout"] = str(max(1, int(update.usb_missing_timeout.strip() or "60")))

    if update.usb_template_id is not None:
        settings["vm_image_1_template_id"] = str(max(1, int(update.usb_template_id.strip() or "100")))

    if update.vm_image_1_template_id is not None:
        settings["vm_image_1_template_id"] = str(max(1, int(update.vm_image_1_template_id.strip() or "100")))

    if update.vm_image_2_template_id is not None:
        settings["vm_image_2_template_id"] = str(max(1, int(update.vm_image_2_template_id.strip() or "200")))

    if update.vm_image_1_pct is not None:
        settings["vm_image_1_pct"] = str(max(0, min(100, int(update.vm_image_1_pct.strip() or "50"))))

    if update.usb_auto_provision is not None:
        settings["usb_auto_provision"] = _normalize_toggle(update.usb_auto_provision)

    if update.usb_ignored_vidpids is not None:
        settings["usb_ignored_vidpids"] = _ensure_json_list(update.usb_ignored_vidpids.strip(), "usb_ignored_vidpids")

    if update.ignored_hostnames is not None:
        settings["ignored_hostnames"] = _ensure_json_list(update.ignored_hostnames.strip(), "ignored_hostnames")

    if update.vm_silent_timeout is not None:
        settings["vm_silent_timeout"] = str(max(1, int(update.vm_silent_timeout.strip() or "24")))

    if update.reclone_schedule_enabled is not None:
        settings["reclone_schedule_enabled"] = _normalize_toggle(update.reclone_schedule_enabled)

    if update.reclone_schedule_cron is not None:
        cron_value = update.reclone_schedule_cron.strip().lower() or "sunday 02:00"
        if _parse_reclone_schedule(cron_value) is None:
            raise HTTPException(status_code=422, detail="reclone_schedule_cron must be in '<day> HH:MM' format")
        settings["reclone_schedule_cron"] = cron_value

    if update.reclone_concurrency is not None:
        settings["reclone_concurrency"] = str(max(1, int(update.reclone_concurrency.strip() or "1")))

    if update.l1_vlan_start is not None:
        settings["l1_vlan_start"] = str(max(1, min(4094, int(update.l1_vlan_start.strip() or "100"))))

    if update.l1_vlan_end is not None:
        settings["l1_vlan_end"] = str(max(1, min(4094, int(update.l1_vlan_end.strip() or "199"))))

    if update.spoke_tls is not None:
        settings["spoke_tls"] = _normalize_toggle(update.spoke_tls)

    _save_settings()

    if changed_branch:
        if "sync_repo" in background_tasks:
            background_tasks["sync_repo"].cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await background_tasks["sync_repo"]
        background_tasks["sync_repo"] = asyncio.create_task(sync_repo())

    # Re-filter unknown_usb immediately so subsequent proxmox_update broadcasts don't
    # restore devices the user just certified or ignored.
    if update.usb_vidpids is not None or update.usb_ignored_vidpids is not None:
        _new_certified: set[str] = {
            str(item.get("vidpid", "")).strip().lower()
            for item in _parse_json_list(settings.get("usb_vidpids", "[]"))
            if isinstance(item, dict) and item.get("vidpid")
        }
        _new_ignored: set[str] = {
            str(v).strip().lower()
            for v in _parse_json_list(settings.get("usb_ignored_vidpids", "[]"))
            if str(v).strip()
        }
        _exclude = _new_certified | _new_ignored
        proxmox_state["unknown_usb"] = [
            d for d in proxmox_state.get("unknown_usb", [])
            if str(d.get("vidpid", "")).strip()
            and str(d.get("vidpid", "")).strip().lower() not in _exclude
        ]

    payload = await api_settings_get()
    await broadcast({"type": "settings_update", "settings": payload})
    if relay_config_changed:
        await _broadcast_relay_state()
    return {"status": "ok", "settings": payload}


@app.post("/api/settings/clear/{provider}")
async def api_settings_clear(provider: str, payload: dict[str, Any] | None = Body(default=None)) -> dict[str, Any]:
    provider_key = provider.strip().lower()
    changed_branch = False
    relay_config_changed = False
    relay_payload: dict[str, Any] | None = None

    if provider_key == "github":
        changed_branch = bool(settings.get("repo_branch"))
        settings["repo_branch"] = ""
        settings["github_token"] = ""
    elif provider_key == "relay":
        settings.update({
            "relay_enabled": "off",
            "relay_server_url": "",
            "relay_spoke_name": "",
            "relay_tenant_hint": "",
            "relay_api_key": "",
            "relay_spoke_id": "",
            "relay_tenant_id": "",
            "relay_poll_interval": RELAY_INTERVAL_DEFAULT,
        })
        relay_state.update({
            "enabled": False,
            "connected": False,
            "last_sync": None,
            "error": None,
            "registration_status": "unregistered",
        })
        relay_registration_refresh_needed = False
        _save_relay_state()
        relay_config_changed = True
        relay_payload = _relay_status_payload()
    elif provider_key == "central":
        requested_mode = str((payload or {}).get("mode") or settings.get("central_api", {}).get("mode", "classic")).strip().lower()
        if requested_mode not in {"classic", "central"}:
            raise HTTPException(status_code=422, detail="mode must be 'classic' or 'central'")
        central_api_cfg = _normalize_central_api_settings(settings.get("central_api", {}), settings.get("central_config", {}))
        central_api_cfg["mode"] = requested_mode
        if requested_mode == "classic":
            central_api_cfg["classic"] = {"url": "", "username": "", "password": ""}
        else:
            central_api_cfg["central"] = {"url": "", "client_id": "", "client_secret": "", "customer_id": ""}
        settings["central_api"] = central_api_cfg
        _sync_central_runtime_config()
    else:
        raise HTTPException(status_code=404, detail=f"Unknown settings provider: {provider}")

    _save_settings()

    if changed_branch:
        if "sync_repo" in background_tasks:
            background_tasks["sync_repo"].cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await background_tasks["sync_repo"]
        background_tasks["sync_repo"] = asyncio.create_task(sync_repo())

    payload = await api_settings_get()
    await broadcast({"type": "settings_update", "settings": payload})
    if relay_config_changed and relay_payload is not None:
        await _broadcast_relay_state()

    response: dict[str, Any] = {"status": "ok", "provider": provider_key, "settings": payload}
    if relay_payload is not None:
        response["relay_status"] = relay_payload
    return response


@app.post("/api/relay/trigger")
async def api_relay_trigger() -> dict[str, Any]:
    """Manually trigger an immediate relay sync."""
    if settings.get("relay_enabled") != "on":
        raise HTTPException(status_code=400, detail="Relay is not enabled")
    if not settings.get("relay_server_url"):
        raise HTTPException(status_code=400, detail="Relay server URL not configured")
    asyncio.create_task(relay_sync_once())
    return {"status": "ok", "message": "Relay sync triggered"}


@app.post("/api/relay/ingest")
async def api_relay_ingest(payload: dict[str, Any] = Body(...)) -> dict[str, Any]:
    """Accept a site snapshot from a remote WebUI acting as a relay agent."""
    site_id = payload.get("site_id")
    if not site_id:
        raise HTTPException(status_code=422, detail="site_id is required")
    tenant_id = payload.get("tenant_id") or "__untenanted__"
    async with state_lock:
        relay_sites.setdefault(tenant_id, {})[site_id] = {**payload, "ingested_at": time.time()}
    await broadcast({
        "type": "relay_ingest",
        "tenant_id": tenant_id,
        "site_id": site_id,
        "client_count": payload.get("client_count", 0),
        "timestamp": payload.get("timestamp"),
    })
    logger.info("Ingested relay snapshot from tenant=%s site=%s (%d clients)", tenant_id, site_id, payload.get("client_count", 0))
    return {"status": "ok", "tenant_id": tenant_id, "site_id": site_id}


@app.get("/api/relay/sites")
async def api_relay_sites(tenant_id: str | None = Query(None)) -> dict[str, Any]:
    """Return ingested site snapshots. Optionally filter by tenant_id."""
    async with state_lock:
        if tenant_id:
            sites = list(relay_sites.get(tenant_id, {}).values())
        else:
            # Return all tenants flattened
            sites = [site for tenant in relay_sites.values() for site in tenant.values()]
    return {"sites": sites, "tenant_id": tenant_id}


@app.get("/api/repo/status")
async def api_repo_status() -> dict[str, Any]:
    return {
        "synced": repo_state.get("synced", False),
        "error": repo_state.get("error"),
        "last_sync": repo_state.get("last_sync"),
        "repo_version": _repo_ver,
    }


@app.get("/api/relay/status")
async def api_relay_status_endpoint() -> dict[str, Any]:
    return {
        **relay_state,
        "spoke_id": settings.get("relay_spoke_id", ""),
        "api_key_configured": bool(settings.get("relay_api_key")),
        "spoke_name": settings.get("relay_spoke_name", ""),
    }


@app.get("/api/relay/diag")
async def api_relay_diag() -> dict[str, Any]:
    """Return registration diagnostics: config summary, live hub reachability, and registration log."""
    server_url = settings.get("relay_server_url", "").rstrip("/")
    hostname = socket.gethostname()

    # Live reachability check
    reachability: dict[str, Any] = {"tested_url": server_url or "(not set)", "ok": False, "detail": ""}
    if server_url:
        try:
            async with httpx.AsyncClient(timeout=8, verify=False) as hc:
                r = await hc.get(f"{server_url}/api/health")
                reachability = {
                    "tested_url": f"{server_url}/api/health",
                    "ok": r.status_code < 400,
                    "http_status": r.status_code,
                    "detail": r.text[:200],
                }
        except Exception as exc:
            reachability = {
                "tested_url": f"{server_url}/api/health",
                "ok": False,
                "detail": str(exc),
            }
    else:
        reachability["detail"] = "Server URL not configured"

    config_check = {
        "relay_enabled": settings.get("relay_enabled", "off"),
        "server_url": server_url or "(not set)",
        "spoke_name": settings.get("relay_spoke_name", "") or "(not set — will use hostname)",
        "hostname": hostname,
        "spoke_id": settings.get("relay_spoke_id", "") or "(none)",
        "api_key_configured": bool(settings.get("relay_api_key")),
        "tenant_id": settings.get("relay_tenant_id", "") or "(none)",
    }

    return {
        "config": config_check,
        "current_state": dict(relay_state),
        "reachability": reachability,
        "log": list(reversed(relay_diag_log)),
    }


@app.get("/api/logs/service")
def api_service_logs(lines: int = Query(default=50, ge=1, le=500)) -> dict[str, Any]:
    timestamp = iso_utcnow()
    try:
        result = subprocess.run(
            [
                "journalctl",
                "-u",
                JOURNAL_UNIT,
                "-n",
                str(lines),
                "--no-pager",
                "--output=short",
            ],
            capture_output=True,
            text=True,
            timeout=5,
        )
        if result.returncode == 0:
            log_lines = result.stdout.splitlines()
            return {"lines": log_lines, "count": len(log_lines), "timestamp": timestamp}
    except Exception:
        pass

    fallback = ["journalctl not available"]
    return {"lines": fallback, "count": len(fallback), "timestamp": timestamp}


@app.get("/api/proxmox/usb-config")
async def get_proxmox_usb_config() -> dict[str, Any]:
    return _proxmox_usb_config_payload()


@app.post("/api/proxmox/reclone-all")
async def api_proxmox_reclone_all() -> dict[str, Any]:
    if reclone_state.get("status") == "running":
        raise HTTPException(status_code=409, detail="A reclone run is already in progress")
    eligible = _reclone_targets_for_run()
    unassigned_dongles = _proxmox_unassigned_present_usb()
    if not eligible and not unassigned_dongles:
        raise HTTPException(
            status_code=400,
            detail=(
                "No reclone-capable guests or unassigned certified USB devices were found. "
                "Guests without a USB mapping or LXC template source are skipped."
            ),
        )
    asyncio.create_task(_run_rolling_reclone("manual"))
    return {"status": "started", "vm_count": len(eligible), "unassigned_dongles": len(unassigned_dongles)}


@app.get("/api/proxmox/reclone-status")
async def api_proxmox_reclone_status() -> dict[str, Any]:
    return dict(reclone_state)


@app.post("/api/proxmox/telemetry", response_model=None)
async def proxmox_telemetry(request: Request, body: dict = Body(...)) -> dict[str, bool] | JSONResponse:
    """Receive telemetry from the Proxmox host agent."""
    node = body.get("node", {}) or {}
    hostname = str(node.get("hostname", "") or "").strip()
    api_key = request.headers.get("X-API-Key", "")
    client_ip = request.client.host if request.client else "unknown"
    now = time.time()

    if not hostname:
        return JSONResponse({"error": "hostname required"}, status_code=400)

    approved_hostname = _resolve_proxmox_agent_hostname(hostname, approved_proxmox_agents)
    if approved_hostname is None:
        _upsert_pending_proxmox_agent(hostname, client_ip, now)
        await broadcast({"type": "proxmox_pending_update", "pending": _pending_proxmox_payload()})
        if api_key:
            return JSONResponse({"error": "agent not approved"}, status_code=401)
        return JSONResponse({"pending": True}, status_code=202)

    if api_key != approved_proxmox_agents[approved_hostname]:
        return JSONResponse({"error": "invalid key"}, status_code=401)

    pending_hostname = _resolve_proxmox_agent_hostname(hostname, pending_proxmox_agents)
    if pending_hostname is not None:
        pending_proxmox_agents.pop(pending_hostname, None)
        await broadcast({"type": "proxmox_pending_update", "pending": _pending_proxmox_payload()})

    async with state_lock:
        client_seen = {hostname: client.get("last_seen") for hostname, client in clients.items()}

    enriched_vms: list[dict[str, Any]] = []
    configured_template_ids: set[str] = {
        str(settings.get("vm_image_1_template_id", "100")).strip(),
        str(settings.get("vm_image_2_template_id", "200")).strip(),
    } - {""}
    for vm in body.get("vms", []):
        enriched = dict(vm)
        client_last_seen = client_seen.get(str(enriched.get("name", "")))
        if isinstance(client_last_seen, datetime):
            enriched["last_seen"] = client_last_seen.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")
        # Mark as template if agent flagged it OR if vmid matches a configured template ID
        if enriched.get("is_template") or str(enriched.get("vmid", "")).strip() in configured_template_ids:
            enriched["is_template"] = True
        enriched_vms.append(enriched)

    # Filter unknown_usb against currently certified and ignored vidpids so the device
    # disappears from the UI immediately after a certify/ignore action, even before the
    # Proxmox agent picks up the updated config on its next poll.
    certified_vidpids: set[str] = {
        str(item.get("vidpid", "")).strip().lower()
        for item in _parse_json_list(settings.get("usb_vidpids", "[]"))
        if isinstance(item, dict) and item.get("vidpid")
    }
    ignored_vidpids: set[str] = {
        str(v).strip().lower()
        for v in _parse_json_list(settings.get("usb_ignored_vidpids", "[]"))
        if str(v).strip()
    }
    exclude_vidpids = certified_vidpids | ignored_vidpids
    raw_unknown = body.get("unknown_usb", [])
    proxmox_state["unknown_usb"] = [
        d for d in raw_unknown
        if str(d.get("vidpid", "")).strip()  # skip devices with no VID:PID
        and str(d.get("vidpid", "")).strip().lower() not in exclude_vidpids
    ]

    normalized_present_usb = body.get("present_usb", [])
    normalized_usb_state = _normalize_proxmox_usb_state(body.get("usb_state", []), normalized_present_usb)

    proxmox_state["connected"] = True
    proxmox_state["last_seen"] = now
    proxmox_state["node"] = node
    proxmox_state["vms"] = enriched_vms
    proxmox_state["usb_state"] = normalized_usb_state
    proxmox_state["present_usb"] = normalized_present_usb
    proxmox_state["missing_timeout_mins"] = int(body.get("missing_timeout_mins", 60) or 60)
    proxmox_state["agent_version"] = str(body.get("agent_version", "")).strip() or None
    proxmox_state["pve_version"] = str(body.get("pve_version", "")).strip() or None

    # Detect provisioning/teardown completions for summary tracking
    global _prev_usb_by_vmid
    new_usb: list[dict] = proxmox_state["usb_state"]
    new_by_vmid = {str(e["vmid"]): e.get("prov_status", "active") for e in new_usb if e.get("vmid") is not None}
    if _prev_usb_by_vmid:
        newly_provisioned = [
            vmid for vmid, st in new_by_vmid.items()
            if st == "active" and _prev_usb_by_vmid.get(vmid) == "provisioning"
        ]
        torn_down = [
            vmid for vmid, st in _prev_usb_by_vmid.items()
            if vmid not in new_by_vmid and st in ("tearing_down", "missing")
        ]
        if newly_provisioned:
            proxmox_state["prov_summary"] = {"action": "provisioned", "count": len(newly_provisioned), "at": now}
            for vmid in newly_provisioned:
                vm = next((item for item in enriched_vms if str(item.get("vmid")) == vmid), {})
                _record_vm_watchdog_clone_completed(vmid, vm.get("name"))
            _save_vm_watchdog()
        elif torn_down:
            proxmox_state["prov_summary"] = {"action": "deleted", "count": len(torn_down), "at": now}
    _update_provision_run_state(enriched_vms, new_usb, now)
    _prev_usb_by_vmid = new_by_vmid

    # Append new log lines to ring buffer and broadcast if any arrived
    new_lines = [str(ln) for ln in (body.get("log_lines") or []) if ln]
    if new_lines:
        proxmox_log_buffer.extend(new_lines)
        if len(proxmox_log_buffer) > PROXMOX_LOG_MAX:
            del proxmox_log_buffer[:len(proxmox_log_buffer) - PROXMOX_LOG_MAX]
        await broadcast({"type": "proxmox_log_update", "lines": new_lines})

    await _broadcast_proxmox_state()
    return {"ok": True}


@app.get("/api/proxmox/logs")
async def get_proxmox_logs() -> dict[str, Any]:
    """Return the in-memory agent log ring buffer."""
    return {"lines": proxmox_log_buffer}


@app.post("/api/proxmox/logs/clear")
async def clear_proxmox_logs() -> dict[str, bool]:
    """Clear the in-memory agent log buffer."""
    proxmox_log_buffer.clear()
    await broadcast({"type": "proxmox_log_update", "lines": [], "cleared": True})
    return {"ok": True}


@app.post("/api/proxmox/watchdog_event")
async def proxmox_watchdog_event(body: dict = Body(...)) -> dict[str, bool]:
    event = str(body.get("event", "") or "").strip()
    service = str(body.get("service", "") or "").strip()
    hostname = str(body.get("hostname", "") or "").strip()
    timestamp = str(body.get("timestamp", "") or "").strip()
    try:
        failure_count = max(0, int(body.get("failure_count", 0) or 0))
    except (TypeError, ValueError):
        raise HTTPException(status_code=400, detail="failure_count must be an integer")

    if not all((event, service, hostname, timestamp)):
        raise HTTPException(status_code=400, detail="event, service, hostname, and timestamp are required")

    entry = {
        "event": event,
        "service": service,
        "hostname": hostname,
        "timestamp": timestamp,
        "failure_count": failure_count,
    }
    proxmox_watchdog_log.append(entry)
    if len(proxmox_watchdog_log) > PROXMOX_WATCHDOG_LOG_MAX:
        del proxmox_watchdog_log[:len(proxmox_watchdog_log) - PROXMOX_WATCHDOG_LOG_MAX]

    log_line = (
        f"[{timestamp}] WATCHDOG event={event} service={service} "
        f"hostname={hostname} failure_count={failure_count}"
    )
    proxmox_log_buffer.append(log_line)
    if len(proxmox_log_buffer) > PROXMOX_LOG_MAX:
        del proxmox_log_buffer[:len(proxmox_log_buffer) - PROXMOX_LOG_MAX]
    await broadcast({"type": "proxmox_log_update", "lines": [log_line]})
    return {"ok": True}


@app.get("/api/proxmox/status")
async def get_proxmox_status() -> dict[str, Any]:
    return _proxmox_status_payload()


@app.post("/api/proxmox/update-agent")
async def api_proxmox_update_agent() -> dict[str, Any]:
    cmd = await _queue_proxmox_agent_update()
    return {
        "queued": 1,
        "id": cmd["id"],
        "target": cmd["target"],
        "branch": cmd["args"].get("branch"),
        "source": cmd["args"].get("repo_raw"),
    }



@app.delete("/api/proxmox/vms/{vmid}")
async def api_proxmox_delete_vm(vmid: int) -> dict[str, Any]:
    args = _prepare_delete_vm_args({"vmid": vmid})
    cmd = await _queue_proxmox_command("delete_vm", args)
    return {
        "queued": 1,
        "ids": [cmd["id"]],
        "vmid": vmid,
        "vm_type": args.get("vm_type"),
        "vm_name": args.get("vm_name"),
    }


@app.post("/api/proxmox/register")
async def proxmox_register(request: Request, body: dict = Body(...)) -> JSONResponse:
    """Called by agent with no key. Adds to pending if not approved."""
    hostname = str(body.get("hostname", "") or request.headers.get("X-Hostname", "")).strip()
    if not hostname:
        return JSONResponse({"error": "hostname required"}, status_code=400)
    client_ip = request.client.host if request.client else "unknown"

    approved_hostname = _resolve_proxmox_agent_hostname(hostname, approved_proxmox_agents)
    if approved_hostname is not None:
        pending_hostname = _resolve_proxmox_agent_hostname(hostname, pending_proxmox_agents)
        if pending_hostname is not None:
            pending_proxmox_agents.pop(pending_hostname, None)
            await broadcast({"type": "proxmox_pending_update", "pending": _pending_proxmox_payload()})
        return JSONResponse({"approved": True, "key": approved_proxmox_agents[approved_hostname]})

    now = time.time()
    _upsert_pending_proxmox_agent(hostname, client_ip, now)
    await broadcast({"type": "proxmox_pending_update", "pending": _pending_proxmox_payload()})
    return JSONResponse({"pending": True}, status_code=202)


@app.get("/api/proxmox/key")
async def proxmox_get_key(hostname: str = Query(...)) -> JSONResponse:
    """Agent polls this until approved. Returns key when ready."""
    approved_hostname = _resolve_proxmox_agent_hostname(hostname, approved_proxmox_agents)
    if approved_hostname is not None:
        return JSONResponse({"approved": True, "key": approved_proxmox_agents[approved_hostname]})
    if _resolve_proxmox_agent_hostname(hostname, pending_proxmox_agents) is not None:
        return JSONResponse({"pending": True}, status_code=202)
    return JSONResponse({"error": "unknown hostname"}, status_code=404)


@app.get("/api/proxmox/pending")
async def proxmox_pending_list() -> list[dict[str, Any]]:
    return _pending_proxmox_payload()


@app.post("/api/proxmox/approve/{hostname}")
async def proxmox_approve(hostname: str) -> dict[str, Any]:
    pending_hostname = _resolve_proxmox_agent_hostname(hostname, pending_proxmox_agents)
    approved_hostname = _resolve_proxmox_agent_hostname(hostname, approved_proxmox_agents)
    if approved_hostname is not None:
        if pending_hostname is not None:
            pending_proxmox_agents.pop(pending_hostname, None)
            await broadcast({"type": "proxmox_pending_update", "pending": _pending_proxmox_payload()})
            await _broadcast_proxmox_state()
        return {"approved": True, "hostname": approved_hostname, "key": approved_proxmox_agents[approved_hostname], "existing": True}

    resolved_hostname = pending_hostname or _normalize_proxmox_hostname(hostname)
    if not resolved_hostname:
        raise HTTPException(status_code=400, detail="hostname is required")

    key = str(uuid.uuid4())
    approved_proxmox_agents[resolved_hostname] = key
    pending_proxmox_agents.pop(pending_hostname or resolved_hostname, None)
    settings["proxmox_approved_agents"] = dict(approved_proxmox_agents)
    _save_settings()
    await broadcast({"type": "proxmox_pending_update", "pending": _pending_proxmox_payload()})
    await _broadcast_proxmox_state()
    return {"approved": True, "hostname": resolved_hostname, "key": key}


@app.post("/api/proxmox/reject/{hostname}")
async def proxmox_reject(hostname: str) -> dict[str, Any]:
    resolved_hostname = _resolve_proxmox_agent_hostname(hostname, pending_proxmox_agents) or _normalize_proxmox_hostname(hostname)
    pending_proxmox_agents.pop(resolved_hostname, None)
    await broadcast({"type": "proxmox_pending_update", "pending": _pending_proxmox_payload()})
    await _broadcast_proxmox_state()
    return {"rejected": True, "hostname": resolved_hostname}


@app.delete("/api/proxmox/approved/{hostname}")
async def proxmox_revoke(hostname: str) -> dict[str, Any]:
    """Revoke an approved agent's key."""
    resolved_hostname = _resolve_proxmox_agent_hostname(hostname, approved_proxmox_agents) or _normalize_proxmox_hostname(hostname)
    approved_proxmox_agents.pop(resolved_hostname, None)
    settings["proxmox_approved_agents"] = dict(approved_proxmox_agents)
    _save_settings()
    await _broadcast_proxmox_state()
    return {"revoked": True, "hostname": resolved_hostname}


@app.get("/api/proxmox/approved")
async def proxmox_approved_list() -> list[dict[str, Any]]:
    return _approved_proxmox_payload()


# ── Aruba Central API endpoints ───────────────────────────────────────────────
@app.post("/api/central/test-connection")
async def api_central_test() -> dict[str, Any]:
    mode = settings.get("central_api", {}).get("mode", "classic")
    async with httpx.AsyncClient() as client:
        if mode == "classic":
            ok, detail_msg = await _test_classic_central_connection(client)
            if ok:
                return {"status": "ok", "message": detail_msg}
            raise HTTPException(status_code=502 if "HTTP" in detail_msg or "rejected" in detail_msg else 422, detail=detail_msg)

        if not _central_ready():
            raise HTTPException(
                status_code=422,
                detail="Central API not configured — enter URL, Client ID, and Client Secret in Setup.",
            )
        ok, detail_msg = await _fetch_central_token(client)
    if ok:
        return {
            "status": "ok",
            "message": "Connected to Central API successfully.",
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
        "wireless_clients": dict(central_wireless_clients),
        "hardware_alerts": _hw_alerts_payload(),
        "client_count_status": _client_count_payload(),
        "site_mappings": settings.get("site_mappings", {}),
        "monitored_checks": settings.get("monitored_checks", []),
        "token_valid": bool(central_token.get("access_token") and time.time() < central_token["expires_at"]),
        "token_state": _central_token_state(),
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
        return {"alerts": [], "warning": "Alert detail not available in Central mode yet."}

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
    async def _poll_with_client() -> None:
        async with httpx.AsyncClient() as client:
            await _poll_central_once(client)
    asyncio.create_task(_poll_with_client())
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
    sim_conf_path = REPO_DIR / "configs" / "simulation.conf"
    client_conf_path = REPO_DIR / "proxmox" / "client-setup.conf"

    sim_mtime = sim_conf_path.stat().st_mtime if sim_conf_path.exists() else -1.0
    client_mtime = client_conf_path.stat().st_mtime if client_conf_path.exists() else -1.0

    if (sim_mtime == _sim_conf_cache["sim_mtime"] and
            client_mtime == _sim_conf_cache["client_mtime"]):
        simulations: dict[str, dict[str, Any]] = copy.deepcopy(_sim_conf_cache["simulations"])
        site_based_num: int = _sim_conf_cache["site_based_num"]
    else:
        simulations = {}
        site_based_num = 2

        # ── Parse simulation.conf ─────────────────────────────────────
        if sim_conf_path.exists():
            try:
                parser = configparser.ConfigParser()
                parser.read_string(sim_conf_path.read_text(encoding="utf-8"))
                site_based_num = int(parser.get("simulation", "site_based_num", fallback="2"))

                _SIM_TEST_KEYS = [
                    "dns_fail", "assoc_fail", "dhcp_fail", "port_flap",
                    "iperf", "www_traffic", "download", "ping_test",
                ]
                sim_section_re = re.compile(r"^s\d$")
                for section in parser.sections():
                    if not sim_section_re.match(section):
                        continue
                    simulations[section] = {
                        "id": section,
                        "wsite": parser.get(section, "wsite", fallback=""),
                        "central_check": parser.get(section, "central_check", fallback="").strip(),
                        "tests": {
                            k: parser.get(section, k, fallback="off").strip().lower() == "on"
                            for k in _SIM_TEST_KEYS
                        },
                        "configured_clients": [],
                        "active_client_count": 0,
                        "central_pass_fail": None,
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

        _sim_conf_cache.update({
            "sim_mtime": sim_mtime,
            "client_mtime": client_mtime,
            "simulations": copy.deepcopy(simulations),
            "site_based_num": site_based_num,
        })

    # ── Match active clients + compute Central PASS/FAIL ─────────
    async with state_lock:
        active_snap = {h: dict(c) for h, c in clients.items()}

    for sim in simulations.values():
        active_count = 0

        # Primary: count any live client whose simulation_id matches this bucket
        for h, c in active_snap.items():
            if c.get("simulation_id", "") == sim["id"]:
                online = compute_online(c.get("last_seen", datetime.min.replace(tzinfo=timezone.utc)))
                if online:
                    active_count += 1

        # Secondary: update configured_clients reporting flags (for detail panel)
        for client_info in sim["configured_clients"]:
            h = client_info["hostname"]
            if h in active_snap:
                c = active_snap[h]
                online = compute_online(c.get("last_seen", datetime.min.replace(tzinfo=timezone.utc)))
                last_seen_dt = c.get("last_seen")
                client_info["reporting"] = True
                client_info["online"] = online
                client_info["last_seen"] = last_seen_dt.isoformat() if last_seen_dt else None

        sim["active_client_count"] = active_count
        sim["central_client_count"] = central_wireless_clients.get(sim["wsite"], None)

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


# Cache: (wsite, central_site) → (timestamp, [client_name, ...])
_central_client_cache: dict[str, tuple[float, list[str]]] = {}
_CENTRAL_CLIENT_CACHE_TTL = 60  # seconds


async def _fetch_central_client_names(wsite: str, central_site: str) -> list[str]:
    """Fetch wireless client hostnames from Central for a given site (cached 60 s)."""
    cache_key = f"{wsite}:{central_site}"
    now = time.time()
    if cache_key in _central_client_cache:
        ts, names = _central_client_cache[cache_key]
        if now - ts < _CENTRAL_CLIENT_CACHE_TTL:
            return names

    cfg = _central_cfg()
    if not cfg.get("access_token") and not cfg.get("client_id"):
        return []

    base_url = cfg["cluster_url"].rstrip("/")
    headers = _central_headers()
    names: list[str] = []

    async with httpx.AsyncClient() as client:
        for path in ["/monitoring/v2/clients/wireless", "/monitoring/v1/clients/wireless"]:
            for site_param in ["site", "site_name"]:
                try:
                    resp = await asyncio.wait_for(
                        client.get(
                            f"{base_url}{path}",
                            headers=headers,
                            params={site_param: central_site, "limit": 1000},
                            timeout=10,
                        ),
                        timeout=12,
                    )
                    if resp.status_code == 401 and _can_refresh():
                        ok, _ = await _refresh_central_token(client)
                        if ok:
                            headers = _central_headers()
                        resp = await client.get(
                            f"{base_url}{path}",
                            headers=headers,
                            params={site_param: central_site, "limit": 1000},
                            timeout=10,
                        )
                    if resp.status_code == 200:
                        body = resp.json()
                        for c in body.get("clients", []):
                            n = (c.get("name") or c.get("client_name") or
                                 c.get("username") or "").strip().lower()
                            if n:
                                names.append(n)
                        _central_client_cache[cache_key] = (now, names)
                        return names
                    if resp.status_code == 404:
                        continue
                except Exception:
                    pass

    return names


@app.get("/api/simulations/{sim_id}/clients")
async def api_sim_clients(sim_id: str) -> dict[str, Any]:
    """Return per-client status for one simulation bucket.

    Each client entry includes:
      - api_online / api_last_seen — from live heartbeats
      - central_connected — matched by hostname from Central wireless client list
    """
    import configparser as _cp

    sim_conf_path = REPO_DIR / "configs" / "simulation.conf"
    client_conf_path = REPO_DIR / "proxmox" / "client-setup.conf"

    # --- Load simulation profile ---
    wsite = ""
    central_site = ""
    site_based_num = 2
    if sim_conf_path.exists():
        try:
            p = _cp.ConfigParser()
            p.read_string(sim_conf_path.read_text(encoding="utf-8"))
            site_based_num = int(p.get("simulation", "site_based_num", fallback="2"))
            if p.has_section(sim_id):
                wsite = p.get(sim_id, "wsite", fallback="")
        except Exception:
            pass

    central_site = settings.get("site_mappings", {}).get(wsite, "")

    # --- Build configured client list from client-setup.conf ---
    configured: dict[str, dict[str, Any]] = {}  # hostname → info
    if client_conf_path.exists():
        try:
            cp = _cp.ConfigParser()
            cp.read_string(client_conf_path.read_text(encoding="utf-8"))
            vmid_re = re.compile(r"^c(\d+)$")
            for section in cp.sections():
                m = vmid_re.match(section)
                if not m:
                    continue
                vmid_str = m.group(1)
                vm_name = cp.get(section, "vm_name", fallback="").strip()
                if not vm_name:
                    continue
                digit = vmid_str[-(site_based_num)] if len(vmid_str) >= site_based_num else vmid_str[-1]
                if f"s{digit}" != sim_id:
                    continue
                hostname = f"{vm_name}-{vmid_str}"
                configured[hostname] = {
                    "hostname": hostname,
                    "vmid": int(vmid_str),
                    "api_online": False,
                    "api_last_seen": None,
                    "central_connected": None,
                    "source": "configured",
                }
        except Exception:
            pass

    # --- Overlay live heartbeat data ---
    async with state_lock:
        active_snap = {h: dict(c) for h, c in clients.items()}

    for h, c in active_snap.items():
        if c.get("simulation_id", "") != sim_id:
            continue
        online = compute_online(c.get("last_seen", datetime.min.replace(tzinfo=timezone.utc)))
        last_seen_dt = c.get("last_seen")
        active_sims = list(c.get("active_simulations", []))
        if h in configured:
            configured[h]["api_online"] = online
            configured[h]["api_last_seen"] = last_seen_dt.isoformat() if last_seen_dt else None
            configured[h]["active_simulations"] = active_sims
        else:
            configured[h] = {
                "hostname": h,
                "vmid": None,
                "api_online": online,
                "api_last_seen": last_seen_dt.isoformat() if last_seen_dt else None,
                "active_simulations": active_sims,
                "central_connected": None,
                "source": "heartbeat",
            }

    # --- Match against Central client list ---
    central_names: list[str] = []
    if central_site:
        try:
            central_names = await asyncio.wait_for(
                _fetch_central_client_names(wsite, central_site), timeout=15
            )
        except Exception:
            pass

    central_set = {n.lower() for n in central_names}
    for info in configured.values():
        if central_set:
            info["central_connected"] = info["hostname"].lower() in central_set
        # else leave None (not configured / fetch failed)

    return {
        "sim_id": sim_id,
        "wsite": wsite,
        "central_site": central_site,
        "central_total": central_wireless_clients.get(wsite, None),
        "clients": sorted(configured.values(), key=lambda x: x["hostname"]),
    }


@app.get("/api/hardware-alerts")
async def api_hardware_alerts() -> dict[str, Any]:
    """Return configured hardware checks merged with current alert device data."""
    return {"hardware_alerts": _hw_alerts_payload()}



async def _api_health_payload() -> dict[str, Any]:
    async with state_lock:
        client_count = len(clients)
    return {
        "status": "ok",
        "version": APP_VERSION,
        "clients": client_count,
        "repo_synced": repo_state["synced"],
        "repo_error": repo_state["error"],
        "installer_version": INSTALLER_VERSION,
    }


@app.post("/api/sync-now")
async def api_sync_now() -> dict[str, Any]:
    """Trigger an immediate GitHub sync outside the normal interval."""
    if "sync_repo" in background_tasks:
        background_tasks["sync_repo"].cancel()
        with contextlib.suppress(asyncio.CancelledError):
            await background_tasks["sync_repo"]
    repo_state["synced"] = False
    repo_state["error"] = None
    background_tasks["sync_repo"] = asyncio.create_task(sync_repo())
    await broadcast({"type": "repo_status", "synced": False, "error": None, "last_sync": repo_state["last_sync"]})
    return {"status": "ok", "message": "GitHub sync started"}


@app.get("/api/version")
async def api_version() -> dict[str, Any]:
    """Return installed and available installer versions."""
    return {
        "status": "ok",
        "app_version": APP_VERSION,
        "current_version": update_state["current_version"],
        "available_version": update_state["available_version"],
        "update_available": update_state["update_available"],
        "last_checked": update_state["last_checked"],
        "update_in_progress": update_state["update_in_progress"],
    }


@app.post("/api/update-all")
async def api_update_all() -> dict[str, Any]:
    """Queue the shared Proxmox update command, then self-update the WebUI."""
    if update_all_state["running"]:
        raise HTTPException(status_code=409, detail="Update All already in progress")
    if update_state["update_in_progress"]:
        raise HTTPException(status_code=409, detail="WebUI update already in progress")
    has_approved_agents = bool(approved_proxmox_agents)
    update_all_state.update({
        "running": True,
        "phase": "agents" if has_approved_agents else "webui",
        "total_agents": 1 if has_approved_agents else 0,
        "completed_agents": 0,
        "failed_agents": 0,
        "agent_cmds": [],
        "started_at": time.time(),
        "error": None,
    })
    await broadcast({"type": "update_all_progress", **update_all_state})
    asyncio.create_task(_run_update_all())
    return {"status": "ok", "message": "Update All started"}


@app.post("/api/self-update")
async def api_self_update() -> dict[str, Any]:
    """Manually trigger a self-update check and apply if a new version is available."""
    if update_state["update_in_progress"]:
        raise HTTPException(status_code=409, detail="Update already in progress")
    # Sync from GitHub first so version check reflects the latest repo state
    try:
        async with _git_lock:
            await asyncio.to_thread(sync_repo_once)
        repo_state["synced"] = True
        repo_state["error"] = None
        repo_state["last_sync"] = time.time()
        await broadcast({"type": "repo_status", "synced": True, "error": None, "last_sync": repo_state["last_sync"]})
    except Exception as exc:
        repo_state["error"] = str(exc)
        await broadcast({"type": "repo_status", "synced": repo_state["synced"], "error": str(exc)})
        raise HTTPException(status_code=502, detail=f"GitHub sync failed: {exc}") from exc
    # Now check version against freshly synced repo
    available = await asyncio.to_thread(_get_repo_version)
    import datetime
    update_state["available_version"] = available
    update_state["last_checked"] = datetime.datetime.now().isoformat(timespec="seconds")
    update_state["update_available"] = (
        available is not None and available != update_state["current_version"]
    )
    await _broadcast_update_state()
    if not update_state["update_available"]:
        return {"status": "ok", "message": f"Already up to date (v{update_state['current_version']})"}
    asyncio.create_task(_run_self_update())
    return {"status": "ok", "message": f"Update to v{available} started — service will restart shortly"}




@app.get("/api/acme")
async def api_acme_get() -> dict[str, Any]:
    cfg = spoke_acme.load_acme_config()
    data = _public_acme_settings(cfg)
    data["cert_info"] = spoke_acme.get_cert_info()
    data["spoke_tls"] = settings.get("spoke_tls", "off")
    return data


@app.post("/api/acme")
async def api_acme_update(payload: dict[str, Any]) -> dict[str, Any]:
    existing = spoke_acme.load_acme_config()
    incoming_credentials = payload.get("dns_credentials") or {}
    merged_credentials = dict(existing.dns_credentials or {})
    for key, value in incoming_credentials.items():
        if value in (None, "***"):
            continue
        merged_credentials[key] = value
    cfg = spoke_acme.AcmeConfig(
        enabled=bool(payload.get("enabled", existing.enabled)),
        domain=str(payload.get("domain", existing.domain) or "").strip(),
        email=str(payload.get("email", existing.email) or "").strip(),
        challenge=str(payload.get("challenge", existing.challenge) or existing.challenge),
        ca=str(payload.get("ca", existing.ca) or existing.ca),
        dns_provider=str(payload.get("dns_provider", existing.dns_provider) or "").strip(),
        dns_credentials=merged_credentials,
        last_renewed=existing.last_renewed,
        last_error=existing.last_error,
        cert_expiry=existing.cert_expiry,
    )
    spoke_acme.save_acme_config(cfg)
    if "spoke_tls" in payload:
        settings["spoke_tls"] = _normalize_toggle(payload.get("spoke_tls"))
        _save_settings()
    data = _public_acme_settings(cfg)
    data["cert_info"] = spoke_acme.get_cert_info()
    data["spoke_tls"] = settings.get("spoke_tls", "off")
    return data


async def _run_acme_request() -> None:
    _acme_status["running"] = True
    _acme_status["last_result"] = None
    _acme_status["last_error"] = None
    await broadcast({"type": "acme_status", **_acme_status})
    cfg = spoke_acme.load_acme_config()
    result = await spoke_acme.request_certificate(cfg, BASE_DIR)
    _acme_status["running"] = False
    _acme_status["last_result"] = result
    _acme_status["last_error"] = None if result.get("success") else result.get("error")
    if result.get("success"):
        settings["spoke_tls"] = "on"
        _save_settings()
        logger.info("TLS certificate ready. Restart the spoke service with SPOKE_TLS=on to enable HTTPS.")
        await broadcast({"type": "cert_renewed", "expires": result.get("expires")})
    await broadcast({"type": "acme_status", **_acme_status})


@app.post("/api/acme/request")
async def api_acme_request() -> dict[str, Any]:
    if _acme_status.get("running"):
        return {"status": "running"}
    asyncio.create_task(_run_acme_request())
    return {"status": "started"}


@app.get("/api/acme/status")
async def api_acme_status() -> dict[str, Any]:
    return dict(_acme_status)


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


@app.get("/api/config/parsed")
async def api_config_parsed() -> dict[str, dict[str, str]]:
    config_path = repo_path("configs", "simulation.conf")
    parser = configparser.ConfigParser()
    parser.optionxform = str
    parser.read(config_path, encoding="utf-8")
    return {section: dict(parser.items(section)) for section in parser.sections()}


@app.post("/api/config/simulation")
async def api_config_simulation(update: SimulationConfigUpdate) -> dict[str, Any]:
    section = update.section.strip()
    if section not in ALLOWED_CONFIG_SECTIONS:
        raise HTTPException(status_code=422, detail="Invalid section name")

    config_path = repo_path("configs", "simulation.conf")
    updates = {str(key).strip(): str(value) for key, value in update.updates.items() if str(key).strip()}
    await asyncio.to_thread(_update_ini_section, config_path, section, updates)

    pushed = False
    try:
        async with _git_lock:
            pushed = await asyncio.to_thread(
                _push_to_github,
                ["configs/simulation.conf"],
                f"WebUI: update [{section}] settings",
            )
    except ValueError:
        pushed = False

    # When the kill switch is turned OFF, immediately push the change down to
    # all clients via the command inbox so they don't stay stuck in the
    # kill-switch loop waiting for their next exec-restart cycle (up to 5 min).
    # IMPORTANT: expand "all" to per-client commands at creation time — the
    # inbox filter matches exact hostname, so a single target="all" command
    # would never be delivered to any client.
    if section == "simulation" and updates.get("kill_switch") == "off":
        async with state_lock:
            known = list(clients.keys())
            targets = known or ["all"]
            for hostname in targets:
                _enqueue_command_locked(hostname, "kill_switch", {"value": "off"})
            serialized = _serialize_commands()
        await broadcast({"type": "commands_update", "commands": serialized})

    return {"status": "ok", "pushed": pushed}


@app.post("/api/config/overrides/save")
async def api_config_overrides_save(update: OverridesSaveRequest) -> dict[str, Any]:
    ensure_repo_ready()
    username = update.username.strip()
    if not username:
        raise HTTPException(status_code=422, detail="Username is required")

    overrides_path = REPO_DIR / "configs" / "user-overrides.conf"
    section = "simulation" if username == "__global__" else username
    flags = {str(key).strip(): str(value) for key, value in update.flags.items() if str(key).strip()}
    await asyncio.to_thread(_update_ini_section, overrides_path, section, flags)

    pushed = False
    try:
        async with _git_lock:
            pushed = await asyncio.to_thread(
                _push_to_github,
                ["configs/user-overrides.conf"],
                f"WebUI: update overrides for {username}",
            )
    except ValueError:
        pushed = False

    return {"status": "ok", "pushed": pushed}


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
    # Ignore the Proxmox template VM — it uses the default hostname before
    # being cloned and renamed.  Registering it would pollute the dashboard.
    _IGNORED_HOSTNAMES = set(_parse_json_list(settings.get("ignored_hostnames", '["sim-rpi-0000"]')))
    if status.hostname in _IGNORED_HOSTNAMES:
        return {"status": "ignored", "reason": "template hostname"}

    now = utcnow()
    watchdog_changed = False
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
            "hw_type": status.hw_type or existing.get("hw_type", ""),
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
        normalized_hostname = str(status.hostname or "").strip().lower()
        for vmid_key, entry in list(vm_watchdog.items()):
            if str(entry.get("hostname") or "").strip().lower() != normalized_hostname:
                continue
            clone_completed_at = _parse_ts(entry.get("clone_completed_at"))
            if clone_completed_at is None or now.timestamp() <= clone_completed_at:
                continue
            vm_watchdog.pop(vmid_key, None)
            watchdog_changed = True
        if watchdog_changed:
            _save_vm_watchdog()
        payload = serialize_client(status.hostname, clients[status.hostname])

    await broadcast({"type": "status_update", "client": payload})
    if watchdog_changed:
        await _broadcast_proxmox_state()
    return {"status": "ok", "client": payload}


@app.get("/api/clients")
async def api_clients() -> list[dict[str, Any]]:
    return await current_clients()


@app.delete("/api/clients/history")
async def api_purge_client_history() -> dict[str, Any]:
    """Purge all persisted client records (in-memory and on disk)."""
    async with state_lock:
        clients.clear()
    await asyncio.to_thread(_save_client_history)
    await broadcast({"type": "clients_purged"})
    logger.info("Client history purged by user request")
    return {"status": "ok", "message": "Client history cleared"}


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



# ── Log viewer endpoints ──────────────────────────────────────────────────────

JOURNAL_UNIT = "client-sim-dashboard"
INSTALL_LOG_PATH = Path("/var/log/client-sim-dashboard-install.log")
LOG_STREAM_KEEPALIVE_SECS = 15
LOG_STREAM_POLL_SECS = 1


def _normalize_log_source(source: str) -> str:
    normalized = (source or "journal").strip().lower()
    if normalized not in {"journal", "install", "agent"}:
        raise HTTPException(status_code=400, detail=f"Unsupported log source: {source}")
    return normalized


def _log_source_hint(source: str, detail: str | None = None) -> str:
    detail_text = f": {detail}" if detail else ""
    if source == "agent":
        return "[INFO] No Proxmox agent logs yet — logs arrive on the next agent telemetry poll (≤60s after activity)."
    if source == "install":
        return f"[INFO] Install log {INSTALL_LOG_PATH} is not available on this spoke yet. Start an install or update to create it{detail_text}"
    return f"[WARN] Live service journal for {JOURNAL_UNIT} is unavailable on this spoke{detail_text}"


def _encode_sse_line(text: str) -> str:
    return f"data: {json.dumps(text)}\n\n"


async def _stream_keepalive() -> str:
    await asyncio.sleep(LOG_STREAM_KEEPALIVE_SECS)
    return ": keepalive\n\n"


@app.get("/api/logs/history")
async def api_logs_history(
    lines: int = Query(default=300, ge=10, le=2000),
    source: str = Query(default="journal"),
):
    """Return the last N lines from the selected log source."""
    source = _normalize_log_source(source)
    try:
        if source == "agent":
            log_lines = proxmox_log_buffer[-lines:]
            if not log_lines:
                log_lines = [_log_source_hint("agent")]
            return PlainTextResponse("\n".join(log_lines))

        if source == "install":
            if not INSTALL_LOG_PATH.exists():
                return PlainTextResponse(_log_source_hint("install"))
            proc = await asyncio.create_subprocess_exec(
                "tail", "-n", str(lines), str(INSTALL_LOG_PATH),
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.DEVNULL,
            )
        else:
            proc = await asyncio.create_subprocess_exec(
                "journalctl", "-u", JOURNAL_UNIT, "--no-pager", "-n", str(lines),
                "--output=short-iso",
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
            )
        stdout, stderr = await asyncio.wait_for(proc.communicate(), timeout=10)
        text = stdout.decode("utf-8", errors="replace").strip()
        if proc.returncode != 0 and not text:
            detail = stderr.decode("utf-8", errors="replace").strip() or None
            return PlainTextResponse(_log_source_hint(source, detail))
        return PlainTextResponse(text or _log_source_hint(source))
    except HTTPException:
        raise
    except Exception as exc:
        return PlainTextResponse(_log_source_hint(source, str(exc)))


@app.get("/api/logs/stream")
async def api_logs_stream(source: str = Query(default="journal")):
    """Server-Sent Events stream of live log output."""
    source = _normalize_log_source(source)

    async def generate():
        yield "retry: 5000\n\n"

        if source == "agent":
            last_index = len(proxmox_log_buffer)
            hinted_empty = False
            while True:
                current_len = len(proxmox_log_buffer)
                if current_len < last_index:
                    last_index = 0
                if current_len > last_index:
                    for line in proxmox_log_buffer[last_index:current_len]:
                        yield _encode_sse_line(str(line))
                    last_index = current_len
                    hinted_empty = False
                    continue
                if current_len == 0 and not hinted_empty:
                    hinted_empty = True
                    yield _encode_sse_line(_log_source_hint("agent"))
                yield await _stream_keepalive()
                await asyncio.sleep(LOG_STREAM_POLL_SECS)

        if source == "install" and not INSTALL_LOG_PATH.exists():
            yield _encode_sse_line(_log_source_hint("install"))

        proc = None
        try:
            if source == "install":
                proc = await asyncio.create_subprocess_exec(
                    "tail", "-n", "0", "-F", str(INSTALL_LOG_PATH),
                    stdout=asyncio.subprocess.PIPE,
                    stderr=asyncio.subprocess.DEVNULL,
                )
            else:
                proc = await asyncio.create_subprocess_exec(
                    "journalctl", "-u", JOURNAL_UNIT, "-f", "--no-pager", "-n", "0",
                    "--output=short-iso",
                    stdout=asyncio.subprocess.PIPE,
                    stderr=asyncio.subprocess.PIPE,
                )
        except Exception as exc:
            yield _encode_sse_line(_log_source_hint(source, str(exc)))
            while True:
                yield await _stream_keepalive()

        try:
            while True:
                try:
                    line = await asyncio.wait_for(proc.stdout.readline(), timeout=LOG_STREAM_KEEPALIVE_SECS)
                except asyncio.TimeoutError:
                    yield ": keepalive\n\n"
                    continue
                if line:
                    text = line.decode("utf-8", errors="replace").rstrip("\n")
                    if text:
                        yield _encode_sse_line(text)
                    continue
                detail = None
                if source == "journal" and proc.stderr is not None:
                    detail = (await proc.stderr.read()).decode("utf-8", errors="replace").strip() or None
                yield _encode_sse_line(_log_source_hint(source, detail))
                while True:
                    yield await _stream_keepalive()
        finally:
            if proc is not None and proc.returncode is None:
                with contextlib.suppress(Exception):
                    proc.kill()

    return StreamingResponse(generate(), media_type="text/event-stream",
                             headers={"Cache-Control": "no-cache",
                                      "X-Accel-Buffering": "no"})


@app.get("/api/init")
async def api_init() -> dict[str, Any]:
    """Single endpoint that returns all state needed for initial page render.
    Replaces 5+ separate REST calls made on page load."""
    cfg = dict(settings["central_config"])
    for secret_key in ("client_secret", "access_token", "refresh_token"):
        cfg.pop(secret_key, None)
    cfg["access_token_configured"] = bool(settings["central_config"].get("access_token") or central_token.get("access_token"))
    cfg["refresh_token_configured"] = bool(settings["central_config"].get("refresh_token") or central_token.get("refresh_token"))
    cfg["client_secret_configured"] = bool(settings["central_config"].get("client_secret"))
    return {
        "mode": "spoke",
        "proxmox": _proxmox_status_payload(),
        "settings": {
            "central_api": _public_central_api_settings(),
            "central_config": cfg,
            "relay_enabled": settings.get("relay_enabled", "off"),
            "relay_server_url": settings.get("relay_server_url", ""),
        },
        "reclone": dict(reclone_state),
        "update_all": dict(update_all_state),
        "central": {
            "status": _central_status_payload(),
            "wireless_clients": dict(central_wireless_clients),
            "hardware_alerts": _hw_alerts_payload(),
            "client_count_status": _client_count_payload(),
            "token_valid": bool(central_token.get("access_token") and time.time() < central_token.get("expires_at", 0)),
            "token_state": _central_token_state(),
        },
        "relay": _relay_status_payload(),
        "installer_version": INSTALLER_VERSION,
        "app_version": APP_VERSION,
        "kill_switch": gkill_switch_state["value"],
        "local_kill_switch": _read_local_kill_switch(),
    }


@app.get("/api/health")
async def api_health() -> dict[str, Any]:
    return await _api_health_payload()


@app.get("/api/services/status")
async def api_services_status() -> dict[str, Any]:
    return {
        "tasks": service_health,
        "task_names": list(background_tasks.keys()),
    }


# ── System health & service control ───────────────────────────────────────────

@app.get("/api/system/health")
async def api_system_health(request: Request) -> dict[str, Any]:
    """LXC host resource snapshot + service status + Proxmox install command."""
    import shutil as _shutil

    # Disk
    try:
        disk = _shutil.disk_usage(BASE_DIR)
        disk_info = {"total": disk.total, "used": disk.used, "free": disk.free}
    except Exception:
        disk_info = {"total": 0, "used": 0, "free": 0}

    # Memory via /proc/meminfo
    mem: dict[str, int] = {}
    try:
        for line in Path("/proc/meminfo").read_text(encoding="utf-8").splitlines():
            if ":" in line:
                k, v = line.split(":", 1)
                try:
                    mem[k.strip()] = int(v.strip().split()[0])
                except (ValueError, IndexError):
                    pass
    except Exception:
        pass
    mem_total = mem.get("MemTotal", 0)
    mem_avail = mem.get("MemAvailable", 0)
    mem_info = {"total_kb": mem_total, "available_kb": mem_avail,
                "used_kb": mem_total - mem_avail}

    # Load average
    try:
        load_parts = Path("/proc/loadavg").read_text(encoding="utf-8").split()
        load = load_parts[:3]
    except Exception:
        load = ["?", "?", "?"]

    # Uptime seconds
    try:
        uptime_secs = float(Path("/proc/uptime").read_text(encoding="utf-8").split()[0])
    except Exception:
        uptime_secs = 0.0

    # Service active state
    try:
        proc = await asyncio.create_subprocess_shell(
            "systemctl is-active client-sim-dashboard 2>/dev/null || echo inactive",
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.DEVNULL,
        )
        stdout, _ = await asyncio.wait_for(proc.communicate(), timeout=5)
        svc_status = stdout.decode().strip()
    except Exception:
        svc_status = "unknown"

    # Pre-built Proxmox agent install command
    base = str(request.base_url).rstrip("/")
    raw_base = REPO_URL.replace(".git", "").replace(
        "github.com", "raw.githubusercontent.com"
    )
    branch = os.environ.get("REPO_BRANCH", "lrb")
    install_cmd = (
        f"bash <(curl -sSL {raw_base}/{branch}/proxmox/install-proxmox-agent.sh)"
        f" --server {base}"
    )

    return {
        "disk": disk_info,
        "memory": mem_info,
        "load": load,
        "uptime_secs": uptime_secs,
        "service_status": svc_status,
        "proxmox_install_cmd": install_cmd,
    }


@app.post("/api/service/{action}")
async def api_service_control(action: str) -> dict[str, Any]:
    """Start, stop, or restart the client-sim-dashboard service."""
    if action not in ("start", "stop", "restart"):
        raise HTTPException(status_code=400, detail="action must be start, stop, or restart")
    try:
        proc = await asyncio.create_subprocess_shell(
            f"sudo -n systemctl {action} client-sim-dashboard",
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        stdout, stderr = await asyncio.wait_for(proc.communicate(), timeout=15)
        rc = proc.returncode or 0
    except asyncio.TimeoutError:
        return {"status": "timeout",
                "message": f"systemctl {action} timed out — service may be restarting"}
    except Exception as exc:
        return {"status": "error", "message": str(exc)}

    if rc != 0:
        return {"status": "error",
                "message": stderr.decode().strip() or f"exit code {rc}"}
    return {"status": "ok", "message": f"Service {action} sent"}


# ── Cache-clear endpoints ──────────────────────────────────────────────────────

@app.post("/api/server/clear-cache")
async def api_server_clear_cache() -> dict[str, Any]:
    """Reset all server-side in-memory state (Proxmox, reclone, commands, update-all).
    Does not restart the service — the UI will receive fresh empty state via WS broadcast."""
    async with state_lock:
        proxmox_state.update({
            "connected": False, "last_seen": None, "node": {}, "vms": [],
            "unknown_usb": [], "usb_state": [], "present_usb": [],
            "agent_version": None, "pve_version": None,
            "prov_summary": None, "prov_run": _default_provision_run_state(),
        })
        proxmox_log_buffer.clear()
        pending_proxmox_agents.clear()
        commands.clear()
        _save_commands()
        reclone_state.update({
            "status": "idle", "type": None, "total": 0, "completed": 0,
            "failed": 0, "current_vm": None, "log": [], "auto_recovery_log": [],
            "last_run": None, "started_at": None,
        })
        _save_reclone_state()
        update_all_state.update({
            "running": False, "phase": "idle", "total_agents": 0,
            "completed_agents": 0, "failed_agents": 0, "agent_cmds": [],
            "started_at": None, "error": None,
        })

    await broadcast({"type": "proxmox_update", **_proxmox_status_payload()})
    await _broadcast_reclone_state()
    await broadcast({"type": "update_all_progress", **update_all_state})
    await broadcast({"type": "commands_update", "commands": []})
    logger.info("Server cache cleared by user request")
    return {"status": "ok", "message": "Server cache cleared"}


@app.post("/api/setup/clear-cache")
async def api_setup_clear_cache() -> dict[str, Any]:
    """Wipe all cached files, re-clone the repo, clear in-memory client/central state,
    then restart the WebUI service so it starts completely fresh."""
    import shutil

    # 1. Delete cached data files
    for path in [
        CLIENT_HISTORY_FILE,
        STATE_CACHE_FILE,
        COMMAND_QUEUE_FILE,
        RECLONE_STATE_FILE,
        RELAY_STATE_FILE,
        UPDATE_STATE_FILE,
        HISTORY_FILE,
        CLIENT_COUNT_BASELINE_FILE,
    ]:
        try:
            path.unlink(missing_ok=True)
        except Exception:
            pass

    # 2. Clear in-memory state
    async with state_lock:
        clients.clear()
    async with history_lock:
        central_history.clear()
    central_wireless_clients.clear()

    # 3. Remove any stale git lock and wipe + re-clone the repo
    async with _git_lock:
        lock_file = REPO_DIR / ".git" / "index.lock"
        lock_file.unlink(missing_ok=True)
        try:
            shutil.rmtree(REPO_DIR, ignore_errors=True)
        except Exception as exc:
            logger.warning("clear-cache: could not remove REPO_DIR: %s", exc)
        try:
            await asyncio.to_thread(sync_repo_once)
            repo_state["synced"] = True
            repo_state["error"] = None
            repo_state["last_sync"] = time.time()
        except Exception as exc:
            logger.warning("clear-cache: re-clone failed: %s", exc)
            repo_state["error"] = str(exc)

    logger.info("Setup cache cleared by user request — restarting service")
    await broadcast({"type": "notification", "level": "info",
                     "message": "Cache cleared — service restarting in 2 seconds…"})

    # 4. Restart the service after a short delay so the response can be sent
    async def _delayed_restart() -> None:
        await asyncio.sleep(2)
        try:
            await asyncio.create_subprocess_shell(
                "sudo -n systemctl restart client-sim-dashboard",
                stdout=asyncio.subprocess.DEVNULL,
                stderr=asyncio.subprocess.DEVNULL,
            )
        except Exception as exc:
            logger.error("clear-cache: restart failed: %s", exc)

    asyncio.create_task(_delayed_restart())
    return {"status": "ok", "message": "Cache cleared — service restarting"}


@app.get("/api/kill-switch", response_class=PlainTextResponse)
async def api_kill_switch() -> str:
    """Return the current global kill switch value ('on' or 'off').
    Clients should poll this as their primary source — always fetched from
    solutions-hpe/main so no fork can override it."""
    return gkill_switch_state["value"]


@app.get("/api/kill-switch/status")
async def api_kill_switch_status() -> dict[str, Any]:
    """Return full gkill_switch state for the WebUI dashboard."""
    return {
        "value": gkill_switch_state["value"],
        "last_fetched": gkill_switch_state["last_fetched"],
        "error": gkill_switch_state["error"],
    }


@app.post("/api/commands")
async def create_command(body: dict[str, Any] = Body(...)) -> dict[str, Any]:
    """Queue a command for one device, all clients, or the proxmox agent."""
    target = str(body.get("target", "")).strip()
    action = _normalize_command_action(body.get("action", ""))
    args = body.get("args", {})
    command_type = _normalize_command_type(body.get("type"))

    if not target or not action:
        raise HTTPException(status_code=422, detail="target and action are required")
    if args is None:
        args = {}
    if not isinstance(args, dict):
        raise HTTPException(status_code=422, detail="args must be an object")

    new_cmds: list[dict[str, Any]] = []
    deduped = 0

    async with state_lock:
        expired, purged = _cleanup_commands_locked()
        if target == "all":
            known = list(clients.keys())
            if not known:
                raise HTTPException(status_code=400, detail="No clients registered yet")
            for hostname in known:
                cmd, created, _expired, _purged = _enqueue_command_locked(hostname, action, args, command_type=command_type)
                if created:
                    new_cmds.append(cmd)
                else:
                    deduped += 1
        elif target == "proxmox":
            cmd, created, _expired, _purged = _enqueue_command_locked(target, action, args, command_type=command_type)
            if created:
                new_cmds.append(cmd)
            else:
                deduped += 1
        else:
            if target not in clients:
                raise HTTPException(status_code=404, detail="Client not found")
            cmd, created, _expired, _purged = _enqueue_command_locked(target, action, args, command_type=command_type)
            if created:
                new_cmds.append(cmd)
            else:
                deduped += 1
        serialized = _serialize_commands()

    if new_cmds or expired or purged:
        await broadcast({"type": "commands_update", "commands": serialized})
    return {"queued": len(new_cmds), "deduped": deduped, "ids": [c["id"] for c in new_cmds]}


@app.get("/api/commands")
async def list_commands() -> list[dict[str, Any]]:
    """Return the current in-memory command queue plus short-lived terminal results."""
    async with state_lock:
        expired, purged = _cleanup_commands_locked()
        serialized = _serialize_commands()
    if expired or purged:
        await broadcast({"type": "commands_update", "commands": serialized})
    return serialized


@app.get("/api/inbox")
async def poll_inbox(request: Request, hostname: str) -> list[dict[str, Any]]:
    """Device polls for pending commands addressed to it. Marks them delivered."""
    if not hostname:
        raise HTTPException(status_code=422, detail="hostname is required")
    approved_hostname = _resolve_proxmox_agent_hostname(hostname, approved_proxmox_agents)
    if approved_hostname is not None:
        api_key = request.headers.get("X-API-Key", "")
        if api_key != approved_proxmox_agents[approved_hostname]:
            raise HTTPException(status_code=401, detail="invalid key")

    async with state_lock:
        expired, purged = _cleanup_commands_locked()
        pending = [
            c for c in commands
            if c["status"] == "pending" and (
                c["target"] == hostname or
                (approved_hostname is not None and _proxmox_hostnames_match(c["target"], approved_hostname)) or
                (c["target"] == "proxmox" and approved_hostname is not None)
            )
        ]
        now = time.time()
        for cmd in pending:
            cmd["status"] = "delivered"
            cmd["updated_at"] = now
        if pending:
            _save_commands()
        serialized = _serialize_commands()
        payload = [{"id": c["id"], "action": c["action"], "args": c["args"], "type": c.get("type")} for c in pending]

    if pending or expired or purged:
        await broadcast({"type": "commands_update", "commands": serialized})
    return payload


@app.post("/api/inbox/ack")
async def ack_command(body: dict[str, Any] = Body(...)) -> dict[str, bool]:
    """Device reports command result."""
    cmd_id = str(body.get("id", "")).strip()
    status = str(body.get("status", "completed")).strip().lower()
    message = body.get("message", "")

    if status not in ("completed", "failed"):
        raise HTTPException(status_code=422, detail="status must be 'completed' or 'failed'")

    async with state_lock:
        expired, purged = _cleanup_commands_locked()
        cmd = next((c for c in commands if c["id"] == cmd_id), None)
        if not cmd:
            raise HTTPException(status_code=404, detail="Command not found")

        cmd["status"] = status
        cmd["message"] = str(message) if message is not None else ""
        cmd["updated_at"] = time.time()
        cmd["purge_after"] = cmd["updated_at"] + COMMAND_RESULT_RETENTION_SECS
        _save_commands()
        serialized = _serialize_commands()

    await broadcast({"type": "commands_update", "commands": serialized})
    return {"ok": True}


@app.delete("/api/commands/pending")
async def expire_pending_for_target(target: str = Query(...)) -> dict[str, int]:
    """Expire active commands for a given target hostname before replacing a VM."""
    count = 0
    now = time.time()
    async with state_lock:
        expired, purged = _cleanup_commands_locked(now)
        for cmd in commands:
            if cmd["target"] == target and cmd["status"] in {"pending", "delivered"}:
                cmd["status"] = "expired"
                cmd["updated_at"] = now
                cmd["purge_after"] = now + COMMAND_RESULT_RETENTION_SECS
                count += 1
        if count:
            _save_commands()
        serialized = _serialize_commands()
    if count:
        logger.info("Expired %d active command(s) for target %s before VM destroy", count, target)
        await broadcast({"type": "commands_update", "commands": serialized})
    elif expired or purged:
        await broadcast({"type": "commands_update", "commands": serialized})
    return {"expired": count}


@app.delete("/api/commands/{cmd_id}")
async def delete_command(cmd_id: str) -> dict[str, bool]:
    """Remove a command from history."""
    async with state_lock:
        before = len(commands)
        commands[:] = [c for c in commands if c["id"] != cmd_id]
        if len(commands) == before:
            raise HTTPException(status_code=404, detail="Command not found")
        _save_commands()
        serialized = _serialize_commands()
    await broadcast({"type": "commands_update", "commands": serialized})
    return {"ok": True}


@app.post("/api/notifications/test")
async def api_notifications_test(body: dict[str, Any]) -> dict[str, Any]:
    """Send a test notification via email or Teams."""
    channel = body.get("channel", "")  # "email" | "teams"
    notif = dict(settings.get("notifications", {}))
    # Allow overriding with posted values (for unsaved fields)
    notif.update({k: v for k, v in body.items() if k != "channel"})

    test_transition = [{
        "check_type": "sim",
        "check_id": "test",
        "check_name": "Test Notification",
        "site": "test-site",
        "old": "ok",
        "new": "error",
        "ts": time.time(),
    }]

    try:
        if channel == "email":
            if not notif.get("smtp_host") or not notif.get("smtp_to"):
                raise HTTPException(status_code=422, detail="smtp_host and smtp_to are required")
            await asyncio.to_thread(_send_email_notifications, notif, test_transition)
        elif channel == "teams":
            url = notif.get("teams_webhook_url", "")
            if not url:
                raise HTTPException(status_code=422, detail="teams_webhook_url is required")
            await _send_teams_notifications(url, test_transition)
        else:
            raise HTTPException(status_code=422, detail="channel must be 'email' or 'teams'")
    except HTTPException:
        raise
    except Exception as exc:
        raise HTTPException(status_code=500, detail=str(exc)) from exc

    return {"status": "ok", "channel": channel}


@app.get("/.well-known/acme-challenge/{token}", include_in_schema=False)
async def acme_challenge(token: str):
    key_authorization = _acme_challenges.get(token)
    if not key_authorization:
        raise HTTPException(404)
    return PlainTextResponse(key_authorization)


@app.websocket("/ws")
async def websocket_endpoint(websocket: WebSocket) -> None:
    await websocket.accept()
    ws_connections.append(websocket)
    # Send initial state snapshot — each message is individually guarded so one
    # serialisation error cannot take down the entire connection.
    try:
        await websocket.send_text(json.dumps({"type": "full_state", "clients": await current_clients()}, default=str))
    except Exception as exc:  # noqa: BLE001
        logger.error("WS on-connect full_state error: %s", exc)
    try:
        global _repo_ver
        _repo_ver = await asyncio.to_thread(_get_repo_version)
        await websocket.send_text(json.dumps({"type": "repo_status", "synced": repo_state["synced"], "error": repo_state["error"], "last_sync": repo_state["last_sync"], "repo_version": _repo_ver}, default=str))
    except Exception as exc:  # noqa: BLE001
        logger.error("WS on-connect repo_status error: %s", exc)
    try:
        await websocket.send_text(json.dumps({"type": "relay_status", **_relay_status_payload()}, default=str))
    except Exception as exc:  # noqa: BLE001
        logger.error("WS on-connect relay_status error: %s", exc)
    try:
        await websocket.send_text(json.dumps({"type": "settings_update", "settings": await api_settings_get()}, default=str))
    except Exception as exc:  # noqa: BLE001
        logger.error("WS on-connect settings_update error: %s", exc)
    try:
        if (
            proxmox_state["connected"]
            or proxmox_state["vms"]
            or proxmox_state.get("usb_state")
            or proxmox_state.get("unknown_usb")
            or pending_proxmox_agents
            or approved_proxmox_agents
        ):
            await websocket.send_text(json.dumps({"type": "proxmox_update", **_proxmox_status_payload()}, default=str))
    except Exception as exc:  # noqa: BLE001
        logger.error("WS on-connect proxmox_update error: %s", exc)
    try:
        await websocket.send_text(json.dumps({"type": "reclone_update", **dict(reclone_state)}, default=str))
    except Exception as exc:  # noqa: BLE001
        logger.error("WS on-connect reclone_update error: %s", exc)
    try:
        await websocket.send_text(json.dumps({"type": "update_all_progress", **dict(update_all_state)}, default=str))
    except Exception as exc:  # noqa: BLE001
        logger.error("WS on-connect update_all_progress error: %s", exc)
    try:
        await websocket.send_text(json.dumps({"type": "central_update", "status": _central_status_payload(), "wireless_clients": dict(central_wireless_clients), "hardware_alerts": _hw_alerts_payload(), "client_count_status": _client_count_payload(), "ts": time.time(), "token_state": _central_token_state()}, default=str))
    except Exception as exc:  # noqa: BLE001
        logger.error("WS on-connect central_update error: %s", exc)
    try:
        # Send current kill switch state so reconnecting clients don't miss a change
        await websocket.send_text(json.dumps({"type": "gkill_switch_update", "value": gkill_switch_state["value"]}))
    except Exception as exc:  # noqa: BLE001
        logger.error("WS on-connect gkill_switch_update error: %s", exc)

    try:
        while True:
            await websocket.receive_text()
    except WebSocketDisconnect:
        pass
    finally:
        with contextlib.suppress(ValueError):
            ws_connections.remove(websocket)


@app.get("/", response_class=HTMLResponse)
async def root():
    index = STATIC_DIR / "index.html"
    html = index.read_text()
    html = html.replace("{{WEBUI_MODE}}", "spoke")
    return HTMLResponse(content=html)


app.mount("/static", StaticFiles(directory=STATIC_DIR), name="static")
