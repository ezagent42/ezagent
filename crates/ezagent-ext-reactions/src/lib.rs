//! EXT-03 Reactions extension for EZAgent.
//!
//! Reactions allow entities to add emoji reactions to timeline Refs.
//! Each reaction is stored as an annotation on the Ref at
//! `ref.ext.reactions` (Y.Map) with keys in the format
//! `{emoji}:{entity_id}` and values as Unix milliseconds (i64).
//!
//! # Hooks
//!
//! - **`reactions.inject`** (PreSend, priority 30) — Validates reaction key
//!   format and signer authorization before writing.
//! - **`reactions.emit`** (AfterWrite, priority 40) — Emits
//!   `reaction.added` or `reaction.removed` events after a reaction is
//!   written.
//!
//! # URI Paths
//!
//! - `/r/{room_id}/m/{ref_id}/reactions` — Reaction list for a message.
//!
//! # Rules
//!
//! - Each entity can only have one reaction per emoji per ref.
//! - The entity_id in the reaction key MUST match the signer.
//! - Entities cannot remove another's reaction (except via Moderation).
//! - Reactions are unsigned — they do not affect Ref Bus signatures.

pub mod hooks;

use ezagent_ext_api::export_extension;
use ezagent_ext_api::prelude::*;

/// The Reactions extension plugin.
///
/// Implements [`ExtensionPlugin`] to register the `reactions.inject` and
/// `reactions.emit` hooks with the Engine. The extension declares no
/// datatypes of its own — reactions are annotations on existing Refs.
pub struct ReactionsExtension {
    manifest: ExtensionManifest,
}

impl Default for ReactionsExtension {
    fn default() -> Self {
        Self {
            manifest: ExtensionManifest::from_toml(include_str!("../manifest.toml"))
                .expect("bundled manifest.toml must be valid"),
        }
    }
}

impl ExtensionPlugin for ReactionsExtension {
    fn manifest(&self) -> &ExtensionManifest {
        &self.manifest
    }

    fn register(&self, ctx: &mut RegistrationContext) -> Result<(), ExtError> {
        // Register the PreSend hook for validation and injection.
        ctx.register_hook_json(
            r#"{"id":"reactions.inject","phase":"PreSend","priority":30}"#,
        )?;

        // Register the AfterWrite hook for event emission.
        ctx.register_hook_json(
            r#"{"id":"reactions.emit","phase":"AfterWrite","priority":40}"#,
        )?;

        Ok(())
    }
}

// Generate the C ABI entry point `ezagent_ext_register`.
export_extension!(ReactionsExtension);

#[cfg(test)]
mod tests {
    use super::*;

    /// TC-2-EXT03-001: Create extension and verify hook registration.
    ///
    /// Creates the ReactionsExtension, registers it, and verifies that
    /// exactly 2 hooks are registered with the correct manifest metadata.
    #[test]
    fn tc_2_ext03_001_add_reaction_extension() {
        let ext = ReactionsExtension::default();
        let m = ext.manifest();

        // Verify manifest metadata.
        assert_eq!(m.name, "reactions");
        assert_eq!(m.version, "0.1.0");
        assert_eq!(m.api_version, 1);

        // Verify hook declarations.
        assert_eq!(m.hook_declarations.len(), 2);
        assert_eq!(m.hook_declarations[0], "reactions.inject");
        assert_eq!(m.hook_declarations[1], "reactions.emit");

        // Verify URI paths.
        assert_eq!(m.uri_paths.len(), 1);
        assert_eq!(
            m.uri_paths[0].pattern,
            "/r/{room_id}/m/{ref_id}/reactions"
        );
        assert_eq!(m.uri_paths[0].description, "Reaction list for a message");

        // Verify registration succeeds and registers 2 hooks.
        let mut ctx = RegistrationContext::new();
        ext.register(&mut ctx).expect("register should succeed");
        assert_eq!(ctx.hook_jsons().len(), 2);
        assert!(ctx.datatype_jsons().is_empty());
        assert!(ctx.last_error().is_none());
    }

