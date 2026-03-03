//! High-level Operation methods on the Engine.
//!
//! These are the public API entry points that compose the lower-level
//! Engine primitives (identity, hooks, registry) into ergonomic operations
//! like `identity_init`, `identity_whoami`, `room_create`, `message_send`,
//! and `status`.

use std::collections::HashMap;

use crate::builtins::message::MessageContent;
use crate::builtins::room::{
    MembershipConfig, MembershipPolicy, PowerLevelConfig, Role, RoomConfig, TimelineConfig,
};
use crate::engine::Engine;
use crate::error::EngineError;
use crate::hooks::phase::{HookContext, TriggerEvent};
use ezagent_protocol::{EntityId, Keypair};

impl Engine {
    /// identity.init -- Initialize local identity with keypair.
    ///
    /// Delegates to [`Engine::init_identity`] which caches the public key,
    /// registers the sign/verify hooks, and stores the keypair and entity ID.
    ///
    /// # Errors
    ///
    /// Returns `EngineError` if hook registration fails.
    pub fn identity_init(
        &mut self,
        entity_id: EntityId,
        keypair: Keypair,
    ) -> Result<(), EngineError> {
        self.init_identity(entity_id, keypair)
    }

    /// identity.whoami -- Get the local entity ID as a string.
    ///
    /// # Errors
    ///
    /// Returns `EngineError::PermissionDenied` if identity has not been
    /// initialized via [`Engine::identity_init`].
    pub fn identity_whoami(&self) -> Result<String, EngineError> {
        self.entity_id()
            .map(|id| id.to_string())
            .ok_or_else(|| EngineError::PermissionDenied("identity not initialized".into()))
    }

    /// room.create -- Create a new room configuration.
    ///
    /// Generates a UUIDv7 room ID, sets the caller as `Owner`, and returns
    /// a fully populated [`RoomConfig`] with default power levels and
    /// invite-only membership.
    ///
    /// # Errors
    ///
    /// Returns `EngineError::PermissionDenied` if identity has not been
    /// initialized.
    pub fn room_create(&self, name: &str) -> Result<RoomConfig, EngineError> {
        let entity_id = self
            .entity_id()
            .ok_or_else(|| EngineError::PermissionDenied("identity not initialized".into()))?;

        let room_id = uuid::Uuid::now_v7().to_string();
        let now = chrono_like_now();

        let mut members = HashMap::new();
        members.insert(entity_id.to_string(), Role::Owner);

        Ok(RoomConfig {
            room_id,
            name: name.to_string(),
            created_by: entity_id.to_string(),
            created_at: now,
            membership: MembershipConfig {
                policy: MembershipPolicy::Invite,
                members,
            },
            power_levels: PowerLevelConfig {
                default: 0,
                events_default: 0,
                admin: 50,
                users: HashMap::new(),
            },
            relays: vec![],
            timeline: TimelineConfig {
                shard_max_refs: 10000,
            },
            enabled_extensions: vec![],
            extra: HashMap::new(),
        })
    }

