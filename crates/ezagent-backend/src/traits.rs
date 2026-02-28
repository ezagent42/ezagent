//! Backend trait definitions for CrdtBackend and NetworkBackend.
//!
//! These traits abstract the CRDT storage layer (bus-spec 4.2) and
//! the network transport layer (bus-spec 4.3) so that concrete
//! implementations (yrs, zenoh) can be swapped independently.

use std::sync::Arc;

use async_trait::async_trait;
use thiserror::Error;

/// Errors that can occur in backend operations.
#[derive(Debug, Error)]
pub enum BackendError {
    /// A CRDT operation failed.
    #[error("CRDT error: {0}")]
    Crdt(String),

    /// A network operation failed.
    #[error("network error: {0}")]
    Network(String),

    /// The requested document was not found.
    #[error("document not found: {0}")]
    DocNotFound(String),

    /// Serialization or deserialization failed.
    #[error("serialization error: {0}")]
    Serialization(String),
}

/// CRDT backend (bus-spec 4.2).
///
/// Manages Y.Doc instances keyed by document ID.  Each document
/// contains Y.Map / Y.Array / Y.Text structures that are
/// collaboratively edited via state-vector-based sync.
pub trait CrdtBackend: Send + Sync {
    /// Return an existing doc or create a new one for `doc_id`.
    fn get_or_create_doc(&self, doc_id: &str) -> Arc<yrs::Doc>;

    /// Encode the state vector of `doc_id` as v1 bytes.
    fn state_vector(&self, doc_id: &str) -> Result<Vec<u8>, BackendError>;

    /// Encode the document state as a v1 update.
    ///
    /// If `sv` is `None`, the full state is returned.
    /// If `sv` is `Some(remote_sv)`, only the diff relative to the
    /// remote state vector is returned.
    fn encode_state(&self, doc_id: &str, sv: Option<&[u8]>) -> Result<Vec<u8>, BackendError>;

    /// Apply a v1-encoded update to `doc_id`.
    fn apply_update(&self, doc_id: &str, update: &[u8]) -> Result<(), BackendError>;
}

/// Network backend (bus-spec 4.3).
///
/// Provides pub/sub messaging, queryable registration, and
/// request/reply semantics over a peer-to-peer transport.
#[async_trait]
pub trait NetworkBackend: Send + Sync {
    /// Publish `payload` on `key_expr`.
    async fn publish(&self, key_expr: &str, payload: &[u8]) -> Result<(), BackendError>;

    /// Subscribe to `key_expr` and return a channel that yields payloads.
    async fn subscribe(
        &self,
        key_expr: &str,
    ) -> Result<tokio::sync::mpsc::Receiver<Vec<u8>>, BackendError>;

    /// Register a queryable on `key_expr`.
    ///
    /// When a query arrives, `handler` is invoked with the query
    /// payload (as owned bytes) and its return value is sent back
    /// as the reply.
    ///
    /// Note: the handler takes `Vec<u8>` rather than `&[u8]` to avoid
    /// a known lifetime-desugaring issue with `async_trait` and
    /// higher-ranked `dyn Fn(&[u8])` trait objects.
    async fn register_queryable(
        &self,
        key_expr: &str,
        handler: Arc<dyn Fn(Vec<u8>) -> Vec<u8> + Send + Sync>,
    ) -> Result<(), BackendError>;

    /// Send a query to `key_expr` and return the first reply payload.
    async fn query(&self, key_expr: &str, payload: Option<&[u8]>) -> Result<Vec<u8>, BackendError>;
}
