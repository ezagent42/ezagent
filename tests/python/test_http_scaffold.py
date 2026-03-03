"""Tests for the FastAPI HTTP server scaffold (Task 14).

Uses FastAPI TestClient for in-process testing.

Because ``PyEngine`` is a PyO3 ``unsendable`` class it must be created
and used on the same OS thread.  ``TestClient`` dispatches synchronous
endpoint handlers to a portal thread, so we cannot create a ``PyEngine``
on the *test* thread and hand it to the handler.  Instead we use
``set_engine_factory`` to supply a factory that will be called lazily on
the handler thread -- this keeps thread-affinity intact.
"""

import os

import pytest
from fastapi.testclient import TestClient

from ezagent._native import PyEngine
from ezagent.server import app, reset_engine, set_engine_factory


@pytest.fixture(autouse=True)
def _fresh_engine():
    """Ensure a clean engine singleton for each test.

    ``reset_engine`` drops the thread-local engine on the *test* thread.
    Because the TestClient's portal thread is reused, we also install a
    ``None`` factory so ``get_engine`` creates a fresh bare engine on
    the next request.
    """
    set_engine_factory(None)
    reset_engine()
    yield
    set_engine_factory(None)
    reset_engine()


def _make_initialized_factory():
    """Return a factory that creates a PyEngine with identity already set up."""

    def factory() -> PyEngine:
        engine = PyEngine()
        engine.identity_init("@alice:relay.example.com", os.urandom(32))
        return engine

    return factory


client = TestClient(app)


# ------------------------------------------------------------------
# /api/status
# ------------------------------------------------------------------

def test_status_endpoint():
    """GET /api/status returns 200 with status info."""
    response = client.get("/api/status")
    assert response.status_code == 200
    data = response.json()
    assert data["status"] == "ok"
    assert "identity_initialized" in data
    assert "registered_datatypes" in data


def test_status_before_identity_init():
    """GET /api/status works even without identity."""
    response = client.get("/api/status")
    assert response.status_code == 200
    assert response.json()["identity_initialized"] is False


def test_status_after_identity_init():
    """GET /api/status reflects initialized identity."""
    set_engine_factory(_make_initialized_factory())
    response = client.get("/api/status")
    assert response.status_code == 200
    assert response.json()["identity_initialized"] is True


# ------------------------------------------------------------------
# /api/identity
# ------------------------------------------------------------------

def test_identity_endpoint():
    """GET /api/identity returns entity_id when initialized."""
    set_engine_factory(_make_initialized_factory())
    response = client.get("/api/identity")
    assert response.status_code == 200
    data = response.json()
    assert data["entity_id"] == "@alice:relay.example.com"


def test_identity_endpoint_unauthorized():
    """GET /api/identity returns 401 when not initialized."""
    response = client.get("/api/identity")
    assert response.status_code == 401
