//! Registration context for extension plugins.
//!
//! When the Engine loads a `.cdylib` extension, it calls the extension's
//! C ABI entry point (`ezagent_ext_register`) and passes a raw pointer to a
//! [`RegistrationContext`]. The extension uses this context to register its
//! datatypes and hooks with the engine.
//!
//! # C ABI Contract
//!
//! The entry function symbol is [`ENTRY_SYMBOL`] with the signature
//! [`ExtEntryFn`]. The engine allocates and owns the `RegistrationContext`;
//! the extension receives a `*mut RegistrationContext` and must not free it.

use crate::error::ExtError;

/// The current Engine API version. Extensions must declare a compatible
/// `api_version` in their manifest; the engine rejects extensions whose
/// `api_version` does not match.
pub const ENGINE_API_VERSION: u32 = 1;

/// The symbol name that the Engine looks up via `dlsym` after loading
/// an extension's dynamic library.
pub const ENTRY_SYMBOL: &str = "ezagent_ext_register";

/// C ABI entry function signature.
///
/// The Engine calls this function exactly once during extension loading.
/// The `ctx` pointer is valid for the duration of the call and must not
/// be stored beyond the call's return.
///
/// # Safety
///
/// - `ctx` must be a valid, non-null pointer to a [`RegistrationContext`]
///   allocated by the Engine.
/// - The function must not store `ctx` beyond its own call frame.
pub type ExtEntryFn = unsafe extern "C" fn(ctx: *mut RegistrationContext);

/// Context passed to extension entry points during registration.
///
/// The Engine creates this struct and passes a raw pointer to the extension's
/// `ezagent_ext_register` function. Extensions call the `register_*` methods
/// to declare their datatypes and hooks.
///
/// Internally, registered items are accumulated as JSON strings and later
/// deserialized by the Engine into their proper typed representations.
pub struct RegistrationContext {
    /// JSON strings describing datatype declarations.
    datatype_jsons: Vec<String>,
    /// JSON strings describing hook declarations.
    hook_jsons: Vec<String>,
    /// Tracks whether any registration error occurred.
    last_error: Option<ExtError>,
}

// SAFETY: RegistrationContext is only used during the single-threaded
// extension registration phase. The Engine holds exclusive access and
// passes a raw pointer to the extension entry function, which runs
// synchronously on the same thread.
unsafe impl Send for RegistrationContext {}

impl RegistrationContext {
    /// Create a new, empty registration context.
    ///
    /// Called by the Engine before invoking the extension's entry function.
    pub fn new() -> Self {
        Self {
            datatype_jsons: Vec::new(),
            hook_jsons: Vec::new(),
            last_error: None,
        }
    }

    /// Reconstruct a `&mut RegistrationContext` from a raw pointer.
    ///
    /// # Safety
    ///
    /// - `ptr` must be a valid, non-null pointer to a `RegistrationContext`
    ///   that was created by [`RegistrationContext::new()`].
    /// - The caller must guarantee exclusive access (no aliasing).
    /// - The resulting reference must not outlive the pointee.
    pub unsafe fn from_raw<'a>(ptr: *mut RegistrationContext) -> &'a mut RegistrationContext {
        // SAFETY: Caller guarantees ptr is valid, non-null, and exclusively
        // accessible.
        unsafe { &mut *ptr }
    }

    /// Register a datatype declaration as a JSON string.
    ///
    /// The JSON will be deserialized by the Engine into a
    /// `DatatypeDeclaration` after registration completes.
    ///
    /// # Errors
    ///
    /// Returns [`ExtError::RegistrationFailed`] if the JSON is empty.
    pub fn register_datatype_json(&mut self, json: &str) -> Result<(), ExtError> {
        if json.is_empty() {
            return Err(ExtError::RegistrationFailed(
                "datatype JSON must not be empty".to_string(),
            ));
        }
        self.datatype_jsons.push(json.to_string());
        Ok(())
    }

    /// Register a hook declaration as a JSON string.
    ///
    /// The JSON will be deserialized by the Engine into a
    /// `HookDeclaration` after registration completes.
    ///
    /// # Errors
    ///
    /// Returns [`ExtError::RegistrationFailed`] if the JSON is empty.
    pub fn register_hook_json(&mut self, json: &str) -> Result<(), ExtError> {
        if json.is_empty() {
            return Err(ExtError::RegistrationFailed(
                "hook JSON must not be empty".to_string(),
            ));
        }
        self.hook_jsons.push(json.to_string());
        Ok(())
    }

