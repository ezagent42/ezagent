//! EXT-11 Threads extension for EZAgent.
//!
//! Provides thread sub-conversations within a room's timeline. Each
//! thread is rooted at an existing Ref, and replies within the thread
//! carry `ext.thread = { root }` to link back to the root message.
//!
//! # Hooks
//!
//! - **`threads.inject`** (PreSend, priority 30) — Injects
//!   `ext.thread = { root }` on the outgoing Ref.
//! - **`threads.filter`** (AfterRead, priority 50) — Filters the
//!   timeline view to show only messages in a specific thread.
//!
//! # URI Paths
//!
//! - `/r/{room_id}/m/{ref_id}/thread` — Thread sub-conversation view.
//!
//! # Dependencies
//!
//! - `reply-to` — EXT-04 Reply To.

pub mod hooks;

use ezagent_ext_api::export_extension;
use ezagent_ext_api::prelude::*;

/// The Threads extension plugin.
///
/// Implements [`ExtensionPlugin`] to register the `threads.inject`
/// and `threads.filter` hooks with the Engine. Declares no datatypes
/// — thread annotations are stored in the Ref's `ext` namespace.
pub struct ThreadsExtension {
    manifest: ExtensionManifest,
}

impl Default for ThreadsExtension {
    fn default() -> Self {
        Self {
            manifest: ExtensionManifest::from_toml(include_str!("../manifest.toml"))
                .expect("bundled manifest.toml must be valid"),
        }
    }
}

impl ExtensionPlugin for ThreadsExtension {
    fn manifest(&self) -> &ExtensionManifest {
        &self.manifest
    }

    fn register(&self, ctx: &mut RegistrationContext) -> Result<(), ExtError> {
        // PreSend hook for injecting thread annotation.
        ctx.register_hook_json(r#"{"id":"threads.inject","phase":"PreSend","priority":30}"#)?;

        // AfterRead hook for filtering thread view.
        ctx.register_hook_json(r#"{"id":"threads.filter","phase":"AfterRead","priority":50}"#)?;

        Ok(())
    }
}

// Generate the C ABI entry point `ezagent_ext_register`.
export_extension!(ThreadsExtension);

#[cfg(test)]
mod tests {
    use super::*;

    /// TC-2-EXT11-001: Verify valid thread root is accepted.
    #[test]
    fn tc_2_ext11_001_valid_thread_root() {
        hooks::validate_thread_root("ref-001").unwrap();
    }

    /// TC-2-EXT11-002: Verify empty thread root is rejected.
    #[test]
    fn tc_2_ext11_002_empty_thread_root() {
        let err = hooks::validate_thread_root("").unwrap_err();
        assert!(
            matches!(err, hooks::ThreadHookError::EmptyRootId),
            "expected EmptyRootId error, got: {err}"
        );
    }

    /// TC-2-EXT11-003: Verify URI path is declared.
    #[test]
    fn tc_2_ext11_003_uri_path() {
        let ext = ThreadsExtension::default();
        let m = ext.manifest();

        assert_eq!(m.uri_paths.len(), 1);
        assert_eq!(m.uri_paths[0].pattern, "/r/{room_id}/m/{ref_id}/thread");
        assert_eq!(m.uri_paths[0].description, "Thread sub-conversation view");
    }

    /// TC-2-EXT11-004: Verify manifest and hook registration.
    #[test]
    fn tc_2_ext11_004_manifest_and_registration() {
        let ext = ThreadsExtension::default();
        let m = ext.manifest();

        assert_eq!(m.name, "threads");
        assert_eq!(m.version, "0.1.0");
        assert_eq!(m.api_version, 1);
        assert!(m.datatype_declarations.is_empty());
        assert_eq!(m.hook_declarations.len(), 2);
        assert_eq!(m.hook_declarations[0], "threads.inject");
        assert_eq!(m.hook_declarations[1], "threads.filter");
        assert_eq!(m.ext_dependencies.len(), 1);
        assert_eq!(m.ext_dependencies[0], "reply-to");

        let mut ctx = RegistrationContext::new();
        ext.register(&mut ctx).expect("register should succeed");
        assert_eq!(ctx.hook_jsons().len(), 2);
        assert!(ctx.datatype_jsons().is_empty());
        assert!(ctx.last_error().is_none());
    }

    /// Verify registered hook JSON contains correct phase and priority.
    #[test]
    fn hook_json_contains_phase_and_priority() {
        let ext = ThreadsExtension::default();
        let mut ctx = RegistrationContext::new();
        ext.register(&mut ctx).expect("register should succeed");

        let hooks = ctx.hook_jsons();
        assert_eq!(hooks.len(), 2);

        let inject: serde_json::Value =
            serde_json::from_str(&hooks[0]).expect("inject hook JSON should be valid");
        assert_eq!(inject["id"], "threads.inject");
        assert_eq!(inject["phase"], "PreSend");
        assert_eq!(inject["priority"], 30);

        let filter: serde_json::Value =
            serde_json::from_str(&hooks[1]).expect("filter hook JSON should be valid");
        assert_eq!(filter["id"], "threads.filter");
        assert_eq!(filter["phase"], "AfterRead");
        assert_eq!(filter["priority"], 50);
    }

    /// Verify the Rust manifest matches the shipped manifest.toml exactly.
    #[test]
    fn manifest_matches_toml() {
        let from_toml = ExtensionManifest::from_toml(include_str!("../manifest.toml"))
            .expect("manifest.toml should parse");
        let ext = ThreadsExtension::default();
        assert_eq!(ext.manifest(), &from_toml);
    }
}
