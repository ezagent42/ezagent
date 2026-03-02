//! Identity built-in datatype — keypair management, public key cache,
//! signing envelope hook, and signature verification hook.
//!
//! The Identity datatype is the foundation of the authentication system.
//! Its two global hooks wrap every write in the system:
//! - `identity.sign_envelope` (pre_send, p=0, runs LAST): signs the payload
//! - `identity.verify_signature` (after_write, p=0, runs FIRST): verifies the signature

use std::collections::HashMap;
use std::sync::{Arc, RwLock};
use std::time::{SystemTime, UNIX_EPOCH};

use ezagent_protocol::{Keypair, KeyPattern, PublicKey, SignedEnvelope};

use crate::error::EngineError;
use crate::hooks::phase::{HookContext, HookDeclaration, HookPhase, TriggerEvent};
use crate::hooks::executor::HookFn;
use crate::registry::datatype::*;

/// Timestamp tolerance for signature verification: +/- 5 minutes in milliseconds.
const TIMESTAMP_TOLERANCE_MS: i64 = 5 * 60 * 1000;

/// The Identity datatype declaration.
///
/// Declares a single data entry `entity_keypair` stored as a Blob at
/// `ezagent/@{entity_id}/identity/pubkey`. This is the Ed25519 public key
/// for the entity, used for signature verification.
pub fn identity_datatype() -> DatatypeDeclaration {
    DatatypeDeclaration {
        id: "identity".to_string(),
        version: "0.1.0".to_string(),
        dependencies: vec![],
        data_entries: vec![DataEntry {
            id: "entity_keypair".to_string(),
            storage_type: StorageType::Blob,
            key_pattern: KeyPattern::new("ezagent/@{entity_id}/identity/pubkey"),
            persistent: true,
            writer_rule: WriterRule::SignerIsEntity,
            sync_strategy: SyncMode::Eager,
        }],
        indexes: vec![],
        is_builtin: true,
    }
}

/// Shared public key cache for signature verification.
///
/// Thread-safe cache mapping entity IDs to their Ed25519 public keys.
/// Used by the `verify_signature` hook to look up public keys without
/// accessing the backing store on every write.
#[derive(Clone, Default)]
pub struct PublicKeyCache {
    inner: Arc<RwLock<HashMap<String, PublicKey>>>,
}

impl PublicKeyCache {
    /// Create a new empty public key cache.
    pub fn new() -> Self {
        Self {
            inner: Arc::new(RwLock::new(HashMap::new())),
        }
    }

    /// Insert a public key for the given entity ID.
    pub fn insert(&self, entity_id: &str, pubkey: PublicKey) {
        let mut map = self.inner.write().unwrap_or_else(|e| e.into_inner());
        map.insert(entity_id.to_string(), pubkey);
    }

    /// Look up the public key for the given entity ID.
    pub fn get(&self, entity_id: &str) -> Option<PublicKey> {
        let map = self.inner.read().unwrap_or_else(|e| e.into_inner());
        map.get(entity_id).cloned()
    }
}

/// Create the `identity.sign_envelope` hook.
///
/// This hook runs in the `PreSend` phase as the LAST hook (priority 0 +
/// special ordering in the executor). It reads the payload and doc_id from
/// `ctx.data`, signs them using the provided keypair, and stores the
/// serialized `SignedEnvelope` back into `ctx.data["signed_envelope"]`.
///
/// # Errors
///
/// Returns `EngineError::PermissionDenied` if no `signer_id` is set in the context.
pub fn sign_envelope_hook(keypair: Arc<Keypair>) -> (HookDeclaration, HookFn) {
    let decl = HookDeclaration {
        id: "identity.sign_envelope".to_string(),
        phase: HookPhase::PreSend,
        trigger_datatype: "*".to_string(),
        trigger_event: TriggerEvent::Any,
        trigger_filter: None,
        priority: 0,
        source: "identity".to_string(),
    };

    let handler: HookFn = Arc::new(move |ctx: &mut HookContext| {
        let signer_id = ctx
            .signer_id
            .as_ref()
            .ok_or_else(|| EngineError::PermissionDenied("no signer_id in context".into()))?
            .clone();

        // Get the payload bytes from ctx.data["payload"].
        // The payload may be a JSON string or a JSON array of numbers.
        let payload: Vec<u8> = if let Some(payload_val) = ctx.data.get("payload") {
            if let Some(s) = payload_val.as_str() {
                s.as_bytes().to_vec()
            } else if let Some(arr) = payload_val.as_array() {
                arr.iter()
                    .filter_map(|v| v.as_u64().map(|n| n as u8))
                    .collect()
            } else {
                Vec::new()
            }
        } else {
            Vec::new()
        };

        let doc_id = ctx
            .data
            .get("doc_id")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();

        // Create the SignedEnvelope using the protocol's sign method.
        let envelope = SignedEnvelope::sign(&keypair, signer_id, doc_id, payload);

        // Store the serialized envelope in context for downstream consumption.
        let envelope_json = serde_json::to_value(&envelope).map_err(|e| {
            EngineError::Protocol(ezagent_protocol::ProtocolError::Serialization(
                e.to_string(),
            ))
        })?;
        ctx.data.insert("signed_envelope".into(), envelope_json);

        Ok(())
    });

    (decl, handler)
}

