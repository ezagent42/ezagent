"""Tests for the Bus API HTTP endpoints (Tasks 15-19).

Covers identity pubkey, rooms CRUD, room membership, messages CRUD,
and annotations CRUD.

Uses the same engine injection pattern as test_http_scaffold.py:
``set_engine_factory`` provides a factory that creates a pre-configured
``PyEngine`` with identity on the handler thread (preserving PyO3
thread-affinity).

IMPORTANT: ``TestClient`` must be used as a **context manager** so that
Starlette pins a single portal thread for all requests in the session.
Without the context manager, ``anyio`` may dispatch each request to a
different worker thread, breaking both ``threading.local()`` persistence
and PyO3 thread-affinity for ``unsendable`` classes.
"""

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


@pytest.fixture()
def client():
    """Provide a TestClient within a context manager for thread pinning."""
    with TestClient(app) as c:
        yield c


# ------------------------------------------------------------------
# Task 15: Identity (TC-4-HTTP-001~003)
# ------------------------------------------------------------------


def test_tc_4_http_002_get_pubkey(client):
    """GET /api/identity/{entity_id}/pubkey returns hex-encoded Ed25519 key."""
    set_engine_factory(_make_initialized_factory())
    response = client.get("/api/identity/@alice:relay.example.com/pubkey")
    assert response.status_code == 200
    data = response.json()
    assert "pubkey" in data
    assert len(data["pubkey"]) == 64
    assert all(c in "0123456789abcdef" for c in data["pubkey"])


def test_tc_4_http_003_get_pubkey_not_found(client):
    """GET /api/identity/{entity_id}/pubkey returns 404 for unknown entity."""
    set_engine_factory(_make_initialized_factory())
    response = client.get("/api/identity/@unknown:relay.example.com/pubkey")
    assert response.status_code == 404


# ------------------------------------------------------------------
# Task 16: Rooms (TC-4-HTTP-010~013)
# ------------------------------------------------------------------


def test_tc_4_http_010_create_room(client):
    """POST /api/rooms creates a room and returns 201 with room JSON."""
    set_engine_factory(_make_initialized_factory())
    response = client.post("/api/rooms", json={"name": "new-room"})
    assert response.status_code == 201
    data = response.json()
    assert "room_id" in data
    assert data["name"] == "new-room"


def test_tc_4_http_011_list_rooms(client):
    """GET /api/rooms returns a list of room objects."""
    set_engine_factory(_make_initialized_factory())
    # Create a room first
    client.post("/api/rooms", json={"name": "room-1"})
    response = client.get("/api/rooms")
    assert response.status_code == 200
    data = response.json()
    assert isinstance(data, list)
    assert len(data) >= 1
    assert data[0]["name"] == "room-1"


def test_tc_4_http_011_list_rooms_empty(client):
    """GET /api/rooms returns an empty list when no rooms exist."""
    set_engine_factory(_make_initialized_factory())
    response = client.get("/api/rooms")
    assert response.status_code == 200
    data = response.json()
    assert isinstance(data, list)
    assert len(data) == 0


def test_tc_4_http_011_list_rooms_multiple(client):
    """GET /api/rooms returns all rooms."""
    set_engine_factory(_make_initialized_factory())
    client.post("/api/rooms", json={"name": "room-a"})
    client.post("/api/rooms", json={"name": "room-b"})
    client.post("/api/rooms", json={"name": "room-c"})
    response = client.get("/api/rooms")
    assert response.status_code == 200
    data = response.json()
    assert len(data) == 3
    names = {r["name"] for r in data}
    assert names == {"room-a", "room-b", "room-c"}


def test_tc_4_http_012_get_room(client):
    """GET /api/rooms/{room_id} returns room details."""
    set_engine_factory(_make_initialized_factory())
    create_resp = client.post("/api/rooms", json={"name": "show-room"})
    room_id = create_resp.json()["room_id"]
    response = client.get(f"/api/rooms/{room_id}")
    assert response.status_code == 200
    assert response.json()["name"] == "show-room"


def test_tc_4_http_012_get_room_not_found(client):
    """GET /api/rooms/{room_id} returns 404 for non-existent room."""
    set_engine_factory(_make_initialized_factory())
    response = client.get("/api/rooms/nonexistent")
    assert response.status_code == 404


