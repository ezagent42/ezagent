//! Room built-in datatype — room configuration, membership management,
//! power levels, and permission hooks.
//!
//! The Room datatype manages room-level configuration including membership,
//! power levels, relay assignments, timeline settings, and extension activation.
//! It declares four hooks:
//!
//! - `room.check_room_write` (pre_send, global `*`, p=10): verify signer is a room member
//! - `room.check_config_permission` (pre_send, `room_config`, p=20): verify admin+ power level
//! - `room.extension_loader` (after_write, `room_config`, p=10): detect extension changes
//! - `room.member_change_notify` (after_write, `room_config`, p=50): detect membership changes

use std::collections::HashMap;
use std::sync::Arc;

use serde::{Deserialize, Serialize};

use ezagent_protocol::KeyPattern;

use crate::error::EngineError;
use crate::hooks::executor::HookFn;
use crate::hooks::phase::{HookContext, HookDeclaration, HookPhase, TriggerEvent};
use crate::registry::datatype::*;

// ---------------------------------------------------------------------------
// Room Config Schema
// ---------------------------------------------------------------------------

/// Policy controlling how new members may join the room.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum MembershipPolicy {
    /// Anyone can join without approval.
    Open,
    /// Users must request to join; admins approve.
    Knock,
    /// Users can only join when explicitly invited by an admin+.
    Invite,
}

/// The role assigned to a member within a room.
///
/// Each role maps to a fixed power level used by the permission hooks.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum Role {
    /// Room owner — power level 100.
    Owner,
    /// Room administrator — power level 50.
    Admin,
    /// Regular member — power level 0.
    Member,
}

impl Role {
    /// Return the numeric power level for this role.
    ///
    /// Owner = 100, Admin = 50, Member = 0.
    pub fn power_level(&self) -> u32 {
        match self {
            Role::Owner => 100,
            Role::Admin => 50,
            Role::Member => 0,
        }
    }
}

/// Complete room configuration stored as a CRDT Map.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RoomConfig {
    /// Unique room identifier.
    pub room_id: String,
    /// Human-readable room name.
    pub name: String,
    /// Entity ID of the room creator.
    pub created_by: String,
    /// ISO 8601 timestamp of room creation.
    pub created_at: String,
    /// Membership configuration (policy + member roster).
    pub membership: MembershipConfig,
    /// Power level configuration.
    pub power_levels: PowerLevelConfig,
    /// List of relay domains this room replicates to.
    pub relays: Vec<String>,
    /// Timeline configuration.
    pub timeline: TimelineConfig,
    /// List of extension IDs currently enabled in this room.
    pub enabled_extensions: Vec<String>,
    /// Extension-owned extra fields (`ext.*` namespace). Preserved across
    /// serialization round-trips so that unknown extension data is not lost.
    #[serde(flatten)]
    pub extra: HashMap<String, serde_json::Value>,
}

/// Membership section of the room configuration.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MembershipConfig {
    /// The policy controlling how new members join.
    pub policy: MembershipPolicy,
    /// Map of entity_id to their Role in the room.
    pub members: HashMap<String, Role>,
}

/// Power level thresholds for the room.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PowerLevelConfig {
    /// Default power level for new members (typically 0).
    pub default: u32,
    /// Default power level required to send events (typically 0).
    pub events_default: u32,
    /// Minimum power level required for admin operations (typically 50).
    pub admin: u32,
    /// Per-user power level overrides.
    pub users: HashMap<String, u32>,
}

/// Timeline configuration for the room.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TimelineConfig {
    /// Maximum number of references per monthly shard (default 10000).
    pub shard_max_refs: u64,
}

// ---------------------------------------------------------------------------
// Datatype Declaration
// ---------------------------------------------------------------------------

