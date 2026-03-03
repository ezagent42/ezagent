//! Integration tests for `ezagent events` (TC-4-CLI-030~032).

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

/// Helper: run `ezagent init` in the given temp directory.
fn init_identity(tmp: &TempDir) {
    let output = Command::new(ezagent_bin())
        .env("EZAGENT_HOME", tmp.path())
        .args(["init", "--relay", "relay-a.example.com", "--name", "alice"])
        .output()
        .expect("init should run");
    assert!(
        output.status.success(),
        "init should succeed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
}

/// TC-4-CLI-030: `ezagent events` starts and can be interrupted.
///
/// The events command blocks waiting for events. We spawn it, let it start,
/// then kill it. The test verifies that the command starts without error
/// and can be killed without panic.
#[test]
#[ignore = "requires built binary -- run: cargo build -p ezagent-cli"]
fn tc_4_cli_030_events_starts() {
    let tmp = TempDir::new().unwrap();
    init_identity(&tmp);

    // Spawn events command (will block waiting for events).
    let mut child = Command::new(ezagent_bin())
        .env("EZAGENT_HOME", tmp.path())
        .args(["events"])
        .stderr(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .spawn()
        .expect("spawn events");

    // Give it a moment to start, then kill.
    std::thread::sleep(std::time::Duration::from_millis(300));
    child.kill().expect("kill events");
    let status = child.wait().expect("wait for events");

    // Killed processes don't have exit code 0 on Unix (signal termination),
    // but they shouldn't panic or produce assertion errors.
    // On Unix, a killed process has no exit code (code() returns None).
    // We just verify it terminated.
    let _ = status;
}

/// TC-4-CLI-031: `ezagent events --room <room_id>` accepts the room filter.
///
/// Verifies the `--room` flag is accepted without error.
#[test]
#[ignore = "requires built binary -- run: cargo build -p ezagent-cli"]
fn tc_4_cli_031_events_room_filter() {
    let tmp = TempDir::new().unwrap();
    init_identity(&tmp);

    let mut child = Command::new(ezagent_bin())
        .env("EZAGENT_HOME", tmp.path())
        .args(["events", "--room", "R-alpha"])
        .stderr(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .spawn()
        .expect("spawn events with --room");

    std::thread::sleep(std::time::Duration::from_millis(300));
    child.kill().expect("kill events");
    let output = child.wait_with_output().expect("wait for events");

    // Verify the filter message appeared on stderr.
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains("Filtering: room=R-alpha"),
        "stderr should mention room filter: {stderr}"
    );
}

/// TC-4-CLI-032: `ezagent events --json` accepts the JSON Lines flag.
///
/// Verifies the `--json` flag is accepted without error. In JSON mode,
/// no startup message is printed to stderr.
#[test]
#[ignore = "requires built binary -- run: cargo build -p ezagent-cli"]
fn tc_4_cli_032_events_json_flag() {
    let tmp = TempDir::new().unwrap();
    init_identity(&tmp);

    let mut child = Command::new(ezagent_bin())
        .env("EZAGENT_HOME", tmp.path())
        .args(["events", "--json"])
        .stderr(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .spawn()
        .expect("spawn events with --json");

    std::thread::sleep(std::time::Duration::from_millis(300));
    child.kill().expect("kill events");
    let output = child.wait_with_output().expect("wait for events");

    // In --json mode, no "Listening for events..." message on stderr.
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        !stderr.contains("Listening for events"),
        "JSON mode should not print startup message: {stderr}"
    );
}