def test_tc_4_http_013_patch_room(client):
    """PATCH /api/rooms/{room_id} updates the room name."""
    set_engine_factory(_make_initialized_factory())
    create_resp = client.post("/api/rooms", json={"name": "old-name"})
    room_id = create_resp.json()["room_id"]
    response = client.patch(f"/api/rooms/{room_id}", json={"name": "new-name"})
    assert response.status_code == 200
    assert response.json()["name"] == "new-name"


def test_tc_4_http_013_patch_room_not_found(client):
    """PATCH /api/rooms/{room_id} returns 404 for non-existent room."""
    set_engine_factory(_make_initialized_factory())
    response = client.patch("/api/rooms/nonexistent", json={"name": "x"})
    assert response.status_code == 404


# ------------------------------------------------------------------
# Task 17: Room Membership (TC-4-HTTP-014~015)
# ------------------------------------------------------------------


def test_tc_4_http_014_invite_and_members(client):
    """POST /api/rooms/{room_id}/invite adds a member."""
    set_engine_factory(_make_initialized_factory())
    create_resp = client.post("/api/rooms", json={"name": "team"})
    room_id = create_resp.json()["room_id"]

    invite_resp = client.post(
        f"/api/rooms/{room_id}/invite",
        json={"entity_id": "@bob:relay.example.com"},
    )
    assert invite_resp.status_code == 200
    assert invite_resp.json()["status"] == "ok"

    members_resp = client.get(f"/api/rooms/{room_id}/members")
    assert members_resp.status_code == 200
    members = members_resp.json()["members"]
    assert "@alice:relay.example.com" in members
    assert "@bob:relay.example.com" in members


def test_tc_4_http_014_members_list(client):
    """GET /api/rooms/{room_id}/members returns member list."""
    set_engine_factory(_make_initialized_factory())
    create_resp = client.post("/api/rooms", json={"name": "solo"})
    room_id = create_resp.json()["room_id"]

    members_resp = client.get(f"/api/rooms/{room_id}/members")
    assert members_resp.status_code == 200
    members = members_resp.json()["members"]
    assert "@alice:relay.example.com" in members


def test_tc_4_http_015_join_and_leave(client):
    """POST join/leave modifies room membership."""
    set_engine_factory(_make_initialized_factory())
    create_resp = client.post("/api/rooms", json={"name": "club"})
    room_id = create_resp.json()["room_id"]

    # Leave
    leave_resp = client.post(f"/api/rooms/{room_id}/leave")
    assert leave_resp.status_code == 200
    assert leave_resp.json()["status"] == "ok"

    members = client.get(f"/api/rooms/{room_id}/members").json()["members"]
    assert len(members) == 0

    # Rejoin
    join_resp = client.post(f"/api/rooms/{room_id}/join")
    assert join_resp.status_code == 200
    assert join_resp.json()["status"] == "ok"

    members = client.get(f"/api/rooms/{room_id}/members").json()["members"]
    assert "@alice:relay.example.com" in members


# ------------------------------------------------------------------
# Task 18: Messages (TC-4-HTTP-020~024)
# ------------------------------------------------------------------


def test_tc_4_http_020_send_message(client):
    """POST /api/rooms/{room_id}/messages sends a message and returns 201."""
    set_engine_factory(_make_initialized_factory())
    create_resp = client.post("/api/rooms", json={"name": "chat"})
    room_id = create_resp.json()["room_id"]

    msg_resp = client.post(
        f"/api/rooms/{room_id}/messages",
        json={"body": "Hello!", "format": "text/plain"},
    )
    assert msg_resp.status_code == 201
    data = msg_resp.json()
    assert "content_id" in data
    assert len(data["content_id"]) == 64


def test_tc_4_http_020_send_message_default_format(client):
    """POST /api/rooms/{room_id}/messages defaults format to text/plain."""
    set_engine_factory(_make_initialized_factory())
    create_resp = client.post("/api/rooms", json={"name": "chat"})
    room_id = create_resp.json()["room_id"]

    msg_resp = client.post(
        f"/api/rooms/{room_id}/messages",
        json={"body": "No format specified"},
    )
    assert msg_resp.status_code == 201
    assert "content_id" in msg_resp.json()


