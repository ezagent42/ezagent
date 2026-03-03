//! EXT-14 Watch extension for EZAgent.
//!
//! Provides watch notifications for refs and channels. An entity can
//! subscribe to watch a specific ref or channel and receive
//! notifications when updates occur.
//!
//! # Hooks
//!
//! - **`watch.set_ref`** (PreSend, priority 30) — Validates that the
//!   entity_id matches the signer for ref watch subscriptions.
//! - **`watch.set_channel`** (PreSend, priority 30) — Validates that
//!   the entity_id matches the signer for channel watch subscriptions.
//! - **`watch.check_ref_watchers`** (AfterWrite, priority 45) — Checks
//!   ref watchers and triggers notifications.
//! - **`watch.check_channel_watchers`** (AfterWrite, priority 46) —
//!   Checks channel watchers and triggers notifications.
//!
//! # Dependencies
//!
//! - `timeline` — Built-in timeline entity.
//! - `reply-to` — EXT-04 Reply To.

pub mod hooks;

use ezagent_ext_api::export_extension;
use ezagent_ext_api::prelude::*;

/// The Watch extension plugin.
///
/// Implements [`ExtensionPlugin`] to register the `watch.set_ref`,
/// `watch.set_channel`, `watch.check_ref_watchers`, and
/// `watch.check_channel_watchers` hooks with the Engine.
pub struct WatchExtension {
    manifest: ExtensionManifest,
}

impl Default for WatchExtension {
    fn default() -> Self {
        Self {
            manifest: ExtensionManifest::from_toml(include_str!("../manifest.toml"))
                .expect("bundled manifest.toml must be valid"),
        }
    }
}

impl ExtensionPlugin for WatchExtension {
    fn manifest(&self) -> &ExtensionManifest {
        &self.manifest
    }

    fn register(&self, ctx: &mut RegistrationContext) -> Result<(), ExtError> {
        // PreSend hook for ref watch validation.
        ctx.register_hook_json(r#"{"id":"watch.set_ref","phase":"PreSend","priority":30}"#)?;

        // PreSend hook for channel watch validation.
        ctx.register_hook_json(r#"{"id":"watch.set_channel","phase":"PreSend","priority":30}"#)?;

        // AfterWrite hook for checking ref watchers.
        ctx.register_hook_json(
            r#"{"id":"watch.check_ref_watchers","phase":"AfterWrite","priority":45}"#,
        )?;

        // AfterWrite hook for checking channel watchers.
        ctx.register_hook_json(
            r#"{"id":"watch.check_channel_watchers","phase":"AfterWrite","priority":46}"#,
        )?;

        Ok(())
    }
}

// Generate the C ABI entry point `ezagent_ext_register`.
export_extension!(WatchExtension);

#[cfg(test)]
mod tests {
    use super::*;

    /// TC-2-EXT14-001: Verify watch owner validation accepts matching signer.
    #[test]
    fn tc_2_ext14_001_valid_watch_owner() {
        hooks::validate_watch_owner("@alice:relay.example.com", "@alice:relay.example.com")
            .unwrap();
    }

    /// TC-2-EXT14-002: Verify watch owner validation rejects mismatching signer.
    #[test]
    fn tc_2_ext14_002_signer_mismatch() {
        let err = hooks::validate_watch_owner("@alice:relay.example.com", "@bob:relay.example.com")
            .unwrap_err();
        assert!(
            matches!(err, hooks::WatchHookError::SignerMismatch { .. }),
            "expected SignerMismatch error, got: {err}"
        );
    }

    /// TC-2-EXT14-003: Verify empty entity_id is rejected.
    #[test]
    fn tc_2_ext14_003_empty_entity_id() {
        let err = hooks::validate_watch_owner("", "@alice:relay.example.com").unwrap_err();
        assert!(
            matches!(err, hooks::WatchHookError::EmptyEntityId),
            "expected EmptyEntityId error, got: {err}"
        );
    }

    /// TC-2-EXT14-004: Verify manifest and hook registration.
    #[test]
    fn tc_2_ext14_004_manifest_and_registration() {
        let ext = WatchExtension::default();
        let m = ext.manifest();

        assert_eq!(m.name, "watch");
        assert_eq!(m.version, "0.1.0");
        assert_eq!(m.api_version, 1);
        assert!(m.datatype_declarations.is_empty());
        assert_eq!(m.hook_declarations.len(), 4);
        assert_eq!(m.hook_declarations[0], "watch.set_ref");
        assert_eq!(m.hook_declarations[1], "watch.set_channel");
        assert_eq!(m.hook_declarations[2], "watch.check_ref_watchers");
        assert_eq!(m.hook_declarations[3], "watch.check_channel_watchers");
        assert_eq!(m.ext_dependencies.len(), 1);
        assert_eq!(m.ext_dependencies[0], "reply-to");
        assert!(m.uri_paths.is_empty());

        let mut ctx = RegistrationContext::new();
        ext.register(&mut ctx).expect("register should succeed");
        assert_eq!(ctx.hook_jsons().len(), 4);
        assert!(ctx.datatype_jsons().is_empty());
        assert!(ctx.last_error().is_none());
    }

    /// Verify registered hook JSON contains correct phase and priority.
    #[test]
    fn hook_json_contains_phase_and_priority() {
        let ext = WatchExtension::default();
        let mut ctx = RegistrationContext::new();
        ext.register(&mut ctx).expect("register should succeed");

        let hooks = ctx.hook_jsons();
        assert_eq!(hooks.len(), 4);

        let set_ref: serde_json::Value =
            serde_json::from_str(&hooks[0]).expect("set_ref hook JSON should be valid");
        assert_eq!(set_ref["id"], "watch.set_ref");
        assert_eq!(set_ref["phase"], "PreSend");
        assert_eq!(set_ref["priority"], 30);

        let set_channel: serde_json::Value =
            serde_json::from_str(&hooks[1]).expect("set_channel hook JSON should be valid");
        assert_eq!(set_channel["id"], "watch.set_channel");
        assert_eq!(set_channel["phase"], "PreSend");
        assert_eq!(set_channel["priority"], 30);

        let check_ref: serde_json::Value =
            serde_json::from_str(&hooks[2]).expect("check_ref_watchers hook JSON should be valid");
        assert_eq!(check_ref["id"], "watch.check_ref_watchers");
        assert_eq!(check_ref["phase"], "AfterWrite");
        assert_eq!(check_ref["priority"], 45);

        let check_channel: serde_json::Value = serde_json::from_str(&hooks[3])
            .expect("check_channel_watchers hook JSON should be valid");
        assert_eq!(check_channel["id"], "watch.check_channel_watchers");
        assert_eq!(check_channel["phase"], "AfterWrite");
        assert_eq!(check_channel["priority"], 46);
    }

    /// Verify the Rust manifest matches the shipped manifest.toml exactly.
    #[test]
    fn manifest_matches_toml() {
        let from_toml = ExtensionManifest::from_toml(include_str!("../manifest.toml"))
            .expect("manifest.toml should parse");
        let ext = WatchExtension::default();
        assert_eq!(ext.manifest(), &from_toml);
    }
}
