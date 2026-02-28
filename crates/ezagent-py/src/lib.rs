use pyo3::prelude::*;
use yrs::{Doc, Map, Transact};

/// TC-PY-001: Verify CRDT map operations work across Python/Rust boundary.
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

/// TC-PY-002: Verify Ed25519 sign/verify works from Python.
#[pyfunction]
fn crypto_sign_verify(message: Vec<u8>) -> PyResult<bool> {
    use ezagent_protocol::{Keypair, PublicKey};
    let keypair = Keypair::generate();
    let signature = keypair.sign(&message);
    let pubkey: PublicKey = keypair.public_key();
    match pubkey.verify(&message, &signature) {
        Ok(()) => Ok(true),
        Err(_) => Ok(false),
    }
}

#[pymodule]
fn _native(m: &Bound<'_, PyModule>) -> PyResult<()> {
    m.add_function(wrap_pyfunction!(crdt_map_roundtrip, m)?)?;
    m.add_function(wrap_pyfunction!(crypto_sign_verify, m)?)?;
    Ok(())
}
