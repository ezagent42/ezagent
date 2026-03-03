//! Integration tests for `ezagent send` and `ezagent messages`.

use std::process::Command;
use tempfile::TempDir;

/// Get path to the compiled binary.
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
        .args(["init", "--relay", "relay-a.example.com", "--name", "alice"])
        .output()
        .expect("init should run");
    assert_eq!(
        output.status.code(),
        Some(0),
        "init failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
}

/// TC-4-CLI-020: ezagent send outputs content ID on success.
#[test]
#[ignore = "requires built binary -- run: cargo build -p ezagent-cli"]
fn tc_4_cli_020_send_message() {
    let tmp = TempDir::new().unwrap();
    init_identity(&tmp);

    // Send message (in-memory engine accepts any room_id)
    let output = Command::new(ezagent_bin())
        .env("EZAGENT_HOME", tmp.path())
        .args(["send", "test-room", "--body", "Hello world"])
        .output()
        .expect("send");

    let stdout = String::from_utf8_lossy(&output.stdout);
    assert_eq!(
        output.status.code(),
        Some(0),
        "stderr: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(!stdout.trim().is_empty(), "should output content_id");
}

/// TC-4-CLI-021: send without init returns error.
#[test]
#[ignore = "requires built binary -- run: cargo build -p ezagent-cli"]
fn tc_4_cli_021_send_not_initialized() {
    let tmp = TempDir::new().unwrap();

    let output = Command::new(ezagent_bin())
        .env("EZAGENT_HOME", tmp.path())
        .args(["send", "fake-room", "--body", "test"])
        .output()
        .expect("send");

    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(stderr.contains("Not initialized"), "stderr: {stderr}");
    assert_eq!(output.status.code(), Some(1));
}

/// TC-4-CLI-022: messages list outputs table or "No messages."
#[test]
#[ignore = "requires built binary -- run: cargo build -p ezagent-cli"]
fn tc_4_cli_022_messages_empty() {
    let tmp = TempDir::new().unwrap();
    init_identity(&tmp);

    // Messages for a room with no timeline refs
    let output = Command::new(ezagent_bin())
        .env("EZAGENT_HOME", tmp.path())
        .args(["messages", "some-room"])
        .output()
        .expect("messages");

    let stdout = String::from_utf8_lossy(&output.stdout);
    assert_eq!(output.status.code(), Some(0));
    assert!(stdout.contains("No messages."), "stdout: {stdout}");
}

/// TC-4-CLI-023: messages --json outputs valid JSON array.
#[test]
#[ignore = "requires built binary -- run: cargo build -p ezagent-cli"]
fn tc_4_cli_023_messages_json() {
    let tmp = TempDir::new().unwrap();
    init_identity(&tmp);

    let output = Command::new(ezagent_bin())
        .env("EZAGENT_HOME", tmp.path())
        .args(["messages", "some-room", "--json"])
        .output()
        .expect("messages json");

    let stdout = String::from_utf8_lossy(&output.stdout);
    assert_eq!(output.status.code(), Some(0));
    // Should be valid JSON (empty array)
    let parsed: serde_json::Value =
        serde_json::from_str(stdout.trim()).expect("stdout should be valid JSON");
    assert!(parsed.is_array());
}

/// TC-4-CLI-024: messages not initialized returns error.
#[test]
#[ignore = "requires built binary -- run: cargo build -p ezagent-cli"]
fn tc_4_cli_024_messages_not_initialized() {
    let tmp = TempDir::new().unwrap();

    let output = Command::new(ezagent_bin())
        .env("EZAGENT_HOME", tmp.path())
        .args(["messages", "fake-room"])
        .output()
        .expect("messages");

    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(stderr.contains("Not initialized"), "stderr: {stderr}");
    assert_eq!(output.status.code(), Some(1));
}
