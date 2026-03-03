//! Engine coordinator — ties together Registry, HookExecutor, IndexBuilder,
//! and all built-in datatypes (Identity, Room, Timeline, Message).
//!
//! The Engine is the central coordinator that:
//! 1. Initializes the Datatype Registry with all 4 built-in datatypes
//! 2. Sets up the Hook Executor with correct dependency order and all built-in hooks
//! 3. Provides write/read pipeline methods that run hooks in the correct order
//! 4. Holds references to the Identity state (keypair, pubkey cache)

use std::collections::HashMap;
use std::path::Path;
use std::sync::Arc;

use ezagent_protocol::{EntityId, Keypair};

use crate::error::EngineError;
use crate::hooks::phase::{HookContext, HookPhase};
use crate::hooks::HookExecutor;
use crate::index::IndexBuilder;
use crate::loader;
use crate::registry::DatatypeRegistry;
use crate::uri_registry::UriPathRegistry;

use crate::builtins::identity::PublicKeyCache;

/// The core Engine coordinator.
///
/// Ties together the Datatype Registry, Hook Pipeline executor, Index Builder,
/// and identity state into a single cohesive unit. All 4 built-in datatypes
/// (Identity, Room, Timeline, Message) are registered at construction time,
/// with their hooks wired into the executor.
///
/// Identity-specific hooks (sign/verify) are registered lazily via
/// [`Engine::init_identity`], since they require a keypair that may not be
/// available at construction time.
pub struct Engine {
    /// The datatype registry containing all built-in and extension datatypes.
    pub registry: DatatypeRegistry,
    /// The hook pipeline executor with all registered hooks.
    pub hook_executor: HookExecutor,
    /// The index builder for derived views.
    pub index_builder: IndexBuilder,
    /// Shared public key cache for signature verification.
    pub pubkey_cache: PublicKeyCache,
    /// The local keypair, set via `init_identity`.
    keypair: Option<Arc<Keypair>>,
    /// The local entity ID, set via `init_identity`.
    entity_id: Option<EntityId>,
    /// URI path registry mapping extension patterns to extension IDs.
    pub uri_registry: UriPathRegistry,
    /// Extensions that have been successfully loaded, keyed by name.
    loaded_extensions: HashMap<String, loader::LoadedExtension>,
    /// Loaded dynamic libraries kept alive for the lifetime of the Engine.
    ///
    /// Libraries must remain loaded as long as any extension code may be called.
    /// Dropping a `Library` would unmap the shared object, causing use-after-free
    /// if any function pointers or vtable entries from that library are still in use.
    #[allow(dead_code)]
    loaded_libraries: Vec<libloading::Library>,
}

impl Engine {
    /// Create a new Engine with all built-in datatypes and hooks registered.
    ///
    /// Registers the 4 built-in datatypes (identity, room, timeline, message),
    /// computes their load order, and registers all non-identity hooks. Identity
    /// hooks (sign_envelope, verify_signature) are registered separately via
    /// [`Engine::init_identity`] because they require a keypair.
    ///
    /// # Errors
    ///
    /// Returns `EngineError` if datatype registration fails (should not happen
    /// for built-in types) or if dependency resolution detects a cycle.
    pub fn new() -> Result<Self, EngineError> {
        let mut registry = DatatypeRegistry::new();

        // Register all 4 built-in datatypes.
        registry.register(crate::builtins::identity::identity_datatype())?;
        registry.register(crate::builtins::room::room_datatype())?;
        registry.register(crate::builtins::timeline::timeline_datatype())?;
        registry.register(crate::builtins::message::message_datatype())?;

        // Compute load order.
        let load_order = registry.load_order()?;

        // Set up hook executor.
        let mut hook_executor = HookExecutor::new();
        hook_executor.set_builtin_ids(vec![
            "identity".into(),
            "room".into(),
            "timeline".into(),
            "message".into(),
        ]);
        hook_executor.set_dependency_order(&load_order);

        // Register room hooks (they don't need state).
        let (decl, handler) = crate::builtins::room::check_room_write_hook();
        hook_executor.register(decl, handler)?;
        let (decl, handler) = crate::builtins::room::check_config_permission_hook();
        hook_executor.register(decl, handler)?;
        let (decl, handler) = crate::builtins::room::extension_loader_hook();
        hook_executor.register(decl, handler)?;
        let (decl, handler) = crate::builtins::room::member_change_notify_hook();
        hook_executor.register(decl, handler)?;

        // Register timeline hooks.
        let (decl, handler) = crate::builtins::timeline::generate_ref_hook();
        hook_executor.register(decl, handler)?;
        let (decl, handler) = crate::builtins::timeline::ref_change_detect_hook();
        hook_executor.register(decl, handler)?;
        let (decl, handler) = crate::builtins::timeline::timeline_pagination_hook();
        hook_executor.register(decl, handler)?;

        // Register message hooks.
        let (decl, handler) = crate::builtins::message::compute_content_hash_hook();
        hook_executor.register(decl, handler)?;
        let (decl, handler) = crate::builtins::message::validate_content_ref_hook();
        hook_executor.register(decl, handler)?;
        let (decl, handler) = crate::builtins::message::resolve_content_hook();
        hook_executor.register(decl, handler)?;

        // Identity hooks (sign/verify) are registered when identity is initialized.

        let index_builder = IndexBuilder::new();
        let pubkey_cache = PublicKeyCache::new();

        Ok(Self {
            registry,
            hook_executor,
            index_builder,
            pubkey_cache,
            keypair: None,
            entity_id: None,
            uri_registry: UriPathRegistry::new(),
            loaded_extensions: HashMap::new(),
            loaded_libraries: Vec::new(),
        })
    }

