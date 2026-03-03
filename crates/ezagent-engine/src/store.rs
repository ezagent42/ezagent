//! In-memory state management for the Engine.
//!
//! Provides [`EngineStore`], a thread-safe, `HashMap`-backed store for rooms,
//! messages, timeline refs, and annotations. Designed as a lightweight
//! in-memory backend that can later be swapped for a persistent implementation.

use std::collections::HashMap;
use std::sync::{Arc, RwLock};

use crate::builtins::message::MessageContent;
use crate::builtins::room::RoomConfig;
use crate::builtins::timeline::TimelineRef;

/// Thread-safe in-memory store for rooms, messages, timeline refs, and annotations.
///
/// All collections are wrapped in `Arc<RwLock<...>>` so that the store can be
/// shared across threads. Lock poisoning on `RwLock` is treated as a
/// programming error (panic-worthy) rather than a recoverable runtime
/// condition, so `expect("lock poisoned")` is used throughout.
#[derive(Clone)]
pub struct EngineStore {
    /// Room configs keyed by `room_id`.
    rooms: Arc<RwLock<HashMap<String, RoomConfig>>>,
    /// Messages keyed by `room_id`, each room holding a `Vec` in insertion order.
    messages: Arc<RwLock<HashMap<String, Vec<MessageContent>>>>,
    /// Timeline refs keyed by `room_id`, each room holding a `Vec` in insertion order.
    timeline_refs: Arc<RwLock<HashMap<String, Vec<TimelineRef>>>>,
    /// Annotations keyed by `(room_id, ref_id)`, each entry holding key-value pairs.
    annotations: Arc<RwLock<HashMap<(String, String), Vec<(String, String)>>>>,
}

impl EngineStore {
    /// Create a new, empty `EngineStore`.
    pub fn new() -> Self {
        Self {
            rooms: Arc::new(RwLock::new(HashMap::new())),
            messages: Arc::new(RwLock::new(HashMap::new())),
            timeline_refs: Arc::new(RwLock::new(HashMap::new())),
            annotations: Arc::new(RwLock::new(HashMap::new())),
        }
    }

    // ── Room operations ──────────────────────────────────────────────

    /// Insert (or replace) a room configuration.
    ///
    /// The room is keyed by its `room_id` field. If a room with the same ID
    /// already exists it is overwritten.
    pub fn insert_room(&self, config: RoomConfig) {
        let mut rooms = self.rooms.write().expect("lock poisoned");
        rooms.insert(config.room_id.clone(), config);
    }

    /// Retrieve a room configuration by its ID.
    ///
    /// Returns `None` if no room with the given ID exists.
    pub fn get_room(&self, room_id: &str) -> Option<RoomConfig> {
        let rooms = self.rooms.read().expect("lock poisoned");
        rooms.get(room_id).cloned()
    }

    /// List all stored room configurations.
    ///
    /// The order is not guaranteed (HashMap iteration order).
    pub fn list_rooms(&self) -> Vec<RoomConfig> {
        let rooms = self.rooms.read().expect("lock poisoned");
        rooms.values().cloned().collect()
    }

    /// Update a room in-place by applying a closure.
    ///
    /// Returns `true` if the room was found and the closure was applied,
    /// `false` if no room with the given ID exists.
    pub fn update_room<F>(&self, room_id: &str, f: F) -> bool
    where
        F: FnOnce(&mut RoomConfig),
    {
        let mut rooms = self.rooms.write().expect("lock poisoned");
        if let Some(config) = rooms.get_mut(room_id) {
            f(config);
            true
        } else {
            false
        }
    }

    // ── Message operations ───────────────────────────────────────────

    /// Insert a message into a room's message list.
    ///
    /// Messages are appended in insertion order. The room does not need to
    /// exist in the rooms map; a message list is created on first insert.
    pub fn insert_message(&self, room_id: &str, content: MessageContent) {
        let mut messages = self.messages.write().expect("lock poisoned");
        messages
            .entry(room_id.to_owned())
            .or_default()
            .push(content);
    }

