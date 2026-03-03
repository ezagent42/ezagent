//! RocksDB-backed CRDT persistence backend.
//!
//! [`RocksDbBackend`] implements [`CrdtBackend`] using RocksDB with four
//! column families:
//!
//! | Column Family      | Purpose                                         |
//! |--------------------|-------------------------------------------------|
//! | `docs`             | `doc_id → yrs` state bytes (full snapshot)      |
//! | `pending_updates`  | `doc_id → Vec<serialized update>`               |
//! | `blobs`            | `sha256_hash → binary content`                  |
//! | `meta`             | `doc_id → metadata` (update count, last snap)   |
//!
//! On startup, existing docs are loaded from the `docs` CF and any
//! pending updates from `pending_updates` are re-applied.  Every 100
//! updates, a snapshot compaction merges pending updates into the
//! base state and clears the pending queue.

use std::collections::HashMap;
use std::path::Path;
use std::sync::{Arc, RwLock};

use rocksdb::{ColumnFamilyDescriptor, Options, DB};
use yrs::updates::decoder::Decode;
use yrs::updates::encoder::Encode;
use yrs::{Doc, ReadTxn, StateVector, Transact, Update};

use crate::traits::{BackendError, CrdtBackend};

/// Number of pending updates before a snapshot compaction is triggered.
const SNAPSHOT_THRESHOLD: u64 = 100;

/// Column family names.
const CF_DOCS: &str = "docs";
const CF_PENDING: &str = "pending_updates";
const CF_BLOBS: &str = "blobs";
const CF_META: &str = "meta";

/// Metadata stored per document in the `meta` column family.
///
/// Serialized as JSON for simplicity and debuggability.
#[derive(serde::Serialize, serde::Deserialize, Debug, Clone, Default)]
struct DocMeta {
    update_count: u64,
    last_snapshot_time: u64,
}

/// RocksDB-backed persistent CRDT backend.
///
/// Documents are loaded into memory on startup.  All CRDT operations
/// happen in-memory for speed, with updates persisted to RocksDB for
/// durability.  A snapshot compaction merges pending updates into a
/// single base state every [`SNAPSHOT_THRESHOLD`] updates.
pub struct RocksDbBackend {
    db: Arc<DB>,
    /// In-memory CRDT docs (loaded from disk + pending updates applied).
    docs: RwLock<HashMap<String, Arc<Doc>>>,
    /// Track update counts for snapshot decisions.
    update_counts: RwLock<HashMap<String, u64>>,
}