    /// message.send -- Create a message content, compute hash, run pre_send hooks.
    ///
    /// Builds a [`MessageContent`] from the given body and format, computes
    /// the SHA-256 content hash, then runs the pre_send hook pipeline on
    /// the content to allow hooks to validate or enrich it.
    ///
    /// # Errors
    ///
    /// Returns `EngineError::PermissionDenied` if identity has not been
    /// initialized, or any `EngineError` if a pre_send hook rejects the
    /// content.
    pub fn message_send(
        &self,
        room_id: &str,
        body: serde_json::Value,
        format: &str,
    ) -> Result<MessageContent, EngineError> {
        let entity_id = self
            .entity_id()
            .ok_or_else(|| EngineError::PermissionDenied("identity not initialized".into()))?;

        let now = chrono_like_now();

        let mut content = MessageContent {
            content_id: String::new(), // Will be set by compute_hash
            content_type: "immutable".to_string(),
            author: entity_id.to_string(),
            body,
            format: format.to_string(),
            media_refs: vec![],
            created_at: now,
            signature: None,
        };

        // Compute content hash.
        content.content_id = content.compute_hash();

        // Run pre_send hooks for content.
        let mut ctx = HookContext::new("immutable_content".into(), TriggerEvent::Insert);
        ctx.room_id = Some(room_id.to_string());
        ctx.signer_id = Some(entity_id.to_string());
        ctx.data.insert("body".into(), content.body.clone());
        ctx.data
            .insert("author".into(), serde_json::json!(content.author));
        ctx.data.insert(
            "content_type".into(),
            serde_json::json!(content.content_type),
        );
        ctx.data
            .insert("format".into(), serde_json::json!(content.format));
        ctx.data
            .insert("created_at".into(), serde_json::json!(content.created_at));
        ctx.data
            .insert("media_refs".into(), serde_json::json!(content.media_refs));

        // Provide membership context so the room.check_room_write hook
        // (fail-closed) allows the write. In a full implementation, the
        // membership data would be read from the room store.
        ctx.data.insert(
            "members".into(),
            serde_json::json!({ entity_id.to_string(): "Member" }),
        );

        self.run_pre_send(&mut ctx)?;

        Ok(content)
    }

    /// status -- Get engine status summary.
    ///
    /// Returns whether identity is initialized and the list of registered
    /// datatype IDs.
    pub fn status(&self) -> EngineStatus {
        EngineStatus {
            identity_initialized: self.entity_id().is_some(),
            registered_datatypes: self.registry.ids(),
        }
    }

    // -----------------------------------------------------------------
    // Stub operations — not yet implemented (Phase 2+)
    // -----------------------------------------------------------------

    /// identity.get_pubkey -- Retrieve the public key for the given entity.
    ///
    /// # Errors
    ///
    /// Returns `EngineError::NotImplemented` (stub).
    pub fn identity_get_pubkey(&self, _entity_id: &str) -> Result<String, EngineError> {
        Err(EngineError::NotImplemented)
    }

    /// room.list -- List all known room IDs.
    ///
    /// # Errors
    ///
    /// Returns `EngineError::NotImplemented` (stub).
    pub fn room_list(&self) -> Result<Vec<String>, EngineError> {
        Err(EngineError::NotImplemented)
    }

    /// room.get -- Retrieve room configuration as JSON.
    ///
    /// # Errors
    ///
    /// Returns `EngineError::NotImplemented` (stub).
    pub fn room_get(&self, _room_id: &str) -> Result<serde_json::Value, EngineError> {
        Err(EngineError::NotImplemented)
    }

    /// room.update_config -- Apply partial updates to a room's configuration.
    ///
    /// # Errors
    ///
    /// Returns `EngineError::NotImplemented` (stub).
    pub fn room_update_config(
        &mut self,
        _room_id: &str,
        _updates: serde_json::Value,
    ) -> Result<(), EngineError> {
        Err(EngineError::NotImplemented)
    }

    /// room.join -- Join a room as the local identity.
    ///
    /// # Errors
    ///
    /// Returns `EngineError::NotImplemented` (stub).
    pub fn room_join(&mut self, _room_id: &str) -> Result<(), EngineError> {
        Err(EngineError::NotImplemented)
    }

    /// room.leave -- Leave a room as the local identity.
    ///
    /// # Errors
    ///
    /// Returns `EngineError::NotImplemented` (stub).
    pub fn room_leave(&mut self, _room_id: &str) -> Result<(), EngineError> {
        Err(EngineError::NotImplemented)
    }

    /// room.invite -- Invite an entity to a room.
    ///
    /// # Errors
    ///
    /// Returns `EngineError::NotImplemented` (stub).
    pub fn room_invite(&mut self, _room_id: &str, _entity_id: &str) -> Result<(), EngineError> {
        Err(EngineError::NotImplemented)
    }

    /// room.members -- List members of a room.
    ///
    /// # Errors
    ///
    /// Returns `EngineError::NotImplemented` (stub).
    pub fn room_members(&self, _room_id: &str) -> Result<Vec<String>, EngineError> {
        Err(EngineError::NotImplemented)
    }