/// Return the Room datatype declaration.
///
/// The Room datatype has a single data entry `room_config` stored as a CrdtMap
/// at `ezagent/{room_id}/config/{state|updates}`. It depends on the Identity
/// datatype.
pub fn room_datatype() -> DatatypeDeclaration {
    DatatypeDeclaration {
        id: "room".to_string(),
        version: "0.1.0".to_string(),
        dependencies: vec!["identity".to_string()],
        data_entries: vec![DataEntry {
            id: "room_config".to_string(),
            storage_type: StorageType::CrdtMap,
            key_pattern: KeyPattern::new("ezagent/{room_id}/config/{state|updates}"),
            persistent: true,
            writer_rule: WriterRule::SignerPowerLevel { min_level: 50 },
            sync_strategy: SyncMode::Eager,
        }],
        indexes: vec![],
        hooks: vec![],
        is_builtin: true,
    }
}

// ---------------------------------------------------------------------------
// Helper: extract members map from HookContext
// ---------------------------------------------------------------------------

/// Parse the `members` field from `ctx.data` into a `HashMap<String, Role>`.
///
/// Expects `ctx.data["members"]` to be a JSON object mapping entity_id strings
/// to role strings (e.g., `{"@alice:relay.com": "Owner", "@bob:relay.com": "Member"}`).
///
/// Returns an empty map if the field is missing or cannot be parsed.
fn parse_members(ctx: &HookContext) -> HashMap<String, Role> {
    let Some(members_val) = ctx.data.get("members") else {
        return HashMap::new();
    };

    let Some(obj) = members_val.as_object() else {
        return HashMap::new();
    };

    let mut result = HashMap::new();
    for (entity_id, role_val) in obj {
        if let Some(role_str) = role_val.as_str() {
            let role = match role_str {
                "Owner" => Role::Owner,
                "Admin" => Role::Admin,
                "Member" => Role::Member,
                _ => continue,
            };
            result.insert(entity_id.clone(), role);
        }
    }
    result
}

// ---------------------------------------------------------------------------
// Hook 1: room.check_room_write (pre_send, global, p=10)
// ---------------------------------------------------------------------------

/// Create the `room.check_room_write` hook.
///
/// This is a **global** pre_send hook (trigger_datatype: `"*"`, priority 10) that
/// verifies the signer is a member of the room. It reads `ctx.signer_id` and
/// `ctx.data["members"]` (a JSON map of entity_id -> role string).
///
/// If the signer is not found in the members map, the context is rejected with
/// reason `"NOT_A_MEMBER"`.
pub fn check_room_write_hook() -> (HookDeclaration, HookFn) {
    let decl = HookDeclaration {
        id: "room.check_room_write".to_string(),
        phase: HookPhase::PreSend,
        trigger_datatype: "*".to_string(),
        trigger_event: TriggerEvent::Any,
        trigger_filter: None,
        priority: 10,
        source: "room".to_string(),
    };

    let handler: HookFn = Arc::new(|ctx: &mut HookContext| {
        let signer_id = ctx
            .signer_id
            .clone()
            .ok_or_else(|| EngineError::PermissionDenied("no signer_id in context".into()))?;

        let members = parse_members(ctx);

        if members.is_empty() {
            // If the operation is not room-scoped (no room_id), skip the
            // membership check — this hook cannot apply.
            if ctx.room_id.is_none() {
                return Ok(());
            }
            // Fail-closed: room-scoped write with no membership data
            // available must be denied.
            let room_id = ctx.room_id.clone().unwrap_or_default();
            ctx.reject("NOT_A_MEMBER");
            return Err(EngineError::NotAMember {
                entity_id: signer_id,
                room_id: format!(
                    "{} — no membership data available — write denied (fail-closed)",
                    room_id
                ),
            });
        }

        if !members.contains_key(&signer_id) {
            let room_id = ctx.room_id.clone().unwrap_or_default();
            ctx.reject("NOT_A_MEMBER");
            return Err(EngineError::NotAMember {
                entity_id: signer_id,
                room_id,
            });
        }

        Ok(())
    });

    (decl, handler)
}

// ---------------------------------------------------------------------------
// Hook 2: room.check_config_permission (pre_send, room_config, p=20)
// ---------------------------------------------------------------------------

