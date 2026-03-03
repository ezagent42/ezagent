//! Integration tests for exit code mapping and config priority (TC-4-CLI-050~054).

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

/// TC-4-CLI-050: resolve_port env var takes priority over config default.
///
/// When `EZAGENT_PORT` is set, `ezagent start` should use that port
/// instead of the config file value or the built-in default.
#[test]
#[ignore = "requires built binary -- run: cargo build -p ezagent-cli"]
fn tc_4_cli_050_env_port_priority() {
    let tmp = TempDir::new().unwrap();
    Command::new(ezagent_bin())
        .env("EZAGENT_HOME", tmp.path())
        .args(["init", "--relay", "relay-a.example.com", "--name", "alice"])
        .output()
        .expect("init");

    // Start with EZAGENT_PORT=9999
    let mut child = Command::new(ezagent_bin())
        .env("EZAGENT_HOME", tmp.path())
        .env("EZAGENT_PORT", "9999")
        .args(["start"])
        .stdout(std::process::Stdio::piped())
        .spawn()
        .expect("spawn");

    std::thread::sleep(std::time::Duration::from_millis(300));
    child.kill().expect("kill");
    let output = child.wait_with_output().expect("wait");
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(
        stdout.contains("9999"),
        "should use env port, got: {stdout}"
    );
}

/// TC-4-CLI-054: exit code 0 on success.
///
/// A successful `ezagent status` command should exit with code 0.
#[test]
#[ignore = "requires built binary -- run: cargo build -p ezagent-cli"]
fn tc_4_cli_054_exit_code_success() {
    let tmp = TempDir::new().unwrap();
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
    assert_eq!(output.status.code(), Some(0));
}

/// TC-4-CLI-051: exit code 1 for not-initialized state.
///
/// Running a command without `init` should produce exit code 1.
#[test]
#[ignore = "requires built binary -- run: cargo build -p ezagent-cli"]
fn tc_4_cli_051_exit_code_not_initialized() {
    let tmp = TempDir::new().unwrap();

    let output = Command::new(ezagent_bin())
        .env("EZAGENT_HOME", tmp.path())
        .args(["status"])
        .output()
        .expect("status");
    assert_eq!(output.status.code(), Some(1));
}

/// TC-4-CLI-052: exit code 2 for missing required arguments.
///
/// Running `ezagent init` without required `--relay` and `--name` should
/// produce exit code 2 (clap's default for argument errors).
#[test]
#[ignore = "requires built binary -- run: cargo build -p ezagent-cli"]
fn tc_4_cli_052_exit_code_arg_error() {
    let tmp = TempDir::new().unwrap();

    let output = Command::new(ezagent_bin())
        .env("EZAGENT_HOME", tmp.path())
        .args(["init"])
        .output()
        .expect("init without args");
    assert_eq!(output.status.code(), Some(2));
}