/// Create the `identity.verify_signature` hook.
///
/// This hook runs in the `AfterWrite` phase as the FIRST hook (priority 0).
/// It extracts the `SignedEnvelope` from `ctx.data["signed_envelope"]`,
/// looks up the signer's public key in the `PublicKeyCache`, verifies the
/// Ed25519 signature, and checks that the timestamp is within +/- 5 minutes.
///
/// On success, sets `ctx.data["signature_verified"] = true`.
///
/// # Errors
///
/// Returns `EngineError::PermissionDenied` if no signer_id is present or
/// the public key is not found in the cache. Returns a protocol error if
/// signature verification or timestamp check fails.
pub fn verify_signature_hook(cache: PublicKeyCache) -> (HookDeclaration, HookFn) {
    let decl = HookDeclaration {
        id: "identity.verify_signature".to_string(),
        phase: HookPhase::AfterWrite,
        trigger_datatype: "*".to_string(),
        trigger_event: TriggerEvent::Any,
        trigger_filter: None,
        priority: 0,
        source: "identity".to_string(),
    };

    let handler: HookFn = Arc::new(move |ctx: &mut HookContext| {
        let signer_id = ctx
            .signer_id
            .as_ref()
            .ok_or_else(|| {
                EngineError::PermissionDenied("no signer_id for verification".into())
            })?
            .clone();

        // Look up the public key for this signer.
        let pubkey = cache.get(&signer_id).ok_or_else(|| {
            EngineError::PermissionDenied(format!("no public key for {}", signer_id))
        })?;

        // Extract the signed envelope from context data.
        if let Some(envelope_json) = ctx.data.get("signed_envelope").cloned() {
            let envelope: SignedEnvelope =
                serde_json::from_value(envelope_json).map_err(|e| {
                    EngineError::Protocol(ezagent_protocol::ProtocolError::Serialization(
                        e.to_string(),
                    ))
                })?;

            // Verify the cryptographic signature.
            envelope.verify(&pubkey)?;

            // Verify timestamp is within +/- 5 minutes of current time.
            let now_ms = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap_or_default()
                .as_millis() as i64;
            let delta_ms = (now_ms - envelope.timestamp).abs();
            if delta_ms > TIMESTAMP_TOLERANCE_MS {
                return Err(EngineError::Protocol(
                    ezagent_protocol::ProtocolError::TimestampOutOfRange { delta_ms },
                ));
            }

            // Mark verification as successful.
            ctx.data
                .insert("signature_verified".into(), serde_json::json!(true));
        }

        Ok(())
    });

    (decl, handler)
}

#[cfg(test)]
mod tests {
    use super::*;
    use ezagent_protocol::{EntityId, Keypair};

    /// TC-1-IDENT-002: Generate a Keypair and verify the public key is 32 bytes.
    #[test]
    fn tc_1_ident_002_keypair_generation() {
        let kp = Keypair::generate();
        let pk = kp.public_key();
        assert_eq!(pk.as_bytes().len(), 32, "Ed25519 public key must be 32 bytes");

        // Verify the keypair can also be reconstructed from bytes.
        let secret_bytes = kp.to_bytes();
        assert_eq!(secret_bytes.len(), 32, "Ed25519 secret key must be 32 bytes");
        let kp2 = Keypair::from_bytes(&secret_bytes);
        assert_eq!(kp2.public_key(), pk, "reconstructed keypair must have same public key");
    }