    /// List messages for a room with pagination support.
    ///
    /// Returns up to `limit` messages. If `before` is `Some(content_id)`,
    /// only messages that appear *before* the first message with that
    /// `content_id` are considered (exclusive upper bound). Messages are
    /// returned in insertion order (oldest first).
    ///
    /// Returns an empty `Vec` if the room has no messages.
    pub fn list_messages(
        &self,
        room_id: &str,
        limit: usize,
        before: Option<&str>,
    ) -> Vec<MessageContent> {
        let messages = self.messages.read().expect("lock poisoned");
        let Some(room_msgs) = messages.get(room_id) else {
            return Vec::new();
        };

        let end = match before {
            Some(before_id) => room_msgs
                .iter()
                .position(|m| m.content_id == before_id)
                .unwrap_or(room_msgs.len()),
            None => room_msgs.len(),
        };

        let start = end.saturating_sub(limit);
        room_msgs[start..end].to_vec()
    }

    // ── Timeline operations ──────────────────────────────────────────

    /// Insert a timeline ref into a room's timeline.
    ///
    /// Refs are appended in insertion order. The room does not need to exist
    /// in the rooms map; a timeline ref list is created on first insert.
    pub fn insert_timeline_ref(&self, room_id: &str, tref: TimelineRef) {
        let mut trefs = self.timeline_refs.write().expect("lock poisoned");
        trefs.entry(room_id.to_owned()).or_default().push(tref);
    }

    /// Retrieve a single timeline ref by room ID and ref ID.
    ///
    /// Returns `None` if the room has no timeline refs or no ref with the
    /// given ID exists.
    pub fn get_timeline_ref(&self, room_id: &str, ref_id: &str) -> Option<TimelineRef> {
        let trefs = self.timeline_refs.read().expect("lock poisoned");
        trefs
            .get(room_id)?
            .iter()
            .find(|r| r.ref_id == ref_id)
            .cloned()
    }

    /// List all timeline refs for a room.
    ///
    /// Returns refs in insertion order. Returns an empty `Vec` if the room
    /// has no timeline refs.
    pub fn list_timeline_refs(&self, room_id: &str) -> Vec<TimelineRef> {
        let trefs = self.timeline_refs.read().expect("lock poisoned");
        trefs.get(room_id).cloned().unwrap_or_default()
    }

    // ── Annotation operations ────────────────────────────────────────

    /// Add an annotation (key-value pair) to a timeline ref.
    ///
    /// If an annotation with the same key already exists for the given
    /// `(room_id, ref_id)` pair, it is replaced with the new value.
    pub fn add_annotation(&self, room_id: &str, ref_id: &str, key: &str, value: &str) {
        let mut annotations = self.annotations.write().expect("lock poisoned");
        let key_pair = (room_id.to_owned(), ref_id.to_owned());
        let entries = annotations.entry(key_pair).or_default();

        // Replace existing annotation with same key, or append new one.
        if let Some(entry) = entries.iter_mut().find(|(k, _)| k == key) {
            entry.1 = value.to_owned();
        } else {
            entries.push((key.to_owned(), value.to_owned()));
        }
    }

    /// List all annotations for a timeline ref.
    ///
    /// Returns a `Vec` of `(key, value)` pairs. Returns an empty `Vec` if
    /// no annotations exist for the given `(room_id, ref_id)`.
    pub fn list_annotations(&self, room_id: &str, ref_id: &str) -> Vec<(String, String)> {
        let annotations = self.annotations.read().expect("lock poisoned");
        annotations
            .get(&(room_id.to_owned(), ref_id.to_owned()))
            .cloned()
            .unwrap_or_default()
    }

    /// Remove an annotation by key from a timeline ref.
    ///
    /// Returns `true` if the annotation was found and removed, `false`
    /// otherwise.
    pub fn remove_annotation(&self, room_id: &str, ref_id: &str, key: &str) -> bool {
        let mut annotations = self.annotations.write().expect("lock poisoned");
        let key_pair = (room_id.to_owned(), ref_id.to_owned());
        if let Some(entries) = annotations.get_mut(&key_pair) {
            let before = entries.len();
            entries.retain(|(k, _)| k != key);
            entries.len() < before
        } else {
            false
        }
    }
}

impl Default for EngineStore {
    fn default() -> Self {
        Self::new()
    }
}

