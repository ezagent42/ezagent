//! Message built-in datatype — content-addressed immutable message storage
//! with SHA-256 hashing and 3 hooks.
//!
//! The Message datatype stores message content as immutable, content-addressed
//! blobs. The SHA-256 hash of the canonical JSON representation serves as the
//! content_id. This ensures integrity: any tampering with the content will
//! invalidate the hash reference.
//!
//! Hooks:
//! - `message.compute_content_hash` (pre_send, immutable_content insert, p=20):
//!   computes SHA-256 hash from canonical JSON and sets content_id
//! - `message.validate_content_ref` (pre_send, timeline_index insert, p=25):
//!   verifies that the referenced content_id exists and author matches
//! - `message.resolve_content` (after_read, timeline_index, p=40):
//!   resolves content_id to full message body

use std::sync::Arc;

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use ezagent_protocol::KeyPattern;

use crate::error::EngineError;
use crate::hooks::executor::HookFn;
use crate::hooks::phase::{HookContext, HookDeclaration, HookPhase, TriggerEvent};
use crate::registry::datatype::*;

// ---------------------------------------------------------------------------
// Content Schema
// ---------------------------------------------------------------------------

/// Immutable message content, stored as a content-addressed blob.
///
/// The `content_id` is the SHA-256 hash of the canonical JSON representation
/// of the content fields (excluding `content_id` and `signature`). It is
/// computed automatically by the `compute_content_hash` hook; callers should
/// leave it empty when creating a new message.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MessageContent {
    /// SHA-256 hash of the canonical content (computed, not set by user).
    pub content_id: String,
    /// Content type: "immutable".
    pub content_type: String,
    /// Entity ID of the message author.
    pub author: String,
    /// Message body (text, structured data, etc.).
    pub body: serde_json::Value,
    /// MIME-like format string: "text/plain", "text/markdown", "application/json".
    pub format: String,
    /// References to blob attachments.
    pub media_refs: Vec<String>,
    /// ISO 8601 creation timestamp.
    pub created_at: String,
    /// Optional cryptographic signature.
    pub signature: Option<String>,
}

impl MessageContent {
    /// Compute the canonical SHA-256 hash of this content.
    ///
    /// The canonical form includes only the content-defining fields (author,
    /// body, content_type, created_at, format, media_refs) serialized as JSON
    /// with sorted keys and no extra whitespace. The `content_id` and
    /// `signature` fields are excluded because they are derived values.
    pub fn compute_hash(&self) -> String {
        let canonical = serde_json::json!({
            "author": self.author,
            "body": self.body,
            "content_type": self.content_type,
            "created_at": self.created_at,
            "format": self.format,
            "media_refs": self.media_refs,
        });
        let bytes = serde_json::to_vec(&canonical).unwrap_or_default();
        let hash = Sha256::digest(&bytes);
        hex_encode(&hash)
    }
}

