//! `ezagent init` -- Initialize identity and register with a relay.

use crate::config::{self, AppConfig, IdentityConfig, RelayConfig};
use ezagent_protocol::{EntityId, Keypair};

/// Run the `init` command.
///
/// Returns the process exit code:
/// - 0 on success
/// - 1 on runtime error
/// - 2 on bad arguments
pub fn run(relay: &str, name: &str, ca_cert: Option<&str>, force: bool) -> i32 {
    let home = config::ezagent_home();

    // Check for existing identity.
    if home.join("config.toml").exists() && !force {
        eprintln!("Identity already exists. Use --force to overwrite.");
        return 1;
    }

    // Parse entity ID.
    let entity_id_str = format!("@{name}:{relay}");
    let entity_id = match EntityId::parse(&entity_id_str) {
        Ok(eid) => eid,
        Err(e) => {
            eprintln!("Invalid identity: {e}");
            return 2;
        }
    };

    // Generate keypair.
    let keypair = Keypair::generate();

    // Save keypair.
    let keyfile = match config::save_keypair(&keypair.to_bytes()) {
        Ok(path) => path,
        Err(e) => {
            eprintln!("{e}");
            return 1;
        }
    };

    // Build config.
    let endpoint = format!("tls/{relay}:7448");
    let app_config = AppConfig {
        identity: IdentityConfig {
            keyfile: keyfile.to_string_lossy().to_string(),
            entity_id: entity_id.to_string(),
        },
        network: Default::default(),
        relay: Some(RelayConfig {
            endpoint,
            ca_cert: ca_cert.unwrap_or("").to_string(),
        }),
        storage: Default::default(),
    };

    // Save config.
    if let Err(e) = config::save_config(&app_config) {
        eprintln!("{e}");
        return 1;
    }

    println!("Identity created: {entity_id}");
    0
}
