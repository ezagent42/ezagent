//! Cross-extension interaction tests.
//!
//! These integration tests verify that extensions work together correctly,
//! not just in isolation. They test URI path conflict detection, dependency
//! ordering, manifest cross-validation, hook priority ranges, and the
//! full 17-extension registry.
//!
//! These tests use the `rlib` side of each extension crate directly
//! (no cdylib / dlopen required), so they are NOT `#[ignore]`.

use std::collections::{HashMap, HashSet};
use std::path::PathBuf;

use ezagent_engine::loader;
use ezagent_engine::uri_registry::UriPathRegistry;
use ezagent_ext_api::prelude::*;

// Import all 17 extension plugin types.
use ezagent_ext_channels::ChannelsExtension;
use ezagent_ext_collab::CollabExtension;
use ezagent_ext_command::CommandExtension;
use ezagent_ext_cross_room_ref::CrossRoomRefExtension;
use ezagent_ext_drafts::DraftsExtension;
use ezagent_ext_link_preview::LinkPreviewExtension;
use ezagent_ext_media::MediaExtension;
use ezagent_ext_moderation::ModerationExtension;
use ezagent_ext_mutable::MutableExtension;
use ezagent_ext_presence::PresenceExtension;
use ezagent_ext_profile::ProfileExtension;
use ezagent_ext_reactions::ReactionsExtension;
use ezagent_ext_receipts::ReceiptsExtension;
use ezagent_ext_reply_to::ReplyToExtension;
use ezagent_ext_runtime::RuntimeExtension;
use ezagent_ext_threads::ThreadsExtension;
use ezagent_ext_watch::WatchExtension;

/// Helper: collect all 17 extension plugins as trait objects.
fn all_extensions() -> Vec<Box<dyn ExtensionPlugin>> {
    vec![
        Box::new(ReactionsExtension::default()),
        Box::new(ChannelsExtension::default()),
        Box::new(ModerationExtension::default()),
        Box::new(ReceiptsExtension::default()),
        Box::new(PresenceExtension::default()),
        Box::new(MediaExtension::default()),
        Box::new(DraftsExtension::default()),
        Box::new(ProfileExtension::default()),
        Box::new(LinkPreviewExtension::default()),
        Box::new(MutableExtension::default()),
        Box::new(ReplyToExtension::default()),
        Box::new(CommandExtension::default()),
        Box::new(CollabExtension::default()),
        Box::new(CrossRoomRefExtension::default()),
        Box::new(ThreadsExtension::default()),
        Box::new(WatchExtension::default()),
        Box::new(RuntimeExtension::default()),
    ]
}

/// TC-2-INTERACT-001: URI path conflict detection.
///
/// Tests that the `UriPathRegistry` correctly detects conflicts when two
/// extensions register overlapping URI patterns.
///
/// - Register `/r/{room_id}/m/{ref_id}/reactions` (from reactions)
/// - Register `/r/{room_id}/m/{ref_id}/thread` (from threads) -- should succeed
///   (different literal segment)
/// - Attempt to register `/r/{room_id}/m/{ref_id}/reactions` again -- should
///   fail with conflict
#[test]
fn tc_2_interact_001_uri_conflict_detection() {
    let mut registry = UriPathRegistry::new();

    // Register first pattern (reactions).
    registry
        .register("/r/{room_id}/m/{ref_id}/reactions", "reactions")
        .expect("first registration should succeed");

    // Different last segment should succeed (threads).
    registry
        .register("/r/{room_id}/m/{ref_id}/thread", "threads")
        .expect("different literal segment should not conflict");

    // Duplicate pattern from a different extension should fail.
    let err = registry
        .register("/r/{room_id}/m/{ref_id}/reactions", "other")
        .expect_err("duplicate pattern from different extension should fail");

    // Verify the error mentions the conflict.
    let err_str = format!("{err}");
    assert!(
        err_str.contains("reactions") || err_str.contains("conflict"),
        "error should mention conflict: {err_str}"
    );
}