impl std::fmt::Debug for EngineStore {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("EngineStore")
            .field(
                "rooms_count",
                &self
                    .rooms
                    .read()
                    .map(|r| r.len())
                    .unwrap_or(0),
            )
            .field(
                "messages_rooms",
                &self
                    .messages
                    .read()
                    .map(|m| m.len())
                    .unwrap_or(0),
            )
            .field(
                "timeline_rooms",
                &self
                    .timeline_refs
                    .read()
                    .map(|t| t.len())
                    .unwrap_or(0),
            )
            .field(
                "annotation_entries",
                &self
                    .annotations
                    .read()
                    .map(|a| a.len())
                    .unwrap_or(0),
            )
            .finish()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::builtins::room::{
        MembershipConfig, MembershipPolicy, PowerLevelConfig, TimelineConfig,
    };
    use crate::builtins::timeline::RefStatus;

    /// Helper: create a minimal RoomConfig for testing.
    fn test_room(room_id: &str, name: &str) -> RoomConfig {
        RoomConfig {
            room_id: room_id.to_owned(),
            name: name.to_owned(),
            created_by: "@alice:relay.example.com".to_owned(),
            created_at: "2025-01-01T00:00:00Z".to_owned(),
            membership: MembershipConfig {
                policy: MembershipPolicy::Invite,
                members: HashMap::new(),
            },
            power_levels: PowerLevelConfig {
                default: 0,
                events_default: 0,
                admin: 50,
                users: HashMap::new(),
            },
            relays: vec!["relay.example.com".to_owned()],
            timeline: TimelineConfig {
                shard_max_refs: 10000,
            },
            enabled_extensions: Vec::new(),
            extra: HashMap::new(),
        }
    }

    /// Helper: create a minimal MessageContent for testing.
    fn test_message(content_id: &str, body: &str) -> MessageContent {
        MessageContent {
            content_id: content_id.to_owned(),
            content_type: "immutable".to_owned(),
            author: "@alice:relay.example.com".to_owned(),
            body: serde_json::json!(body),
            format: "text/plain".to_owned(),
            media_refs: Vec::new(),
            created_at: "2025-01-01T00:00:00Z".to_owned(),
            signature: None,
        }
    }

    /// Helper: create a minimal TimelineRef for testing.
    fn test_timeline_ref(ref_id: &str, content_id: &str) -> TimelineRef {
        TimelineRef {
            ref_id: ref_id.to_owned(),
            author: "@alice:relay.example.com".to_owned(),
            content_type: "immutable".to_owned(),
            content_id: content_id.to_owned(),
            created_at: "2025-01-01T00:00:00Z".to_owned(),
            status: RefStatus::Active,
            signature: None,
            ext: HashMap::new(),
        }
    }

    // ── Room tests ───────────────────────────────────────────────────

    #[test]
    fn insert_and_get_room() {
        let store = EngineStore::new();
        let room = test_room("R-alpha", "Alpha Room");

        store.insert_room(room.clone());

        let retrieved = store.get_room("R-alpha");
        assert!(retrieved.is_some(), "room should be retrievable after insert");
        assert_eq!(retrieved.unwrap().name, "Alpha Room");
    }

    #[test]
    fn get_nonexistent_room_returns_none() {
        let store = EngineStore::new();
        assert!(store.get_room("nonexistent").is_none());
    }

    #[test]
    fn list_rooms_returns_all() {
        let store = EngineStore::new();
        store.insert_room(test_room("R-alpha", "Alpha"));
        store.insert_room(test_room("R-beta", "Beta"));

        let rooms = store.list_rooms();
        assert_eq!(rooms.len(), 2);

        let ids: Vec<&str> = rooms.iter().map(|r| r.room_id.as_str()).collect();
        assert!(ids.contains(&"R-alpha"));
        assert!(ids.contains(&"R-beta"));
    }

    #[test]
    fn list_rooms_empty() {
        let store = EngineStore::new();
        assert!(store.list_rooms().is_empty());
    }

    #[test]
    fn update_room_in_place() {
        let store = EngineStore::new();
        store.insert_room(test_room("R-alpha", "Alpha"));

        let updated = store.update_room("R-alpha", |config| {
            config.name = "Updated Alpha".to_owned();
        });
        assert!(updated, "update_room should return true for existing room");

        let room = store.get_room("R-alpha").unwrap();
        assert_eq!(room.name, "Updated Alpha");
    }

    #[test]
    fn update_nonexistent_room_returns_false() {
        let store = EngineStore::new();
        let updated = store.update_room("nonexistent", |_| {});
        assert!(!updated, "update_room should return false for missing room");
    }

