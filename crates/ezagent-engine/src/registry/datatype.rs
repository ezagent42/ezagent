//! Core data types for the Datatype Registry (bus-spec §3.1).
//!
//! This module defines the foundational types used by the Engine to declare,
//! store, and query datatypes: `StorageType`, `SyncMode`, `WriterRule`,
//! `DataEntry`, `IndexDeclaration`, and `DatatypeDeclaration`.

use ezagent_protocol::KeyPattern;
use serde::{Deserialize, Serialize};

/// Storage type for a data entry (bus-spec §3.1.2).
///
/// Each data entry within a Datatype declaration specifies one of five
/// storage types that determines the CRDT semantics and persistence behavior.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum StorageType {
    /// Last-Writer-Wins Map. Used for Room config, Profile, etc.
    CrdtMap,
    /// YATA-ordered Array. Used for Timeline Index shards.
    CrdtArray,
    /// YATA character-level collaborative text. Used for collaborative documents.
    CrdtText,
    /// Immutable hash-addressed binary. Used for public keys, media attachments.
    Blob,
    /// No persistence, memory-only. Used for Presence, Awareness signals.
    Ephemeral,
}

/// Sync strategy for live sync propagation (bus-spec §3.1.6).
///
/// Controls how updates are propagated to peers after a local CRDT write.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub enum SyncMode {
    /// Immediately publish every update.
    #[default]
    Eager,
    /// Buffer updates and publish as a batch after `batch_ms` milliseconds.
    Batched { batch_ms: u64 },
    /// Only sync on explicit pull or initial sync.
    Lazy,
}

/// Writer rule expression (bus-spec §3.1.4).
///
/// A composable predicate that the Hook Pipeline evaluates during `pre_send`
/// to decide whether a write operation is authorized.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum WriterRule {
    /// The signer is the entity that owns the document.
    SignerIsEntity,
    /// The signer is a current member of the room.
    SignerInMembers,
    /// The signer has at least `min_level` power level in the room.
    SignerPowerLevel { min_level: u32 },
    /// The signer is the original author of the content.
    SignerIsAuthor,
    /// The signer is listed in the ACL editors set.
    SignerInAclEditors,
    /// The annotation key contains the signer's entity ID.
    AnnotationKeyContainsSigner,
    /// The entry can only be written once (immutable after first write).
    OneTimeWrite,
    /// Both rules must be satisfied.
    And(Box<WriterRule>, Box<WriterRule>),
    /// At least one rule must be satisfied.
    Or(Box<WriterRule>, Box<WriterRule>),
}

/// A single data entry within a Datatype declaration (bus-spec §3.1.1).
///
/// Each Datatype may declare multiple data entries, each with its own
/// storage type, key pattern, persistence, writer rule, and sync strategy.
#[derive(Debug, Clone)]
pub struct DataEntry {
    /// Unique identifier for this data entry within the Datatype.
    pub id: String,
    /// The CRDT storage type.
    pub storage_type: StorageType,
    /// Key pattern template for document addressing.
    pub key_pattern: KeyPattern,
    /// Whether this entry is persisted to disk.
    pub persistent: bool,
    /// Authorization rule for writes.
    pub writer_rule: WriterRule,
    /// Sync propagation strategy.
    pub sync_strategy: SyncMode,
}

/// Index refresh strategy (bus-spec §3.4.2).
///
/// Determines when the Index Builder recomputes an index.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RefreshStrategy {
    /// Recompute whenever the input data changes.
    OnChange,
    /// Recompute only when explicitly requested.
    OnDemand,
    /// Recompute at fixed intervals.
    Periodic { interval_secs: u64 },
}

/// An index declaration within a Datatype (bus-spec §3.4.1).
///
/// Indexes allow the Engine to maintain derived, queryable views of data
/// entries using configurable transforms and refresh policies.
#[derive(Debug, Clone)]
pub struct IndexDeclaration {
    /// Unique identifier for this index within the Datatype.
    pub id: String,
    /// The data entry id that feeds this index.
    pub input: String,
    /// The transform expression applied to the input.
    pub transform: String,
    /// When to refresh the index.
    pub refresh: RefreshStrategy,
    /// Optional operation id that triggers refresh.
    pub operation_id: Option<String>,
}

/// A complete Datatype declaration (bus-spec §3.5).
///
/// A Datatype bundles together data entries, indexes, hooks, and metadata
/// about dependencies and built-in status. The Engine loads datatypes in
/// topological order according to their declared dependencies.
#[derive(Debug, Clone)]
pub struct DatatypeDeclaration {
    /// Unique identifier for this Datatype (e.g., "identity", "room", "EXT-01").
    pub id: String,
    /// Semantic version string.
    pub version: String,
    /// IDs of other Datatypes this one depends on.
    pub dependencies: Vec<String>,
    /// The data entries declared by this Datatype.
    pub data_entries: Vec<DataEntry>,
    /// The indexes declared by this Datatype.
    pub indexes: Vec<IndexDeclaration>,
    /// The hook declarations associated with this Datatype.
    pub hooks: Vec<crate::hooks::HookDeclaration>,
    /// Whether this is a built-in datatype (identity, room, timeline, message).
    pub is_builtin: bool,
}

#[cfg(test)]
mod tests {
    use super::*;

    /// TC-1-ENGINE-006: all five storage types are distinct.
    #[test]
    fn tc_1_engine_006_five_storage_types() {
        let types = [
            StorageType::CrdtMap,
            StorageType::CrdtArray,
            StorageType::CrdtText,
            StorageType::Blob,
            StorageType::Ephemeral,
        ];

        // Each type is distinct from every other type.
        for (i, a) in types.iter().enumerate() {
            for (j, b) in types.iter().enumerate() {
                if i == j {
                    assert_eq!(a, b);
                } else {
                    assert_ne!(a, b, "{a:?} should differ from {b:?}");
                }
            }
        }

        // Verify we have exactly 5 types.
        assert_eq!(types.len(), 5);
    }

    #[test]
    fn sync_mode_default_is_eager() {
        assert_eq!(SyncMode::default(), SyncMode::Eager);
    }

    #[test]
    fn writer_rule_composition() {
        let rule = WriterRule::And(
            Box::new(WriterRule::SignerInMembers),
            Box::new(WriterRule::Or(
                Box::new(WriterRule::SignerIsAuthor),
                Box::new(WriterRule::SignerPowerLevel { min_level: 50 }),
            )),
        );
        // Just verify it constructs and can be debug-printed.
        let debug = format!("{rule:?}");
        assert!(debug.contains("And"));
        assert!(debug.contains("Or"));
    }

    #[test]
    fn storage_type_serde_roundtrip() {
        let st = StorageType::CrdtMap;
        let json = serde_json::to_string(&st).unwrap();
        let st2: StorageType = serde_json::from_str(&json).unwrap();
        assert_eq!(st, st2);
    }

    #[test]
    fn sync_mode_serde_roundtrip() {
        let sm = SyncMode::Batched { batch_ms: 100 };
        let json = serde_json::to_string(&sm).unwrap();
        let sm2: SyncMode = serde_json::from_str(&json).unwrap();
        assert_eq!(sm, sm2);
    }

    #[test]
    fn writer_rule_serde_roundtrip() {
        let wr = WriterRule::And(
            Box::new(WriterRule::SignerInMembers),
            Box::new(WriterRule::SignerPowerLevel { min_level: 50 }),
        );
        let json = serde_json::to_string(&wr).unwrap();
        let wr2: WriterRule = serde_json::from_str(&json).unwrap();
        assert_eq!(wr, wr2);
    }
}
