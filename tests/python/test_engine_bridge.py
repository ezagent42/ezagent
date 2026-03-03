"""Tests for the PyEngine PyO3 bridge (Task 13).

These tests verify that the full Engine operations API is correctly
exposed to Python through the PyO3 bindings.
"""

import json
import os

import pytest

from ezagent._native import PyEngine


def test_engine_create():
    """PyEngine can be created."""
    engine = PyEngine()
    assert engine is not None


def test_identity_init_and_whoami():
    """identity_init and identity_whoami round-trip."""
    engine = PyEngine()
    keypair_bytes = os.urandom(32)
    engine.identity_init("@alice:relay.example.com", keypair_bytes)
    assert engine.identity_whoami() == "@alice:relay.example.com"


def test_identity_whoami_before_init():
    """identity_whoami raises before init."""
    engine = PyEngine()
    with pytest.raises(RuntimeError):
        engine.identity_whoami()


def test_identity_init_bad_entity_id():
    """identity_init raises with invalid entity ID."""
    engine = PyEngine()
    with pytest.raises(RuntimeError):
        engine.identity_init("invalid-entity-id", os.urandom(32))


def test_identity_init_bad_keypair_length():
    """identity_init raises when keypair_bytes is not 32 bytes."""
    engine = PyEngine()
    with pytest.raises(RuntimeError, match="32 bytes"):
        engine.identity_init("@alice:relay.example.com", os.urandom(16))


def test_room_create_and_list():
    """room_create and room_list round-trip."""
    engine = PyEngine()
    engine.identity_init("@alice:relay.example.com", os.urandom(32))

    room_json = engine.room_create("Alpha")
    room = json.loads(room_json)
    assert room["name"] == "Alpha"
    assert "room_id" in room

    rooms = engine.room_list()
    assert room["room_id"] in rooms


def test_room_get():
    """room_get returns JSON."""
    engine = PyEngine()
    engine.identity_init("@alice:relay.example.com", os.urandom(32))

    room_json = engine.room_create("Beta")
    room = json.loads(room_json)

    got_json = engine.room_get(room["room_id"])
    got = json.loads(got_json)
    assert got["name"] == "Beta"


def test_room_not_found():
    """room_get raises for non-existent room."""
    engine = PyEngine()
    with pytest.raises(RuntimeError):
        engine.room_get("nonexistent")


def test_message_send_and_timeline():
    """message_send and timeline_list round-trip."""
    engine = PyEngine()
    engine.identity_init("@alice:relay.example.com", os.urandom(32))

    room_json = engine.room_create("Chat")
    room = json.loads(room_json)
    room_id = room["room_id"]

    content_json = engine.message_send(room_id, '"Hello!"', "text/plain")
    content = json.loads(content_json)
    assert len(content["content_id"]) == 64  # SHA-256 hex

    refs = engine.timeline_list(room_id)
    assert len(refs) == 1

    ref_json = engine.timeline_get_ref(room_id, refs[0])
    ref_data = json.loads(ref_json)
    assert ref_data["content_id"] == content["content_id"]


def test_room_invite_and_members():
    """room_invite adds members."""
    engine = PyEngine()
    engine.identity_init("@alice:relay.example.com", os.urandom(32))

    room_json = engine.room_create("Team")
    room = json.loads(room_json)
    room_id = room["room_id"]

    engine.room_invite(room_id, "@bob:relay.example.com")
    members = engine.room_members(room_id)
    assert "@alice:relay.example.com" in members
    assert "@bob:relay.example.com" in members


def test_annotations():
    """annotation_add, annotation_list, annotation_remove."""
    engine = PyEngine()
    engine.identity_init("@alice:relay.example.com", os.urandom(32))

    engine.annotation_add("room-1", "ref-1", "review:@alice", "approved")
    anns = engine.annotation_list("room-1", "ref-1")
    assert len(anns) == 1
    assert "review:@alice=approved" in anns[0]

    engine.annotation_remove("room-1", "ref-1", "review:@alice")
    anns = engine.annotation_list("room-1", "ref-1")
    assert len(anns) == 0


def test_status():
    """status returns tuple of (bool, list)."""
    engine = PyEngine()
    initialized, datatypes = engine.status()
    assert initialized is False
    assert "identity" in datatypes
    assert "room" in datatypes
    assert "timeline" in datatypes
    assert "message" in datatypes