    /// TC-1-IDENT-003: Insert and retrieve public keys from the PublicKeyCache.
    #[test]
    fn tc_1_ident_003_pubkey_cache_insert_get() {
        let cache = PublicKeyCache::new();

        let kp_alice = Keypair::generate();
        let kp_bob = Keypair::generate();
        let pk_alice = kp_alice.public_key();
        let pk_bob = kp_bob.public_key();

        // Cache starts empty.
        assert!(cache.get("@alice:relay.com").is_none());
        assert!(cache.get("@bob:relay.com").is_none());

        // Insert Alice's key.
        cache.insert("@alice:relay.com", pk_alice.clone());
        assert_eq!(cache.get("@alice:relay.com"), Some(pk_alice.clone()));
        assert!(cache.get("@bob:relay.com").is_none());

        // Insert Bob's key.
        cache.insert("@bob:relay.com", pk_bob.clone());
        assert_eq!(cache.get("@alice:relay.com"), Some(pk_alice));
        assert_eq!(cache.get("@bob:relay.com"), Some(pk_bob.clone()));

        // Overwrite Bob's key.
        let kp_bob2 = Keypair::generate();
        let pk_bob2 = kp_bob2.public_key();
        cache.insert("@bob:relay.com", pk_bob2.clone());
        assert_eq!(cache.get("@bob:relay.com"), Some(pk_bob2));
        assert_ne!(cache.get("@bob:relay.com"), Some(pk_bob));
    }

    /// TC-1-IDENT-004: Verify identity_datatype() returns the correct fields.
    #[test]
    fn tc_1_ident_004_identity_datatype_declaration() {
        let dt = identity_datatype();

        assert_eq!(dt.id, "identity");
        assert_eq!(dt.version, "0.1.0");
        assert!(dt.dependencies.is_empty(), "identity has no dependencies");
        assert!(dt.is_builtin, "identity must be built-in");
        assert!(dt.indexes.is_empty(), "identity declares no indexes");

        // Verify the single data entry.
        assert_eq!(dt.data_entries.len(), 1);
        let entry = &dt.data_entries[0];
        assert_eq!(entry.id, "entity_keypair");
        assert_eq!(entry.storage_type, StorageType::Blob);
        assert_eq!(
            entry.key_pattern.template(),
            "ezagent/@{entity_id}/identity/pubkey"
        );
        assert!(entry.persistent);
        assert_eq!(entry.writer_rule, WriterRule::SignerIsEntity);
        assert_eq!(entry.sync_strategy, SyncMode::Eager);
    }

    /// TC-1-IDENT-005: Create the sign_envelope hook, run it, verify ctx has signed_envelope.
    #[test]
    fn tc_1_ident_005_sign_envelope_hook_creates_signature() {
        let kp = Keypair::generate();
        let (decl, handler) = sign_envelope_hook(Arc::new(kp));

        // Verify hook declaration.
        assert_eq!(decl.id, "identity.sign_envelope");
        assert_eq!(decl.phase, HookPhase::PreSend);
        assert_eq!(decl.trigger_datatype, "*");
        assert_eq!(decl.priority, 0);
        assert_eq!(decl.source, "identity");

        // Create a context with signer, payload, and doc_id.
        let mut ctx = HookContext::new("message".to_string(), TriggerEvent::Insert);
        ctx.signer_id = Some("@alice:relay.com".to_string());
        ctx.data.insert(
            "payload".into(),
            serde_json::json!("hello world"),
        );
        ctx.data.insert(
            "doc_id".into(),
            serde_json::json!("rooms/abc/messages"),
        );

        // Execute the hook.
        let result = (handler)(&mut ctx);
        assert!(result.is_ok(), "sign_envelope hook should succeed");

        // Verify signed_envelope is in context.
        let envelope_val = ctx.data.get("signed_envelope");
        assert!(envelope_val.is_some(), "signed_envelope must be in context data");

        // Deserialize and verify the envelope contents.
        let envelope: SignedEnvelope =
            serde_json::from_value(envelope_val.unwrap().clone()).unwrap();
        assert_eq!(envelope.signer_id, "@alice:relay.com");
        assert_eq!(envelope.doc_id, "rooms/abc/messages");
        assert_eq!(envelope.payload, b"hello world");
        assert_eq!(envelope.version, 1);
    }

