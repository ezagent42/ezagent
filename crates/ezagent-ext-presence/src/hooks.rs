//! Presence validation hooks for the Presence extension.
//!
//! This module provides the core validation logic for presence writes.
//! An entity can only update its own presence state — the key entity
//! must match the signer's entity_id.

/// Errors from presence hook validation.
#[derive(Debug, thiserror::Error)]
pub enum PresenceHookError {
    /// The presence key's entity does not match the signer.
    #[error("presence writer mismatch: key entity '{key_entity}' does not match signer '{signer}'")]
    WriterMismatch { key_entity: String, signer: String },
}

/// Validate that the presence key entity matches the signer.
///
/// Each entity can only write its own presence state. The `key_entity`
/// parameter is the entity_id embedded in the presence key, and `signer`
/// is the authenticated entity performing the write.
///
/// # Errors
///
/// Returns [`PresenceHookError::WriterMismatch`] if the key entity does
/// not match the signer.
pub fn validate_presence_writer(
    key_entity: &str,
    signer: &str,
) -> Result<(), PresenceHookError> {
    if key_entity != signer {
        return Err(PresenceHookError::WriterMismatch {
            key_entity: key_entity.to_string(),
            signer: signer.to_string(),
        });
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn valid_matching_writer() {
        validate_presence_writer(
            "@alice:relay.example.com",
            "@alice:relay.example.com",
        )
        .unwrap();
    }

    #[test]
    fn valid_agent_writer() {
        validate_presence_writer(
            "@code-reviewer:relay.example.com",
            "@code-reviewer:relay.example.com",
        )
        .unwrap();
    }

    #[test]
    fn invalid_different_entity() {
        let err = validate_presence_writer(
            "@alice:relay.example.com",
            "@bob:relay.example.com",
        )
        .unwrap_err();
        assert!(
            matches!(err, PresenceHookError::WriterMismatch { .. }),
            "unexpected error: {err}"
        );
    }

    #[test]
    fn invalid_different_relay() {
        let err = validate_presence_writer(
            "@alice:relay-a.example.com",
            "@alice:relay-b.example.com",
        )
        .unwrap_err();
        assert!(
            matches!(err, PresenceHookError::WriterMismatch { .. }),
            "unexpected error: {err}"
        );
    }

    #[test]
    fn invalid_empty_signer() {
        let err = validate_presence_writer("@alice:relay.example.com", "").unwrap_err();
        assert!(
            matches!(err, PresenceHookError::WriterMismatch { .. }),
            "unexpected error: {err}"
        );
    }
}
