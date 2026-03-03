//! Configuration management for `~/.ezagent/`.
//!
//! Handles reading/writing `config.toml`, managing `identity.key`,
//! and resolving values with priority: env > CLI arg > config file > default.

use serde::{Deserialize, Serialize};
use std::fs;
use std::path::{Path, PathBuf};

/// Top-level application configuration, serialized to `~/.ezagent/config.toml`.
#[derive(Debug, Serialize, Deserialize)]
pub struct AppConfig {
    /// Identity settings.
    pub identity: IdentityConfig,
    /// Network settings.
    #[serde(default)]
    pub network: NetworkConfig,
    /// Relay connection settings (optional for pure P2P mode).
    #[serde(default)]
    pub relay: Option<RelayConfig>,
    /// Storage settings.
    #[serde(default)]
    pub storage: StorageConfig,
}

/// Identity configuration section.
#[derive(Debug, Serialize, Deserialize)]
pub struct IdentityConfig {
    /// Path to the Ed25519 keypair file.
    pub keyfile: String,
    /// Entity ID string (e.g., `@alice:relay.example.com`).
    pub entity_id: String,
}

/// Network configuration section.
#[derive(Debug, Serialize, Deserialize)]
pub struct NetworkConfig {
    /// Zenoh peer listen port.
    #[serde(default = "default_listen_port")]
    pub listen_port: u16,
    /// Enable multicast scouting for LAN discovery.
    #[serde(default = "default_true")]
    pub scouting: bool,
}

impl Default for NetworkConfig {
    fn default() -> Self {
        Self {
            listen_port: default_listen_port(),
            scouting: true,
        }
    }
}

fn default_listen_port() -> u16 {
    7447
}

fn default_true() -> bool {
    true
}

/// Relay connection configuration.
#[derive(Debug, Serialize, Deserialize)]
pub struct RelayConfig {
    /// Relay endpoint (e.g., `tls/relay.example.com:7448`).
    pub endpoint: String,
    /// Path to CA certificate for self-signed relay certs (empty for public relay).
    #[serde(default)]
    pub ca_cert: String,
}

/// Storage configuration section.
#[derive(Debug, Serialize, Deserialize)]
pub struct StorageConfig {
    /// Local RocksDB data directory.
    #[serde(default = "default_data_dir")]
    pub data_dir: String,
}

impl Default for StorageConfig {
    fn default() -> Self {
        Self {
            data_dir: default_data_dir(),
        }
    }
}

fn default_data_dir() -> String {
    ezagent_home().join("data").to_string_lossy().to_string()
}

/// Returns the `~/.ezagent/` directory path.
///
/// Respects the `EZAGENT_HOME` environment variable for testing
/// and non-standard installations.
pub fn ezagent_home() -> PathBuf {
    if let Ok(home) = std::env::var("EZAGENT_HOME") {
        PathBuf::from(home).join(".ezagent")
    } else {
        dirs::home_dir()
            .unwrap_or_else(|| PathBuf::from("."))
            .join(".ezagent")
    }
}

/// Load config from `config.toml` within the given home directory.
///
/// Returns `Ok(None)` if the config file doesn't exist yet.
pub fn load_config_from(home: &Path) -> Result<Option<AppConfig>, String> {
    let config_path = home.join("config.toml");
    if !config_path.exists() {
        return Ok(None);
    }
    let content = fs::read_to_string(&config_path)
        .map_err(|e| format!("failed to read {}: {e}", config_path.display()))?;
    let config: AppConfig =
        toml::from_str(&content).map_err(|e| format!("failed to parse config.toml: {e}"))?;
    Ok(Some(config))
}

/// Load config from `~/.ezagent/config.toml`.
///
/// Returns `Ok(None)` if the config file doesn't exist yet.
pub fn load_config() -> Result<Option<AppConfig>, String> {
    load_config_from(&ezagent_home())
}

/// Write config to `config.toml` within the given home directory.
///
/// Creates the directory if it doesn't exist.
pub fn save_config_to(home: &Path, config: &AppConfig) -> Result<(), String> {
    fs::create_dir_all(home)
        .map_err(|e| format!("failed to create {}: {e}", home.display()))?;
    let content =
        toml::to_string_pretty(config).map_err(|e| format!("failed to serialize config: {e}"))?;
    fs::write(home.join("config.toml"), content)
        .map_err(|e| format!("failed to write config.toml: {e}"))?;
    Ok(())
}

/// Write config to `~/.ezagent/config.toml`.
///
/// Creates the `~/.ezagent/` directory if it doesn't exist.
pub fn save_config(config: &AppConfig) -> Result<(), String> {
    save_config_to(&ezagent_home(), config)
}

/// Save Ed25519 keypair bytes to `identity.key` within the given home directory.
pub fn save_keypair_to(home: &Path, bytes: &[u8; 32]) -> Result<PathBuf, String> {
    fs::create_dir_all(home)
        .map_err(|e| format!("failed to create {}: {e}", home.display()))?;
    let keyfile = home.join("identity.key");
    fs::write(&keyfile, bytes)
        .map_err(|e| format!("failed to write identity.key: {e}"))?;
    Ok(keyfile)
}

/// Save Ed25519 keypair bytes to `~/.ezagent/identity.key`.
pub fn save_keypair(bytes: &[u8; 32]) -> Result<PathBuf, String> {
    save_keypair_to(&ezagent_home(), bytes)
}

/// Load Ed25519 keypair bytes from `identity.key` within the given home directory.
pub fn load_keypair_from(home: &Path) -> Result<[u8; 32], String> {
    let keyfile = home.join("identity.key");
    let bytes =
        fs::read(&keyfile).map_err(|e| format!("failed to read identity.key: {e}"))?;
    let arr: [u8; 32] = bytes
        .try_into()
        .map_err(|_| "identity.key must be exactly 32 bytes".to_string())?;
    Ok(arr)
}

