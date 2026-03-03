//! EXT-04 Reply To extension for EZAgent.
//!
//! Adds reply annotation on Ref, enabling threaded conversations by
//! linking a new message to an existing timeline Ref.
//!
//! # Hooks
//!
//! - **`reply_to.inject`** (PreSend, priority 30) — Injects
//!   `ext.reply_to = { ref_id }` on the outgoing Ref.
//!
//! # Dependencies
//!
//! - `timeline` — Built-in timeline entity.

pub mod hooks;

use ezagent_ext_api::export_extension;
use ezagent_ext_api::prelude::*;

/// The Reply To extension plugin.
///
/// Implements [`ExtensionPlugin`] to register the `reply_to.inject`
/// hook with the Engine. Declares no datatypes — reply annotations
/// are stored in the Ref's `ext` namespace.
pub struct ReplyToExtension {
    manifest: ExtensionManifest,
}

impl Default for ReplyToExtension {
    fn default() -> Self {
        Self {
            manifest: ExtensionManifest::from_toml(include_str!("../manifest.toml"))
                .expect("bundled manifest.toml must be valid"),
        }
    }
}

impl ExtensionPlugin for ReplyToExtension {
    fn manifest(&self) -> &ExtensionManifest {
        &self.manifest
    }

    fn register(&self, ctx: &mut RegistrationContext) -> Result<(), ExtError> {
        // PreSend hook for injecting reply-to annotation.
        ctx.register_hook_json(
            r#"{"id":"reply_to.inject","phase":"PreSend","priority":30}"#,
        )?;

        Ok(())
    }
}

// Generate the C ABI entry point `ezagent_ext_register`.
export_extension!(ReplyToExtension);

#[cfg(test)]
mod tests {
    use super::*;

    /// TC-2-EXT04-001: Verify valid reply target is accepted.
    #[test]
    fn tc_2_ext04_001_valid_reply_target() {
        hooks::validate_reply_target("ref-001").unwrap();
    }

    /// TC-2-EXT04-002: Verify empty reply target is rejected.
    #[test]
    fn tc_2_ext04_002_empty_reply_target() {
        let err = hooks::validate_reply_target("").unwrap_err();
        assert!(
            matches!(err, hooks::ReplyToHookError::EmptyRefId),
            "expected EmptyRefId error, got: {err}"
        );
    }

    /// TC-2-EXT04-003: Verify manifest and hook registration.
    #[test]
    fn tc_2_ext04_003_manifest_and_registration() {
        let ext = ReplyToExtension::default();
        let m = ext.manifest();

        assert_eq!(m.name, "reply-to");
        assert_eq!(m.version, "0.1.0");
        assert_eq!(m.api_version, 1);
        assert!(m.datatype_declarations.is_empty());
        assert_eq!(m.hook_declarations.len(), 1);
        assert_eq!(m.hook_declarations[0], "reply_to.inject");
        assert_eq!(m.ext_dependencies.len(), 1);
        assert_eq!(m.ext_dependencies[0], "timeline");
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
        let ext = ReplyToExtension::default();
        let mut ctx = RegistrationContext::new();
        ext.register(&mut ctx).expect("register should succeed");

        let hooks = ctx.hook_jsons();
        assert_eq!(hooks.len(), 1);

        let inject: serde_json::Value =
            serde_json::from_str(&hooks[0]).expect("inject hook JSON should be valid");
        assert_eq!(inject["id"], "reply_to.inject");
        assert_eq!(inject["phase"], "PreSend");
        assert_eq!(inject["priority"], 30);
    }

    /// Verify the Rust manifest matches the shipped manifest.toml exactly.
    #[test]
    fn manifest_matches_toml() {
        let from_toml = ExtensionManifest::from_toml(include_str!("../manifest.toml"))
            .expect("manifest.toml should parse");
        let ext = ReplyToExtension::default();
        assert_eq!(ext.manifest(), &from_toml);
    }
}