    /// Initialize the local identity (generate or load keypair).
    ///
    /// Caches the entity's public key, registers the `identity.sign_envelope`
    /// and `identity.verify_signature` hooks, and stores the keypair and
    /// entity ID for later use.
    ///
    /// # Errors
    ///
    /// Returns `EngineError` if hook registration fails (should not happen
    /// for built-in hooks).
    pub fn init_identity(
        &mut self,
        entity_id: EntityId,
        keypair: Keypair,
    ) -> Result<(), EngineError> {
        let keypair = Arc::new(keypair);

        // Cache own public key.
        self.pubkey_cache
            .insert(&entity_id.to_string(), keypair.public_key());

        // Register identity hooks.
        let (decl, handler) =
            crate::builtins::identity::sign_envelope_hook(Arc::clone(&keypair));
        self.hook_executor.register(decl, handler)?;
        let (decl, handler) =
            crate::builtins::identity::verify_signature_hook(self.pubkey_cache.clone());
        self.hook_executor.register(decl, handler)?;

        self.keypair = Some(keypair);
        self.entity_id = Some(entity_id);
        Ok(())
    }

    /// Get the local entity ID.
    pub fn entity_id(&self) -> Option<&EntityId> {
        self.entity_id.as_ref()
    }

    /// Get the local keypair.
    pub fn keypair(&self) -> Option<&Keypair> {
        self.keypair.as_ref().map(|k| k.as_ref())
    }

    /// Execute the pre_send hook pipeline for a write operation.
    ///
    /// If the context has no `signer_id` set, the engine's local entity ID
    /// is used as the default signer. This ensures that all writes are
    /// attributed to the local identity unless explicitly overridden.
    ///
    /// # Errors
    ///
    /// Returns `EngineError` if any PreSend hook rejects the operation or
    /// encounters an error.
    pub fn run_pre_send(&self, ctx: &mut HookContext) -> Result<(), EngineError> {
        // Set signer_id from engine's identity if not already set.
        if ctx.signer_id.is_none() {
            if let Some(entity_id) = &self.entity_id {
                ctx.signer_id = Some(entity_id.to_string());
            }
        }
        self.hook_executor.execute(HookPhase::PreSend, ctx)
    }

    /// Execute the after_write hook pipeline.
    ///
    /// Marks the context as read-only before executing hooks. AfterWrite
    /// hook errors are logged but do not abort the pipeline.
    ///
    /// # Errors
    ///
    /// Returns `Ok(())` in practice, since AfterWrite errors are logged
    /// rather than propagated.
    pub fn run_after_write(&self, ctx: &mut HookContext) -> Result<(), EngineError> {
        ctx.read_only = true;
        self.hook_executor.execute(HookPhase::AfterWrite, ctx)
    }