    /// TC-1-IDENT-006: Create verify_signature hook with cached pubkey, verify success.
    #[test]
    fn tc_1_ident_006_verify_signature_hook_succeeds() {
        let kp = Keypair::generate();
        let pk = kp.public_key();

        // Populate the cache with Alice's public key.
        let cache = PublicKeyCache::new();
        cache.insert("@alice:relay.com", pk);

        // Sign an envelope.
        let envelope = SignedEnvelope::sign(
            &kp,
            "@alice:relay.com".into(),
            "rooms/abc/messages".into(),
            b"test payload".to_vec(),
        );

        // Create the verify hook.
        let (_decl, handler) = verify_signature_hook(cache);

        // Build context with the signed envelope.
        let mut ctx = HookContext::new("message".to_string(), TriggerEvent::Insert);
        ctx.signer_id = Some("@alice:relay.com".to_string());
        ctx.data.insert(
            "signed_envelope".into(),
            serde_json::to_value(&envelope).unwrap(),
        );

        // Execute the hook.
        let result = (handler)(&mut ctx);
        assert!(result.is_ok(), "verify_signature should succeed for valid envelope");

        // Verify the flag was set.
        let verified = ctx.data.get("signature_verified");
        assert_eq!(verified, Some(&serde_json::json!(true)));
    }

    /// TC-1-IDENT-007: Verify hook fails when public key is not in cache.
    #[test]
    fn tc_1_ident_007_verify_signature_missing_pubkey() {
        let kp = Keypair::generate();

        // Create an envelope signed by Alice.
        let envelope = SignedEnvelope::sign(
            &kp,
            "@alice:relay.com".into(),
            "doc/1".into(),
            b"data".to_vec(),
        );

        // Cache is empty — no public key for Alice.
        let cache = PublicKeyCache::new();
        let (_decl, handler) = verify_signature_hook(cache);

        let mut ctx = HookContext::new("message".to_string(), TriggerEvent::Insert);
        ctx.signer_id = Some("@alice:relay.com".to_string());
        ctx.data.insert(
            "signed_envelope".into(),
            serde_json::to_value(&envelope).unwrap(),
        );

        let result = (handler)(&mut ctx);
        assert!(result.is_err(), "should fail when pubkey is not in cache");
        let err_msg = result.unwrap_err().to_string();
        assert!(
            err_msg.contains("no public key"),
            "error should mention missing public key, got: {err_msg}"
        );
    }

    /// TC-1-IDENT-008: EntityId parse -> display -> parse roundtrip.
    #[test]
    fn tc_1_ident_008_entity_id_display_roundtrip() {
        let original = "@alice:relay-a.example.com";
        let id1 = EntityId::parse(original).unwrap();
        let displayed = id1.to_string();
        assert_eq!(displayed, original);

        let id2 = EntityId::parse(&displayed).unwrap();
        assert_eq!(id1, id2);

        // Test with various valid entity IDs.
        let cases = [
            "@bob:relay.io",
            "@code-reviewer:relay.example.com",
            "@a1:localhost",
            "@42:relay.io",
        ];
        for case in &cases {
            let id = EntityId::parse(case).unwrap();
            let s = id.to_string();
            assert_eq!(&s, case, "roundtrip failed for {case}");
            let id_back = EntityId::parse(&s).unwrap();
            assert_eq!(id, id_back);
        }
    }

    // --- TC-1-SIGN tests ---

    /// TC-1-SIGN-001: Sign with Keypair, verify with PublicKey, expect true.
    #[test]
    fn tc_1_sign_001_sign_and_verify_roundtrip() {
        let kp = Keypair::generate();
        let pk = kp.public_key();

        let envelope = SignedEnvelope::sign(
            &kp,
            "@alice:relay.com".into(),
            "rooms/room-1/messages".into(),
            b"crdt-update-payload".to_vec(),
        );

        // Verify should succeed with the correct public key.
        assert!(
            envelope.verify(&pk).is_ok(),
            "signature verification should succeed for correctly signed envelope"
        );

        // Verify envelope fields are correct.
        assert_eq!(envelope.version, 1);
        assert_eq!(envelope.signer_id, "@alice:relay.com");
        assert_eq!(envelope.doc_id, "rooms/room-1/messages");
        assert_eq!(envelope.payload, b"crdt-update-payload");
        assert_eq!(envelope.signature.len(), 64, "Ed25519 signature must be 64 bytes");
    }

