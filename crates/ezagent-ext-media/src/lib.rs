//! EXT-10 Media extension for EZAgent.
//!
//! Media handles blob storage with SHA-256 content-addressed deduplication.
//! Blobs are stored at the room level and referenced by hash.
//!
//! # Hooks
//!
//! - **`media.upload`** (PreSend, priority 20) — Validates blob hash
//!   format before writing.
//!
//! # Datatypes
//!
//! - `global_blob` — Content-addressed blob storage.
//! - `blob_ref` — Reference from a message to a blob.
//!
//! # URI Paths
//!
//! - `/r/{room_id}/blob/{blob_id}` — Blob storage within a room.
//!
//! # Rules
//!
//! - Blob hashes must be in `sha256:<hex>` format.
//! - The hex portion must be exactly 64 lowercase hex characters.

pub mod hooks;

use ezagent_ext_api::export_extension;
use ezagent_ext_api::prelude::*;

/// The Media extension plugin.
///
/// Implements [`ExtensionPlugin`] to register the `media.upload` hook
/// with the Engine.
pub struct MediaExtension {
    manifest: ExtensionManifest,
}

impl Default for MediaExtension {
    fn default() -> Self {
        Self {
            manifest: ExtensionManifest::from_toml(include_str!("../manifest.toml"))
                .expect("bundled manifest.toml must be valid"),
        }
    }
}

impl ExtensionPlugin for MediaExtension {
    fn manifest(&self) -> &ExtensionManifest {
        &self.manifest
    }

    fn register(&self, ctx: &mut RegistrationContext) -> Result<(), ExtError> {
        // PreSend hook for blob hash validation.
        ctx.register_hook_json(r#"{"id":"media.upload","phase":"PreSend","priority":20}"#)?;

        Ok(())
    }
}

// Generate the C ABI entry point `ezagent_ext_register`.
export_extension!(MediaExtension);

#[cfg(test)]
mod tests {
    use super::*;

    /// TC-2-EXT10-001: Verify valid blob hash is accepted.
    #[test]
    fn tc_2_ext10_001_valid_blob_hash() {
        let valid_hash = "sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";
        hooks::validate_blob_hash(valid_hash).unwrap();
    }

    /// TC-2-EXT10-002: Verify invalid blob hashes are rejected.
    #[test]
    fn tc_2_ext10_002_invalid_blob_hashes() {
        // Missing prefix.
        let err = hooks::validate_blob_hash(
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        )
        .unwrap_err();
        assert!(
            matches!(err, hooks::MediaHookError::InvalidBlobHash { .. }),
            "expected InvalidBlobHash error, got: {err}"
        );

        // Wrong prefix.
        assert!(hooks::validate_blob_hash("md5:e3b0c44298fc1c149afbf4c8996fb924").is_err());

        // Too short hex.
        assert!(hooks::validate_blob_hash("sha256:abcd").is_err());

        // Non-hex characters.
        assert!(hooks::validate_blob_hash(
            "sha256:g3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
        .is_err());

        // Empty.
        assert!(hooks::validate_blob_hash("").is_err());

        // Just prefix.
        assert!(hooks::validate_blob_hash("sha256:").is_err());

        // Uppercase hex.
        assert!(hooks::validate_blob_hash(
            "sha256:E3B0C44298FC1C149AFBF4C8996FB92427AE41E4649B934CA495991B7852B855"
        )
        .is_err());
    }

    /// TC-2-EXT10-003: Verify manifest, datatypes, and hook registration.
    #[test]
    fn tc_2_ext10_003_manifest_and_registration() {
        let ext = MediaExtension::default();
        let m = ext.manifest();

        assert_eq!(m.name, "media");
        assert_eq!(m.version, "0.2.0");
        assert_eq!(m.api_version, 1);
        assert_eq!(m.datatype_declarations.len(), 2);
        assert_eq!(m.datatype_declarations[0], "global_blob");
        assert_eq!(m.datatype_declarations[1], "blob_ref");
        assert_eq!(m.hook_declarations.len(), 1);
        assert_eq!(m.hook_declarations[0], "media.upload");
        assert!(m.ext_dependencies.is_empty());
        assert_eq!(m.uri_paths.len(), 1);
        assert_eq!(m.uri_paths[0].pattern, "/r/{room_id}/blob/{blob_id}");

        let mut ctx = RegistrationContext::new();
        ext.register(&mut ctx).expect("register should succeed");
        assert_eq!(ctx.hook_jsons().len(), 1);
        assert!(ctx.datatype_jsons().is_empty());
        assert!(ctx.last_error().is_none());
    }

    /// Verify registered hook JSON contains correct phase and priority.
    #[test]
    fn hook_json_contains_phase_and_priority() {
        let ext = MediaExtension::default();
        let mut ctx = RegistrationContext::new();
        ext.register(&mut ctx).expect("register should succeed");

        let hooks = ctx.hook_jsons();
        assert_eq!(hooks.len(), 1);

        let upload: serde_json::Value =
            serde_json::from_str(&hooks[0]).expect("upload hook JSON should be valid");
        assert_eq!(upload["id"], "media.upload");
        assert_eq!(upload["phase"], "PreSend");
        assert_eq!(upload["priority"], 20);
    }

    /// Verify the Rust manifest matches the shipped manifest.toml exactly.
    #[test]
    fn manifest_matches_toml() {
        let from_toml = ExtensionManifest::from_toml(include_str!("../manifest.toml"))
            .expect("manifest.toml should parse");
        let ext = MediaExtension::default();
        assert_eq!(ext.manifest(), &from_toml);
    }
}