    #[test]
    fn insert_room_overwrites_existing() {
        let store = EngineStore::new();
        store.insert_room(test_room("R-alpha", "Original"));
        store.insert_room(test_room("R-alpha", "Replaced"));

        let room = store.get_room("R-alpha").unwrap();
        assert_eq!(room.name, "Replaced");
    }

    // ── Message tests ────────────────────────────────────────────────

    #[test]
    fn insert_and_list_messages() {
        let store = EngineStore::new();
        store.insert_message("R-alpha", test_message("msg-001", "Hello"));
        store.insert_message("R-alpha", test_message("msg-002", "World"));

        let msgs = store.list_messages("R-alpha", 10, None);
        assert_eq!(msgs.len(), 2);
        assert_eq!(msgs[0].content_id, "msg-001");
        assert_eq!(msgs[1].content_id, "msg-002");
    }

    #[test]
    fn list_messages_empty_room() {
        let store = EngineStore::new();
        assert!(store.list_messages("nonexistent", 10, None).is_empty());
    }

    #[test]
    fn list_messages_with_limit() {
        let store = EngineStore::new();
        for i in 0..5 {
            store.insert_message("R-alpha", test_message(&format!("msg-{i:03}"), "text"));
        }

        let msgs = store.list_messages("R-alpha", 3, None);
        assert_eq!(msgs.len(), 3);
        // Should return the last 3 messages (most recent).
        assert_eq!(msgs[0].content_id, "msg-002");
        assert_eq!(msgs[1].content_id, "msg-003");
        assert_eq!(msgs[2].content_id, "msg-004");
    }

    #[test]
    fn list_messages_with_before() {
        let store = EngineStore::new();
        for i in 0..5 {
            store.insert_message("R-alpha", test_message(&format!("msg-{i:03}"), "text"));
        }

        // Get up to 2 messages before msg-003.
        let msgs = store.list_messages("R-alpha", 2, Some("msg-003"));
        assert_eq!(msgs.len(), 2);
        assert_eq!(msgs[0].content_id, "msg-001");
        assert_eq!(msgs[1].content_id, "msg-002");
    }

    #[test]
    fn list_messages_before_nonexistent_returns_all() {
        let store = EngineStore::new();
        store.insert_message("R-alpha", test_message("msg-001", "Hello"));

        // When `before` ID doesn't exist, treat as end-of-list.
        let msgs = store.list_messages("R-alpha", 10, Some("nonexistent"));
        assert_eq!(msgs.len(), 1);
    }

    #[test]
    fn list_messages_limit_exceeds_count() {
        let store = EngineStore::new();
        store.insert_message("R-alpha", test_message("msg-001", "Hello"));

        let msgs = store.list_messages("R-alpha", 100, None);
        assert_eq!(msgs.len(), 1);
    }

    // ── Timeline ref tests ───────────────────────────────────────────

    #[test]
    fn insert_and_get_timeline_ref() {
        let store = EngineStore::new();
        let tref = test_timeline_ref("ref-001", "content-abc");

        store.insert_timeline_ref("R-alpha", tref);

        let retrieved = store.get_timeline_ref("R-alpha", "ref-001");
        assert!(retrieved.is_some());
        assert_eq!(retrieved.unwrap().content_id, "content-abc");
    }

    #[test]
    fn get_timeline_ref_nonexistent_room() {
        let store = EngineStore::new();
        assert!(store.get_timeline_ref("nonexistent", "ref-001").is_none());
    }

    #[test]
    fn get_timeline_ref_nonexistent_ref() {
        let store = EngineStore::new();
        store.insert_timeline_ref("R-alpha", test_timeline_ref("ref-001", "c1"));
        assert!(store.get_timeline_ref("R-alpha", "nonexistent").is_none());
    }

    #[test]
    fn list_timeline_refs() {
        let store = EngineStore::new();
        store.insert_timeline_ref("R-alpha", test_timeline_ref("ref-001", "c1"));
        store.insert_timeline_ref("R-alpha", test_timeline_ref("ref-002", "c2"));

        let refs = store.list_timeline_refs("R-alpha");
        assert_eq!(refs.len(), 2);
        assert_eq!(refs[0].ref_id, "ref-001");
        assert_eq!(refs[1].ref_id, "ref-002");
    }

    #[test]
    fn list_timeline_refs_empty_room() {
        let store = EngineStore::new();
        assert!(store.list_timeline_refs("nonexistent").is_empty());
    }

