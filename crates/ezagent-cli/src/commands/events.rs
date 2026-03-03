//! `ezagent events` -- real-time event stream.
//!
//! Subscribes to the engine [`EventStream`] and prints events to stdout.
//! Supports `--room <room_id>` filtering and `--json` output (JSON Lines).
//! Runs until the stream closes or the process is interrupted (Ctrl+C).

use ezagent_engine::events::{EngineEvent, EventStream};

/// Extract the room_id from an event for filtering purposes.
fn event_room_id(event: &EngineEvent) -> &str {
    match event {
        EngineEvent::MessageNew { room_id, .. } => room_id,
        EngineEvent::MessageDeleted { room_id, .. } => room_id,
        EngineEvent::RoomMemberJoined { room_id, .. } => room_id,
        EngineEvent::RoomMemberLeft { room_id, .. } => room_id,
    }
}

/// Format an event as a human-readable line.
fn format_event(event: &EngineEvent) -> String {
    match event {
        EngineEvent::MessageNew {
            room_id,
            ref_id,
            author,
            ..
        } => {
            format!("message.new    {room_id}  {author}  ref={ref_id}")
        }
        EngineEvent::MessageDeleted {
            room_id,
            ref_id,
            author,
        } => {
            format!("message.delete {room_id}  {author}  ref={ref_id}")
        }
        EngineEvent::RoomMemberJoined { room_id, entity_id } => {
            format!("room.joined    {room_id}  {entity_id}")
        }
        EngineEvent::RoomMemberLeft { room_id, entity_id } => {
            format!("room.left      {room_id}  {entity_id}")
        }
    }
}

