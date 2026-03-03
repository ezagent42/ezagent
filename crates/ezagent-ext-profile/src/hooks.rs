//! Profile validation hooks for the Profile extension.
//!
//! This module provides the core validation logic for entity profiles.
//! - Writer validation: only the entity itself can update its profile.
//! - Entity type validation: must be "human" or "agent".

/// The set of valid entity types.
const VALID_ENTITY_TYPES: &[&str] = &["human", "agent", "service"];

/// Errors from profile hook validation.
#[derive(Debug, thiserror::Error)]
pub enum ProfileHookError {
    /// The profile's entity does not match the signer.
    #[error("profile writer mismatch: profile entity '{profile_entity}' does not match signer '{signer}'")]
    WriterMismatch {
        profile_entity: String,
        signer: String,
    },

    /// The entity type is not valid.
    #[error("invalid entity type '{entity_type}': expected 'human', 'agent', or 'service'")]
    InvalidEntityType { entity_type: String },
}

/// Validate that the profile entity matches the signer.
///
/// Each entity can only write its own profile. The `profile_entity`
/// parameter is the entity_id of the profile being written, and `signer`
/// is the authenticated entity performing the write.
///
/// # Errors
///
/// Returns [`ProfileHookError::WriterMismatch`] if the profile entity
/// does not match the signer.
pub fn validate_profile_writer(
    profile_entity: &str,
    signer: &str,
) -> Result<(), ProfileHookError> {
    if profile_entity != signer {
        return Err(ProfileHookError::WriterMismatch {
            profile_entity: profile_entity.to_string(),
            signer: signer.to_string(),
        });
    }
    Ok(())
}

/// Validate an entity type string.
///
/// The entity type must be exactly `"human"` or `"agent"`.
///
/// # Errors
///
/// Returns [`ProfileHookError::InvalidEntityType`] if the type is not
/// in the valid set.
pub fn validate_entity_type(entity_type: &str) -> Result<(), ProfileHookError> {
    if VALID_ENTITY_TYPES.contains(&entity_type) {
        Ok(())
    } else {
        Err(ProfileHookError::InvalidEntityType {
            entity_type: entity_type.to_string(),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // ── validate_profile_writer tests ─────────────────────────────────

    #[test]
    fn valid_matching_writer() {
        validate_profile_writer(
            "@alice:relay.example.com",
            "@alice:relay.example.com",
        )
        .unwrap();
    }

    #[test]
    fn valid_agent_writer() {
        validate_profile_writer(
            "@code-reviewer:relay.example.com",
            "@code-reviewer:relay.example.com",
        )
        .unwrap();
    }

    #[test]
    fn invalid_different_entity() {
        let err = validate_profile_writer(
            "@alice:relay.example.com",
            "@bob:relay.example.com",
        )
        .unwrap_err();
        assert!(
            matches!(err, ProfileHookError::WriterMismatch { .. }),
            "unexpected error: {err}"
        );
    }

    #[test]
    fn invalid_different_relay() {
        let err = validate_profile_writer(
            "@alice:relay-a.example.com",
            "@alice:relay-b.example.com",
        )
        .unwrap_err();
        assert!(
            matches!(err, ProfileHookError::WriterMismatch { .. }),
            "unexpected error: {err}"
        );
    }

    // ── validate_entity_type tests ────────────────────────────────────

    #[test]
    fn valid_human_type() {
        validate_entity_type("human").unwrap();
    }

    #[test]
    fn valid_agent_type() {
        validate_entity_type("agent").unwrap();
    }

    #[test]
    fn valid_service_type() {
        validate_entity_type("service").unwrap();
    }

    #[test]
    fn invalid_empty_type() {
        let err = validate_entity_type("").unwrap_err();
        assert!(
            matches!(err, ProfileHookError::InvalidEntityType { .. }),
            "unexpected error: {err}"
        );
    }

    #[test]
    fn invalid_bot_type() {
        let err = validate_entity_type("bot").unwrap_err();
        assert!(
            matches!(err, ProfileHookError::InvalidEntityType { .. }),
            "unexpected error: {err}"
        );
    }

    #[test]
    fn invalid_case_sensitive() {
        assert!(validate_entity_type("Human").is_err());
        assert!(validate_entity_type("AGENT").is_err());
        assert!(validate_entity_type("Agent").is_err());
        assert!(validate_entity_type("Service").is_err());
    }
}