def test_status_after_init():
    """status reports identity_initialized=True after init."""
    engine = PyEngine()
    engine.identity_init("@alice:relay.example.com", os.urandom(32))
    initialized, datatypes = engine.status()
    assert initialized is True
    assert len(datatypes) >= 4


def test_room_update_config():
    """room_update_config modifies room name."""
    engine = PyEngine()
    engine.identity_init("@alice:relay.example.com", os.urandom(32))

    room_json = engine.room_create("Old Name")
    room = json.loads(room_json)
    room_id = room["room_id"]

    engine.room_update_config(room_id, '{"name": "New Name"}')
    got = json.loads(engine.room_get(room_id))
    assert got["name"] == "New Name"


def test_room_update_config_invalid_json():
    """room_update_config raises on invalid JSON."""
    engine = PyEngine()
    engine.identity_init("@alice:relay.example.com", os.urandom(32))

    room_json = engine.room_create("Test")
    room = json.loads(room_json)
    room_id = room["room_id"]

    with pytest.raises(RuntimeError, match="invalid JSON"):
        engine.room_update_config(room_id, "not-json")


def test_room_join_leave():
    """room_join and room_leave."""
    engine = PyEngine()
    engine.identity_init("@alice:relay.example.com", os.urandom(32))

    room_json = engine.room_create("Club")
    room = json.loads(room_json)
    room_id = room["room_id"]

    engine.room_leave(room_id)
    members = engine.room_members(room_id)
    assert len(members) == 0

    engine.room_join(room_id)
    members = engine.room_members(room_id)
    assert "@alice:relay.example.com" in members


def test_message_delete():
    """message_delete on existing ref succeeds."""
    engine = PyEngine()
    engine.identity_init("@alice:relay.example.com", os.urandom(32))

    room_json = engine.room_create("Del")
    room = json.loads(room_json)
    room_id = room["room_id"]

    engine.message_send(room_id, '"test"', "text/plain")
    refs = engine.timeline_list(room_id)
    assert len(refs) == 1

    engine.message_delete(room_id, refs[0])  # should not raise


def test_message_delete_nonexistent():
    """message_delete on non-existent ref raises."""
    engine = PyEngine()
    with pytest.raises(RuntimeError):
        engine.message_delete("room", "nonexistent-ref")


def test_identity_get_pubkey():
    """identity_get_pubkey returns hex-encoded key."""
    engine = PyEngine()
    engine.identity_init("@alice:relay.example.com", os.urandom(32))

    pubkey = engine.identity_get_pubkey("@alice:relay.example.com")
    assert len(pubkey) == 64  # 32 bytes hex-encoded
    assert all(c in "0123456789abcdef" for c in pubkey)


def test_identity_get_pubkey_not_found():
    """identity_get_pubkey raises for unknown entity."""
    engine = PyEngine()
    with pytest.raises(RuntimeError):
        engine.identity_get_pubkey("@unknown:relay.example.com")


def test_message_send_invalid_body_json():
    """message_send raises on invalid body JSON."""
    engine = PyEngine()
    engine.identity_init("@alice:relay.example.com", os.urandom(32))

    room_json = engine.room_create("Bad")
    room = json.loads(room_json)
    room_id = room["room_id"]

    with pytest.raises(RuntimeError, match="invalid body JSON"):
        engine.message_send(room_id, "not valid json {{{", "text/plain")


def test_room_create_before_identity_init():
    """room_create raises before identity init."""
    engine = PyEngine()
    with pytest.raises(RuntimeError):
        engine.room_create("NoIdentity")


def test_annotation_remove_nonexistent():
    """annotation_remove raises for non-existent key."""
    engine = PyEngine()
    with pytest.raises(RuntimeError):
        engine.annotation_remove("room", "ref", "nonexistent-key")


def test_multiple_rooms():
    """Multiple rooms can be created and listed."""
    engine = PyEngine()
    engine.identity_init("@alice:relay.example.com", os.urandom(32))

    room1 = json.loads(engine.room_create("Room 1"))
    room2 = json.loads(engine.room_create("Room 2"))
    room3 = json.loads(engine.room_create("Room 3"))

    rooms = engine.room_list()
    assert len(rooms) == 3
    assert room1["room_id"] in rooms
    assert room2["room_id"] in rooms
    assert room3["room_id"] in rooms


