//! Exit code definitions and error mapping.
//!
//! Maps [`ezagent_engine::error::EngineError`] variants to standardized CLI
//! exit codes so that callers and scripts can distinguish error categories.

// Some constants are reserved for L2 features (connection errors, arg validation).
#![allow(dead_code)]

/// Process exited successfully.
pub const EXIT_SUCCESS: i32 = 0;

/// A runtime error occurred (catch-all for engine errors).
pub const EXIT_RUNTIME_ERROR: i32 = 1;

/// Invalid CLI arguments were supplied.
pub const EXIT_ARG_ERROR: i32 = 2;

/// Connection to the relay or peer could not be established.
pub const EXIT_CONNECTION_FAILED: i32 = 3;

/// Authentication failed (e.g., signature verification).
pub const EXIT_AUTH_FAILED: i32 = 4;

/// The operation was denied due to insufficient permissions.
pub const EXIT_PERMISSION_DENIED: i32 = 5;

/// Map an [`EngineError`] to the appropriate exit code.
///
/// | Error variant | Exit code |
/// |---|---|
/// | `PermissionDenied` | 5 |
/// | `NotAMember` | 5 |
/// | `SignatureVerificationFailed` | 4 |
/// | Everything else | 1 |
pub fn error_to_exit_code(err: &ezagent_engine::error::EngineError) -> i32 {
    use ezagent_engine::error::EngineError;
    match err {
        EngineError::PermissionDenied(_) => EXIT_PERMISSION_DENIED,
        EngineError::NotAMember { .. } => EXIT_PERMISSION_DENIED,
        EngineError::SignatureVerificationFailed(_) => EXIT_AUTH_FAILED,
        _ => EXIT_RUNTIME_ERROR,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use ezagent_engine::error::EngineError;

    #[test]
    fn test_permission_denied_exit_code() {
        let err = EngineError::PermissionDenied("test".into());
        assert_eq!(error_to_exit_code(&err), EXIT_PERMISSION_DENIED);
    }

    #[test]
    fn test_not_a_member_exit_code() {
        let err = EngineError::NotAMember {
            entity_id: "@alice:relay.com".into(),
            room_id: "R-alpha".into(),
        };
        assert_eq!(error_to_exit_code(&err), EXIT_PERMISSION_DENIED);
    }

    #[test]
    fn test_signature_failed_exit_code() {
        let err = EngineError::SignatureVerificationFailed("bad sig".into());
        assert_eq!(error_to_exit_code(&err), EXIT_AUTH_FAILED);
    }

    #[test]
    fn test_hook_rejected_exit_code() {
        let err = EngineError::HookRejected("denied".into());
        assert_eq!(error_to_exit_code(&err), EXIT_RUNTIME_ERROR);
    }

    #[test]
    fn test_not_found_exit_code() {
        let err = EngineError::DatatypeNotFound("room xyz".into());
        assert_eq!(error_to_exit_code(&err), EXIT_RUNTIME_ERROR);
    }

    #[test]
    fn test_circular_dependency_exit_code() {
        let err = EngineError::CircularDependency {
            cycle: "A -> B -> A".into(),
        };
        assert_eq!(error_to_exit_code(&err), EXIT_RUNTIME_ERROR);
    }

    #[test]
    fn test_extension_load_failed_exit_code() {
        let err = EngineError::ExtensionLoadFailed {
            name: "ext-test".into(),
            reason: "missing lib".into(),
        };
        assert_eq!(error_to_exit_code(&err), EXIT_RUNTIME_ERROR);
    }
}
