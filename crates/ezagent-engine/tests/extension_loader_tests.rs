//! Integration tests for the full extension loading pipeline.
//!
//! These tests validate:
//! - Manifest scanning from a tempdir layout (non-ignored, no dlopen).
//! - End-to-end `dlopen -> dlsym -> call` with the `test-dummy` cdylib
//!   (ignored by default; requires `cargo build -p ezagent-ext-test-dummy`).

use std::fs;
use std::path::PathBuf;

use ezagent_engine::engine::Engine;
use ezagent_engine::loader;

/// TC-2-LOADER-INT-001: scan_manifests discovers a manifest written to a tempdir.
///
/// This test does NOT require the cdylib to be built — it only exercises
/// manifest scanning and parsing as an integration test.
#[test]
fn scan_manifests_integration() {
    let tmp = tempfile::tempdir().expect("failed to create tempdir");
    let ext_dir = tmp.path().join("test-dummy");
    fs::create_dir_all(&ext_dir).expect("failed to create extension dir");

    // Write a manifest.toml matching the test-dummy extension.
    let manifest_toml = r#"[extension]
name = "test-dummy"
version = "0.1.0"
api_version = "1"

[datatypes]
declarations = []

[hooks]
declarations = []

[dependencies]
extensions = []
"#;
    fs::write(ext_dir.join("manifest.toml"), manifest_toml).expect("failed to write manifest.toml");

    let (found, errors) = loader::scan_manifests(tmp.path());

    assert!(
        errors.is_empty(),
        "expected no scan errors, got: {errors:?}"
    );
    assert_eq!(found.len(), 1, "expected exactly 1 extension");
    assert_eq!(found[0].1.name, "test-dummy");
    assert_eq!(found[0].1.version, "0.1.0");
    assert_eq!(found[0].1.api_version, 1);
    assert!(found[0].1.datatype_declarations.is_empty());
    assert!(found[0].1.hook_declarations.is_empty());
    assert!(found[0].1.ext_dependencies.is_empty());
}

/// TC-2-LOADER-INT-002: scan + filter + resolve pipeline works end-to-end
/// with multiple manifests in a tempdir (no dlopen).
#[test]
fn scan_filter_resolve_integration() {
    let tmp = tempfile::tempdir().expect("failed to create tempdir");

    // Extension "alpha" depends on builtin "message" (should be fine).
    let alpha_dir = tmp.path().join("alpha");
    fs::create_dir_all(&alpha_dir).expect("failed to create alpha dir");
    fs::write(
        alpha_dir.join("manifest.toml"),
        r#"[extension]
name = "alpha"
version = "0.1.0"
api_version = "1"

[dependencies]
extensions = ["message"]
"#,
    )
    .expect("failed to write alpha manifest");

    // Extension "beta" depends on "alpha".
    let beta_dir = tmp.path().join("beta");
    fs::create_dir_all(&beta_dir).expect("failed to create beta dir");
    fs::write(
        beta_dir.join("manifest.toml"),
        r#"[extension]
name = "beta"
version = "0.1.0"
api_version = "1"

[dependencies]
extensions = ["alpha"]
"#,
    )
    .expect("failed to write beta manifest");

    // Extension "incompatible" has wrong API version.
    let incompat_dir = tmp.path().join("incompatible");
    fs::create_dir_all(&incompat_dir).expect("failed to create incompatible dir");
    fs::write(
        incompat_dir.join("manifest.toml"),
        r#"[extension]
name = "incompatible"
version = "0.1.0"
api_version = "999"
"#,
    )
    .expect("failed to write incompatible manifest");

    // Step 1: Scan.
    let (scanned, scan_errors) = loader::scan_manifests(tmp.path());
    assert!(scan_errors.is_empty(), "scan errors: {scan_errors:?}");
    assert_eq!(scanned.len(), 3);

    // Step 2: Filter.
    let (compatible, version_errors) = loader::filter_api_version(scanned);
    assert_eq!(version_errors.len(), 1);
    assert_eq!(version_errors[0].name, "incompatible");
    assert_eq!(compatible.len(), 2);

    // Step 3: Resolve order.
    let order = loader::resolve_extension_order(&compatible).expect("resolution should succeed");
    assert_eq!(order.len(), 2);

    // alpha must come before beta.
    let alpha_pos = order
        .iter()
        .position(|n| n == "alpha")
        .expect("alpha in order");
    let beta_pos = order
        .iter()
        .position(|n| n == "beta")
        .expect("beta in order");
    assert!(
        alpha_pos < beta_pos,
        "alpha ({alpha_pos}) must load before beta ({beta_pos})"
    );
}

/// Locate the cargo target directory relative to CARGO_MANIFEST_DIR.
///
/// The engine crate is at `ezagent/crates/ezagent-engine/`, and the
/// workspace target directory is at `ezagent/target/`. We navigate up
/// two levels from CARGO_MANIFEST_DIR.
fn cargo_target_dir() -> PathBuf {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    // ezagent/crates/ezagent-engine -> ezagent/crates -> ezagent
    let workspace_root = manifest_dir
        .parent()
        .expect("crates dir")
        .parent()
        .expect("workspace root");
    workspace_root.join("target").join("debug")
}

/// Locate the test-dummy crate's manifest.toml.
fn dummy_manifest_path() -> PathBuf {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let workspace_root = manifest_dir
        .parent()
        .expect("crates dir")
        .parent()
        .expect("workspace root");
    workspace_root
        .join("crates")
        .join("ezagent-ext-test-dummy")
        .join("manifest.toml")
}

