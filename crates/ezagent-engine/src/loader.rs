//! Extension Loader — manifest scanning, API version filtering, and dependency
//! resolution for dynamic extension loading (bus-spec SS4.7).
//!
//! The loader implements the full extension loading pipeline:
//!
//! 1. **Scan** — discover `manifest.toml` files in extension subdirectories.
//! 2. **Filter** — reject extensions with incompatible API versions.
//! 3. **Resolve** — topologically sort extensions by declared dependencies.
//! 4. **Load** — `dlopen` each library and call the registration entry point.
//!
//! # Directory Layout
//!
//! ```text
//! extensions/
//! +-- reactions/
//! |   +-- manifest.toml
//! |   +-- libreactions.dylib   (or .so / .dll)
//! +-- channels/
//!     +-- manifest.toml
//!     +-- libchannels.so
//! ```

use std::collections::{HashMap, HashSet, VecDeque};
use std::path::{Path, PathBuf};

use ezagent_ext_api::{ExtensionManifest, ENGINE_API_VERSION};

/// Record of a successfully loaded extension.
#[derive(Debug, Clone)]
pub struct LoadedExtension {
    /// The extension's unique name.
    pub name: String,
    /// The extension's semantic version.
    pub version: String,
    /// The full parsed manifest.
    pub manifest: ExtensionManifest,
}

/// Record of an extension that failed to load.
#[derive(Debug, Clone)]
pub struct ExtensionLoadError {
    /// The extension name (or directory name if the manifest failed to parse).
    pub name: String,
    /// Human-readable reason for the failure.
    pub reason: String,
}

impl std::fmt::Display for ExtensionLoadError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "extension '{}' failed: {}", self.name, self.reason)
    }
}

/// Scan a directory for extension manifests.
///
/// Looks for `{dir}/*/manifest.toml` files. For each subdirectory that
/// contains a valid `manifest.toml`, the parsed manifest and its parent
/// path are returned. Invalid or missing manifests produce errors that
/// are collected but do not prevent other extensions from loading.
///
/// Returns a tuple of `(successes, errors)`.
pub fn scan_manifests(dir: &Path) -> (Vec<(PathBuf, ExtensionManifest)>, Vec<ExtensionLoadError>) {
    let mut successes = Vec::new();
    let mut errors = Vec::new();

    let entries = match std::fs::read_dir(dir) {
        Ok(entries) => entries,
        Err(e) => {
            log::warn!("cannot read extension directory {}: {}", dir.display(), e);
            return (successes, errors);
        }
    };

    for entry in entries {
        let entry = match entry {
            Ok(e) => e,
            Err(e) => {
                log::warn!("error reading directory entry in {}: {}", dir.display(), e);
                continue;
            }
        };

        let path = entry.path();
        if !path.is_dir() {
            continue;
        }

        let dir_name = match path.file_name().and_then(|n| n.to_str()) {
            Some(name) => name.to_string(),
            None => continue,
        };

        let manifest_path = path.join("manifest.toml");
        let toml_content = match std::fs::read_to_string(&manifest_path) {
            Ok(content) => content,
            Err(e) => {
                errors.push(ExtensionLoadError {
                    name: dir_name,
                    reason: format!("cannot read manifest.toml: {e}"),
                });
                continue;
            }
        };

        match ExtensionManifest::from_toml(&toml_content) {
            Ok(manifest) => {
                successes.push((path, manifest));
            }
            Err(e) => {
                errors.push(ExtensionLoadError {
                    name: dir_name,
                    reason: format!("manifest parse error: {e}"),
                });
            }
        }
    }

    (successes, errors)
}

/// Filter out extensions whose `api_version` does not match [`ENGINE_API_VERSION`].
///
/// Returns a tuple of `(compatible, errors)`. Extensions with incompatible
/// API versions are reported as errors.
pub fn filter_api_version(
    manifests: Vec<(PathBuf, ExtensionManifest)>,
) -> (Vec<(PathBuf, ExtensionManifest)>, Vec<ExtensionLoadError>) {
    let mut compatible = Vec::new();
    let mut errors = Vec::new();

    for (path, manifest) in manifests {
        if manifest.api_version == ENGINE_API_VERSION {
            compatible.push((path, manifest));
        } else {
            errors.push(ExtensionLoadError {
                name: manifest.name.clone(),
                reason: format!(
                    "incompatible API version: extension declares {}, engine requires {}",
                    manifest.api_version, ENGINE_API_VERSION
                ),
            });
        }
    }

    (compatible, errors)
}

