//! Command validation hooks for the Command extension.
//!
//! This module provides the core validation logic for slash commands.
//! A command consists of a namespace, an action, and an invoke_id for
//! tracking the invocation.
//!
//! # Command Format
//!
//! ```text
//! /{namespace} {action} [params...]
//! ```
//!
//! Namespaces must be lowercase alphanumeric (`[a-z0-9]`).

/// Errors from command hook validation.
#[derive(Debug, thiserror::Error)]
pub enum CommandHookError {
    /// The command namespace is empty.
    #[error("command namespace must not be empty")]
    EmptyNamespace,

    /// The command action is empty.
    #[error("command action must not be empty")]
    EmptyAction,

    /// The invoke_id is empty.
    #[error("command invoke_id must not be empty")]
    EmptyInvokeId,

    /// The namespace contains invalid characters (must be lowercase alphanumeric).
    #[error("invalid namespace format '{ns}': must be lowercase alphanumeric [a-z0-9]")]
    InvalidNamespaceFormat { ns: String },
}

/// Validate a command's namespace, action, and invoke_id.
///
/// Per the spec, the `command.validate` PreSend hook ensures:
/// - `ns` is non-empty and lowercase alphanumeric
/// - `action` is non-empty
/// - `invoke_id` is non-empty
///
/// # Errors
///
/// Returns [`CommandHookError`] if any field is empty or the namespace
/// format is invalid.
pub fn validate_command(ns: &str, action: &str, invoke_id: &str) -> Result<(), CommandHookError> {
    if ns.is_empty() {
        return Err(CommandHookError::EmptyNamespace);
    }
    if action.is_empty() {
        return Err(CommandHookError::EmptyAction);
    }
    if invoke_id.is_empty() {
        return Err(CommandHookError::EmptyInvokeId);
    }

    // Validate namespace format: lowercase alphanumeric only.
    for ch in ns.chars() {
        if !matches!(ch, 'a'..='z' | '0'..='9') {
            return Err(CommandHookError::InvalidNamespaceFormat { ns: ns.to_string() });
        }
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    // ── validate_command tests ────────────────────────────────────────

    #[test]
    fn valid_command() {
        validate_command("polls", "create", "inv-001").unwrap();
    }

    #[test]
    fn valid_command_numeric_ns() {
        validate_command("ext42", "run", "inv-002").unwrap();
    }

    #[test]
    fn empty_namespace() {
        let err = validate_command("", "create", "inv-001").unwrap_err();
        assert!(
            matches!(err, CommandHookError::EmptyNamespace),
            "unexpected error: {err}"
        );
    }

    #[test]
    fn empty_action() {
        let err = validate_command("polls", "", "inv-001").unwrap_err();
        assert!(
            matches!(err, CommandHookError::EmptyAction),
            "unexpected error: {err}"
        );
    }

    #[test]
    fn empty_invoke_id() {
        let err = validate_command("polls", "create", "").unwrap_err();
        assert!(
            matches!(err, CommandHookError::EmptyInvokeId),
            "unexpected error: {err}"
        );
    }

    #[test]
    fn invalid_namespace_uppercase() {
        let err = validate_command("Polls", "create", "inv-001").unwrap_err();
        assert!(
            matches!(err, CommandHookError::InvalidNamespaceFormat { .. }),
            "unexpected error: {err}"
        );
    }

    #[test]
    fn invalid_namespace_hyphen() {
        let err = validate_command("my-ns", "create", "inv-001").unwrap_err();
        assert!(
            matches!(err, CommandHookError::InvalidNamespaceFormat { .. }),
            "unexpected error: {err}"
        );
    }

    #[test]
    fn invalid_namespace_underscore() {
        let err = validate_command("my_ns", "create", "inv-001").unwrap_err();
        assert!(
            matches!(err, CommandHookError::InvalidNamespaceFormat { .. }),
            "unexpected error: {err}"
        );
    }

    #[test]
    fn invalid_namespace_special_chars() {
        let err = validate_command("ns!", "create", "inv-001").unwrap_err();
        assert!(
            matches!(err, CommandHookError::InvalidNamespaceFormat { .. }),
            "unexpected error: {err}"
        );
    }

    #[test]
    fn valid_single_char_fields() {
        validate_command("a", "b", "c").unwrap();
    }
}
