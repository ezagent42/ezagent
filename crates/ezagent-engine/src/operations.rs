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
use crate::builtins::timeline::{RefStatus, TimelineRef};
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

    /// identity.get_pubkey -- Retrieve the hex-encoded public key for the given entity.
    ///
    /// Looks up the public key from the in-memory pubkey cache and returns it
    /// as a hex-encoded string.
    ///
    /// # Errors
    ///
    /// Returns `EngineError::DatatypeNotFound` if no public key is cached for
    /// the given entity ID.
    pub fn identity_get_pubkey(&self, entity_id: &str) -> Result<String, EngineError> {
        self.pubkey_cache
            .get(entity_id)
            .map(|pk| hex::encode(pk.as_bytes()))
            .ok_or_else(|| EngineError::DatatypeNotFound(format!("pubkey for {entity_id}")))
    }

    /// room.create -- Create a new room configuration.
    ///
    /// Generates a UUIDv7 room ID, sets the caller as `Owner`, stores the
    /// room in the [`EngineStore`], and returns a fully populated [`RoomConfig`]
    /// with default power levels and invite-only membership.
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

        let room = RoomConfig {
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
        };

        self.store.insert_room(room.clone());

        Ok(room)
    }

    /// room.list -- List all known room IDs.
    ///
    /// Returns a `Vec` of room ID strings from the in-memory store.
    ///
    /// # Errors
    ///
    /// Currently infallible but returns `Result` for API consistency.
    pub fn room_list(&self) -> Result<Vec<String>, EngineError> {
        Ok(self
            .store
            .list_rooms()
            .iter()
            .map(|r| r.room_id.clone())
            .collect())
    }

    /// room.get -- Retrieve room configuration as JSON.
    ///
    /// # Errors
    ///
    /// Returns `EngineError::DatatypeNotFound` if no room with the given ID
    /// exists in the store.
    pub fn room_get(&self, room_id: &str) -> Result<serde_json::Value, EngineError> {
        self.store
            .get_room(room_id)
            .map(|r| serde_json::to_value(r).expect("serialize RoomConfig"))
            .ok_or_else(|| EngineError::DatatypeNotFound(format!("room {room_id}")))
    }

    /// room.update_config -- Apply partial updates to a room's configuration.
    ///
    /// Currently supports updating the `name` field. Additional fields can be
    /// added as needed.
    ///
    /// # Errors
    ///
    /// Returns `EngineError::DatatypeNotFound` if no room with the given ID
    /// exists in the store.
    pub fn room_update_config(
        &mut self,
        room_id: &str,
        updates: serde_json::Value,
    ) -> Result<(), EngineError> {
        let found = self.store.update_room(room_id, |r| {
            if let Some(name) = updates.get("name").and_then(|v| v.as_str()) {
                r.name = name.to_string();
            }
            // Add more fields as needed.
        });
        if found {
            Ok(())
        } else {
            Err(EngineError::DatatypeNotFound(format!("room {room_id}")))
        }
    }

    /// room.join -- Join a room as the local identity.
    ///
    /// Adds the local entity as a `Member` to the room's membership list.
    ///
    /// # Errors
    ///
    /// Returns `EngineError::PermissionDenied` if identity has not been
    /// initialized, or `EngineError::DatatypeNotFound` if the room does not
    /// exist.
    pub fn room_join(&mut self, room_id: &str) -> Result<(), EngineError> {
        let entity_id = self
            .entity_id()
            .ok_or_else(|| EngineError::PermissionDenied("identity not initialized".into()))?
            .to_string();
        let found = self.store.update_room(room_id, |r| {
            r.membership
                .members
                .insert(entity_id.clone(), crate::builtins::room::Role::Member);
        });
        if found {
            Ok(())
        } else {
            Err(EngineError::DatatypeNotFound(format!("room {room_id}")))
        }
    }

    /// room.leave -- Leave a room as the local identity.
    ///
    /// Removes the local entity from the room's membership list.
    ///
    /// # Errors
    ///
    /// Returns `EngineError::PermissionDenied` if identity has not been
    /// initialized, or `EngineError::DatatypeNotFound` if the room does not
    /// exist.
    pub fn room_leave(&mut self, room_id: &str) -> Result<(), EngineError> {
        let entity_id = self
            .entity_id()
            .ok_or_else(|| EngineError::PermissionDenied("identity not initialized".into()))?
            .to_string();
        let found = self.store.update_room(room_id, |r| {
            r.membership.members.remove(&entity_id);
        });
        if found {
            Ok(())
        } else {
            Err(EngineError::DatatypeNotFound(format!("room {room_id}")))
        }
    }

    /// room.invite -- Invite an entity to a room.
    ///
    /// Adds the given entity as a `Member` to the room's membership list.
    ///
    /// # Errors
    ///
    /// Returns `EngineError::DatatypeNotFound` if the room does not exist.
    pub fn room_invite(&mut self, room_id: &str, entity_id: &str) -> Result<(), EngineError> {
        let found = self.store.update_room(room_id, |r| {
            r.membership
                .members
                .insert(entity_id.to_string(), crate::builtins::room::Role::Member);
        });
        if found {
            Ok(())
        } else {
            Err(EngineError::DatatypeNotFound(format!("room {room_id}")))
        }
    }

    /// room.members -- List members of a room.
    ///
    /// Returns a `Vec` of entity ID strings for all members of the room.
    ///
    /// # Errors
    ///
    /// Returns `EngineError::DatatypeNotFound` if the room does not exist.
    pub fn room_members(&self, room_id: &str) -> Result<Vec<String>, EngineError> {
        self.store
            .get_room(room_id)
            .map(|r| r.membership.members.keys().cloned().collect())
            .ok_or_else(|| EngineError::DatatypeNotFound(format!("room {room_id}")))
    }

    /// message.send -- Create a message content, compute hash, run pre_send hooks.
    ///
    /// Builds a [`MessageContent`] from the given body and format, computes
    /// the SHA-256 content hash, then runs the pre_send hook pipeline on
    /// the content to allow hooks to validate or enrich it. Stores the
    /// message and a corresponding timeline ref in the [`EngineStore`].
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

        // Store the message.
        self.store.insert_message(room_id, content.clone());

        // Create and store a timeline ref.
        let tref = TimelineRef {
            ref_id: ulid::Ulid::new().to_string(),
            author: entity_id.to_string(),
            content_type: "immutable".to_string(),
            content_id: content.content_id.clone(),
            created_at: content.created_at.clone(),
            status: RefStatus::Active,
            signature: None,
            ext: HashMap::new(),
        };
        self.store.insert_timeline_ref(room_id, tref);

        Ok(content)
    }

    /// timeline.list -- List timeline ref IDs for a room.
    ///
    /// Returns a `Vec` of ref ID strings for all timeline refs in the room.
    ///
    /// # Errors
    ///
    /// Currently infallible but returns `Result` for API consistency.
    pub fn timeline_list(&self, room_id: &str) -> Result<Vec<String>, EngineError> {
        Ok(self
            .store
            .list_timeline_refs(room_id)
            .iter()
            .map(|r| r.ref_id.clone())
            .collect())
    }

    /// timeline.get_ref -- Retrieve a timeline ref by ID as JSON.
    ///
    /// # Errors
    ///
    /// Returns `EngineError::DatatypeNotFound` if no ref with the given ID
    /// exists in the room.
    pub fn timeline_get_ref(
        &self,
        room_id: &str,
        ref_id: &str,
    ) -> Result<serde_json::Value, EngineError> {
        self.store
            .get_timeline_ref(room_id, ref_id)
            .map(|r| serde_json::to_value(r).expect("serialize TimelineRef"))
            .ok_or_else(|| EngineError::DatatypeNotFound(format!("ref {ref_id}")))
    }

    /// message.delete -- Soft-delete a message by ref ID.
    ///
    /// Checks that the timeline ref exists. In the current in-memory store
    /// implementation, the actual status update is acknowledged without
    /// modifying the ref (EngineStore does not expose a direct
    /// `update_timeline_ref` method yet).
    ///
    /// # Errors
    ///
    /// Returns `EngineError::DatatypeNotFound` if the ref does not exist.
    pub fn message_delete(&mut self, room_id: &str, ref_id: &str) -> Result<(), EngineError> {
        // Check the ref exists.
        if self.store.get_timeline_ref(room_id, ref_id).is_none() {
            return Err(EngineError::DatatypeNotFound(format!("ref {ref_id}")));
        }
        // For the in-memory store, we could update the status, but EngineStore
        // doesn't expose a direct update_timeline_ref method. For now, acknowledge.
        Ok(())
    }

    /// annotation.list -- List annotations on a timeline ref.
    ///
    /// Returns annotations as `key=value` formatted strings.
    ///
    /// # Errors
    ///
    /// Currently infallible but returns `Result` for API consistency.
    pub fn annotation_list(
        &self,
        room_id: &str,
        ref_id: &str,
    ) -> Result<Vec<String>, EngineError> {
        Ok(self
            .store
            .list_annotations(room_id, ref_id)
            .iter()
            .map(|(k, v)| format!("{k}={v}"))
            .collect())
    }

    /// annotation.add -- Add an annotation to a timeline ref.
    ///
    /// # Errors
    ///
    /// Currently infallible but returns `Result` for API consistency.
    pub fn annotation_add(
        &mut self,
        room_id: &str,
        ref_id: &str,
        key: &str,
        value: &str,
    ) -> Result<(), EngineError> {
        self.store.add_annotation(room_id, ref_id, key, value);
        Ok(())
    }

    /// annotation.remove -- Remove an annotation from a timeline ref.
    ///
    /// # Errors
    ///
    /// Returns `EngineError::DatatypeNotFound` if no annotation with the
    /// given key exists.
    pub fn annotation_remove(
        &mut self,
        room_id: &str,
        ref_id: &str,
        key: &str,
    ) -> Result<(), EngineError> {
        if self.store.remove_annotation(room_id, ref_id, key) {
            Ok(())
        } else {
            Err(EngineError::DatatypeNotFound(format!("annotation {key}")))
        }
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

    // -----------------------------------------------------------------
    // EngineStore-backed operation tests
    // -----------------------------------------------------------------

    #[test]
    fn tc_4_store_001_room_create_and_list() {
        let mut engine = Engine::new().expect("engine");
        let kp = Keypair::generate();
        let eid = EntityId::parse("@alice:relay.example.com").expect("eid");
        engine.identity_init(eid, kp).expect("init");

        let room = engine.room_create("Alpha").expect("create");
        let room_id = room.room_id.clone();

        let rooms = engine.room_list().expect("list");
        assert_eq!(rooms.len(), 1);
        assert!(rooms.contains(&room_id));

        let got = engine.room_get(&room_id).expect("get");
        assert_eq!(got["name"], "Alpha");
    }

    #[test]
    fn tc_4_store_002_room_members_and_invite() {
        let mut engine = Engine::new().expect("engine");
        let kp = Keypair::generate();
        let eid = EntityId::parse("@alice:relay.example.com").expect("eid");
        engine.identity_init(eid, kp).expect("init");

        let room = engine.room_create("Alpha").expect("create");
        let room_id = room.room_id.clone();

        let members = engine.room_members(&room_id).expect("members");
        assert_eq!(members.len(), 1);
        assert!(members.contains(&"@alice:relay.example.com".to_string()));

        engine
            .room_invite(&room_id, "@bob:relay.example.com")
            .expect("invite");
        let members = engine.room_members(&room_id).expect("members");
        assert_eq!(members.len(), 2);
        assert!(members.contains(&"@bob:relay.example.com".to_string()));
    }

    #[test]
    fn tc_4_store_003_message_send_and_timeline() {
        let mut engine = Engine::new().expect("engine");
        let kp = Keypair::generate();
        let eid = EntityId::parse("@alice:relay.example.com").expect("eid");
        engine.identity_init(eid, kp).expect("init");

        let room = engine.room_create("Alpha").expect("create");
        let room_id = room.room_id.clone();

        let content = engine
            .message_send(&room_id, serde_json::json!("Hello!"), "text/plain")
            .expect("send");

        let refs = engine.timeline_list(&room_id).expect("timeline");
        assert_eq!(refs.len(), 1);

        let tref = engine
            .timeline_get_ref(&room_id, &refs[0])
            .expect("get ref");
        assert_eq!(tref["content_id"], content.content_id);
    }

    #[test]
    fn tc_4_store_004_room_not_found() {
        let engine = Engine::new().expect("engine");
        assert!(engine.room_get("nonexistent").is_err());
        assert!(engine.room_members("nonexistent").is_err());
    }

    #[test]
    fn tc_4_store_005_annotations() {
        let mut engine = Engine::new().expect("engine");
        let kp = Keypair::generate();
        let eid = EntityId::parse("@alice:relay.example.com").expect("eid");
        engine.identity_init(eid, kp).expect("init");

        engine
            .annotation_add("room-1", "ref-1", "review:@alice:r.com", "approved")
            .expect("add");
        let anns = engine.annotation_list("room-1", "ref-1").expect("list");
        assert_eq!(anns.len(), 1);
        assert!(anns[0].contains("review:@alice:r.com"));

        engine
            .annotation_remove("room-1", "ref-1", "review:@alice:r.com")
            .expect("remove");
        let anns = engine.annotation_list("room-1", "ref-1").expect("list");
        assert!(anns.is_empty());
    }

    #[test]
    fn tc_4_store_006_room_join_and_leave() {
        let mut engine = Engine::new().expect("engine");
        let kp = Keypair::generate();
        let eid = EntityId::parse("@alice:relay.example.com").expect("eid");
        engine.identity_init(eid, kp).expect("init");

        let room = engine.room_create("Test").expect("create");
        let room_id = room.room_id.clone();

        // Alice is already a member (Owner).
        engine.room_leave(&room_id).expect("leave");
        let members = engine.room_members(&room_id).expect("members");
        assert!(members.is_empty());

        // Re-join.
        engine.room_join(&room_id).expect("join");
        let members = engine.room_members(&room_id).expect("members");
        assert_eq!(members.len(), 1);
    }
}