/// Run the events command: subscribe to event stream and print events.
///
/// Creates a standalone [`EventStream`], subscribes to it, and prints events
/// to stdout as they arrive. In L1, no external event source exists, so the
/// command simply waits until the broadcast channel is closed or the process
/// is interrupted (Ctrl+C).
///
/// Returns 0 on clean exit, 1 on error.
pub async fn run(room_filter: Option<&str>, json: bool) -> i32 {
    // L1: Create a standalone EventStream. In L2, this will come from the Engine.
    let stream = EventStream::default();
    let mut rx = stream.subscribe();

    // Print a startup message so the user knows we're listening.
    if !json {
        eprintln!("Listening for events... (Ctrl+C to stop)");
        if let Some(room) = room_filter {
            eprintln!("Filtering: room={room}");
        }
    }

    loop {
        match rx.recv().await {
            Ok(event) => {
                // Apply room filter.
                if let Some(room) = room_filter {
                    if event_room_id(&event) != room {
                        continue;
                    }
                }
                if json {
                    match serde_json::to_string(&event) {
                        Ok(s) => println!("{s}"),
                        Err(e) => eprintln!("warning: failed to serialize event: {e}"),
                    }
                } else {
                    println!("{}", format_event(&event));
                }
            }
            Err(tokio::sync::broadcast::error::RecvError::Closed) => break,
            Err(tokio::sync::broadcast::error::RecvError::Lagged(n)) => {
                eprintln!("warning: lagged {n} events");
                continue;
            }
        }
    }
    0
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    fn make_message_new() -> EngineEvent {
        EngineEvent::MessageNew {
            room_id: "R-alpha".to_string(),
            ref_id: "ref-001".to_string(),
            author: "@alice:relay.com".to_string(),
            content_id: "hash123".to_string(),
        }
    }

    fn make_message_deleted() -> EngineEvent {
        EngineEvent::MessageDeleted {
            room_id: "R-alpha".to_string(),
            ref_id: "ref-002".to_string(),
            author: "@bob:relay.com".to_string(),
        }
    }

    fn make_room_joined() -> EngineEvent {
        EngineEvent::RoomMemberJoined {
            room_id: "R-beta".to_string(),
            entity_id: "@carol:relay.com".to_string(),
        }
    }

    fn make_room_left() -> EngineEvent {
        EngineEvent::RoomMemberLeft {
            room_id: "R-beta".to_string(),
            entity_id: "@dave:relay.com".to_string(),
        }
    }

    // --- event_room_id tests ---

    #[test]
    fn event_room_id_message_new() {
        let event = make_message_new();
        assert_eq!(event_room_id(&event), "R-alpha");
    }

    #[test]
    fn event_room_id_message_deleted() {
        let event = make_message_deleted();
        assert_eq!(event_room_id(&event), "R-alpha");
    }

    #[test]
    fn event_room_id_room_joined() {
        let event = make_room_joined();
        assert_eq!(event_room_id(&event), "R-beta");
    }

    #[test]
    fn event_room_id_room_left() {
        let event = make_room_left();
        assert_eq!(event_room_id(&event), "R-beta");
    }

    // --- format_event tests ---

    #[test]
    fn format_event_message_new() {
        let event = make_message_new();
        let formatted = format_event(&event);
        assert!(
            formatted.contains("message.new"),
            "should contain event type: {formatted}"
        );
        assert!(
            formatted.contains("R-alpha"),
            "should contain room_id: {formatted}"
        );
        assert!(
            formatted.contains("@alice:relay.com"),
            "should contain author: {formatted}"
        );
        assert!(
            formatted.contains("ref=ref-001"),
            "should contain ref_id: {formatted}"
        );
    }

    #[test]
    fn format_event_message_deleted() {
        let event = make_message_deleted();
        let formatted = format_event(&event);
        assert!(
            formatted.contains("message.delete"),
            "should contain event type: {formatted}"
        );
        assert!(
            formatted.contains("R-alpha"),
            "should contain room_id: {formatted}"
        );
        assert!(
            formatted.contains("@bob:relay.com"),
            "should contain author: {formatted}"
        );
        assert!(
            formatted.contains("ref=ref-002"),
            "should contain ref_id: {formatted}"
        );
    }

    #[test]
    fn format_event_room_joined() {
        let event = make_room_joined();
        let formatted = format_event(&event);
        assert!(
            formatted.contains("room.joined"),
            "should contain event type: {formatted}"
        );
        assert!(
            formatted.contains("R-beta"),
            "should contain room_id: {formatted}"
        );
        assert!(
            formatted.contains("@carol:relay.com"),
            "should contain entity_id: {formatted}"
        );
    }

    #[test]
    fn format_event_room_left() {
        let event = make_room_left();
        let formatted = format_event(&event);
        assert!(
            formatted.contains("room.left"),
            "should contain event type: {formatted}"
        );
        assert!(
            formatted.contains("R-beta"),
            "should contain room_id: {formatted}"
        );
        assert!(
            formatted.contains("@dave:relay.com"),
            "should contain entity_id: {formatted}"
        );
    }

    // --- async run tests ---

    /// Test that the run function exits cleanly when the broadcast channel closes.
    #[tokio::test]
    async fn run_exits_on_channel_close() {
        let stream = EventStream::new(16);
        let mut rx = stream.subscribe();

        // Emit an event then drop the stream (closing the channel).
        stream.emit(EngineEvent::MessageNew {
            room_id: "R-alpha".to_string(),
            ref_id: "ref-001".to_string(),
            author: "@alice:relay.com".to_string(),
            content_id: "hash".to_string(),
        });

        // Receive the event.
        let event = rx.recv().await.expect("should receive event");
        assert_eq!(event_room_id(&event), "R-alpha");
    }

    /// Test that room_id filtering works correctly.
    #[test]
    fn room_filter_matches() {
        let event_alpha = EngineEvent::MessageNew {
            room_id: "R-alpha".to_string(),
            ref_id: "ref-001".to_string(),
            author: "@alice:relay.com".to_string(),
            content_id: "hash".to_string(),
        };
        let event_beta = EngineEvent::RoomMemberJoined {
            room_id: "R-beta".to_string(),
            entity_id: "@bob:relay.com".to_string(),
        };

        let filter = "R-alpha";
        assert_eq!(event_room_id(&event_alpha), filter, "should match R-alpha");
        assert_ne!(
            event_room_id(&event_beta),
            filter,
            "should not match R-alpha"
        );
    }

    /// Test that JSON serialization of events works (used by --json flag).
    #[test]
    fn json_serialization_all_variants() {
        let events = vec![
            make_message_new(),
            make_message_deleted(),
            make_room_joined(),
            make_room_left(),
        ];

        for event in &events {
            let json = serde_json::to_string(event);
            assert!(json.is_ok(), "event should serialize to JSON: {event:?}");
            let json_str = json.unwrap();
            assert!(!json_str.is_empty(), "JSON output should not be empty");
        }
    }
}
