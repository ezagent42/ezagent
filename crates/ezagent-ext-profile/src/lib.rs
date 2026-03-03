//! EXT-13 Profile extension for EZAgent.
//!
//! Profile provides entity profile management with type validation.
//! Each entity can only update its own profile, and entity types must
//! be either "human" or "agent".
//!
//! # Hooks
//!
//! - **`profile.validate_fields`** (PreSend, priority 25) — Validates
//!   profile fields including entity_type.
//! - **`profile.validate_writer`** (PreSend, priority 20) — Validates
//!   that the profile writer matches the entity.
//! - **`profile.index_update`** (AfterWrite, priority 50) — Notifies
//!   Relay-side index when a profile changes.
//!
//! # Datatypes
//!
//! - `entity_profile` — Per-entity profile storage.
//!
//! # URI Paths
//!
//! - `/@{entity_id}/profile` — Entity profile page.
//!
//! # Rules
//!
//! - Only the entity itself can update its profile.
//! - Entity type must be "human" or "agent".

pub mod hooks;

use ezagent_ext_api::export_extension;
use ezagent_ext_api::prelude::*;

/// The Profile extension plugin.
///
/// Implements [`ExtensionPlugin`] to register the `profile.validate_fields`,
/// `profile.validate_writer`, and `profile.index_update` hooks with the Engine.
pub struct ProfileExtension {
    manifest: ExtensionManifest,
}

impl Default for ProfileExtension {
    fn default() -> Self {
        Self {
            manifest: ExtensionManifest::from_toml(include_str!("../manifest.toml"))
                .expect("bundled manifest.toml must be valid"),
        }
    }
}

impl ExtensionPlugin for ProfileExtension {
    fn manifest(&self) -> &ExtensionManifest {
        &self.manifest
    }

    fn register(&self, ctx: &mut RegistrationContext) -> Result<(), ExtError> {
        // PreSend hook for field validation.
        ctx.register_hook_json(
            r#"{"id":"profile.validate_fields","phase":"PreSend","priority":25}"#,
        )?;

        // PreSend hook for writer validation.
        ctx.register_hook_json(
            r#"{"id":"profile.validate_writer","phase":"PreSend","priority":20}"#,
        )?;

        // AfterWrite hook for index update notification.
        ctx.register_hook_json(
            r#"{"id":"profile.index_update","phase":"AfterWrite","priority":50}"#,
        )?;

        Ok(())
    }
}

// Generate the C ABI entry point `ezagent_ext_register`.
export_extension!(ProfileExtension);

#[cfg(test)]
mod tests {
    use super::*;

    /// TC-2-EXT13-001: Verify profile writer validation accepts matching signer.
    #[test]
    fn tc_2_ext13_001_valid_profile_writer() {
        hooks::validate_profile_writer(
            "@alice:relay.example.com",
            "@alice:relay.example.com",
        )
        .unwrap();
    }

    /// TC-2-EXT13-002: Verify profile writer validation rejects mismatched signer.
    #[test]
    fn tc_2_ext13_002_invalid_profile_writer() {
        let err = hooks::validate_profile_writer(
            "@alice:relay.example.com",
            "@bob:relay.example.com",
        )
        .unwrap_err();
        assert!(
            matches!(err, hooks::ProfileHookError::WriterMismatch { .. }),
            "expected WriterMismatch error, got: {err}"
        );
    }

    /// TC-2-EXT13-003: Verify valid entity types are accepted.
    #[test]
    fn tc_2_ext13_003_valid_entity_types() {
        assert!(hooks::validate_entity_type("human").is_ok());
        assert!(hooks::validate_entity_type("agent").is_ok());
        assert!(hooks::validate_entity_type("service").is_ok());
    }

    /// TC-2-EXT13-004: Verify invalid entity types are rejected.
    #[test]
    fn tc_2_ext13_004_invalid_entity_types() {
        let err = hooks::validate_entity_type("bot").unwrap_err();
        assert!(
            matches!(err, hooks::ProfileHookError::InvalidEntityType { .. }),
            "expected InvalidEntityType error, got: {err}"
        );

        assert!(hooks::validate_entity_type("").is_err());
        assert!(hooks::validate_entity_type("Human").is_err());
        assert!(hooks::validate_entity_type("AGENT").is_err());
        assert!(hooks::validate_entity_type("robot").is_err());
    }

    /// TC-2-EXT13-005: Verify manifest, datatype, and hook registration.
    #[test]
    fn tc_2_ext13_005_manifest_and_registration() {
        let ext = ProfileExtension::default();
        let m = ext.manifest();

        assert_eq!(m.name, "profile");
        assert_eq!(m.version, "0.1.0");
        assert_eq!(m.api_version, 1);
        assert_eq!(m.datatype_declarations.len(), 1);
        assert_eq!(m.datatype_declarations[0], "entity_profile");
        assert_eq!(m.hook_declarations.len(), 3);
        assert_eq!(m.hook_declarations[0], "profile.validate_fields");
        assert_eq!(m.hook_declarations[1], "profile.validate_writer");
        assert_eq!(m.hook_declarations[2], "profile.index_update");
        assert!(m.ext_dependencies.is_empty());
        assert_eq!(m.uri_paths.len(), 1);
        assert_eq!(m.uri_paths[0].pattern, "/@{entity_id}/profile");

        let mut ctx = RegistrationContext::new();
        ext.register(&mut ctx).expect("register should succeed");
        assert_eq!(ctx.hook_jsons().len(), 3);
        assert!(ctx.datatype_jsons().is_empty());
        assert!(ctx.last_error().is_none());
    }

    /// Verify registered hook JSON contains correct phase and priority.
    #[test]
    fn hook_json_contains_phase_and_priority() {
        let ext = ProfileExtension::default();
        let mut ctx = RegistrationContext::new();
        ext.register(&mut ctx).expect("register should succeed");

        let hooks = ctx.hook_jsons();
        assert_eq!(hooks.len(), 3);

        let fields: serde_json::Value =
            serde_json::from_str(&hooks[0]).expect("validate_fields hook JSON should be valid");
        assert_eq!(fields["id"], "profile.validate_fields");
        assert_eq!(fields["phase"], "PreSend");
        assert_eq!(fields["priority"], 25);

        let writer: serde_json::Value =
            serde_json::from_str(&hooks[1]).expect("validate_writer hook JSON should be valid");
        assert_eq!(writer["id"], "profile.validate_writer");
        assert_eq!(writer["phase"], "PreSend");
        assert_eq!(writer["priority"], 20);

        let index: serde_json::Value =
            serde_json::from_str(&hooks[2]).expect("index_update hook JSON should be valid");
        assert_eq!(index["id"], "profile.index_update");
        assert_eq!(index["phase"], "AfterWrite");
        assert_eq!(index["priority"], 50);
    }

    /// Verify the Rust manifest matches the shipped manifest.toml exactly.
    #[test]
    fn manifest_matches_toml() {
        let from_toml = ExtensionManifest::from_toml(include_str!("../manifest.toml"))
            .expect("manifest.toml should parse");
        let ext = ProfileExtension::default();
        assert_eq!(ext.manifest(), &from_toml);
    }
}