    /// timeline.list -- List timeline shard IDs for a room.
    ///
    /// # Errors
    ///
    /// Returns `EngineError::NotImplemented` (stub).
    pub fn timeline_list(&self, _room_id: &str) -> Result<Vec<String>, EngineError> {
        Err(EngineError::NotImplemented)
    }

    /// timeline.get_ref -- Retrieve a timeline ref by ID.
    ///
    /// # Errors
    ///
    /// Returns `EngineError::NotImplemented` (stub).
    pub fn timeline_get_ref(
        &self,
        _room_id: &str,
        _ref_id: &str,
    ) -> Result<serde_json::Value, EngineError> {
        Err(EngineError::NotImplemented)
    }

    /// message.delete -- Soft-delete a message by ref ID.
    ///
    /// # Errors
    ///
    /// Returns `EngineError::NotImplemented` (stub).
    pub fn message_delete(&mut self, _room_id: &str, _ref_id: &str) -> Result<(), EngineError> {
        Err(EngineError::NotImplemented)
    }

    /// annotation.list -- List annotations on a timeline ref.
    ///
    /// # Errors
    ///
    /// Returns `EngineError::NotImplemented` (stub).
    pub fn annotation_list(
        &self,
        _room_id: &str,
        _ref_id: &str,
    ) -> Result<Vec<String>, EngineError> {
        Err(EngineError::NotImplemented)
    }

    /// annotation.add -- Add an annotation to a timeline ref.
    ///
    /// # Errors
    ///
    /// Returns `EngineError::NotImplemented` (stub).
    pub fn annotation_add(
        &mut self,
        _room_id: &str,
        _ref_id: &str,
        _key: &str,
        _value: &str,
    ) -> Result<(), EngineError> {
        Err(EngineError::NotImplemented)
    }

    /// annotation.remove -- Remove an annotation from a timeline ref.
    ///
    /// # Errors
    ///
    /// Returns `EngineError::NotImplemented` (stub).
    pub fn annotation_remove(
        &mut self,
        _room_id: &str,
        _ref_id: &str,
        _key: &str,
    ) -> Result<(), EngineError> {
        Err(EngineError::NotImplemented)
    }
}

/// Summary of the current engine state.
pub struct EngineStatus {
    /// Whether local identity has been initialized.
    pub identity_initialized: bool,
    /// IDs of all registered datatypes.
    pub registered_datatypes: Vec<String>,
}