    /// TC-2-EXT03-002: Validate reaction key parsing.
    ///
    /// Tests `parse_reaction_key` with a valid key like
    /// `"👍:@bob:relay-a.example.com"` and verifies the emoji and
    /// entity_id are correctly extracted.
    #[test]
    fn tc_2_ext03_002_validate_reaction_key_parsing() {
        let (emoji, entity_id) =
            hooks::parse_reaction_key("👍:@bob:relay-a.example.com").unwrap();
        assert_eq!(emoji, "👍");
        assert_eq!(entity_id, "@bob:relay-a.example.com");

        // Additional valid key patterns.
        let (emoji, entity_id) =
            hooks::parse_reaction_key("❤️:@alice:relay.example.com").unwrap();
        assert_eq!(emoji, "❤️");
        assert_eq!(entity_id, "@alice:relay.example.com");
    }

    /// TC-2-EXT03-003: Cannot remove another's reaction.
    ///
    /// Tests `validate_reaction_signer` rejects when signer != entity_id
    /// in the reaction key.
    #[test]
    fn tc_2_ext03_003_cannot_remove_others_reaction() {
        // Bob's reaction key, but Alice is the signer — should be rejected.
        let err = hooks::validate_reaction_signer(
            "👍:@bob:relay-a.example.com",
            "@alice:relay-a.example.com",
        )
        .unwrap_err();
        assert!(
            matches!(err, hooks::ReactionHookError::SignerMismatch { .. }),
            "expected SignerMismatch error, got: {err}"
        );

        // Bob's reaction key with Bob as signer — should succeed.
        hooks::validate_reaction_signer(
            "👍:@bob:relay-a.example.com",
            "@bob:relay-a.example.com",
        )
        .unwrap();
    }

    /// TC-2-EXT03-004: Reactions don't affect Bus signature.
    ///
    /// Verifies that:
    /// 1. The manifest declares no datatype declarations (reactions are
    ///    annotations on existing Refs, not standalone datatypes).
    /// 2. The registered hooks don't include any signature-related hooks.
    /// 3. No ext_dependencies are declared (timeline is built-in).
    #[test]
    fn tc_2_ext03_004_reactions_unsigned() {
        let ext = ReactionsExtension::default();
        let m = ext.manifest();

        // No datatype declarations — reactions are annotations, not datatypes.
        assert!(
            m.datatype_declarations.is_empty(),
            "reactions should declare no datatypes"
        );

        // No ext_dependencies — timeline is built-in, not an extension.
        assert!(
            m.ext_dependencies.is_empty(),
            "reactions should have no extension dependencies"
        );

        // Register and verify no signature-related hooks.
        let mut ctx = RegistrationContext::new();
        ext.register(&mut ctx).expect("register should succeed");

        // Verify no datatype registrations.
        assert!(
            ctx.datatype_jsons().is_empty(),
            "reactions should register no datatypes"
        );

        // Verify hook JSONs don't reference signing.
        for hook_json in ctx.hook_jsons() {
            let parsed: serde_json::Value =
                serde_json::from_str(hook_json).expect("hook JSON should be valid");
            let id = parsed["id"].as_str().unwrap_or_default();
            assert!(
                !id.contains("sign"),
                "reactions hooks should not involve signing: {id}"
            );
        }
    }

    /// Verify registered hook JSON contains correct phase and priority.
    #[test]
    fn hook_json_contains_phase_and_priority() {
        let ext = ReactionsExtension::default();
        let mut ctx = RegistrationContext::new();
        ext.register(&mut ctx).expect("register should succeed");

        let hooks = ctx.hook_jsons();
        assert_eq!(hooks.len(), 2);

        // Verify reactions.inject hook.
        let inject: serde_json::Value =
            serde_json::from_str(&hooks[0]).expect("inject hook JSON should be valid");
        assert_eq!(inject["id"], "reactions.inject");
        assert_eq!(inject["phase"], "PreSend");
        assert_eq!(inject["priority"], 30);

        // Verify reactions.emit hook.
        let emit: serde_json::Value =
            serde_json::from_str(&hooks[1]).expect("emit hook JSON should be valid");
        assert_eq!(emit["id"], "reactions.emit");
        assert_eq!(emit["phase"], "AfterWrite");
        assert_eq!(emit["priority"], 40);
    }

    /// Verify the Rust manifest matches the shipped manifest.toml exactly.
    #[test]
    fn manifest_matches_toml() {
        let from_toml = ExtensionManifest::from_toml(include_str!("../manifest.toml"))
            .expect("manifest.toml should parse");
        let ext = ReactionsExtension::default();
        assert_eq!(ext.manifest(), &from_toml);
    }
}
