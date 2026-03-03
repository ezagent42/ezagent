//! Draft validation hooks for the Drafts extension.
//!
//! This module provides the core validation logic for draft ownership.
//! An entity can only write its own drafts — the draft's entity_id
//! must match the signer.

/// Errors from draft hook validation.
#[derive(Debug, thiserror::Error)]
pub enum DraftHookError {
    /// The draft's entity_id does not match the signer.
    #[error(
        "draft owner mismatch: draft entity '{draft_entity_id}' does not match signer '{signer}'"
    )]
    OwnerMismatch {
        draft_entity_id: String,
        signer: String,
    },
}

/// Validate that the draft entity_id matches the signer.
///
/// Each entity can only write its own drafts. The `draft_entity_id`
/// parameter is the entity_id stored in the draft, and `signer` is the
/// authenticated entity performing the write.
///
/// # Errors
///
/// Returns [`DraftHookError::OwnerMismatch`] if the draft entity_id
/// does not match the signer.
pub fn validate_draft_owner(draft_entity_id: &str, signer: &str) -> Result<(), DraftHookError> {
    if draft_entity_id != signer {
        return Err(DraftHookError::OwnerMismatch {
            draft_entity_id: draft_entity_id.to_string(),
            signer: signer.to_string(),
        });
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn valid_matching_owner() {
        validate_draft_owner("@alice:relay.example.com", "@alice:relay.example.com").unwrap();
    }

    #[test]
    fn valid_agent_owner() {
        validate_draft_owner(
            "@code-reviewer:relay.example.com",
            "@code-reviewer:relay.example.com",
        )
        .unwrap();
    }

    #[test]
    fn invalid_different_entity() {
        let err =
            validate_draft_owner("@alice:relay.example.com", "@bob:relay.example.com").unwrap_err();
        assert!(
            matches!(err, DraftHookError::OwnerMismatch { .. }),
            "unexpected error: {err}"
        );
    }

    #[test]
    fn invalid_different_relay() {
        let err = validate_draft_owner("@alice:relay-a.example.com", "@alice:relay-b.example.com")
            .unwrap_err();
        assert!(
            matches!(err, DraftHookError::OwnerMismatch { .. }),
            "unexpected error: {err}"
        );
    }

    #[test]
    fn invalid_empty_signer() {
        let err = validate_draft_owner("@alice:relay.example.com", "").unwrap_err();
        assert!(
            matches!(err, DraftHookError::OwnerMismatch { .. }),
            "unexpected error: {err}"
        );
    }
}
