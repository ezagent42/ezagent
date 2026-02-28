//! In-memory CRDT backend powered by Yrs (Yjs CRDT in Rust).
//!
//! [`YrsBackend`] manages a collection of [`yrs::Doc`] instances keyed
//! by document ID.  Each doc is created with `skip_gc: true` to
//! preserve the full timeline history (bus-spec requirement).

use std::collections::HashMap;
use std::sync::{Arc, RwLock};

use yrs::updates::decoder::Decode;
use yrs::updates::encoder::Encode;
use yrs::{Doc, Options, ReadTxn, StateVector, Transact, Update};

use crate::traits::{BackendError, CrdtBackend};

/// In-memory CRDT backend using Yrs documents.
///
/// Documents are stored in a concurrent `RwLock<HashMap>`, allowing
/// multiple readers for existing docs and exclusive access only when
/// creating new ones.
pub struct YrsBackend {
    docs: RwLock<HashMap<String, Arc<Doc>>>,
}

impl YrsBackend {
    /// Create a new empty backend.
    pub fn new() -> Self {
        Self {
            docs: RwLock::new(HashMap::new()),
        }
    }
}

impl Default for YrsBackend {
    fn default() -> Self {
        Self::new()
    }
}

impl CrdtBackend for YrsBackend {
    fn get_or_create_doc(&self, doc_id: &str) -> Arc<Doc> {
        // Fast path: read lock to check if doc already exists.
        {
            let docs = self.docs.read().expect("docs lock poisoned");
            if let Some(doc) = docs.get(doc_id) {
                return Arc::clone(doc);
            }
        }
        // Slow path: write lock to create the doc.
        let mut docs = self.docs.write().expect("docs lock poisoned");
        // Double-check after acquiring write lock.
        if let Some(doc) = docs.get(doc_id) {
            return Arc::clone(doc);
        }
        let opts = Options {
            skip_gc: true,
            ..Options::default()
        };
        let doc = Arc::new(Doc::with_options(opts));
        docs.insert(doc_id.to_string(), Arc::clone(&doc));
        doc
    }

    fn state_vector(&self, doc_id: &str) -> Result<Vec<u8>, BackendError> {
        let doc = self.get_or_create_doc(doc_id);
        let txn = doc.transact();
        Ok(txn.state_vector().encode_v1())
    }

    fn encode_state(&self, doc_id: &str, sv: Option<&[u8]>) -> Result<Vec<u8>, BackendError> {
        let doc = self.get_or_create_doc(doc_id);
        let txn = doc.transact();
        match sv {
            None => {
                // Full state: encode relative to empty state vector.
                Ok(txn.encode_state_as_update_v1(&StateVector::default()))
            }
            Some(sv_bytes) => {
                // Diff state: decode remote state vector, encode diff.
                let remote_sv = StateVector::decode_v1(sv_bytes)
                    .map_err(|e| BackendError::Serialization(e.to_string()))?;
                Ok(txn.encode_state_as_update_v1(&remote_sv))
            }
        }
    }

    fn apply_update(&self, doc_id: &str, update: &[u8]) -> Result<(), BackendError> {
        // Empty update is a no-op.
        if update.is_empty() {
            return Ok(());
        }
        let doc = self.get_or_create_doc(doc_id);
        let decoded = Update::decode_v1(update).map_err(|e| BackendError::Crdt(e.to_string()))?;
        let mut txn = doc.transact_mut();
        txn.apply_update(decoded)
            .map_err(|e| BackendError::Crdt(e.to_string()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use yrs::{Map, Transact};

    #[test]
    fn get_or_create_returns_same_arc_for_same_id() {
        let backend = YrsBackend::new();
        let doc1 = backend.get_or_create_doc("room-1");
        let doc2 = backend.get_or_create_doc("room-1");
        assert!(Arc::ptr_eq(&doc1, &doc2));
    }

    #[test]
    fn different_ids_return_different_arcs() {
        let backend = YrsBackend::new();
        let doc1 = backend.get_or_create_doc("room-1");
        let doc2 = backend.get_or_create_doc("room-2");
        assert!(!Arc::ptr_eq(&doc1, &doc2));
    }

    #[test]
    fn map_write_state_vector_non_empty() {
        let backend = YrsBackend::new();
        let doc = backend.get_or_create_doc("room-1");
        {
            let map = doc.get_or_insert_map("data");
            let mut txn = doc.transact_mut();
            map.insert(&mut txn, "key", "value");
        }
        let sv = backend.state_vector("room-1").unwrap();
        assert!(
            !sv.is_empty(),
            "state vector should be non-empty after write"
        );
    }

    #[test]
    fn encode_full_state_and_apply_to_second_backend() {
        let backend_a = YrsBackend::new();
        let doc_a = backend_a.get_or_create_doc("room-1");
        {
            let map = doc_a.get_or_insert_map("data");
            let mut txn = doc_a.transact_mut();
            map.insert(&mut txn, "greeting", "hello");
        }

        // Encode full state from backend A.
        let full_state = backend_a.encode_state("room-1", None).unwrap();

        // Apply to backend B.
        let backend_b = YrsBackend::new();
        backend_b.apply_update("room-1", &full_state).unwrap();

        // Verify data arrived.
        let doc_b = backend_b.get_or_create_doc("room-1");
        let map_b = doc_b.get_or_insert_map("data");
        let txn = doc_b.transact();
        let value = map_b.get(&txn, "greeting").unwrap();
        assert_eq!(value.to_string(&txn), "hello");
    }

    #[test]
    fn encode_diff_state_only_transfers_new_data() {
        let backend_a = YrsBackend::new();
        let doc_a = backend_a.get_or_create_doc("room-1");

        // Write initial data.
        {
            let map = doc_a.get_or_insert_map("data");
            let mut txn = doc_a.transact_mut();
            map.insert(&mut txn, "k1", "v1");
        }

        // Sync full state to B.
        let full_state = backend_a.encode_state("room-1", None).unwrap();
        let backend_b = YrsBackend::new();
        backend_b.apply_update("room-1", &full_state).unwrap();

        // Write more data on A.
        {
            let map = doc_a.get_or_insert_map("data");
            let mut txn = doc_a.transact_mut();
            map.insert(&mut txn, "k2", "v2");
        }

        // Get B's state vector and use it to request diff from A.
        let sv_b = backend_b.state_vector("room-1").unwrap();
        let diff = backend_a.encode_state("room-1", Some(&sv_b)).unwrap();

        // The diff should be smaller than the full state (it only contains k2).
        let full_state_after = backend_a.encode_state("room-1", None).unwrap();
        assert!(
            diff.len() < full_state_after.len(),
            "diff ({} bytes) should be smaller than full state ({} bytes)",
            diff.len(),
            full_state_after.len()
        );

        // Apply diff to B and verify both keys exist.
        backend_b.apply_update("room-1", &diff).unwrap();
        let doc_b = backend_b.get_or_create_doc("room-1");
        let map_b = doc_b.get_or_insert_map("data");
        let txn = doc_b.transact();
        assert_eq!(map_b.get(&txn, "k1").unwrap().to_string(&txn), "v1");
        assert_eq!(map_b.get(&txn, "k2").unwrap().to_string(&txn), "v2");
    }

    #[test]
    fn apply_empty_update_is_ok() {
        let backend = YrsBackend::new();
        let result = backend.apply_update("room-1", &[]);
        assert!(result.is_ok());
    }
}