    /// Execute the after_read hook pipeline.
    ///
    /// Marks the context as read-only before executing hooks. AfterRead
    /// hook errors are silently ignored.
    ///
    /// # Errors
    ///
    /// Returns `Ok(())` in practice, since AfterRead errors are silently
    /// ignored.
    pub fn run_after_read(&self, ctx: &mut HookContext) -> Result<(), EngineError> {
        ctx.read_only = true;
        self.hook_executor.execute(HookPhase::AfterRead, ctx)
    }

    /// Check if a datatype is registered.
    pub fn has_datatype(&self, id: &str) -> bool {
        self.registry.get(id).is_some()
    }

    /// Get the load order for a room with given enabled extensions.
    ///
    /// Always includes the 4 built-in datatypes; additionally includes
    /// any extensions whose IDs appear in `enabled_extensions`, provided
    /// their dependencies are met.
    ///
    /// # Errors
    ///
    /// Returns `EngineError::DependencyNotMet` if an enabled extension's
    /// dependency is not also enabled (or built-in).
    pub fn load_order_for_room(
        &self,
        enabled_extensions: &[String],
    ) -> Result<Vec<String>, EngineError> {
        self.registry.load_order_for_room(enabled_extensions)
    }

    /// Check whether a named extension has been loaded.
    pub fn is_extension_loaded(&self, name: &str) -> bool {
        self.loaded_extensions.contains_key(name)
    }

    /// Return the names of all currently loaded extensions.
    pub fn loaded_extensions(&self) -> Vec<String> {
        self.loaded_extensions.keys().cloned().collect()
    }

    /// Load extensions from a directory.
    ///
    /// Orchestrates the full extension loading pipeline:
    ///
    /// 1. **Scan** -- discover `manifest.toml` files in `{dir}/*/`.
    /// 2. **Filter** -- reject extensions with incompatible API versions.
    /// 3. **Resolve** -- topologically sort by declared dependencies.
    /// 4. **Load** -- for each extension in order, compute the library path,
    ///    open the shared library via `libloading`, look up the entry symbol,
    ///    create a `RegistrationContext` and call the entry function, then
    ///    process any registered datatypes/hooks from the context. On success
    ///    the extension is recorded; on failure the error is collected and
    ///    loading continues to the next extension.
    ///
    /// Returns all errors encountered during the pipeline. Errors are
    /// non-fatal: each failing extension is skipped but does not prevent
    /// other extensions from loading.
    pub fn load_extensions(&mut self, dir: &Path) -> Vec<loader::ExtensionLoadError> {
        let mut all_errors: Vec<loader::ExtensionLoadError> = Vec::new();

        // Step 1: Scan.
        let (scanned, scan_errors) = loader::scan_manifests(dir);
        all_errors.extend(scan_errors);

        // Step 2: Filter by API version.
        let (compatible, version_errors) = loader::filter_api_version(scanned);
        all_errors.extend(version_errors);

        // Step 3: Resolve topological order.
        let order = match loader::resolve_extension_order(&compatible) {
            Ok(order) => order,
            Err(dep_errors) => {
                all_errors.extend(dep_errors);
                return all_errors;
            }
        };

        // Build a lookup from name to (path, manifest) for the loading phase.
        let manifest_map: HashMap<String, (std::path::PathBuf, ezagent_ext_api::ExtensionManifest)> =
            compatible
                .into_iter()
                .map(|(path, manifest)| (manifest.name.clone(), (path, manifest)))
                .collect();

        // Step 4: Load each extension in topological order.
        for ext_name in &order {
            let (ext_path, manifest) = match manifest_map.get(ext_name) {
                Some(entry) => entry,
                None => continue,
            };

            let lib_name = loader::lib_filename(ext_name);
            let lib_path = ext_path.join(&lib_name);

            // 4a-b: Open the shared library.
            let lib = match unsafe { libloading::Library::new(&lib_path) } {
                Ok(lib) => lib,
                Err(e) => {
                    all_errors.push(loader::ExtensionLoadError {
                        name: ext_name.clone(),
                        reason: format!("failed to load library '{}': {}", lib_path.display(), e),
                    });
                    continue;
                }
            };

            // 4c: Look up the entry symbol.
            let entry_fn: libloading::Symbol<'_, ezagent_ext_api::ExtEntryFn> =
                match unsafe { lib.get(ezagent_ext_api::ENTRY_SYMBOL.as_bytes()) } {
                    Ok(sym) => sym,
                    Err(e) => {
                        all_errors.push(loader::ExtensionLoadError {
                            name: ext_name.clone(),
                            reason: format!(
                                "symbol '{}' not found: {}",
                                ezagent_ext_api::ENTRY_SYMBOL,
                                e
                            ),
                        });
                        continue;
                    }
                };

            // 4d: Create registration context and call the entry function.
            let mut ctx = ezagent_ext_api::RegistrationContext::new();
            unsafe {
                entry_fn(&mut ctx as *mut ezagent_ext_api::RegistrationContext);
            }

            // Check for errors reported by the extension.
            if let Some(ext_err) = ctx.last_error() {
                all_errors.push(loader::ExtensionLoadError {
                    name: ext_name.clone(),
                    reason: format!("registration error: {ext_err}"),
                });
                continue;
            }

            // 4e: Process registered datatypes (best-effort JSON deserialization).
            // Datatype and hook registration from JSON is deferred to the
            // integration phase (Task 4). For now, log the registrations.
            for dt_json in ctx.datatype_jsons() {
                log::debug!(
                    "extension '{}' registered datatype JSON: {}",
                    ext_name,
                    dt_json
                );
            }

            for hook_json in ctx.hook_jsons() {
                log::debug!(
                    "extension '{}' registered hook JSON: {}",
                    ext_name,
                    hook_json
                );
            }

            // 4f: Record success.
            self.loaded_extensions.insert(
                ext_name.clone(),
                loader::LoadedExtension {
                    name: ext_name.clone(),
                    version: manifest.version.clone(),
                    manifest: manifest.clone(),
                },
            );

            // Keep the library alive for the lifetime of the Engine.
            self.loaded_libraries.push(lib);
        }

        all_errors
    }
}