def test_timeline_get_ref_nonexistent():
    """timeline_get_ref raises for non-existent ref."""
    engine = PyEngine()
    with pytest.raises(RuntimeError):
        engine.timeline_get_ref("room", "nonexistent-ref")


# ---------------------------------------------------------------------------
# EventStream / PyEventReceiver tests (Task 24)
# ---------------------------------------------------------------------------


def test_subscribe_events():
    """subscribe_events returns a PyEventReceiver."""
    engine = PyEngine()
    engine.identity_init("@alice:relay.example.com", os.urandom(32))
    rx = engine.subscribe_events()
    assert rx is not None


def test_event_receiver_timeout():
    """next_event returns None on timeout (no events)."""
    engine = PyEngine()
    rx = engine.subscribe_events()
    # Short timeout since no events will arrive.
    result = rx.next_event(100)
    assert result is None


def test_event_on_message_send():
    """message_send emits a message.new event."""
    engine = PyEngine()
    engine.identity_init("@alice:relay.example.com", os.urandom(32))

    room_json = engine.room_create("Chat")
    room = json.loads(room_json)
    room_id = room["room_id"]

    # Subscribe BEFORE sending.
    rx = engine.subscribe_events()

    # Send a message.
    engine.message_send(room_id, '"Hello!"', "text/plain")

    # Should receive the event.
    event_json = rx.next_event(1000)
    assert event_json is not None
    event = json.loads(event_json)
    assert event["type"] == "message.new"
    assert event["room_id"] == room_id
    assert event["author"] == "@alice:relay.example.com"


def test_event_on_room_invite():
    """room_invite emits a room.member_joined event."""
    engine = PyEngine()
    engine.identity_init("@alice:relay.example.com", os.urandom(32))

    room_json = engine.room_create("Team")
    room = json.loads(room_json)
    room_id = room["room_id"]

    rx = engine.subscribe_events()

    engine.room_invite(room_id, "@bob:relay.example.com")

    event_json = rx.next_event(1000)
    assert event_json is not None
    event = json.loads(event_json)
    assert event["type"] == "room.member_joined"
    assert event["room_id"] == room_id
    assert event["entity_id"] == "@bob:relay.example.com"


def test_event_on_room_join():
    """room_join emits a room.member_joined event."""
    engine = PyEngine()
    engine.identity_init("@alice:relay.example.com", os.urandom(32))

    room_json = engine.room_create("Club")
    room = json.loads(room_json)
    room_id = room["room_id"]

    # Leave first so we can join.
    engine.room_leave(room_id)

    rx = engine.subscribe_events()
    engine.room_join(room_id)

    event_json = rx.next_event(1000)
    assert event_json is not None
    event = json.loads(event_json)
    assert event["type"] == "room.member_joined"
    assert event["entity_id"] == "@alice:relay.example.com"


def test_event_on_room_leave():
    """room_leave emits a room.member_left event."""
    engine = PyEngine()
    engine.identity_init("@alice:relay.example.com", os.urandom(32))

    room_json = engine.room_create("Club")
    room = json.loads(room_json)
    room_id = room["room_id"]

    rx = engine.subscribe_events()
    engine.room_leave(room_id)

    event_json = rx.next_event(1000)
    assert event_json is not None
    event = json.loads(event_json)
    assert event["type"] == "room.member_left"
    assert event["entity_id"] == "@alice:relay.example.com"


def test_event_on_message_delete():
    """message_delete emits a message.deleted event."""
    engine = PyEngine()
    engine.identity_init("@alice:relay.example.com", os.urandom(32))

    room_json = engine.room_create("Del")
    room = json.loads(room_json)
    room_id = room["room_id"]

    engine.message_send(room_id, '"test"', "text/plain")
    refs = engine.timeline_list(room_id)
    assert len(refs) == 1
    ref_id = refs[0]

    rx = engine.subscribe_events()
    engine.message_delete(room_id, ref_id)

    event_json = rx.next_event(1000)
    assert event_json is not None
    event = json.loads(event_json)
    assert event["type"] == "message.deleted"
    assert event["room_id"] == room_id
    assert event["ref_id"] == ref_id
