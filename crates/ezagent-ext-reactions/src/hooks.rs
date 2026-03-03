//! Reaction validation hooks for the Reactions extension.
//!
//! This module provides the core validation logic for reaction keys and
//! signer authorization. The key format is `{emoji}:{entity_id}` where
//! `entity_id` follows the `@local:relay` pattern.
//!
//! # Key Format
//!
//! ```text
//! 👍:@bob:relay-a.example.com
//! ├──┘ └────────────────────┘
//! emoji      entity_id
//! ```
//!
//! The boundary between emoji and entity_id is located at the first `:@`
//! occurrence, since entity IDs always start with `@`.

/// Errors from reaction hook validation.
#[derive(Debug, thiserror::Error)]
pub enum ReactionHookError {
    /// The reaction key does not contain the `:@` boundary.
    #[error("invalid reaction key format: '{key}', expected '{{emoji}}:{{entity_id}}'")]
    InvalidKeyFormat { key: String },

    /// The emoji portion of the key is empty.
    #[error("empty emoji in reaction key")]
    EmptyEmoji,

    /// The entity_id in the reaction key does not match the signer.
    #[error("reaction key entity_id '{entity_id}' does not match signer '{signer_id}'")]
    SignerMismatch {
        entity_id: String,
        signer_id: String,
    },
}

/// Validate a reaction key format: `{emoji}:{entity_id}`.
///
/// Returns `Ok((emoji, entity_id))` on success. The entity_id starts with `@`,
/// so we split on the first `:@` to handle emojis that might contain `:`.
///
/// # Errors
///
/// Returns [`ReactionHookError`] if:
/// - The key does not contain `:@`
/// - The emoji portion is empty
pub fn parse_reaction_key(key: &str) -> Result<(&str, &str), ReactionHookError> {
    // The entity_id starts with '@', so we split on the first ':@'
    // to handle emojis that might contain ':'
    // Format: {emoji}:{entity_id} where entity_id = @local:relay
    if let Some(pos) = key.find(":@") {
        let emoji = &key[..pos];
        let entity_id = &key[pos + 1..]; // includes the '@'
        if emoji.is_empty() {
            return Err(ReactionHookError::EmptyEmoji);
        }
        Ok((emoji, entity_id))
    } else {
        Err(ReactionHookError::InvalidKeyFormat {
            key: key.to_string(),
        })
    }
}

/// Validate that the signer matches the entity_id in the reaction key.
///
/// Per the spec, `entity_id` in reaction key MUST equal signer. An entity
/// cannot add or remove reactions on behalf of another entity (except
/// through the Moderation extension, which is handled separately).
///
/// # Errors
///
/// Returns [`ReactionHookError`] if the key is malformed or the entity_id
/// does not match the `signer_id`.
pub fn validate_reaction_signer(key: &str, signer_id: &str) -> Result<(), ReactionHookError> {
    let (_, entity_id) = parse_reaction_key(key)?;
    if entity_id != signer_id {
        return Err(ReactionHookError::SignerMismatch {
            entity_id: entity_id.to_string(),
            signer_id: signer_id.to_string(),
        });
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    // ── parse_reaction_key tests ─────────────────────────────────────

    #[test]
    fn parse_valid_simple_emoji() {
        let (emoji, entity_id) = parse_reaction_key("👍:@bob:relay-a.example.com").unwrap();
        assert_eq!(emoji, "👍");
        assert_eq!(entity_id, "@bob:relay-a.example.com");
    }

    #[test]
    fn parse_valid_text_emoji() {
        let (emoji, entity_id) = parse_reaction_key(":thumbsup::@alice:relay.example.com").unwrap();
        assert_eq!(emoji, ":thumbsup:");
        assert_eq!(entity_id, "@alice:relay.example.com");
    }

    #[test]
    fn parse_valid_compound_emoji() {
        // Emoji with ZWJ sequences
        let (emoji, entity_id) = parse_reaction_key("👨‍👩‍👧‍👦:@carol:relay-b.example.com").unwrap();
        assert_eq!(emoji, "👨‍👩‍👧‍👦");
        assert_eq!(entity_id, "@carol:relay-b.example.com");
    }

    #[test]
    fn parse_valid_heart_emoji() {
        let (emoji, entity_id) = parse_reaction_key("❤️:@admin:relay.example.com").unwrap();
        assert_eq!(emoji, "❤️");
        assert_eq!(entity_id, "@admin:relay.example.com");
    }

    #[test]
    fn parse_missing_colon_at() {
        let err = parse_reaction_key("👍bob:relay.example.com").unwrap_err();
        assert!(
            matches!(err, ReactionHookError::InvalidKeyFormat { .. }),
            "unexpected error: {err}"
        );
    }

    #[test]
    fn parse_empty_key() {
        let err = parse_reaction_key("").unwrap_err();
        assert!(
            matches!(err, ReactionHookError::InvalidKeyFormat { .. }),
            "unexpected error: {err}"
        );
    }

    #[test]
    fn parse_empty_emoji() {
        let err = parse_reaction_key(":@bob:relay.example.com").unwrap_err();
        assert!(
            matches!(err, ReactionHookError::EmptyEmoji),
            "unexpected error: {err}"
        );
    }

    #[test]
    fn parse_no_entity_id() {
        // Just an emoji with no entity part
        let err = parse_reaction_key("👍").unwrap_err();
        assert!(
            matches!(err, ReactionHookError::InvalidKeyFormat { .. }),
            "unexpected error: {err}"
        );
    }

    #[test]
    fn parse_colon_but_no_at() {
        // Has colon but entity_id doesn't start with @
        let err = parse_reaction_key("👍:bob:relay.example.com").unwrap_err();
        assert!(
            matches!(err, ReactionHookError::InvalidKeyFormat { .. }),
            "unexpected error: {err}"
        );
    }

    // ── validate_reaction_signer tests ───────────────────────────────

    #[test]
    fn validate_signer_matching() {
        validate_reaction_signer("👍:@bob:relay-a.example.com", "@bob:relay-a.example.com")
            .unwrap();
    }

    #[test]
    fn validate_signer_mismatch() {
        let err =
            validate_reaction_signer("👍:@bob:relay-a.example.com", "@alice:relay-a.example.com")
                .unwrap_err();
        assert!(
            matches!(err, ReactionHookError::SignerMismatch { .. }),
            "unexpected error: {err}"
        );
    }

    #[test]
    fn validate_signer_different_relay() {
        let err =
            validate_reaction_signer("👍:@bob:relay-a.example.com", "@bob:relay-b.example.com")
                .unwrap_err();
        assert!(
            matches!(err, ReactionHookError::SignerMismatch { .. }),
            "unexpected error: {err}"
        );
    }

    #[test]
    fn validate_signer_malformed_key() {
        let err = validate_reaction_signer("invalid-key", "@bob:relay.example.com").unwrap_err();
        assert!(
            matches!(err, ReactionHookError::InvalidKeyFormat { .. }),
            "unexpected error: {err}"
        );
    }

    #[test]
    fn validate_signer_with_text_emoji() {
        validate_reaction_signer(
            ":fire::@code-reviewer:relay.example.com",
            "@code-reviewer:relay.example.com",
        )
        .unwrap();
    }
}