impl RocksDbBackend {
    /// Open (or create) a RocksDB-backed persistence backend at `path`.
    ///
    /// On open, all existing documents are restored from the `docs`
    /// column family and any pending updates are re-applied.
    pub fn open(path: impl AsRef<Path>) -> Result<Self, BackendError> {
        let mut db_opts = Options::default();
        db_opts.create_if_missing(true);
        db_opts.create_missing_column_families(true);

        let cf_descriptors = vec![
            ColumnFamilyDescriptor::new(CF_DOCS, Options::default()),
            ColumnFamilyDescriptor::new(CF_PENDING, Options::default()),
            ColumnFamilyDescriptor::new(CF_BLOBS, Options::default()),
            ColumnFamilyDescriptor::new(CF_META, Options::default()),
        ];

        let db = DB::open_cf_descriptors(&db_opts, path.as_ref(), cf_descriptors)
            .map_err(|e| BackendError::Crdt(format!("failed to open RocksDB: {e}")))?;

        let db = Arc::new(db);
        let mut docs_map: HashMap<String, Arc<Doc>> = HashMap::new();
        let mut update_counts_map: HashMap<String, u64> = HashMap::new();

        // Load existing docs from the `docs` CF.
        {
            let cf_docs = db
                .cf_handle(CF_DOCS)
                .ok_or_else(|| BackendError::Crdt("missing 'docs' column family".into()))?;
            let iter = db.iterator_cf(&cf_docs, rocksdb::IteratorMode::Start);
            for item in iter {
                let (key, value) =
                    item.map_err(|e| BackendError::Crdt(format!("RocksDB iterator error: {e}")))?;
                let doc_id = String::from_utf8(key.to_vec())
                    .map_err(|e| BackendError::Serialization(format!("invalid doc_id: {e}")))?;

                let doc = Doc::with_options(yrs::Options {
                    skip_gc: true,
                    ..yrs::Options::default()
                });

                // Apply the base state snapshot.
                if !value.is_empty() {
                    let update = Update::decode_v1(&value)
                        .map_err(|e| BackendError::Crdt(format!("decode base state: {e}")))?;
                    let mut txn = doc.transact_mut();
                    txn.apply_update(update)
                        .map_err(|e| BackendError::Crdt(format!("apply base state: {e}")))?;
                }

                docs_map.insert(doc_id, Arc::new(doc));
            }
        }

        // Apply pending updates for each doc.
        {
            let cf_pending = db.cf_handle(CF_PENDING).ok_or_else(|| {
                BackendError::Crdt("missing 'pending_updates' column family".into())
            })?;
            let iter = db.iterator_cf(&cf_pending, rocksdb::IteratorMode::Start);
            for item in iter {
                let (key, value) =
                    item.map_err(|e| BackendError::Crdt(format!("RocksDB iterator error: {e}")))?;
                let doc_id = String::from_utf8(key.to_vec())
                    .map_err(|e| BackendError::Serialization(format!("invalid doc_id: {e}")))?;

                let updates: Vec<Vec<u8>> = serde_json::from_slice(&value).map_err(|e| {
                    BackendError::Serialization(format!("decode pending updates: {e}"))
                })?;

                // Ensure doc exists (create if needed).
                if !docs_map.contains_key(&doc_id) {
                    let doc = Doc::with_options(yrs::Options {
                        skip_gc: true,
                        ..yrs::Options::default()
                    });
                    docs_map.insert(doc_id.clone(), Arc::new(doc));
                }

                let doc = docs_map.get(&doc_id).expect("doc was just inserted");
                for update_bytes in &updates {
                    if update_bytes.is_empty() {
                        continue;
                    }
                    let update = Update::decode_v1(update_bytes)
                        .map_err(|e| BackendError::Crdt(format!("decode pending update: {e}")))?;
                    let mut txn = doc.transact_mut();
                    txn.apply_update(update)
                        .map_err(|e| BackendError::Crdt(format!("apply pending update: {e}")))?;
                }

                update_counts_map.insert(doc_id, updates.len() as u64);
            }
        }

        // Also load update counts from meta CF.
        {
            let cf_meta = db
                .cf_handle(CF_META)
                .ok_or_else(|| BackendError::Crdt("missing 'meta' column family".into()))?;
            let iter = db.iterator_cf(&cf_meta, rocksdb::IteratorMode::Start);
            for item in iter {
                let (key, value) =
                    item.map_err(|e| BackendError::Crdt(format!("RocksDB iterator error: {e}")))?;
                let doc_id = String::from_utf8(key.to_vec())
                    .map_err(|e| BackendError::Serialization(format!("invalid doc_id: {e}")))?;
                let meta: DocMeta = serde_json::from_slice(&value)
                    .map_err(|e| BackendError::Serialization(format!("decode doc meta: {e}")))?;
                // Use meta count if we don't already have a count from pending updates.
                update_counts_map.entry(doc_id).or_insert(meta.update_count);
            }
        }

        Ok(Self {
            db,
            docs: RwLock::new(docs_map),
            update_counts: RwLock::new(update_counts_map),
        })
    }

    /// Store a content-addressed blob.
    ///
    /// Blobs are write-once: if a blob with the given hash already exists,
    /// the write is silently ignored (no-op).
    pub fn put_blob(&self, hash: &str, data: &[u8]) -> Result<(), BackendError> {
        let cf_blobs = self
            .db
            .cf_handle(CF_BLOBS)
            .ok_or_else(|| BackendError::Crdt("missing 'blobs' column family".into()))?;

        // Write-once semantics: check if key already exists.
        let existing = self
            .db
            .get_cf(&cf_blobs, hash.as_bytes())
            .map_err(|e| BackendError::Crdt(format!("blob read error: {e}")))?;
        if existing.is_some() {
            return Ok(());
        }

        self.db
            .put_cf(&cf_blobs, hash.as_bytes(), data)
            .map_err(|e| BackendError::Crdt(format!("blob write error: {e}")))?;
        Ok(())
    }

