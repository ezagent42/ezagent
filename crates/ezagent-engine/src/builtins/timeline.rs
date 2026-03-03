//! Timeline built-in datatype — ULID ref generation, shard management,
//! cursor-based pagination, and 3 hooks.
//!
//! The Timeline datatype manages the ordered sequence of references (refs)
//! within a room. Each ref points to a content object (immutable, mutable,
//! or collaborative) and is identified by a ULID (time-sortable unique ID).
//!
//! Sharding: refs are grouped into shards (UUIDv7-identified). When a shard
//! reaches `shard_max_refs`, a new shard is created.
//!
//! Hooks:
//! - `timeline.generate_ref` (pre_send, timeline_index insert, p=20): generates ULID ref_id
//! - `timeline.ref_change_detect` (after_write, timeline_index, p=30): detects ref changes
//! - `timeline.timeline_pagination` (after_read, timeline_index, p=30): cursor-based pagination

use std::sync::Arc;

use serde::{Deserialize, Serialize};

use ezagent_protocol::KeyPattern;

use crate::error::EngineError;
use crate::hooks::executor::HookFn;
use crate::hooks::phase::{HookContext, HookDeclaration, HookPhase, TriggerEvent};
use crate::registry::datatype::*;

// ---------------------------------------------------------------------------
// Ref Schema
// ---------------------------------------------------------------------------

/// Status of a timeline reference.
///
/// A ref starts as `Active` and may be soft-deleted by the original author,
/// changing its status to `DeletedByAuthor`. The ref remains in the CRDT
/// array; it is never physically removed.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum RefStatus {
    /// The ref is live and visible.
    Active,
    /// The ref has been soft-deleted by its original author.
    DeletedByAuthor,
}

/// A single reference in the timeline.
///
/// Each ref points to a content object and carries metadata about the
/// author, content type, creation time, and current status.
///
/// The `ext` field captures any `ext.*` namespaced fields from extensions,
/// preserving them across serialization round-trips.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TimelineRef {
    /// ULID identifier for this ref (time-sortable).
    pub ref_id: String,
    /// Entity ID of the ref author.
    pub author: String,
    /// Content type: "immutable", "mutable", or "collaborative".
    pub content_type: String,
    /// Content identifier (hash for immutable, UUID for mutable/collaborative).
    pub content_id: String,
    /// ISO 8601 creation timestamp.
    pub created_at: String,
    /// Current status of this ref.
    pub status: RefStatus,
    /// Optional cryptographic signature.
    pub signature: Option<String>,
    /// Extension-owned extra fields (`ext.*` namespace). Preserved across
    /// serialization round-trips so that unknown extension data is not lost.
    #[serde(flatten)]
    pub ext: std::collections::HashMap<String, serde_json::Value>,
}

// ---------------------------------------------------------------------------
// Sharding
// ---------------------------------------------------------------------------

/// A timeline shard containing an ordered list of refs.
///
/// Each shard is identified by a UUIDv7, which is itself time-sortable.
/// Refs within a shard maintain insertion order.
#[derive(Debug, Clone)]
pub struct TimelineShard {
    /// UUIDv7 identifier for this shard.
    pub shard_id: String,
    /// Ordered list of refs in this shard.
    pub refs: Vec<TimelineRef>,
}

/// Manages timeline shards, creating new ones when the active shard is full.
///
/// The `ShardManager` maintains an ordered list of shards. New refs are
/// appended to the active (last) shard. When the active shard reaches
/// `shard_max_refs`, a new shard is automatically created.
pub struct ShardManager {
    /// Ordered list of shards (newest last).
    pub shards: Vec<TimelineShard>,
    /// Maximum number of refs per shard before a new shard is created.
    pub shard_max_refs: u64,
}

impl ShardManager {
    /// Create a new `ShardManager` with the given max refs per shard.
    ///
    /// Starts with a single empty shard.
    pub fn new(shard_max_refs: u64) -> Self {
        let initial_shard = TimelineShard {
            shard_id: uuid::Uuid::now_v7().to_string(),
            refs: Vec::new(),
        };
        Self {
            shards: vec![initial_shard],
            shard_max_refs,
        }
    }

    /// Return a reference to the active (last) shard, if any.
    pub fn active_shard(&self) -> Option<&TimelineShard> {
        self.shards.last()
    }

    /// Return a mutable reference to the active (last) shard, if any.
    pub fn active_shard_mut(&mut self) -> Option<&mut TimelineShard> {
        self.shards.last_mut()
    }

    /// Add a ref to the timeline.
    ///
    /// If the active shard is full (>= `shard_max_refs`), a new shard is
    /// created first. Returns the shard_id where the ref was placed.
    pub fn add_ref(&mut self, timeline_ref: TimelineRef) -> String {
        // Check if active shard is full and we need a new one.
        let needs_new_shard = self
            .shards
            .last()
            .map(|s| s.refs.len() as u64 >= self.shard_max_refs)
            .unwrap_or(true);

        if needs_new_shard {
            let new_shard = TimelineShard {
                shard_id: uuid::Uuid::now_v7().to_string(),
                refs: Vec::new(),
            };
            self.shards.push(new_shard);
        }

        let shard = self.shards.last_mut().expect("at least one shard exists");
        shard.refs.push(timeline_ref);
        shard.shard_id.clone()
    }

