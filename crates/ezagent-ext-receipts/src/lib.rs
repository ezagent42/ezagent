//! EXT-08 Read Receipts extension for EZAgent.
//!
//! Read Receipts track per-entity read positions in a room's timeline.
//! Each entity can only update its own read receipt — the receipt key
//! must match the signer's entity_id.
//!
//! # Hooks
//!
//! - **`receipts.auto_mark`** (AfterRead, priority 70) — Automatically
//!   updates the read position when a user views messages.
//! - **`receipts.update_unread`** (AfterWrite, priority 50) — Updates
//!   unread counts after new messages are written.
//!
//! # Datatypes
//!
//! - `read_receipts` — Per-entity read position tracking.
//!
//! # Rules
//!
//! - The receipt key's entity_id must match the signer.

pub mod hooks;

use ezagent_ext_api::export_extension;
use ezagent_ext_api::prelude::*;

/// The Read Receipts extension plugin.
///
/// Implements [`ExtensionPlugin`] to register the `receipts.auto_mark`
/// and `receipts.update_unread` hooks with the Engine.
pub struct ReceiptsExtension {
    manifest: ExtensionManifest,
}

impl Default for ReceiptsExtension {
    fn default() -> Self {
        Self {
            manifest: ExtensionManifest::from_toml(include_str!("../manifest.toml"))
                .expect("bundled manifest.toml must be valid"),
        }
    }
}

impl ExtensionPlugin for ReceiptsExtension {
    fn manifest(&self) -> &ExtensionManifest {
        &self.manifest
    }

    fn register(&self, ctx: &mut RegistrationContext) -> Result<(), ExtError> {
        // AfterRead hook for auto-marking read position.
        ctx.register_hook_json(
            r#"{"id":"receipts.auto_mark","phase":"AfterRead","priority":70}"#,
        )?;

        // AfterWrite hook for updating unread counts.
        ctx.register_hook_json(
            r#"{"id":"receipts.update_unread","phase":"AfterWrite","priority":50}"#,
        )?;

        Ok(())
    }
}

// Generate the C ABI entry point `ezagent_ext_register`.
export_extension!(ReceiptsExtension);

#[cfg(test)]
mod tests {
    use super::*;

    /// TC-2-EXT08-001: Verify receipt writer validation accepts matching signer.
    #[test]
    fn tc_2_ext08_001_valid_receipt_writer() {
        hooks::validate_receipt_writer(
            "@alice:relay.example.com",
            "@alice:relay.example.com",
        )
        .unwrap();
    }

    /// TC-2-EXT08-002: Verify receipt writer validation rejects mismatched signer.
    #[test]
    fn tc_2_ext08_002_invalid_receipt_writer() {
        let err = hooks::validate_receipt_writer(
            "@alice:relay.example.com",
            "@bob:relay.example.com",
        )
        .unwrap_err();
        assert!(
            matches!(err, hooks::ReceiptHookError::WriterMismatch { .. }),
            "expected WriterMismatch error, got: {err}"
        );
    }

    /// TC-2-EXT08-003: Verify manifest, datatype, and hook registration.
    #[test]
    fn tc_2_ext08_003_manifest_and_registration() {
        let ext = ReceiptsExtension::default();
        let m = ext.manifest();

        assert_eq!(m.name, "read-receipts");
        assert_eq!(m.version, "0.1.0");
        assert_eq!(m.api_version, 1);
        assert_eq!(m.datatype_declarations.len(), 1);
        assert_eq!(m.datatype_declarations[0], "read_receipts");
        assert_eq!(m.hook_declarations.len(), 2);
        assert_eq!(m.hook_declarations[0], "receipts.auto_mark");
        assert_eq!(m.hook_declarations[1], "receipts.update_unread");
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
        let ext = ReceiptsExtension::default();
        let mut ctx = RegistrationContext::new();
        ext.register(&mut ctx).expect("register should succeed");

        let hooks = ctx.hook_jsons();
        assert_eq!(hooks.len(), 2);

        let auto_mark: serde_json::Value =
            serde_json::from_str(&hooks[0]).expect("auto_mark hook JSON should be valid");
        assert_eq!(auto_mark["id"], "receipts.auto_mark");
        assert_eq!(auto_mark["phase"], "AfterRead");
        assert_eq!(auto_mark["priority"], 70);

        let update_unread: serde_json::Value =
            serde_json::from_str(&hooks[1]).expect("update_unread hook JSON should be valid");
        assert_eq!(update_unread["id"], "receipts.update_unread");
        assert_eq!(update_unread["phase"], "AfterWrite");
        assert_eq!(update_unread["priority"], 50);
    }

    /// Verify the Rust manifest matches the shipped manifest.toml exactly.
    #[test]
    fn manifest_matches_toml() {
        let from_toml = ExtensionManifest::from_toml(include_str!("../manifest.toml"))
            .expect("manifest.toml should parse");
        let ext = ReceiptsExtension::default();
        assert_eq!(ext.manifest(), &from_toml);
    }
}
