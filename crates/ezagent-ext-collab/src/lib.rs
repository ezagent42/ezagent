//! EXT-02 Collab extension for EZAgent.
//!
//! Provides collaborative content with ACL (Access Control List)
//! support. Builds on top of Mutable Content (EXT-01) to add
//! multi-writer editing with permission management.
//!
//! # Hooks
//!
//! - **`collab.check_acl`** (PreSend, priority 25) — Validates write
//!   permission based on the document's ACL mode.
//!
//! # Datatypes
//!
//! - `collab_acl` — Access control list for collaborative documents.
//!
//! # ACL Modes
//!
//! - `owner_only` — Only the document owner can write.
//! - `explicit` — Owner plus explicitly listed editors can write.
//! - `room_members` — All room members can write.
//!
//! # Dependencies
//!
//! - `mutable` — EXT-01 Mutable Content.
//! - `room` — Built-in room entity.

pub mod hooks;

use ezagent_ext_api::export_extension;
use ezagent_ext_api::prelude::*;

/// The Collab extension plugin.
///
/// Implements [`ExtensionPlugin`] to register the `collab.check_acl`
/// hook with the Engine. Declares the `collab_acl` datatype for
/// storing access control lists.
pub struct CollabExtension {
    manifest: ExtensionManifest,
}

impl Default for CollabExtension {
    fn default() -> Self {
        Self {
            manifest: ExtensionManifest::from_toml(include_str!("../manifest.toml"))
                .expect("bundled manifest.toml must be valid"),
        }
    }
}

impl ExtensionPlugin for CollabExtension {
    fn manifest(&self) -> &ExtensionManifest {
        &self.manifest
    }

    fn register(&self, ctx: &mut RegistrationContext) -> Result<(), ExtError> {
        // PreSend hook for ACL validation.
        ctx.register_hook_json(
            r#"{"id":"collab.check_acl","phase":"PreSend","priority":25}"#,
        )?;

        Ok(())
    }
}

// Generate the C ABI entry point `ezagent_ext_register`.
export_extension!(CollabExtension);

#[cfg(test)]
mod tests {
    use super::*;

    /// TC-2-EXT02-001: Verify owner can write in owner_only mode.
    #[test]
    fn tc_2_ext02_001_owner_can_write() {
        hooks::validate_acl_owner(
            "@alice:relay.example.com",
            "@alice:relay.example.com",
        )
        .unwrap();
    }

    /// TC-2-EXT02-002: Verify non-owner is rejected in owner_only mode.
    #[test]
    fn tc_2_ext02_002_non_owner_rejected() {
        let err = hooks::validate_acl_owner(
            "@alice:relay.example.com",
            "@bob:relay.example.com",
        )
        .unwrap_err();
        assert!(
            matches!(err, hooks::CollabHookError::NotOwner { .. }),
            "expected NotOwner error, got: {err}"
        );
    }

    /// TC-2-EXT02-003: Verify ACL mode validation.
    #[test]
    fn tc_2_ext02_003_acl_modes() {
        hooks::validate_acl_mode("owner_only").unwrap();
        hooks::validate_acl_mode("explicit").unwrap();
        hooks::validate_acl_mode("room_members").unwrap();

        let err = hooks::validate_acl_mode("public").unwrap_err();
        assert!(
            matches!(err, hooks::CollabHookError::InvalidAclMode { .. }),
            "expected InvalidAclMode error, got: {err}"
        );
    }

    /// TC-2-EXT02-004: Verify ACL upgrade path.
    #[test]
    fn tc_2_ext02_004_acl_upgrade_path() {
        // Valid upgrades.
        hooks::validate_acl_upgrade("owner_only", "explicit").unwrap();
        hooks::validate_acl_upgrade("explicit", "room_members").unwrap();
        hooks::validate_acl_upgrade("owner_only", "room_members").unwrap();

        // Same mode is allowed.
        hooks::validate_acl_upgrade("explicit", "explicit").unwrap();

        // Downgrades are rejected.
        assert!(hooks::validate_acl_upgrade("room_members", "explicit").is_err());
        assert!(hooks::validate_acl_upgrade("explicit", "owner_only").is_err());
    }

    /// TC-2-EXT02-005: Verify collab_acl datatype is declared.
    #[test]
    fn tc_2_ext02_005_datatype_declared() {
        let ext = CollabExtension::default();
        let m = ext.manifest();

        assert_eq!(m.datatype_declarations.len(), 1);
        assert_eq!(m.datatype_declarations[0], "collab_acl");
    }

    /// TC-2-EXT02-006: Verify manifest and hook registration.
    #[test]
    fn tc_2_ext02_006_manifest_and_registration() {
        let ext = CollabExtension::default();
        let m = ext.manifest();

        assert_eq!(m.name, "collab");
        assert_eq!(m.version, "0.1.0");
        assert_eq!(m.api_version, 1);
        assert_eq!(m.hook_declarations.len(), 1);
        assert_eq!(m.hook_declarations[0], "collab.check_acl");
        assert_eq!(m.ext_dependencies.len(), 2);
        assert_eq!(m.ext_dependencies[0], "mutable");
        assert_eq!(m.ext_dependencies[1], "room");
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
        let ext = CollabExtension::default();
        let mut ctx = RegistrationContext::new();
        ext.register(&mut ctx).expect("register should succeed");

        let hooks = ctx.hook_jsons();
        assert_eq!(hooks.len(), 1);

        let check_acl: serde_json::Value =
            serde_json::from_str(&hooks[0]).expect("check_acl hook JSON should be valid");
        assert_eq!(check_acl["id"], "collab.check_acl");
        assert_eq!(check_acl["phase"], "PreSend");
        assert_eq!(check_acl["priority"], 25);
    }

    /// Verify the Rust manifest matches the shipped manifest.toml exactly.
    #[test]
    fn manifest_matches_toml() {
        let from_toml = ExtensionManifest::from_toml(include_str!("../manifest.toml"))
            .expect("manifest.toml should parse");
        let ext = CollabExtension::default();
        assert_eq!(ext.manifest(), &from_toml);
    }
}
