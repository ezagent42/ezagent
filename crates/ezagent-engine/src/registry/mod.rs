//! Datatype Registry — central catalog of all datatype declarations.
//!
//! The registry stores `DatatypeDeclaration` entries, resolves their load
//! order via topological sort, and supports per-room extension filtering.

pub mod datatype;
pub mod dependency;

use std::collections::HashMap;

use crate::error::EngineError;
use datatype::DatatypeDeclaration;
use dependency::resolve_load_order;

/// Central registry for all known datatypes (built-in and extension).
///
/// The registry enforces uniqueness by datatype id, and provides methods
/// to compute global and per-room load orders.
pub struct DatatypeRegistry {
    datatypes: HashMap<String, DatatypeDeclaration>,
}

impl DatatypeRegistry {
    /// Create an empty registry.
    pub fn new() -> Self {
        Self {
            datatypes: HashMap::new(),
        }
    }

    /// Register a datatype declaration.
    ///
    /// Returns `EngineError::DuplicateDatatype` if a datatype with the same
    /// id is already registered.
    pub fn register(&mut self, decl: DatatypeDeclaration) -> Result<(), EngineError> {
        if self.datatypes.contains_key(&decl.id) {
            return Err(EngineError::DuplicateDatatype(decl.id.clone()));
        }
        self.datatypes.insert(decl.id.clone(), decl);
        Ok(())
    }

    /// Look up a datatype by id.
    pub fn get(&self, id: &str) -> Option<&DatatypeDeclaration> {
        self.datatypes.get(id)
    }

    /// Return all registered datatype IDs.
    pub fn ids(&self) -> Vec<String> {
        self.datatypes.keys().cloned().collect()
    }

    /// Compute the global load order for all registered datatypes.
    ///
    /// Returns a topologically sorted list of datatype IDs with alphabetical
    /// tie-breaking. Returns `EngineError::CircularDependency` on cycle.
    pub fn load_order(&self) -> Result<Vec<String>, EngineError> {
        let ids: Vec<String> = self.datatypes.keys().cloned().collect();
        let deps: HashMap<String, Vec<String>> = self
            .datatypes
            .iter()
            .map(|(id, decl)| (id.clone(), decl.dependencies.clone()))
            .collect();
        resolve_load_order(&ids, &deps)
    }

    /// Compute the load order for a specific room given its enabled extensions.
    ///
    /// - Always includes all built-in datatypes.
    /// - Only includes extensions whose id appears in `enabled_extensions`.
    /// - Verifies that every dependency of an enabled extension is also
    ///   enabled (or built-in). Returns `EngineError::DependencyNotMet` if not.
    pub fn load_order_for_room(
        &self,
        enabled_extensions: &[String],
    ) -> Result<Vec<String>, EngineError> {
        // Collect the IDs that will participate in this room.
        let mut room_ids: Vec<String> = Vec::new();
        let enabled_set: std::collections::HashSet<&str> =
            enabled_extensions.iter().map(|s| s.as_str()).collect();

        for (id, decl) in &self.datatypes {
            if decl.is_builtin || enabled_set.contains(id.as_str()) {
                room_ids.push(id.clone());
            }
        }

        let room_id_set: std::collections::HashSet<&str> =
            room_ids.iter().map(|s| s.as_str()).collect();

        // Check that every dependency of included datatypes is also included.
        for id in &room_ids {
            let decl = &self.datatypes[id];
            for dep in &decl.dependencies {
                if !room_id_set.contains(dep.as_str()) {
                    return Err(EngineError::DependencyNotMet {
                        ext: id.clone(),
                        requires: dep.clone(),
                    });
                }
            }
        }

        // Compute topological order over the included subset.
        let deps: HashMap<String, Vec<String>> = room_ids
            .iter()
            .map(|id| {
                let decl = &self.datatypes[id];
                (id.clone(), decl.dependencies.clone())
            })
            .collect();

        resolve_load_order(&room_ids, &deps)
    }
}

impl Default for DatatypeRegistry {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::datatype::*;
    use super::*;
    use ezagent_protocol::KeyPattern;

    /// Helper: create a minimal built-in datatype declaration.
    fn builtin_decl(id: &str, deps: Vec<&str>) -> DatatypeDeclaration {
        DatatypeDeclaration {
            id: id.to_string(),
            version: "1.0.0".to_string(),
            dependencies: deps.into_iter().map(String::from).collect(),
            data_entries: vec![DataEntry {
                id: format!("{id}_entry"),
                storage_type: StorageType::CrdtMap,
                key_pattern: KeyPattern::new(format!("entity/@{{entity_id}}/{id}")),
                persistent: true,
                writer_rule: WriterRule::SignerIsEntity,
                sync_strategy: SyncMode::default(),
            }],
            indexes: vec![],
            hooks: vec![],
            is_builtin: true,
        }
    }

