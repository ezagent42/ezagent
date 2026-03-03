//! Integration tests for `ezagent room` and `ezagent rooms` commands.

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

/// TC-4-CLI-010: room create outputs room ID.
#[test]
#[ignore = "requires built binary -- run: cargo build -p ezagent-cli"]
fn tc_4_cli_010_room_create() {
    let tmp = TempDir::new().unwrap();
    init_identity(&tmp);

    let output = Command::new(ezagent_bin())
        .env("EZAGENT_HOME", tmp.path())
        .args(["room", "create", "--name", "Test Room"])
        .output()
        .expect("room create");

    let stdout = String::from_utf8_lossy(&output.stdout);
    assert_eq!(
        output.status.code(),
        Some(0),
        "stderr: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    // Should output a UUID-like room ID
    assert!(!stdout.trim().is_empty(), "should output room_id");
}

/// TC-4-CLI-011: room create without init returns error.
#[test]
#[ignore = "requires built binary -- run: cargo build -p ezagent-cli"]
fn tc_4_cli_011_room_create_not_initialized() {
    let tmp = TempDir::new().unwrap();

    let output = Command::new(ezagent_bin())
        .env("EZAGENT_HOME", tmp.path())
        .args(["room", "create", "--name", "Test Room"])
        .output()
        .expect("room create");

    let stderr = String::from_utf8_lossy(&output.stderr);
    assert_eq!(output.status.code(), Some(1));
    assert!(
        stderr.contains("Not initialized"),
        "stderr: {stderr}"
    );
}

/// TC-4-CLI-012: rooms list with --json outputs valid JSON (empty array for fresh engine).
#[test]
#[ignore = "requires built binary -- run: cargo build -p ezagent-cli"]
fn tc_4_cli_012_rooms_list_json() {
    let tmp = TempDir::new().unwrap();
    init_identity(&tmp);

    let output = Command::new(ezagent_bin())
        .env("EZAGENT_HOME", tmp.path())
        .args(["rooms", "--json"])
        .output()
        .expect("rooms --json");

    let stdout = String::from_utf8_lossy(&output.stdout);
    assert_eq!(
        output.status.code(),
        Some(0),
        "stderr: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    // Should be valid JSON (empty array for fresh engine with no state persistence)
    let parsed: serde_json::Value =
        serde_json::from_str(stdout.trim()).expect("stdout should be valid JSON");
    assert!(parsed.is_array(), "JSON output should be an array");
}

/// TC-4-CLI-013: rooms list with --quiet outputs IDs one per line (empty for fresh engine).
#[test]
#[ignore = "requires built binary -- run: cargo build -p ezagent-cli"]
fn tc_4_cli_013_rooms_list_quiet() {
    let tmp = TempDir::new().unwrap();
    init_identity(&tmp);

    let output = Command::new(ezagent_bin())
        .env("EZAGENT_HOME", tmp.path())
        .args(["rooms", "--quiet"])
        .output()
        .expect("rooms --quiet");

    assert_eq!(
        output.status.code(),
        Some(0),
        "stderr: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    // Quiet mode on empty rooms should produce no output
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(stdout.trim().is_empty(), "empty rooms should produce no output");
}

/// TC-4-CLI-014: rooms list table mode works (even if empty).
#[test]
#[ignore = "requires built binary -- run: cargo build -p ezagent-cli"]
fn tc_4_cli_014_rooms_list_table() {
    let tmp = TempDir::new().unwrap();
    init_identity(&tmp);

    let output = Command::new(ezagent_bin())
        .env("EZAGENT_HOME", tmp.path())
        .args(["rooms"])
        .output()
        .expect("rooms");

    let stdout = String::from_utf8_lossy(&output.stdout);
    assert_eq!(
        output.status.code(),
        Some(0),
        "stderr: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    // Empty rooms => "No rooms." message
    assert!(
        stdout.contains("No rooms"),
        "should show empty message: {stdout}"
    );
}

/// TC-4-CLI-015: rooms list without init returns error.
#[test]
#[ignore = "requires built binary -- run: cargo build -p ezagent-cli"]
fn tc_4_cli_015_rooms_list_not_initialized() {
    let tmp = TempDir::new().unwrap();

    let output = Command::new(ezagent_bin())
        .env("EZAGENT_HOME", tmp.path())
        .args(["rooms"])
        .output()
        .expect("rooms");

    let stderr = String::from_utf8_lossy(&output.stderr);
    assert_eq!(output.status.code(), Some(1));
    assert!(
        stderr.contains("Not initialized"),
        "stderr: {stderr}"
    );
}

/// TC-4-CLI-016: room show with nonexistent ID returns error.
#[test]
#[ignore = "requires built binary -- run: cargo build -p ezagent-cli"]
fn tc_4_cli_016_room_show_not_found() {
    let tmp = TempDir::new().unwrap();
    init_identity(&tmp);

    let output = Command::new(ezagent_bin())
        .env("EZAGENT_HOME", tmp.path())
        .args(["room", "show", "nonexistent-room"])
        .output()
        .expect("room show");

    assert_eq!(output.status.code(), Some(1));
}

/// TC-4-CLI-016b: room show without init returns error.
#[test]
#[ignore = "requires built binary -- run: cargo build -p ezagent-cli"]
fn tc_4_cli_016b_room_show_not_initialized() {
    let tmp = TempDir::new().unwrap();

    let output = Command::new(ezagent_bin())
        .env("EZAGENT_HOME", tmp.path())
        .args(["room", "show", "some-room"])
        .output()
        .expect("room show");

    let stderr = String::from_utf8_lossy(&output.stderr);
    assert_eq!(output.status.code(), Some(1));
    assert!(
        stderr.contains("Not initialized"),
        "stderr: {stderr}"
    );
}

/// TC-4-CLI-016c: room invite without init returns error.
#[test]
#[ignore = "requires built binary -- run: cargo build -p ezagent-cli"]
fn tc_4_cli_016c_room_invite_not_initialized() {
    let tmp = TempDir::new().unwrap();

    let output = Command::new(ezagent_bin())
        .env("EZAGENT_HOME", tmp.path())
        .args(["room", "invite", "some-room", "--entity", "@bob:relay.example.com"])
        .output()
        .expect("room invite");

    let stderr = String::from_utf8_lossy(&output.stderr);
    assert_eq!(output.status.code(), Some(1));
    assert!(
        stderr.contains("Not initialized"),
        "stderr: {stderr}"
    );
}
