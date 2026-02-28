//! Sync protocol messages for CRDT state exchange.

use serde::{Deserialize, Serialize};

/// Messages exchanged during CRDT sync.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type")]
pub enum SyncMessage {
    /// Request the state of a document, optionally with a state vector.
    #[serde(rename = "state_query")]
    StateQuery {
        /// The document ID to query.
        doc_id: String,
        /// Optional state vector for incremental sync.
        state_vector: Option<Vec<u8>>,
    },

    /// Reply with a document's state (full or incremental).
    #[serde(rename = "state_reply")]
    StateReply {
        /// The document ID being replied about.
        doc_id: String,
        /// The CRDT state/update payload.
        payload: Vec<u8>,
        /// Whether this is a full state snapshot (true) or incremental update (false).
        is_full: bool,
    },
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn state_query_serde_roundtrip() {
        let msg = SyncMessage::StateQuery {
            doc_id: "rooms/abc/messages".into(),
            state_vector: Some(vec![1, 2, 3]),
        };

        let json = serde_json::to_string(&msg).unwrap();
        assert!(json.contains("\"type\":\"state_query\""));

        let msg2: SyncMessage = serde_json::from_str(&json).unwrap();
        match msg2 {
            SyncMessage::StateQuery {
                doc_id,
                state_vector,
            } => {
                assert_eq!(doc_id, "rooms/abc/messages");
                assert_eq!(state_vector, Some(vec![1, 2, 3]));
            }
            _ => panic!("expected StateQuery"),
        }
    }

    #[test]
    fn state_query_without_state_vector() {
        let msg = SyncMessage::StateQuery {
            doc_id: "doc/1".into(),
            state_vector: None,
        };

        let json = serde_json::to_string(&msg).unwrap();
        let msg2: SyncMessage = serde_json::from_str(&json).unwrap();
        match msg2 {
            SyncMessage::StateQuery {
                doc_id,
                state_vector,
            } => {
                assert_eq!(doc_id, "doc/1");
                assert!(state_vector.is_none());
            }
            _ => panic!("expected StateQuery"),
        }
    }

    #[test]
    fn state_reply_serde_roundtrip() {
        let msg = SyncMessage::StateReply {
            doc_id: "rooms/abc/messages".into(),
            payload: vec![10, 20, 30],
            is_full: true,
        };

        let json = serde_json::to_string(&msg).unwrap();
        assert!(json.contains("\"type\":\"state_reply\""));

        let msg2: SyncMessage = serde_json::from_str(&json).unwrap();
        match msg2 {
            SyncMessage::StateReply {
                doc_id,
                payload,
                is_full,
            } => {
                assert_eq!(doc_id, "rooms/abc/messages");
                assert_eq!(payload, vec![10, 20, 30]);
                assert!(is_full);
            }
            _ => panic!("expected StateReply"),
        }
    }

    #[test]
    fn state_reply_incremental() {
        let msg = SyncMessage::StateReply {
            doc_id: "doc/1".into(),
            payload: vec![42],
            is_full: false,
        };

        let json = serde_json::to_string(&msg).unwrap();
        let msg2: SyncMessage = serde_json::from_str(&json).unwrap();
        match msg2 {
            SyncMessage::StateReply { is_full, .. } => {
                assert!(!is_full);
            }
            _ => panic!("expected StateReply"),
        }
    }

    #[test]
    fn clone_works() {
        let msg = SyncMessage::StateQuery {
            doc_id: "doc/1".into(),
            state_vector: None,
        };
        let msg2 = msg.clone();
        let json1 = serde_json::to_string(&msg).unwrap();
        let json2 = serde_json::to_string(&msg2).unwrap();
        assert_eq!(json1, json2);
    }
}