    /// Return the total number of refs across all shards.
    pub fn total_refs(&self) -> usize {
        self.shards.iter().map(|s| s.refs.len()).sum()
    }

    /// Find a ref by its ref_id across all shards.
    pub fn find_ref(&self, ref_id: &str) -> Option<&TimelineRef> {
        for shard in &self.shards {
            for r in &shard.refs {
                if r.ref_id == ref_id {
                    return Some(r);
                }
            }
        }
        None
    }

    /// Find a mutable ref by its ref_id across all shards.
    pub fn find_ref_mut(&mut self, ref_id: &str) -> Option<&mut TimelineRef> {
        for shard in &mut self.shards {
            for r in &mut shard.refs {
                if r.ref_id == ref_id {
                    return Some(r);
                }
            }
        }
        None
    }
}

// ---------------------------------------------------------------------------
// Pagination
// ---------------------------------------------------------------------------

/// Cursor for paginating through timeline refs across shards.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PaginationCursor {
    /// The shard_id to resume from.
    pub shard_id: String,
    /// The offset within that shard (index of the next ref to return).
    pub offset: usize,
}

/// Result of a pagination query.
#[derive(Debug, Clone)]
pub struct PaginationResult {
    /// The refs in this page.
    pub refs: Vec<TimelineRef>,
    /// Cursor for the next page, if there are more results.
    pub next_cursor: Option<PaginationCursor>,
    /// Whether there are more results beyond this page.
    pub has_more: bool,
}

/// Paginate timeline refs across shards.
///
/// Returns up to `limit` refs starting from the given cursor position
/// (or from the beginning if no cursor is provided). The returned
/// `PaginationResult` includes a `next_cursor` if there are more refs
/// to fetch.
pub fn paginate(
    shards: &[TimelineShard],
    cursor: Option<&PaginationCursor>,
    limit: usize,
) -> PaginationResult {
    if shards.is_empty() || limit == 0 {
        return PaginationResult {
            refs: Vec::new(),
            next_cursor: None,
            has_more: false,
        };
    }

    // Determine starting position.
    let (start_shard_idx, start_offset) = match cursor {
        Some(c) => {
            // Find the shard matching the cursor's shard_id.
            let idx = shards
                .iter()
                .position(|s| s.shard_id == c.shard_id)
                .unwrap_or(0);
            (idx, c.offset)
        }
        None => (0, 0),
    };

    let mut result_refs = Vec::with_capacity(limit);
    let mut current_shard_idx = start_shard_idx;
    let mut current_offset = start_offset;

    while result_refs.len() < limit && current_shard_idx < shards.len() {
        let shard = &shards[current_shard_idx];

        if current_offset < shard.refs.len() {
            let remaining_capacity = limit - result_refs.len();
            let available = shard.refs.len() - current_offset;
            let take = remaining_capacity.min(available);

            result_refs.extend_from_slice(&shard.refs[current_offset..current_offset + take]);
            current_offset += take;
        }

        // If we've consumed this shard, move to the next one.
        if current_offset >= shard.refs.len() {
            current_shard_idx += 1;
            current_offset = 0;
        }

        // If we've filled the page, stop.
        if result_refs.len() >= limit {
            break;
        }
    }

    // Determine if there are more refs after the current position.
    let has_more = if current_shard_idx < shards.len() {
        // We stopped mid-shard or there are more shards.
        current_offset < shards[current_shard_idx].refs.len()
            || current_shard_idx + 1 < shards.len()
    } else {
        false
    };

    let next_cursor = if has_more {
        Some(PaginationCursor {
            shard_id: shards[current_shard_idx].shard_id.clone(),
            offset: current_offset,
        })
    } else {
        None
    };

    PaginationResult {
        refs: result_refs,
        next_cursor,
        has_more,
    }
}

// ---------------------------------------------------------------------------
// Datatype Declaration
// ---------------------------------------------------------------------------

/// Return the Timeline datatype declaration.
///
/// The Timeline datatype has a single data entry `timeline_index` stored as
/// a CrdtArray at `ezagent/{room_id}/index/{shard_id}/{state|updates}`.
/// It depends on the Identity and Room datatypes.
pub fn timeline_datatype() -> DatatypeDeclaration {
    DatatypeDeclaration {
        id: "timeline".to_string(),
        version: "0.1.0".to_string(),
        dependencies: vec!["identity".to_string(), "room".to_string()],
        data_entries: vec![DataEntry {
            id: "timeline_index".to_string(),
            storage_type: StorageType::CrdtArray,
            key_pattern: KeyPattern::new("ezagent/{room_id}/index/{shard_id}/{state|updates}"),
            persistent: true,
            writer_rule: WriterRule::SignerInMembers,
            sync_strategy: SyncMode::Eager,
        }],
        indexes: vec![],
        hooks: vec![],
        is_builtin: true,
    }
}

// ---------------------------------------------------------------------------
// Hook 1: timeline.generate_ref (pre_send, timeline_index insert, p=20)
// ---------------------------------------------------------------------------

