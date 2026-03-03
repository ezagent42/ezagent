//! Runtime validation hooks for the Runtime extension.
//!
//! This module provides the core validation logic for the Socialware
//! runtime infrastructure. It validates namespace formats and
//! content type formats used by Socialware applications.
//!
//! # Namespace Format
//!
//! ```text
//! polls          (valid: lowercase alphanumeric, 1-32 chars)
//! my-ns          (invalid: hyphens not allowed)
//! MyNs           (invalid: uppercase not allowed)
//! ```
//!
//! # Content Type Format
//!
//! ```text
//! {namespace}:{entity_type}.{action}
//! polls:vote.cast
//! standup:report.submit
//! ```

/// Maximum length of a Socialware namespace.
pub const MAX_NAMESPACE_LENGTH: usize = 32;

/// Errors from runtime hook validation.
#[derive(Debug, thiserror::Error)]
pub enum RuntimeHookError {
    /// The Socialware namespace is not enabled in the room.
    #[error("namespace '{ns}' is not enabled in this room")]
    NamespaceNotEnabled { ns: String },

    /// The Socialware is not installed locally.
    #[error("socialware '{ns}' is not installed locally")]
    SocialwareNotInstalled { ns: String },

    /// The namespace format is invalid.
    #[error("invalid namespace format '{ns}': must be lowercase alphanumeric, 1-32 chars")]
    InvalidNamespaceFormat { ns: String },
}

/// Validate a Socialware namespace format.
///
/// Namespaces must be lowercase alphanumeric (`[a-z0-9]`), 1 to 32
/// characters long. No hyphens, underscores, or special characters.
///
/// # Errors
///
/// Returns [`RuntimeHookError::InvalidNamespaceFormat`] if the
/// namespace is empty, too long, or contains invalid characters.
pub fn validate_namespace_format(ns: &str) -> Result<(), RuntimeHookError> {
    if ns.is_empty() || ns.len() > MAX_NAMESPACE_LENGTH {
        return Err(RuntimeHookError::InvalidNamespaceFormat { ns: ns.to_string() });
    }

    for ch in ns.chars() {
        if !matches!(ch, 'a'..='z' | '0'..='9') {
            return Err(RuntimeHookError::InvalidNamespaceFormat { ns: ns.to_string() });
        }
    }

    Ok(())
}

/// Validate a Socialware content type format.
///
/// Content types follow the pattern `{ns}:{entity_type}.{action}`,
/// e.g., `polls:vote.cast`. All three parts must be non-empty.
///
/// # Errors
///
/// Returns [`RuntimeHookError::InvalidNamespaceFormat`] if the content
/// type does not match the expected format.
pub fn validate_content_type_format(content_type: &str) -> Result<(), RuntimeHookError> {
    // Split on ':' to get namespace and rest.
    let Some(colon_pos) = content_type.find(':') else {
        return Err(RuntimeHookError::InvalidNamespaceFormat {
            ns: content_type.to_string(),
        });
    };

    let ns = &content_type[..colon_pos];
    let rest = &content_type[colon_pos + 1..];

    // Validate namespace part.
    validate_namespace_format(ns)?;

    // Split rest on '.' to get entity_type and action.
    let Some(dot_pos) = rest.find('.') else {
        return Err(RuntimeHookError::InvalidNamespaceFormat {
            ns: content_type.to_string(),
        });
    };

    let entity_type = &rest[..dot_pos];
    let action = &rest[dot_pos + 1..];

    if entity_type.is_empty() || action.is_empty() {
        return Err(RuntimeHookError::InvalidNamespaceFormat {
            ns: content_type.to_string(),
        });
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    // ── validate_namespace_format tests ──────────────────────────────

    #[test]
    fn valid_namespace() {
        validate_namespace_format("polls").unwrap();
    }

    #[test]
    fn valid_namespace_numeric() {
        validate_namespace_format("ext42").unwrap();
    }

    #[test]
    fn valid_namespace_single_char() {
        validate_namespace_format("a").unwrap();
    }

    #[test]
    fn valid_namespace_max_length() {
        let ns = "a".repeat(MAX_NAMESPACE_LENGTH);
        validate_namespace_format(&ns).unwrap();
    }

    #[test]
    fn invalid_namespace_empty() {
        let err = validate_namespace_format("").unwrap_err();
        assert!(
            matches!(err, RuntimeHookError::InvalidNamespaceFormat { .. }),
            "unexpected error: {err}"
        );
    }

    #[test]
    fn invalid_namespace_too_long() {
        let ns = "a".repeat(MAX_NAMESPACE_LENGTH + 1);
        let err = validate_namespace_format(&ns).unwrap_err();
        assert!(
            matches!(err, RuntimeHookError::InvalidNamespaceFormat { .. }),
            "unexpected error: {err}"
        );
    }

    #[test]
    fn invalid_namespace_uppercase() {
        let err = validate_namespace_format("Polls").unwrap_err();
        assert!(
            matches!(err, RuntimeHookError::InvalidNamespaceFormat { .. }),
            "unexpected error: {err}"
        );
    }

    #[test]
    fn invalid_namespace_hyphen() {
        let err = validate_namespace_format("my-ns").unwrap_err();
        assert!(
            matches!(err, RuntimeHookError::InvalidNamespaceFormat { .. }),
            "unexpected error: {err}"
        );
    }

    #[test]
    fn invalid_namespace_underscore() {
        let err = validate_namespace_format("my_ns").unwrap_err();
        assert!(
            matches!(err, RuntimeHookError::InvalidNamespaceFormat { .. }),
            "unexpected error: {err}"
        );
    }

    #[test]
    fn invalid_namespace_special() {
        let err = validate_namespace_format("ns!").unwrap_err();
        assert!(
            matches!(err, RuntimeHookError::InvalidNamespaceFormat { .. }),
            "unexpected error: {err}"
        );
    }

    // ── validate_content_type_format tests ──────────────────────────

    #[test]
    fn valid_content_type() {
        validate_content_type_format("polls:vote.cast").unwrap();
    }

    #[test]
    fn valid_content_type_standup() {
        validate_content_type_format("standup:report.submit").unwrap();
    }

    #[test]
    fn invalid_content_type_no_colon() {
        let err = validate_content_type_format("pollsvote.cast").unwrap_err();
        assert!(
            matches!(err, RuntimeHookError::InvalidNamespaceFormat { .. }),
            "unexpected error: {err}"
        );
    }

    #[test]
    fn invalid_content_type_no_dot() {
        let err = validate_content_type_format("polls:votecast").unwrap_err();
        assert!(
            matches!(err, RuntimeHookError::InvalidNamespaceFormat { .. }),
            "unexpected error: {err}"
        );
    }

    #[test]
    fn invalid_content_type_empty_entity() {
        let err = validate_content_type_format("polls:.cast").unwrap_err();
        assert!(
            matches!(err, RuntimeHookError::InvalidNamespaceFormat { .. }),
            "unexpected error: {err}"
        );
    }

    #[test]
    fn invalid_content_type_empty_action() {
        let err = validate_content_type_format("polls:vote.").unwrap_err();
        assert!(
            matches!(err, RuntimeHookError::InvalidNamespaceFormat { .. }),
            "unexpected error: {err}"
        );
    }

    #[test]
    fn invalid_content_type_bad_namespace() {
        let err = validate_content_type_format("My-Ns:vote.cast").unwrap_err();
        assert!(
            matches!(err, RuntimeHookError::InvalidNamespaceFormat { .. }),
            "unexpected error: {err}"
        );
    }
}