/// TC-2-LOADER-INT-003: Full end-to-end extension loading via Engine.
///
/// Builds and loads the `test-dummy` cdylib extension through the Engine's
/// `load_extensions` method, validating the complete
/// `dlopen -> dlsym -> call -> register` pipeline.
#[test]
#[ignore = "requires cdylib build — run: cargo build -p ezagent-ext-test-dummy"]
fn end_to_end_extension_loading() {
    let target_dir = cargo_target_dir();

    // The cargo-built cdylib filename for crate "ezagent-ext-test-dummy".
    let cdylib_name = if cfg!(target_os = "macos") {
        "libezagent_ext_test_dummy.dylib"
    } else if cfg!(target_os = "windows") {
        "ezagent_ext_test_dummy.dll"
    } else {
        "libezagent_ext_test_dummy.so"
    };

    let cdylib_path = target_dir.join(cdylib_name);
    assert!(
        cdylib_path.exists(),
        "cdylib not found at {}: run `cargo build -p ezagent-ext-test-dummy` first",
        cdylib_path.display()
    );

    // The loader expects the library named after the extension's manifest name
    // ("test-dummy"), not the crate name. The loader::lib_filename function
    // converts "test-dummy" -> "libtest_dummy.dylib" (on macOS).
    let expected_lib_name = loader::lib_filename("test-dummy");

    // Set up the extension directory layout:
    //   {tmpdir}/test-dummy/manifest.toml
    //   {tmpdir}/test-dummy/libtest_dummy.dylib  (symlink to cargo output)
    let tmp = tempfile::tempdir().expect("failed to create tempdir");
    let ext_dir = tmp.path().join("test-dummy");
    fs::create_dir_all(&ext_dir).expect("failed to create extension dir");

    // Copy manifest.toml from the crate.
    let manifest_src = dummy_manifest_path();
    assert!(
        manifest_src.exists(),
        "manifest.toml not found at {}",
        manifest_src.display()
    );
    fs::copy(&manifest_src, ext_dir.join("manifest.toml")).expect("failed to copy manifest.toml");

    // Symlink the cdylib with the name the loader expects.
    #[cfg(unix)]
    std::os::unix::fs::symlink(&cdylib_path, ext_dir.join(&expected_lib_name)).unwrap_or_else(
        |e| {
            panic!(
                "failed to symlink {} -> {}: {e}",
                cdylib_path.display(),
                ext_dir.join(&expected_lib_name).display()
            )
        },
    );

    #[cfg(windows)]
    fs::copy(&cdylib_path, ext_dir.join(&expected_lib_name)).expect("failed to copy cdylib");

    // Load extensions through the Engine.
    let mut engine = Engine::new().expect("Engine::new() should succeed");

    // Verify no extensions loaded initially.
    assert!(
        engine.loaded_extensions().is_empty(),
        "no extensions should be loaded initially"
    );
    assert!(
        !engine.is_extension_loaded("test-dummy"),
        "test-dummy should not be loaded initially"
    );

    // Load extensions from our temp directory.
    let errors = engine.load_extensions(tmp.path());

    // Assert no errors.
    assert!(
        errors.is_empty(),
        "expected no load errors, got: {errors:?}",
    );

    // Assert the extension is loaded.
    assert!(
        engine.is_extension_loaded("test-dummy"),
        "test-dummy should be loaded after load_extensions"
    );

    // Assert loaded_extensions() contains "test-dummy".
    let loaded = engine.loaded_extensions();
    assert!(
        loaded.contains(&"test-dummy".to_string()),
        "loaded_extensions should contain 'test-dummy', got: {loaded:?}"
    );
}

/// TC-2-LOADER-INT-004: load_extensions reports an error when the cdylib is missing.
#[test]
fn load_extensions_missing_cdylib() {
    let tmp = tempfile::tempdir().expect("failed to create tempdir");
    let ext_dir = tmp.path().join("test-dummy");
    fs::create_dir_all(&ext_dir).expect("failed to create extension dir");

    // Write a valid manifest but no library file.
    fs::write(
        ext_dir.join("manifest.toml"),
        r#"[extension]
name = "test-dummy"
version = "0.1.0"
api_version = "1"
"#,
    )
    .expect("failed to write manifest");

    let mut engine = Engine::new().expect("Engine::new() should succeed");
    let errors = engine.load_extensions(tmp.path());

    // Should get an error about the missing library.
    assert_eq!(errors.len(), 1, "expected 1 error for missing cdylib");
    assert_eq!(errors[0].name, "test-dummy");
    assert!(
        errors[0].reason.contains("failed to load library"),
        "error should mention library load failure: {}",
        errors[0].reason
    );

    // Extension should NOT be marked as loaded.
    assert!(
        !engine.is_extension_loaded("test-dummy"),
        "test-dummy should not be loaded when cdylib is missing"
    );
}

/// TC-2-LOADER-INT-005: load_extensions with empty directory produces no errors.
#[test]
fn load_extensions_empty_dir() {
    let tmp = tempfile::tempdir().expect("failed to create tempdir");

    let mut engine = Engine::new().expect("Engine::new() should succeed");
    let errors = engine.load_extensions(tmp.path());

    assert!(
        errors.is_empty(),
        "empty dir should produce no errors: {errors:?}"
    );
    assert!(engine.loaded_extensions().is_empty());
}
