//! Shared utilities for CLI commands.

use crate::config;
use ezagent_engine::engine::Engine;

/// Create and initialize an engine from saved config.
///
/// Loads config and keypair from `~/.ezagent/`, then creates and initializes
/// an [`Engine`] with the stored identity.
///
/// Returns `Err(exit_code)` if any step fails (prints error to stderr).
pub fn init_engine() -> Result<(Engine, config::AppConfig), i32> {
    let cfg = match config::load_config() {
        Ok(Some(c)) => c,
        Ok(None) => {
            eprintln!("Not initialized. Run 'ezagent init' first.");
            return Err(1);
        }
        Err(e) => {
            eprintln!("{e}");
            return Err(1);
        }
    };
    let keypair_bytes = match config::load_keypair() {
        Ok(b) => b,
        Err(e) => {
            eprintln!("{e}");
            return Err(1);
        }
    };
    let mut engine = match Engine::new() {
        Ok(e) => e,
        Err(e) => {
            eprintln!("Engine error: {e}");
            return Err(1);
        }
    };
    let entity_id = match ezagent_protocol::EntityId::parse(&cfg.identity.entity_id) {
        Ok(eid) => eid,
        Err(e) => {
            eprintln!("Invalid entity ID in config: {e}");
            return Err(1);
        }
    };
    let keypair = ezagent_protocol::Keypair::from_bytes(&keypair_bytes);
    if let Err(e) = engine.init_identity(entity_id, keypair) {
        eprintln!("Failed to init identity: {e}");
        return Err(1);
    }
    Ok((engine, cfg))
}
