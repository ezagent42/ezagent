//! Protocol error types for the EZAgent protocol.

use serde::{Deserialize, Serialize};
use thiserror::Error;

/// All errors that can occur in the protocol layer.
#[derive(Debug, Error, Clone, Serialize, Deserialize)]
pub enum ProtocolError {
    /// An entity ID string could not be parsed.
    #[error("invalid entity ID: {0}")]
    InvalidEntityId(String),

    /// A cryptographic signature failed verification.
    #[error("invalid signature")]
    InvalidSignature,

    /// A timestamp is outside the acceptable range (+-5 min tolerance).
    #[error("timestamp out of range: delta {delta_ms}ms exceeds ±5min tolerance")]
    TimestampOutOfRange {
        /// The delta in milliseconds between the envelope timestamp and current time.
        delta_ms: i64,
    },

    /// The envelope version does not match the expected version.
    #[error("invalid envelope version: got {got}, expected {expected}")]
    InvalidEnvelopeVersion {
        /// The version found in the envelope.
        got: u8,
        /// The version expected by this implementation.
        expected: u8,
    },

    /// A key pattern template is invalid or cannot be instantiated.
    #[error("invalid key pattern: {0}")]
    InvalidKeyPattern(String),

    /// A serialization or deserialization error occurred.
    #[error("serialization error: {0}")]
    Serialization(String),
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn display_invalid_entity_id() {
        let e = ProtocolError::InvalidEntityId("bad-id".into());
        assert_eq!(e.to_string(), "invalid entity ID: bad-id");
    }

    #[test]
    fn display_invalid_signature() {
        let e = ProtocolError::InvalidSignature;
        assert_eq!(e.to_string(), "invalid signature");
    }

    #[test]
    fn display_timestamp_out_of_range() {
        let e = ProtocolError::TimestampOutOfRange { delta_ms: 400_000 };
        assert_eq!(
            e.to_string(),
            "timestamp out of range: delta 400000ms exceeds ±5min tolerance"
        );
    }

    #[test]
    fn display_invalid_envelope_version() {
        let e = ProtocolError::InvalidEnvelopeVersion {
            got: 2,
            expected: 1,
        };
        assert_eq!(e.to_string(), "invalid envelope version: got 2, expected 1");
    }

    #[test]
    fn display_invalid_key_pattern() {
        let e = ProtocolError::InvalidKeyPattern("missing {var}".into());
        assert_eq!(e.to_string(), "invalid key pattern: missing {var}");
    }

    #[test]
    fn display_serialization() {
        let e = ProtocolError::Serialization("unexpected EOF".into());
        assert_eq!(e.to_string(), "serialization error: unexpected EOF");
    }

    #[test]
    fn clone_works() {
        let e = ProtocolError::InvalidSignature;
        let e2 = e.clone();
        assert_eq!(e.to_string(), e2.to_string());
    }

    #[test]
    fn serde_roundtrip() {
        let e = ProtocolError::TimestampOutOfRange { delta_ms: 12345 };
        let json = serde_json::to_string(&e).unwrap();
        let e2: ProtocolError = serde_json::from_str(&json).unwrap();
        assert_eq!(e.to_string(), e2.to_string());
    }
}
