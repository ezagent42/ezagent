//! Thread validation hooks for the Threads extension.
//!
//! This module provides the core validation logic for thread
//! sub-conversations. A thread is rooted at an existing timeline Ref,
//! and all replies within the thread carry `ext.thread = { root }`.
//!
//! # Validation Rule
//!
//! ```text
//! root_ref_id is non-empty  →  valid thread root
//! root_ref_id is empty      →  rejected (EmptyRootId)
//! ```

/// Errors from thread hook validation.
#[derive(Debug, thiserror::Error)]
pub enum ThreadHookError {
    /// The thread root ref_id is empty.
    #[error("thread root ref_id must not be empty")]
    EmptyRootId,
}

/// Validate that a thread root ref_id is non-empty.
///
/// Per the spec, the `threads.inject` PreSend hook injects
/// `ext.thread = { root }` on the Ref. The root must reference
/// the original message that started the thread.
///
/// # Errors
///
/// Returns [`ThreadHookError::EmptyRootId`] if `root_ref_id` is empty.
pub fn validate_thread_root(root_ref_id: &str) -> Result<(), ThreadHookError> {
    if root_ref_id.is_empty() {
        return Err(ThreadHookError::EmptyRootId);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    // ── validate_thread_root tests ───────────────────────────────────

    #[test]
    fn valid_root_id() {
        validate_thread_root("ref-001").unwrap();
    }

    #[test]
    fn valid_uuid_root_id() {
        validate_thread_root("550e8400-e29b-41d4-a716-446655440000").unwrap();
    }

    #[test]
    fn valid_hash_root_id() {
        validate_thread_root("sha256:abc123def456").unwrap();
    }

    #[test]
    fn empty_root_id_rejected() {
        let err = validate_thread_root("").unwrap_err();
        assert!(
            matches!(err, ThreadHookError::EmptyRootId),
            "unexpected error: {err}"
        );
    }

    #[test]
    fn whitespace_root_id_accepted() {
        // Whitespace-only is technically non-empty; higher-level
        // validation would catch semantically invalid IDs.
        validate_thread_root(" ").unwrap();
    }
}
