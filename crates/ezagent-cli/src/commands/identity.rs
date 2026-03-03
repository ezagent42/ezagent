//! `ezagent identity` -- Identity management commands.

use crate::config;

/// Run the `identity whoami` command.
///
/// Returns the process exit code:
/// - 0 on success
/// - 1 on runtime error (not initialized, or read error)
pub fn whoami() -> i32 {
    let config = match config::load_config() {
        Ok(Some(cfg)) => cfg,
        Ok(None) => {
            eprintln!("Not initialized. Run 'ezagent init' first.");
            return 1;
        }
        Err(e) => {
            eprintln!("{e}");
            return 1;
        }
    };

    // Load keypair for pubkey fingerprint.
    let pubkey_fp = match config::load_keypair() {
        Ok(bytes) => {
            let kp = ezagent_protocol::Keypair::from_bytes(&bytes);
            hex::encode(&kp.public_key().as_bytes()[..8])
        }
        Err(_) => "unknown".to_string(),
    };

    let relay = config
        .relay
        .as_ref()
        .map(|r| r.endpoint.clone())
        .unwrap_or_else(|| "none".to_string());

    println!("Entity ID:  {}", config.identity.entity_id);
    println!("Relay:      {relay}");
    println!("Public Key: {pubkey_fp}");
    0
}
