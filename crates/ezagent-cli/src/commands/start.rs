//! `ezagent start` — start the HTTP API server (L1 stub).

use super::common::init_engine;
use crate::config;

/// Start the HTTP API server.
///
/// In Level 1, this is a stub that validates configuration, prints a startup
/// message, and blocks until the process is killed. The actual FastAPI server
/// will be added in Level 2.
///
/// Returns 0 on clean shutdown, 1 on error.
pub fn run(port: Option<u16>, no_ui: bool) -> i32 {
    // Verify identity is initialized.
    let (_engine, cfg) = match init_engine() {
        Ok(v) => v,
        Err(code) => return code,
    };

    let actual_port = config::resolve_port(port, &Some(cfg));

    println!("EZAgent server starting on http://localhost:{actual_port}");
    if no_ui {
        println!("Static UI disabled (--no-ui)");
    }
    println!("Press Ctrl+C to stop.");

    // L1 stub: block until the process is killed.
    // In L2, this will spawn the FastAPI server and manage its lifecycle.
    std::thread::park();
    0
}
