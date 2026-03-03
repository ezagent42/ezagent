//! EXT-09 Presence extension for EZAgent.
//!
//! Presence tracks ephemeral online/typing state for entities in a room.
//! Both datatypes (`presence_token` and `awareness_state`) are ephemeral
//! and not persisted.
//!
//! # Hooks
//!
//! - **`presence.online_change`** (AfterWrite, priority 40) — Fires
//!   when an entity's online status changes.
//! - **`presence.typing_change`** (AfterWrite, priority 40) — Fires
//!   when an entity's typing indicator changes.
//!
//! # Datatypes
//!
//! - `presence_token` — Ephemeral online/offline status token.
//! - `awareness_state` — Ephemeral awareness state (typing, cursor, etc.).
//!
//! # Rules
//!
//! - The presence key's entity must match the signer — entities can only
//!   update their own presence state.

pub mod hooks;

use ezagent_ext_api::export_extension;
use ezagent_ext_api::prelude::*;

/// The Presence extension plugin.
///
/// Implements [`ExtensionPlugin`] to register the `presence.online_change`
/// and `presence.typing_change` hooks with the Engine.
pub struct PresenceExtension {
    manifest: ExtensionManifest,
}

impl Default for PresenceExtension {
    fn default() -> Self {
        Self {
            manifest: ExtensionManifest::from_toml(include_str!("../manifest.toml"))
                .expect("bundled manifest.toml must be valid"),
        }
    }
}

impl ExtensionPlugin for PresenceExtension {
    fn manifest(&self) -> &ExtensionManifest {
        &self.manifest
    }

    fn register(&self, ctx: &mut RegistrationContext) -> Result<(), ExtError> {
        // AfterWrite hook for online status changes.
        ctx.register_hook_json(
            r#"{"id":"presence.online_change","phase":"AfterWrite","priority":40}"#,
        )?;

        // AfterWrite hook for typing indicator changes.
        ctx.register_hook_json(
            r#"{"id":"presence.typing_change","phase":"AfterWrite","priority":40}"#,
        )?;

        Ok(())
    }
}

// Generate the C ABI entry point `ezagent_ext_register`.
export_extension!(PresenceExtension);

#[cfg(test)]
mod tests {
    use super::*;

    /// TC-2-EXT09-001: Verify presence writer validation accepts matching signer.
    #[test]
    fn tc_2_ext09_001_valid_presence_writer() {
        hooks::validate_presence_writer(
            "@alice:relay.example.com",
            "@alice:relay.example.com",
        )
        .unwrap();
    }

    /// TC-2-EXT09-002: Verify presence writer validation rejects mismatched signer.
    #[test]
    fn tc_2_ext09_002_invalid_presence_writer() {
        let err = hooks::validate_presence_writer(
            "@alice:relay.example.com",
            "@bob:relay.example.com",
        )
        .unwrap_err();
        assert!(
            matches!(err, hooks::PresenceHookError::WriterMismatch { .. }),
            "expected WriterMismatch error, got: {err}"
        );
    }

    /// TC-2-EXT09-003: Verify manifest, datatypes, and hook registration.
    #[test]
    fn tc_2_ext09_003_manifest_and_registration() {
        let ext = PresenceExtension::default();
        let m = ext.manifest();

        assert_eq!(m.name, "presence");
        assert_eq!(m.version, "0.1.0");
        assert_eq!(m.api_version, 1);
        assert_eq!(m.datatype_declarations.len(), 2);
        assert_eq!(m.datatype_declarations[0], "presence_token");
        assert_eq!(m.datatype_declarations[1], "awareness_state");
        assert_eq!(m.hook_declarations.len(), 2);
        assert_eq!(m.hook_declarations[0], "presence.online_change");
        assert_eq!(m.hook_declarations[1], "presence.typing_change");
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
        let ext = PresenceExtension::default();
        let mut ctx = RegistrationContext::new();
        ext.register(&mut ctx).expect("register should succeed");

        let hooks = ctx.hook_jsons();
        assert_eq!(hooks.len(), 2);

        let online: serde_json::Value =
            serde_json::from_str(&hooks[0]).expect("online_change hook JSON should be valid");
        assert_eq!(online["id"], "presence.online_change");
        assert_eq!(online["phase"], "AfterWrite");
        assert_eq!(online["priority"], 40);

        let typing: serde_json::Value =
            serde_json::from_str(&hooks[1]).expect("typing_change hook JSON should be valid");
        assert_eq!(typing["id"], "presence.typing_change");
        assert_eq!(typing["phase"], "AfterWrite");
        assert_eq!(typing["priority"], 40);
    }

    /// Verify the Rust manifest matches the shipped manifest.toml exactly.
    #[test]
    fn manifest_matches_toml() {
        let from_toml = ExtensionManifest::from_toml(include_str!("../manifest.toml"))
            .expect("manifest.toml should parse");
        let ext = PresenceExtension::default();
        assert_eq!(ext.manifest(), &from_toml);
    }
}
