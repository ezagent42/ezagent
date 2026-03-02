//! Hook phase types and context for the 3-phase Hook Pipeline (bus-spec SS3.2).
//!
//! The Hook Pipeline has three phases:
//! - **PreSend**: before CRDT write, may modify data or reject the write.
//! - **AfterWrite**: after CRDT apply, may trigger side-effects; errors logged, not propagated.
//! - **AfterRead**: after CRDT read, may enhance API response; errors silently ignored.

use serde::{Deserialize, Serialize};
use std::collections::HashMap;

/// The three lifecycle phases of the Hook Pipeline.
///
/// Each phase has distinct semantics for data access and error handling
/// (see bus-spec SS3.2.2).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum HookPhase {
    /// Before CRDT write. May modify data, may reject the write.
    PreSend,
    /// After CRDT apply. Read-only on trigger data, may write other datatypes.
    AfterWrite,
    /// After CRDT read. Fully read-only. Errors return raw data.
    AfterRead,
}

/// The event type that triggers a hook.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum TriggerEvent {
    /// Triggered on new data insertion.
    Insert,
    /// Triggered on data update.
    Update,
    /// Triggered on data deletion.
    Delete,
    /// Triggered on any event (insert, update, or delete).
    Any,
}

impl TriggerEvent {
    /// Returns `true` if this trigger matches the given concrete event.
    ///
    /// `Any` matches all events. A concrete event matches itself.
    pub fn matches(&self, other: &TriggerEvent) -> bool {
        matches!(self, TriggerEvent::Any) || matches!(other, TriggerEvent::Any) || self == other
    }
}

/// A hook declaration describing when and how a hook fires.
///
/// Each hook is identified by `id`, belongs to a `phase`, and is triggered
/// by events on a specific datatype (or `"*"` for global hooks).
/// Hooks are sorted by `priority` (ascending), then by dependency topology
/// of `source`, then alphabetically by `source` id.
#[derive(Debug, Clone)]
pub struct HookDeclaration {
    /// Globally unique hook identifier (e.g., "identity.sign_envelope").
    pub id: String,
    /// Which pipeline phase this hook runs in.
    pub phase: HookPhase,
    /// The datatype ID this hook triggers on. `"*"` means global (all datatypes).
    pub trigger_datatype: String,
    /// The event type that triggers this hook.
    pub trigger_event: TriggerEvent,
    /// Optional filter expression for additional trigger conditions.
    pub trigger_filter: Option<String>,
    /// Execution priority. 0 = highest priority (runs first). Ascending order.
    pub priority: u32,
    /// The datatype ID that registered this hook.
    pub source: String,
}

/// Mutable context passed to hook handlers during execution.
///
/// Contains the event details, associated data, and flags for rejection.
/// Hooks may modify `data` (in PreSend phase), set `rejected` to abort
/// writes, or add enhanced fields (in AfterRead phase).
#[derive(Debug, Clone)]
pub struct HookContext {
    /// The datatype ID of the data being processed.
    pub datatype_id: String,
    /// The event type that triggered the hook.
    pub event: TriggerEvent,
    /// Key-value data associated with the event. Hooks may read/modify this.
    pub data: HashMap<String, serde_json::Value>,
    /// The entity ID of the signer, if available.
    pub signer_id: Option<String>,
    /// The room ID, if the operation is scoped to a room.
    pub room_id: Option<String>,
    /// Whether the context is read-only (true for AfterWrite and AfterRead).
    pub read_only: bool,
    /// Whether a hook has rejected this operation.
    pub rejected: bool,
    /// The reason for rejection, if `rejected` is true.
    pub rejection_reason: Option<String>,
    /// Tracks which hooks have executed, in order. Used for testing/debugging.
    pub executed_hooks: Vec<String>,
}

impl HookContext {
    /// Create a new `HookContext` for the given datatype and event.
    ///
    /// The context starts with no signer, no room, read-write, and not rejected.
    pub fn new(datatype_id: String, event: TriggerEvent) -> Self {
        Self {
            datatype_id,
            event,
            data: HashMap::new(),
            signer_id: None,
            room_id: None,
            read_only: false,
            rejected: false,
            rejection_reason: None,
            executed_hooks: Vec::new(),
        }
    }

    /// Reject the current operation with the given reason.
    ///
    /// Sets `rejected` to `true` and stores the reason string.
    /// Only meaningful in PreSend phase; in other phases rejection is ignored.
    pub fn reject(&mut self, reason: impl Into<String>) {
        self.rejected = true;
        self.rejection_reason = Some(reason.into());
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn trigger_event_any_matches_all() {
        assert!(TriggerEvent::Any.matches(&TriggerEvent::Insert));
        assert!(TriggerEvent::Any.matches(&TriggerEvent::Update));
        assert!(TriggerEvent::Any.matches(&TriggerEvent::Delete));
        assert!(TriggerEvent::Any.matches(&TriggerEvent::Any));
    }

    #[test]
    fn trigger_event_concrete_matches_itself() {
        assert!(TriggerEvent::Insert.matches(&TriggerEvent::Insert));
        assert!(TriggerEvent::Update.matches(&TriggerEvent::Update));
        assert!(TriggerEvent::Delete.matches(&TriggerEvent::Delete));
    }

    #[test]
    fn trigger_event_concrete_does_not_match_other() {
        assert!(!TriggerEvent::Insert.matches(&TriggerEvent::Update));
        assert!(!TriggerEvent::Insert.matches(&TriggerEvent::Delete));
        assert!(!TriggerEvent::Update.matches(&TriggerEvent::Delete));
    }

    #[test]
    fn trigger_event_concrete_matches_any() {
        assert!(TriggerEvent::Insert.matches(&TriggerEvent::Any));
        assert!(TriggerEvent::Update.matches(&TriggerEvent::Any));
        assert!(TriggerEvent::Delete.matches(&TriggerEvent::Any));
    }

    #[test]
    fn hook_context_new_defaults() {
        let ctx = HookContext::new("message".to_string(), TriggerEvent::Insert);
        assert_eq!(ctx.datatype_id, "message");
        assert_eq!(ctx.event, TriggerEvent::Insert);
        assert!(ctx.data.is_empty());
        assert!(ctx.signer_id.is_none());
        assert!(ctx.room_id.is_none());
        assert!(!ctx.read_only);
        assert!(!ctx.rejected);
        assert!(ctx.rejection_reason.is_none());
        assert!(ctx.executed_hooks.is_empty());
    }

    #[test]
    fn hook_context_reject() {
        let mut ctx = HookContext::new("room".to_string(), TriggerEvent::Update);
        ctx.reject("NOT_A_MEMBER");
        assert!(ctx.rejected);
        assert_eq!(ctx.rejection_reason.as_deref(), Some("NOT_A_MEMBER"));
    }

    #[test]
    fn hook_phase_serde_roundtrip() {
        let phase = HookPhase::PreSend;
        let json = serde_json::to_string(&phase).unwrap();
        let phase2: HookPhase = serde_json::from_str(&json).unwrap();
        assert_eq!(phase, phase2);
    }

    #[test]
    fn trigger_event_serde_roundtrip() {
        let event = TriggerEvent::Delete;
        let json = serde_json::to_string(&event).unwrap();
        let event2: TriggerEvent = serde_json::from_str(&json).unwrap();
        assert_eq!(event, event2);
    }
}