    /// Retrieve a blob by its content hash.
    pub fn get_blob(&self, hash: &str) -> Result<Option<Vec<u8>>, BackendError> {
        let cf_blobs = self
            .db
            .cf_handle(CF_BLOBS)
            .ok_or_else(|| BackendError::Crdt("missing 'blobs' column family".into()))?;
        self.db
            .get_cf(&cf_blobs, hash.as_bytes())
            .map_err(|e| BackendError::Crdt(format!("blob read error: {e}")))
    }

    /// Perform a snapshot compaction if the update count has reached the
    /// threshold.
    ///
    /// A snapshot merges the current in-memory doc state into the `docs`
    /// CF, clears the `pending_updates` CF for that doc, and resets the
    /// update counter.
    fn maybe_snapshot(&self, doc_id: &str) -> Result<(), BackendError> {
        let count = {
            let counts = self
                .update_counts
                .read()
                .expect("update_counts lock poisoned");
            counts.get(doc_id).copied().unwrap_or(0)
        };

        if count < SNAPSHOT_THRESHOLD {
            return Ok(());
        }

        // Perform snapshot: encode full state and write to docs CF.
        let state_bytes = {
            let docs = self.docs.read().expect("docs lock poisoned");
            let doc = docs
                .get(doc_id)
                .ok_or_else(|| BackendError::DocNotFound(doc_id.to_string()))?;
            let txn = doc.transact();
            txn.encode_state_as_update_v1(&StateVector::default())
        };

        let cf_docs = self
            .db
            .cf_handle(CF_DOCS)
            .ok_or_else(|| BackendError::Crdt("missing 'docs' column family".into()))?;
        let cf_pending = self
            .db
            .cf_handle(CF_PENDING)
            .ok_or_else(|| BackendError::Crdt("missing 'pending_updates' column family".into()))?;
        let cf_meta = self
            .db
            .cf_handle(CF_META)
            .ok_or_else(|| BackendError::Crdt("missing 'meta' column family".into()))?;

        // Write the full snapshot to `docs` CF.
        self.db
            .put_cf(&cf_docs, doc_id.as_bytes(), &state_bytes)
            .map_err(|e| BackendError::Crdt(format!("snapshot write error: {e}")))?;

        // Clear pending updates.
        self.db
            .delete_cf(&cf_pending, doc_id.as_bytes())
            .map_err(|e| BackendError::Crdt(format!("clear pending error: {e}")))?;

        // Reset the update count.
        {
            let mut counts = self
                .update_counts
                .write()
                .expect("update_counts lock poisoned");
            counts.insert(doc_id.to_string(), 0);
        }

        // Update meta.
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs();
        let meta = DocMeta {
            update_count: 0,
            last_snapshot_time: now,
        };
        let meta_bytes = serde_json::to_vec(&meta)
            .map_err(|e| BackendError::Serialization(format!("encode meta: {e}")))?;
        self.db
            .put_cf(&cf_meta, doc_id.as_bytes(), &meta_bytes)
            .map_err(|e| BackendError::Crdt(format!("meta write error: {e}")))?;

        Ok(())
    }

    /// Persist a single update to the `pending_updates` column family.
    ///
    /// Pending updates are stored as a JSON array of byte-arrays.
    fn persist_pending_update(&self, doc_id: &str, update: &[u8]) -> Result<(), BackendError> {
        let cf_pending = self
            .db
            .cf_handle(CF_PENDING)
            .ok_or_else(|| BackendError::Crdt("missing 'pending_updates' column family".into()))?;

        // Read existing pending updates (if any).
        let mut pending: Vec<Vec<u8>> = match self
            .db
            .get_cf(&cf_pending, doc_id.as_bytes())
            .map_err(|e| BackendError::Crdt(format!("pending read error: {e}")))?
        {
            Some(bytes) => serde_json::from_slice(&bytes)
                .map_err(|e| BackendError::Serialization(format!("decode pending: {e}")))?,
            None => Vec::new(),
        };

        pending.push(update.to_vec());

        let pending_bytes = serde_json::to_vec(&pending)
            .map_err(|e| BackendError::Serialization(format!("encode pending: {e}")))?;

        self.db
            .put_cf(&cf_pending, doc_id.as_bytes(), &pending_bytes)
            .map_err(|e| BackendError::Crdt(format!("pending write error: {e}")))?;

        Ok(())
    }

