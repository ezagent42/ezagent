"""Tests for HTTP error handling (Task 23, TC-4-HTTP-070~074)."""

import os

import pytest
from fastapi.testclient import TestClient

from ezagent._native import PyEngine
from ezagent.server import app, reset_engine, set_engine_factory


@pytest.fixture(autouse=True)
def _fresh_engine():
    set_engine_factory(None)
    reset_engine()
    yield
    set_engine_factory(None)
    reset_engine()


def _make_initialized_factory():
    def factory() -> PyEngine:
        engine = PyEngine()
        engine.identity_init("@alice:relay.example.com", os.urandom(32))
        return engine

    return factory


# TC-4-HTTP-070: 400 Bad Request - missing required params
def test_tc_4_http_070_invalid_params():
    """POST /api/rooms with empty body returns 422 (FastAPI validation)."""
    set_engine_factory(_make_initialized_factory())
    with TestClient(app) as client:
        response = client.post("/api/rooms", json={})
        assert response.status_code == 422  # FastAPI returns 422 for validation errors


def test_tc_4_http_070b_missing_body():
    """POST /api/rooms without JSON body returns 422."""
    set_engine_factory(_make_initialized_factory())
    with TestClient(app) as client:
        response = client.post("/api/rooms")
        assert response.status_code == 422


# TC-4-HTTP-071: 401 Unauthorized
def test_tc_4_http_071_unauthorized():
    """GET /api/identity without init returns 401."""
    with TestClient(app) as client:
        response = client.get("/api/identity")
        assert response.status_code == 401


# TC-4-HTTP-072: 404 Not Found
def test_tc_4_http_072_not_found():
    """GET /api/rooms/nonexistent returns 404."""
    set_engine_factory(_make_initialized_factory())
    with TestClient(app) as client:
        response = client.get("/api/rooms/00000000-0000-0000-0000-000000000000")
        assert response.status_code == 404
        data = response.json()
        assert "error" in data["detail"]
        assert data["detail"]["error"]["code"] == "NOT_FOUND"


# TC-4-HTTP-073: 409 Conflict - we test the error format
# Note: The engine doesn't have a direct "conflict" error, so we test the
# standard error format using a 404 scenario.
def test_tc_4_http_073_error_format():
    """Error responses follow the standard format."""
    set_engine_factory(_make_initialized_factory())
    with TestClient(app) as client:
        response = client.get("/api/rooms/nonexistent")
        assert response.status_code == 404
        detail = response.json()["detail"]
        assert "error" in detail
        assert "code" in detail["error"]
        assert "message" in detail["error"]


# TC-4-HTTP-074: GET /api/status
def test_tc_4_http_074_status():
    """GET /api/status returns 200 with expected fields."""
    set_engine_factory(_make_initialized_factory())
    with TestClient(app) as client:
        response = client.get("/api/status")
        assert response.status_code == 200
        data = response.json()
        assert data["status"] == "ok"
        assert data["identity_initialized"] is True
        assert "registered_datatypes" in data


# Extension stubs return 501
def test_extension_stubs_return_501():
    """Extension endpoints return 501 Not Implemented."""
    with TestClient(app) as client:
        # EXT-01
        response = client.put("/api/rooms/room1/messages/ref1")
        assert response.status_code == 501

        # EXT-03
        response = client.post("/api/rooms/room1/messages/ref1/reactions")
        assert response.status_code == 501

        # EXT-06
        response = client.get("/api/channels")
        assert response.status_code == 501

        # EXT-10
        response = client.post("/api/blobs")
        assert response.status_code == 501

        # Render
        response = client.get("/api/renderers")
        assert response.status_code == 501


def test_extension_stub_error_format():
    """Extension 501 responses have standard error format."""
    with TestClient(app) as client:
        response = client.get("/api/renderers")
        assert response.status_code == 501
        detail = response.json()["detail"]
        assert detail["error"]["code"] == "NOT_IMPLEMENTED"