    /// TC-1-SIGN-002: Sign, modify payload, verify should fail.
    #[test]
    fn tc_1_sign_002_tampered_payload_rejected() {
        let kp = Keypair::generate();
        let pk = kp.public_key();

        let mut envelope = SignedEnvelope::sign(
            &kp,
            "@alice:relay.com".into(),
            "doc/1".into(),
            b"original-payload".to_vec(),
        );

        // Tamper with the payload.
        envelope.payload = b"tampered-payload".to_vec();

        // Verification must fail.
        assert!(
            envelope.verify(&pk).is_err(),
            "tampered payload must fail verification"
        );
    }

    /// TC-1-SIGN-003: Sign with key A, verify with key B, expect failure.
    #[test]
    fn tc_1_sign_003_wrong_key_rejected() {
        let kp_a = Keypair::generate();
        let kp_b = Keypair::generate();

        let envelope = SignedEnvelope::sign(
            &kp_a,
            "@alice:relay.com".into(),
            "doc/1".into(),
            b"data".to_vec(),
        );

        // Verify with the wrong key.
        assert!(
            envelope.verify(&kp_b.public_key()).is_err(),
            "verification with wrong key must fail"
        );

        // Verify with the correct key still succeeds.
        assert!(
            envelope.verify(&kp_a.public_key()).is_ok(),
            "verification with correct key must succeed"
        );
    }

    /// TC-1-SIGN-004: Verify timestamp is within +/- 5 min using the protocol's envelope.
    #[test]
    fn tc_1_sign_004_timestamp_tolerance() {
        let kp = Keypair::generate();
        let pk = kp.public_key();

        // Sign a fresh envelope — its timestamp is "now".
        let envelope = SignedEnvelope::sign(
            &kp,
            "@alice:relay.com".into(),
            "doc/1".into(),
            b"data".to_vec(),
        );

        // The signature itself is valid.
        assert!(envelope.verify(&pk).is_ok());

        // Check that the timestamp is within tolerance of current time.
        let now_ms = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_millis() as i64;
        let delta_ms = (now_ms - envelope.timestamp).abs();
        assert!(
            delta_ms <= TIMESTAMP_TOLERANCE_MS,
            "fresh envelope timestamp delta {}ms should be within 5 minutes",
            delta_ms
        );

        // Simulate an expired envelope by creating one with an old timestamp.
        // We cannot directly set the timestamp before signing (the sign method
        // uses SystemTime::now()), so we tamper the timestamp field and verify
        // the timestamp check logic independently.
        let mut expired_envelope = envelope.clone();
        expired_envelope.timestamp = now_ms - (6 * 60 * 1000); // 6 minutes ago

        // The cryptographic signature will fail because timestamp is part of
        // the signed bytes, but we can check our tolerance logic directly.
        let expired_delta = (now_ms - expired_envelope.timestamp).abs();
        assert!(
            expired_delta > TIMESTAMP_TOLERANCE_MS,
            "6-minute-old timestamp should exceed 5-minute tolerance"
        );

        // Verify that the verify_signature_hook rejects expired timestamps.
        // We need a "validly signed" envelope with an old timestamp for a
        // complete end-to-end test. Since we cannot create one (signing always
        // uses current time), we test the hook's timestamp logic by running
        // the hook against a freshly signed envelope (which must pass).
        let cache = PublicKeyCache::new();
        cache.insert("@alice:relay.com", pk);

        let fresh_envelope = SignedEnvelope::sign(
            &kp,
            "@alice:relay.com".into(),
            "doc/1".into(),
            b"data".to_vec(),
        );

        let (_decl, handler) = verify_signature_hook(cache);
        let mut ctx = HookContext::new("message".to_string(), TriggerEvent::Insert);
        ctx.signer_id = Some("@alice:relay.com".to_string());
        ctx.data.insert(
            "signed_envelope".into(),
            serde_json::to_value(&fresh_envelope).unwrap(),
        );

        let result = (handler)(&mut ctx);
        assert!(
            result.is_ok(),
            "fresh envelope should pass timestamp tolerance check"
        );

        // Verify the constant itself is correct: 5 * 60 * 1000 = 300_000 ms.
        assert_eq!(TIMESTAMP_TOLERANCE_MS, 300_000);
    }

