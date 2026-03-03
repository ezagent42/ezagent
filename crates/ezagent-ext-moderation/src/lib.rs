//! EXT-07 Moderation extension for EZAgent.
//!
//! Moderation provides overlay actions that moderators can apply to
//! timeline content without mutating the original messages. Actions
//! include redacting, pinning, and user banning.
//!
//! # Hooks
//!
//! - **`moderation.emit_action`** (AfterWrite, priority 40) — Emits
//!   moderation events when actions are written to the overlay.
//! - **`moderation.merge_overlay`** (AfterRead, priority 60) — Merges
//!   the moderation overlay into the timeline view on read.
//!
//! # Datatypes
//!
//! - `moderation_overlay` — Stores moderation actions per room.
//!
//! # Actions
//!
//! Valid actions: `redact`, `pin`, `unpin`, `ban_user`, `unban_user`.

pub mod hooks;

use ezagent_ext_api::export_extension;
use ezagent_ext_api::prelude::*;

/// The Moderation extension plugin.
///
/// Implements [`ExtensionPlugin`] to register the `moderation.emit_action`
/// and `moderation.merge_overlay` hooks with the Engine.
pub struct ModerationExtension {
    manifest: ExtensionManifest,
}

impl Default for ModerationExtension {
    fn default() -> Self {
        Self {
            manifest: ExtensionManifest::from_toml(include_str!("../manifest.toml"))
                .expect("bundled manifest.toml must be valid"),
        }
    }
}

impl ExtensionPlugin for ModerationExtension {
    fn manifest(&self) -> &ExtensionManifest {
        &self.manifest
    }

    fn register(&self, ctx: &mut RegistrationContext) -> Result<(), ExtError> {
        // AfterWrite hook for emitting moderation action events.
        ctx.register_hook_json(
            r#"{"id":"moderation.emit_action","phase":"AfterWrite","priority":40}"#,
        )?;

        // AfterRead hook for merging overlay into timeline view.
        ctx.register_hook_json(
            r#"{"id":"moderation.merge_overlay","phase":"AfterRead","priority":60}"#,
        )?;

        Ok(())
    }
}

// Generate the C ABI entry point `ezagent_ext_register`.
export_extension!(ModerationExtension);

#[cfg(test)]
mod tests {
    use super::*;

    /// TC-2-EXT07-001: Verify valid moderation actions are accepted.
    #[test]
    fn tc_2_ext07_001_valid_actions() {
        assert!(hooks::validate_moderation_action("redact").is_ok());
        assert!(hooks::validate_moderation_action("pin").is_ok());
        assert!(hooks::validate_moderation_action("unpin").is_ok());
        assert!(hooks::validate_moderation_action("ban_user").is_ok());
        assert!(hooks::validate_moderation_action("unban_user").is_ok());
    }

    /// TC-2-EXT07-002: Verify invalid moderation actions are rejected.
    #[test]
    fn tc_2_ext07_002_invalid_actions() {
        let err = hooks::validate_moderation_action("delete").unwrap_err();
        assert!(
            matches!(err, hooks::ModerationHookError::InvalidAction { .. }),
            "expected InvalidAction error, got: {err}"
        );

        assert!(hooks::validate_moderation_action("").is_err());
        assert!(hooks::validate_moderation_action("REDACT").is_err());
        assert!(hooks::validate_moderation_action("kick").is_err());
    }

    /// TC-2-EXT07-003: Verify moderation_overlay datatype is declared.
    #[test]
    fn tc_2_ext07_003_overlay_datatype() {
        let ext = ModerationExtension::default();
        let m = ext.manifest();

        assert_eq!(m.datatype_declarations.len(), 1);
        assert_eq!(m.datatype_declarations[0], "moderation_overlay");
    }

    /// TC-2-EXT07-004: Verify manifest and hook registration.
    #[test]
    fn tc_2_ext07_004_manifest_and_registration() {
        let ext = ModerationExtension::default();
        let m = ext.manifest();

        assert_eq!(m.name, "moderation");
        assert_eq!(m.version, "0.1.0");
        assert_eq!(m.api_version, 1);
        assert_eq!(m.hook_declarations.len(), 2);
        assert_eq!(m.hook_declarations[0], "moderation.emit_action");
        assert_eq!(m.hook_declarations[1], "moderation.merge_overlay");
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
        let ext = ModerationExtension::default();
        let mut ctx = RegistrationContext::new();
        ext.register(&mut ctx).expect("register should succeed");

        let hooks = ctx.hook_jsons();
        assert_eq!(hooks.len(), 2);

        let emit: serde_json::Value =
            serde_json::from_str(&hooks[0]).expect("emit_action hook JSON should be valid");
        assert_eq!(emit["id"], "moderation.emit_action");
        assert_eq!(emit["phase"], "AfterWrite");
        assert_eq!(emit["priority"], 40);

        let merge: serde_json::Value =
            serde_json::from_str(&hooks[1]).expect("merge_overlay hook JSON should be valid");
        assert_eq!(merge["id"], "moderation.merge_overlay");
        assert_eq!(merge["phase"], "AfterRead");
        assert_eq!(merge["priority"], 60);
    }

    /// Verify the Rust manifest matches the shipped manifest.toml exactly.
    #[test]
    fn manifest_matches_toml() {
        let from_toml = ExtensionManifest::from_toml(include_str!("../manifest.toml"))
            .expect("manifest.toml should parse");
        let ext = ModerationExtension::default();
        assert_eq!(ext.manifest(), &from_toml);
    }
}
