//! Integration tests for `ezagent start`.

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

/// TC-4-CLI-042: start shows server message and can be interrupted.
#[test]
#[ignore = "requires built binary -- run: cargo build -p ezagent-cli"]
fn tc_4_cli_042_start_shows_message() {
    let tmp = TempDir::new().unwrap();

    // Init first.
    Command::new(ezagent_bin())
        .env("EZAGENT_HOME", tmp.path())
        .args(["init", "--relay", "relay-a.example.com", "--name", "alice"])
        .output()
        .expect("init");

    let mut child = Command::new(ezagent_bin())
        .env("EZAGENT_HOME", tmp.path())
        .args(["start"])
        .stdout(std::process::Stdio::piped())
        .spawn()
        .expect("spawn start");

    // Give the process a moment to print its startup message.
    std::thread::sleep(std::time::Duration::from_millis(300));
    child.kill().expect("kill");
    let output = child.wait_with_output().expect("wait");
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(
        stdout.contains("http://localhost:"),
        "stdout should contain listen URL: {stdout}"
    );
    assert!(
        stdout.contains("Ctrl+C"),
        "stdout should mention Ctrl+C: {stdout}"
    );
}

/// TC-4-CLI-042b: start with --port overrides the default port.
#[test]
#[ignore = "requires built binary -- run: cargo build -p ezagent-cli"]
fn tc_4_cli_042b_start_custom_port() {
    let tmp = TempDir::new().unwrap();

    Command::new(ezagent_bin())
        .env("EZAGENT_HOME", tmp.path())
        .args(["init", "--relay", "relay-a.example.com", "--name", "alice"])
        .output()
        .expect("init");

    let mut child = Command::new(ezagent_bin())
        .env("EZAGENT_HOME", tmp.path())
        .args(["start", "--port", "9999"])
        .stdout(std::process::Stdio::piped())
        .spawn()
        .expect("spawn start");

    std::thread::sleep(std::time::Duration::from_millis(300));
    child.kill().expect("kill");
    let output = child.wait_with_output().expect("wait");
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(
        stdout.contains("http://localhost:9999"),
        "stdout should contain custom port 9999: {stdout}"
    );
}

/// TC-4-CLI-042c: start with --no-ui prints UI disabled message.
#[test]
#[ignore = "requires built binary -- run: cargo build -p ezagent-cli"]
fn tc_4_cli_042c_start_no_ui_flag() {
    let tmp = TempDir::new().unwrap();

    Command::new(ezagent_bin())
        .env("EZAGENT_HOME", tmp.path())
        .args(["init", "--relay", "relay-a.example.com", "--name", "alice"])
        .output()
        .expect("init");

    let mut child = Command::new(ezagent_bin())
        .env("EZAGENT_HOME", tmp.path())
        .args(["start", "--no-ui"])
        .stdout(std::process::Stdio::piped())
        .spawn()
        .expect("spawn start");

    std::thread::sleep(std::time::Duration::from_millis(300));
    child.kill().expect("kill");
    let output = child.wait_with_output().expect("wait");
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(
        stdout.contains("Static UI disabled"),
        "stdout should say UI disabled: {stdout}"
    );
}

/// TC-4-CLI-043: start without init returns error.
#[test]
#[ignore = "requires built binary -- run: cargo build -p ezagent-cli"]
fn tc_4_cli_043_start_not_initialized() {
    let tmp = TempDir::new().unwrap();

    let output = Command::new(ezagent_bin())
        .env("EZAGENT_HOME", tmp.path())
        .args(["start"])
        .output()
        .expect("start");

    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains("Not initialized"),
        "stderr should say not initialized: {stderr}"
    );
    assert_eq!(output.status.code(), Some(1));
}