/// Create the `timeline.generate_ref` hook.
///
/// This hook runs in the `PreSend` phase on `timeline_index` insert events
/// (priority 20). It generates a ULID ref_id, sets `status` to `Active`,
/// and sets `created_at` to the current ISO 8601 timestamp.
///
/// Reads from `ctx.data`:
/// - `author`: entity_id of the ref author
/// - `content_type`: "immutable", "mutable", or "collaborative"
/// - `content_id`: hash or UUID of the content
///
/// Writes to `ctx.data`:
/// - `ref_id`: the generated ULID string
/// - `status`: "Active"
/// - `created_at`: ISO 8601 timestamp
/// - `timeline_ref`: the complete serialized TimelineRef
pub fn generate_ref_hook() -> (HookDeclaration, HookFn) {
    let decl = HookDeclaration {
        id: "timeline.generate_ref".to_string(),
        phase: HookPhase::PreSend,
        trigger_datatype: "timeline_index".to_string(),
        trigger_event: TriggerEvent::Insert,
        trigger_filter: None,
        priority: 20,
        source: "timeline".to_string(),
    };

    let handler: HookFn = Arc::new(|ctx: &mut HookContext| {
        // Generate a ULID for the ref_id.
        let ref_id = ulid::Ulid::new().to_string();

        // Read author from context.
        let author = ctx
            .data
            .get("author")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();

        // Read content_type from context.
        let content_type = ctx
            .data
            .get("content_type")
            .and_then(|v| v.as_str())
            .unwrap_or("immutable")
            .to_string();

        // Read content_id from context.
        let content_id = ctx
            .data
            .get("content_id")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();

        // Generate ISO 8601 timestamp.
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default();
        let secs = now.as_secs();
        // Simple ISO 8601 formatting without external crate.
        // We compute a UTC timestamp in the format "YYYY-MM-DDTHH:MM:SSZ".
        let created_at = format_iso8601(secs);

        let timeline_ref = TimelineRef {
            ref_id: ref_id.clone(),
            author,
            content_type,
            content_id,
            created_at: created_at.clone(),
            status: RefStatus::Active,
            signature: None,
            ext: std::collections::HashMap::new(),
        };

        // Store results in context.
        ctx.data.insert("ref_id".into(), serde_json::json!(ref_id));
        ctx.data
            .insert("status".into(), serde_json::json!("Active"));
        ctx.data
            .insert("created_at".into(), serde_json::json!(created_at));

        let ref_json = serde_json::to_value(&timeline_ref).map_err(|e| {
            EngineError::Protocol(ezagent_protocol::ProtocolError::Serialization(
                e.to_string(),
            ))
        })?;
        ctx.data.insert("timeline_ref".into(), ref_json);

        Ok(())
    });

    (decl, handler)
}

/// Format a Unix timestamp (seconds) as an ISO 8601 string "YYYY-MM-DDTHH:MM:SSZ".
fn format_iso8601(epoch_secs: u64) -> String {
    // Calculate date/time components from epoch seconds.
    let secs_per_minute: u64 = 60;
    let secs_per_hour: u64 = 3600;
    let secs_per_day: u64 = 86400;

    let mut remaining = epoch_secs;

    let total_days = remaining / secs_per_day;
    remaining %= secs_per_day;

    let hours = remaining / secs_per_hour;
    remaining %= secs_per_hour;

    let minutes = remaining / secs_per_minute;
    let seconds = remaining % secs_per_minute;

    // Calculate year, month, day from total days since 1970-01-01.
    let (year, month, day) = days_to_date(total_days);

    format!(
        "{:04}-{:02}-{:02}T{:02}:{:02}:{:02}Z",
        year, month, day, hours, minutes, seconds
    )
}

/// Convert total days since Unix epoch (1970-01-01) to (year, month, day).
fn days_to_date(mut total_days: u64) -> (u64, u64, u64) {
    let mut year = 1970u64;

    loop {
        let days_in_year = if is_leap_year(year) { 366 } else { 365 };
        if total_days < days_in_year {
            break;
        }
        total_days -= days_in_year;
        year += 1;
    }

    let leap = is_leap_year(year);
    let days_in_months: [u64; 12] = [
        31,
        if leap { 29 } else { 28 },
        31,
        30,
        31,
        30,
        31,
        31,
        30,
        31,
        30,
        31,
    ];

    let mut month = 1u64;
    for &dim in &days_in_months {
        if total_days < dim {
            break;
        }
        total_days -= dim;
        month += 1;
    }

    let day = total_days + 1; // Days are 1-indexed.
    (year, month, day)
}

/// Returns true if the given year is a leap year.
fn is_leap_year(year: u64) -> bool {
    (year.is_multiple_of(4) && !year.is_multiple_of(100)) || year.is_multiple_of(400)
}

// ---------------------------------------------------------------------------
// Hook 2: timeline.ref_change_detect (after_write, timeline_index, p=30)
// ---------------------------------------------------------------------------