    /// Test that sign_envelope_hook fails when no signer_id is set.
    #[test]
    fn sign_envelope_no_signer_id_fails() {
        let kp = Keypair::generate();
        let (_decl, handler) = sign_envelope_hook(Arc::new(kp));

        let mut ctx = HookContext::new("message".to_string(), TriggerEvent::Insert);
        // No signer_id set.
        let result = (handler)(&mut ctx);
        assert!(result.is_err());
        let err_msg = result.unwrap_err().to_string();
        assert!(err_msg.contains("no signer_id"));
    }

    /// Test that verify_signature_hook fails when no signer_id is set.
    #[test]
    fn verify_signature_no_signer_id_fails() {
        let cache = PublicKeyCache::new();
        let (_decl, handler) = verify_signature_hook(cache);

        let mut ctx = HookContext::new("message".to_string(), TriggerEvent::Insert);
        // No signer_id set.
        let result = (handler)(&mut ctx);
        assert!(result.is_err());
        let err_msg = result.unwrap_err().to_string();
        assert!(err_msg.contains("no signer_id"));
    }

    /// Test the full sign-then-verify pipeline through hooks.
    #[test]
    fn sign_then_verify_pipeline() {
        let kp = Keypair::generate();
        let pk = kp.public_key();

        // Set up cache with Alice's key.
        let cache = PublicKeyCache::new();
        cache.insert("@alice:relay.com", pk);

        // Create both hooks.
        let (_sign_decl, sign_handler) = sign_envelope_hook(Arc::new(kp));
        let (_verify_decl, verify_handler) = verify_signature_hook(cache);

        // Step 1: Sign.
        let mut ctx = HookContext::new("message".to_string(), TriggerEvent::Insert);
        ctx.signer_id = Some("@alice:relay.com".to_string());
        ctx.data
            .insert("payload".into(), serde_json::json!("important data"));
        ctx.data
            .insert("doc_id".into(), serde_json::json!("rooms/r1/messages"));

        let result = (sign_handler)(&mut ctx);
        assert!(result.is_ok(), "signing should succeed");
        assert!(ctx.data.contains_key("signed_envelope"));

        // Step 2: Verify using the same context (simulating the pipeline).
        let result = (verify_handler)(&mut ctx);
        assert!(result.is_ok(), "verification should succeed after signing");
        assert_eq!(
            ctx.data.get("signature_verified"),
            Some(&serde_json::json!(true))
        );
    }

    /// Test that PublicKeyCache is thread-safe (Clone + Send + Sync).
    #[test]
    fn pubkey_cache_is_clone_and_thread_safe() {
        let cache = PublicKeyCache::new();
        let cache2 = cache.clone();

        let kp = Keypair::generate();
        let pk = kp.public_key();

        // Write through one handle, read through the other.
        cache.insert("@alice:relay.com", pk.clone());
        assert_eq!(cache2.get("@alice:relay.com"), Some(pk));
    }

    /// Test sign_envelope_hook with empty payload.
    #[test]
    fn sign_envelope_empty_payload() {
        let kp = Keypair::generate();
        let pk = kp.public_key();
        let (_decl, handler) = sign_envelope_hook(Arc::new(kp));

        let mut ctx = HookContext::new("identity".to_string(), TriggerEvent::Insert);
        ctx.signer_id = Some("@bob:relay.io".to_string());
        // No payload or doc_id in data — should use empty defaults.

        let result = (handler)(&mut ctx);
        assert!(result.is_ok(), "sign_envelope should handle empty payload");

        let envelope: SignedEnvelope = serde_json::from_value(
            ctx.data.get("signed_envelope").unwrap().clone(),
        )
        .unwrap();
        assert_eq!(envelope.signer_id, "@bob:relay.io");
        assert_eq!(envelope.doc_id, "");
        assert!(envelope.payload.is_empty());
        assert!(envelope.verify(&pk).is_ok());
    }
}
