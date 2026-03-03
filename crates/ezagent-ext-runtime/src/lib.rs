//! EXT-17 Runtime extension for EZAgent.
//!
//! Provides the Socialware runtime infrastructure. This extension is
//! the gateway for Socialware applications — it validates namespace
//! enablement, local installation, and maintains the socialware
//! messages index.
//!
//! # Hooks
//!
//! - **`runtime.namespace_check`** (PreSend, priority 45) — Validates
//!   that the Socialware namespace is enabled in the room.
//! - **`runtime.local_sw_check`** (PreSend, priority 46) — Validates
//!   that the Socialware is installed locally.
//! - **`runtime.sw_message_index`** (AfterWrite, priority 50) —
//!   Updates the socialware messages index after write.
//!
//! # URI Paths
//!
//! - `/r/{room_id}/sw/{namespace}` — Socialware namespace within a room.
//!
//! # Dependencies
//!
//! - `channels` — EXT-06 Channels.
//! - `reply-to` — EXT-04 Reply To.
//! - `command` — EXT-15 Command.

pub mod hooks;

use ezagent_ext_api::export_extension;
use ezagent_ext_api::prelude::*;

/// The Runtime extension plugin.
///
/// Implements [`ExtensionPlugin`] to register the
/// `runtime.namespace_check`, `runtime.local_sw_check`, and
/// `runtime.sw_message_index` hooks with the Engine.
pub struct RuntimeExtension {
    manifest: ExtensionManifest,
}

impl Default for RuntimeExtension {
    fn default() -> Self {
        Self {
            manifest: ExtensionManifest::from_toml(include_str!("../manifest.toml"))
                .expect("bundled manifest.toml must be valid"),
        }
    }
}

impl ExtensionPlugin for RuntimeExtension {
    fn manifest(&self) -> &ExtensionManifest {
        &self.manifest
    }

    fn register(&self, ctx: &mut RegistrationContext) -> Result<(), ExtError> {
        // PreSend hook for namespace enablement check.
        ctx.register_hook_json(
            r#"{"id":"runtime.namespace_check","phase":"PreSend","priority":45}"#,
        )?;

        // PreSend hook for local Socialware installation check.
        ctx.register_hook_json(
            r#"{"id":"runtime.local_sw_check","phase":"PreSend","priority":46}"#,
        )?;

        // AfterWrite hook for socialware messages index update.
        ctx.register_hook_json(
            r#"{"id":"runtime.sw_message_index","phase":"AfterWrite","priority":50}"#,
        )?;

        Ok(())
    }
}

// Generate the C ABI entry point `ezagent_ext_register`.
export_extension!(RuntimeExtension);

#[cfg(test)]
mod tests {
    use super::*;

    /// TC-2-EXT17-001: Verify valid namespace format is accepted.
    #[test]
    fn tc_2_ext17_001_valid_namespace() {
        hooks::validate_namespace_format("polls").unwrap();
        hooks::validate_namespace_format("standup").unwrap();
        hooks::validate_namespace_format("ext42").unwrap();
    }

    /// TC-2-EXT17-002: Verify invalid namespace format is rejected.
    #[test]
    fn tc_2_ext17_002_invalid_namespace() {
        assert!(hooks::validate_namespace_format("").is_err());
        assert!(hooks::validate_namespace_format("My-Ns").is_err());
        assert!(hooks::validate_namespace_format("my_ns").is_err());

        let long_ns = "a".repeat(33);
        assert!(hooks::validate_namespace_format(&long_ns).is_err());
    }

    /// TC-2-EXT17-003: Verify valid content type format is accepted.
    #[test]
    fn tc_2_ext17_003_valid_content_type() {
        hooks::validate_content_type_format("polls:vote.cast").unwrap();
        hooks::validate_content_type_format("standup:report.submit").unwrap();
    }

    /// TC-2-EXT17-004: Verify invalid content type format is rejected.
    #[test]
    fn tc_2_ext17_004_invalid_content_type() {
        assert!(hooks::validate_content_type_format("pollsvote.cast").is_err());
        assert!(hooks::validate_content_type_format("polls:votecast").is_err());
        assert!(hooks::validate_content_type_format("polls:.cast").is_err());
        assert!(hooks::validate_content_type_format("polls:vote.").is_err());
    }

    /// TC-2-EXT17-005: Verify URI path is declared.
    #[test]
    fn tc_2_ext17_005_uri_path() {
        let ext = RuntimeExtension::default();
        let m = ext.manifest();

        assert_eq!(m.uri_paths.len(), 1);
        assert_eq!(m.uri_paths[0].pattern, "/r/{room_id}/sw/{namespace}");
        assert_eq!(
            m.uri_paths[0].description,
            "Socialware namespace within a room"
        );
    }

    /// TC-2-EXT17-006: Verify manifest and hook registration.
    #[test]
    fn tc_2_ext17_006_manifest_and_registration() {
        let ext = RuntimeExtension::default();
        let m = ext.manifest();

        assert_eq!(m.name, "runtime");
        assert_eq!(m.version, "0.1.0");
        assert_eq!(m.api_version, 1);
        assert!(m.datatype_declarations.is_empty());
        assert_eq!(m.hook_declarations.len(), 3);
        assert_eq!(m.hook_declarations[0], "runtime.namespace_check");
        assert_eq!(m.hook_declarations[1], "runtime.local_sw_check");
        assert_eq!(m.hook_declarations[2], "runtime.sw_message_index");
        assert_eq!(m.ext_dependencies.len(), 3);
        assert_eq!(m.ext_dependencies[0], "channels");
        assert_eq!(m.ext_dependencies[1], "reply-to");
        assert_eq!(m.ext_dependencies[2], "command");

        let mut ctx = RegistrationContext::new();
        ext.register(&mut ctx).expect("register should succeed");
        assert_eq!(ctx.hook_jsons().len(), 3);
        assert!(ctx.datatype_jsons().is_empty());
        assert!(ctx.last_error().is_none());
    }

    /// Verify registered hook JSON contains correct phase and priority.
    #[test]
    fn hook_json_contains_phase_and_priority() {
        let ext = RuntimeExtension::default();
        let mut ctx = RegistrationContext::new();
        ext.register(&mut ctx).expect("register should succeed");

        let hooks = ctx.hook_jsons();
        assert_eq!(hooks.len(), 3);

        let ns_check: serde_json::Value =
            serde_json::from_str(&hooks[0]).expect("namespace_check hook JSON should be valid");
        assert_eq!(ns_check["id"], "runtime.namespace_check");
        assert_eq!(ns_check["phase"], "PreSend");
        assert_eq!(ns_check["priority"], 45);

        let sw_check: serde_json::Value =
            serde_json::from_str(&hooks[1]).expect("local_sw_check hook JSON should be valid");
        assert_eq!(sw_check["id"], "runtime.local_sw_check");
        assert_eq!(sw_check["phase"], "PreSend");
        assert_eq!(sw_check["priority"], 46);

        let index: serde_json::Value =
            serde_json::from_str(&hooks[2]).expect("sw_message_index hook JSON should be valid");
        assert_eq!(index["id"], "runtime.sw_message_index");
        assert_eq!(index["phase"], "AfterWrite");
        assert_eq!(index["priority"], 50);
    }

    /// Verify the Rust manifest matches the shipped manifest.toml exactly.
    #[test]
    fn manifest_matches_toml() {
        let from_toml = ExtensionManifest::from_toml(include_str!("../manifest.toml"))
            .expect("manifest.toml should parse");
        let ext = RuntimeExtension::default();
        assert_eq!(ext.manifest(), &from_toml);
    }
}