/// Create the `timeline.ref_change_detect` hook.
///
/// This hook runs in the `AfterWrite` phase on `timeline_index` events
/// (priority 30). It detects ref additions and deletions by examining
/// `ctx.data["timeline_ref"]` (for new refs) and `ctx.data["deleted_ref_id"]`
/// (for soft-deleted refs), and stores the detected changes in `ctx.data`.
///
/// Writes to `ctx.data`:
/// - `new_refs`: array of newly added ref_ids
/// - `deleted_refs`: array of soft-deleted ref_ids
pub fn ref_change_detect_hook() -> (HookDeclaration, HookFn) {
    let decl = HookDeclaration {
        id: "timeline.ref_change_detect".to_string(),
        phase: HookPhase::AfterWrite,
        trigger_datatype: "timeline_index".to_string(),
        trigger_event: TriggerEvent::Any,
        trigger_filter: None,
        priority: 30,
        source: "timeline".to_string(),
    };

    let handler: HookFn = Arc::new(|ctx: &mut HookContext| {
        let mut new_refs: Vec<String> = Vec::new();
        let mut deleted_refs: Vec<String> = Vec::new();

        // Detect new ref from the timeline_ref field.
        if let Some(ref_val) = ctx.data.get("timeline_ref").cloned() {
            if let Ok(tref) = serde_json::from_value::<TimelineRef>(ref_val) {
                if tref.status == RefStatus::Active {
                    new_refs.push(tref.ref_id);
                }
            }
        }

        // Detect soft-deleted refs.
        if let Some(deleted_val) = ctx.data.get("deleted_ref_id").cloned() {
            if let Some(ref_id) = deleted_val.as_str() {
                deleted_refs.push(ref_id.to_string());
            }
        }

        // Store the detected changes in context.
        ctx.data
            .insert("new_refs".into(), serde_json::json!(new_refs));
        ctx.data
            .insert("deleted_refs".into(), serde_json::json!(deleted_refs));

        Ok(())
    });

    (decl, handler)
}

// ---------------------------------------------------------------------------
// Hook 3: timeline.timeline_pagination (after_read, timeline_index, p=30)
// ---------------------------------------------------------------------------

/// Create the `timeline.timeline_pagination` hook.
///
/// This hook runs in the `AfterRead` phase on `timeline_index` events
/// (priority 30). It applies cursor-based pagination to the refs stored
/// in `ctx.data["shards"]`.
///
/// Reads from `ctx.data`:
/// - `shards`: JSON array of shard objects with `shard_id` and `refs`
/// - `cursor`: optional pagination cursor (`{ shard_id, offset }`)
/// - `limit`: page size (defaults to 50)
///
/// Writes to `ctx.data`:
/// - `paginated_refs`: the refs for the current page
/// - `next_cursor`: cursor for the next page (if any)
/// - `has_more`: whether more results exist
pub fn timeline_pagination_hook() -> (HookDeclaration, HookFn) {
    let decl = HookDeclaration {
        id: "timeline.timeline_pagination".to_string(),
        phase: HookPhase::AfterRead,
        trigger_datatype: "timeline_index".to_string(),
        trigger_event: TriggerEvent::Any,
        trigger_filter: None,
        priority: 30,
        source: "timeline".to_string(),
    };

    let handler: HookFn = Arc::new(|ctx: &mut HookContext| {
        // Parse shards from context data.
        let shards: Vec<TimelineShard> = if let Some(shards_val) = ctx.data.get("shards").cloned() {
            parse_shards_from_json(&shards_val)
        } else {
            Vec::new()
        };

        // Parse cursor from context data.
        let cursor: Option<PaginationCursor> = ctx
            .data
            .get("cursor")
            .cloned()
            .and_then(|v| serde_json::from_value(v).ok());

        // Parse limit from context data.
        let limit = ctx.data.get("limit").and_then(|v| v.as_u64()).unwrap_or(50) as usize;

        // Run pagination.
        let result = paginate(&shards, cursor.as_ref(), limit);

        // Store results in context.
        let refs_json: Vec<serde_json::Value> = result
            .refs
            .iter()
            .filter_map(|r| serde_json::to_value(r).ok())
            .collect();

        ctx.data
            .insert("paginated_refs".into(), serde_json::json!(refs_json));

        if let Some(next) = &result.next_cursor {
            if let Ok(cursor_json) = serde_json::to_value(next) {
                ctx.data.insert("next_cursor".into(), cursor_json);
            }
        } else {
            ctx.data
                .insert("next_cursor".into(), serde_json::Value::Null);
        }

        ctx.data
            .insert("has_more".into(), serde_json::json!(result.has_more));

        Ok(())
    });

    (decl, handler)
}