/// TC-2-INTERACT-002: Extension dependency ordering.
///
/// Tests that `resolve_extension_order` correctly orders extensions by
/// dependency. Creates manifests for:
/// - `reply-to` (no deps)
/// - `threads` (depends on `reply-to`)
/// - `runtime` (depends on `channels`, `reply-to`, `command`)
/// - `channels` (no deps)
/// - `command` (no deps)
///
/// Verifies:
/// - `reply-to` appears before `threads`
/// - `channels`, `reply-to`, and `command` all appear before `runtime`
#[test]
fn tc_2_interact_002_dependency_ordering() {
    // Build manifests with dependencies, paired with dummy PathBufs.
    let manifests: Vec<(PathBuf, ExtensionManifest)> = vec![
        (
            PathBuf::from("reply-to"),
            ExtensionManifest {
                name: "reply-to".to_string(),
                version: "0.1.0".to_string(),
                api_version: 1,
                datatype_declarations: vec![],
                hook_declarations: vec!["reply_to.inject".to_string()],
                ext_dependencies: vec![],
                uri_paths: vec![],
            },
        ),
        (
            PathBuf::from("threads"),
            ExtensionManifest {
                name: "threads".to_string(),
                version: "0.1.0".to_string(),
                api_version: 1,
                datatype_declarations: vec![],
                hook_declarations: vec!["threads.inject".to_string()],
                ext_dependencies: vec!["reply-to".to_string()],
                uri_paths: vec![],
            },
        ),
        (
            PathBuf::from("runtime"),
            ExtensionManifest {
                name: "runtime".to_string(),
                version: "0.1.0".to_string(),
                api_version: 1,
                datatype_declarations: vec![],
                hook_declarations: vec!["runtime.namespace_check".to_string()],
                ext_dependencies: vec![
                    "channels".to_string(),
                    "reply-to".to_string(),
                    "command".to_string(),
                ],
                uri_paths: vec![],
            },
        ),
        (
            PathBuf::from("channels"),
            ExtensionManifest {
                name: "channels".to_string(),
                version: "0.1.0".to_string(),
                api_version: 1,
                datatype_declarations: vec![],
                hook_declarations: vec!["channels.inject_tags".to_string()],
                ext_dependencies: vec![],
                uri_paths: vec![],
            },
        ),
        (
            PathBuf::from("command"),
            ExtensionManifest {
                name: "command".to_string(),
                version: "0.1.0".to_string(),
                api_version: 1,
                datatype_declarations: vec![],
                hook_declarations: vec!["command.validate".to_string()],
                ext_dependencies: vec![],
                uri_paths: vec![],
            },
        ),
    ];

    let order =
        loader::resolve_extension_order(&manifests).expect("dependency resolution should succeed");

    assert_eq!(order.len(), 5, "all 5 extensions should be in the order");

    // reply-to must appear before threads.
    let reply_to_pos = order
        .iter()
        .position(|n| n == "reply-to")
        .expect("reply-to in order");
    let threads_pos = order
        .iter()
        .position(|n| n == "threads")
        .expect("threads in order");
    assert!(
        reply_to_pos < threads_pos,
        "reply-to ({reply_to_pos}) must come before threads ({threads_pos})"
    );

    // channels, reply-to, and command must all appear before runtime.
    let runtime_pos = order
        .iter()
        .position(|n| n == "runtime")
        .expect("runtime in order");
    let channels_pos = order
        .iter()
        .position(|n| n == "channels")
        .expect("channels in order");
    let command_pos = order
        .iter()
        .position(|n| n == "command")
        .expect("command in order");

    assert!(
        channels_pos < runtime_pos,
        "channels ({channels_pos}) must come before runtime ({runtime_pos})"
    );
    assert!(
        reply_to_pos < runtime_pos,
        "reply-to ({reply_to_pos}) must come before runtime ({runtime_pos})"
    );
    assert!(
        command_pos < runtime_pos,
        "command ({command_pos}) must come before runtime ({runtime_pos})"
    );
}

