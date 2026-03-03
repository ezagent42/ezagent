//! Extension manifest parsing (`manifest.toml`).
//!
//! Each extension ships with a `manifest.toml` that declares its metadata,
//! datatypes, hooks, dependencies, and URI paths. The [`ExtensionManifest`]
//! struct is the in-memory representation of that file.
//!
//! # TOML Format
//!
//! ```toml
//! [extension]
//! name = "reactions"
//! version = "0.1.0"
//! api_version = "1"
//!
//! [datatypes]
//! declarations = []
//!
//! [hooks]
//! declarations = ["reactions.add"]
//!
//! [dependencies]
//! extensions = []
//!
//! [[uri.paths]]
//! pattern = "/r/{room_id}/m/{ref_id}/reactions"
//! description = "Reaction list"
//! ```
//!
//! All sections except `[extension]` are optional.

use serde::{Deserialize, Serialize};

use crate::error::ExtError;

/// A URI path declaration within an extension manifest.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct UriPath {
    /// The URI pattern template (e.g., `/r/{room_id}/m/{ref_id}/reactions`).
    pub pattern: String,
    /// Human-readable description of what this path represents.
    pub description: String,
}

/// Parsed representation of an extension's `manifest.toml`.
///
/// The manifest declares everything the Engine needs to know about an
/// extension before loading its dynamic library: name, version, API
/// compatibility, datatype declarations, hook declarations, dependency
/// requirements, and URI path registrations.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ExtensionManifest {
    /// The extension's unique name (e.g., `"reactions"`).
    pub name: String,
    /// The extension's semantic version (e.g., `"0.1.0"`).
    pub version: String,
    /// The Engine API version this extension was built against.
    pub api_version: u32,
    /// Datatype IDs declared by this extension.
    pub datatype_declarations: Vec<String>,
    /// Hook IDs declared by this extension.
    pub hook_declarations: Vec<String>,
    /// Names of other extensions this extension depends on.
    pub ext_dependencies: Vec<String>,
    /// URI path patterns registered by this extension.
    pub uri_paths: Vec<UriPath>,
}

/// Raw TOML structure for deserialization (matches the manifest.toml layout).
#[derive(Debug, Deserialize)]
struct RawManifest {
    extension: RawExtension,
    datatypes: Option<RawDatatypes>,
    hooks: Option<RawHooks>,
    dependencies: Option<RawDependencies>,
    uri: Option<RawUri>,
}

#[derive(Debug, Deserialize)]
struct RawExtension {
    name: String,
    version: String,
    api_version: String,
}

#[derive(Debug, Deserialize)]
struct RawDatatypes {
    declarations: Option<Vec<String>>,
}

#[derive(Debug, Deserialize)]
struct RawHooks {
    declarations: Option<Vec<String>>,
}

#[derive(Debug, Deserialize)]
struct RawDependencies {
    extensions: Option<Vec<String>>,
}

#[derive(Debug, Deserialize)]
struct RawUri {
    paths: Option<Vec<UriPath>>,
}