/// Simple hex encoding without requiring the `hex` crate.
fn hex_encode(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

// ---------------------------------------------------------------------------
// Datatype Declaration
// ---------------------------------------------------------------------------

/// Return the Message datatype declaration.
///
/// The Message datatype has a single data entry `immutable_content` stored as
/// a Blob at `ezagent/{room_id}/content/{sha256_hash}`. It depends on the
/// Identity and Timeline datatypes.
pub fn message_datatype() -> DatatypeDeclaration {
    DatatypeDeclaration {
        id: "message".to_string(),
        version: "0.1.0".to_string(),
        dependencies: vec![
            "identity".to_string(),
            "room".to_string(),
            "timeline".to_string(),
        ],
        data_entries: vec![DataEntry {
            id: "immutable_content".to_string(),
            storage_type: StorageType::Blob,
            key_pattern: KeyPattern::new("ezagent/{room_id}/content/{sha256_hash}"),
            persistent: true,
            writer_rule: WriterRule::OneTimeWrite,
            sync_strategy: SyncMode::Eager,
        }],
        indexes: vec![],
        hooks: vec![],
        is_builtin: true,
    }
}

// ---------------------------------------------------------------------------
// Hook 1: message.compute_content_hash (pre_send, immutable_content insert, p=20)
// ---------------------------------------------------------------------------

/// Create the `message.compute_content_hash` hook.
///
/// This hook runs in the `PreSend` phase on `immutable_content` insert events
/// (priority 20). It reads the message content from `ctx.data`, computes the
/// canonical SHA-256 hash, and stores the computed `content_id` back into
/// `ctx.data["content_id"]`.
///
/// Expected context data:
/// - `author` (string): entity ID of the message author
/// - `body` (any JSON): message body
/// - `content_type` (string): should be "immutable"
/// - `format` (string): MIME format
/// - `media_refs` (array of strings): blob references
/// - `created_at` (string): ISO 8601 timestamp
///
/// On success, sets `ctx.data["content_id"]` to the computed SHA-256 hash.
pub fn compute_content_hash_hook() -> (HookDeclaration, HookFn) {
    let decl = HookDeclaration {
        id: "message.compute_content_hash".to_string(),
        phase: HookPhase::PreSend,
        trigger_datatype: "immutable_content".to_string(),
        trigger_event: TriggerEvent::Insert,
        trigger_filter: None,
        priority: 20,
        source: "message".to_string(),
    };

    let handler: HookFn = Arc::new(|ctx: &mut HookContext| {
        // Extract content fields from context data.
        let author = ctx
            .data
            .get("author")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();

        let body = ctx
            .data
            .get("body")
            .cloned()
            .unwrap_or(serde_json::Value::Null);

        let content_type = ctx
            .data
            .get("content_type")
            .and_then(|v| v.as_str())
            .unwrap_or("immutable")
            .to_string();

        let format = ctx
            .data
            .get("format")
            .and_then(|v| v.as_str())
            .unwrap_or("text/plain")
            .to_string();

        let media_refs: Vec<String> = ctx
            .data
            .get("media_refs")
            .and_then(|v| v.as_array())
            .map(|arr| {
                arr.iter()
                    .filter_map(|item| item.as_str().map(String::from))
                    .collect()
            })
            .unwrap_or_default();

        let created_at = ctx
            .data
            .get("created_at")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();

        // Build a MessageContent to compute the hash.
        let content = MessageContent {
            content_id: String::new(), // placeholder, will be computed
            content_type,
            author,
            body,
            format,
            media_refs,
            created_at,
            signature: None,
        };

        let hash = content.compute_hash();

        // Store the computed content_id back into context.
        ctx.data
            .insert("content_id".into(), serde_json::json!(hash));

        Ok(())
    });

    (decl, handler)
}

// ---------------------------------------------------------------------------
// Hook 2: message.validate_content_ref (pre_send, timeline_index insert, p=25)
// ---------------------------------------------------------------------------

/// Create the `message.validate_content_ref` hook.
///
/// This hook runs in the `PreSend` phase on `timeline_index` insert events
/// (priority 25). It verifies that:
/// 1. The `content_id` referenced in the timeline ref actually exists in the
///    content store (represented by `ctx.data["content_store"]`).
/// 2. The author in the content matches the signer of the timeline ref.
///
/// Expected context data:
/// - `content_id` (string): the SHA-256 hash to look up
/// - `content_store` (object): map of content_id -> serialized MessageContent
/// - `signer_id` on ctx: the entity making the write
///
/// On failure, rejects the context with reason `"CONTENT_NOT_FOUND"` or
/// `"AUTHOR_MISMATCH"`.
pub fn validate_content_ref_hook() -> (HookDeclaration, HookFn) {
    let decl = HookDeclaration {
        id: "message.validate_content_ref".to_string(),
        phase: HookPhase::PreSend,
        trigger_datatype: "timeline_index".to_string(),
        trigger_event: TriggerEvent::Insert,
        trigger_filter: None,
        priority: 25,
        source: "message".to_string(),
    };

    let handler: HookFn = Arc::new(|ctx: &mut HookContext| {
        // Get the content_id to validate.
        let content_id = ctx
            .data
            .get("content_id")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();

        if content_id.is_empty() {
            // No content_id to validate — skip (may be a non-message ref).
            return Ok(());
        }

        // Look up the content in the content store.
        let content_store = ctx.data.get("content_store").cloned();
        let content_entry = content_store
            .as_ref()
            .and_then(|store| store.get(&content_id));

        let content_json = match content_entry {
            Some(entry) => entry.clone(),
            None => {
                ctx.reject("CONTENT_NOT_FOUND");
                return Err(EngineError::HookRejected(format!(
                    "content_id {} not found in content store",
                    content_id
                )));
            }
        };

        // Verify author matches signer.
        let content_author = content_json
            .get("author")
            .and_then(|v| v.as_str())
            .unwrap_or("");

        let signer_id = ctx
            .signer_id
            .clone()
            .unwrap_or_default();

        if content_author != signer_id {
            ctx.reject("AUTHOR_MISMATCH");
            return Err(EngineError::HookRejected(format!(
                "content author {} does not match signer {}",
                content_author, signer_id
            )));
        }

        Ok(())
    });

    (decl, handler)
}

// ---------------------------------------------------------------------------
// Hook 3: message.resolve_content (after_read, timeline_index, p=40)
// ---------------------------------------------------------------------------

/// Create the `message.resolve_content` hook.
///
/// This hook runs in the `AfterRead` phase on `timeline_index` (priority 40).
/// It resolves the `content_id` from the timeline ref into the full message
/// body by looking it up in `ctx.data["content_store"]`.
///
/// On success, sets `ctx.data["resolved_content"]` to the full MessageContent.
/// On failure (content not found), the hook silently succeeds (AfterRead
/// errors return raw data, not errors).
pub fn resolve_content_hook() -> (HookDeclaration, HookFn) {
    let decl = HookDeclaration {
        id: "message.resolve_content".to_string(),
        phase: HookPhase::AfterRead,
        trigger_datatype: "timeline_index".to_string(),
        trigger_event: TriggerEvent::Any,
        trigger_filter: None,
        priority: 40,
        source: "message".to_string(),
    };

    let handler: HookFn = Arc::new(|ctx: &mut HookContext| {
        let content_id = ctx
            .data
            .get("content_id")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();

        if content_id.is_empty() {
            return Ok(());
        }

        // Look up the content in the content store.
        let resolved = ctx
            .data
            .get("content_store")
            .and_then(|store| store.get(&content_id))
            .cloned();

        if let Some(content) = resolved {
            ctx.data
                .insert("resolved_content".into(), content);
        }

        Ok(())
    });

    (decl, handler)
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    /// Helper: create a sample MessageContent for testing.
    fn sample_content(author: &str, body: &str) -> MessageContent {
        MessageContent {
            content_id: String::new(),
            content_type: "immutable".to_string(),
            author: author.to_string(),
            body: serde_json::json!(body),
            format: "text/plain".to_string(),
            media_refs: vec![],
            created_at: "2026-03-01T12:00:00Z".to_string(),
            signature: None,
        }
    }

    // -----------------------------------------------------------------------
    // TC-1-MSG-001: Content hash determinism
    // -----------------------------------------------------------------------

    /// TC-1-MSG-001: Same content produces the same SHA-256 hash; different
    /// content produces a different hash.
    #[test]
    fn tc_1_msg_001_content_hash_determinism() {
        // Two identical messages must produce the same hash.
        let msg_a = sample_content("@alice:relay.com", "Hello, world!");
        let msg_b = sample_content("@alice:relay.com", "Hello, world!");

        let hash_a = msg_a.compute_hash();
        let hash_b = msg_b.compute_hash();

        assert_eq!(
            hash_a, hash_b,
            "identical content must produce the same hash"
        );

        // Hash should be 64 hex characters (256 bits / 4 bits per hex digit).
        assert_eq!(hash_a.len(), 64, "SHA-256 hex digest must be 64 characters");

        // Hash should only contain hex characters.
        assert!(
            hash_a.chars().all(|c| c.is_ascii_hexdigit()),
            "hash must contain only hex digits"
        );

        // Different body produces a different hash.
        let msg_c = sample_content("@alice:relay.com", "Goodbye, world!");
        let hash_c = msg_c.compute_hash();
        assert_ne!(
            hash_a, hash_c,
            "different body must produce a different hash"
        );

        // Different author produces a different hash.
        let msg_d = sample_content("@bob:relay.com", "Hello, world!");
        let hash_d = msg_d.compute_hash();
        assert_ne!(
            hash_a, hash_d,
            "different author must produce a different hash"
        );

        // Different timestamp produces a different hash.
        let mut msg_e = sample_content("@alice:relay.com", "Hello, world!");
        msg_e.created_at = "2026-03-02T00:00:00Z".to_string();
        let hash_e = msg_e.compute_hash();
        assert_ne!(
            hash_a, hash_e,
            "different created_at must produce a different hash"
        );

        // Changing content_id or signature does NOT affect the hash
        // (those fields are excluded from canonical form).
        let mut msg_f = sample_content("@alice:relay.com", "Hello, world!");
        msg_f.content_id = "some-old-id".to_string();
        msg_f.signature = Some("some-signature".to_string());
        let hash_f = msg_f.compute_hash();
        assert_eq!(
            hash_a, hash_f,
            "content_id and signature must not affect the hash"
        );
    }

    // -----------------------------------------------------------------------
    // TC-1-MSG-002: compute_content_hash hook
    // -----------------------------------------------------------------------

    /// TC-1-MSG-002: The compute_content_hash hook computes the SHA-256 hash
    /// and stores it as content_id in the context.
    #[test]
    fn tc_1_msg_002_compute_hash_hook() {
        let (decl, handler) = compute_content_hash_hook();

        // Verify hook declaration.
        assert_eq!(decl.id, "message.compute_content_hash");
        assert_eq!(decl.phase, HookPhase::PreSend);
        assert_eq!(decl.trigger_datatype, "immutable_content");
        assert_eq!(decl.trigger_event, TriggerEvent::Insert);
        assert_eq!(decl.priority, 20);
        assert_eq!(decl.source, "message");

        // Build context with message content fields.
        let mut ctx = HookContext::new("immutable_content".to_string(), TriggerEvent::Insert);
        ctx.signer_id = Some("@alice:relay.com".to_string());
        ctx.room_id = Some("R-alpha".to_string());
        ctx.data
            .insert("author".into(), serde_json::json!("@alice:relay.com"));
        ctx.data
            .insert("body".into(), serde_json::json!("Hello from Alice"));
        ctx.data
            .insert("content_type".into(), serde_json::json!("immutable"));
        ctx.data
            .insert("format".into(), serde_json::json!("text/plain"));
        ctx.data
            .insert("media_refs".into(), serde_json::json!([]));
        ctx.data
            .insert("created_at".into(), serde_json::json!("2026-03-01T12:00:00Z"));

        // Execute the hook.
        let result = (handler)(&mut ctx);
        assert!(result.is_ok(), "compute_content_hash hook should succeed");

        // Verify content_id was set.
        let content_id = ctx
            .data
            .get("content_id")
            .expect("content_id must be set by hook");
        let hash_str = content_id.as_str().expect("content_id must be a string");
        assert_eq!(hash_str.len(), 64, "SHA-256 hex digest must be 64 characters");

        // Verify determinism: compute the same hash manually.
        let expected_content = MessageContent {
            content_id: String::new(),
            content_type: "immutable".to_string(),
            author: "@alice:relay.com".to_string(),
            body: serde_json::json!("Hello from Alice"),
            format: "text/plain".to_string(),
            media_refs: vec![],
            created_at: "2026-03-01T12:00:00Z".to_string(),
            signature: None,
        };
        let expected_hash = expected_content.compute_hash();
        assert_eq!(
            hash_str, expected_hash,
            "hook-computed hash must match MessageContent::compute_hash()"
        );
    }

    // -----------------------------------------------------------------------
    // TC-1-MSG-003: validate_content_ref success
    // -----------------------------------------------------------------------

    /// TC-1-MSG-003: A valid content reference passes validation when the
    /// content exists and the author matches the signer.
    #[test]
    fn tc_1_msg_003_validate_content_ref_success() {
        let (decl, handler) = validate_content_ref_hook();

        // Verify hook declaration.
        assert_eq!(decl.id, "message.validate_content_ref");
        assert_eq!(decl.phase, HookPhase::PreSend);
        assert_eq!(decl.trigger_datatype, "timeline_index");
        assert_eq!(decl.trigger_event, TriggerEvent::Insert);
        assert_eq!(decl.priority, 25);
        assert_eq!(decl.source, "message");

        // Create content and compute its hash.
        let content = sample_content("@alice:relay.com", "Test message");
        let hash = content.compute_hash();

        // Build a content store with this content.
        let content_json = serde_json::to_value(&content).expect("serialize content");
        let content_store = serde_json::json!({
            hash.clone(): content_json,
        });

        // Build context simulating a timeline_index insert.
        let mut ctx = HookContext::new("timeline_index".to_string(), TriggerEvent::Insert);
        ctx.signer_id = Some("@alice:relay.com".to_string());
        ctx.room_id = Some("R-alpha".to_string());
        ctx.data
            .insert("content_id".into(), serde_json::json!(hash));
        ctx.data
            .insert("content_store".into(), content_store);

        // Execute the hook.
        let result = (handler)(&mut ctx);
        assert!(
            result.is_ok(),
            "validate_content_ref should succeed for valid ref"
        );
        assert!(
            !ctx.rejected,
            "context should not be rejected for valid ref"
        );
    }

    // -----------------------------------------------------------------------
    // TC-1-MSG-004: validate_content_ref author mismatch
    // -----------------------------------------------------------------------

    /// TC-1-MSG-004: Author mismatch causes the validate_content_ref hook
    /// to reject the context with "AUTHOR_MISMATCH".
    #[test]
    fn tc_1_msg_004_validate_content_ref_author_mismatch() {
        let (_decl, handler) = validate_content_ref_hook();

        // Create content authored by Alice.
        let content = sample_content("@alice:relay.com", "Alice's message");
        let hash = content.compute_hash();

        let content_json = serde_json::to_value(&content).expect("serialize content");
        let content_store = serde_json::json!({
            hash.clone(): content_json,
        });

        // Build context where Bob is the signer (mismatch).
        let mut ctx = HookContext::new("timeline_index".to_string(), TriggerEvent::Insert);
        ctx.signer_id = Some("@bob:relay.com".to_string());
        ctx.room_id = Some("R-alpha".to_string());
        ctx.data
            .insert("content_id".into(), serde_json::json!(hash));
        ctx.data
            .insert("content_store".into(), content_store);

        // Execute the hook.
        let result = (handler)(&mut ctx);
        assert!(
            result.is_err(),
            "validate_content_ref should fail on author mismatch"
        );
        assert!(ctx.rejected, "context should be rejected");
        assert_eq!(
            ctx.rejection_reason.as_deref(),
            Some("AUTHOR_MISMATCH"),
            "rejection reason must be AUTHOR_MISMATCH"
        );

        let err_msg = result.unwrap_err().to_string();
        assert!(
            err_msg.contains("does not match signer"),
            "error should mention author/signer mismatch, got: {err_msg}"
        );
    }

    // -----------------------------------------------------------------------
    // TC-1-MSG-005: message_datatype declaration
    // -----------------------------------------------------------------------

    /// TC-1-MSG-005: Verify that message_datatype() returns the correct
    /// declaration fields.
    #[test]
    fn tc_1_msg_005_message_datatype_declaration() {
        let dt = message_datatype();

        assert_eq!(dt.id, "message");
        assert_eq!(dt.version, "0.1.0");
        assert_eq!(
            dt.dependencies,
            vec!["identity", "room", "timeline"],
            "message must depend on identity, room, and timeline"
        );
        assert!(dt.is_builtin, "message must be a built-in datatype");
        assert!(dt.indexes.is_empty(), "message declares no indexes");

        // Verify the single data entry.
        assert_eq!(dt.data_entries.len(), 1);
        let entry = &dt.data_entries[0];
        assert_eq!(entry.id, "immutable_content");
        assert_eq!(entry.storage_type, StorageType::Blob);
        assert_eq!(
            entry.key_pattern.template(),
            "ezagent/{room_id}/content/{sha256_hash}"
        );
        assert!(entry.persistent);
        assert_eq!(entry.writer_rule, WriterRule::OneTimeWrite);
        assert_eq!(entry.sync_strategy, SyncMode::Eager);
    }

    // -----------------------------------------------------------------------
    // Additional tests
    // -----------------------------------------------------------------------

    /// Verify that validate_content_ref rejects when content_id is not found.
    #[test]
    fn validate_content_ref_content_not_found() {
        let (_decl, handler) = validate_content_ref_hook();

        let mut ctx = HookContext::new("timeline_index".to_string(), TriggerEvent::Insert);
        ctx.signer_id = Some("@alice:relay.com".to_string());
        ctx.data.insert(
            "content_id".into(),
            serde_json::json!("nonexistent_hash_abc123"),
        );
        ctx.data
            .insert("content_store".into(), serde_json::json!({}));

        let result = (handler)(&mut ctx);
        assert!(result.is_err(), "should fail when content_id not found");
        assert!(ctx.rejected, "context should be rejected");
        assert_eq!(
            ctx.rejection_reason.as_deref(),
            Some("CONTENT_NOT_FOUND"),
            "rejection reason must be CONTENT_NOT_FOUND"
        );
    }

    /// Verify that validate_content_ref skips when no content_id is present.
    #[test]
    fn validate_content_ref_skips_without_content_id() {
        let (_decl, handler) = validate_content_ref_hook();

        let mut ctx = HookContext::new("timeline_index".to_string(), TriggerEvent::Insert);
        ctx.signer_id = Some("@alice:relay.com".to_string());
        // No content_id in data.

        let result = (handler)(&mut ctx);
        assert!(result.is_ok(), "should skip when no content_id");
        assert!(!ctx.rejected);
    }

    /// Verify that resolve_content resolves a valid content_id.
    #[test]
    fn resolve_content_resolves_valid_id() {
        let (decl, handler) = resolve_content_hook();

        // Verify hook declaration.
        assert_eq!(decl.id, "message.resolve_content");
        assert_eq!(decl.phase, HookPhase::AfterRead);
        assert_eq!(decl.trigger_datatype, "timeline_index");
        assert_eq!(decl.trigger_event, TriggerEvent::Any);
        assert_eq!(decl.priority, 40);
        assert_eq!(decl.source, "message");

        let content = sample_content("@alice:relay.com", "Resolve me!");
        let hash = content.compute_hash();
        let content_json = serde_json::to_value(&content).expect("serialize");

        let content_store = serde_json::json!({
            hash.clone(): content_json.clone(),
        });

        let mut ctx = HookContext::new("timeline_index".to_string(), TriggerEvent::Any);
        ctx.data
            .insert("content_id".into(), serde_json::json!(hash));
        ctx.data
            .insert("content_store".into(), content_store);

        let result = (handler)(&mut ctx);
        assert!(result.is_ok(), "resolve_content should succeed");

        let resolved = ctx
            .data
            .get("resolved_content")
            .expect("resolved_content must be set");
        assert_eq!(
            resolved, &content_json,
            "resolved content must match the original"
        );
    }

    /// Verify that resolve_content gracefully handles missing content.
    #[test]
    fn resolve_content_missing_content_is_ok() {
        let (_decl, handler) = resolve_content_hook();

        let mut ctx = HookContext::new("timeline_index".to_string(), TriggerEvent::Any);
        ctx.data.insert(
            "content_id".into(),
            serde_json::json!("nonexistent_hash"),
        );
        ctx.data
            .insert("content_store".into(), serde_json::json!({}));

        let result = (handler)(&mut ctx);
        assert!(
            result.is_ok(),
            "resolve_content should succeed even when content is missing"
        );
        assert!(
            !ctx.data.contains_key("resolved_content"),
            "resolved_content should not be set when content is missing"
        );
    }

    /// Verify hex_encode produces correct output.
    #[test]
    fn hex_encode_correctness() {
        assert_eq!(hex_encode(&[]), "");
        assert_eq!(hex_encode(&[0x00]), "00");
        assert_eq!(hex_encode(&[0xff]), "ff");
        assert_eq!(hex_encode(&[0xde, 0xad, 0xbe, 0xef]), "deadbeef");
        assert_eq!(hex_encode(&[0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef]), "0123456789abcdef");
    }

    /// MessageContent serde roundtrip.
    #[test]
    fn message_content_serde_roundtrip() {
        let mut content = sample_content("@alice:relay.com", "roundtrip test");
        content.content_id = content.compute_hash();
        content.media_refs = vec!["blob/abc123".to_string()];
        content.signature = Some("sig-placeholder".to_string());

        let json = serde_json::to_string(&content).expect("serialize");
        let roundtripped: MessageContent =
            serde_json::from_str(&json).expect("deserialize");

        assert_eq!(roundtripped.content_id, content.content_id);
        assert_eq!(roundtripped.content_type, "immutable");
        assert_eq!(roundtripped.author, "@alice:relay.com");
        assert_eq!(roundtripped.body, serde_json::json!("roundtrip test"));
        assert_eq!(roundtripped.format, "text/plain");
        assert_eq!(roundtripped.media_refs, vec!["blob/abc123"]);
        assert_eq!(roundtripped.created_at, "2026-03-01T12:00:00Z");
        assert_eq!(
            roundtripped.signature.as_deref(),
            Some("sig-placeholder")
        );
    }
}