/// TC-2-INTERACT-003: Manifest cross-validation across all extensions.
///
/// Loads all 17 extension manifests and verifies that there are no
/// duplicate hook IDs or duplicate datatype IDs across the full set.
#[test]
fn tc_2_interact_003_no_duplicate_hooks_or_datatypes() {
    let extensions = all_extensions();

    // Collect all hook declarations.
    let mut all_hooks: Vec<(String, String)> = Vec::new(); // (hook_id, ext_name)
    let mut all_datatypes: Vec<(String, String)> = Vec::new(); // (dt_id, ext_name)

    for ext in &extensions {
        let m = ext.manifest();
        for hook in &m.hook_declarations {
            all_hooks.push((hook.clone(), m.name.clone()));
        }
        for dt in &m.datatype_declarations {
            all_datatypes.push((dt.clone(), m.name.clone()));
        }
    }

    // Assert no duplicate hook IDs.
    let mut seen_hooks: HashMap<&str, &str> = HashMap::new();
    for (hook_id, ext_name) in &all_hooks {
        if let Some(prev_ext) = seen_hooks.insert(hook_id.as_str(), ext_name.as_str()) {
            panic!("duplicate hook ID '{hook_id}': declared by both '{prev_ext}' and '{ext_name}'");
        }
    }

    // Assert no duplicate datatype IDs.
    let mut seen_datatypes: HashMap<&str, &str> = HashMap::new();
    for (dt_id, ext_name) in &all_datatypes {
        if let Some(prev_ext) = seen_datatypes.insert(dt_id.as_str(), ext_name.as_str()) {
            panic!(
                "duplicate datatype ID '{dt_id}': declared by both '{prev_ext}' and '{ext_name}'"
            );
        }
    }

    // Verify we collected a reasonable number of hooks and datatypes.
    assert!(
        all_hooks.len() >= 17,
        "expected at least 17 hook declarations across all extensions, got {}",
        all_hooks.len()
    );
    assert!(
        all_datatypes.len() >= 5,
        "expected at least 5 datatype declarations across all extensions, got {}",
        all_datatypes.len()
    );
}

/// TC-2-INTERACT-004: Hook priority ordering correctness.
///
/// Tests that hook priorities across all extensions follow the spec ranges:
/// - Extension PreSend: 20-49 (except drafts.clear_on_send at 90)
/// - Extension AfterWrite: 35-50
/// - Extension AfterRead: 45-70
/// - Drafts `clear_on_send`: exactly 90 (cleanup range)
///
/// Registers hooks from all extensions and verifies they sort correctly
/// by priority within each phase.
#[test]
fn tc_2_interact_004_hook_priority_ranges() {
    let extensions = all_extensions();

    // Collect all hook JSONs from all extensions.
    let mut pre_send_hooks: Vec<(String, i64)> = Vec::new(); // (id, priority)
    let mut after_write_hooks: Vec<(String, i64)> = Vec::new();
    let mut after_read_hooks: Vec<(String, i64)> = Vec::new();

    for ext in &extensions {
        let mut ctx = RegistrationContext::new();
        ext.register(&mut ctx)
            .unwrap_or_else(|e| panic!("register failed for '{}': {e}", ext.manifest().name));

        for hook_json in ctx.hook_jsons() {
            let parsed: serde_json::Value =
                serde_json::from_str(hook_json).expect("hook JSON should be valid");

            let id = parsed["id"]
                .as_str()
                .expect("hook should have 'id'")
                .to_string();
            let phase = parsed["phase"].as_str().expect("hook should have 'phase'");
            let priority = parsed["priority"]
                .as_i64()
                .expect("hook should have 'priority'");

            match phase {
                "PreSend" => pre_send_hooks.push((id, priority)),
                "AfterWrite" => after_write_hooks.push((id, priority)),
                "AfterRead" => after_read_hooks.push((id, priority)),
                other => panic!("unexpected hook phase: {other}"),
            }
        }
    }

    // Verify PreSend priorities: 20-49 for normal, 90 for drafts.clear_on_send.
    for (id, priority) in &pre_send_hooks {
        if id == "drafts.clear_on_send" {
            assert_eq!(
                *priority, 90,
                "drafts.clear_on_send should have priority 90, got {priority}"
            );
        } else {
            assert!(
                (20..=49).contains(priority),
                "PreSend hook '{id}' has priority {priority}, expected 20-49"
            );
        }
    }

    // Verify AfterWrite priorities: 35-50.
    for (id, priority) in &after_write_hooks {
        assert!(
            (35..=50).contains(priority),
            "AfterWrite hook '{id}' has priority {priority}, expected 35-50"
        );
    }

    // Verify AfterRead priorities: 45-70.
    for (id, priority) in &after_read_hooks {
        assert!(
            (45..=70).contains(priority),
            "AfterRead hook '{id}' has priority {priority}, expected 45-70"
        );
    }

    // Verify hooks within each phase are sortable by priority (no collisions
    // in the sense that the sorted order is deterministic within a phase when
    // IDs are used as tie-breakers).
    let mut pre_send_sorted = pre_send_hooks.clone();
    pre_send_sorted.sort_by(|a, b| a.1.cmp(&b.1).then_with(|| a.0.cmp(&b.0)));
    // Just verify the sort succeeds and produces the same length.
    assert_eq!(pre_send_sorted.len(), pre_send_hooks.len());

    let mut after_write_sorted = after_write_hooks.clone();
    after_write_sorted.sort_by(|a, b| a.1.cmp(&b.1).then_with(|| a.0.cmp(&b.0)));
    assert_eq!(after_write_sorted.len(), after_write_hooks.len());

    let mut after_read_sorted = after_read_hooks.clone();
    after_read_sorted.sort_by(|a, b| a.1.cmp(&b.1).then_with(|| a.0.cmp(&b.0)));
    assert_eq!(after_read_sorted.len(), after_read_hooks.len());

    // Verify we have hooks in each phase.
    assert!(
        !pre_send_hooks.is_empty(),
        "should have at least one PreSend hook"
    );
    assert!(
        !after_write_hooks.is_empty(),
        "should have at least one AfterWrite hook"
    );
    assert!(
        !after_read_hooks.is_empty(),
        "should have at least one AfterRead hook"
    );
}

