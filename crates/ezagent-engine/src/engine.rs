//! Engine coordinator — ties together Registry, HookExecutor, IndexBuilder,
//! and all built-in datatypes (Identity, Room, Timeline, Message).
//!
//! The Engine is the central coordinator that:
//! 1. Initializes the Datatype Registry with all 4 built-in datatypes
//! 2. Sets up the Hook Executor with correct dependency order and all built-in hooks
//! 3. Provides write/read pipeline methods that run hooks in the correct order
//! 4. Holds references to the Identity state (keypair, pubkey cache)

use std::sync::Arc;

use ezagent_protocol::{EntityId, Keypair};

use crate::error::EngineError;
use crate::hooks::phase::{HookContext, HookPhase};
use crate::hooks::HookExecutor;
use crate::index::IndexBuilder;
use crate::registry::DatatypeRegistry;

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