    #[test]
    fn timeline_refs_scoped_by_room() {
        let store = EngineStore::new();
        store.insert_timeline_ref("R-alpha", test_timeline_ref("ref-001", "c1"));
        store.insert_timeline_ref("R-beta", test_timeline_ref("ref-002", "c2"));

        assert_eq!(store.list_timeline_refs("R-alpha").len(), 1);
        assert_eq!(store.list_timeline_refs("R-beta").len(), 1);
        assert!(store.get_timeline_ref("R-alpha", "ref-002").is_none());
    }

    // ── Annotation tests ─────────────────────────────────────────────

    #[test]
    fn add_and_list_annotations() {
        let store = EngineStore::new();
        store.add_annotation("R-alpha", "ref-001", "reaction:thumbsup", "@alice");
        store.add_annotation("R-alpha", "ref-001", "reaction:heart", "@bob");

        let annotations = store.list_annotations("R-alpha", "ref-001");
        assert_eq!(annotations.len(), 2);
        assert!(annotations.contains(&("reaction:thumbsup".to_owned(), "@alice".to_owned())));
        assert!(annotations.contains(&("reaction:heart".to_owned(), "@bob".to_owned())));
    }

    #[test]
    fn list_annotations_empty() {
        let store = EngineStore::new();
        assert!(store.list_annotations("R-alpha", "ref-001").is_empty());
    }

    #[test]
    fn add_annotation_replaces_existing_key() {
        let store = EngineStore::new();
        store.add_annotation("R-alpha", "ref-001", "status", "draft");
        store.add_annotation("R-alpha", "ref-001", "status", "published");

        let annotations = store.list_annotations("R-alpha", "ref-001");
        assert_eq!(annotations.len(), 1);
        assert_eq!(annotations[0], ("status".to_owned(), "published".to_owned()));
    }

    #[test]
    fn remove_annotation() {
        let store = EngineStore::new();
        store.add_annotation("R-alpha", "ref-001", "key1", "val1");
        store.add_annotation("R-alpha", "ref-001", "key2", "val2");

        let removed = store.remove_annotation("R-alpha", "ref-001", "key1");
        assert!(removed, "should return true for existing annotation");

        let annotations = store.list_annotations("R-alpha", "ref-001");
        assert_eq!(annotations.len(), 1);
        assert_eq!(annotations[0].0, "key2");
    }

    #[test]
    fn remove_nonexistent_annotation() {
        let store = EngineStore::new();
        let removed = store.remove_annotation("R-alpha", "ref-001", "nope");
        assert!(!removed, "should return false for missing annotation");
    }

    #[test]
    fn annotations_scoped_by_room_and_ref() {
        let store = EngineStore::new();
        store.add_annotation("R-alpha", "ref-001", "key", "val-a");
        store.add_annotation("R-alpha", "ref-002", "key", "val-b");
        store.add_annotation("R-beta", "ref-001", "key", "val-c");

        assert_eq!(
            store.list_annotations("R-alpha", "ref-001"),
            vec![("key".to_owned(), "val-a".to_owned())]
        );
        assert_eq!(
            store.list_annotations("R-alpha", "ref-002"),
            vec![("key".to_owned(), "val-b".to_owned())]
        );
        assert_eq!(
            store.list_annotations("R-beta", "ref-001"),
            vec![("key".to_owned(), "val-c".to_owned())]
        );
    }

    // ── Default / Debug ──────────────────────────────────────────────

    #[test]
    fn default_creates_empty_store() {
        let store = EngineStore::default();
        assert!(store.list_rooms().is_empty());
        assert!(store.list_messages("any", 10, None).is_empty());
        assert!(store.list_timeline_refs("any").is_empty());
        assert!(store.list_annotations("any", "any").is_empty());
    }

    #[test]
    fn debug_format_shows_counts() {
        let store = EngineStore::new();
        store.insert_room(test_room("R-alpha", "Alpha"));
        store.insert_message("R-alpha", test_message("m1", "hi"));

        let debug = format!("{:?}", store);
        assert!(debug.contains("EngineStore"));
        assert!(debug.contains("rooms_count"));
    }

    // ── Clone / thread safety ────────────────────────────────────────

    #[test]
    fn clone_shares_state() {
        let store = EngineStore::new();
        let store2 = store.clone();

        store.insert_room(test_room("R-alpha", "Alpha"));

        // The clone should see the same data (Arc shared).
        assert!(store2.get_room("R-alpha").is_some());
    }
}
