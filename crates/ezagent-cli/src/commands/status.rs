//! `ezagent status` — connection and identity status.

use super::common::init_engine;

/// Display current status: identity, relay, rooms, connection.
///
/// Returns 0 on success, 1 on error (not initialized).
pub fn run() -> i32 {
    let (engine, cfg) = match init_engine() {
        Ok(v) => v,
        Err(code) => return code,
    };

    let relay = cfg
        .relay
        .as_ref()
        .map(|r| {
            let ep = &r.endpoint;
            let stripped = ep.strip_prefix("tls/").unwrap_or(ep);
            match stripped.rfind(':') {
                Some(pos) => stripped[..pos].to_string(),
                None => stripped.to_string(),
            }
        })
        .unwrap_or_else(|| "none".to_string());

    let room_count = engine.room_list().map(|r| r.len()).unwrap_or(0);

    println!("Entity ID:   {}", cfg.identity.entity_id);
    println!("Relay:       {relay}");
    println!("Rooms:       {room_count}");
    println!("Connection:  offline (L1 stub)");
    0
}
