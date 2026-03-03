//! Mutable content validation hooks for the Mutable extension.
//!
//! This module provides the core validation logic for message editing.
//! Only the original author of a message is permitted to edit it.
//!
//! # Validation Rule
//!
//! ```text
//! content.author == signer  →  edit allowed
//! content.author != signer  →  edit rejected (NotAuthor)
//! ```

/// Errors from mutable content hook validation.
#[derive(Debug, thiserror::Error)]
pub enum MutableHookError {
    /// The signer is not the author of the content being edited.
    #[error("signer '{signer}' is not the author '{author}' of the content")]
    NotAuthor { author: String, signer: String },
}

/// Validate that the signer is the author of the content being edited.
///
/// Per the spec, only the original author may edit mutable content.
/// This is enforced by the `mutable.validate_edit` PreSend hook.
///
/// # Errors
///
/// Returns [`MutableHookError::NotAuthor`] if `author != signer`.
pub fn validate_edit_author(author: &str, signer: &str) -> Result<(), MutableHookError> {
    if author != signer {
        return Err(MutableHookError::NotAuthor {
            author: author.to_string(),
            signer: signer.to_string(),
        });
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    // ── validate_edit_author tests ────────────────────────────────────

    #[test]
    fn author_matches_signer() {
        validate_edit_author(
            "@alice:relay.example.com",
            "@alice:relay.example.com",
        )
        .unwrap();
    }

    #[test]
    fn author_does_not_match_signer() {
        let err = validate_edit_author(
            "@alice:relay.example.com",
            "@bob:relay.example.com",
        )
        .unwrap_err();
        assert!(
            matches!(err, MutableHookError::NotAuthor { .. }),
            "unexpected error: {err}"
        );
    }

    #[test]
    fn author_different_relay() {
        let err = validate_edit_author(
            "@alice:relay-a.example.com",
            "@alice:relay-b.example.com",
        )
        .unwrap_err();
        assert!(
            matches!(err, MutableHookError::NotAuthor { .. }),
            "unexpected error: {err}"
        );
    }

    #[test]
    fn ai_agent_author_matches() {
        validate_edit_author(
            "@code-reviewer:relay.example.com",
            "@code-reviewer:relay.example.com",
        )
        .unwrap();
    }

    #[test]
    fn empty_author_and_signer_match() {
        // Edge case: empty strings are technically equal.
        validate_edit_author("", "").unwrap();
    }

    #[test]
    fn empty_author_mismatch() {
        let err = validate_edit_author("", "@bob:relay.example.com").unwrap_err();
        assert!(
            matches!(err, MutableHookError::NotAuthor { .. }),
            "unexpected error: {err}"
        );
    }
}
