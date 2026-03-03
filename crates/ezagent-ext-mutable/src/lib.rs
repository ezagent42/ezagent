//! EXT-01 Mutable Content extension for EZAgent.
//!
//! Allows message editing after send. The original author retains
//! exclusive edit rights — no other entity may modify a mutable
//! content object.
//!
//! # Hooks
//!
//! - **`mutable.validate_edit`** (PreSend, priority 25) — Validates
//!   that the signer is the original author of the content.
//! - **`mutable.status_update`** (AfterWrite, priority 35) — Updates
//!   the Ref status to "edited" after a successful edit.
//!
//! # Datatypes
//!
//! - `mutable_content` — Mutable message content (UUID-addressed CRDT).
//!
//! # Dependencies
//!
//! - `message` — Built-in message entity.

pub mod hooks;

use ezagent_ext_api::export_extension;
use ezagent_ext_api::prelude::*;

/// The Mutable Content extension plugin.
///
/// Implements [`ExtensionPlugin`] to register the `mutable.validate_edit`
/// and `mutable.status_update` hooks with the Engine. Declares the
/// `mutable_content` datatype.
pub struct MutableExtension {
    manifest: ExtensionManifest,
}

impl Default for MutableExtension {
    fn default() -> Self {
        Self {
            manifest: ExtensionManifest::from_toml(include_str!("../manifest.toml"))
                .expect("bundled manifest.toml must be valid"),
        }
    }
}

impl ExtensionPlugin for MutableExtension {
    fn manifest(&self) -> &ExtensionManifest {
        &self.manifest
    }

    fn register(&self, ctx: &mut RegistrationContext) -> Result<(), ExtError> {
        // PreSend hook for author validation before edit.
        ctx.register_hook_json(
            r#"{"id":"mutable.validate_edit","phase":"PreSend","priority":25}"#,
        )?;

        // AfterWrite hook for status update to "edited".
        ctx.register_hook_json(
            r#"{"id":"mutable.status_update","phase":"AfterWrite","priority":35}"#,
        )?;

        Ok(())
    }
}

// Generate the C ABI entry point `ezagent_ext_register`.
export_extension!(MutableExtension);

#[cfg(test)]
mod tests {
    use super::*;

    /// TC-2-EXT01-001: Verify author validation accepts matching signer.
    #[test]
    fn tc_2_ext01_001_author_can_edit() {
        hooks::validate_edit_author(
            "@alice:relay.example.com",
            "@alice:relay.example.com",
        )
        .unwrap();
    }

    /// TC-2-EXT01-002: Verify non-author is rejected.
    #[test]
    fn tc_2_ext01_002_non_author_rejected() {
        let err = hooks::validate_edit_author(
            "@alice:relay.example.com",
            "@bob:relay.example.com",
        )
        .unwrap_err();
        assert!(
            matches!(err, hooks::MutableHookError::NotAuthor { .. }),
            "expected NotAuthor error, got: {err}"
        );
    }

    /// TC-2-EXT01-003: Verify mutable_content datatype is declared.
    #[test]
    fn tc_2_ext01_003_datatype_declared() {
        let ext = MutableExtension::default();
        let m = ext.manifest();

        assert_eq!(m.datatype_declarations.len(), 1);
        assert_eq!(m.datatype_declarations[0], "mutable_content");
    }

    /// TC-2-EXT01-004: Verify manifest and hook registration.
    #[test]
    fn tc_2_ext01_004_manifest_and_registration() {
        let ext = MutableExtension::default();
        let m = ext.manifest();

        assert_eq!(m.name, "mutable");
        assert_eq!(m.version, "0.1.0");
        assert_eq!(m.api_version, 1);
        assert_eq!(m.hook_declarations.len(), 2);
        assert_eq!(m.hook_declarations[0], "mutable.validate_edit");
        assert_eq!(m.hook_declarations[1], "mutable.status_update");
        assert!(m.ext_dependencies.is_empty());
        assert!(m.uri_paths.is_empty());

        let mut ctx = RegistrationContext::new();
        ext.register(&mut ctx).expect("register should succeed");
        assert_eq!(ctx.hook_jsons().len(), 2);
        assert!(ctx.datatype_jsons().is_empty());
        assert!(ctx.last_error().is_none());
    }

    /// Verify registered hook JSON contains correct phase and priority.
    #[test]
    fn hook_json_contains_phase_and_priority() {
        let ext = MutableExtension::default();
        let mut ctx = RegistrationContext::new();
        ext.register(&mut ctx).expect("register should succeed");

        let hooks = ctx.hook_jsons();
        assert_eq!(hooks.len(), 2);

        let validate: serde_json::Value =
            serde_json::from_str(&hooks[0]).expect("validate_edit hook JSON should be valid");
        assert_eq!(validate["id"], "mutable.validate_edit");
        assert_eq!(validate["phase"], "PreSend");
        assert_eq!(validate["priority"], 25);

        let status: serde_json::Value =
            serde_json::from_str(&hooks[1]).expect("status_update hook JSON should be valid");
        assert_eq!(status["id"], "mutable.status_update");
        assert_eq!(status["phase"], "AfterWrite");
        assert_eq!(status["priority"], 35);
    }

    /// Verify the Rust manifest matches the shipped manifest.toml exactly.
    #[test]
    fn manifest_matches_toml() {
        let from_toml = ExtensionManifest::from_toml(include_str!("../manifest.toml"))
            .expect("manifest.toml should parse");
        let ext = MutableExtension::default();
        assert_eq!(ext.manifest(), &from_toml);
    }
}
