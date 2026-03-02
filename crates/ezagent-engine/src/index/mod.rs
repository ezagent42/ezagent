//! Index Builder (bus-spec §3.4).
//!
//! The Index Builder maintains derived, queryable views of data entries.
//! Each index is declared by a Datatype via [`IndexDeclaration`] and refreshed
//! according to its [`RefreshStrategy`]:
//!
//! - **OnChange** — always included in the refresh list (re-evaluated whenever
//!   the underlying data changes).
//! - **OnDemand** — never auto-refreshes; only refreshed via explicit request.
//! - **Periodic** — included in the refresh list once the configured interval
//!   has elapsed since the last refresh.

pub mod refresh;

use std::time::Instant;

use crate::registry::datatype::{IndexDeclaration, RefreshStrategy};

/// A single entry in the [`IndexBuilder`], pairing an [`IndexDeclaration`]
/// with bookkeeping state (last refresh timestamp).
#[derive(Debug)]
pub struct IndexEntry {
    /// The index declaration from the Datatype.
    pub declaration: IndexDeclaration,
    /// When this index was last refreshed. `None` means it has never been
    /// refreshed.
    pub last_refresh: Option<Instant>,
}

/// Manages a collection of indexes and determines which need refreshing.
#[derive(Debug, Default)]
pub struct IndexBuilder {
    indexes: Vec<IndexEntry>,
}

impl IndexBuilder {
    /// Create a new, empty `IndexBuilder`.
    pub fn new() -> Self {
        Self {
            indexes: Vec::new(),
        }
    }

    /// Register an index declaration. The index starts with no recorded
    /// refresh time (i.e., it has never been refreshed).
    pub fn register(&mut self, decl: IndexDeclaration) {
        self.indexes.push(IndexEntry {
            declaration: decl,
            last_refresh: None,
        });
    }

    /// Look up an index entry by its declaration id.
    pub fn get(&self, id: &str) -> Option<&IndexEntry> {
        self.indexes.iter().find(|e| e.declaration.id == id)
    }

    /// Returns references to indexes that need refreshing according to their
    /// strategy:
    ///
    /// - **OnChange** — always needs refresh (included every time).
    /// - **Periodic** — needs refresh if the interval has elapsed since the
    ///   last refresh, or if never refreshed.
    /// - **OnDemand** — never auto-refreshes (excluded from this list).
    pub fn indexes_needing_refresh(&self) -> Vec<&IndexEntry> {
        let now = Instant::now();

        self.indexes
            .iter()
            .filter(|entry| match &entry.declaration.refresh {
                RefreshStrategy::OnChange => true,
                RefreshStrategy::OnDemand => false,
                RefreshStrategy::Periodic { interval_secs } => {
                    match entry.last_refresh {
                        None => true, // Never refreshed — needs refresh.
                        Some(last) => {
                            now.duration_since(last).as_secs() >= *interval_secs
                        }
                    }
                }
            })
            .collect()
    }

    /// Mark an index as freshly refreshed (sets `last_refresh` to now).
    pub fn mark_refreshed(&mut self, id: &str) {
        if let Some(entry) = self.indexes.iter_mut().find(|e| e.declaration.id == id) {
            entry.last_refresh = Some(Instant::now());
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Helper to create a minimal `IndexDeclaration` with the given id and
    /// refresh strategy.
    fn make_index(id: &str, refresh: RefreshStrategy) -> IndexDeclaration {
        IndexDeclaration {
            id: id.to_string(),
            input: "messages".to_string(),
            transform: "identity".to_string(),
            refresh,
            operation_id: None,
        }
    }

    /// TC-1-INDEX-001: register and retrieve an index.
    #[test]
    fn tc_1_index_001_register_index() {
        let mut builder = IndexBuilder::new();
        let decl = make_index("idx-1", RefreshStrategy::OnChange);
        builder.register(decl);

        let entry = builder.get("idx-1");
        assert!(entry.is_some(), "registered index should be retrievable");
        let entry = entry.unwrap();
        assert_eq!(entry.declaration.id, "idx-1");
        assert_eq!(entry.declaration.input, "messages");
        assert!(entry.last_refresh.is_none(), "newly registered index should have no last_refresh");

        // Non-existent index returns None.
        assert!(builder.get("nonexistent").is_none());
    }

    /// TC-1-INDEX-002: OnChange indexes are always in the refresh list.
    #[test]
    fn tc_1_index_002_on_change_always_needs_refresh() {
        let mut builder = IndexBuilder::new();
        builder.register(make_index("on-change-idx", RefreshStrategy::OnChange));

        // Before any refresh.
        let needing = builder.indexes_needing_refresh();
        assert_eq!(needing.len(), 1);
        assert_eq!(needing[0].declaration.id, "on-change-idx");

        // After marking refreshed, OnChange should STILL need refresh.
        builder.mark_refreshed("on-change-idx");
        let needing = builder.indexes_needing_refresh();
        assert_eq!(needing.len(), 1, "OnChange should always appear in refresh list");
        assert_eq!(needing[0].declaration.id, "on-change-idx");
    }

    /// TC-1-INDEX-003: OnDemand indexes are never in the auto-refresh list.
    #[test]
    fn tc_1_index_003_on_demand_never_auto_refreshes() {
        let mut builder = IndexBuilder::new();
        builder.register(make_index("on-demand-idx", RefreshStrategy::OnDemand));

        let needing = builder.indexes_needing_refresh();
        assert!(
            needing.is_empty(),
            "OnDemand indexes should never appear in auto-refresh list"
        );

        // Even after some time, OnDemand should still not auto-refresh.
        // (mark_refreshed is a no-op in terms of auto-refresh behavior)
        builder.mark_refreshed("on-demand-idx");
        let needing = builder.indexes_needing_refresh();
        assert!(
            needing.is_empty(),
            "OnDemand indexes should never appear in auto-refresh list even after mark_refreshed"
        );
    }
}
