//! EXT-06 Channels extension for EZAgent.
//!
//! Channels allow messages within a Room to be organized into named
//! sub-streams. Each message Ref can carry up to 5 channel tags in
//! `ref.ext.channels` (Y.Array<String>).
//!
//! # Hooks
//!
//! - **`channels.inject_tags`** (PreSend, priority 30) — Validates and
//!   injects channel tags on Ref before writing.
//! - **`channels.update_activity`** (AfterWrite, priority 50) — Updates
//!   the per-channel activity index after a message is written.
//! - **`channels.aggregate`** (AfterRead, priority 50) — Provides a
//!   channel aggregation view when reading.
//!
//! # URI Paths
//!
//! - `/r/{room_id}/c/{channel_name}` — Channel view within a room.
//!
//! # Rules
//!
//! - Channel tags must match `[a-z0-9-]{1,64}`.
//! - A single Ref can have at most 5 tags.
//! - No duplicate tags on a single Ref.

pub mod hooks;

use ezagent_ext_api::export_extension;
use ezagent_ext_api::prelude::*;

/// The Channels extension plugin.
///
/// Implements [`ExtensionPlugin`] to register the `channels.inject_tags`,
/// `channels.update_activity`, and `channels.aggregate` hooks with the
/// Engine.
pub struct ChannelsExtension {
    manifest: ExtensionManifest,
}

impl Default for ChannelsExtension {
    fn default() -> Self {
        Self {
            manifest: ExtensionManifest::from_toml(include_str!("../manifest.toml"))
                .expect("bundled manifest.toml must be valid"),
        }
    }
}

impl ExtensionPlugin for ChannelsExtension {
    fn manifest(&self) -> &ExtensionManifest {
        &self.manifest
    }

    fn register(&self, ctx: &mut RegistrationContext) -> Result<(), ExtError> {
        // PreSend hook for tag validation and injection.
        ctx.register_hook_json(r#"{"id":"channels.inject_tags","phase":"PreSend","priority":30}"#)?;

        // AfterWrite hook for activity index updates.
        ctx.register_hook_json(
            r#"{"id":"channels.update_activity","phase":"AfterWrite","priority":50}"#,
        )?;

        // AfterRead hook for channel aggregation view.
        ctx.register_hook_json(r#"{"id":"channels.aggregate","phase":"AfterRead","priority":50}"#)?;

        Ok(())
    }
}

// Generate the C ABI entry point `ezagent_ext_register`.
export_extension!(ChannelsExtension);

#[cfg(test)]
mod tests {
    use super::*;

    /// TC-2-EXT06-001: Verify channel tag format validation.
    #[test]
    fn tc_2_ext06_001_channel_tag_format() {
        // Valid tags.
        assert!(hooks::validate_channel_tag("general").is_ok());
        assert!(hooks::validate_channel_tag("dev-ops").is_ok());
        assert!(hooks::validate_channel_tag("team-42").is_ok());
        assert!(hooks::validate_channel_tag("a").is_ok());
        assert!(hooks::validate_channel_tag("0").is_ok());

        // 64 chars is the maximum.
        let max_tag = "a".repeat(64);
        assert!(hooks::validate_channel_tag(&max_tag).is_ok());

        // Invalid: uppercase.
        assert!(hooks::validate_channel_tag("General").is_err());

        // Invalid: spaces.
        assert!(hooks::validate_channel_tag("my channel").is_err());

        // Invalid: underscore.
        assert!(hooks::validate_channel_tag("my_channel").is_err());

        // Invalid: empty.
        assert!(hooks::validate_channel_tag("").is_err());

        // Invalid: too long (65 chars).
        let too_long = "a".repeat(65);
        assert!(hooks::validate_channel_tag(&too_long).is_err());
    }

    /// TC-2-EXT06-002: Verify duplicate tag detection.
    #[test]
    fn tc_2_ext06_002_duplicate_tags() {
        let tags = &["general", "dev", "general"];
        let err = hooks::validate_channel_tags(tags).unwrap_err();
        assert!(
            matches!(err, hooks::ChannelHookError::DuplicateTag { .. }),
            "expected DuplicateTag error, got: {err}"
        );
    }

    /// TC-2-EXT06-003: Verify max tag count enforcement.
    #[test]
    fn tc_2_ext06_003_max_tag_count() {
        let tags = &["a", "b", "c", "d", "e"];
        assert!(hooks::validate_channel_tags(tags).is_ok());

        let too_many = &["a", "b", "c", "d", "e", "f"];
        let err = hooks::validate_channel_tags(too_many).unwrap_err();
        assert!(
            matches!(err, hooks::ChannelHookError::TooManyTags { .. }),
            "expected TooManyTags error, got: {err}"
        );
    }

    /// TC-2-EXT06-004: Verify manifest and hook registration.
    #[test]
    fn tc_2_ext06_004_manifest_and_registration() {
        let ext = ChannelsExtension::default();
        let m = ext.manifest();

        assert_eq!(m.name, "channels");
        assert_eq!(m.version, "0.1.0");
        assert_eq!(m.api_version, 1);
        assert!(m.datatype_declarations.is_empty());
        assert_eq!(m.hook_declarations.len(), 3);
        assert_eq!(m.hook_declarations[0], "channels.inject_tags");
        assert_eq!(m.hook_declarations[1], "channels.update_activity");
        assert_eq!(m.hook_declarations[2], "channels.aggregate");
        assert!(m.ext_dependencies.is_empty());
        assert_eq!(m.uri_paths.len(), 1);
        assert_eq!(m.uri_paths[0].pattern, "/r/{room_id}/c/{channel_name}");

        let mut ctx = RegistrationContext::new();
        ext.register(&mut ctx).expect("register should succeed");
        assert_eq!(ctx.hook_jsons().len(), 3);
        assert!(ctx.datatype_jsons().is_empty());
        assert!(ctx.last_error().is_none());
    }

    /// Verify registered hook JSON contains correct phase and priority.
    #[test]
    fn hook_json_contains_phase_and_priority() {
        let ext = ChannelsExtension::default();
        let mut ctx = RegistrationContext::new();
        ext.register(&mut ctx).expect("register should succeed");

        let hooks = ctx.hook_jsons();
        assert_eq!(hooks.len(), 3);

        let inject: serde_json::Value =
            serde_json::from_str(&hooks[0]).expect("inject_tags hook JSON should be valid");
        assert_eq!(inject["id"], "channels.inject_tags");
        assert_eq!(inject["phase"], "PreSend");
        assert_eq!(inject["priority"], 30);

        let update: serde_json::Value =
            serde_json::from_str(&hooks[1]).expect("update_activity hook JSON should be valid");
        assert_eq!(update["id"], "channels.update_activity");
        assert_eq!(update["phase"], "AfterWrite");
        assert_eq!(update["priority"], 50);

        let aggregate: serde_json::Value =
            serde_json::from_str(&hooks[2]).expect("aggregate hook JSON should be valid");
        assert_eq!(aggregate["id"], "channels.aggregate");
        assert_eq!(aggregate["phase"], "AfterRead");
        assert_eq!(aggregate["priority"], 50);
    }

    /// Verify the Rust manifest matches the shipped manifest.toml exactly.
    #[test]
    fn manifest_matches_toml() {
        let from_toml = ExtensionManifest::from_toml(include_str!("../manifest.toml"))
            .expect("manifest.toml should parse");
        let ext = ChannelsExtension::default();
        assert_eq!(ext.manifest(), &from_toml);
    }
}
