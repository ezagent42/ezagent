//! Message send and list CLI commands.
//!
//! Provides `send` (send a message) and `messages` (list timeline refs)
//! subcommands. Each function returns a process exit code (0 = success, 1 = error).

use super::common::init_engine;
use crate::output::OutputFormat;

/// `ezagent send <room_id> --body "text"`
///
/// Sends a message to the given room and prints the content ID to stdout.
/// Returns 0 on success, 1 on error.
pub fn send(room_id: &str, body: &str) -> i32 {
    let (engine, _cfg) = match init_engine() {
        Ok(v) => v,
        Err(code) => return code,
    };
    let body_val = serde_json::json!(body);
    match engine.message_send(room_id, body_val, "text/plain") {
        Ok(content) => {
            println!("{}", content.content_id);
            0
        }
        Err(e) => {
            eprintln!("{e}");
            1
        }
    }
}

/// `ezagent messages <room_id> [--limit N] [--before REF_ID] [--json]`
///
/// Lists messages for the given room. Supports pagination via `--limit` and
/// `--before`. Returns 0 on success, 1 on error.
pub fn list(room_id: &str, limit: Option<usize>, before: Option<&str>, json: bool) -> i32 {
    let (engine, _cfg) = match init_engine() {
        Ok(v) => v,
        Err(code) => return code,
    };
    let format = OutputFormat::from_flags(json, false);

    let refs = match engine.timeline_list(room_id) {
        Ok(r) => r,
        Err(e) => {
            eprintln!("{e}");
            return 1;
        }
    };

    // Apply pagination: --before filters refs before the given ID, --limit caps count.
    let filtered: Vec<&String> = if let Some(before_id) = before {
        refs.iter()
            .take_while(|r| r.as_str() != before_id)
            .collect()
    } else {
        refs.iter().collect()
    };

    let limited: Vec<&String> = if let Some(lim) = limit {
        // Take the last `lim` items (most recent).
        let start = filtered.len().saturating_sub(lim);
        filtered[start..].to_vec()
    } else {
        filtered
    };

    // Collect timeline ref details.
    let details: Vec<serde_json::Value> = limited
        .iter()
        .filter_map(|ref_id| engine.timeline_get_ref(room_id, ref_id).ok())
        .collect();

    match format {
        OutputFormat::Json => match serde_json::to_string_pretty(&details) {
            Ok(s) => println!("{s}"),
            Err(e) => {
                eprintln!("{e}");
                return 1;
            }
        },
        OutputFormat::Table | OutputFormat::Quiet => {
            if details.is_empty() {
                println!("No messages.");
                return 0;
            }
            println!(
                "{:<28} {:<20} {:<30} CONTENT ID",
                "REF ID", "AUTHOR", "CREATED AT"
            );
            for d in &details {
                let ref_id = d.get("ref_id").and_then(|v| v.as_str()).unwrap_or("-");
                let author = d.get("author").and_then(|v| v.as_str()).unwrap_or("-");
                let created = d
                    .get("created_at")
                    .and_then(|v| v.as_str())
                    .unwrap_or("-");
                let content_id = d
                    .get("content_id")
                    .and_then(|v| v.as_str())
                    .unwrap_or("-");
                println!("{:<28} {:<20} {:<30} {}", ref_id, author, created, content_id);
            }
        }
    }
    0
}