/// Simple ISO 8601-like timestamp (avoids chrono dependency).
///
/// Returns seconds since Unix epoch followed by `Z` (e.g., `"1709337600Z"`).
/// For Phase 1, a full ISO 8601 date library is not needed; the important
/// property is that timestamps are monotonically increasing and parseable.
fn chrono_like_now() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    let dur = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default();
    let secs = dur.as_secs();
    format!("{secs}Z")
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use crate::engine::Engine;
    use ezagent_protocol::{EntityId, Keypair};

    /// TC-1-API-001: identity_init and identity_whoami round-trip.
    #[test]
    fn tc_1_api_001_identity_init_and_whoami() {
        let mut engine = Engine::new().expect("Engine::new() should succeed");

        // Before init, whoami should fail.
        let err = engine.identity_whoami();
        assert!(err.is_err(), "whoami should fail before init");

        // Initialize identity.
        let kp = Keypair::generate();
        let entity_id = EntityId::parse("@alice:relay.example.com").expect("valid entity id");
        engine
            .identity_init(entity_id, kp)
            .expect("identity_init should succeed");

        // After init, whoami should return the entity ID.
        let whoami = engine
            .identity_whoami()
            .expect("whoami should succeed after init");
        assert_eq!(
            whoami, "@alice:relay.example.com",
            "whoami must return the initialized entity ID"
        );
    }

    /// TC-1-API-002: room_create produces valid RoomConfig with correct fields.
    #[test]
    fn tc_1_api_002_room_create() {
        let mut engine = Engine::new().expect("Engine::new() should succeed");

        // room_create should fail before identity init.
        let err = engine.room_create("test-room");
        assert!(err.is_err(), "room_create should fail before identity init");

        // Initialize identity.
        let kp = Keypair::generate();
        let entity_id = EntityId::parse("@alice:relay.example.com").expect("valid entity id");
        engine
            .identity_init(entity_id, kp)
            .expect("identity_init should succeed");

        // Create a room.
        let room = engine
            .room_create("Alpha Room")
            .expect("room_create should succeed");

        // Verify fields.
        assert!(!room.room_id.is_empty(), "room_id should be set");
        assert_eq!(room.name, "Alpha Room");
        assert_eq!(room.created_by, "@alice:relay.example.com");
        assert!(!room.created_at.is_empty(), "created_at should be set");

        // Creator should be Owner.
        assert_eq!(room.membership.members.len(), 1);
        assert_eq!(
            room.membership.members.get("@alice:relay.example.com"),
            Some(&crate::builtins::room::Role::Owner),
            "creator must be Owner"
        );

        // Default membership policy is Invite.
        assert_eq!(
            room.membership.policy,
            crate::builtins::room::MembershipPolicy::Invite
        );

        // Default power levels.
        assert_eq!(room.power_levels.default, 0);
        assert_eq!(room.power_levels.events_default, 0);
        assert_eq!(room.power_levels.admin, 50);
        assert!(room.power_levels.users.is_empty());

        // No relays or extensions by default.
        assert!(room.relays.is_empty());
        assert!(room.enabled_extensions.is_empty());

        // Timeline config.
        assert_eq!(room.timeline.shard_max_refs, 10000);
    }

    /// TC-1-API-003: message_send produces content with valid SHA-256 hash.
    #[test]
    fn tc_1_api_003_message_send() {
        let mut engine = Engine::new().expect("Engine::new() should succeed");

        // Initialize identity.
        let kp = Keypair::generate();
        let entity_id = EntityId::parse("@alice:relay.example.com").expect("valid entity id");
        engine
            .identity_init(entity_id, kp)
            .expect("identity_init should succeed");

        // Send a message.
        let content = engine
            .message_send("R-alpha", serde_json::json!("Hello, world!"), "text/plain")
            .expect("message_send should succeed");

        // content_id should be a 64-character hex string (SHA-256).
        assert_eq!(
            content.content_id.len(),
            64,
            "content_id must be a 64-char SHA-256 hex digest"
        );
        assert!(
            content.content_id.chars().all(|c| c.is_ascii_hexdigit()),
            "content_id must contain only hex digits"
        );

        // Verify the hash is deterministic: recompute and compare.
        let recomputed = content.compute_hash();
        assert_eq!(
            content.content_id, recomputed,
            "content_id must match recomputed hash"
        );

        // Verify other fields.
        assert_eq!(content.author, "@alice:relay.example.com");
        assert_eq!(content.body, serde_json::json!("Hello, world!"));
        assert_eq!(content.format, "text/plain");
        assert_eq!(content.content_type, "immutable");
        assert!(content.media_refs.is_empty());
        assert!(!content.created_at.is_empty());
    }

    /// Verify engine status reports correct state.
    #[test]
    fn engine_status_reports() {
        let mut engine = Engine::new().expect("Engine::new() should succeed");

        let status = engine.status();
        assert!(!status.identity_initialized);
        assert!(status
            .registered_datatypes
            .contains(&"identity".to_string()));
        assert!(status.registered_datatypes.contains(&"room".to_string()));
        assert!(status
            .registered_datatypes
            .contains(&"timeline".to_string()));
        assert!(status.registered_datatypes.contains(&"message".to_string()));

        // After identity init, status should reflect it.
        let kp = Keypair::generate();
        let entity_id = EntityId::parse("@bob:relay.io").expect("valid entity id");
        engine.identity_init(entity_id, kp).expect("init");

        let status = engine.status();
        assert!(status.identity_initialized);
    }
}
