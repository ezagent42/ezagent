//! Media validation hooks for the Media extension.
//!
//! This module provides the core validation logic for blob hashes.
//! Blob hashes must follow the `sha256:<hex>` format where the hex
//! portion is exactly 64 lowercase hexadecimal characters.
//!
//! # Hash Format
//!
//! ```text
//! sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
//! ├─────┘└───────────────────────────────────────────────────────────────────┘
//! prefix                           64 hex chars
//! ```

/// Expected length of the hex portion of a SHA-256 hash.
const SHA256_HEX_LEN: usize = 64;

/// The required prefix for blob hashes.
const HASH_PREFIX: &str = "sha256:";

/// Errors from media hook validation.
#[derive(Debug, thiserror::Error)]
pub enum MediaHookError {
    /// The blob hash does not follow the `sha256:<hex>` format.
    #[error("invalid blob hash '{hash}': must be 'sha256:<64 lowercase hex chars>'")]
    InvalidBlobHash { hash: String },
}

/// Validate a blob hash format: `sha256:<64 lowercase hex chars>`.
///
/// # Errors
///
/// Returns [`MediaHookError::InvalidBlobHash`] if the hash does not
/// start with `sha256:`, has the wrong hex length, or contains
/// non-lowercase-hex characters.
pub fn validate_blob_hash(hash: &str) -> Result<(), MediaHookError> {
    let hex = match hash.strip_prefix(HASH_PREFIX) {
        Some(h) => h,
        None => {
            return Err(MediaHookError::InvalidBlobHash {
                hash: hash.to_string(),
            });
        }
    };

    if hex.len() != SHA256_HEX_LEN {
        return Err(MediaHookError::InvalidBlobHash {
            hash: hash.to_string(),
        });
    }

    for ch in hex.chars() {
        if !matches!(ch, '0'..='9' | 'a'..='f') {
            return Err(MediaHookError::InvalidBlobHash {
                hash: hash.to_string(),
            });
        }
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn valid_sha256_hash() {
        validate_blob_hash(
            "sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        )
        .unwrap();
    }

    #[test]
    fn valid_all_zeros_hash() {
        let hash = format!("sha256:{}", "0".repeat(64));
        validate_blob_hash(&hash).unwrap();
    }

    #[test]
    fn valid_all_f_hash() {
        let hash = format!("sha256:{}", "f".repeat(64));
        validate_blob_hash(&hash).unwrap();
    }

    #[test]
    fn invalid_missing_prefix() {
        let err = validate_blob_hash(
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        )
        .unwrap_err();
        assert!(
            matches!(err, MediaHookError::InvalidBlobHash { .. }),
            "unexpected error: {err}"
        );
    }

    #[test]
    fn invalid_wrong_prefix() {
        let err = validate_blob_hash(
            "md5:e3b0c44298fc1c149afbf4c8996fb924",
        )
        .unwrap_err();
        assert!(
            matches!(err, MediaHookError::InvalidBlobHash { .. }),
            "unexpected error: {err}"
        );
    }

    #[test]
    fn invalid_short_hex() {
        let err = validate_blob_hash("sha256:abcd").unwrap_err();
        assert!(
            matches!(err, MediaHookError::InvalidBlobHash { .. }),
            "unexpected error: {err}"
        );
    }

    #[test]
    fn invalid_long_hex() {
        let hash = format!("sha256:{}", "a".repeat(65));
        let err = validate_blob_hash(&hash).unwrap_err();
        assert!(
            matches!(err, MediaHookError::InvalidBlobHash { .. }),
            "unexpected error: {err}"
        );
    }

    #[test]
    fn invalid_uppercase_hex() {
        let err = validate_blob_hash(
            "sha256:E3B0C44298FC1C149AFBF4C8996FB92427AE41E4649B934CA495991B7852B855",
        )
        .unwrap_err();
        assert!(
            matches!(err, MediaHookError::InvalidBlobHash { .. }),
            "unexpected error: {err}"
        );
    }

    #[test]
    fn invalid_non_hex_chars() {
        let err = validate_blob_hash(
            "sha256:g3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        )
        .unwrap_err();
        assert!(
            matches!(err, MediaHookError::InvalidBlobHash { .. }),
            "unexpected error: {err}"
        );
    }

    #[test]
    fn invalid_empty() {
        assert!(validate_blob_hash("").is_err());
    }

    #[test]
    fn invalid_just_prefix() {
        assert!(validate_blob_hash("sha256:").is_err());
    }
}
