"""
Unit tests for pattern API endpoints.

Tests the following endpoints:
- GET /list_theta_rho_files
- GET /list_theta_rho_files_with_metadata
- POST /get_theta_rho_coordinates
- POST /run_theta_rho (when disconnected)
"""
import pytest
from unittest.mock import patch, MagicMock, AsyncMock


class TestListThetaRhoFiles:
    """Tests for /list_theta_rho_files endpoint."""

    @pytest.mark.asyncio
    async def test_list_theta_rho_files(self, async_client):
        """The catalog is the connected board's manifest (board_catalog)."""
        mock_files = ["circle.thr", "spiral.thr", "custom/pattern.thr"]

        with patch("main.pattern_manager.board_catalog", return_value=mock_files):
            response = await async_client.get("/list_theta_rho_files")

        assert response.status_code == 200
        data = response.json()
        assert isinstance(data, list)
        assert len(data) == 3
        assert "circle.thr" in data
        assert "spiral.thr" in data
        assert "custom/pattern.thr" in data

    @pytest.mark.asyncio
    async def test_list_theta_rho_files_empty(self, async_client):
        """Empty when no board has been synced (no manifest cached)."""
        with patch("main.pattern_manager.board_catalog", return_value=[]):
            response = await async_client.get("/list_theta_rho_files")

        assert response.status_code == 200
        data = response.json()
        assert data == []


class TestListThetaRhoFilesWithMetadata:
    """Tests for /list_theta_rho_files_with_metadata endpoint."""

    @pytest.mark.asyncio
    async def test_list_theta_rho_files_with_metadata(self, async_client):
        """Board catalog paths, metadata defaulting to 0 with no local cache."""
        mock_files = ["circle.thr"]

        with patch("main.pattern_manager.board_catalog", return_value=mock_files):
            # No local metadata cache to join — coords/date default to 0.
            with patch("builtins.open", side_effect=FileNotFoundError):
                response = await async_client.get("/list_theta_rho_files_with_metadata")

        assert response.status_code == 200
        data = response.json()
        assert isinstance(data, list)
        assert len(data) == 1

        item = data[0]
        assert item["path"] == "circle.thr"
        assert item["name"] == "circle"
        assert item["category"] == "root"
        assert item["date_modified"] == 0
        assert item["coordinates_count"] == 0


class TestGetThetaRhoCoordinates:
    """Tests for /get_theta_rho_coordinates endpoint."""

    @pytest.mark.asyncio
    async def test_get_theta_rho_coordinates_valid_file(self, async_client, tmp_path):
        """Test getting coordinates from a valid file."""
        # Create test pattern file
        patterns_dir = tmp_path / "patterns"
        patterns_dir.mkdir()
        test_file = patterns_dir / "test.thr"
        test_file.write_text("0.0 0.5\n1.57 0.8\n3.14 0.3\n")

        mock_coordinates = [(0.0, 0.5), (1.57, 0.8), (3.14, 0.3)]

        with patch("main.THETA_RHO_DIR", str(patterns_dir)):
            with patch("main.pattern_manager.resolve_local_path", return_value="test.thr"):
                with patch("main.parse_theta_rho_file", return_value=mock_coordinates):
                    response = await async_client.post(
                        "/get_theta_rho_coordinates",
                        json={"file_name": "test.thr"}
                    )

        assert response.status_code == 200
        data = response.json()
        assert "coordinates" in data
        assert len(data["coordinates"]) == 3
        assert data["coordinates"][0] == [0.0, 0.5]
        assert data["coordinates"][1] == [1.57, 0.8]
        assert data["coordinates"][2] == [3.14, 0.3]

    @pytest.mark.asyncio
    async def test_get_theta_rho_coordinates_file_not_found(self, async_client, tmp_path):
        """Test getting coordinates from non-existent file returns error.

        Note: The endpoint returns 500 because it catches the HTTPException and re-raises it.
        """
        patterns_dir = tmp_path / "patterns"
        patterns_dir.mkdir()

        with patch("main.THETA_RHO_DIR", str(patterns_dir)):
            response = await async_client.post(
                "/get_theta_rho_coordinates",
                json={"file_name": "nonexistent.thr"}
            )

        # The endpoint wraps the 404 in a 500 due to exception handling
        assert response.status_code in [404, 500]
        data = response.json()
        assert "not found" in data["detail"].lower()


