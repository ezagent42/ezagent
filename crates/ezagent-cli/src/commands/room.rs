//! Room management CLI commands.
//!
//! Provides `room create`, `room show`, `room invite`, and `rooms` (list)
//! subcommands. Each function returns a process exit code (0 = success, 1 = error).

use super::common::init_engine;
use crate::output::OutputFormat;

/// `ezagent room create --name <name>`
///
/// Creates a new room and prints the generated room ID to stdout.
/// Returns 0 on success, 1 on error.
pub fn create(name: &str) -> i32 {
    let (engine, _cfg) = match init_engine() {
        Ok(v) => v,
        Err(code) => return code,
    };
    match engine.room_create(name) {
        Ok(room) => {
            println!("{}", room.room_id);
            0
        }
        Err(e) => {
            eprintln!("{e}");
            crate::exit_codes::error_to_exit_code(&e)
        }
    }
}

/// `ezagent rooms [--json] [--quiet]`
///
/// Lists all rooms. Output format depends on flags:
/// - Table (default): shows ROOM ID and NAME columns
/// - JSON: outputs full room details as a JSON array
/// - Quiet: outputs one room ID per line
///
/// Returns 0 on success, 1 on error.
pub fn list(json: bool, quiet: bool) -> i32 {
    let (engine, _cfg) = match init_engine() {
        Ok(v) => v,
        Err(code) => return code,
    };
    let format = OutputFormat::from_flags(json, quiet);
    let rooms = match engine.room_list() {
        Ok(r) => r,
        Err(e) => {
            eprintln!("{e}");
            return crate::exit_codes::error_to_exit_code(&e);
        }
    };

    match format {
        OutputFormat::Quiet => {
            for id in &rooms {
                println!("{id}");
            }
        }
        OutputFormat::Json => {
            // Get full room details for JSON output
            let details: Vec<serde_json::Value> = rooms
                .iter()
                .filter_map(|id| engine.room_get(id).ok())
                .collect();
            match serde_json::to_string_pretty(&details) {
                Ok(s) => println!("{s}"),
                Err(e) => {
                    eprintln!("{e}");
                    return 1;
                }
            }
        }
        OutputFormat::Table => {
            if rooms.is_empty() {
                println!("No rooms.");
                return 0;
            }
            // Simple table: ID | Name
            println!("{:<40} NAME", "ROOM ID");
            for id in &rooms {
                let name = engine
                    .room_get(id)
                    .ok()
                    .and_then(|v| {
                        v.get("name")
                            .and_then(|n| n.as_str())
                            .map(|s| s.to_string())
                    })
                    .unwrap_or_default();
                println!("{:<40} {}", id, name);
            }
        }
    }
    0
}

/// `ezagent room show <room_id>`
///
/// Displays the full room configuration as pretty-printed JSON.
/// Returns 0 on success, 1 on error (e.g., room not found).
pub fn show(room_id: &str) -> i32 {
    let (engine, _cfg) = match init_engine() {
        Ok(v) => v,
        Err(code) => return code,
    };
    match engine.room_get(room_id) {
        Ok(val) => match serde_json::to_string_pretty(&val) {
            Ok(s) => {
                println!("{s}");
                0
            }
            Err(e) => {
                eprintln!("{e}");
                1
            }
        },
        Err(e) => {
            eprintln!("{e}");
            crate::exit_codes::error_to_exit_code(&e)
        }
    }
}

/// `ezagent room invite <room_id> --entity <entity_id>`
///
/// Invites an entity to a room as a member.
/// Returns 0 on success, 1 on error (e.g., room not found).
pub fn invite(room_id: &str, entity_id: &str) -> i32 {
    let (mut engine, _cfg) = match init_engine() {
        Ok(v) => v,
        Err(code) => return code,
    };
    match engine.room_invite(room_id, entity_id) {
        Ok(()) => {
            println!("Invited {entity_id} to room {room_id}");
            0
        }
        Err(e) => {
            eprintln!("{e}");
            crate::exit_codes::error_to_exit_code(&e)
        }
    }
}
