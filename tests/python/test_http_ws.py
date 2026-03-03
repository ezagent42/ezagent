"""Tests for the WebSocket event stream endpoint (Task 25).

Uses FastAPI TestClient WebSocket support for in-process testing.

NOTE: Because ``PyEngine`` is ``unsendable``, the WebSocket handler's
background polling thread creates its own engine via ``get_engine()``.
For these tests to observe events, the engine factory must be shared so
that the polling thread's engine is the *same instance* as the one used
by the HTTP endpoints.  Since ``get_engine`` uses ``threading.local()``,
the background thread gets its own engine, so we cannot directly observe
events from a different thread's engine operations.

For L3 these tests verify:
  - WebSocket connection acceptance
  - WebSocket protocol (connect / disconnect)
  - Event delivery within the same engine instance (via direct test)
"""

import json
import os

import pytest
from fastapi.testclient import TestClient

from ezagent._native import PyEngine
from ezagent.server import app, reset_engine, set_engine_factory


@pytest.fixture(autouse=True)
def _fresh_engine():
    """Ensure a clean engine singleton for each test."""
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


# ------------------------------------------------------------------
# TC-4-WS-001: WebSocket connection acceptance
# ------------------------------------------------------------------


def test_ws_connect_and_disconnect():
    """WebSocket /ws accepts connections and handles disconnect."""
    with TestClient(app) as client:
        with client.websocket_connect("/ws") as ws:
            # Connection was accepted if we get here.
            assert ws is not None
            # Closing the context manager triggers WebSocketDisconnect.


# ------------------------------------------------------------------
# TC-4-WS-002: WebSocket accepts room query parameter
# ------------------------------------------------------------------


def test_ws_connect_with_room_filter():
    """WebSocket /ws?room=<id> accepts connections with room filter."""
    with TestClient(app) as client:
        with client.websocket_connect("/ws?room=test-room") as ws:
            assert ws is not None


# ------------------------------------------------------------------
# TC-4-WS-003: PyEventReceiver direct event delivery
# ------------------------------------------------------------------


def test_event_receiver_delivers_events_directly():
    """PyEventReceiver receives events from the same engine instance."""
    engine = PyEngine()
    engine.identity_init("@alice:relay.example.com", os.urandom(32))

    room_json = engine.room_create("WS-Test")
    room = json.loads(room_json)
    room_id = room["room_id"]

    # Subscribe before sending.
    rx = engine.subscribe_events()

    # Send a message.
    engine.message_send(room_id, '"ws test"', "text/plain")

    # Should receive the event.
    event_json = rx.next_event(2000)
    assert event_json is not None
    event = json.loads(event_json)
    assert event["type"] == "message.new"
    assert event["room_id"] == room_id


# ------------------------------------------------------------------
# TC-4-WS-004: Multiple events delivered in order
# ------------------------------------------------------------------


def test_event_receiver_multiple_events():
    """Multiple events arrive in order."""
    engine = PyEngine()
    engine.identity_init("@alice:relay.example.com", os.urandom(32))

    room_json = engine.room_create("Multi")
    room = json.loads(room_json)
    room_id = room["room_id"]

    rx = engine.subscribe_events()

    # Emit multiple events.
    engine.room_invite(room_id, "@bob:relay.example.com")
    engine.message_send(room_id, '"msg1"', "text/plain")
    engine.message_send(room_id, '"msg2"', "text/plain")

    events = []
    for _ in range(3):
        ej = rx.next_event(1000)
        if ej is not None:
            events.append(json.loads(ej))

    assert len(events) == 3
    assert events[0]["type"] == "room.member_joined"
    assert events[1]["type"] == "message.new"
    assert events[2]["type"] == "message.new"


# ------------------------------------------------------------------
# TC-4-WS-005: Timeout returns None when no events
# ------------------------------------------------------------------


def test_event_receiver_returns_none_on_timeout():
    """next_event returns None when no events arrive within timeout."""
    engine = PyEngine()
    rx = engine.subscribe_events()
    result = rx.next_event(50)
    assert result is None
