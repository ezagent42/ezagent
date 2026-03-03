//! URI Path Registry for extension URI routing.
//!
//! Maps extension URI patterns to extension IDs and detects conflicts
//! per extensions-spec section 1.2.3. Each extension can register one or more URI
//! patterns (e.g. `/r/{room_id}/m/{ref_id}/reactions`), and the registry
//! ensures that no two extensions claim conflicting patterns.
//!
//! A conflict occurs when two patterns have the same number of segments and
//! every corresponding segment pair either matches literally or both segments
//! are placeholders (`{...}`).

use crate::error::EngineError;

/// A single registered URI pattern entry.
struct UriPathEntry {
    /// The URI pattern string, e.g. `/r/{room_id}/m/{ref_id}/reactions`.
    pattern: String,
    /// The extension ID that owns this pattern.
    extension_id: String,
}

/// Registry of extension URI patterns with conflict detection and path resolution.
///
/// Extensions register URI patterns via [`UriPathRegistry::register`]. The registry
/// ensures no two extensions claim patterns that would match the same concrete paths.
/// At runtime, [`UriPathRegistry::resolve`] maps a concrete path to the owning
/// extension ID.
#[derive(Default)]
pub struct UriPathRegistry {
    entries: Vec<UriPathEntry>,
}

impl UriPathRegistry {
    /// Create an empty URI path registry.
    pub fn new() -> Self {
        Self {
            entries: Vec::new(),
        }
    }

    /// Register a URI pattern for an extension.
    ///
    /// Checks all existing entries for conflicts before inserting. Two patterns
    /// conflict if they have the same segment count and every segment pair
    /// either matches literally or both are placeholders.
    ///
    /// # Errors
    ///
    /// Returns [`EngineError::UriPathConflict`] if the pattern conflicts with
    /// a pattern already registered by a different extension.
    pub fn register(&mut self, pattern: &str, extension_id: &str) -> Result<(), EngineError> {
        for entry in &self.entries {
            if entry.extension_id == extension_id {
                // Same extension re-registering — allow (idempotent).
                continue;
            }
            if patterns_conflict(pattern, &entry.pattern) {
                return Err(EngineError::UriPathConflict {
                    pattern: pattern.to_string(),
                    ext_a: entry.extension_id.clone(),
                    ext_b: extension_id.to_string(),
                });
            }
        }
        self.entries.push(UriPathEntry {
            pattern: pattern.to_string(),
            extension_id: extension_id.to_string(),
        });
        Ok(())
    }

    /// Resolve a concrete path to the extension ID that owns it.
    ///
    /// Returns `None` if no registered pattern matches the path.
    pub fn resolve(&self, path: &str) -> Option<&str> {
        for entry in &self.entries {
            if path_matches_pattern(path, &entry.pattern) {
                return Some(&entry.extension_id);
            }
        }
        None
    }

    /// List all registered (pattern, extension_id) pairs.
    pub fn entries(&self) -> Vec<(&str, &str)> {
        self.entries
            .iter()
            .map(|e| (e.pattern.as_str(), e.extension_id.as_str()))
            .collect()
    }
}

/// Split a path into segments, trimming the leading `/`.
fn segments(path: &str) -> Vec<&str> {
    let trimmed = path.strip_prefix('/').unwrap_or(path);
    if trimmed.is_empty() {
        return Vec::new();
    }
    trimmed.split('/').collect()
}

/// Check whether a segment contains a placeholder (e.g. `@{entity_id}`).
///
/// Returns `true` if the segment has `{...}` anywhere within it.
fn contains_placeholder(seg: &str) -> bool {
    if let Some(start) = seg.find('{') {
        seg[start..].contains('}')
    } else {
        false
    }
}

/// Extract the literal prefix before any placeholder in a segment.
///
/// For `@{entity_id}` returns `Some("@")`. For `{room_id}` returns `Some("")`.
/// For a pure literal like `profile` returns `None`.
fn placeholder_prefix(seg: &str) -> Option<&str> {
    seg.find('{').map(|idx| &seg[..idx])
}

/// Check whether two segments can match overlapping sets of concrete values.
///
/// Two segments overlap if:
/// - Both contain placeholders and share the same literal prefix, OR
/// - One contains a placeholder whose prefix is compatible with the other segment, OR
/// - Both are pure literals and are identical.
fn segments_overlap(a: &str, b: &str) -> bool {
    let a_has = contains_placeholder(a);
    let b_has = contains_placeholder(b);

    if a_has && b_has {
        // Both have placeholders — they overlap if they share the same literal prefix.
        let prefix_a = placeholder_prefix(a).unwrap_or("");
        let prefix_b = placeholder_prefix(b).unwrap_or("");
        prefix_a == prefix_b
    } else if a_has {
        // `a` has a placeholder, `b` is pure literal.
        // They overlap if `b` starts with `a`'s literal prefix.
        let prefix = placeholder_prefix(a).unwrap_or("");
        b.starts_with(prefix)
    } else if b_has {
        // `b` has a placeholder, `a` is pure literal.
        let prefix = placeholder_prefix(b).unwrap_or("");
        a.starts_with(prefix)
    } else {
        // Both pure literals.
        a == b
    }
}

