//! Cross-room reference validation hooks for the Cross-Room Ref extension.
//!
//! This module provides the core validation logic for cross-room
//! references. A cross-room reference requires both a ref_id (the
//! target message) and a room_id (the room containing the target).
//!
//! # Validation Rules
//!
//! ```text
//! ref_id is non-empty AND room_id is non-empty  →  valid reference
//! ref_id is empty                                →  rejected (EmptyRefId)
//! room_id is empty                               →  rejected (EmptyRoomId)
//! ```

/// Errors from cross-room reference hook validation.
#[derive(Debug, thiserror::Error)]
pub enum CrossRoomHookError {
    /// The target room_id is empty.
    #[error("cross-room reference room_id must not be empty")]
    EmptyRoomId,

    /// The target ref_id is empty.
    #[error("cross-room reference ref_id must not be empty")]
    EmptyRefId,
}

/// Validate a cross-room reference.
///
/// Per the spec, the `cross_room.resolve_preview` AfterRead hook
/// resolves a preview for a reference that spans rooms. Both
/// `ref_id` and `room_id` must be non-empty.
///
/// # Errors
///
/// Returns [`CrossRoomHookError`] if either field is empty.
pub fn validate_cross_room_ref(ref_id: &str, room_id: &str) -> Result<(), CrossRoomHookError> {
    if ref_id.is_empty() {
        return Err(CrossRoomHookError::EmptyRefId);
    }
    if room_id.is_empty() {
        return Err(CrossRoomHookError::EmptyRoomId);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    // ── validate_cross_room_ref tests ────────────────────────────────

    #[test]
    fn valid_cross_room_ref() {
        validate_cross_room_ref("ref-001", "room-alpha").unwrap();
    }

    #[test]
    fn valid_uuid_ids() {
        validate_cross_room_ref(
            "550e8400-e29b-41d4-a716-446655440000",
            "660e8400-e29b-41d4-a716-446655440000",
        )
        .unwrap();
    }

    #[test]
    fn empty_ref_id() {
        let err = validate_cross_room_ref("", "room-alpha").unwrap_err();
        assert!(
            matches!(err, CrossRoomHookError::EmptyRefId),
            "unexpected error: {err}"
        );
    }

    #[test]
    fn empty_room_id() {
        let err = validate_cross_room_ref("ref-001", "").unwrap_err();
        assert!(
            matches!(err, CrossRoomHookError::EmptyRoomId),
            "unexpected error: {err}"
        );
    }

    #[test]
    fn both_empty() {
        // ref_id is checked first.
        let err = validate_cross_room_ref("", "").unwrap_err();
        assert!(
            matches!(err, CrossRoomHookError::EmptyRefId),
            "unexpected error: {err}"
        );
    }
}
