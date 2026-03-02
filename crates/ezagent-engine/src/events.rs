//! Event Stream -- engine event broadcast backed by `tokio::sync::broadcast`.
//!
//! The [`EventStream`] provides a publish-subscribe mechanism for engine
//! events. Components can subscribe to receive [`EngineEvent`] notifications
//! for room membership changes, new messages, deletions, etc.
//!
//! The stream uses `tokio::sync::broadcast` which supports multiple
//! subscribers. Events emitted when there are no subscribers are silently
//! dropped (no panic, no error).

use serde::{Deserialize, Serialize};
use tokio::sync::broadcast;

/// Event types emitted by the engine.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum EngineEvent {
    /// A new message was added to a room's timeline.
    MessageNew {
        /// The room containing the message.
        room_id: String,
        /// The timeline reference ID.
        ref_id: String,
        /// The message author's entity ID.
        author: String,
        /// The content hash (SHA-256).
        content_id: String,
    },
    /// A message was deleted (soft-delete) from a room's timeline.
    MessageDeleted {
        /// The room containing the deleted message.
        room_id: String,
        /// The timeline reference ID of the deleted message.
        ref_id: String,
        /// The entity that performed the deletion.
        author: String,
    },
    /// A member joined a room.
    RoomMemberJoined {
        /// The room the member joined.
        room_id: String,
        /// The entity ID of the new member.
        entity_id: String,
    },
    /// A member left a room.
    RoomMemberLeft {
        /// The room the member left.
        room_id: String,
        /// The entity ID of the departing member.
        entity_id: String,
    },
}

/// Event stream backed by `tokio::sync::broadcast`.
///
/// Supports multiple subscribers. Events emitted when no subscribers exist
/// are silently dropped.
pub struct EventStream {
    sender: broadcast::Sender<EngineEvent>,
}

impl EventStream {
    /// Create a new event stream with the given channel capacity.
    ///
    /// The capacity determines how many events can be buffered before
    /// slower subscribers start lagging (receiving `RecvError::Lagged`).
    pub fn new(capacity: usize) -> Self {
        let (sender, _) = broadcast::channel(capacity);
        Self { sender }
    }

    /// Emit an event to all current subscribers.
    ///
    /// If there are no subscribers, the event is silently dropped.
    pub fn emit(&self, event: EngineEvent) {
        // If no receivers, send returns Err but we ignore it.
        let _ = self.sender.send(event);
    }

    /// Subscribe to the event stream.
    ///
    /// Returns a `broadcast::Receiver` that will receive all events emitted
    /// after this subscription was created.
    pub fn subscribe(&self) -> broadcast::Receiver<EngineEvent> {
        self.sender.subscribe()
    }

    /// Get the number of active subscribers.
    pub fn subscriber_count(&self) -> usize {
        self.sender.receiver_count()
    }
}

