//! `ezagent open <uri>` -- URI navigation command.
//!
//! Parses `ezagent://` URIs and displays the referenced resource.
//! Supports Room URIs (`/r/{room_id}`) and Message URIs (`/r/{room_id}/m/{ref_id}`).

use super::common::init_engine;

/// Parsed ezagent URI components.
struct ParsedUri {
    /// Normalized authority (lowercase, no trailing slash).
    authority: String,
    /// The path portion after the authority.
    path: String,
}

/// Parse an ezagent:// URI into its components.
///
/// Normalizes the authority to lowercase and strips trailing slashes.
fn parse_ezagent_uri(uri: &str) -> Result<ParsedUri, String> {
    let trimmed = uri.trim().trim_end_matches('/');
    if !trimmed.starts_with("ezagent://") {
        return Err("scheme must be 'ezagent://'".to_string());
    }
    let rest = &trimmed["ezagent://".len()..];
    if rest.is_empty() {
        return Err("missing authority".to_string());
    }
    let (authority, path) = match rest.find('/') {
        Some(idx) => (&rest[..idx], &rest[idx..]),
        None => (rest, ""),
    };
    if authority.is_empty() {
        return Err("missing authority".to_string());
    }
    Ok(ParsedUri {
        authority: authority.to_lowercase(),
        path: if path.is_empty() {
            "/".to_string()
        } else {
            path.to_string()
        },
    })
}

/// Resource types that can be resolved from a URI path.
enum Resource {
    Room { room_id: String },
    Message { room_id: String, ref_id: String },
}

/// Parse the path component into a Resource.
fn resolve_path(path: &str) -> Result<Resource, String> {
    let path = path.trim_end_matches('/');
    let segments: Vec<&str> = path.split('/').filter(|s| !s.is_empty()).collect();

    match segments.as_slice() {
        ["r", room_id] => Ok(Resource::Room {
            room_id: room_id.to_string(),
        }),
        ["r", room_id, "m", ref_id] => Ok(Resource::Message {
            room_id: room_id.to_string(),
            ref_id: ref_id.to_string(),
        }),
        _ => Err(format!("unrecognized path: {path}")),
    }
}

/// `ezagent open <uri>`
///
/// Parses an `ezagent://` URI and displays the referenced resource.
/// Exit codes: 0 = success, 2 = INVALID_URI, 3 = RESOURCE_NOT_FOUND.
pub fn run(uri: &str) -> i32 {
    let parsed = match parse_ezagent_uri(uri) {
        Ok(u) => u,
        Err(e) => {
            eprintln!("INVALID_URI: {e}");
            return 2;
        }
    };

    let resource = match resolve_path(&parsed.path) {
        Ok(r) => r,
        Err(e) => {
            eprintln!("INVALID_URI: {e}");
            return 2;
        }
    };

    let (engine, _cfg) = match init_engine() {
        Ok(v) => v,
        Err(code) => return code,
    };

    match resource {
        Resource::Room { room_id } => match engine.room_get(&room_id) {
            Ok(val) => {
                let name = val.get("name").and_then(|v| v.as_str()).unwrap_or("-");
                println!("Room: {name}");
                println!("URI:  ezagent://{}/r/{}", parsed.authority, room_id);
                println!("ID:   {room_id}");

                if let Ok(members) = engine.room_members(&room_id) {
                    println!("Members: {}", members.join(", "));
                }
                0
            }
            Err(_) => {
                eprintln!("RESOURCE_NOT_FOUND: room {room_id}");
                3
            }
        },
        Resource::Message { room_id, ref_id } => {
            match engine.timeline_get_ref(&room_id, &ref_id) {
                Ok(val) => {
                    let author = val.get("author").and_then(|v| v.as_str()).unwrap_or("-");
                    let created =
                        val.get("created_at").and_then(|v| v.as_str()).unwrap_or("-");
                    let content_id =
                        val.get("content_id").and_then(|v| v.as_str()).unwrap_or("-");
                    println!("Message: {ref_id}");
                    println!(
                        "URI:     ezagent://{}/r/{}/m/{}",
                        parsed.authority, room_id, ref_id
                    );
                    println!("Author:  {author}");
                    println!("Created: {created}");
                    println!("Content: {content_id}");
                    0
                }
                Err(_) => {
                    eprintln!("RESOURCE_NOT_FOUND: message {ref_id} in room {room_id}");
                    3
                }
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_valid_room_uri() {
        let parsed = parse_ezagent_uri("ezagent://relay.test/r/room-123").unwrap();
        assert_eq!(parsed.authority, "relay.test");
        assert_eq!(parsed.path, "/r/room-123");
    }

    #[test]
    fn parse_valid_message_uri() {
        let parsed = parse_ezagent_uri("ezagent://relay.test/r/room-1/m/ref-1").unwrap();
        assert_eq!(parsed.authority, "relay.test");
        assert_eq!(parsed.path, "/r/room-1/m/ref-1");
    }

    #[test]
    fn parse_normalizes_authority_lowercase() {
        let parsed = parse_ezagent_uri("ezagent://Relay.Test/r/room-1").unwrap();
        assert_eq!(parsed.authority, "relay.test");
    }

    #[test]
    fn parse_strips_trailing_slash() {
        let parsed = parse_ezagent_uri("ezagent://relay.test/r/room-1/").unwrap();
        assert_eq!(parsed.authority, "relay.test");
        assert_eq!(parsed.path, "/r/room-1");
    }

    #[test]
    fn parse_rejects_wrong_scheme() {
        assert!(parse_ezagent_uri("http://example.com").is_err());
    }

    #[test]
    fn parse_rejects_missing_authority() {
        assert!(parse_ezagent_uri("ezagent://").is_err());
    }

    #[test]
    fn parse_rejects_not_a_uri() {
        assert!(parse_ezagent_uri("not-a-uri").is_err());
    }

    #[test]
    fn resolve_room_path() {
        let r = resolve_path("/r/room-123").unwrap();
        match r {
            Resource::Room { room_id } => assert_eq!(room_id, "room-123"),
            _ => panic!("expected Room"),
        }
    }

    #[test]
    fn resolve_message_path() {
        let r = resolve_path("/r/room-1/m/ref-1").unwrap();
        match r {
            Resource::Message { room_id, ref_id } => {
                assert_eq!(room_id, "room-1");
                assert_eq!(ref_id, "ref-1");
            }
            _ => panic!("expected Message"),
        }
    }

    #[test]
    fn resolve_rejects_unknown_path() {
        assert!(resolve_path("/unknown/path").is_err());
        assert!(resolve_path("/").is_err());
    }
}