/// Create the `room.check_config_permission` hook.
///
/// This hook runs in the `PreSend` phase on `room_config` writes (priority 20).
/// It verifies that the signer's power level is >= 50 (Admin or Owner).
///
/// Reads `ctx.signer_id` and `ctx.data["members"]` to determine the signer's
/// role and power level. If the power level is insufficient, the context is
/// rejected with reason `"INSUFFICIENT_POWER_LEVEL"`.
pub fn check_config_permission_hook() -> (HookDeclaration, HookFn) {
    let decl = HookDeclaration {
        id: "room.check_config_permission".to_string(),
        phase: HookPhase::PreSend,
        trigger_datatype: "room_config".to_string(),
        trigger_event: TriggerEvent::Any,
        trigger_filter: None,
        priority: 20,
        source: "room".to_string(),
    };

    let handler: HookFn = Arc::new(|ctx: &mut HookContext| {
        let signer_id = ctx
            .signer_id
            .clone()
            .ok_or_else(|| EngineError::PermissionDenied("no signer_id in context".into()))?;

        let members = parse_members(ctx);

        let power_level = members
            .get(&signer_id)
            .map(|role| role.power_level())
            .unwrap_or(0);

        if power_level < 50 {
            ctx.reject("INSUFFICIENT_POWER_LEVEL");
            return Err(EngineError::PermissionDenied(format!(
                "power_level {} < 50 for {}",
                power_level, signer_id
            )));
        }

        Ok(())
    });

    (decl, handler)
}

// ---------------------------------------------------------------------------
// Hook 3: room.extension_loader (after_write, room_config, p=10)
// ---------------------------------------------------------------------------

/// Create the `room.extension_loader` hook.
///
/// This hook runs in the `AfterWrite` phase on `room_config` writes (priority 10).
/// It compares the old and new `enabled_extensions` lists (from
/// `ctx.data["old_enabled_extensions"]` and `ctx.data["enabled_extensions"]`)
/// and logs any added or removed extensions.
///
/// Since this is an AfterWrite hook, errors are logged but do not abort.
pub fn extension_loader_hook() -> (HookDeclaration, HookFn) {
    let decl = HookDeclaration {
        id: "room.extension_loader".to_string(),
        phase: HookPhase::AfterWrite,
        trigger_datatype: "room_config".to_string(),
        trigger_event: TriggerEvent::Any,
        trigger_filter: None,
        priority: 10,
        source: "room".to_string(),
    };

    let handler: HookFn = Arc::new(|ctx: &mut HookContext| {
        let old_exts = extract_string_list(ctx.data.get("old_enabled_extensions"));
        let new_exts = extract_string_list(ctx.data.get("enabled_extensions"));

        // Detect added extensions.
        let added: Vec<&String> = new_exts.iter().filter(|e| !old_exts.contains(e)).collect();
        // Detect removed extensions.
        let removed: Vec<&String> = old_exts.iter().filter(|e| !new_exts.contains(e)).collect();

        if !added.is_empty() || !removed.is_empty() {
            let room_id = ctx.room_id.clone().unwrap_or_default();
            // Store the diff in context for downstream consumers.
            ctx.data
                .insert("extensions_added".into(), serde_json::json!(added));
            ctx.data
                .insert("extensions_removed".into(), serde_json::json!(removed));
            eprintln!(
                "[room.extension_loader] room={}: added={:?}, removed={:?}",
                room_id, added, removed
            );
        }

        Ok(())
    });

    (decl, handler)
}

/// Extract a `Vec<String>` from an optional JSON value that should be an array of strings.
fn extract_string_list(val: Option<&serde_json::Value>) -> Vec<String> {
    val.and_then(|v| v.as_array())
        .map(|arr| {
            arr.iter()
                .filter_map(|item| item.as_str().map(String::from))
                .collect()
        })
        .unwrap_or_default()
}

// ---------------------------------------------------------------------------
// Hook 4: room.member_change_notify (after_write, room_config, p=50)
// ---------------------------------------------------------------------------

