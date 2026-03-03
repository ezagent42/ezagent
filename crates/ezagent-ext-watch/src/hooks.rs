//! Watch notification validation hooks for the Watch extension.
//!
//! This module provides the core validation logic for watch
//! subscriptions. An entity can watch a ref or a channel, and
//! the watch entity_id must match the signer.
//!
//! # Validation Rules
//!
//! ```text
//! watch_entity_id == signer  →  valid watch subscription
//! watch_entity_id != signer  →  rejected (SignerMismatch)
//! watch_entity_id is empty   →  rejected (EmptyEntityId)
//! ```

/// Errors from watch hook validation.
#[derive(Debug, thiserror::Error)]
pub enum WatchHookError {
    /// The watch entity_id does not match the signer.
    #[error("watch entity '{watch_entity}' does not match signer '{signer}'")]
    SignerMismatch {
        watch_entity: String,
        signer: String,
    },

    /// The watch entity_id is empty.
    #[error("watch entity_id must not be empty")]
    EmptyEntityId,
}

/// Validate that the watch entity_id matches the signer.
///
/// Per the spec, only the entity itself can set or modify its own
/// watch subscriptions. The entity_id in the watch record must
/// match the signer of the operation.
///
/// # Errors
///
/// Returns [`WatchHookError`] if:
/// - `watch_entity_id` is empty
/// - `watch_entity_id` does not match `signer`
pub fn validate_watch_owner(watch_entity_id: &str, signer: &str) -> Result<(), WatchHookError> {
    if watch_entity_id.is_empty() {
        return Err(WatchHookError::EmptyEntityId);
    }
    if watch_entity_id != signer {
        return Err(WatchHookError::SignerMismatch {
            watch_entity: watch_entity_id.to_string(),
            signer: signer.to_string(),
        });
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    // ── validate_watch_owner tests ───────────────────────────────────

    #[test]
    fn matching_entity_and_signer() {
        validate_watch_owner("@alice:relay.example.com", "@alice:relay.example.com").unwrap();
    }

    #[test]
    fn mismatching_entity_and_signer() {
        let err =
            validate_watch_owner("@alice:relay.example.com", "@bob:relay.example.com").unwrap_err();
        assert!(
            matches!(err, WatchHookError::SignerMismatch { .. }),
            "unexpected error: {err}"
        );
    }

    #[test]
    fn empty_entity_id() {
        let err = validate_watch_owner("", "@alice:relay.example.com").unwrap_err();
        assert!(
            matches!(err, WatchHookError::EmptyEntityId),
            "unexpected error: {err}"
        );
    }

    #[test]
    fn different_relay_domain() {
        let err = validate_watch_owner("@alice:relay-a.example.com", "@alice:relay-b.example.com")
            .unwrap_err();
        assert!(
            matches!(err, WatchHookError::SignerMismatch { .. }),
            "unexpected error: {err}"
        );
    }

    #[test]
    fn ai_agent_entity() {
        validate_watch_owner(
            "@code-reviewer:relay.example.com",
            "@code-reviewer:relay.example.com",
        )
        .unwrap();
    }
}
