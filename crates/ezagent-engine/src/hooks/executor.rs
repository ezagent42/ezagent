//! Hook Pipeline executor (bus-spec SS3.2).
//!
//! The `HookExecutor` manages hook registration and execution across the three
//! pipeline phases. It enforces priority ordering, dependency-topology ordering,
//! global hook restrictions, and phase-specific error handling semantics.

use std::collections::{HashMap, HashSet};
use std::sync::Arc;

use crate::error::EngineError;

use super::phase::{HookContext, HookDeclaration, HookPhase};

/// A hook handler function.
///
/// Receives a mutable `HookContext` and returns `Ok(())` on success or an
/// `EngineError` on failure. The function must be `Send + Sync` for
/// thread-safe execution.
pub type HookFn = Arc<dyn Fn(&mut HookContext) -> Result<(), EngineError> + Send + Sync>;

/// A registered hook entry combining its declaration with its handler.
pub struct HookEntry {
    /// The hook declaration (metadata).
    pub decl: HookDeclaration,
    /// The handler function to invoke.
    pub handler: HookFn,
}

/// The Hook Pipeline executor.
///
/// Manages a collection of registered hooks and executes them in the correct
/// order for each pipeline phase. Enforces:
///
/// - Priority-based ordering (ascending, 0 = highest priority)
/// - Dependency-topology ordering for same-priority hooks
/// - Alphabetical tie-breaking for same-priority, unrelated hooks
/// - Special handling for `identity.sign_envelope` (always last in PreSend)
/// - Global hook restriction (only built-in datatypes may register `"*"` triggers)
/// - Phase-specific error handling (PreSend aborts, AfterWrite logs, AfterRead ignores)
pub struct HookExecutor {
    /// All registered hook entries.
    hooks: Vec<HookEntry>,
    /// Maps source datatype ID to its position in the dependency topology.
    /// Lower index = earlier in dependency chain (loaded first).
    dependency_order: HashMap<String, usize>,
    /// Set of datatype IDs that are built-in (allowed to register global hooks).
    builtin_ids: HashSet<String>,
}

impl HookExecutor {
    /// Create a new empty `HookExecutor`.
    pub fn new() -> Self {
        Self {
            hooks: Vec::new(),
            dependency_order: HashMap::new(),
            builtin_ids: HashSet::new(),
        }
    }

    /// Set the dependency topology order for hook sorting.
    ///
    /// The order slice should be the topologically sorted list of datatype IDs
    /// (e.g., from `DatatypeRegistry::load_order()`). The position in this
    /// list determines the sort key for hooks with equal priority.
    pub fn set_dependency_order(&mut self, order: &[String]) {
        self.dependency_order.clear();
        for (i, id) in order.iter().enumerate() {
            self.dependency_order.insert(id.clone(), i);
        }
    }

    /// Set the set of built-in datatype IDs.
    ///
    /// Only datatypes in this set are allowed to register global hooks
    /// (hooks with `trigger_datatype: "*"`).
    pub fn set_builtin_ids(&mut self, ids: Vec<String>) {
        self.builtin_ids = ids.into_iter().collect();
    }

    /// Register a hook with the executor.
    ///
    /// Returns `EngineError::ExtensionCannotRegisterGlobalHook` if a non-builtin
    /// datatype attempts to register a global hook (`trigger_datatype: "*"`).
    pub fn register(&mut self, decl: HookDeclaration, handler: HookFn) -> Result<(), EngineError> {
        // Enforce global hook restriction (bus-spec SS3.2.4).
        if decl.trigger_datatype == "*" && !self.builtin_ids.contains(&decl.source) {
            return Err(EngineError::ExtensionCannotRegisterGlobalHook);
        }

        self.hooks.push(HookEntry { decl, handler });
        Ok(())
    }

    /// Execute all matching hooks for the given phase and context.
    ///
    /// Filters hooks by phase, trigger datatype, and trigger event, then
    /// sorts them according to the spec ordering rules and executes them
    /// sequentially.
    ///
    /// # Error Handling by Phase
    ///
    /// - **PreSend**: If any hook returns an error or sets `ctx.rejected`,
    ///   execution stops immediately and the error is returned to the caller.
    /// - **AfterWrite**: Errors are logged via `eprintln!` but execution continues
    ///   through the remaining hooks.
    /// - **AfterRead**: Errors are silently ignored and execution continues.
    pub fn execute(&self, phase: HookPhase, ctx: &mut HookContext) -> Result<(), EngineError> {
        // Collect indices of matching hooks.
        let mut matching_indices: Vec<usize> = self
            .hooks
            .iter()
            .enumerate()
            .filter(|(_, entry)| {
                // Phase must match.
                if entry.decl.phase != phase {
                    return false;
                }
                // Trigger datatype must match: "*" matches all, or exact match.
                if entry.decl.trigger_datatype != "*"
                    && entry.decl.trigger_datatype != ctx.datatype_id
                {
                    return false;
                }
                // Trigger event must match.
                entry.decl.trigger_event.matches(&ctx.event)
            })
            .map(|(i, _)| i)
            .collect();

        // Sort by: priority ASC -> dependency order -> alphabetical source.
        matching_indices.sort_by(|&a, &b| {
            let decl_a = &self.hooks[a].decl;
            let decl_b = &self.hooks[b].decl;

            // 1. Priority ascending.
            let prio_cmp = decl_a.priority.cmp(&decl_b.priority);
            if prio_cmp != std::cmp::Ordering::Equal {
                return prio_cmp;
            }

            // 2. Dependency topology order (lower index = earlier dependency).
            let dep_a = self
                .dependency_order
                .get(&decl_a.source)
                .copied()
                .unwrap_or(usize::MAX);
            let dep_b = self
                .dependency_order
                .get(&decl_b.source)
                .copied()
                .unwrap_or(usize::MAX);
            let dep_cmp = dep_a.cmp(&dep_b);
            if dep_cmp != std::cmp::Ordering::Equal {
                return dep_cmp;
            }

            // 3. Alphabetical by source id.
            decl_a.source.cmp(&decl_b.source)
        });

        // Special rule: identity.sign_envelope must run LAST in PreSend
        // (bus-spec SS3.2.3), regardless of its priority.
        if phase == HookPhase::PreSend {
            let sign_pos = matching_indices
                .iter()
                .position(|&i| self.hooks[i].decl.id == "identity.sign_envelope");
            if let Some(pos) = sign_pos {
                let sign_idx = matching_indices.remove(pos);
                matching_indices.push(sign_idx);
            }
        }

        // Execute hooks in order.
        for &idx in &matching_indices {
            let entry = &self.hooks[idx];

            match phase {
                HookPhase::PreSend => {
                    // PreSend: error aborts the chain.
                    (entry.handler)(ctx)?;

                    // Check if a hook rejected via context flag.
                    if ctx.rejected {
                        let reason = ctx
                            .rejection_reason
                            .clone()
                            .unwrap_or_else(|| "rejected by hook".to_string());
                        return Err(EngineError::HookRejected(reason));
                    }
                }
                HookPhase::AfterWrite => {
                    // AfterWrite: log errors, continue chain.
                    if let Err(e) = (entry.handler)(ctx) {
                        eprintln!(
                            "[hook-pipeline] after_write hook '{}' failed: {}",
                            entry.decl.id, e
                        );
                    }
                }
                HookPhase::AfterRead => {
                    // AfterRead: silently ignore errors.
                    let _ = (entry.handler)(ctx);
                }
            }
        }

        Ok(())
    }
}

impl Default for HookExecutor {
    fn default() -> Self {
        Self::new()
    }
}
