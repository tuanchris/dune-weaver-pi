"""
Per-board catalog cache — the host's local copy of "what's on THIS board".

The FluidNC board is the source of truth for which patterns and playlists exist
(its SD card is authoritative; the mobile app and a swapped SD card change it
out-of-band). The app displays that catalog, so the host caches it per board,
keyed by the board's MAC. Caching per board means switching between tables is
instant and survives the board being briefly offline.

Two files live under ``board_cache/<key>/``:

  - ``manifest.json``  -> ``{"etag", "patterns": [...], "fetched_at"}``
    The board's ``/sand_patterns`` catalog (paths relative to ``/patterns``).
    The firmware serves ``/patterns/index.json`` with an ETag and answers a
    conditional GET with ``304 Not Modified`` when nothing changed, so a
    reconnect to an unchanged board re-downloads nothing (the firmware API.md
    explicitly asks clients to cache the ETag and revalidate — the repeated full
    catalog downloads are what pushed the heap-tight board into low-memory
    shedding). The stored ``etag`` is what we send back as ``If-None-Match``.

  - ``playlists.json`` -> ``{"<name>": ["<pattern-path>", ...], ...}``
    Each board playlist's entries (relative to ``/patterns``, matching the
    manifest), read from ``/sd/playlists/<name>.txt`` at sync time.

Local pattern files (``./patterns``) are NOT the catalog anymore — they are only
a preview asset store (thumbnails + the live-playback canvas), matched to a
board pattern by path.
"""

import json
import logging
import os

from modules.core.state import state

logger = logging.getLogger(__name__)

# Sibling of playlists.json / metadata_cache.json in the project root.
CACHE_ROOT = os.path.join(os.getcwd(), "board_cache")

_EMPTY_MANIFEST = {"etag": None, "patterns": [], "fetched_at": 0.0}


def _sanitize(value: str) -> str:
    """Filesystem-safe token: keep alnum, collapse everything else to nothing."""
    return "".join(c for c in (value or "").lower() if c.isalnum())


def board_key(mac: str | None = None, hostname: str | None = None) -> str | None:
    """Stable per-board directory key.

    MAC is preferred — it is the one identifier that survives a DHCP move or an
    mDNS hostname change (the same identity the reconnect watchdog matches on).
    Falls back to the hostname when the MAC is unknown (older firmware). Returns
    None when the board hasn't been identified yet, so callers skip caching
    rather than write to an ambiguous shared key.
    """
    mac = mac if mac is not None else getattr(state, "board_mac", None)
    if mac:
        key = _sanitize(mac)
        if key:
            return f"mac-{key}"
    hostname = hostname if hostname is not None else getattr(state, "board_hostname", None)
    if hostname:
        key = _sanitize(hostname)
        if key:
            return f"host-{key}"
    return None


def _board_dir(key: str) -> str:
    return os.path.join(CACHE_ROOT, key)


def _read_json(path: str, default):
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except FileNotFoundError:
        return default
    except (json.JSONDecodeError, ValueError, OSError) as e:
        logger.warning(f"Board cache {path} unreadable ({e}); using default")
        return default


def _write_json(path: str, data) -> None:
    """Atomic write (tmp + replace) so a crash mid-write can't corrupt the cache."""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = f"{path}.tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, separators=(",", ":"))
    os.replace(tmp, path)


# --------------------------------------------------------------------- manifest

def load_manifest(key: str | None = None) -> dict:
    """Cached pattern manifest for a board (defaults to the current board)."""
    key = key or board_key()
    if not key:
        return dict(_EMPTY_MANIFEST)
    data = _read_json(os.path.join(_board_dir(key), "manifest.json"), None)
    if not isinstance(data, dict):
        return dict(_EMPTY_MANIFEST)
    patterns = data.get("patterns")
    return {
        "etag": data.get("etag"),
        "patterns": patterns if isinstance(patterns, list) else [],
        "fetched_at": data.get("fetched_at", 0.0),
    }


def save_manifest(patterns: list, etag: str | None, key: str | None = None) -> None:
    key = key or board_key()
    if not key:
        return
    import time
    _write_json(
        os.path.join(_board_dir(key), "manifest.json"),
        {"etag": etag, "patterns": list(patterns or []), "fetched_at": time.time()},
    )


# -------------------------------------------------------------------- playlists

def load_playlists(key: str | None = None) -> dict:
    """Cached ``{name: [pattern-path, ...]}`` playlists for a board."""
    key = key or board_key()
    if not key:
        return {}
    data = _read_json(os.path.join(_board_dir(key), "playlists.json"), {})
    return data if isinstance(data, dict) else {}


def save_playlists(playlists: dict, key: str | None = None) -> None:
    key = key or board_key()
    if not key:
        return
    _write_json(os.path.join(_board_dir(key), "playlists.json"), playlists or {})