/// TC-2-INTERACT-005: Full manifest registry (all 17 extensions).
///
/// Loads all 17 extension manifests and verifies the complete set:
/// - Exactly 17 extensions
/// - All unique names
/// - All api_version == 1
/// - Known extension names match the expected set
/// - URI paths: reactions, threads, media, profile, channels, runtime
///   all have URI paths; others don't
#[test]
fn tc_2_interact_005_full_manifest_registry() {
    let extensions = all_extensions();

    // Verify exactly 17 extensions.
    assert_eq!(
        extensions.len(),
        17,
        "should have exactly 17 extensions, got {}",
        extensions.len()
    );

    // Collect all names.
    let names: Vec<String> = extensions
        .iter()
        .map(|e| e.manifest().name.clone())
        .collect();

    // Verify all unique.
    let unique_names: HashSet<&str> = names.iter().map(|n| n.as_str()).collect();
    assert_eq!(
        unique_names.len(),
        17,
        "all 17 extension names should be unique, got {} unique out of {}",
        unique_names.len(),
        names.len()
    );

    // Verify all api_version == 1.
    for ext in &extensions {
        let m = ext.manifest();
        assert_eq!(
            m.api_version, 1,
            "extension '{}' should have api_version=1, got {}",
            m.name, m.api_version
        );
    }

    // Verify the known set of extension names.
    // Note: the receipts extension's manifest name is "read-receipts".
    let expected_names: HashSet<&str> = [
        "reactions",
        "channels",
        "moderation",
        "read-receipts",
        "presence",
        "media",
        "drafts",
        "profile",
        "link-preview",
        "mutable",
        "reply-to",
        "command",
        "collab",
        "cross-room-ref",
        "threads",
        "watch",
        "runtime",
    ]
    .iter()
    .copied()
    .collect();

    assert_eq!(
        unique_names, expected_names,
        "extension names mismatch.\n  Expected: {expected_names:?}\n  Got: {unique_names:?}"
    );

    // Verify URI paths: these extensions should have URI paths.
    let extensions_with_uri: HashSet<&str> = [
        "reactions",
        "threads",
        "media",
        "profile",
        "channels",
        "runtime",
    ]
    .iter()
    .copied()
    .collect();

    for ext in &extensions {
        let m = ext.manifest();
        if extensions_with_uri.contains(m.name.as_str()) {
            assert!(
                !m.uri_paths.is_empty(),
                "extension '{}' should have URI paths but has none",
                m.name
            );
        } else {
            assert!(
                m.uri_paths.is_empty(),
                "extension '{}' should NOT have URI paths but has {:?}",
                m.name,
                m.uri_paths
            );
        }
    }

    // Verify all URI paths can be registered without conflicts.
    let mut registry = UriPathRegistry::new();
    for ext in &extensions {
        let m = ext.manifest();
        for uri_path in &m.uri_paths {
            registry
                .register(&uri_path.pattern, &m.name)
                .unwrap_or_else(|e| {
                    panic!(
                        "URI path '{}' from '{}' should register without conflict: {e}",
                        uri_path.pattern, m.name
                    )
                });
        }
    }

    // Verify all extensions can be resolved in dependency order.
    let manifests: Vec<(PathBuf, ExtensionManifest)> = extensions
        .iter()
        .map(|ext| {
            let m = ext.manifest().clone();
            (PathBuf::from(&m.name), m)
        })
        .collect();

    let order = loader::resolve_extension_order(&manifests)
        .expect("all 17 extensions should resolve without dependency errors");

    assert_eq!(
        order.len(),
        17,
        "resolved order should contain all 17 extensions"
    );
}
