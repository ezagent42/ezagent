//! Integration tests for `ezagent open`.

use std::process::Command;
use tempfile::TempDir;

fn ezagent_bin() -> std::path::PathBuf {
    let mut path = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    // Navigate: crates/ezagent-cli -> crates -> ezagent -> target/debug
    path.pop(); // -> crates/
    path.pop(); // -> ezagent/
    path.push("target");
    path.push("debug");
    path.push("ezagent");
    path
}

/// Helper: init identity in the given temp directory.
fn init_identity(tmp: &TempDir) {
    let output = Command::new(ezagent_bin())
        .env("EZAGENT_HOME", tmp.path())
        .args(["init", "--relay", "relay.test", "--name", "alice"])
        .output()
        .expect("init should run");
    assert_eq!(
        output.status.code(),
        Some(0),
        "init failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
}

/// TC-4-CLI-URI-003: Invalid URI returns exit code 2.
#[test]
#[ignore = "requires built binary -- run: cargo build -p ezagent-cli"]
fn tc_4_cli_uri_003_invalid_uri() {
    let tmp = TempDir::new().unwrap();

    let output = Command::new(ezagent_bin())
        .env("EZAGENT_HOME", tmp.path())
        .args(["open", "not-a-uri"])
        .output()
        .expect("failed to run ezagent");

    let stderr = String::from_utf8_lossy(&output.stderr);
    assert_eq!(
        output.status.code(),
        Some(2),
        "exit code should be 2, stderr: {stderr}"
    );
    assert!(stderr.contains("INVALID_URI"), "stderr: {stderr}");
}

/// TC-4-CLI-URI-003b: Wrong scheme returns exit code 2.
#[test]
#[ignore = "requires built binary -- run: cargo build -p ezagent-cli"]
fn tc_4_cli_uri_003b_wrong_scheme() {
    let tmp = TempDir::new().unwrap();

    let output = Command::new(ezagent_bin())
        .env("EZAGENT_HOME", tmp.path())
        .args(["open", "http://example.com/r/room-1"])
        .output()
        .expect("failed to run ezagent");

    assert_eq!(output.status.code(), Some(2));
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(stderr.contains("INVALID_URI"), "stderr: {stderr}");
}

/// TC-4-CLI-URI-004: Resource not found returns exit code 3.
#[test]
#[ignore = "requires built binary -- run: cargo build -p ezagent-cli"]
fn tc_4_cli_uri_004_resource_not_found() {
    let tmp = TempDir::new().unwrap();

    // First init identity
    init_identity(&tmp);

    let output = Command::new(ezagent_bin())
        .env("EZAGENT_HOME", tmp.path())
        .args(["open", "ezagent://relay.test/r/nonexistent-room"])
        .output()
        .expect("failed to run ezagent");

    let stderr = String::from_utf8_lossy(&output.stderr);
    assert_eq!(
        output.status.code(),
        Some(3),
        "exit code should be 3, stderr: {stderr}"
    );
    assert!(
        stderr.contains("RESOURCE_NOT_FOUND"),
        "stderr: {stderr}"
    );
}

/// TC-4-CLI-URI-003c: Invalid path returns exit code 2.
#[test]
#[ignore = "requires built binary -- run: cargo build -p ezagent-cli"]
fn tc_4_cli_uri_003c_invalid_path() {
    let tmp = TempDir::new().unwrap();

    init_identity(&tmp);

    let output = Command::new(ezagent_bin())
        .env("EZAGENT_HOME", tmp.path())
        .args(["open", "ezagent://relay.test/unknown/path"])
        .output()
        .expect("failed to run ezagent");

    assert_eq!(output.status.code(), Some(2));
}
