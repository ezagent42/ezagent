//! Integration tests for `ezagent status`.

use std::process::Command;
use tempfile::TempDir;

/// Get path to the compiled binary.
fn ezagent_bin() -> std::path::PathBuf {
    let mut path = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    path.pop(); // -> crates/
    path.pop(); // -> ezagent/
    path.push("target");
    path.push("debug");
    path.push("ezagent");
    path
}

/// TC-4-CLI-040: status shows identity info.
#[test]
#[ignore = "requires built binary -- run: cargo build -p ezagent-cli"]
fn tc_4_cli_040_status_shows_info() {
    let tmp = TempDir::new().unwrap();

    // Init first.
    Command::new(ezagent_bin())
        .env("EZAGENT_HOME", tmp.path())
        .args(["init", "--relay", "relay-a.example.com", "--name", "alice"])
        .output()
        .expect("init");

    let output = Command::new(ezagent_bin())
        .env("EZAGENT_HOME", tmp.path())
        .args(["status"])
        .output()
        .expect("status");

    let stdout = String::from_utf8_lossy(&output.stdout);
    assert_eq!(output.status.code(), Some(0), "exit code should be 0");
    assert!(
        stdout.contains("@alice:relay-a.example.com"),
        "stdout should contain entity ID: {stdout}"
    );
    assert!(
        stdout.contains("relay-a.example.com"),
        "stdout should contain relay domain: {stdout}"
    );
    assert!(
        stdout.contains("Rooms:"),
        "stdout should contain room count: {stdout}"
    );
    assert!(
        stdout.contains("Connection:"),
        "stdout should contain connection status: {stdout}"
    );
}

/// TC-4-CLI-041: status without init returns error.
#[test]
#[ignore = "requires built binary -- run: cargo build -p ezagent-cli"]
fn tc_4_cli_041_status_not_initialized() {
    let tmp = TempDir::new().unwrap();

    let output = Command::new(ezagent_bin())
        .env("EZAGENT_HOME", tmp.path())
        .args(["status"])
        .output()
        .expect("status");

    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains("Not initialized"),
        "stderr should say not initialized: {stderr}"
    );
    assert_eq!(output.status.code(), Some(1));
}