    /// Helper: create a minimal extension datatype declaration.
    fn extension_decl(id: &str, deps: Vec<&str>) -> DatatypeDeclaration {
        DatatypeDeclaration {
            id: id.to_string(),
            version: "1.0.0".to_string(),
            dependencies: deps.into_iter().map(String::from).collect(),
            data_entries: vec![DataEntry {
                id: format!("{id}_entry"),
                storage_type: StorageType::CrdtMap,
                key_pattern: KeyPattern::new(format!("room/{{room_id}}/ext/{id}")),
                persistent: true,
                writer_rule: WriterRule::SignerInMembers,
                sync_strategy: SyncMode::default(),
            }],
            indexes: vec![],
            hooks: vec![],
            is_builtin: false,
        }
    }

    /// Helper: register the four built-in datatypes into a registry.
    fn register_builtins(reg: &mut DatatypeRegistry) {
        reg.register(builtin_decl("identity", vec![])).unwrap();
        reg.register(builtin_decl("room", vec!["identity"]))
            .unwrap();
        reg.register(builtin_decl("timeline", vec!["identity", "room"]))
            .unwrap();
        reg.register(builtin_decl(
            "message",
            vec!["identity", "room", "timeline"],
        ))
        .unwrap();
    }

    /// TC-1-ENGINE-001: register a built-in datatype, verify fields.
    #[test]
    fn tc_1_engine_001_register_builtin_datatype() {
        let mut reg = DatatypeRegistry::new();

        let identity = DatatypeDeclaration {
            id: "identity".to_string(),
            version: "1.0.0".to_string(),
            dependencies: vec![],
            data_entries: vec![DataEntry {
                id: "pubkey".to_string(),
                storage_type: StorageType::Blob,
                key_pattern: KeyPattern::new("entity/@{entity_id}/identity/pubkey"),
                persistent: true,
                writer_rule: WriterRule::SignerIsEntity,
                sync_strategy: SyncMode::Eager,
            }],
            indexes: vec![],
            hooks: vec![],
            is_builtin: true,
        };

        reg.register(identity).unwrap();

        let fetched = reg.get("identity").expect("identity should be registered");
        assert_eq!(fetched.id, "identity");
        assert_eq!(fetched.version, "1.0.0");
        assert!(fetched.dependencies.is_empty());
        assert!(fetched.is_builtin);
        assert_eq!(fetched.data_entries.len(), 1);

        let entry = &fetched.data_entries[0];
        assert_eq!(entry.id, "pubkey");
        assert_eq!(entry.storage_type, StorageType::Blob);
        assert_eq!(
            entry.key_pattern.template(),
            "entity/@{entity_id}/identity/pubkey"
        );
        assert!(entry.persistent);
        assert_eq!(entry.writer_rule, WriterRule::SignerIsEntity);
        assert_eq!(entry.sync_strategy, SyncMode::Eager);
    }

    /// TC-1-ENGINE-002: dependency resolution order — identity < room < timeline < message.
    #[test]
    fn tc_1_engine_002_dependency_resolution_order() {
        let mut reg = DatatypeRegistry::new();
        register_builtins(&mut reg);

        let order = reg.load_order().unwrap();
        assert_eq!(order, vec!["identity", "room", "timeline", "message"]);
    }

    /// TC-1-ENGINE-003: circular dependency is rejected.
    #[test]
    fn tc_1_engine_003_circular_dependency_rejected() {
        let mut reg = DatatypeRegistry::new();

        let a = DatatypeDeclaration {
            id: "a".to_string(),
            version: "1.0.0".to_string(),
            dependencies: vec!["b".to_string()],
            data_entries: vec![],
            indexes: vec![],
            hooks: vec![],
            is_builtin: false,
        };
        let b = DatatypeDeclaration {
            id: "b".to_string(),
            version: "1.0.0".to_string(),
            dependencies: vec!["a".to_string()],
            data_entries: vec![],
            indexes: vec![],
            hooks: vec![],
            is_builtin: false,
        };

        reg.register(a).unwrap();
        reg.register(b).unwrap();

        let err = reg.load_order().unwrap_err();
        let msg = err.to_string();
        assert!(
            msg.contains("circular dependency"),
            "expected CircularDependency, got: {msg}"
        );
        assert!(
            msg.contains('a') && msg.contains('b'),
            "cycle should mention a and b: {msg}"
        );
    }

    /// TC-1-ENGINE-004: extension filtering by enabled_extensions.
    #[test]
    fn tc_1_engine_004_extension_by_enabled() {
        let mut reg = DatatypeRegistry::new();
        register_builtins(&mut reg);

        // Register two extensions.
        reg.register(extension_decl("mutable", vec!["message"]))
            .unwrap();
        reg.register(extension_decl("collaborative", vec!["mutable"]))
            .unwrap();

        // Room with no extensions enabled: only builtins.
        let order_none = reg.load_order_for_room(&[]).unwrap();
        assert_eq!(order_none, vec!["identity", "room", "timeline", "message"]);
        assert!(!order_none.contains(&"mutable".to_string()));
        assert!(!order_none.contains(&"collaborative".to_string()));

        // Room with mutable enabled.
        let order_mut = reg.load_order_for_room(&["mutable".to_string()]).unwrap();
        assert!(order_mut.contains(&"mutable".to_string()));
        assert!(!order_mut.contains(&"collaborative".to_string()));
        // mutable should come after message.
        let msg_pos = order_mut.iter().position(|x| x == "message").unwrap();
        let mut_pos = order_mut.iter().position(|x| x == "mutable").unwrap();
        assert!(mut_pos > msg_pos, "mutable should load after message");

        // Room with both enabled.
        let order_both = reg
            .load_order_for_room(&["mutable".to_string(), "collaborative".to_string()])
            .unwrap();
        assert!(order_both.contains(&"mutable".to_string()));
        assert!(order_both.contains(&"collaborative".to_string()));
        let mut_pos2 = order_both.iter().position(|x| x == "mutable").unwrap();
        let col_pos = order_both
            .iter()
            .position(|x| x == "collaborative")
            .unwrap();
        assert!(
            col_pos > mut_pos2,
            "collaborative should load after mutable"
        );
    }