/// Create the `room.member_change_notify` hook.
///
/// This hook runs in the `AfterWrite` phase on `room_config` writes (priority 50).
/// It compares the old members list (`ctx.data["old_members"]`) with the current
/// members list (`ctx.data["members"]`) and detects additions and removals.
///
/// Stores `members_added` and `members_removed` in `ctx.data` for event emission.
pub fn member_change_notify_hook() -> (HookDeclaration, HookFn) {
    let decl = HookDeclaration {
        id: "room.member_change_notify".to_string(),
        phase: HookPhase::AfterWrite,
        trigger_datatype: "room_config".to_string(),
        trigger_event: TriggerEvent::Any,
        trigger_filter: None,
        priority: 50,
        source: "room".to_string(),
    };

    let handler: HookFn = Arc::new(|ctx: &mut HookContext| {
        let old_members = extract_member_keys(ctx.data.get("old_members"));
        let new_members = extract_member_keys(ctx.data.get("members"));

        let added: Vec<&String> = new_members
            .iter()
            .filter(|m| !old_members.contains(m))
            .collect();
        let removed: Vec<&String> = old_members
            .iter()
            .filter(|m| !new_members.contains(m))
            .collect();

        if !added.is_empty() || !removed.is_empty() {
            let room_id = ctx.room_id.clone().unwrap_or_default();
            ctx.data
                .insert("members_added".into(), serde_json::json!(added));
            ctx.data
                .insert("members_removed".into(), serde_json::json!(removed));
            eprintln!(
                "[room.member_change_notify] room={}: added={:?}, removed={:?}",
                room_id, added, removed
            );
        }

        Ok(())
    });

    (decl, handler)
}

