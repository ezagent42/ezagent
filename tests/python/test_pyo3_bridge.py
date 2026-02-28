from ezagent._native import crdt_map_roundtrip, crypto_sign_verify


def test_crdt_map_roundtrip():
    """TC-PY-001: CRDT map operations across Python/Rust boundary."""
    result = crdt_map_roundtrip("hello", "world")
    assert result == "world"


def test_crdt_map_roundtrip_unicode():
    """TC-PY-001b: CRDT map with unicode values."""
    result = crdt_map_roundtrip("name", "Alice 你好")
    assert result == "Alice 你好"


def test_crypto_sign_verify():
    """TC-PY-002: Ed25519 sign/verify from Python."""
    assert crypto_sign_verify(b"test message") is True


def test_crypto_sign_verify_empty():
    """TC-PY-002b: Sign/verify empty message."""
    assert crypto_sign_verify(b"") is True