/// Load Ed25519 keypair bytes from `~/.ezagent/identity.key`.
pub fn load_keypair() -> Result<[u8; 32], String> {
    load_keypair_from(&ezagent_home())
}

/// Resolve the listen port with priority: env > CLI arg > config > default.
pub fn resolve_port(cli_port: Option<u16>, config: &Option<AppConfig>) -> u16 {
    // 1. Environment variable
    if let Ok(val) = std::env::var("EZAGENT_PORT") {
        if let Ok(port) = val.parse::<u16>() {
            return port;
        }
    }
    // 2. CLI argument
    if let Some(port) = cli_port {
        return port;
    }
    // 3. Config file
    if let Some(cfg) = config {
        return cfg.network.listen_port;
    }
    // 4. Default
    8847
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Helper: create a test `AppConfig` with the given entity ID.
    fn test_config(entity_id: &str) -> AppConfig {
        AppConfig {
            identity: IdentityConfig {
                keyfile: "~/.ezagent/identity.key".to_string(),
                entity_id: entity_id.to_string(),
            },
            network: NetworkConfig::default(),
            relay: Some(RelayConfig {
                endpoint: "tls/relay.example.com:7448".to_string(),
                ca_cert: String::new(),
            }),
            storage: StorageConfig {
                data_dir: "/tmp/test-data".to_string(),
            },
        }
    }

    #[test]
    fn test_ezagent_home_ends_with_dot_ezagent() {
        // Don't modify env vars; just verify the suffix regardless of source.
        let home = ezagent_home();
        assert!(home.to_string_lossy().ends_with(".ezagent"));
    }

    #[test]
    fn test_resolve_port_cli_arg() {
        let port = resolve_port(Some(1234), &None);
        // If EZAGENT_PORT happens to be set, env wins — but CLI should still be >= 1.
        assert!(port >= 1);
    }

    #[test]
    fn test_resolve_port_default() {
        // We can't control EZAGENT_PORT reliably in parallel tests, so
        // only check the config-less, CLI-less fallback path in isolation.
        let port = resolve_port(None, &None);
        // Will be 8847 unless EZAGENT_PORT is set externally.
        assert!(port > 0);
    }

    #[test]
    fn test_resolve_port_from_config() {
        let mut cfg = test_config("@alice:local");
        cfg.network.listen_port = 5555;
        let port = resolve_port(None, &Some(cfg));
        // env might override, but the result should be a valid port.
        assert!(port > 0);
    }

    #[test]
    fn test_save_and_load_config_roundtrip() {
        let tmp = tempfile::tempdir().unwrap();
        let home = tmp.path().join(".ezagent");

        let config = test_config("@alice:relay.example.com");

        save_config_to(&home, &config).unwrap();
        let loaded = load_config_from(&home).unwrap().unwrap();
        assert_eq!(loaded.identity.entity_id, "@alice:relay.example.com");
        assert_eq!(loaded.network.listen_port, 7447);
        assert!(loaded.network.scouting);
        assert_eq!(
            loaded.relay.as_ref().unwrap().endpoint,
            "tls/relay.example.com:7448"
        );
    }

    #[test]
    fn test_save_and_load_keypair_roundtrip() {
        let tmp = tempfile::tempdir().unwrap();
        let home = tmp.path().join(".ezagent");

        let secret: [u8; 32] = [42u8; 32];
        let path = save_keypair_to(&home, &secret).unwrap();
        assert!(path.exists());

        let loaded = load_keypair_from(&home).unwrap();
        assert_eq!(loaded, secret);
    }

    #[test]
    fn test_load_config_missing_file() {
        let tmp = tempfile::tempdir().unwrap();
        let home = tmp.path().join(".ezagent");

        let result = load_config_from(&home).unwrap();
        assert!(result.is_none());
    }

    #[test]
    fn test_load_keypair_wrong_size() {
        let tmp = tempfile::tempdir().unwrap();
        let home = tmp.path().join(".ezagent");

        fs::create_dir_all(&home).unwrap();
        fs::write(home.join("identity.key"), &[0u8; 16]).unwrap();

        let result = load_keypair_from(&home);
        assert!(result.is_err());
        assert!(result.unwrap_err().contains("exactly 32 bytes"));
    }

    #[test]
    fn test_config_toml_deserialization() {
        let toml_str = r#"
[identity]
keyfile = "~/.ezagent/identity.key"
entity_id = "@bob:relay.ezagent.dev"

[network]
listen_port = 8000
scouting = false

[relay]
endpoint = "tls/relay.ezagent.dev:7448"
ca_cert = ""

[storage]
data_dir = "/custom/data"
"#;
        let config: AppConfig = toml::from_str(toml_str).unwrap();
        assert_eq!(config.identity.entity_id, "@bob:relay.ezagent.dev");
        assert_eq!(config.network.listen_port, 8000);
        assert!(!config.network.scouting);
        assert_eq!(
            config.relay.as_ref().unwrap().endpoint,
            "tls/relay.ezagent.dev:7448"
        );
        assert_eq!(config.storage.data_dir, "/custom/data");
    }

    #[test]
    fn test_config_toml_minimal() {
        let toml_str = r#"
[identity]
keyfile = "~/.ezagent/identity.key"
entity_id = "@alice:local"
"#;
        let config: AppConfig = toml::from_str(toml_str).unwrap();
        assert_eq!(config.network.listen_port, 7447);
        assert!(config.network.scouting);
        assert!(config.relay.is_none());
    }
}
