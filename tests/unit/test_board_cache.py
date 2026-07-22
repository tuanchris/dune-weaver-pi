"""
Unit tests for the per-board catalog cache and its connect-time sync.

Covers:
- board_key derivation (MAC preferred, hostname fallback, None when unknown)
- manifest / playlists round-trip on disk (per-board directories)
- board_settings.sync_board_catalog: ETag revalidation (200 store vs 304 keep)
  and reading playlist .txt entries into the cache
"""
import pytest
from unittest.mock import MagicMock

from modules.core import board_cache, board_settings
from modules.core.state import state


@pytest.fixture
def cache_root(tmp_path, monkeypatch):
    """Point the cache at a throwaway dir so tests never touch the real one."""
    root = tmp_path / "board_cache"
    monkeypatch.setattr(board_cache, "CACHE_ROOT", str(root))
    return root


@pytest.fixture
def board_identity(monkeypatch):
    """A known board MAC/hostname on state, restored after the test."""
    monkeypatch.setattr(state, "board_mac", "aa:bb:cc:dd:ee:ff", raising=False)
    monkeypatch.setattr(state, "board_hostname", "DWMP", raising=False)


class TestBoardKey:
    def test_prefers_mac(self, board_identity):
        assert board_cache.board_key() == "mac-aabbccddeeff"

    def test_falls_back_to_hostname(self, monkeypatch):
        monkeypatch.setattr(state, "board_mac", None, raising=False)
        monkeypatch.setattr(state, "board_hostname", "Dune-Weaver!", raising=False)
        assert board_cache.board_key() == "host-duneweaver"

    def test_none_when_unidentified(self, monkeypatch):
        monkeypatch.setattr(state, "board_mac", None, raising=False)
        monkeypatch.setattr(state, "board_hostname", None, raising=False)
        assert board_cache.board_key() is None

    def test_explicit_args_override_state(self, board_identity):
        assert board_cache.board_key(mac="11:22:33:44:55:66") == "mac-112233445566"


class TestRoundTrip:
    def test_manifest_round_trip(self, cache_root, board_identity):
        assert board_cache.load_manifest() == {"etag": None, "patterns": [], "fetched_at": 0.0}
        board_cache.save_manifest(["a.thr", "sub/b.thr"], "etag-1")
        loaded = board_cache.load_manifest()
        assert loaded["etag"] == "etag-1"
        assert loaded["patterns"] == ["a.thr", "sub/b.thr"]
        assert loaded["fetched_at"] > 0

    def test_playlists_round_trip(self, cache_root, board_identity):
        assert board_cache.load_playlists() == {}
        board_cache.save_playlists({"Evening": ["a.thr", "b.thr"]})
        assert board_cache.load_playlists() == {"Evening": ["a.thr", "b.thr"]}

    def test_two_boards_are_isolated(self, cache_root):
        board_cache.save_manifest(["a.thr"], "e-a", key="mac-aaa")
        board_cache.save_manifest(["b.thr"], "e-b", key="mac-bbb")
        assert board_cache.load_manifest("mac-aaa")["patterns"] == ["a.thr"]
        assert board_cache.load_manifest("mac-bbb")["patterns"] == ["b.thr"]

    def test_no_write_without_identity(self, cache_root, monkeypatch):
        monkeypatch.setattr(state, "board_mac", None, raising=False)
        monkeypatch.setattr(state, "board_hostname", None, raising=False)
        board_cache.save_manifest(["a.thr"], "e")  # no-op, no crash
        assert not cache_root.exists()


class TestSyncBoardCatalog:
    def test_stores_manifest_and_playlists(self, cache_root, board_identity):
        conn = MagicMock()
        conn.get_patterns_manifest.return_value = ("etag-1", ["x.thr", "custom/y.thr"])
        conn.list_playlists.return_value = ["Evening.txt", "Morning"]
        conn.fetch_file.side_effect = lambda p: {
            "/playlists/Evening.txt": b"/patterns/x.thr\n/patterns/custom/y.thr\n",
            "/playlists/Morning.txt": b"/sd/patterns/x.thr\n",
        }[p]

        board_settings.sync_board_catalog(conn)

        assert board_cache.load_manifest()["patterns"] == ["x.thr", "custom/y.thr"]
        # .txt lines are normalized to patterns-relative paths (same as manifest).
        assert board_cache.load_playlists() == {
            "Evening": ["x.thr", "custom/y.thr"],
            "Morning": ["x.thr"],
        }
        # The cached ETag is sent back for revalidation next time.
        conn.get_patterns_manifest.assert_called_once_with(None)

    def test_304_keeps_prior_manifest(self, cache_root, board_identity):
        board_cache.save_manifest(["kept.thr"], "etag-1")
        conn = MagicMock()
        conn.get_patterns_manifest.return_value = ("etag-1", None)  # 304
        conn.list_playlists.return_value = []

        board_settings.sync_board_catalog(conn)

        conn.get_patterns_manifest.assert_called_once_with("etag-1")
        assert board_cache.load_manifest()["patterns"] == ["kept.thr"]

    def test_skips_when_unidentified(self, cache_root, monkeypatch):
        monkeypatch.setattr(state, "board_mac", None, raising=False)
        monkeypatch.setattr(state, "board_hostname", None, raising=False)
        conn = MagicMock()
        board_settings.sync_board_catalog(conn)
        conn.get_patterns_manifest.assert_not_called()

    def test_unreadable_playlist_skipped_not_fatal(self, cache_root, board_identity):
        conn = MagicMock()
        conn.get_patterns_manifest.return_value = ("e", ["x.thr"])
        conn.list_playlists.return_value = ["Good", "Bad"]

        def fetch(path):
            if "Bad" in path:
                raise RuntimeError("gone")
            return b"/patterns/x.thr\n"

        conn.fetch_file.side_effect = fetch
        board_settings.sync_board_catalog(conn)
        assert board_cache.load_playlists() == {"Good": ["x.thr"]}