def test_tc_4_http_021_list_messages(client):
    """GET /api/rooms/{room_id}/messages lists timeline refs."""
    set_engine_factory(_make_initialized_factory())
    create_resp = client.post("/api/rooms", json={"name": "chat"})
    room_id = create_resp.json()["room_id"]

    client.post(f"/api/rooms/{room_id}/messages", json={"body": "msg1"})
    client.post(f"/api/rooms/{room_id}/messages", json={"body": "msg2"})

    response = client.get(f"/api/rooms/{room_id}/messages")
    assert response.status_code == 200
    data = response.json()
    assert len(data) == 2


def test_tc_4_http_021_list_messages_with_limit(client):
    """GET /api/rooms/{room_id}/messages?limit=N limits results."""
    set_engine_factory(_make_initialized_factory())
    create_resp = client.post("/api/rooms", json={"name": "chat"})
    room_id = create_resp.json()["room_id"]

    for i in range(5):
        client.post(f"/api/rooms/{room_id}/messages", json={"body": f"msg{i}"})

    response = client.get(f"/api/rooms/{room_id}/messages?limit=3")
    assert response.status_code == 200
    assert len(response.json()) == 3


def test_tc_4_http_021_list_messages_empty(client):
    """GET /api/rooms/{room_id}/messages returns empty list for empty room."""
    set_engine_factory(_make_initialized_factory())
    create_resp = client.post("/api/rooms", json={"name": "empty"})
    room_id = create_resp.json()["room_id"]

    response = client.get(f"/api/rooms/{room_id}/messages")
    assert response.status_code == 200
    assert response.json() == []


def test_tc_4_http_022_get_message(client):
    """GET /api/rooms/{room_id}/messages/{ref_id} returns ref details."""
    set_engine_factory(_make_initialized_factory())
    create_resp = client.post("/api/rooms", json={"name": "chat"})
    room_id = create_resp.json()["room_id"]

    client.post(f"/api/rooms/{room_id}/messages", json={"body": "Hello!"})
    messages = client.get(f"/api/rooms/{room_id}/messages").json()
    ref_id = messages[0]["ref_id"]

    response = client.get(f"/api/rooms/{room_id}/messages/{ref_id}")
    assert response.status_code == 200
    assert response.json()["ref_id"] == ref_id


def test_tc_4_http_022_get_message_not_found(client):
    """GET /api/rooms/{room_id}/messages/{ref_id} returns 404 for unknown ref."""
    set_engine_factory(_make_initialized_factory())
    response = client.get("/api/rooms/some-room/messages/nonexistent-ref")
    assert response.status_code == 404


def test_tc_4_http_023_delete_message(client):
    """DELETE /api/rooms/{room_id}/messages/{ref_id} returns 204."""
    set_engine_factory(_make_initialized_factory())
    create_resp = client.post("/api/rooms", json={"name": "chat"})
    room_id = create_resp.json()["room_id"]

    client.post(f"/api/rooms/{room_id}/messages", json={"body": "Delete me"})
    messages = client.get(f"/api/rooms/{room_id}/messages").json()
    ref_id = messages[0]["ref_id"]

    response = client.delete(f"/api/rooms/{room_id}/messages/{ref_id}")
    assert response.status_code == 204


def test_tc_4_http_023_delete_message_not_found(client):
    """DELETE /api/rooms/{room_id}/messages/{ref_id} returns 404 for unknown ref."""
    set_engine_factory(_make_initialized_factory())
    response = client.delete("/api/rooms/some-room/messages/nonexistent-ref")
    assert response.status_code == 404


# ------------------------------------------------------------------
# Task 19: Annotations (TC-4-HTTP-030~032)
# ------------------------------------------------------------------


def test_tc_4_http_030_add_annotation(client):
    """POST .../annotations adds annotation and returns 201."""
    set_engine_factory(_make_initialized_factory())
    create_resp = client.post("/api/rooms", json={"name": "anno"})
    room_id = create_resp.json()["room_id"]

    client.post(f"/api/rooms/{room_id}/messages", json={"body": "test"})
    messages = client.get(f"/api/rooms/{room_id}/messages").json()
    ref_id = messages[0]["ref_id"]

    response = client.post(
        f"/api/rooms/{room_id}/messages/{ref_id}/annotations",
        json={"key": "review:@alice", "value": "approved"},
    )
    assert response.status_code == 201
    assert response.json()["status"] == "ok"