    /// Persist the update count to the `meta` column family.
    fn persist_meta(&self, doc_id: &str, update_count: u64) -> Result<(), BackendError> {
        let cf_meta = self
            .db
            .cf_handle(CF_META)
            .ok_or_else(|| BackendError::Crdt("missing 'meta' column family".into()))?;

        let existing_meta: DocMeta = match self
            .db
            .get_cf(&cf_meta, doc_id.as_bytes())
            .map_err(|e| BackendError::Crdt(format!("meta read error: {e}")))?
        {
            Some(bytes) => serde_json::from_slice(&bytes)
                .map_err(|e| BackendError::Serialization(format!("decode meta: {e}")))?,
            None => DocMeta::default(),
        };

        let meta = DocMeta {
            update_count,
            last_snapshot_time: existing_meta.last_snapshot_time,
        };
        let meta_bytes = serde_json::to_vec(&meta)
            .map_err(|e| BackendError::Serialization(format!("encode meta: {e}")))?;

        self.db
            .put_cf(&cf_meta, doc_id.as_bytes(), &meta_bytes)
            .map_err(|e| BackendError::Crdt(format!("meta write error: {e}")))?;

        Ok(())
    }

    /// Persist the initial doc state to the `docs` column family.
    fn persist_doc_state(&self, doc_id: &str) -> Result<(), BackendError> {
        let cf_docs = self
            .db
            .cf_handle(CF_DOCS)
            .ok_or_else(|| BackendError::Crdt("missing 'docs' column family".into()))?;

        let state_bytes = {
            let docs = self.docs.read().expect("docs lock poisoned");
            let doc = docs
                .get(doc_id)
                .ok_or_else(|| BackendError::DocNotFound(doc_id.to_string()))?;
            let txn = doc.transact();
            txn.encode_state_as_update_v1(&StateVector::default())
        };

        self.db
            .put_cf(&cf_docs, doc_id.as_bytes(), &state_bytes)
            .map_err(|e| BackendError::Crdt(format!("doc state write error: {e}")))?;

        Ok(())
    }

    /// Return the current pending update count for a document.
    ///
    /// Useful for tests to verify snapshot behavior.
    pub fn pending_update_count(&self, doc_id: &str) -> u64 {
        let counts = self
            .update_counts
            .read()
            .expect("update_counts lock poisoned");
        counts.get(doc_id).copied().unwrap_or(0)
    }
}

