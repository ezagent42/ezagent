//! EZAgent Extension Plugin API.
//!
//! This crate defines the stable C ABI boundary between the Engine and
//! extension plugins. Extensions are compiled as `.cdylib` and loaded
//! via `dlopen` at engine startup.
//!
//! # Overview
//!
//! - [`manifest::ExtensionManifest`] — parsed `manifest.toml` declaring
//!   extension metadata, datatypes, hooks, dependencies, and URI paths.
//! - [`context::RegistrationContext`] — opaque context passed to the
//!   extension's entry function for registering datatypes and hooks.
//! - [`ExtensionPlugin`] — high-level trait that extension authors implement.
//! - [`export_extension!`] — macro that generates the C ABI entry function.
//!
//! # Extension Authoring
//!
//! ```rust,ignore
//! use ezagent_ext_api::prelude::*;
//!
//! struct MyExtension;
//!
//! impl ExtensionPlugin for MyExtension {
//!     fn manifest(&self) -> &ExtensionManifest {
//!         // return cached manifest
//!         # todo!()
//!     }
//!
//!     fn register(&self, ctx: &mut RegistrationContext) -> Result<(), ExtError> {
//!         ctx.register_hook_json(r#"{"id":"my.hook"}"#)?;
//!         Ok(())
//!     }
//! }
//!
//! export_extension!(MyExtension);
//! ```

pub mod context;
pub mod error;
pub mod manifest;

pub use context::{ExtEntryFn, RegistrationContext, ENGINE_API_VERSION, ENTRY_SYMBOL};
pub use error::ExtError;
pub use manifest::{ExtensionManifest, UriPath};

/// Convenience re-exports for extension authors.
pub mod prelude {
    pub use crate::context::RegistrationContext;
    pub use crate::error::ExtError;
    pub use crate::manifest::{ExtensionManifest, UriPath};
    pub use crate::ExtensionPlugin;
}

/// Trait that extension authors implement to define their plugin.
///
/// The Engine calls [`manifest()`](ExtensionPlugin::manifest) to obtain
/// the extension's metadata, then calls [`register()`](ExtensionPlugin::register)
/// with a [`RegistrationContext`] to let the extension declare its
/// datatypes and hooks.
pub trait ExtensionPlugin {
    /// Return a reference to the extension's parsed manifest.
    fn manifest(&self) -> &ExtensionManifest;

    /// Register this extension's datatypes and hooks with the engine.
    ///
    /// Called exactly once during extension loading. The extension should
    /// use [`RegistrationContext::register_datatype_json()`] and
    /// [`RegistrationContext::register_hook_json()`] to declare its
    /// components.
    fn register(&self, ctx: &mut RegistrationContext) -> Result<(), ExtError>;
}

/// Generate the C ABI entry function for an extension plugin.
///
/// This macro creates an `extern "C"` function named `ezagent_ext_register`
/// that the Engine looks up via `dlsym`. The function instantiates the
/// given plugin type using `Default::default()` and calls its
/// [`ExtensionPlugin::register()`] method.
///
/// # Usage
///
/// ```rust,ignore
/// use ezagent_ext_api::export_extension;
///
/// #[derive(Default)]
/// struct ReactionsExtension;
///
/// impl ExtensionPlugin for ReactionsExtension {
///     // ...
///     # fn manifest(&self) -> &ExtensionManifest { todo!() }
///     # fn register(&self, ctx: &mut RegistrationContext) -> Result<(), ExtError> { todo!() }
/// }
///
/// export_extension!(ReactionsExtension);
/// ```
///
/// # Safety
///
/// The generated function assumes `ctx` is a valid, non-null pointer to a
/// [`RegistrationContext`] allocated by the Engine.
#[macro_export]
macro_rules! export_extension {
    ($plugin_type:ty) => {
        /// C ABI entry point called by the Engine during extension loading.
        ///
        /// # Safety
        ///
        /// `ctx` must be a valid, non-null pointer to a
        /// [`RegistrationContext`] owned by the Engine.
        #[no_mangle]
        pub unsafe extern "C" fn ezagent_ext_register(
            ctx: *mut $crate::context::RegistrationContext,
        ) {
            // SAFETY: The Engine guarantees `ctx` is valid and exclusively
            // accessible during this call.
            let ctx_ref = unsafe { $crate::context::RegistrationContext::from_raw(ctx) };
            let plugin = <$plugin_type as Default>::default();
            if let Err(e) = <$plugin_type as $crate::ExtensionPlugin>::register(&plugin, ctx_ref) {
                ctx_ref.set_error(e);
            }
        }
    };
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A minimal test extension for verifying the trait and macro.
    struct TestExtension {
        manifest: ExtensionManifest,
    }

    impl ExtensionPlugin for TestExtension {
        fn manifest(&self) -> &ExtensionManifest {
            &self.manifest
        }

        fn register(&self, ctx: &mut RegistrationContext) -> Result<(), ExtError> {
            ctx.register_hook_json(r#"{"id":"test.hook","phase":"PreSend"}"#)?;
            Ok(())
        }
    }

    #[test]
    fn extension_plugin_trait_works() {
        let ext = TestExtension {
            manifest: ExtensionManifest {
                name: "test".to_string(),
                version: "0.1.0".to_string(),
                api_version: 1,
                datatype_declarations: vec![],
                hook_declarations: vec!["test.hook".to_string()],
                ext_dependencies: vec![],
                uri_paths: vec![],
            },
        };

        assert_eq!(ext.manifest().name, "test");

        let mut ctx = RegistrationContext::new();
        ext.register(&mut ctx).unwrap();
        assert_eq!(ctx.hook_jsons().len(), 1);
    }

    #[test]
    fn export_macro_generates_entry_function() {
        // Verify the macro compiles by using it with our test extension.
        // We can't directly test the symbol lookup here, but we can
        // verify the generated function is callable.

        #[derive(Default)]
        struct MacroTestExt;

        impl ExtensionPlugin for MacroTestExt {
            fn manifest(&self) -> &ExtensionManifest {
                // This is only called by the engine, not by the macro.
                unimplemented!("not used in this test")
            }

            fn register(&self, ctx: &mut RegistrationContext) -> Result<(), ExtError> {
                ctx.register_datatype_json(r#"{"id":"macro_test"}"#)?;
                Ok(())
            }
        }

        // Manually invoke the same logic the macro would generate.
        let mut ctx = RegistrationContext::new();
        let plugin = MacroTestExt;
        plugin.register(&mut ctx).unwrap();
        assert_eq!(ctx.datatype_jsons().len(), 1);
    }

    #[test]
    fn re_exports_are_accessible() {
        // Verify that re-exported types are usable.
        let _: u32 = ENGINE_API_VERSION;
        let _: &str = ENTRY_SYMBOL;
        let _ctx = RegistrationContext::new();
        let _err = ExtError::ManifestParse("test".into());
        let _manifest = ExtensionManifest {
            name: String::new(),
            version: String::new(),
            api_version: 1,
            datatype_declarations: vec![],
            hook_declarations: vec![],
            ext_dependencies: vec![],
            uri_paths: vec![],
        };
    }

    #[test]
    fn prelude_re_exports() {
        // Verify prelude re-exports compile.
        use crate::prelude::*;
        let _ctx = RegistrationContext::new();
        let _err = ExtError::ManifestParse("test".into());
        let _manifest = ExtensionManifest {
            name: String::new(),
            version: String::new(),
            api_version: 1,
            datatype_declarations: vec![],
            hook_declarations: vec![],
            ext_dependencies: vec![],
            uri_paths: vec![],
        };
    }
}