/// Determine whether two URI patterns conflict.
///
/// Two patterns conflict if they have the same number of segments and every
/// corresponding segment pair overlaps (i.e. can match the same concrete value).
/// This means both patterns would match the same set of concrete paths.
fn patterns_conflict(a: &str, b: &str) -> bool {
    let segs_a = segments(a);
    let segs_b = segments(b);

    if segs_a.len() != segs_b.len() {
        return false;
    }

    segs_a
        .iter()
        .zip(segs_b.iter())
        .all(|(sa, sb)| segments_overlap(sa, sb))
}

/// Determine whether a concrete path matches a URI pattern.
///
/// A path matches a pattern if they have the same number of segments and every
/// concrete segment either matches the pattern segment literally, or the pattern
/// segment contains a placeholder and the concrete segment starts with the
/// placeholder's literal prefix.
fn path_matches_pattern(path: &str, pattern: &str) -> bool {
    let path_segs = segments(path);
    let pattern_segs = segments(pattern);

    if path_segs.len() != pattern_segs.len() {
        return false;
    }

    path_segs
        .iter()
        .zip(pattern_segs.iter())
        .all(|(ps, pt)| {
            if contains_placeholder(pt) {
                let prefix = placeholder_prefix(pt).unwrap_or("");
                ps.starts_with(prefix)
            } else {
                ps == pt
            }
        })
}

#[cfg(test)]
mod tests {
    use super::*;

    /// TC-2-URI-001: Conflict detection.
    ///
    /// Register `/r/{room_id}/c/{channel_name}` for "ext-a", then same pattern
    /// for "ext-b" -> must return `EngineError::UriPathConflict` with correct fields.
    #[test]
    fn tc_2_uri_001_conflict_detection() {
        let mut reg = UriPathRegistry::new();
        reg.register("/r/{room_id}/c/{channel_name}", "ext-a")
            .expect("first registration should succeed");

        let err = reg
            .register("/r/{room_id}/c/{channel_name}", "ext-b")
            .expect_err("duplicate pattern from different extension should fail");

        match err {
            EngineError::UriPathConflict {
                pattern,
                ext_a,
                ext_b,
            } => {
                assert_eq!(pattern, "/r/{room_id}/c/{channel_name}");
                assert_eq!(ext_a, "ext-a");
                assert_eq!(ext_b, "ext-b");
            }
            other => panic!("expected UriPathConflict, got: {other:?}"),
        }
    }

    /// TC-2-URI-002: Non-conflicting patterns register successfully.
    ///
    /// Register 4 patterns with different structures without error.
    #[test]
    fn tc_2_uri_002_non_conflicting_patterns() {
        let mut reg = UriPathRegistry::new();

        reg.register("/r/{room_id}/m/{ref_id}/reactions", "reactions")
            .expect("reactions pattern should register");
        reg.register("/r/{room_id}/m/{ref_id}/thread", "threads")
            .expect("threads pattern should register");
        reg.register("/r/{room_id}/c/{channel_name}", "channels")
            .expect("channels pattern should register");
        reg.register("/@{entity_id}/profile", "profile")
            .expect("profile pattern should register");

        assert_eq!(reg.entries().len(), 4);
    }

    /// TC-2-URI-003: Extension without URI section loads fine.
    ///
    /// An empty registry has no entries, validating the "no [uri] section" case.
    #[test]
    fn tc_2_uri_003_no_uri_section() {
        let reg = UriPathRegistry::new();
        assert!(reg.entries().is_empty());
        assert!(reg.resolve("/any/path").is_none());
    }

    /// Resolve concrete paths to their owning extension IDs.
    #[test]
    fn resolve_concrete_path() {
        let mut reg = UriPathRegistry::new();

        reg.register("/r/{room_id}/m/{ref_id}/reactions", "reactions")
            .unwrap();
        reg.register("/r/{room_id}/m/{ref_id}/thread", "threads")
            .unwrap();
        reg.register("/r/{room_id}/c/{channel_name}", "channels")
            .unwrap();
        reg.register("/@{entity_id}/profile", "profile")
            .unwrap();

        // Concrete path matching reactions.
        assert_eq!(
            reg.resolve("/r/abc123/m/ref001/reactions"),
            Some("reactions")
        );

        // Concrete path matching channels.
        assert_eq!(reg.resolve("/r/abc123/c/general"), Some("channels"));

        // Concrete path matching profile.
        assert_eq!(reg.resolve("/@alice/profile"), Some("profile"));

        // Unknown path returns None.
        assert_eq!(reg.resolve("/unknown/path"), None);

        // Path with wrong segment count returns None.
        assert_eq!(reg.resolve("/r/abc123/m/ref001"), None);
    }