/// Resolve the topological load order for a set of extensions using Kahn's
/// algorithm with alphabetical tie-breaking.
///
/// Extensions whose dependencies form a cycle are all reported as errors.
/// Extensions whose dependencies are missing (not in the provided set and
/// not a built-in datatype) are also reported as errors.
///
/// Returns `Ok(ordered_names)` on success, or a vec of errors for every
/// extension that could not be ordered.
pub fn resolve_extension_order(
    manifests: &[(PathBuf, ExtensionManifest)],
) -> Result<Vec<String>, Vec<ExtensionLoadError>> {
    // Built-in datatype names that extensions may depend on.
    let builtins: HashSet<&str> = ["identity", "room", "timeline", "message"]
        .iter()
        .copied()
        .collect();

    // Build adjacency and in-degree maps.
    let ext_names: HashSet<String> = manifests.iter().map(|(_, m)| m.name.clone()).collect();

    // Map from extension name to its dependencies (only extension deps, not builtins).
    let mut adj: HashMap<String, Vec<String>> = HashMap::new();
    let mut in_degree: HashMap<String, usize> = HashMap::new();
    let mut errors = Vec::new();

    for (_, manifest) in manifests {
        adj.entry(manifest.name.clone()).or_default();
        in_degree.entry(manifest.name.clone()).or_insert(0);

        for dep in &manifest.ext_dependencies {
            // If the dep is a built-in, skip — builtins are always available.
            if builtins.contains(dep.as_str()) {
                continue;
            }

            // If the dep is another extension in our set, add an edge.
            if ext_names.contains(dep) {
                adj.entry(dep.clone())
                    .or_default()
                    .push(manifest.name.clone());
                *in_degree.entry(manifest.name.clone()).or_insert(0) += 1;
            } else {
                // Missing dependency — not a builtin and not in our set.
                errors.push(ExtensionLoadError {
                    name: manifest.name.clone(),
                    reason: format!("missing dependency: '{dep}' is not loaded"),
                });
            }
        }
    }

    if !errors.is_empty() {
        return Err(errors);
    }

    // Kahn's algorithm with alphabetical tie-breaking.
    let mut queue: VecDeque<String> = VecDeque::new();
    let mut zero_degree: Vec<String> = in_degree
        .iter()
        .filter(|(_, &deg)| deg == 0)
        .map(|(name, _)| name.clone())
        .collect();
    zero_degree.sort();
    for name in zero_degree {
        queue.push_back(name);
    }

    let mut order: Vec<String> = Vec::new();

    while let Some(current) = queue.pop_front() {
        order.push(current.clone());

        // Collect and sort neighbors for deterministic ordering.
        if let Some(neighbors) = adj.get(&current) {
            let mut next_ready: Vec<String> = Vec::new();
            for neighbor in neighbors {
                if let Some(deg) = in_degree.get_mut(neighbor) {
                    *deg -= 1;
                    if *deg == 0 {
                        next_ready.push(neighbor.clone());
                    }
                }
            }
            next_ready.sort();
            for name in next_ready {
                queue.push_back(name);
            }
        }
    }

    // Check for cycle: if order doesn't contain all extensions, there's a cycle.
    if order.len() != ext_names.len() {
        let ordered_set: HashSet<&str> = order.iter().map(|s| s.as_str()).collect();
        let cycle_members: Vec<String> = ext_names
            .iter()
            .filter(|name| !ordered_set.contains(name.as_str()))
            .cloned()
            .collect();

        let mut cycle_errors = Vec::new();
        for name in &cycle_members {
            cycle_errors.push(ExtensionLoadError {
                name: name.clone(),
                reason: format!(
                    "circular dependency involving: {}",
                    cycle_members.join(", ")
                ),
            });
        }
        return Err(cycle_errors);
    }

    Ok(order)
}

