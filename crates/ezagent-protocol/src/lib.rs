//! EZAgent shared protocol types.
//!
//! This crate is the single source of truth for all protocol-level types.
//! It MUST NOT depend on yrs, zenoh, rocksdb, or pyo3.

pub mod crypto;
pub mod entity_id;
pub mod envelope;
pub mod error;
pub mod key_pattern;
pub mod sync;

pub use crypto::{Keypair, PublicKey, Signature};
pub use entity_id::EntityId;
pub use envelope::SignedEnvelope;
pub use error::ProtocolError;
pub use key_pattern::KeyPattern;
pub use sync::SyncMessage;
