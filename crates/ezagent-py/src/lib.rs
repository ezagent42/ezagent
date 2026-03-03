//! ezagent-py — PyO3 bridge to Rust engine.
//!
//! Minimal Phase 0 verification: CRDT Y.Map roundtrip (TC-PY-001)
//! and Ed25519 sign/verify (TC-PY-002).
//!
//! Phase 3: Full Engine operations API via `PyEngine` (engine_bridge module).

mod engine_bridge;

use pyo3::prelude::*;
use yrs::{Doc, Map, Transact};

/// Insert a key-value pair into a CRDT Y.Map and read it back (TC-PY-001).
///
/// Verifies that yrs CRDT operations work correctly across the
/// Python/Rust FFI boundary.
#[pyfunction]
fn crdt_map_roundtrip(key: String, value: String) -> PyResult<String> {
    let doc = Doc::new();
    let map = doc.get_or_insert_map("test");
    {
        let mut txn = doc.transact_mut();
        map.insert(&mut txn, key.as_str(), value.as_str());
    }
    let txn = doc.transact();
    let result = map
        .get(&txn, &key)
        .map(|v| v.to_string(&txn))
        .ok_or_else(|| pyo3::exceptions::PyValueError::new_err("key not found after insert"))?;
    Ok(result)
}

/// Generate an Ed25519 keypair, sign a message, and verify (TC-PY-002).
///
/// Returns `True` if verification succeeds. Raises `ValueError` on failure.
#[pyfunction]
fn crypto_sign_verify(message: Vec<u8>) -> PyResult<bool> {
    use ezagent_protocol::Keypair;
    let keypair = Keypair::generate();
    let signature = keypair.sign(&message);
    let pubkey = keypair.public_key();
    pubkey
        .verify(&message, &signature)
        .map(|()| true)
        .map_err(|e| pyo3::exceptions::PyValueError::new_err(format!("verification failed: {e}")))
}

#[pymodule]
fn _native(m: &Bound<'_, PyModule>) -> PyResult<()> {
    m.add_function(wrap_pyfunction!(crdt_map_roundtrip, m)?)?;
    m.add_function(wrap_pyfunction!(crypto_sign_verify, m)?)?;
    m.add_class::<engine_bridge::PyEngine>()?;
    m.add_class::<engine_bridge::PyEventReceiver>()?;
    Ok(())
}
