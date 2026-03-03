//! EXT-12 Drafts extension for EZAgent.
//!
//! Drafts provide private per-entity draft message management. Each
//! entity can only read and write its own drafts.
//!
//! # Hooks
//!
//! - **`drafts.clear_on_send`** (PreSend, priority 90) — Clears
//!   the draft for a room after a message is sent.
//!
//! # Datatypes
//!
//! - `user_draft` — Per-entity draft storage.
//!
//! # Rules
//!
//! - Entities can only write their own drafts.

pub mod hooks;

use ezagent_ext_api::export_extension;
use ezagent_ext_api::prelude::*;

/// The Drafts extension plugin.
///
/// Implements [`ExtensionPlugin`] to register the `drafts.clear_on_send`
/// hook with the Engine.
pub struct DraftsExtension {
    manifest: ExtensionManifest,
}

impl Default for DraftsExtension {
    fn default() -> Self {
        Self {
            manifest: ExtensionManifest::from_toml(include_str!("../manifest.toml"))
                .expect("bundled manifest.toml must be valid"),
        }
    }
}

impl ExtensionPlugin for DraftsExtension {
    fn manifest(&self) -> &ExtensionManifest {
        &self.manifest
    }

    fn register(&self, ctx: &mut RegistrationContext) -> Result<(), ExtError> {
        // PreSend hook for clearing draft on send.
        ctx.register_hook_json(
            r#"{"id":"drafts.clear_on_send","phase":"PreSend","priority":90}"#,
        )?;

        Ok(())
    }
}

// Generate the C ABI entry point `ezagent_ext_register`.
export_extension!(DraftsExtension);

#[cfg(test)]
mod tests {
    use super::*;

    /// TC-2-EXT12-001: Verify draft owner validation accepts matching signer.
    #[test]
    fn tc_2_ext12_001_valid_draft_owner() {
        hooks::validate_draft_owner(
            "@alice:relay.example.com",
            "@alice:relay.example.com",
        )
        .unwrap();
    }

    /// TC-2-EXT12-002: Verify draft owner validation rejects mismatched signer.
    #[test]
    fn tc_2_ext12_002_invalid_draft_owner() {
        let err = hooks::validate_draft_owner(
            "@alice:relay.example.com",
            "@bob:relay.example.com",
        )
        .unwrap_err();
        assert!(
            matches!(err, hooks::DraftHookError::OwnerMismatch { .. }),
            "expected OwnerMismatch error, got: {err}"
        );
    }

    /// TC-2-EXT12-003: Verify manifest, datatype, and hook registration.
    #[test]
    fn tc_2_ext12_003_manifest_and_registration() {
        let ext = DraftsExtension::default();
        let m = ext.manifest();

        assert_eq!(m.name, "drafts");
        assert_eq!(m.version, "0.1.0");
        assert_eq!(m.api_version, 1);
        assert_eq!(m.datatype_declarations.len(), 1);
        assert_eq!(m.datatype_declarations[0], "user_draft");
        assert_eq!(m.hook_declarations.len(), 1);
        assert_eq!(m.hook_declarations[0], "drafts.clear_on_send");
        assert!(m.ext_dependencies.is_empty());
        assert!(m.uri_paths.is_empty());

        let mut ctx = RegistrationContext::new();
        ext.register(&mut ctx).expect("register should succeed");
        assert_eq!(ctx.hook_jsons().len(), 1);
        assert!(ctx.datatype_jsons().is_empty());
        assert!(ctx.last_error().is_none());
    }

    /// Verify registered hook JSON contains correct phase and priority.
    #[test]
    fn hook_json_contains_phase_and_priority() {
        let ext = DraftsExtension::default();
        let mut ctx = RegistrationContext::new();
        ext.register(&mut ctx).expect("register should succeed");

        let hooks = ctx.hook_jsons();
        assert_eq!(hooks.len(), 1);

        let clear: serde_json::Value =
            serde_json::from_str(&hooks[0]).expect("clear_on_send hook JSON should be valid");
        assert_eq!(clear["id"], "drafts.clear_on_send");
        assert_eq!(clear["phase"], "PreSend");
        assert_eq!(clear["priority"], 90);
    }

    /// Verify the Rust manifest matches the shipped manifest.toml exactly.
    #[test]
    fn manifest_matches_toml() {
        let from_toml = ExtensionManifest::from_toml(include_str!("../manifest.toml"))
            .expect("manifest.toml should parse");
        let ext = DraftsExtension::default();
        assert_eq!(ext.manifest(), &from_toml);
    }
}