    /// TC-1-ENGINE-005: enabling an extension whose dependency is not met.
    #[test]
    fn tc_1_engine_005_extension_dependency_not_met() {
        let mut reg = DatatypeRegistry::new();
        register_builtins(&mut reg);

        reg.register(extension_decl("mutable", vec!["message"]))
            .unwrap();
        reg.register(extension_decl("collaborative", vec!["mutable"]))
            .unwrap();

        // Enable collaborative without mutable → dependency not met.
        let err = reg
            .load_order_for_room(&["collaborative".to_string()])
            .unwrap_err();
        let msg = err.to_string();
        assert!(
            msg.contains("dependency not met"),
            "expected DependencyNotMet, got: {msg}"
        );
        assert!(
            msg.contains("collaborative") && msg.contains("mutable"),
            "error should mention collaborative and mutable: {msg}"
        );
    }

    /// TC-1-ENGINE-006 is in datatype.rs (five_storage_types).

    #[test]
    fn duplicate_registration_rejected() {
        let mut reg = DatatypeRegistry::new();
        reg.register(builtin_decl("identity", vec![])).unwrap();

        let err = reg.register(builtin_decl("identity", vec![])).unwrap_err();
        assert!(err.to_string().contains("duplicate datatype"));
    }

    #[test]
    fn get_nonexistent_returns_none() {
        let reg = DatatypeRegistry::new();
        assert!(reg.get("nonexistent").is_none());
    }

    #[test]
    fn ids_returns_all_registered() {
        let mut reg = DatatypeRegistry::new();
        register_builtins(&mut reg);

        let mut ids = reg.ids();
        ids.sort();
        assert_eq!(ids, vec!["identity", "message", "room", "timeline"]);
    }

    #[test]
    fn empty_registry_load_order() {
        let reg = DatatypeRegistry::new();
        let order = reg.load_order().unwrap();
        assert!(order.is_empty());
    }

    #[test]
    fn load_order_for_room_with_all_extensions_enabled() {
        let mut reg = DatatypeRegistry::new();
        register_builtins(&mut reg);

        reg.register(extension_decl("mutable", vec!["message"]))
            .unwrap();
        reg.register(extension_decl("collaborative", vec!["mutable"]))
            .unwrap();
        reg.register(extension_decl("reactions", vec!["message"]))
            .unwrap();

        let order = reg
            .load_order_for_room(&[
                "mutable".to_string(),
                "collaborative".to_string(),
                "reactions".to_string(),
            ])
            .unwrap();

        // All 7 datatypes present.
        assert_eq!(order.len(), 7);
        // Builtins first.
        assert_eq!(&order[..4], &["identity", "room", "timeline", "message"]);
        // collaborative after mutable.
        let mut_pos = order.iter().position(|x| x == "mutable").unwrap();
        let col_pos = order.iter().position(|x| x == "collaborative").unwrap();
        assert!(col_pos > mut_pos);
    }

    #[test]
    fn default_impl() {
        let reg = DatatypeRegistry::default();
        assert!(reg.ids().is_empty());
    }

    #[test]
    fn index_declaration_in_datatype() {
        let decl = DatatypeDeclaration {
            id: "timeline".to_string(),
            version: "1.0.0".to_string(),
            dependencies: vec!["identity".to_string(), "room".to_string()],
            data_entries: vec![DataEntry {
                id: "shard".to_string(),
                storage_type: StorageType::CrdtArray,
                key_pattern: KeyPattern::new("room/{room_id}/index/{shard_id}"),
                persistent: true,
                writer_rule: WriterRule::SignerInMembers,
                sync_strategy: SyncMode::Eager,
            }],
            indexes: vec![IndexDeclaration {
                id: "by_author".to_string(),
                input: "shard".to_string(),
                transform: "group_by(author)".to_string(),
                refresh: RefreshStrategy::OnChange,
                operation_id: None,
            }],
            hooks: vec![],
            is_builtin: true,
        };

        assert_eq!(decl.indexes.len(), 1);
        assert_eq!(decl.indexes[0].id, "by_author");
        assert_eq!(decl.indexes[0].refresh, RefreshStrategy::OnChange);
    }
}
