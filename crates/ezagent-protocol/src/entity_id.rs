//! Entity ID types for the EZAgent protocol.
//!
//! An EntityId has the form `@local_part:relay_domain`.

use std::fmt;
use std::str::FromStr;

use serde::{Deserialize, Serialize};

use crate::error::ProtocolError;

/// A unique identifier for an entity in the protocol.
///
/// Format: `@{local_part}:{relay_domain}`
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct EntityId {
    /// The local part of the entity ID (e.g. "alice").
    pub local_part: String,
    /// The relay domain of the entity ID (e.g. "relay-a.example.com").
    pub relay_domain: String,
}

impl EntityId {
    /// Parse an entity ID string of the form `@local_part:relay_domain`.
    pub fn parse(s: &str) -> Result<Self, ProtocolError> {
        if !s.starts_with('@') {
            return Err(ProtocolError::InvalidEntityId(format!(
                "must start with '@': {s}"
            )));
        }

        let rest = &s[1..]; // skip '@'
        let colon_pos = rest
            .find(':')
            .ok_or_else(|| ProtocolError::InvalidEntityId(format!("missing ':' separator: {s}")))?;

        let local_part = &rest[..colon_pos];
        let relay_domain = &rest[colon_pos + 1..];

        if local_part.is_empty() {
            return Err(ProtocolError::InvalidEntityId(format!(
                "empty local_part: {s}"
            )));
        }

        if relay_domain.is_empty() {
            return Err(ProtocolError::InvalidEntityId(format!(
                "empty relay_domain: {s}"
            )));
        }

        Ok(Self {
            local_part: local_part.to_string(),
            relay_domain: relay_domain.to_string(),
        })
    }
}

impl fmt::Display for EntityId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "@{}:{}", self.local_part, self.relay_domain)
    }
}

impl FromStr for EntityId {
    type Err = ProtocolError;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        Self::parse(s)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_valid() {
        let id = EntityId::parse("@alice:relay-a.example.com").unwrap();
        assert_eq!(id.local_part, "alice");
        assert_eq!(id.relay_domain, "relay-a.example.com");
    }

    #[test]
    fn display_roundtrip() {
        let id = EntityId {
            local_part: "bob".into(),
            relay_domain: "relay-b.example.com".into(),
        };
        assert_eq!(id.to_string(), "@bob:relay-b.example.com");
        let parsed = EntityId::parse(&id.to_string()).unwrap();
        assert_eq!(id, parsed);
    }

    #[test]
    fn parse_missing_at() {
        let err = EntityId::parse("alice:relay.com").unwrap_err();
        assert!(err.to_string().contains("must start with '@'"));
    }

    #[test]
    fn parse_missing_colon() {
        let err = EntityId::parse("@alice-relay.com").unwrap_err();
        assert!(err.to_string().contains("missing ':'"));
    }

    #[test]
    fn parse_empty_local() {
        let err = EntityId::parse("@:relay.com").unwrap_err();
        assert!(err.to_string().contains("empty local_part"));
    }

    #[test]
    fn parse_empty_domain() {
        let err = EntityId::parse("@alice:").unwrap_err();
        assert!(err.to_string().contains("empty relay_domain"));
    }

    #[test]
    fn from_str_trait() {
        let id: EntityId = "@carol:relay.io".parse().unwrap();
        assert_eq!(id.local_part, "carol");
        assert_eq!(id.relay_domain, "relay.io");
    }

    #[test]
    fn serde_roundtrip() {
        let id = EntityId::parse("@dave:relay-x.net").unwrap();
        let json = serde_json::to_string(&id).unwrap();
        let id2: EntityId = serde_json::from_str(&json).unwrap();
        assert_eq!(id, id2);
    }

    #[test]
    fn hash_and_eq() {
        use std::collections::HashSet;
        let id1 = EntityId::parse("@alice:relay.com").unwrap();
        let id2 = EntityId::parse("@alice:relay.com").unwrap();
        let id3 = EntityId::parse("@bob:relay.com").unwrap();
        let mut set = HashSet::new();
        set.insert(id1.clone());
        set.insert(id2);
        set.insert(id3);
        assert_eq!(set.len(), 2);
    }
}