impl Default for Engine {
    fn default() -> Self {
        Self::new().expect("built-in datatype registration should not fail")
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::hooks::phase::TriggerEvent;
    use ezagent_protocol::{EntityId, Keypair};

    /// engine_initializes_with_all_builtins — Engine::new() succeeds, has all 4 datatypes.
    #[test]
    fn engine_initializes_with_all_builtins() {
        let engine = Engine::new().expect("Engine::new() should succeed");

        assert!(engine.has_datatype("identity"), "identity must be registered");
        assert!(engine.has_datatype("room"), "room must be registered");
        assert!(engine.has_datatype("timeline"), "timeline must be registered");
        assert!(engine.has_datatype("message"), "message must be registered");

        // Verify that non-existent datatypes return false.
        assert!(!engine.has_datatype("nonexistent"));
    }

    /// engine_load_order_is_correct — identity < room < timeline < message.
    #[test]
    fn engine_load_order_is_correct() {
        let engine = Engine::new().expect("Engine::new() should succeed");

        let order = engine.registry.load_order().expect("load_order should succeed");
        assert_eq!(
            order,
            vec!["identity", "room", "timeline", "message"],
            "built-in load order must be identity < room < timeline < message"
        );
    }

    /// engine_init_identity_registers_hooks — after init_identity, sign/verify hooks work.
    #[test]
    fn engine_init_identity_registers_hooks() {
        let mut engine = Engine::new().expect("Engine::new() should succeed");

        let kp = Keypair::generate();
        let entity_id = EntityId::parse("@alice:relay.example.com").expect("valid entity id");

        engine
            .init_identity(entity_id.clone(), kp)
            .expect("init_identity should succeed");

        // Verify the entity ID and keypair are stored.
        assert_eq!(
            engine.entity_id().map(|e| e.to_string()),
            Some("@alice:relay.example.com".to_string())
        );
        assert!(engine.keypair().is_some(), "keypair should be set after init_identity");

        // Verify the public key is cached.
        let cached_pk = engine.pubkey_cache.get("@alice:relay.example.com");
        assert!(cached_pk.is_some(), "public key should be cached after init_identity");

        // Test that the sign hook works by running pre_send.
        let mut ctx = HookContext::new("message".to_string(), TriggerEvent::Insert);
        ctx.signer_id = Some("@alice:relay.example.com".to_string());
        ctx.data.insert("payload".into(), serde_json::json!("test data"));
        ctx.data.insert("doc_id".into(), serde_json::json!("rooms/r1/messages"));

        let result = engine.run_pre_send(&mut ctx);
        assert!(result.is_ok(), "pre_send should succeed after init_identity: {:?}", result.err());

        // The sign hook should have produced a signed_envelope.
        assert!(
            ctx.data.contains_key("signed_envelope"),
            "signed_envelope should be in context after pre_send"
        );
    }

    /// engine_pre_send_sets_signer — run_pre_send auto-sets signer_id.
    #[test]
    fn engine_pre_send_sets_signer() {
        let mut engine = Engine::new().expect("Engine::new() should succeed");

        let kp = Keypair::generate();
        let entity_id = EntityId::parse("@bob:relay.io").expect("valid entity id");

        engine
            .init_identity(entity_id, kp)
            .expect("init_identity should succeed");

        // Create a context with NO signer_id.
        let mut ctx = HookContext::new("message".to_string(), TriggerEvent::Insert);
        assert!(ctx.signer_id.is_none(), "signer_id should start as None");

        ctx.data.insert("payload".into(), serde_json::json!("auto-sign test"));
        ctx.data.insert("doc_id".into(), serde_json::json!("rooms/r1/messages"));

        let result = engine.run_pre_send(&mut ctx);
        assert!(result.is_ok(), "pre_send should succeed: {:?}", result.err());

        // The signer_id should have been auto-set from the engine's entity_id.
        assert_eq!(
            ctx.signer_id.as_deref(),
            Some("@bob:relay.io"),
            "signer_id should be auto-set from engine entity_id"
        );
    }

    /// engine_after_write_sets_read_only — run_after_write marks ctx as read_only.
    #[test]
    fn engine_after_write_sets_read_only() {
        let engine = Engine::new().expect("Engine::new() should succeed");

        let mut ctx = HookContext::new("message".to_string(), TriggerEvent::Insert);
        assert!(!ctx.read_only, "context should start read-write");

        let result = engine.run_after_write(&mut ctx);
        assert!(result.is_ok(), "after_write should succeed");
        assert!(ctx.read_only, "context should be read_only after run_after_write");
    }

    /// engine_after_read_sets_read_only — run_after_read marks ctx as read_only.
    #[test]
    fn engine_after_read_sets_read_only() {
        let engine = Engine::new().expect("Engine::new() should succeed");

        let mut ctx = HookContext::new("timeline_index".to_string(), TriggerEvent::Any);
        assert!(!ctx.read_only, "context should start read-write");

        let result = engine.run_after_read(&mut ctx);
        assert!(result.is_ok(), "after_read should succeed");
        assert!(ctx.read_only, "context should be read_only after run_after_read");
    }

    /// engine_default_impl — Default trait works.
    #[test]
    fn engine_default_impl() {
        let engine = Engine::default();

        // Default engine should have all 4 builtins registered.
        assert!(engine.has_datatype("identity"));
        assert!(engine.has_datatype("room"));
        assert!(engine.has_datatype("timeline"));
        assert!(engine.has_datatype("message"));

        // No identity initialized yet.
        assert!(engine.entity_id().is_none());
        assert!(engine.keypair().is_none());
    }

    /// engine_no_extensions_loaded_by_default — loaded_extensions is empty after Engine::new().
    #[test]
    fn engine_no_extensions_loaded_by_default() {
        let engine = Engine::new().expect("Engine::new() should succeed");

        assert!(
            engine.loaded_extensions().is_empty(),
            "no extensions should be loaded by default"
        );
        assert!(
            !engine.is_extension_loaded("reactions"),
            "random extension should not be loaded"
        );
    }

    /// load_order_for_room returns builtins-only when no extensions are enabled.
    #[test]
    fn engine_load_order_for_room_builtins_only() {
        let engine = Engine::new().expect("Engine::new() should succeed");

        let order = engine
            .load_order_for_room(&[])
            .expect("load_order_for_room should succeed");
        assert_eq!(
            order,
            vec!["identity", "room", "timeline", "message"],
            "empty extensions should yield builtins only"
        );
    }
}
