//! EXT-15 Command extension for EZAgent.
//!
//! Provides a slash command system for invoking Socialware actions.
//! Command data is stored as Ref annotations, not as standalone
//! datatypes.
//!
//! # Hooks
//!
//! - **`command.validate`** (PreSend, priority 35) — Validates namespace,
//!   action, and required params before writing the command.
//! - **`command.dispatch`** (AfterWrite, priority 42) — Dispatches the
//!   command to the target Socialware after write.
//! - **`command.result_notify`** (AfterWrite, priority 43) — Notifies
//!   when the command result is written.
//!
//! # Dependencies
//!
//! - `timeline` — Built-in timeline entity.
//! - `room` — Built-in room entity.

pub mod hooks;

use ezagent_ext_api::export_extension;
use ezagent_ext_api::prelude::*;

/// The Command extension plugin.
///
/// Implements [`ExtensionPlugin`] to register the `command.validate`,
/// `command.dispatch`, and `command.result_notify` hooks with the
/// Engine. Declares no datatypes — command data is stored as Ref
/// annotations.
pub struct CommandExtension {
    manifest: ExtensionManifest,
}

impl Default for CommandExtension {
    fn default() -> Self {
        Self {
            manifest: ExtensionManifest::from_toml(include_str!("../manifest.toml"))
                .expect("bundled manifest.toml must be valid"),
        }
    }
}

impl ExtensionPlugin for CommandExtension {
    fn manifest(&self) -> &ExtensionManifest {
        &self.manifest
    }

    fn register(&self, ctx: &mut RegistrationContext) -> Result<(), ExtError> {
        // PreSend hook for command validation.
        ctx.register_hook_json(r#"{"id":"command.validate","phase":"PreSend","priority":35}"#)?;

        // AfterWrite hook for command dispatch.
        ctx.register_hook_json(r#"{"id":"command.dispatch","phase":"AfterWrite","priority":42}"#)?;

        // AfterWrite hook for result notification.
        ctx.register_hook_json(
            r#"{"id":"command.result_notify","phase":"AfterWrite","priority":43}"#,
        )?;

        Ok(())
    }
}

// Generate the C ABI entry point `ezagent_ext_register`.
export_extension!(CommandExtension);

#[cfg(test)]
mod tests {
    use super::*;

    /// TC-2-EXT15-001: Verify valid command is accepted.
    #[test]
    fn tc_2_ext15_001_valid_command() {
        hooks::validate_command("polls", "create", "inv-001").unwrap();
    }

    /// TC-2-EXT15-002: Verify empty namespace is rejected.
    #[test]
    fn tc_2_ext15_002_empty_namespace() {
        let err = hooks::validate_command("", "create", "inv-001").unwrap_err();
        assert!(
            matches!(err, hooks::CommandHookError::EmptyNamespace),
            "expected EmptyNamespace error, got: {err}"
        );
    }

    /// TC-2-EXT15-003: Verify invalid namespace format is rejected.
    #[test]
    fn tc_2_ext15_003_invalid_namespace() {
        let err = hooks::validate_command("My-Ns", "create", "inv-001").unwrap_err();
        assert!(
            matches!(err, hooks::CommandHookError::InvalidNamespaceFormat { .. }),
            "expected InvalidNamespaceFormat error, got: {err}"
        );
    }

    /// TC-2-EXT15-004: Verify manifest and hook registration.
    #[test]
    fn tc_2_ext15_004_manifest_and_registration() {
        let ext = CommandExtension::default();
        let m = ext.manifest();

        assert_eq!(m.name, "command");
        assert_eq!(m.version, "0.1.0");
        assert_eq!(m.api_version, 1);
        assert!(m.datatype_declarations.is_empty());
        assert_eq!(m.hook_declarations.len(), 3);
        assert_eq!(m.hook_declarations[0], "command.validate");
        assert_eq!(m.hook_declarations[1], "command.dispatch");
        assert_eq!(m.hook_declarations[2], "command.result_notify");
        assert!(m.ext_dependencies.is_empty());
        assert!(m.uri_paths.is_empty());

        let mut ctx = RegistrationContext::new();
        ext.register(&mut ctx).expect("register should succeed");
        assert_eq!(ctx.hook_jsons().len(), 3);
        assert!(ctx.datatype_jsons().is_empty());
        assert!(ctx.last_error().is_none());
    }

    /// Verify registered hook JSON contains correct phase and priority.
    #[test]
    fn hook_json_contains_phase_and_priority() {
        let ext = CommandExtension::default();
        let mut ctx = RegistrationContext::new();
        ext.register(&mut ctx).expect("register should succeed");

        let hooks = ctx.hook_jsons();
        assert_eq!(hooks.len(), 3);

        let validate: serde_json::Value =
            serde_json::from_str(&hooks[0]).expect("validate hook JSON should be valid");
        assert_eq!(validate["id"], "command.validate");
        assert_eq!(validate["phase"], "PreSend");
        assert_eq!(validate["priority"], 35);

        let dispatch: serde_json::Value =
            serde_json::from_str(&hooks[1]).expect("dispatch hook JSON should be valid");
        assert_eq!(dispatch["id"], "command.dispatch");
        assert_eq!(dispatch["phase"], "AfterWrite");
        assert_eq!(dispatch["priority"], 42);

        let notify: serde_json::Value =
            serde_json::from_str(&hooks[2]).expect("result_notify hook JSON should be valid");
        assert_eq!(notify["id"], "command.result_notify");
        assert_eq!(notify["phase"], "AfterWrite");
        assert_eq!(notify["priority"], 43);
    }

    /// Verify the Rust manifest matches the shipped manifest.toml exactly.
    #[test]
    fn manifest_matches_toml() {
        let from_toml = ExtensionManifest::from_toml(include_str!("../manifest.toml"))
            .expect("manifest.toml should parse");
        let ext = CommandExtension::default();
        assert_eq!(ext.manifest(), &from_toml);
    }
}