impl ExtensionManifest {
    /// Parse an [`ExtensionManifest`] from a TOML string.
    ///
    /// Returns [`ExtError::ManifestParse`] if the TOML is invalid or
    /// required fields are missing.
    pub fn from_toml(toml_str: &str) -> Result<Self, ExtError> {
        let raw: RawManifest =
            toml::from_str(toml_str).map_err(|e| ExtError::ManifestParse(e.to_string()))?;

        let api_version: u32 = raw
            .extension
            .api_version
            .parse()
            .map_err(|e| ExtError::ManifestParse(format!("invalid api_version: {e}")))?;

        Ok(Self {
            name: raw.extension.name,
            version: raw.extension.version,
            api_version,
            datatype_declarations: raw
                .datatypes
                .and_then(|d| d.declarations)
                .unwrap_or_default(),
            hook_declarations: raw
                .hooks
                .and_then(|h| h.declarations)
                .unwrap_or_default(),
            ext_dependencies: raw
                .dependencies
                .and_then(|d| d.extensions)
                .unwrap_or_default(),
            uri_paths: raw.uri.and_then(|u| u.paths).unwrap_or_default(),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// TC-2-EXT-API-001: Parse a complete manifest.toml with all sections.
    #[test]
    fn parse_full_manifest() {
        let toml_str = r#"
[extension]
name = "reactions"
version = "0.1.0"
api_version = "1"

[datatypes]
declarations = ["reactions.reaction_list"]

[hooks]
declarations = ["reactions.add", "reactions.remove"]

[dependencies]
extensions = ["message"]

[[uri.paths]]
pattern = "/r/{room_id}/m/{ref_id}/reactions"
description = "Reaction list"
"#;

        let manifest = ExtensionManifest::from_toml(toml_str).unwrap();
        assert_eq!(manifest.name, "reactions");
        assert_eq!(manifest.version, "0.1.0");
        assert_eq!(manifest.api_version, 1);
        assert_eq!(
            manifest.datatype_declarations,
            vec!["reactions.reaction_list"]
        );
        assert_eq!(
            manifest.hook_declarations,
            vec!["reactions.add", "reactions.remove"]
        );
        assert_eq!(manifest.ext_dependencies, vec!["message"]);
        assert_eq!(manifest.uri_paths.len(), 1);
        assert_eq!(
            manifest.uri_paths[0].pattern,
            "/r/{room_id}/m/{ref_id}/reactions"
        );
        assert_eq!(manifest.uri_paths[0].description, "Reaction list");
    }

    /// TC-2-EXT-API-002: Parse manifest with only the required [extension] section.
    #[test]
    fn parse_minimal_manifest() {
        let toml_str = r#"
[extension]
name = "minimal"
version = "0.0.1"
api_version = "1"
"#;

        let manifest = ExtensionManifest::from_toml(toml_str).unwrap();
        assert_eq!(manifest.name, "minimal");
        assert_eq!(manifest.version, "0.0.1");
        assert_eq!(manifest.api_version, 1);
        assert!(manifest.datatype_declarations.is_empty());
        assert!(manifest.hook_declarations.is_empty());
        assert!(manifest.ext_dependencies.is_empty());
        assert!(manifest.uri_paths.is_empty());
    }

    /// TC-2-EXT-API-003: Parse manifest with extension dependencies.
    #[test]
    fn parse_manifest_with_dependencies() {
        let toml_str = r#"
[extension]
name = "collaborative"
version = "0.2.0"
api_version = "1"

[dependencies]
extensions = ["message", "mutable"]
"#;

        let manifest = ExtensionManifest::from_toml(toml_str).unwrap();
        assert_eq!(manifest.name, "collaborative");
        assert_eq!(manifest.ext_dependencies, vec!["message", "mutable"]);
    }

    /// TC-2-EXT-API-004: Invalid TOML returns ExtError::ManifestParse.
    #[test]
    fn invalid_toml_returns_error() {
        let bad_toml = "this is not valid toml {{{{";
        let err = ExtensionManifest::from_toml(bad_toml).unwrap_err();
        match &err {
            ExtError::ManifestParse(_) => {} // expected
            other => panic!("expected ManifestParse, got: {other}"),
        }
    }

    #[test]
    fn missing_extension_section_returns_error() {
        let toml_str = r#"
[hooks]
declarations = ["foo.bar"]
"#;
        let err = ExtensionManifest::from_toml(toml_str).unwrap_err();
        match &err {
            ExtError::ManifestParse(_) => {}
            other => panic!("expected ManifestParse, got: {other}"),
        }
    }

    #[test]
    fn invalid_api_version_returns_error() {
        let toml_str = r#"
[extension]
name = "bad"
version = "0.1.0"
api_version = "not_a_number"
"#;
        let err = ExtensionManifest::from_toml(toml_str).unwrap_err();
        let msg = err.to_string();
        assert!(
            msg.contains("invalid api_version"),
            "expected api_version error, got: {msg}"
        );
    }

    #[test]
    fn multiple_uri_paths() {
        let toml_str = r#"
[extension]
name = "channels"
version = "0.1.0"
api_version = "1"

[[uri.paths]]
pattern = "/r/{room_id}/c/{channel_name}"
description = "Channel view"

[[uri.paths]]
pattern = "/r/{room_id}/c"
description = "Channel list"
"#;

        let manifest = ExtensionManifest::from_toml(toml_str).unwrap();
        assert_eq!(manifest.uri_paths.len(), 2);
        assert_eq!(
            manifest.uri_paths[0].pattern,
            "/r/{room_id}/c/{channel_name}"
        );
        assert_eq!(manifest.uri_paths[1].pattern, "/r/{room_id}/c");
    }

    #[test]
    fn manifest_serde_roundtrip() {
        let manifest = ExtensionManifest {
            name: "test".to_string(),
            version: "1.0.0".to_string(),
            api_version: 1,
            datatype_declarations: vec!["test.data".to_string()],
            hook_declarations: vec!["test.hook".to_string()],
            ext_dependencies: vec!["base".to_string()],
            uri_paths: vec![UriPath {
                pattern: "/test".to_string(),
                description: "Test path".to_string(),
            }],
        };
        let json = serde_json::to_string(&manifest).unwrap();
        let manifest2: ExtensionManifest = serde_json::from_str(&json).unwrap();
        assert_eq!(manifest, manifest2);
    }
}