    /// Different-length patterns never conflict.
    #[test]
    fn different_length_patterns_dont_conflict() {
        let mut reg = UriPathRegistry::new();

        // 5 segments.
        reg.register("/r/{room_id}/m/{ref_id}/reactions", "reactions")
            .expect("reactions should register");

        // 4 segments — different length, cannot conflict.
        reg.register("/r/{room_id}/m/{ref_id}", "messages")
            .expect("messages should register (different segment count)");

        assert_eq!(reg.entries().len(), 2);
    }

    /// Placeholder-vs-placeholder at same positions conflicts.
    ///
    /// `/r/{room_id}/c/{name}` and `/r/{room_id}/c/{channel_name}` have the
    /// same structure — they would match the same concrete paths.
    #[test]
    fn placeholder_vs_literal_conflicts() {
        let mut reg = UriPathRegistry::new();

        reg.register("/r/{room_id}/c/{name}", "ext-a")
            .expect("first registration should succeed");

        let err = reg
            .register("/r/{room_id}/c/{channel_name}", "ext-b")
            .expect_err("same structure with different placeholder names should conflict");

        match err {
            EngineError::UriPathConflict {
                ext_a, ext_b, ..
            } => {
                assert_eq!(ext_a, "ext-a");
                assert_eq!(ext_b, "ext-b");
            }
            other => panic!("expected UriPathConflict, got: {other:?}"),
        }
    }

    /// Literal vs placeholder at the same position means they overlap
    /// (the placeholder matches the literal value).
    #[test]
    fn literal_vs_placeholder_conflicts() {
        let mut reg = UriPathRegistry::new();

        reg.register("/r/{room_id}/c/general", "ext-a")
            .expect("first registration should succeed");

        let err = reg
            .register("/r/{room_id}/c/{channel_name}", "ext-b")
            .expect_err("placeholder overlaps with literal at same position");

        match err {
            EngineError::UriPathConflict { .. } => {}
            other => panic!("expected UriPathConflict, got: {other:?}"),
        }
    }

    /// Same extension re-registering the same pattern is idempotent.
    #[test]
    fn same_extension_re_register_is_idempotent() {
        let mut reg = UriPathRegistry::new();

        reg.register("/r/{room_id}/c/{channel_name}", "channels")
            .expect("first registration should succeed");
        reg.register("/r/{room_id}/c/{channel_name}", "channels")
            .expect("re-registration by same extension should succeed");

        // Two entries exist (append-only), but both belong to the same extension.
        assert_eq!(reg.entries().len(), 2);
    }

    /// Default trait produces an empty registry.
    #[test]
    fn default_is_empty() {
        let reg = UriPathRegistry::default();
        assert!(reg.entries().is_empty());
    }

    /// patterns_conflict helper: unit-level tests.
    #[test]
    fn patterns_conflict_unit() {
        // Identical literal patterns conflict.
        assert!(patterns_conflict("/a/b/c", "/a/b/c"));

        // Different literals at same position do not conflict.
        assert!(!patterns_conflict("/a/b/c", "/a/b/d"));

        // Different segment counts never conflict.
        assert!(!patterns_conflict("/a/b", "/a/b/c"));

        // Both placeholders at every position conflict.
        assert!(patterns_conflict("/{x}/{y}", "/{a}/{b}"));

        // Mixed placeholder and literal — placeholder matches the literal.
        assert!(patterns_conflict("/{x}/b", "/a/b"));
    }

    /// path_matches_pattern helper: unit-level tests.
    #[test]
    fn path_matches_pattern_unit() {
        assert!(path_matches_pattern("/r/abc/m/ref1/reactions", "/r/{room_id}/m/{ref_id}/reactions"));
        assert!(!path_matches_pattern("/r/abc/m/ref1", "/r/{room_id}/m/{ref_id}/reactions"));
        assert!(!path_matches_pattern("/r/abc/m/ref1/thread", "/r/{room_id}/m/{ref_id}/reactions"));
        assert!(path_matches_pattern("/a/b", "/{x}/{y}"));
        assert!(path_matches_pattern("/a/b", "/a/b"));
        assert!(!path_matches_pattern("/a/b", "/a/c"));
    }
}
