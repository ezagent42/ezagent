//! Channel validation hooks for the Channels extension.
//!
//! This module provides the core validation logic for channel tags.
//! Tags must be lowercase alphanumeric with hyphens, 1-64 characters.
//!
//! # Tag Format
//!
//! ```text
//! general
//! dev-ops
//! team-42
//! ```
//!
//! Tags are validated without regex using character-by-character checks.

/// Maximum number of channel tags per Ref.
pub const MAX_TAGS: usize = 5;

/// Maximum length of a single channel tag.
pub const MAX_TAG_LENGTH: usize = 64;

/// Errors from channel hook validation.
#[derive(Debug, thiserror::Error)]
pub enum ChannelHookError {
    /// A channel tag contains invalid characters or is empty/too long.
    #[error("invalid channel tag '{tag}': must be [a-z0-9-]{{1,64}}")]
    InvalidTag { tag: String },

    /// Too many tags on a single Ref.
    #[error("too many channel tags: {count} exceeds maximum of {MAX_TAGS}")]
    TooManyTags { count: usize },

    /// Duplicate tag detected.
    #[error("duplicate channel tag: '{tag}'")]
    DuplicateTag { tag: String },
}

/// Validate a single channel tag format: `[a-z0-9-]{1,64}`.
///
/// Uses character-by-character validation (no regex dependency).
///
/// # Errors
///
/// Returns [`ChannelHookError::InvalidTag`] if the tag is empty,
/// exceeds 64 characters, or contains characters outside `[a-z0-9-]`.
pub fn validate_channel_tag(tag: &str) -> Result<(), ChannelHookError> {
    if tag.is_empty() || tag.len() > MAX_TAG_LENGTH {
        return Err(ChannelHookError::InvalidTag {
            tag: tag.to_string(),
        });
    }

    for ch in tag.chars() {
        if !matches!(ch, 'a'..='z' | '0'..='9' | '-') {
            return Err(ChannelHookError::InvalidTag {
                tag: tag.to_string(),
            });
        }
    }

    Ok(())
}

/// Validate a set of channel tags: max 5, no duplicates, each valid format.
///
/// # Errors
///
/// Returns [`ChannelHookError`] if:
/// - More than 5 tags are provided
/// - Any tag has invalid format
/// - Any tag appears more than once
pub fn validate_channel_tags(tags: &[&str]) -> Result<(), ChannelHookError> {
    if tags.len() > MAX_TAGS {
        return Err(ChannelHookError::TooManyTags { count: tags.len() });
    }

    // Check each tag's format and detect duplicates.
    // For up to 5 elements, a linear scan is faster than a HashSet.
    for (i, tag) in tags.iter().enumerate() {
        validate_channel_tag(tag)?;

        // Check for duplicates among previously validated tags.
        for prev in &tags[..i] {
            if *prev == *tag {
                return Err(ChannelHookError::DuplicateTag {
                    tag: (*tag).to_string(),
                });
            }
        }
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    // ── validate_channel_tag tests ────────────────────────────────────

    #[test]
    fn valid_simple_tags() {
        assert!(validate_channel_tag("general").is_ok());
        assert!(validate_channel_tag("dev").is_ok());
        assert!(validate_channel_tag("a").is_ok());
        assert!(validate_channel_tag("0").is_ok());
        assert!(validate_channel_tag("abc-123").is_ok());
    }

    #[test]
    fn valid_max_length_tag() {
        let tag = "a".repeat(MAX_TAG_LENGTH);
        assert!(validate_channel_tag(&tag).is_ok());
    }

    #[test]
    fn invalid_empty_tag() {
        let err = validate_channel_tag("").unwrap_err();
        assert!(
            matches!(err, ChannelHookError::InvalidTag { .. }),
            "unexpected error: {err}"
        );
    }

    #[test]
    fn invalid_too_long_tag() {
        let tag = "a".repeat(MAX_TAG_LENGTH + 1);
        let err = validate_channel_tag(&tag).unwrap_err();
        assert!(
            matches!(err, ChannelHookError::InvalidTag { .. }),
            "unexpected error: {err}"
        );
    }

    #[test]
    fn invalid_uppercase() {
        let err = validate_channel_tag("General").unwrap_err();
        assert!(
            matches!(err, ChannelHookError::InvalidTag { .. }),
            "unexpected error: {err}"
        );
    }

    #[test]
    fn invalid_underscore() {
        let err = validate_channel_tag("my_channel").unwrap_err();
        assert!(
            matches!(err, ChannelHookError::InvalidTag { .. }),
            "unexpected error: {err}"
        );
    }

    #[test]
    fn invalid_space() {
        let err = validate_channel_tag("my channel").unwrap_err();
        assert!(
            matches!(err, ChannelHookError::InvalidTag { .. }),
            "unexpected error: {err}"
        );
    }

    #[test]
    fn invalid_special_chars() {
        assert!(validate_channel_tag("chan!").is_err());
        assert!(validate_channel_tag("chan.nel").is_err());
        assert!(validate_channel_tag("chan@nel").is_err());
    }

    // ── validate_channel_tags tests ───────────────────────────────────

    #[test]
    fn valid_tag_set() {
        assert!(validate_channel_tags(&["general", "dev", "ops"]).is_ok());
    }

    #[test]
    fn valid_empty_tag_set() {
        assert!(validate_channel_tags(&[]).is_ok());
    }

    #[test]
    fn valid_max_tag_set() {
        assert!(validate_channel_tags(&["a", "b", "c", "d", "e"]).is_ok());
    }

    #[test]
    fn too_many_tags() {
        let err = validate_channel_tags(&["a", "b", "c", "d", "e", "f"]).unwrap_err();
        assert!(
            matches!(err, ChannelHookError::TooManyTags { count: 6 }),
            "unexpected error: {err}"
        );
    }

    #[test]
    fn duplicate_tags() {
        let err = validate_channel_tags(&["general", "dev", "general"]).unwrap_err();
        assert!(
            matches!(err, ChannelHookError::DuplicateTag { .. }),
            "unexpected error: {err}"
        );
    }

    #[test]
    fn invalid_tag_in_set() {
        let err = validate_channel_tags(&["general", "BAD"]).unwrap_err();
        assert!(
            matches!(err, ChannelHookError::InvalidTag { .. }),
            "unexpected error: {err}"
        );
    }
}
