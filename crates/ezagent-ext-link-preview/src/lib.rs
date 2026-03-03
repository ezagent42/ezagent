//! EXT-16 Link Preview extension for EZAgent.
//!
//! Link Preview extracts URLs from message text during after_read to
//! annotate Refs with preview metadata. No datatypes are declared —
//! previews are annotations on existing Refs (like reactions).
//!
//! # Hooks
//!
//! - **`link-preview.extract`** (PreSend, priority 25) — Scans message
//!   body for URLs and writes placeholder preview entries.
//! - **`link-preview.fetch`** (AfterWrite, priority 50) — Asynchronously
//!   fetches Open Graph metadata for extracted URLs.
//!
//! # Rules
//!
//! - URLs must start with `http://` or `https://`.
//! - Extraction is best-effort — not a full URL parser.

pub mod hooks;

use ezagent_ext_api::export_extension;
use ezagent_ext_api::prelude::*;

/// The Link Preview extension plugin.
///
/// Implements [`ExtensionPlugin`] to register the `link-preview.extract`
/// and `link-preview.fetch` hooks with the Engine. The extension declares
/// no datatypes — link previews are annotations on existing Refs.
pub struct LinkPreviewExtension {
    manifest: ExtensionManifest,
}

impl Default for LinkPreviewExtension {
    fn default() -> Self {
        Self {
            manifest: ExtensionManifest::from_toml(include_str!("../manifest.toml"))
                .expect("bundled manifest.toml must be valid"),
        }
    }
}

impl ExtensionPlugin for LinkPreviewExtension {
    fn manifest(&self) -> &ExtensionManifest {
        &self.manifest
    }

    fn register(&self, ctx: &mut RegistrationContext) -> Result<(), ExtError> {
        // PreSend hook for URL extraction and placeholder creation.
        ctx.register_hook_json(r#"{"id":"link-preview.extract","phase":"PreSend","priority":25}"#)?;

        // AfterWrite hook for async metadata fetching.
        ctx.register_hook_json(
            r#"{"id":"link-preview.fetch","phase":"AfterWrite","priority":50}"#,
        )?;

        Ok(())
    }
}

// Generate the C ABI entry point `ezagent_ext_register`.
export_extension!(LinkPreviewExtension);

#[cfg(test)]
mod tests {
    use super::*;

    /// TC-2-EXT16-001: Verify basic URL extraction.
    #[test]
    fn tc_2_ext16_001_basic_url_extraction() {
        let urls = hooks::extract_urls("Check out https://example.com for details");
        assert_eq!(urls, vec!["https://example.com"]);

        let urls = hooks::extract_urls("Visit http://example.org/page?q=1 now");
        assert_eq!(urls, vec!["http://example.org/page?q=1"]);
    }

    /// TC-2-EXT16-002: Verify multiple URL extraction.
    #[test]
    fn tc_2_ext16_002_multiple_urls() {
        let urls =
            hooks::extract_urls("See https://example.com and http://other.org/path for more");
        assert_eq!(urls, vec!["https://example.com", "http://other.org/path"]);
    }

    /// TC-2-EXT16-003: Verify edge cases.
    #[test]
    fn tc_2_ext16_003_edge_cases() {
        // No URLs.
        let urls = hooks::extract_urls("Hello, world!");
        assert!(urls.is_empty());

        // Empty string.
        let urls = hooks::extract_urls("");
        assert!(urls.is_empty());

        // URL at start.
        let urls = hooks::extract_urls("https://example.com is great");
        assert_eq!(urls, vec!["https://example.com"]);

        // URL at end.
        let urls = hooks::extract_urls("Visit https://example.com");
        assert_eq!(urls, vec!["https://example.com"]);

        // FTP should not match (not http/https).
        let urls = hooks::extract_urls("Download from ftp://files.example.com");
        assert!(urls.is_empty());
    }

    /// TC-2-EXT16-004: Verify manifest and hook registration.
    #[test]
    fn tc_2_ext16_004_manifest_and_registration() {
        let ext = LinkPreviewExtension::default();
        let m = ext.manifest();

        assert_eq!(m.name, "link-preview");
        assert_eq!(m.version, "0.1.0");
        assert_eq!(m.api_version, 1);
        assert!(m.datatype_declarations.is_empty());
        assert_eq!(m.hook_declarations.len(), 2);
        assert_eq!(m.hook_declarations[0], "link-preview.extract");
        assert_eq!(m.hook_declarations[1], "link-preview.fetch");
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
        let ext = LinkPreviewExtension::default();
        let mut ctx = RegistrationContext::new();
        ext.register(&mut ctx).expect("register should succeed");

        let hooks = ctx.hook_jsons();
        assert_eq!(hooks.len(), 2);

        let extract: serde_json::Value =
            serde_json::from_str(&hooks[0]).expect("extract hook JSON should be valid");
        assert_eq!(extract["id"], "link-preview.extract");
        assert_eq!(extract["phase"], "PreSend");
        assert_eq!(extract["priority"], 25);

        let fetch: serde_json::Value =
            serde_json::from_str(&hooks[1]).expect("fetch hook JSON should be valid");
        assert_eq!(fetch["id"], "link-preview.fetch");
        assert_eq!(fetch["phase"], "AfterWrite");
        assert_eq!(fetch["priority"], 50);
    }

    /// Verify the Rust manifest matches the shipped manifest.toml exactly.
    #[test]
    fn manifest_matches_toml() {
        let from_toml = ExtensionManifest::from_toml(include_str!("../manifest.toml"))
            .expect("manifest.toml should parse");
        let ext = LinkPreviewExtension::default();
        assert_eq!(ext.manifest(), &from_toml);
    }
}