class TestRunThetaRho:
    """Tests for /run_theta_rho endpoint."""

    @pytest.mark.asyncio
    async def test_run_theta_rho_when_disconnected(self, async_client, mock_state):
        """A board pattern with no connection fails on the connection check."""
        mock_state.conn = None
        mock_state.is_homing = False

        with patch("main.state", mock_state):
            with patch("main.pattern_manager.is_on_board", return_value=True):
                response = await async_client.post(
                    "/run_theta_rho",
                    json={"file_name": "circle.thr", "pre_execution": "none"},
                )

        assert response.status_code == 400
        data = response.json()
        assert "not established" in data["detail"].lower() or "not connected" in data["detail"].lower()

    @pytest.mark.asyncio
    async def test_run_theta_rho_during_homing(self, async_client, mock_state):
        """Test run_theta_rho fails when homing is in progress."""
        mock_state.is_homing = True
        mock_state.conn = MagicMock()
        mock_state.conn.is_connected.return_value = True

        with patch("main.state", mock_state):
            with patch("main.pattern_manager.is_on_board", return_value=True):
                response = await async_client.post(
                    "/run_theta_rho",
                    json={"file_name": "circle.thr", "pre_execution": "none"},
                )

        assert response.status_code == 409
        data = response.json()
        assert "homing" in data["detail"].lower()

    @pytest.mark.asyncio
    async def test_run_theta_rho_not_on_board(self, async_client, mock_state):
        """A pattern absent from the board's catalog returns 404."""
        mock_state.conn = MagicMock()
        mock_state.conn.is_connected.return_value = True
        mock_state.is_homing = False

        with patch("main.state", mock_state):
            with patch("main.pattern_manager.is_on_board", return_value=False):
                response = await async_client.post(
                    "/run_theta_rho",
                    json={"file_name": "nonexistent.thr", "pre_execution": "none"},
                )

        assert response.status_code == 404
        data = response.json()
        assert "board" in data["detail"].lower()


class TestStopExecution:
    """Tests for /stop_execution endpoint."""

    @pytest.mark.asyncio
    async def test_stop_execution(self, async_client, mock_state):
        """Test stop_execution endpoint."""
        mock_state.is_homing = False
        mock_state.conn = MagicMock()
        mock_state.conn.is_connected.return_value = True

        with patch("main.state", mock_state):
            with patch("main.execution.stop", new_callable=AsyncMock, return_value=True):
                response = await async_client.post("/stop_execution")

        assert response.status_code == 200
        data = response.json()
        assert data["success"] is True

    @pytest.mark.asyncio
    async def test_stop_execution_when_disconnected(self, async_client, mock_state):
        """Test stop_execution fails when not connected."""
        mock_state.conn = None

        with patch("main.state", mock_state):
            response = await async_client.post("/stop_execution")

        assert response.status_code == 400
        data = response.json()
        assert "not established" in data["detail"].lower()


class TestPauseResumeExecution:
    """Tests for /pause_execution and /resume_execution endpoints."""

    @pytest.mark.asyncio
    async def test_pause_execution(self, async_client):
        """Test pause_execution endpoint."""
        with patch("main.execution.get_cached_status", return_value={"is_running": True}):
            with patch("main.execution.pause", new_callable=AsyncMock):
                response = await async_client.post("/pause_execution")

        assert response.status_code == 200
        data = response.json()
        assert data["success"] is True

    @pytest.mark.asyncio
    async def test_pause_execution_when_idle(self, async_client):
        """Test pause_execution returns 400 when nothing is playing."""
        with patch("main.execution.get_cached_status",
                   return_value={"is_running": False, "pause_time_remaining": 0}):
            response = await async_client.post("/pause_execution")

        assert response.status_code == 400
        data = response.json()
        assert "nothing is currently playing" in data["detail"].lower()

    @pytest.mark.asyncio
    async def test_resume_execution(self, async_client):
        """Test resume_execution endpoint."""
        with patch("main.execution.get_cached_status", return_value={"is_paused": True}):
            with patch("main.execution.resume", new_callable=AsyncMock):
                response = await async_client.post("/resume_execution")

        assert response.status_code == 200
        data = response.json()
        assert data["success"] is True

    @pytest.mark.asyncio
    async def test_resume_execution_when_not_paused(self, async_client):
        """Test resume_execution returns 400 when not paused."""
        with patch("main.execution.get_cached_status", return_value={"is_paused": False}):
            response = await async_client.post("/resume_execution")

        assert response.status_code == 400
        data = response.json()
        assert "not paused" in data["detail"].lower()


class TestDeleteThetaRhoFile:
    """Tests for /delete_theta_rho_file endpoint."""

    @pytest.mark.asyncio
    async def test_delete_theta_rho_file_success(self, async_client, tmp_path):
        """Test deleting an existing pattern file."""
        patterns_dir = tmp_path / "patterns"
        patterns_dir.mkdir()
        test_file = patterns_dir / "test.thr"
        test_file.write_text("0 0.5")

        # Must patch pattern_manager.THETA_RHO_DIR which is what the endpoint uses
        with patch("main.pattern_manager.THETA_RHO_DIR", str(patterns_dir)):
            with patch("modules.core.cache_manager.delete_pattern_cache", return_value=True):
                response = await async_client.post(
                    "/delete_theta_rho_file",
                    json={"file_name": "test.thr"}
                )

        assert response.status_code == 200
        data = response.json()
        assert data["success"] is True
        # Verify file was actually deleted
        assert not test_file.exists()

    @pytest.mark.asyncio
    async def test_delete_theta_rho_file_not_found(self, async_client, tmp_path):
        """Test deleting a non-existent file returns error."""
        patterns_dir = tmp_path / "patterns"
        patterns_dir.mkdir()

        with patch("main.pattern_manager.THETA_RHO_DIR", str(patterns_dir)):
            response = await async_client.post(
                "/delete_theta_rho_file",
                json={"file_name": "nonexistent.thr"}
            )

        assert response.status_code == 404