impl CrdtBackend for RocksDbBackend {
    fn get_or_create_doc(&self, doc_id: &str) -> Arc<Doc> {
        // Fast path: read lock.
        {
            let docs = self.docs.read().expect("docs lock poisoned");
            if let Some(doc) = docs.get(doc_id) {
                return Arc::clone(doc);
            }
        }

        // Slow path: write lock to create.
        let mut docs = self.docs.write().expect("docs lock poisoned");
        // Double-check after acquiring write lock.
        if let Some(doc) = docs.get(doc_id) {
            return Arc::clone(doc);
        }

        let doc = Arc::new(Doc::with_options(yrs::Options {
            skip_gc: true,
            ..yrs::Options::default()
        }));
        docs.insert(doc_id.to_string(), Arc::clone(&doc));

        // Persist initial empty state — ignore errors during doc creation
        // since the doc is empty and will be persisted on first update.
        drop(docs);
        let _ = self.persist_doc_state(doc_id);

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
            None => Ok(txn.encode_state_as_update_v1(&StateVector::default())),
            Some(sv_bytes) => {
                let remote_sv = StateVector::decode_v1(sv_bytes)
                    .map_err(|e| BackendError::Serialization(e.to_string()))?;
                Ok(txn.encode_state_as_update_v1(&remote_sv))
            }
        }
    }

    fn apply_update(&self, doc_id: &str, update: &[u8]) -> Result<(), BackendError> {
        if update.is_empty() {
            return Ok(());
        }

        let doc = self.get_or_create_doc(doc_id);
        let decoded = Update::decode_v1(update).map_err(|e| BackendError::Crdt(e.to_string()))?;
        {
            let mut txn = doc.transact_mut();
            txn.apply_update(decoded)
                .map_err(|e| BackendError::Crdt(e.to_string()))?;
        }

        // Persist the update to pending_updates CF.
        self.persist_pending_update(doc_id, update)?;

        // Increment update count.
        let new_count = {
            let mut counts = self
                .update_counts
                .write()
                .expect("update_counts lock poisoned");
            let count = counts.entry(doc_id.to_string()).or_insert(0);
            *count += 1;
            *count
        };

        // Persist meta with updated count.
        self.persist_meta(doc_id, new_count)?;

        // Maybe trigger snapshot compaction.
        self.maybe_snapshot(doc_id)?;

        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;
    use yrs::{Map, Transact};

    /// Helper: create a YRS update that sets a key in a Y.Map named "data".
    fn make_map_update(key: &str, value: &str) -> Vec<u8> {
        let doc = Doc::with_options(yrs::Options {
            skip_gc: true,
            ..yrs::Options::default()
        });
        let map = doc.get_or_insert_map("data");
        {
            let mut txn = doc.transact_mut();
            map.insert(&mut txn, key, value);
        }
        let txn = doc.transact();
        txn.encode_state_as_update_v1(&StateVector::default())
    }

    /// TC-1-PERSIST-001: Create doc, apply update, close, reopen, verify state.
    #[test]
    fn tc_1_persist_001_store_and_retrieve_doc() {
        let dir = tempdir().expect("failed to create temp dir");
        let path = dir.path().join("test_db");

        let doc_id = "test-room-1";

        // Phase 1: Create backend, apply an update, then drop it.
        {
            let backend = RocksDbBackend::open(&path).expect("failed to open backend");
            let doc = backend.get_or_create_doc(doc_id);

            // Write data via the doc directly.
            let map = doc.get_or_insert_map("data");
            {
                let mut txn = doc.transact_mut();
                map.insert(&mut txn, "greeting", "hello");
            }

            // Encode the state and re-apply via the backend API to persist.
            let state = {
                let txn = doc.transact();
                txn.encode_state_as_update_v1(&StateVector::default())
            };
            // Create a fresh doc_id to apply the update to (simulate external update).
            // Actually, let's just use apply_update which persists to pending_updates.
            // We need to use a separate doc for this since the update is already applied.
            // Instead, let's just directly use the encode_state to verify and
            // persist through a snapshot.
            let backend2_doc_id = "test-room-persist";
            backend
                .apply_update(backend2_doc_id, &state)
                .expect("apply_update failed");
        }

        // Phase 2: Reopen and verify.
        {
            let backend = RocksDbBackend::open(&path).expect("failed to reopen backend");
            let doc = backend.get_or_create_doc("test-room-persist");
            let map = doc.get_or_insert_map("data");
            let txn = doc.transact();
            let value = map.get(&txn, "greeting").expect("key 'greeting' not found");
            assert_eq!(value.to_string(&txn), "hello");
        }
    }

    /// TC-1-PERSIST-002: put_blob, put same hash again (no-op), get blob.
    #[test]
    fn tc_1_persist_002_blob_write_once() {
        let dir = tempdir().expect("failed to create temp dir");
        let path = dir.path().join("test_db_blob");

        let backend = RocksDbBackend::open(&path).expect("failed to open backend");

        let hash = "sha256:abc123";
        let data = b"hello world blob content";

        // First write should succeed.
        backend.put_blob(hash, data).expect("put_blob failed");

        // Second write with same hash should be a no-op.
        let different_data = b"different content that should be ignored";
        backend
            .put_blob(hash, different_data)
            .expect("put_blob no-op failed");

        // Verify original data is preserved (not overwritten).
        let retrieved = backend.get_blob(hash).expect("get_blob failed");
        assert_eq!(retrieved.as_deref(), Some(data.as_slice()));

        // Verify non-existent blob returns None.
        let missing = backend
            .get_blob("sha256:nonexistent")
            .expect("get_blob missing failed");
        assert!(missing.is_none());
    }

    /// TC-1-PERSIST-003: Apply 100+ updates, verify snapshot triggers.
    #[test]
    fn tc_1_persist_003_snapshot_compaction() {
        let dir = tempdir().expect("failed to create temp dir");
        let path = dir.path().join("test_db_snapshot");

        let backend = RocksDbBackend::open(&path).expect("failed to open backend");
        let doc_id = "snapshot-test-room";

        // Apply 100 updates (threshold for snapshot).
        for i in 0..SNAPSHOT_THRESHOLD {
            let update = make_map_update(&format!("key-{i}"), &format!("value-{i}"));
            backend
                .apply_update(doc_id, &update)
                .unwrap_or_else(|e| panic!("apply_update {i} failed: {e}"));
        }

        // After exactly 100 updates, snapshot should have triggered
        // and reset the count to 0.
        assert_eq!(
            backend.pending_update_count(doc_id),
            0,
            "update count should be reset to 0 after snapshot"
        );

        // Verify the pending_updates CF is cleared.
        let cf_pending = backend
            .db
            .cf_handle(CF_PENDING)
            .expect("missing pending CF");
        let pending = backend
            .db
            .get_cf(&cf_pending, doc_id.as_bytes())
            .expect("read pending");
        assert!(
            pending.is_none(),
            "pending updates should be cleared after snapshot"
        );

        // Verify the docs CF has the full state.
        let cf_docs = backend.db.cf_handle(CF_DOCS).expect("missing docs CF");
        let state = backend
            .db
            .get_cf(&cf_docs, doc_id.as_bytes())
            .expect("read docs CF");
        assert!(state.is_some(), "docs CF should have snapshot state");

        // Verify all 100 keys are present in the doc.
        let doc = backend.get_or_create_doc(doc_id);
        let map = doc.get_or_insert_map("data");
        let txn = doc.transact();
        for i in 0..SNAPSHOT_THRESHOLD {
            let val = map.get(&txn, &format!("key-{i}"));
            assert!(
                val.is_some(),
                "key-{i} should be present after snapshot compaction"
            );
        }
    }

    /// TC-1-PERSIST-004: Apply updates, close, reopen, verify applied.
    #[test]
    fn tc_1_persist_004_pending_updates_survive_restart() {
        let dir = tempdir().expect("failed to create temp dir");
        let path = dir.path().join("test_db_pending");

        let doc_id = "pending-test-room";

        // Phase 1: Apply a few updates (below snapshot threshold), then close.
        {
            let backend = RocksDbBackend::open(&path).expect("failed to open backend");

            let update1 = make_map_update("name", "Alice");
            backend
                .apply_update(doc_id, &update1)
                .expect("apply_update 1 failed");

            let update2 = make_map_update("role", "admin");
            backend
                .apply_update(doc_id, &update2)
                .expect("apply_update 2 failed");

            // Verify both are present before close.
            let doc = backend.get_or_create_doc(doc_id);
            let map = doc.get_or_insert_map("data");
            let txn = doc.transact();
            assert_eq!(map.get(&txn, "name").unwrap().to_string(&txn), "Alice");
            assert_eq!(map.get(&txn, "role").unwrap().to_string(&txn), "admin");
        }

        // Phase 2: Reopen and verify pending updates were replayed.
        {
            let backend = RocksDbBackend::open(&path).expect("failed to reopen backend");
            let doc = backend.get_or_create_doc(doc_id);
            let map = doc.get_or_insert_map("data");
            let txn = doc.transact();

            let name_val = map
                .get(&txn, "name")
                .expect("key 'name' not found after restart");
            assert_eq!(name_val.to_string(&txn), "Alice");

            let role_val = map
                .get(&txn, "role")
                .expect("key 'role' not found after restart");
            assert_eq!(role_val.to_string(&txn), "admin");
        }
    }
}