/// Compute the platform-specific library filename for an extension.
///
/// Replaces `-` with `_` in the extension name (Rust convention) and
/// adds the platform-appropriate prefix and suffix:
/// - macOS: `lib{name}.dylib`
/// - Linux: `lib{name}.so`
/// - Windows: `{name}.dll`
pub fn lib_filename(ext_name: &str) -> String {
    let safe_name = ext_name.replace('-', "_");

    if cfg!(target_os = "macos") {
        format!("lib{safe_name}.dylib")
    } else if cfg!(target_os = "windows") {
        format!("{safe_name}.dll")
    } else {
        // Linux and other Unix-like systems.
        format!("lib{safe_name}.so")
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    /// Helper: write a valid manifest.toml into a subdirectory.
    fn write_manifest(dir: &Path, name: &str, deps: &[&str]) {
        write_manifest_with_version(dir, name, deps, 1);
    }

    /// Helper: write a manifest.toml with a specific api_version.
    fn write_manifest_with_version(dir: &Path, name: &str, deps: &[&str], api_version: u32) {
        let ext_dir = dir.join(name);
        fs::create_dir_all(&ext_dir).unwrap();

        let deps_str = deps
            .iter()
            .map(|d| format!("\"{d}\""))
            .collect::<Vec<_>>()
            .join(", ");

        let toml = format!(
            r#"[extension]
name = "{name}"
version = "0.1.0"
api_version = "{api_version}"

[dependencies]
extensions = [{deps_str}]
"#
        );

        fs::write(ext_dir.join("manifest.toml"), toml).unwrap();
    }

    /// TC-2-LOADER-001: scan_manifests discovers extensions in subdirectories.
    #[test]
    fn scan_manifests_finds_extensions() {
        let tmp = tempfile::tempdir().unwrap();
        let dir = tmp.path();

        write_manifest(dir, "reactions", &[]);
        write_manifest(dir, "channels", &[]);

        let (found, errors) = scan_manifests(dir);

        assert!(errors.is_empty(), "expected no errors, got: {errors:?}");
        assert_eq!(found.len(), 2, "expected 2 extensions");

        let names: HashSet<String> = found.iter().map(|(_, m)| m.name.clone()).collect();
        assert!(names.contains("reactions"));
        assert!(names.contains("channels"));
    }

    /// TC-2-LOADER-002: scan_manifests skips invalid TOML but still finds valid ones.
    #[test]
    fn scan_manifests_skips_invalid() {
        let tmp = tempfile::tempdir().unwrap();
        let dir = tmp.path();

        // Valid manifest.
        write_manifest(dir, "good-ext", &[]);

        // Invalid manifest.
        let bad_dir = dir.join("bad-ext");
        fs::create_dir_all(&bad_dir).unwrap();
        fs::write(bad_dir.join("manifest.toml"), "this is not valid TOML {{{{").unwrap();

        let (found, errors) = scan_manifests(dir);

        assert_eq!(found.len(), 1, "should find 1 valid extension");
        assert_eq!(found[0].1.name, "good-ext");
        assert_eq!(errors.len(), 1, "should report 1 error");
        assert_eq!(errors[0].name, "bad-ext");
        assert!(
            errors[0].reason.contains("manifest parse error"),
            "error reason should mention parse: {}",
            errors[0].reason
        );
    }

    /// TC-2-LOADER-003: filter_api_version rejects incompatible versions.
    #[test]
    fn filter_api_version_skips_incompatible() {
        let tmp = tempfile::tempdir().unwrap();
        let dir = tmp.path();

        write_manifest_with_version(dir, "good", &[], 1);
        write_manifest_with_version(dir, "future", &[], 999);

        let (all, scan_errors) = scan_manifests(dir);
        assert!(scan_errors.is_empty());
        assert_eq!(all.len(), 2);

        let (compatible, version_errors) = filter_api_version(all);

        assert_eq!(compatible.len(), 1);
        assert_eq!(compatible[0].1.name, "good");

        assert_eq!(version_errors.len(), 1);
        assert_eq!(version_errors[0].name, "future");
        assert!(version_errors[0]
            .reason
            .contains("incompatible API version"));
    }

    /// TC-2-LOADER-004: topological ordering respects dependencies.
    #[test]
    fn resolve_order_topological() {
        let tmp = tempfile::tempdir().unwrap();
        let dir = tmp.path();

        // collab depends on mutable.
        write_manifest(dir, "mutable", &["message"]);
        write_manifest(dir, "collab", &["mutable"]);

        let (manifests, _) = scan_manifests(dir);

        let order = resolve_extension_order(&manifests).expect("resolution should succeed");

        let mut_pos = order.iter().position(|n| n == "mutable").unwrap();
        let col_pos = order.iter().position(|n| n == "collab").unwrap();

        assert!(
            mut_pos < col_pos,
            "mutable ({mut_pos}) should load before collab ({col_pos})"
        );
    }

    /// TC-2-LOADER-005: circular dependency is detected and reported.
    #[test]
    fn resolve_order_circular_dependency() {
        let tmp = tempfile::tempdir().unwrap();
        let dir = tmp.path();

        write_manifest(dir, "alpha", &["beta"]);
        write_manifest(dir, "beta", &["alpha"]);

        let (manifests, _) = scan_manifests(dir);

        let result = resolve_extension_order(&manifests);
        assert!(result.is_err(), "should detect circular dependency");

        let errors = result.unwrap_err();
        assert_eq!(errors.len(), 2, "both extensions in the cycle should fail");

        let error_names: HashSet<String> = errors.iter().map(|e| e.name.clone()).collect();
        assert!(error_names.contains("alpha"));
        assert!(error_names.contains("beta"));

        for err in &errors {
            assert!(
                err.reason.contains("circular dependency"),
                "error reason should mention circular: {}",
                err.reason
            );
        }
    }

    /// TC-2-LOADER-006: lib_filename produces correct name for current platform.
    #[test]
    fn lib_filename_platform() {
        let name = lib_filename("my-extension");

        if cfg!(target_os = "macos") {
            assert_eq!(name, "libmy_extension.dylib");
        } else if cfg!(target_os = "windows") {
            assert_eq!(name, "my_extension.dll");
        } else {
            assert_eq!(name, "libmy_extension.so");
        }
    }

    /// lib_filename replaces dashes with underscores.
    #[test]
    fn lib_filename_replaces_dashes() {
        let name = lib_filename("my-cool-ext");
        assert!(
            name.contains("my_cool_ext"),
            "dashes should become underscores: {name}"
        );
    }

    /// resolve_extension_order with no extensions returns empty order.
    #[test]
    fn resolve_order_empty() {
        let manifests: Vec<(PathBuf, ExtensionManifest)> = vec![];
        let order = resolve_extension_order(&manifests).expect("empty should succeed");
        assert!(order.is_empty());
    }

    /// resolve_extension_order alphabetical tie-breaking for independent extensions.
    #[test]
    fn resolve_order_alphabetical_tiebreak() {
        let tmp = tempfile::tempdir().unwrap();
        let dir = tmp.path();

        // Three independent extensions — should come out alphabetically.
        write_manifest(dir, "zeta", &[]);
        write_manifest(dir, "alpha", &[]);
        write_manifest(dir, "mu", &[]);

        let (manifests, _) = scan_manifests(dir);
        let order = resolve_extension_order(&manifests).expect("resolution should succeed");

        assert_eq!(order, vec!["alpha", "mu", "zeta"]);
    }

    /// scan_manifests on non-existent directory returns empty.
    #[test]
    fn scan_manifests_nonexistent_dir() {
        let (found, errors) = scan_manifests(Path::new("/nonexistent/path/that/does/not/exist"));
        assert!(found.is_empty());
        assert!(errors.is_empty());
    }

    /// scan_manifests skips regular files (non-directories).
    #[test]
    fn scan_manifests_skips_files() {
        let tmp = tempfile::tempdir().unwrap();
        let dir = tmp.path();

        // Create a regular file, not a directory.
        fs::write(dir.join("not_a_dir.txt"), "hello").unwrap();

        // Create a valid extension directory.
        write_manifest(dir, "valid", &[]);

        let (found, errors) = scan_manifests(dir);
        assert_eq!(found.len(), 1);
        assert_eq!(found[0].1.name, "valid");
        assert!(errors.is_empty());
    }
}