impl Default for EventStream {
    fn default() -> Self {
        Self::new(1024) // Default capacity
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    /// TC-1-API-004: Subscribe, emit, and receive an event.
    #[tokio::test]
    async fn tc_1_api_004_event_stream_subscribe() {
        let stream = EventStream::new(16);

        // Subscribe before emitting.
        let mut rx = stream.subscribe();

        assert_eq!(stream.subscriber_count(), 1, "should have 1 subscriber");

        // Emit an event.
        stream.emit(EngineEvent::MessageNew {
            room_id: "R-alpha".to_string(),
            ref_id: "ref-001".to_string(),
            author: "@alice:relay.example.com".to_string(),
            content_id: "abc123def456".to_string(),
        });

        // Receive the event.
        let event = rx.recv().await.expect("should receive event");

        match event {
            EngineEvent::MessageNew {
                room_id,
                ref_id,
                author,
                content_id,
            } => {
                assert_eq!(room_id, "R-alpha");
                assert_eq!(ref_id, "ref-001");
                assert_eq!(author, "@alice:relay.example.com");
                assert_eq!(content_id, "abc123def456");
            }
            _ => panic!("expected MessageNew event"),
        }
    }

    /// TC-1-API-005: Emitting with no subscribers does not panic.
    #[test]
    fn tc_1_api_005_event_stream_no_subscribers() {
        let stream = EventStream::new(16);

        assert_eq!(stream.subscriber_count(), 0, "should have 0 subscribers");

        // Emit events with no subscribers -- should not panic.
        stream.emit(EngineEvent::MessageNew {
            room_id: "R-alpha".to_string(),
            ref_id: "ref-001".to_string(),
            author: "@alice:relay.example.com".to_string(),
            content_id: "abc123".to_string(),
        });

        stream.emit(EngineEvent::RoomMemberJoined {
            room_id: "R-alpha".to_string(),
            entity_id: "@bob:relay.example.com".to_string(),
        });

        stream.emit(EngineEvent::RoomMemberLeft {
            room_id: "R-alpha".to_string(),
            entity_id: "@carol:relay.example.com".to_string(),
        });

        stream.emit(EngineEvent::MessageDeleted {
            room_id: "R-alpha".to_string(),
            ref_id: "ref-002".to_string(),
            author: "@alice:relay.example.com".to_string(),
        });

        // If we get here, no panic occurred.
    }

    /// Default event stream has capacity 1024.
    #[test]
    fn event_stream_default() {
        let stream = EventStream::default();
        assert_eq!(stream.subscriber_count(), 0);
    }

    /// Multiple subscribers each receive the same event.
    #[tokio::test]
    async fn event_stream_multiple_subscribers() {
        let stream = EventStream::new(16);

        let mut rx1 = stream.subscribe();
        let mut rx2 = stream.subscribe();

        assert_eq!(stream.subscriber_count(), 2);

        stream.emit(EngineEvent::RoomMemberJoined {
            room_id: "R-beta".to_string(),
            entity_id: "@bob:relay.io".to_string(),
        });

        let e1 = rx1.recv().await.expect("rx1 should receive");
        let e2 = rx2.recv().await.expect("rx2 should receive");

        // Both should be RoomMemberJoined.
        match (&e1, &e2) {
            (
                EngineEvent::RoomMemberJoined {
                    room_id: r1,
                    entity_id: e1,
                },
                EngineEvent::RoomMemberJoined {
                    room_id: r2,
                    entity_id: e2,
                },
            ) => {
                assert_eq!(r1, "R-beta");
                assert_eq!(r2, "R-beta");
                assert_eq!(e1, "@bob:relay.io");
                assert_eq!(e2, "@bob:relay.io");
            }
            _ => panic!("both subscribers should receive RoomMemberJoined"),
        }
    }

    /// EngineEvent serde roundtrip.
    #[test]
    fn engine_event_serde_roundtrip() {
        let events = vec![
            EngineEvent::MessageNew {
                room_id: "R-alpha".to_string(),
                ref_id: "ref-001".to_string(),
                author: "@alice:relay.com".to_string(),
                content_id: "hash123".to_string(),
            },
            EngineEvent::MessageDeleted {
                room_id: "R-alpha".to_string(),
                ref_id: "ref-002".to_string(),
                author: "@bob:relay.com".to_string(),
            },
            EngineEvent::RoomMemberJoined {
                room_id: "R-beta".to_string(),
                entity_id: "@carol:relay.com".to_string(),
            },
            EngineEvent::RoomMemberLeft {
                room_id: "R-beta".to_string(),
                entity_id: "@dave:relay.com".to_string(),
            },
        ];

        for event in &events {
            let json = serde_json::to_string(event).expect("serialize event");
            let roundtripped: EngineEvent =
                serde_json::from_str(&json).expect("deserialize event");

            // Verify roundtrip by re-serializing and comparing JSON.
            let json2 = serde_json::to_string(&roundtripped).expect("re-serialize");
            assert_eq!(json, json2, "serde roundtrip must be lossless");
        }
    }
}