    /// Return all registered datatype JSON strings.
    pub fn datatype_jsons(&self) -> &[String] {
        &self.datatype_jsons
    }

    /// Return all registered hook JSON strings.
    pub fn hook_jsons(&self) -> &[String] {
        &self.hook_jsons
    }

    /// Return the last registration error, if any.
    pub fn last_error(&self) -> Option<&ExtError> {
        self.last_error.as_ref()
    }

    /// Record a registration error.
    ///
    /// Called internally when a registration method fails, so that the Engine
    /// can inspect errors after the entry function returns.
    pub fn set_error(&mut self, error: ExtError) {
        self.last_error = Some(error);
    }
}

impl Default for RegistrationContext {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn register_datatype_json_stores_entry() {
        let mut ctx = RegistrationContext::new();
        let json = r#"{"id":"reactions","version":"0.1.0"}"#;
        ctx.register_datatype_json(json).unwrap();
        assert_eq!(ctx.datatype_jsons().len(), 1);
        assert_eq!(ctx.datatype_jsons()[0], json);
    }

    #[test]
    fn register_hook_json_stores_entry() {
        let mut ctx = RegistrationContext::new();
        let json = r#"{"id":"reactions.add","phase":"PreSend"}"#;
        ctx.register_hook_json(json).unwrap();
        assert_eq!(ctx.hook_jsons().len(), 1);
        assert_eq!(ctx.hook_jsons()[0], json);
    }

    #[test]
    fn register_empty_datatype_json_fails() {
        let mut ctx = RegistrationContext::new();
        let err = ctx.register_datatype_json("").unwrap_err();
        match &err {
            ExtError::RegistrationFailed(msg) => {
                assert!(msg.contains("empty"), "expected 'empty' in: {msg}");
            }
            other => panic!("expected RegistrationFailed, got: {other}"),
        }
    }

    #[test]
    fn register_empty_hook_json_fails() {
        let mut ctx = RegistrationContext::new();
        let err = ctx.register_hook_json("").unwrap_err();
        match &err {
            ExtError::RegistrationFailed(msg) => {
                assert!(msg.contains("empty"), "expected 'empty' in: {msg}");
            }
            other => panic!("expected RegistrationFailed, got: {other}"),
        }
    }

    #[test]
    fn multiple_registrations() {
        let mut ctx = RegistrationContext::new();
        ctx.register_datatype_json(r#"{"id":"a"}"#).unwrap();
        ctx.register_datatype_json(r#"{"id":"b"}"#).unwrap();
        ctx.register_hook_json(r#"{"id":"h1"}"#).unwrap();
        ctx.register_hook_json(r#"{"id":"h2"}"#).unwrap();
        ctx.register_hook_json(r#"{"id":"h3"}"#).unwrap();

        assert_eq!(ctx.datatype_jsons().len(), 2);
        assert_eq!(ctx.hook_jsons().len(), 3);
    }

    #[test]
    fn from_raw_roundtrip() {
        let mut ctx = RegistrationContext::new();
        ctx.register_datatype_json(r#"{"id":"test"}"#).unwrap();

        let ptr: *mut RegistrationContext = &mut ctx;
        // SAFETY: ptr is valid and we have exclusive access in this test.
        let ctx_ref = unsafe { RegistrationContext::from_raw(ptr) };
        assert_eq!(ctx_ref.datatype_jsons().len(), 1);
    }

    #[test]
    fn last_error_initially_none() {
        let ctx = RegistrationContext::new();
        assert!(ctx.last_error().is_none());
    }

    #[test]
    fn set_error_records_error() {
        let mut ctx = RegistrationContext::new();
        ctx.set_error(ExtError::RegistrationFailed("test".into()));
        assert!(ctx.last_error().is_some());
    }

    #[test]
    fn default_impl() {
        let ctx = RegistrationContext::default();
        assert!(ctx.datatype_jsons().is_empty());
        assert!(ctx.hook_jsons().is_empty());
        assert!(ctx.last_error().is_none());
    }

    #[test]
    fn engine_api_version_is_1() {
        assert_eq!(ENGINE_API_VERSION, 1);
    }

    #[test]
    fn entry_symbol_is_correct() {
        assert_eq!(ENTRY_SYMBOL, "ezagent_ext_register");
    }
}