/// Parse a JSON value into a list of `TimelineShard`s.
///
/// Expects a JSON array of objects, each with `shard_id` (string) and
/// `refs` (array of TimelineRef objects).
fn parse_shards_from_json(val: &serde_json::Value) -> Vec<TimelineShard> {
    let Some(arr) = val.as_array() else {
        return Vec::new();
    };

    arr.iter()
        .filter_map(|shard_val| {
            let shard_id = shard_val.get("shard_id")?.as_str()?.to_string();
            let refs_val = shard_val.get("refs")?;
            let refs: Vec<TimelineRef> = if let Some(refs_arr) = refs_val.as_array() {
                refs_arr
                    .iter()
                    .filter_map(|r| serde_json::from_value(r.clone()).ok())
                    .collect()
            } else {
                Vec::new()
            };
            Some(TimelineShard { shard_id, refs })
        })
        .collect()
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    /// Helper to create a TimelineRef with the given ref_id and author.
    fn make_ref(ref_id: &str, author: &str) -> TimelineRef {
        TimelineRef {
            ref_id: ref_id.to_string(),
            author: author.to_string(),
            content_type: "immutable".to_string(),
            content_id: "abc123".to_string(),
            created_at: "2026-03-01T00:00:00Z".to_string(),
            status: RefStatus::Active,
            signature: None,
            ext: std::collections::HashMap::new(),
        }
    }

    /// Helper to create a TimelineRef with a real ULID.
    fn make_ulid_ref(author: &str) -> TimelineRef {
        TimelineRef {
            ref_id: ulid::Ulid::new().to_string(),
            author: author.to_string(),
            content_type: "immutable".to_string(),
            content_id: "content-hash-123".to_string(),
            created_at: "2026-03-01T00:00:00Z".to_string(),
            status: RefStatus::Active,
            signature: None,
            ext: std::collections::HashMap::new(),
        }
    }

    /// TC-1-TL-001: Create TimelineRef, verify ULID format.
    #[test]
    fn tc_1_tl_001_ref_creation() {
        let tref = make_ulid_ref("@alice:relay.example.com");

        // ULID is 26 characters, uppercase alphanumeric (Crockford Base32).
        assert_eq!(
            tref.ref_id.len(),
            26,
            "ULID string should be 26 characters, got {}",
            tref.ref_id.len()
        );

        // Verify it parses back as a valid ULID.
        let parsed = ulid::Ulid::from_string(&tref.ref_id);
        assert!(
            parsed.is_ok(),
            "ref_id should be a valid ULID: {}",
            tref.ref_id
        );

        // Verify other fields.
        assert_eq!(tref.author, "@alice:relay.example.com");
        assert_eq!(tref.content_type, "immutable");
        assert_eq!(tref.status, RefStatus::Active);
        assert!(tref.signature.is_none());

        // Verify two ULIDs are different.
        let tref2 = make_ulid_ref("@alice:relay.example.com");
        assert_ne!(tref.ref_id, tref2.ref_id, "two ULIDs should be different");

        // Verify both are valid ULIDs with timestamps.
        let ulid1 = ulid::Ulid::from_string(&tref.ref_id).unwrap();
        let ulid2 = ulid::Ulid::from_string(&tref2.ref_id).unwrap();
        // Both should have non-zero timestamps (generated "now").
        assert!(ulid1.timestamp_ms() > 0, "ULID should have a timestamp");
        assert!(ulid2.timestamp_ms() > 0, "ULID should have a timestamp");
    }

    /// TC-1-TL-002: ShardManager creates shards when full.
    #[test]
    fn tc_1_tl_002_shard_creation() {
        let mut sm = ShardManager::new(3); // 3 refs per shard max.

        // Initially: 1 shard, 0 refs.
        assert_eq!(sm.shards.len(), 1);
        assert_eq!(sm.total_refs(), 0);

        // Add 3 refs — should all go in the first shard.
        let shard_id_1 = sm.add_ref(make_ref("ref-1", "@alice:relay.com"));
        let shard_id_2 = sm.add_ref(make_ref("ref-2", "@bob:relay.com"));
        let shard_id_3 = sm.add_ref(make_ref("ref-3", "@alice:relay.com"));

        assert_eq!(sm.shards.len(), 1, "still 1 shard after 3 refs");
        assert_eq!(sm.total_refs(), 3);
        assert_eq!(shard_id_1, shard_id_2);
        assert_eq!(shard_id_2, shard_id_3);

        // Add a 4th ref — should trigger a new shard.
        let shard_id_4 = sm.add_ref(make_ref("ref-4", "@bob:relay.com"));

        assert_eq!(sm.shards.len(), 2, "should have 2 shards after 4 refs");
        assert_eq!(sm.total_refs(), 4);
        assert_ne!(shard_id_3, shard_id_4, "4th ref should be in a new shard");

        // Verify first shard has 3 refs, second has 1.
        assert_eq!(sm.shards[0].refs.len(), 3);
        assert_eq!(sm.shards[1].refs.len(), 1);
    }

    /// TC-1-TL-003: Refs within a shard maintain insertion order.
    #[test]
    fn tc_1_tl_003_ref_ordering() {
        let mut sm = ShardManager::new(100);

        sm.add_ref(make_ref("first", "@alice:relay.com"));
        sm.add_ref(make_ref("second", "@bob:relay.com"));
        sm.add_ref(make_ref("third", "@carol:relay.com"));

        let shard = sm.active_shard().expect("should have an active shard");
        assert_eq!(shard.refs.len(), 3);
        assert_eq!(shard.refs[0].ref_id, "first");
        assert_eq!(shard.refs[1].ref_id, "second");
        assert_eq!(shard.refs[2].ref_id, "third");

        // Verify authors match the insertion order.
        assert_eq!(shard.refs[0].author, "@alice:relay.com");
        assert_eq!(shard.refs[1].author, "@bob:relay.com");
        assert_eq!(shard.refs[2].author, "@carol:relay.com");
    }

    /// TC-1-TL-004: Soft delete sets status=DeletedByAuthor, ref stays.
    #[test]
    fn tc_1_tl_004_soft_delete() {
        let mut sm = ShardManager::new(100);

        sm.add_ref(make_ref("ref-to-delete", "@alice:relay.com"));
        sm.add_ref(make_ref("ref-to-keep", "@bob:relay.com"));

        assert_eq!(sm.total_refs(), 2);

        // Find the ref and soft-delete it.
        let tref = sm.find_ref_mut("ref-to-delete").expect("ref should exist");
        assert_eq!(tref.status, RefStatus::Active);

        // Only the original author can delete — simulate author check.
        assert_eq!(tref.author, "@alice:relay.com");
        tref.status = RefStatus::DeletedByAuthor;

        // Verify the ref is still present but marked as deleted.
        let deleted = sm
            .find_ref("ref-to-delete")
            .expect("ref should still exist");
        assert_eq!(deleted.status, RefStatus::DeletedByAuthor);

        // Total refs unchanged — soft delete doesn't remove.
        assert_eq!(sm.total_refs(), 2);

        // The other ref is unaffected.
        let kept = sm.find_ref("ref-to-keep").expect("kept ref should exist");
        assert_eq!(kept.status, RefStatus::Active);
    }

    /// TC-1-TL-005: Cursor-based pagination across multiple shards.
    #[test]
    fn tc_1_tl_005_cursor_pagination() {
        // Create 3 shards with 2 refs each.
        let shards = vec![
            TimelineShard {
                shard_id: "shard-1".to_string(),
                refs: vec![
                    make_ref("ref-1", "@alice:relay.com"),
                    make_ref("ref-2", "@bob:relay.com"),
                ],
            },
            TimelineShard {
                shard_id: "shard-2".to_string(),
                refs: vec![
                    make_ref("ref-3", "@carol:relay.com"),
                    make_ref("ref-4", "@alice:relay.com"),
                ],
            },
            TimelineShard {
                shard_id: "shard-3".to_string(),
                refs: vec![
                    make_ref("ref-5", "@bob:relay.com"),
                    make_ref("ref-6", "@carol:relay.com"),
                ],
            },
        ];

        // Page 1: limit=2, no cursor.
        let page1 = paginate(&shards, None, 2);
        assert_eq!(page1.refs.len(), 2);
        assert_eq!(page1.refs[0].ref_id, "ref-1");
        assert_eq!(page1.refs[1].ref_id, "ref-2");
        assert!(page1.has_more, "should have more refs");
        assert!(page1.next_cursor.is_some(), "should have a next cursor");

        // Page 2: continue from cursor.
        let page2 = paginate(&shards, page1.next_cursor.as_ref(), 2);
        assert_eq!(page2.refs.len(), 2);
        assert_eq!(page2.refs[0].ref_id, "ref-3");
        assert_eq!(page2.refs[1].ref_id, "ref-4");
        assert!(page2.has_more);
        assert!(page2.next_cursor.is_some());

        // Page 3: last page.
        let page3 = paginate(&shards, page2.next_cursor.as_ref(), 2);
        assert_eq!(page3.refs.len(), 2);
        assert_eq!(page3.refs[0].ref_id, "ref-5");
        assert_eq!(page3.refs[1].ref_id, "ref-6");
        assert!(!page3.has_more, "no more refs");
        assert!(page3.next_cursor.is_none(), "no next cursor on last page");

        // Edge: paginate with limit larger than total.
        let all = paginate(&shards, None, 100);
        assert_eq!(all.refs.len(), 6);
        assert!(!all.has_more);
        assert!(all.next_cursor.is_none());

        // Edge: paginate with empty shards.
        let empty = paginate(&[], None, 10);
        assert!(empty.refs.is_empty());
        assert!(!empty.has_more);
    }

    /// TC-1-TL-006: generate_ref hook generates ULID and sets fields.
    #[test]
    fn tc_1_tl_006_generate_ref_hook() {
        let (decl, handler) = generate_ref_hook();

        // Verify hook declaration.
        assert_eq!(decl.id, "timeline.generate_ref");
        assert_eq!(decl.phase, HookPhase::PreSend);
        assert_eq!(decl.trigger_datatype, "timeline_index");
        assert_eq!(decl.trigger_event, TriggerEvent::Insert);
        assert_eq!(decl.priority, 20);
        assert_eq!(decl.source, "timeline");

        // Create context with input data.
        let mut ctx = HookContext::new("timeline_index".to_string(), TriggerEvent::Insert);
        ctx.signer_id = Some("@alice:relay.example.com".to_string());
        ctx.data.insert(
            "author".into(),
            serde_json::json!("@alice:relay.example.com"),
        );
        ctx.data
            .insert("content_type".into(), serde_json::json!("immutable"));
        ctx.data
            .insert("content_id".into(), serde_json::json!("sha256:abcdef"));

        // Execute the hook.
        let result = (handler)(&mut ctx);
        assert!(result.is_ok(), "generate_ref hook should succeed");

        // Verify ref_id is a valid ULID.
        let ref_id = ctx
            .data
            .get("ref_id")
            .and_then(|v| v.as_str())
            .expect("ref_id should be in context");
        assert_eq!(ref_id.len(), 26, "ULID should be 26 chars");
        assert!(
            ulid::Ulid::from_string(ref_id).is_ok(),
            "ref_id should be a valid ULID"
        );

        // Verify status is Active.
        let status = ctx
            .data
            .get("status")
            .and_then(|v| v.as_str())
            .expect("status should be in context");
        assert_eq!(status, "Active");

        // Verify created_at is an ISO 8601 timestamp.
        let created_at = ctx
            .data
            .get("created_at")
            .and_then(|v| v.as_str())
            .expect("created_at should be in context");
        assert!(
            created_at.ends_with('Z'),
            "created_at should end with Z: {created_at}"
        );
        assert!(
            created_at.contains('T'),
            "created_at should contain T: {created_at}"
        );

        // Verify the complete timeline_ref is in context.
        let ref_val = ctx
            .data
            .get("timeline_ref")
            .expect("timeline_ref should be in context");
        let tref: TimelineRef =
            serde_json::from_value(ref_val.clone()).expect("timeline_ref should deserialize");
        assert_eq!(tref.ref_id, ref_id);
        assert_eq!(tref.author, "@alice:relay.example.com");
        assert_eq!(tref.content_type, "immutable");
        assert_eq!(tref.content_id, "sha256:abcdef");
        assert_eq!(tref.status, RefStatus::Active);
    }

    /// TC-1-TL-007: ref_change_detect hook detects new ref.
    #[test]
    fn tc_1_tl_007_ref_change_detect_hook() {
        let (decl, handler) = ref_change_detect_hook();

        // Verify hook declaration.
        assert_eq!(decl.id, "timeline.ref_change_detect");
        assert_eq!(decl.phase, HookPhase::AfterWrite);
        assert_eq!(decl.trigger_datatype, "timeline_index");
        assert_eq!(decl.trigger_event, TriggerEvent::Any);
        assert_eq!(decl.priority, 30);
        assert_eq!(decl.source, "timeline");

        // Test detecting a new ref.
        let tref = make_ref("ref-new-001", "@alice:relay.com");
        let mut ctx = HookContext::new("timeline_index".to_string(), TriggerEvent::Insert);
        ctx.data
            .insert("timeline_ref".into(), serde_json::to_value(&tref).unwrap());

        let result = (handler)(&mut ctx);
        assert!(result.is_ok());

        let new_refs: Vec<String> =
            serde_json::from_value(ctx.data.get("new_refs").unwrap().clone()).unwrap();
        assert_eq!(new_refs, vec!["ref-new-001"]);

        let deleted_refs: Vec<String> =
            serde_json::from_value(ctx.data.get("deleted_refs").unwrap().clone()).unwrap();
        assert!(deleted_refs.is_empty());

        // Test detecting a deleted ref.
        let mut ctx2 = HookContext::new("timeline_index".to_string(), TriggerEvent::Update);
        ctx2.data.insert(
            "deleted_ref_id".into(),
            serde_json::json!("ref-deleted-001"),
        );

        let result2 = (handler)(&mut ctx2);
        assert!(result2.is_ok());

        let new_refs2: Vec<String> =
            serde_json::from_value(ctx2.data.get("new_refs").unwrap().clone()).unwrap();
        assert!(new_refs2.is_empty());

        let deleted_refs2: Vec<String> =
            serde_json::from_value(ctx2.data.get("deleted_refs").unwrap().clone()).unwrap();
        assert_eq!(deleted_refs2, vec!["ref-deleted-001"]);
    }

    /// TC-1-TL-008: Verify timeline_datatype() declaration fields.
    #[test]
    fn tc_1_tl_008_timeline_datatype_declaration() {
        let dt = timeline_datatype();

        assert_eq!(dt.id, "timeline");
        assert_eq!(dt.version, "0.1.0");
        assert_eq!(
            dt.dependencies,
            vec!["identity", "room"],
            "timeline depends on identity and room"
        );
        assert!(dt.is_builtin, "timeline must be a built-in datatype");
        assert!(dt.indexes.is_empty(), "timeline declares no indexes");

        // Verify the single data entry.
        assert_eq!(dt.data_entries.len(), 1);
        let entry = &dt.data_entries[0];
        assert_eq!(entry.id, "timeline_index");
        assert_eq!(entry.storage_type, StorageType::CrdtArray);
        assert_eq!(
            entry.key_pattern.template(),
            "ezagent/{room_id}/index/{shard_id}/{state|updates}"
        );
        assert!(entry.persistent);
        assert_eq!(entry.writer_rule, WriterRule::SignerInMembers);
        assert_eq!(entry.sync_strategy, SyncMode::Eager);
    }

    // -----------------------------------------------------------------------
    // Additional tests for completeness
    // -----------------------------------------------------------------------

    /// RefStatus serde roundtrip.
    #[test]
    fn ref_status_serde_roundtrip() {
        for status in &[RefStatus::Active, RefStatus::DeletedByAuthor] {
            let json = serde_json::to_string(status).expect("serialize status");
            let roundtripped: RefStatus = serde_json::from_str(&json).expect("deserialize status");
            assert_eq!(status, &roundtripped);
        }
    }

    /// TimelineRef serde roundtrip.
    #[test]
    fn timeline_ref_serde_roundtrip() {
        let tref = TimelineRef {
            ref_id: ulid::Ulid::new().to_string(),
            author: "@alice:relay.example.com".to_string(),
            content_type: "mutable".to_string(),
            content_id: "uuid-123-456".to_string(),
            created_at: "2026-03-01T12:00:00Z".to_string(),
            status: RefStatus::Active,
            signature: Some("sig-data".to_string()),
            ext: std::collections::HashMap::new(),
        };

        let json = serde_json::to_string(&tref).expect("serialize ref");
        let roundtripped: TimelineRef = serde_json::from_str(&json).expect("deserialize ref");

        assert_eq!(tref.ref_id, roundtripped.ref_id);
        assert_eq!(tref.author, roundtripped.author);
        assert_eq!(tref.content_type, roundtripped.content_type);
        assert_eq!(tref.content_id, roundtripped.content_id);
        assert_eq!(tref.created_at, roundtripped.created_at);
        assert_eq!(tref.status, roundtripped.status);
        assert_eq!(tref.signature, roundtripped.signature);
    }

    /// Verify that ext.* fields survive serialization round-trip on TimelineRef.
    #[test]
    fn timeline_ref_ext_fields_roundtrip() {
        let mut ext = std::collections::HashMap::new();
        ext.insert(
            "ext.reactions".to_string(),
            serde_json::json!({"thumbs_up": 5}),
        );
        ext.insert(
            "ext.threads".to_string(),
            serde_json::json!({"reply_count": 3}),
        );

        let tref = TimelineRef {
            ref_id: "01HXYZ".to_string(),
            author: "@alice:relay.com".to_string(),
            content_type: "immutable".to_string(),
            content_id: "hash-abc".to_string(),
            created_at: "2026-03-01T00:00:00Z".to_string(),
            status: RefStatus::Active,
            signature: None,
            ext: ext.clone(),
        };

        let json = serde_json::to_string(&tref).expect("serialize ref with ext");
        let roundtripped: TimelineRef =
            serde_json::from_str(&json).expect("deserialize ref with ext");

        assert_eq!(
            roundtripped.ext.get("ext.reactions"),
            ext.get("ext.reactions"),
            "ext.reactions must survive roundtrip"
        );
        assert_eq!(
            roundtripped.ext.get("ext.threads"),
            ext.get("ext.threads"),
            "ext.threads must survive roundtrip"
        );
        assert_eq!(roundtripped.ext.len(), 2);
    }

    /// ShardManager find_ref returns None for missing ref.
    #[test]
    fn shard_manager_find_ref_missing() {
        let sm = ShardManager::new(10);
        assert!(sm.find_ref("nonexistent").is_none());
    }

    /// ShardManager find_ref across multiple shards.
    #[test]
    fn shard_manager_find_ref_across_shards() {
        let mut sm = ShardManager::new(2); // 2 per shard.

        sm.add_ref(make_ref("ref-a", "@alice:relay.com"));
        sm.add_ref(make_ref("ref-b", "@bob:relay.com"));
        // Next ref triggers new shard.
        sm.add_ref(make_ref("ref-c", "@carol:relay.com"));

        assert_eq!(sm.shards.len(), 2);

        // Find ref in first shard.
        let found_a = sm.find_ref("ref-a");
        assert!(found_a.is_some());
        assert_eq!(found_a.unwrap().author, "@alice:relay.com");

        // Find ref in second shard.
        let found_c = sm.find_ref("ref-c");
        assert!(found_c.is_some());
        assert_eq!(found_c.unwrap().author, "@carol:relay.com");
    }

    /// Pagination with limit=0 returns empty.
    #[test]
    fn pagination_limit_zero() {
        let shards = vec![TimelineShard {
            shard_id: "s1".to_string(),
            refs: vec![make_ref("r1", "@a:r.com")],
        }];
        let result = paginate(&shards, None, 0);
        assert!(result.refs.is_empty());
        assert!(!result.has_more);
    }

    /// Pagination with a cursor pointing mid-shard.
    #[test]
    fn pagination_mid_shard_cursor() {
        let shards = vec![TimelineShard {
            shard_id: "s1".to_string(),
            refs: vec![
                make_ref("r1", "@a:r.com"),
                make_ref("r2", "@b:r.com"),
                make_ref("r3", "@c:r.com"),
            ],
        }];

        let cursor = PaginationCursor {
            shard_id: "s1".to_string(),
            offset: 1,
        };

        let result = paginate(&shards, Some(&cursor), 10);
        assert_eq!(result.refs.len(), 2);
        assert_eq!(result.refs[0].ref_id, "r2");
        assert_eq!(result.refs[1].ref_id, "r3");
        assert!(!result.has_more);
    }

    /// timeline_pagination hook parses shards and applies pagination.
    #[test]
    fn timeline_pagination_hook_integration() {
        let (_decl, handler) = timeline_pagination_hook();

        // Build shards as JSON.
        let shard1_refs = vec![make_ref("r1", "@a:r.com"), make_ref("r2", "@b:r.com")];
        let shard2_refs = vec![make_ref("r3", "@c:r.com")];

        let shards_json = serde_json::json!([
            {
                "shard_id": "s1",
                "refs": serde_json::to_value(&shard1_refs).unwrap()
            },
            {
                "shard_id": "s2",
                "refs": serde_json::to_value(&shard2_refs).unwrap()
            }
        ]);

        let mut ctx = HookContext::new("timeline_index".to_string(), TriggerEvent::Any);
        ctx.data.insert("shards".into(), shards_json);
        ctx.data.insert("limit".into(), serde_json::json!(2));

        let result = (handler)(&mut ctx);
        assert!(result.is_ok());

        let paginated: Vec<serde_json::Value> =
            serde_json::from_value(ctx.data.get("paginated_refs").unwrap().clone()).unwrap();
        assert_eq!(paginated.len(), 2);

        let has_more = ctx.data.get("has_more").and_then(|v| v.as_bool()).unwrap();
        assert!(has_more, "should have more with limit=2 and 3 total refs");
    }

    /// format_iso8601 produces a valid timestamp.
    #[test]
    fn format_iso8601_known_epoch() {
        // Unix epoch = 1970-01-01T00:00:00Z.
        let s = format_iso8601(0);
        assert_eq!(s, "1970-01-01T00:00:00Z");

        // 2026-03-01T00:00:00Z = 1772150400 (approximately).
        // Let's test a known date: 2000-01-01T00:00:00Z = 946684800.
        let s2 = format_iso8601(946684800);
        assert_eq!(s2, "2000-01-01T00:00:00Z");
    }
}
