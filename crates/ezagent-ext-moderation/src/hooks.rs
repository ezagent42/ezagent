//! Moderation validation hooks for the Moderation extension.
//!
//! This module provides the core validation logic for moderation actions.
//! Valid actions are: `redact`, `pin`, `unpin`, `ban_user`, `unban_user`.

/// The set of valid moderation actions.
const VALID_ACTIONS: &[&str] = &["redact", "pin", "unpin", "ban_user", "unban_user"];

/// Errors from moderation hook validation.
#[derive(Debug, thiserror::Error)]
pub enum ModerationHookError {
    /// The action string is not a recognized moderation action.
    #[error("invalid moderation action '{action}': expected one of: redact, pin, unpin, ban_user, unban_user")]
    InvalidAction { action: String },
}

/// Validate a moderation action string.
///
/// The action must be exactly one of: `redact`, `pin`, `unpin`,
/// `ban_user`, `unban_user`.
///
/// # Errors
///
/// Returns [`ModerationHookError::InvalidAction`] if the action is not
/// in the valid set.
pub fn validate_moderation_action(action: &str) -> Result<(), ModerationHookError> {
    if VALID_ACTIONS.contains(&action) {
        Ok(())
    } else {
        Err(ModerationHookError::InvalidAction {
            action: action.to_string(),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn all_valid_actions() {
        for action in VALID_ACTIONS {
            validate_moderation_action(action).unwrap();
        }
    }

    #[test]
    fn invalid_action_delete() {
        let err = validate_moderation_action("delete").unwrap_err();
        assert!(
            matches!(err, ModerationHookError::InvalidAction { .. }),
            "unexpected error: {err}"
        );
    }

    #[test]
    fn invalid_action_empty() {
        let err = validate_moderation_action("").unwrap_err();
        assert!(
            matches!(err, ModerationHookError::InvalidAction { .. }),
            "unexpected error: {err}"
        );
    }

    #[test]
    fn invalid_action_case_sensitive() {
        assert!(validate_moderation_action("Redact").is_err());
        assert!(validate_moderation_action("REDACT").is_err());
        assert!(validate_moderation_action("Pin").is_err());
        assert!(validate_moderation_action("BAN_USER").is_err());
    }

    #[test]
    fn invalid_action_similar_words() {
        assert!(validate_moderation_action("kick").is_err());
        assert!(validate_moderation_action("mute").is_err());
        assert!(validate_moderation_action("ban").is_err());
        assert!(validate_moderation_action("unban").is_err());
    }
}