/// Extract a list of member entity_ids (the keys) from a JSON object value.
fn extract_member_keys(val: Option<&serde_json::Value>) -> Vec<String> {
    val.and_then(|v| v.as_object())
        .map(|obj| obj.keys().cloned().collect())
        .unwrap_or_default()
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    /// Helper to build a members JSON object from a list of (entity_id, role_str) pairs.
    fn members_json(pairs: &[(&str, &str)]) -> serde_json::Value {
        let mut map = serde_json::Map::new();
        for (id, role) in pairs {
            map.insert((*id).to_string(), serde_json::json!(*role));
        }
        serde_json::Value::Object(map)
    }

    /// TC-1-ROOM-001: Create RoomConfig, serialize/deserialize, verify fields.
    #[test]
    fn tc_1_room_001_room_config_schema() {
        let mut members = HashMap::new();
        members.insert("@alice:relay.example.com".to_string(), Role::Owner);
        members.insert("@bob:relay.example.com".to_string(), Role::Member);

        let config = RoomConfig {
            room_id: "R-alpha".to_string(),
            name: "Alpha Room".to_string(),
            created_by: "@alice:relay.example.com".to_string(),
            created_at: "2026-03-01T00:00:00Z".to_string(),
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
            relays: vec!["relay.example.com".to_string()],
            timeline: TimelineConfig {
                shard_max_refs: 10000,
            },
            enabled_extensions: vec!["EXT-01".to_string(), "EXT-03".to_string()],
            extra: HashMap::new(),
        };

        // Serialize to JSON.
        let json = serde_json::to_string(&config).expect("serialization should succeed");

        // Deserialize back.
        let deserialized: RoomConfig =
            serde_json::from_str(&json).expect("deserialization should succeed");

        // Verify all fields survived the roundtrip.
        assert_eq!(deserialized.room_id, "R-alpha");
        assert_eq!(deserialized.name, "Alpha Room");
        assert_eq!(deserialized.created_by, "@alice:relay.example.com");
        assert_eq!(deserialized.created_at, "2026-03-01T00:00:00Z");
        assert_eq!(deserialized.membership.policy, MembershipPolicy::Invite);
        assert_eq!(deserialized.membership.members.len(), 2);
        assert_eq!(
            deserialized
                .membership
                .members
                .get("@alice:relay.example.com"),
            Some(&Role::Owner)
        );
        assert_eq!(
            deserialized
                .membership
                .members
                .get("@bob:relay.example.com"),
            Some(&Role::Member)
        );
        assert_eq!(deserialized.power_levels.default, 0);
        assert_eq!(deserialized.power_levels.events_default, 0);
        assert_eq!(deserialized.power_levels.admin, 50);
        assert!(deserialized.power_levels.users.is_empty());
        assert_eq!(deserialized.relays, vec!["relay.example.com"]);
        assert_eq!(deserialized.timeline.shard_max_refs, 10000);
        assert_eq!(deserialized.enabled_extensions, vec!["EXT-01", "EXT-03"]);
    }

    /// TC-1-ROOM-002: MembershipPolicy variants Open, Knock, Invite are distinct.
    #[test]
    fn tc_1_room_002_membership_policy_variants() {
        let open = MembershipPolicy::Open;
        let knock = MembershipPolicy::Knock;
        let invite = MembershipPolicy::Invite;

        // All three are distinct.
        assert_ne!(open, knock);
        assert_ne!(open, invite);
        assert_ne!(knock, invite);

        // Each is equal to itself.
        assert_eq!(open, MembershipPolicy::Open);
        assert_eq!(knock, MembershipPolicy::Knock);
        assert_eq!(invite, MembershipPolicy::Invite);

        // Serde roundtrip preserves variants.
        for policy in &[open, knock, invite] {
            let json = serde_json::to_string(policy).expect("serialize policy");
            let roundtripped: MembershipPolicy =
                serde_json::from_str(&json).expect("deserialize policy");
            assert_eq!(policy, &roundtripped);
        }
    }

    /// TC-1-ROOM-003: Power level values — Owner=100, Admin=50, Member=0.
    #[test]
    fn tc_1_room_003_power_level_values() {
        assert_eq!(Role::Owner.power_level(), 100);
        assert_eq!(Role::Admin.power_level(), 50);
        assert_eq!(Role::Member.power_level(), 0);

        // Verify ordering: Owner > Admin > Member.
        assert!(Role::Owner.power_level() > Role::Admin.power_level());
        assert!(Role::Admin.power_level() > Role::Member.power_level());
    }

    /// TC-1-ROOM-004: check_room_write allows a member.
    #[test]
    fn tc_1_room_004_check_room_write_allows_member() {
        let (_decl, handler) = check_room_write_hook();

        let mut ctx = HookContext::new("message".to_string(), TriggerEvent::Insert);
        ctx.signer_id = Some("@alice:relay.example.com".to_string());
        ctx.room_id = Some("R-alpha".to_string());
        ctx.data.insert(
            "members".into(),
            members_json(&[
                ("@alice:relay.example.com", "Owner"),
                ("@bob:relay.example.com", "Member"),
            ]),
        );

        let result = (handler)(&mut ctx);
        assert!(result.is_ok(), "member should be allowed to write");
        assert!(!ctx.rejected, "context should not be rejected for a member");
    }

    /// TC-1-ROOM-005: check_room_write rejects a non-member with "NOT_A_MEMBER".
    #[test]
    fn tc_1_room_005_check_room_write_rejects_nonmember() {
        let (_decl, handler) = check_room_write_hook();

        let mut ctx = HookContext::new("message".to_string(), TriggerEvent::Insert);
        ctx.signer_id = Some("@mallory:evil.com".to_string());
        ctx.room_id = Some("R-alpha".to_string());
        ctx.data.insert(
            "members".into(),
            members_json(&[
                ("@alice:relay.example.com", "Owner"),
                ("@bob:relay.example.com", "Member"),
            ]),
        );

        let result = (handler)(&mut ctx);
        assert!(result.is_err(), "non-member should be rejected");
        assert!(ctx.rejected, "context should be rejected");
        assert_eq!(
            ctx.rejection_reason.as_deref(),
            Some("NOT_A_MEMBER"),
            "rejection reason must be NOT_A_MEMBER"
        );
    }

    /// TC-1-ROOM-006: check_config_permission allows Admin (power_level 50).
    #[test]
    fn tc_1_room_006_config_permission_allows_admin() {
        let (_decl, handler) = check_config_permission_hook();

        let mut ctx = HookContext::new("room_config".to_string(), TriggerEvent::Update);
        ctx.signer_id = Some("@bob:relay.example.com".to_string());
        ctx.data.insert(
            "members".into(),
            members_json(&[
                ("@alice:relay.example.com", "Owner"),
                ("@bob:relay.example.com", "Admin"),
            ]),
        );

        let result = (handler)(&mut ctx);
        assert!(result.is_ok(), "Admin should be allowed to modify config");
        assert!(!ctx.rejected, "context should not be rejected for Admin");
    }

    /// TC-1-ROOM-007: check_config_permission rejects Member (power_level 0).
    #[test]
    fn tc_1_room_007_config_permission_rejects_member() {
        let (_decl, handler) = check_config_permission_hook();

        let mut ctx = HookContext::new("room_config".to_string(), TriggerEvent::Update);
        ctx.signer_id = Some("@bob:relay.example.com".to_string());
        ctx.data.insert(
            "members".into(),
            members_json(&[
                ("@alice:relay.example.com", "Owner"),
                ("@bob:relay.example.com", "Member"),
            ]),
        );

        let result = (handler)(&mut ctx);
        assert!(
            result.is_err(),
            "Member should be rejected for config changes"
        );
        assert!(ctx.rejected, "context should be rejected");
        assert_eq!(
            ctx.rejection_reason.as_deref(),
            Some("INSUFFICIENT_POWER_LEVEL"),
            "rejection reason must be INSUFFICIENT_POWER_LEVEL"
        );
    }

    /// TC-1-ROOM-008: Verify room_datatype() declaration fields.
    #[test]
    fn tc_1_room_008_room_datatype_declaration() {
        let dt = room_datatype();

        assert_eq!(dt.id, "room");
        assert_eq!(dt.version, "0.1.0");
        assert_eq!(dt.dependencies, vec!["identity"]);
        assert!(dt.is_builtin, "room must be a built-in datatype");
        assert!(dt.indexes.is_empty(), "room declares no indexes");

        // Verify the single data entry.
        assert_eq!(dt.data_entries.len(), 1);
        let entry = &dt.data_entries[0];
        assert_eq!(entry.id, "room_config");
        assert_eq!(entry.storage_type, StorageType::CrdtMap);
        assert_eq!(
            entry.key_pattern.template(),
            "ezagent/{room_id}/config/{state|updates}"
        );
        assert!(entry.persistent);
        assert_eq!(
            entry.writer_rule,
            WriterRule::SignerPowerLevel { min_level: 50 }
        );
        assert_eq!(entry.sync_strategy, SyncMode::Eager);
    }

    /// TC-1-ROOM-009: Owner (power_level 100) can modify config.
    #[test]
    fn tc_1_room_009_owner_can_modify_config() {
        let (_decl, handler) = check_config_permission_hook();

        let mut ctx = HookContext::new("room_config".to_string(), TriggerEvent::Update);
        ctx.signer_id = Some("@alice:relay.example.com".to_string());
        ctx.data.insert(
            "members".into(),
            members_json(&[
                ("@alice:relay.example.com", "Owner"),
                ("@bob:relay.example.com", "Member"),
            ]),
        );

        let result = (handler)(&mut ctx);
        assert!(result.is_ok(), "Owner should be allowed to modify config");
        assert!(!ctx.rejected, "context should not be rejected for Owner");
    }

    // -----------------------------------------------------------------------
    // Additional hook declaration tests
    // -----------------------------------------------------------------------

    /// Verify check_room_write hook declaration fields.
    #[test]
    fn check_room_write_hook_declaration() {
        let (decl, _handler) = check_room_write_hook();
        assert_eq!(decl.id, "room.check_room_write");
        assert_eq!(decl.phase, HookPhase::PreSend);
        assert_eq!(decl.trigger_datatype, "*");
        assert_eq!(decl.trigger_event, TriggerEvent::Any);
        assert!(decl.trigger_filter.is_none());
        assert_eq!(decl.priority, 10);
        assert_eq!(decl.source, "room");
    }

    /// Verify check_config_permission hook declaration fields.
    #[test]
    fn check_config_permission_hook_declaration() {
        let (decl, _handler) = check_config_permission_hook();
        assert_eq!(decl.id, "room.check_config_permission");
        assert_eq!(decl.phase, HookPhase::PreSend);
        assert_eq!(decl.trigger_datatype, "room_config");
        assert_eq!(decl.trigger_event, TriggerEvent::Any);
        assert!(decl.trigger_filter.is_none());
        assert_eq!(decl.priority, 20);
        assert_eq!(decl.source, "room");
    }

    /// Verify extension_loader hook declaration fields.
    #[test]
    fn extension_loader_hook_declaration() {
        let (decl, _handler) = extension_loader_hook();
        assert_eq!(decl.id, "room.extension_loader");
        assert_eq!(decl.phase, HookPhase::AfterWrite);
        assert_eq!(decl.trigger_datatype, "room_config");
        assert_eq!(decl.trigger_event, TriggerEvent::Any);
        assert!(decl.trigger_filter.is_none());
        assert_eq!(decl.priority, 10);
        assert_eq!(decl.source, "room");
    }

    /// Verify member_change_notify hook declaration fields.
    #[test]
    fn member_change_notify_hook_declaration() {
        let (decl, _handler) = member_change_notify_hook();
        assert_eq!(decl.id, "room.member_change_notify");
        assert_eq!(decl.phase, HookPhase::AfterWrite);
        assert_eq!(decl.trigger_datatype, "room_config");
        assert_eq!(decl.trigger_event, TriggerEvent::Any);
        assert!(decl.trigger_filter.is_none());
        assert_eq!(decl.priority, 50);
        assert_eq!(decl.source, "room");
    }

    /// Extension loader detects additions and removals.
    #[test]
    fn extension_loader_detects_changes() {
        let (_decl, handler) = extension_loader_hook();

        let mut ctx = HookContext::new("room_config".to_string(), TriggerEvent::Update);
        ctx.room_id = Some("R-alpha".to_string());
        ctx.data.insert(
            "old_enabled_extensions".into(),
            serde_json::json!(["EXT-01", "EXT-03"]),
        );
        ctx.data.insert(
            "enabled_extensions".into(),
            serde_json::json!(["EXT-01", "EXT-04", "EXT-05"]),
        );

        let result = (handler)(&mut ctx);
        assert!(result.is_ok());

        // EXT-04, EXT-05 were added.
        let added = ctx
            .data
            .get("extensions_added")
            .expect("should have extensions_added");
        let added_arr: Vec<String> = serde_json::from_value(added.clone()).unwrap();
        assert!(added_arr.contains(&"EXT-04".to_string()));
        assert!(added_arr.contains(&"EXT-05".to_string()));
        assert_eq!(added_arr.len(), 2);

        // EXT-03 was removed.
        let removed = ctx
            .data
            .get("extensions_removed")
            .expect("should have extensions_removed");
        let removed_arr: Vec<String> = serde_json::from_value(removed.clone()).unwrap();
        assert_eq!(removed_arr, vec!["EXT-03"]);
    }

    /// Member change notify detects additions and removals.
    #[test]
    fn member_change_notify_detects_changes() {
        let (_decl, handler) = member_change_notify_hook();

        let mut ctx = HookContext::new("room_config".to_string(), TriggerEvent::Update);
        ctx.room_id = Some("R-alpha".to_string());
        ctx.data.insert(
            "old_members".into(),
            members_json(&[
                ("@alice:relay.example.com", "Owner"),
                ("@bob:relay.example.com", "Member"),
            ]),
        );
        ctx.data.insert(
            "members".into(),
            members_json(&[
                ("@alice:relay.example.com", "Owner"),
                ("@carol:relay.example.com", "Member"),
            ]),
        );

        let result = (handler)(&mut ctx);
        assert!(result.is_ok());

        // @carol was added.
        let added = ctx
            .data
            .get("members_added")
            .expect("should have members_added");
        let added_arr: Vec<String> = serde_json::from_value(added.clone()).unwrap();
        assert_eq!(added_arr, vec!["@carol:relay.example.com"]);

        // @bob was removed.
        let removed = ctx
            .data
            .get("members_removed")
            .expect("should have members_removed");
        let removed_arr: Vec<String> = serde_json::from_value(removed.clone()).unwrap();
        assert_eq!(removed_arr, vec!["@bob:relay.example.com"]);
    }

    /// check_room_write rejects when no members data is provided but room_id
    /// is set (fail-closed).
    #[test]
    fn check_room_write_rejects_without_members_fail_closed() {
        let (_decl, handler) = check_room_write_hook();

        let mut ctx = HookContext::new("message".to_string(), TriggerEvent::Insert);
        ctx.signer_id = Some("@anyone:relay.com".to_string());
        ctx.room_id = Some("R-alpha".to_string());
        // No "members" in ctx.data — room-scoped write must be denied.

        let result = (handler)(&mut ctx);
        assert!(
            result.is_err(),
            "should reject when no members data (fail-closed)"
        );
        assert!(ctx.rejected, "context should be rejected");
        assert_eq!(
            ctx.rejection_reason.as_deref(),
            Some("NOT_A_MEMBER"),
            "rejection reason must be NOT_A_MEMBER"
        );
    }

    /// check_room_write skips when no members data and no room_id (not room-scoped).
    #[test]
    fn check_room_write_skips_without_room_id() {
        let (_decl, handler) = check_room_write_hook();

        let mut ctx = HookContext::new("message".to_string(), TriggerEvent::Insert);
        ctx.signer_id = Some("@anyone:relay.com".to_string());
        // No "members" in ctx.data and no room_id — not room-scoped.

        let result = (handler)(&mut ctx);
        assert!(result.is_ok(), "should skip check when not room-scoped");
        assert!(!ctx.rejected);
    }

    /// check_room_write fails when no signer_id is set.
    #[test]
    fn check_room_write_no_signer_fails() {
        let (_decl, handler) = check_room_write_hook();

        let mut ctx = HookContext::new("message".to_string(), TriggerEvent::Insert);
        ctx.data.insert(
            "members".into(),
            members_json(&[("@alice:relay.example.com", "Owner")]),
        );
        // No signer_id.

        let result = (handler)(&mut ctx);
        assert!(result.is_err());
        let err_msg = result.unwrap_err().to_string();
        assert!(err_msg.contains("no signer_id"));
    }

    /// check_config_permission fails when no signer_id is set.
    #[test]
    fn check_config_permission_no_signer_fails() {
        let (_decl, handler) = check_config_permission_hook();

        let mut ctx = HookContext::new("room_config".to_string(), TriggerEvent::Update);
        // No signer_id.

        let result = (handler)(&mut ctx);
        assert!(result.is_err());
        let err_msg = result.unwrap_err().to_string();
        assert!(err_msg.contains("no signer_id"));
    }

    /// Role serde roundtrip.
    #[test]
    fn role_serde_roundtrip() {
        for role in &[Role::Owner, Role::Admin, Role::Member] {
            let json = serde_json::to_string(role).expect("serialize role");
            let roundtripped: Role = serde_json::from_str(&json).expect("deserialize role");
            assert_eq!(role, &roundtripped);
        }
    }

    /// Verify that unknown ext.* fields survive RoomConfig serialization round-trip.
    #[test]
    fn room_config_ext_fields_roundtrip() {
        let mut members = HashMap::new();
        members.insert("@alice:relay.example.com".to_string(), Role::Owner);

        let mut extra = HashMap::new();
        extra.insert(
            "ext.polls".to_string(),
            serde_json::json!({"active_polls": 3}),
        );
        extra.insert(
            "ext.custom".to_string(),
            serde_json::json!({"setting": "value"}),
        );

        let config = RoomConfig {
            room_id: "R-test".to_string(),
            name: "Test Room".to_string(),
            created_by: "@alice:relay.example.com".to_string(),
            created_at: "2026-03-01T00:00:00Z".to_string(),
            membership: MembershipConfig {
                policy: MembershipPolicy::Open,
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
            extra: extra.clone(),
        };

        let json = serde_json::to_string(&config).expect("serialize config with ext fields");
        let roundtripped: RoomConfig =
            serde_json::from_str(&json).expect("deserialize config with ext fields");

        assert_eq!(
            roundtripped.extra.get("ext.polls"),
            extra.get("ext.polls"),
            "ext.polls must survive roundtrip"
        );
        assert_eq!(
            roundtripped.extra.get("ext.custom"),
            extra.get("ext.custom"),
            "ext.custom must survive roundtrip"
        );
        assert_eq!(roundtripped.extra.len(), 2);

        // Verify the core fields are still intact.
        assert_eq!(roundtripped.room_id, "R-test");
        assert_eq!(roundtripped.name, "Test Room");
    }
}
