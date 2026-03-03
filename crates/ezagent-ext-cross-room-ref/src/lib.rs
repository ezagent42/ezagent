//! EXT-05 Cross-Room Ref extension for EZAgent.
//!
//! Extends the reply-to mechanism to support references across
//! different rooms. When a user replies to a message in another
//! room, this extension resolves a preview of the target content.
//!
//! # Hooks
//!
//! - **`cross_room.resolve_preview`** (AfterRead, priority 45) —
//!   Resolves a preview for the cross-room reference target.
//!
//! # Dependencies
//!
//! - `reply-to` — EXT-04 Reply To.
//! - `room` — Built-in room entity.

pub mod hooks;

use ezagent_ext_api::export_extension;
use ezagent_ext_api::prelude::*;

/// The Cross-Room Ref extension plugin.
///
/// Implements [`ExtensionPlugin`] to register the
/// `cross_room.resolve_preview` hook with the Engine. Declares no
/// datatypes — cross-room references are annotations on Refs.
pub struct CrossRoomRefExtension {
    manifest: ExtensionManifest,
}

impl Default for CrossRoomRefExtension {
    fn default() -> Self {
        Self {
            manifest: ExtensionManifest::from_toml(include_str!("../manifest.toml"))
                .expect("bundled manifest.toml must be valid"),
        }
    }
}

impl ExtensionPlugin for CrossRoomRefExtension {
    fn manifest(&self) -> &ExtensionManifest {
        &self.manifest
    }

    fn register(&self, ctx: &mut RegistrationContext) -> Result<(), ExtError> {
        // AfterRead hook for resolving cross-room previews.
        ctx.register_hook_json(
            r#"{"id":"cross_room.resolve_preview","phase":"AfterRead","priority":45}"#,
        )?;

        Ok(())
    }
}

// Generate the C ABI entry point `ezagent_ext_register`.
export_extension!(CrossRoomRefExtension);

#[cfg(test)]
mod tests {
    use super::*;

    /// TC-2-EXT05-001: Verify valid cross-room reference is accepted.
    #[test]
    fn tc_2_ext05_001_valid_cross_room_ref() {
        hooks::validate_cross_room_ref("ref-001", "room-alpha").unwrap();
    }

    /// TC-2-EXT05-002: Verify empty ref_id is rejected.
    #[test]
    fn tc_2_ext05_002_empty_ref_id() {
        let err = hooks::validate_cross_room_ref("", "room-alpha").unwrap_err();
        assert!(
            matches!(err, hooks::CrossRoomHookError::EmptyRefId),
            "expected EmptyRefId error, got: {err}"
        );
    }

    /// TC-2-EXT05-003: Verify empty room_id is rejected.
    #[test]
    fn tc_2_ext05_003_empty_room_id() {
        let err = hooks::validate_cross_room_ref("ref-001", "").unwrap_err();
        assert!(
            matches!(err, hooks::CrossRoomHookError::EmptyRoomId),
            "expected EmptyRoomId error, got: {err}"
        );
    }

    /// TC-2-EXT05-004: Verify manifest and hook registration.
    #[test]
    fn tc_2_ext05_004_manifest_and_registration() {
        let ext = CrossRoomRefExtension::default();
        let m = ext.manifest();

        assert_eq!(m.name, "cross-room-ref");
        assert_eq!(m.version, "0.1.0");
        assert_eq!(m.api_version, 1);
        assert!(m.datatype_declarations.is_empty());
        assert_eq!(m.hook_declarations.len(), 1);
        assert_eq!(m.hook_declarations[0], "cross_room.resolve_preview");
        assert_eq!(m.ext_dependencies.len(), 2);
        assert_eq!(m.ext_dependencies[0], "reply-to");
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
        let ext = CrossRoomRefExtension::default();
        let mut ctx = RegistrationContext::new();
        ext.register(&mut ctx).expect("register should succeed");

        let hooks = ctx.hook_jsons();
        assert_eq!(hooks.len(), 1);

        let resolve: serde_json::Value =
            serde_json::from_str(&hooks[0]).expect("resolve_preview hook JSON should be valid");
        assert_eq!(resolve["id"], "cross_room.resolve_preview");
        assert_eq!(resolve["phase"], "AfterRead");
        assert_eq!(resolve["priority"], 45);
    }

    /// Verify the Rust manifest matches the shipped manifest.toml exactly.
    #[test]
    fn manifest_matches_toml() {
        let from_toml = ExtensionManifest::from_toml(include_str!("../manifest.toml"))
            .expect("manifest.toml should parse");
        let ext = CrossRoomRefExtension::default();
        assert_eq!(ext.manifest(), &from_toml);
    }
}
