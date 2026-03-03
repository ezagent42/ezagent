//! Integration tests for `ezagent init`.

use std::fs;
use std::process::Command;
use tempfile::TempDir;

/// Get path to the compiled binary.
fn ezagent_bin() -> std::path::PathBuf {
    // cargo test sets OUT_DIR for integration tests, but the binary
    // is in the target/debug directory.
    let mut path = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    // Navigate: crates/ezagent-cli -> crates -> ezagent -> target/debug
    path.pop(); // -> crates/
    path.pop(); // -> ezagent/
    path.push("target");
    path.push("debug");
    path.push("ezagent");
    path
}

/// TC-4-CLI-001: ezagent init creates identity and config.
#[test]
#[ignore = "requires built binary -- run: cargo build -p ezagent-cli"]
fn tc_4_cli_001_init_creates_identity() {
    let tmp = TempDir::new().unwrap();

    let output = Command::new(ezagent_bin())
        .env("EZAGENT_HOME", tmp.path())
        .args(["init", "--relay", "relay-a.example.com", "--name", "alice"])
        .output()
        .expect("failed to run ezagent");

    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);

    assert_eq!(
        output.status.code(),
        Some(0),
        "exit code should be 0, stderr: {stderr}"
    );
    assert!(
        stdout.contains("Identity created: @alice:relay-a.example.com"),
        "stdout should contain identity: {stdout}"
    );

    // Verify files.
    let home = tmp.path().join(".ezagent");
    assert!(
        home.join("identity.key").exists(),
        "identity.key should exist"
    );
    assert!(
        home.join("config.toml").exists(),
        "config.toml should exist"
    );

    // Verify config content.
    let config_content = fs::read_to_string(home.join("config.toml")).unwrap();
    assert!(config_content.contains("@alice:relay-a.example.com"));
    assert!(config_content.contains("relay-a.example.com"));

    // Verify keypair is 32 bytes.
    let key_bytes = fs::read(home.join("identity.key")).unwrap();
    assert_eq!(key_bytes.len(), 32, "identity.key should be 32 bytes");
}

/// TC-4-CLI-003: ezagent init rejects duplicate registration.
#[test]
#[ignore = "requires built binary -- run: cargo build -p ezagent-cli"]
fn tc_4_cli_003_init_duplicate_rejected() {
    let tmp = TempDir::new().unwrap();

    // First init.
    let first = Command::new(ezagent_bin())
        .env("EZAGENT_HOME", tmp.path())
        .args(["init", "--relay", "relay-a.example.com", "--name", "alice"])
        .output()
        .expect("first init");
    assert_eq!(first.status.code(), Some(0));

    // Second init without --force.
    let second = Command::new(ezagent_bin())
        .env("EZAGENT_HOME", tmp.path())
        .args(["init", "--relay", "relay-a.example.com", "--name", "bob"])
        .output()
        .expect("second init");

    let stderr = String::from_utf8_lossy(&second.stderr);
    assert_eq!(second.status.code(), Some(1));
    assert!(
        stderr.contains("Identity already exists"),
        "stderr should contain rejection: {stderr}"
    );
}

/// TC-4-CLI-003b: ezagent init with --force overwrites.
#[test]
#[ignore = "requires built binary -- run: cargo build -p ezagent-cli"]
fn tc_4_cli_003b_init_force_overwrites() {
    let tmp = TempDir::new().unwrap();

    // First init.
    Command::new(ezagent_bin())
        .env("EZAGENT_HOME", tmp.path())
        .args(["init", "--relay", "relay-a.example.com", "--name", "alice"])
        .output()
        .expect("first init");

    // Second init with --force.
    let second = Command::new(ezagent_bin())
        .env("EZAGENT_HOME", tmp.path())
        .args([
            "init",
            "--relay",
            "relay-a.example.com",
            "--name",
            "bob",
            "--force",
        ])
        .output()
        .expect("second init with force");

    let stdout = String::from_utf8_lossy(&second.stdout);
    assert_eq!(second.status.code(), Some(0));
    assert!(stdout.contains("@bob:relay-a.example.com"));

    // Config should reflect new identity.
    let home = tmp.path().join(".ezagent");
    let config = fs::read_to_string(home.join("config.toml")).unwrap();
    assert!(config.contains("@bob:relay-a.example.com"));
}

/// TC-4-CLI-004: ezagent identity whoami shows identity info.
#[test]
#[ignore = "requires built binary -- run: cargo build -p ezagent-cli"]
fn tc_4_cli_004_identity_whoami() {
    let tmp = TempDir::new().unwrap();

    // Init first.
    Command::new(ezagent_bin())
        .env("EZAGENT_HOME", tmp.path())
        .args(["init", "--relay", "relay-a.example.com", "--name", "alice"])
        .output()
        .expect("init");

    let output = Command::new(ezagent_bin())
        .env("EZAGENT_HOME", tmp.path())
        .args(["identity", "whoami"])
        .output()
        .expect("whoami");

    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(stdout.contains("@alice:relay-a.example.com"), "stdout: {stdout}");
    assert!(stdout.contains("relay-a.example.com"), "stdout: {stdout}");
    assert_eq!(output.status.code(), Some(0));
}

/// TC-4-CLI-005: ezagent identity whoami fails when not initialized.
#[test]
#[ignore = "requires built binary -- run: cargo build -p ezagent-cli"]
fn tc_4_cli_005_identity_whoami_not_initialized() {
    let tmp = TempDir::new().unwrap();

    let output = Command::new(ezagent_bin())
        .env("EZAGENT_HOME", tmp.path())
        .args(["identity", "whoami"])
        .output()
        .expect("whoami");

    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(stderr.contains("Not initialized"), "stderr: {stderr}");
    assert_eq!(output.status.code(), Some(1));
}