def test_tc_4_http_031_list_annotations(client):
    """GET .../annotations returns parsed key-value pairs."""
    set_engine_factory(_make_initialized_factory())
    create_resp = client.post("/api/rooms", json={"name": "anno"})
    room_id = create_resp.json()["room_id"]

    client.post(f"/api/rooms/{room_id}/messages", json={"body": "test"})
    messages = client.get(f"/api/rooms/{room_id}/messages").json()
    ref_id = messages[0]["ref_id"]

    client.post(
        f"/api/rooms/{room_id}/messages/{ref_id}/annotations",
        json={"key": "review:@alice", "value": "approved"},
    )

    response = client.get(
        f"/api/rooms/{room_id}/messages/{ref_id}/annotations"
    )
    assert response.status_code == 200
    anns = response.json()
    assert len(anns) == 1
    assert anns[0]["key"] == "review:@alice"
    assert anns[0]["value"] == "approved"


def test_tc_4_http_031_list_annotations_empty(client):
    """GET .../annotations returns empty list when no annotations exist."""
    set_engine_factory(_make_initialized_factory())
    create_resp = client.post("/api/rooms", json={"name": "anno"})
    room_id = create_resp.json()["room_id"]

    client.post(f"/api/rooms/{room_id}/messages", json={"body": "test"})
    messages = client.get(f"/api/rooms/{room_id}/messages").json()
    ref_id = messages[0]["ref_id"]

    response = client.get(
        f"/api/rooms/{room_id}/messages/{ref_id}/annotations"
    )
    assert response.status_code == 200
    assert response.json() == []


def test_tc_4_http_031_list_annotations_multiple(client):
    """GET .../annotations returns all annotations."""
    set_engine_factory(_make_initialized_factory())
    create_resp = client.post("/api/rooms", json={"name": "anno"})
    room_id = create_resp.json()["room_id"]

    client.post(f"/api/rooms/{room_id}/messages", json={"body": "test"})
    messages = client.get(f"/api/rooms/{room_id}/messages").json()
    ref_id = messages[0]["ref_id"]

    client.post(
        f"/api/rooms/{room_id}/messages/{ref_id}/annotations",
        json={"key": "review:@alice", "value": "approved"},
    )
    client.post(
        f"/api/rooms/{room_id}/messages/{ref_id}/annotations",
        json={"key": "priority", "value": "high"},
    )

    response = client.get(
        f"/api/rooms/{room_id}/messages/{ref_id}/annotations"
    )
    assert response.status_code == 200
    anns = response.json()
    assert len(anns) == 2
    keys = {a["key"] for a in anns}
    assert keys == {"review:@alice", "priority"}


def test_tc_4_http_032_delete_annotation(client):
    """DELETE .../annotations/{key} removes annotation and returns 204."""
    set_engine_factory(_make_initialized_factory())
    create_resp = client.post("/api/rooms", json={"name": "anno"})
    room_id = create_resp.json()["room_id"]

    client.post(f"/api/rooms/{room_id}/messages", json={"body": "test"})
    messages = client.get(f"/api/rooms/{room_id}/messages").json()
    ref_id = messages[0]["ref_id"]

    client.post(
        f"/api/rooms/{room_id}/messages/{ref_id}/annotations",
        json={"key": "review:@alice", "value": "approved"},
    )

    response = client.delete(
        f"/api/rooms/{room_id}/messages/{ref_id}/annotations/review:@alice"
    )
    assert response.status_code == 204

    # Verify it's gone
    anns = client.get(
        f"/api/rooms/{room_id}/messages/{ref_id}/annotations"
    ).json()
    assert len(anns) == 0


def test_tc_4_http_032_delete_annotation_not_found(client):
    """DELETE .../annotations/{key} returns 404 for non-existent key."""
    set_engine_factory(_make_initialized_factory())
    response = client.delete(
        "/api/rooms/room-1/messages/ref-1/annotations/nonexistent-key"
    )
    assert response.status_code == 404
