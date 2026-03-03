//! Read receipt validation hooks for the Read Receipts extension.
//!
//! This module provides the core validation logic for receipt ownership.
//! An entity can only update its own read receipt — the key in the
//! receipt datatype must match the signer's entity_id.

/// Errors from read receipt hook validation.
#[derive(Debug, thiserror::Error)]
pub enum ReceiptHookError {
    /// The receipt key's entity_id does not match the signer.
    #[error("receipt writer mismatch: key '{key}' does not match signer '{signer}'")]
    WriterMismatch { key: String, signer: String },
}

/// Validate that the receipt key matches the signer's entity_id.
///
/// Each entity can only write its own read receipt. The `key` parameter
/// is the entity_id stored in the receipt, and `signer` is the
/// authenticated entity performing the write.
///
/// # Errors
///
/// Returns [`ReceiptHookError::WriterMismatch`] if the key does not
/// equal the signer.
pub fn validate_receipt_writer(key: &str, signer: &str) -> Result<(), ReceiptHookError> {
    if key != signer {
        return Err(ReceiptHookError::WriterMismatch {
            key: key.to_string(),
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
        validate_receipt_writer(
            "@alice:relay.example.com",
            "@alice:relay.example.com",
        )
        .unwrap();
    }

    #[test]
    fn valid_agent_writer() {
        validate_receipt_writer(
            "@code-reviewer:relay.example.com",
            "@code-reviewer:relay.example.com",
        )
        .unwrap();
    }

    #[test]
    fn invalid_different_entity() {
        let err = validate_receipt_writer(
            "@alice:relay.example.com",
            "@bob:relay.example.com",
        )
        .unwrap_err();
        assert!(
            matches!(err, ReceiptHookError::WriterMismatch { .. }),
            "unexpected error: {err}"
        );
    }

    #[test]
    fn invalid_different_relay() {
        let err = validate_receipt_writer(
            "@alice:relay-a.example.com",
            "@alice:relay-b.example.com",
        )
        .unwrap_err();
        assert!(
            matches!(err, ReceiptHookError::WriterMismatch { .. }),
            "unexpected error: {err}"
        );
    }

    #[test]
    fn invalid_empty_signer() {
        let err = validate_receipt_writer("@alice:relay.example.com", "").unwrap_err();
        assert!(
            matches!(err, ReceiptHookError::WriterMismatch { .. }),
            "unexpected error: {err}"
        );
    }
}
