//! Test-dummy extension for end-to-end integration testing.
//!
//! This is a minimal extension that implements [`ExtensionPlugin`] and uses
//! [`export_extension!`] to generate the C ABI entry point. It does nothing
//! in `register()` — it exists solely to prove the full
//! `dlopen -> dlsym -> call` pipeline works.

use ezagent_ext_api::export_extension;
use ezagent_ext_api::prelude::*;

/// A minimal test extension that does nothing but prove the loading pipeline.
pub struct TestDummyExtension {
    manifest: ExtensionManifest,
}

impl Default for TestDummyExtension {
    fn default() -> Self {
        Self {
            manifest: ExtensionManifest {
                name: "test-dummy".to_string(),
                version: "0.1.0".to_string(),
                api_version: 1,
                datatype_declarations: vec![],
                hook_declarations: vec![],
                ext_dependencies: vec![],
                uri_paths: vec![],
            },
        }
    }
}

impl ExtensionPlugin for TestDummyExtension {
    fn manifest(&self) -> &ExtensionManifest {
        &self.manifest
    }

    fn register(&self, _ctx: &mut RegistrationContext) -> Result<(), ExtError> {
        // Intentionally empty — proves the pipeline works.
        Ok(())
    }
}

// Generate the C ABI entry point `ezagent_ext_register`.
export_extension!(TestDummyExtension);

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_dummy_manifest() {
        let ext = TestDummyExtension::default();
        let m = ext.manifest();
        assert_eq!(m.name, "test-dummy");
        assert_eq!(m.version, "0.1.0");
        assert_eq!(m.api_version, 1);
        assert!(m.datatype_declarations.is_empty());
        assert!(m.hook_declarations.is_empty());
        assert!(m.ext_dependencies.is_empty());
        assert!(m.uri_paths.is_empty());
    }

    #[test]
    fn test_dummy_register_succeeds() {
        let ext = TestDummyExtension::default();
        let mut ctx = RegistrationContext::new();
        ext.register(&mut ctx).expect("register should succeed");
        assert!(ctx.datatype_jsons().is_empty());
        assert!(ctx.hook_jsons().is_empty());
        assert!(ctx.last_error().is_none());
    }
}
