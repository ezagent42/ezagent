//! Error types for the extension API.
//!
//! This module defines [`ExtError`], the primary error enum used throughout
//! the extension loading, manifest parsing, and registration process.

use thiserror::Error;

/// Errors that can occur during extension loading and registration.
#[derive(Debug, Error)]
pub enum ExtError {
    /// The manifest TOML could not be parsed or is missing required fields.
    #[error("manifest parse error: {0}")]
    ManifestParse(String),

    /// An extension failed to register with the engine (e.g., duplicate
    /// datatype, invalid hook declaration).
    #[error("registration failed: {0}")]
    RegistrationFailed(String),

    /// The extension was built against an incompatible Engine API version.
    #[error("incompatible API version: extension requires {extension}, engine provides {engine}")]
    IncompatibleApiVersion {
        /// The API version the extension was built against.
        extension: u32,
        /// The API version the engine currently provides.
        engine: u32,
    },
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn display_manifest_parse() {
        let e = ExtError::ManifestParse("missing [extension] section".into());
        assert_eq!(
            e.to_string(),
            "manifest parse error: missing [extension] section"
        );
    }

    #[test]
    fn display_registration_failed() {
        let e = ExtError::RegistrationFailed("duplicate datatype: reactions".into());
        assert_eq!(
            e.to_string(),
            "registration failed: duplicate datatype: reactions"
        );
    }

    #[test]
    fn display_incompatible_api_version() {
        let e = ExtError::IncompatibleApiVersion {
            extension: 2,
            engine: 1,
        };
        assert_eq!(
            e.to_string(),
            "incompatible API version: extension requires 2, engine provides 1"
        );
    }
}
