//! Reply-to validation hooks for the Reply To extension.
//!
//! This module provides the core validation logic for reply target
//! references. A reply annotation links a new Ref to an existing Ref
//! via `ref.ext.reply_to = { ref_id }`.
//!
//! # Validation Rule
//!
//! ```text
//! ref_id is non-empty  →  valid reply target
//! ref_id is empty      →  rejected (EmptyRefId)
//! ```

/// Errors from reply-to hook validation.
#[derive(Debug, thiserror::Error)]
pub enum ReplyToHookError {
    /// The reply target ref_id is empty.
    #[error("reply target ref_id must not be empty")]
    EmptyRefId,
}

/// Validate that a reply target ref_id is non-empty.
///
/// Per the spec, the `reply_to.inject` PreSend hook injects
/// `ext.reply_to = { ref_id }` on the Ref. The ref_id must reference
/// a valid existing Ref.
///
/// # Errors
///
/// Returns [`ReplyToHookError::EmptyRefId`] if `ref_id` is empty.
pub fn validate_reply_target(ref_id: &str) -> Result<(), ReplyToHookError> {
    if ref_id.is_empty() {
        return Err(ReplyToHookError::EmptyRefId);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    // ── validate_reply_target tests ──────────────────────────────────

    #[test]
    fn valid_ref_id() {
        validate_reply_target("ref-001").unwrap();
    }

    #[test]
    fn valid_uuid_ref_id() {
        validate_reply_target("550e8400-e29b-41d4-a716-446655440000").unwrap();
    }

    #[test]
    fn valid_hash_ref_id() {
        validate_reply_target("sha256:abc123def456").unwrap();
    }

    #[test]
    fn empty_ref_id_rejected() {
        let err = validate_reply_target("").unwrap_err();
        assert!(
            matches!(err, ReplyToHookError::EmptyRefId),
            "unexpected error: {err}"
        );
    }

    #[test]
    fn whitespace_ref_id_accepted() {
        // Whitespace-only is technically non-empty; higher-level
        // validation would catch semantically invalid IDs.
        validate_reply_target(" ").unwrap();
    }
}
