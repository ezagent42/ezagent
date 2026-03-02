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
    ///
    /// Enforces the ABNF spec:
    /// - `local_part`: lowercase alphanumeric + hyphens, no leading/trailing
    ///   hyphens, no consecutive hyphens, 1-64 chars.
    /// - `relay_domain`: valid DNS-style domain, lowercase, 1-253 chars.
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

        // --- local_part validation ---

        if local_part.is_empty() {
            return Err(ProtocolError::InvalidEntityId(format!(
                "empty local_part: {s}"
            )));
        }

        if local_part.len() > 64 {
            return Err(ProtocolError::InvalidEntityId(format!(
                "local_part exceeds 64 characters: {s}"
            )));
        }

        // Only lowercase ascii letters (a-z), digits (0-9), and hyphens (-)
        for ch in local_part.chars() {
            if !ch.is_ascii_lowercase() && !ch.is_ascii_digit() && ch != '-' {
                if ch.is_ascii_uppercase() {
                    return Err(ProtocolError::InvalidEntityId(format!(
                        "local_part contains uppercase letter '{ch}': {s}"
                    )));
                }
                return Err(ProtocolError::InvalidEntityId(format!(
                    "local_part contains invalid character '{ch}': {s}"
                )));
            }
        }

        // No leading hyphen
        if local_part.starts_with('-') {
            return Err(ProtocolError::InvalidEntityId(format!(
                "local_part starts with hyphen: {s}"
            )));
        }

        // No trailing hyphen
        if local_part.ends_with('-') {
            return Err(ProtocolError::InvalidEntityId(format!(
                "local_part ends with hyphen: {s}"
            )));
        }

        // No consecutive hyphens
        if local_part.contains("--") {
            return Err(ProtocolError::InvalidEntityId(format!(
                "local_part contains consecutive hyphens: {s}"
            )));
        }

        // --- relay_domain validation ---

        if relay_domain.is_empty() {
            return Err(ProtocolError::InvalidEntityId(format!(
                "empty relay_domain: {s}"
            )));
        }

        if relay_domain.len() > 253 {
            return Err(ProtocolError::InvalidEntityId(format!(
                "relay_domain exceeds 253 characters: {s}"
            )));
        }

        // Only lowercase ascii + dots + hyphens + digits
        for ch in relay_domain.chars() {
            if !ch.is_ascii_lowercase() && !ch.is_ascii_digit() && ch != '.' && ch != '-' {
                return Err(ProtocolError::InvalidEntityId(format!(
                    "relay_domain contains invalid character '{ch}': {s}"
                )));
            }
        }

        // No leading/trailing dots or hyphens
        if relay_domain.starts_with('.') || relay_domain.starts_with('-') {
            return Err(ProtocolError::InvalidEntityId(format!(
                "relay_domain starts with '{}': {s}",
                &relay_domain[..1]
            )));
        }
        if relay_domain.ends_with('.') || relay_domain.ends_with('-') {
            return Err(ProtocolError::InvalidEntityId(format!(
                "relay_domain ends with '{}': {s}",
                &relay_domain[relay_domain.len() - 1..]
            )));
        }

        // Must contain at least one dot or be "localhost"
        if !relay_domain.contains('.') && relay_domain != "localhost" {
            return Err(ProtocolError::InvalidEntityId(format!(
                "relay_domain must contain a dot or be 'localhost': {s}"
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

    /// TC-1-IDENT-001: Comprehensive EntityId format validation.
    ///
    /// Verifies that the parser enforces the ABNF spec for entity IDs:
    /// lowercase-only local_part, valid charset, reject uppercase, empty
    /// parts, leading/trailing hyphens, consecutive hyphens, and domain
    /// format.
    #[test]
    fn tc_1_ident_001_entity_id_format_validation() {
        // --- Valid entity IDs ---

        let id = EntityId::parse("@alice:relay.example.com").unwrap();
        assert_eq!(id.local_part, "alice");
        assert_eq!(id.relay_domain, "relay.example.com");

        let id = EntityId::parse("@code-reviewer:relay.example.com").unwrap();
        assert_eq!(id.local_part, "code-reviewer");
        assert_eq!(id.relay_domain, "relay.example.com");

        let id = EntityId::parse("@a1:localhost").unwrap();
        assert_eq!(id.local_part, "a1");
        assert_eq!(id.relay_domain, "localhost");

        // Digits-only local_part
        let id = EntityId::parse("@42:relay.io").unwrap();
        assert_eq!(id.local_part, "42");

        // Single character local_part
        let id = EntityId::parse("@a:relay.io").unwrap();
        assert_eq!(id.local_part, "a");

        // Hyphen in the middle
        let id = EntityId::parse("@my-agent:relay.io").unwrap();
        assert_eq!(id.local_part, "my-agent");

        // --- Invalid: uppercase in local_part ---

        let err = EntityId::parse("@Alice:relay.example.com").unwrap_err();
        assert!(
            err.to_string().contains("uppercase"),
            "expected uppercase error, got: {err}"
        );

        let err = EntityId::parse("@ALICE:relay.example.com").unwrap_err();
        assert!(
            err.to_string().contains("uppercase"),
            "expected uppercase error, got: {err}"
        );

        // --- Invalid: empty local_part ---

        let err = EntityId::parse("@:relay.example.com").unwrap_err();
        assert!(
            err.to_string().contains("empty local_part"),
            "expected empty local_part error, got: {err}"
        );

        // --- Invalid: empty relay_domain ---

        let err = EntityId::parse("@alice:").unwrap_err();
        assert!(
            err.to_string().contains("empty relay_domain"),
            "expected empty relay_domain error, got: {err}"
        );

        // --- Invalid: missing @ prefix ---

        let err = EntityId::parse("alice:relay.example.com").unwrap_err();
        assert!(
            err.to_string().contains("must start with '@'"),
            "expected missing '@' error, got: {err}"
        );

        // --- Invalid: leading hyphen in local_part ---

        let err = EntityId::parse("@-alice:relay.example.com").unwrap_err();
        assert!(
            err.to_string().contains("starts with hyphen"),
            "expected leading hyphen error, got: {err}"
        );

        // --- Invalid: consecutive hyphens in local_part ---

        let err = EntityId::parse("@alice--bob:relay.example.com").unwrap_err();
        assert!(
            err.to_string().contains("consecutive hyphens"),
            "expected consecutive hyphens error, got: {err}"
        );

        // --- Invalid: trailing hyphen in local_part ---

        let err = EntityId::parse("@alice-:relay.example.com").unwrap_err();
        assert!(
            err.to_string().contains("ends with hyphen"),
            "expected trailing hyphen error, got: {err}"
        );

        // --- Invalid: local_part too long (65 chars) ---

        let long_local = "a".repeat(65);
        let err = EntityId::parse(&format!("@{long_local}:relay.io")).unwrap_err();
        assert!(
            err.to_string().contains("exceeds 64"),
            "expected length error, got: {err}"
        );

        // --- Invalid: relay_domain with no dot and not localhost ---

        let err = EntityId::parse("@alice:relay").unwrap_err();
        assert!(
            err.to_string().contains("must contain a dot"),
            "expected domain format error, got: {err}"
        );

        // --- Invalid: relay_domain starts with dot ---

        let err = EntityId::parse("@alice:.relay.com").unwrap_err();
        assert!(
            err.to_string().contains("starts with '.'"),
            "expected leading dot error, got: {err}"
        );

        // --- Invalid: relay_domain ends with dot ---

        let err = EntityId::parse("@alice:relay.com.").unwrap_err();
        assert!(
            err.to_string().contains("ends with '.'"),
            "expected trailing dot error, got: {err}"
        );

        // --- Invalid: relay_domain too long (254 chars) ---

        let long_domain = format!("{}.com", "a".repeat(250));
        assert!(long_domain.len() > 253);
        let err = EntityId::parse(&format!("@alice:{long_domain}")).unwrap_err();
        assert!(
            err.to_string().contains("exceeds 253"),
            "expected domain length error, got: {err}"
        );

        // --- Invalid: special characters in local_part ---

        let err = EntityId::parse("@alice.bob:relay.com").unwrap_err();
        assert!(
            err.to_string().contains("invalid character '.'"),
            "expected invalid char error, got: {err}"
        );

        let err = EntityId::parse("@alice@bob:relay.com").unwrap_err();
        assert!(
            err.to_string().contains("invalid character '@'"),
            "expected invalid char error, got: {err}"
        );

        // --- Invalid: uppercase in relay_domain ---

        let err = EntityId::parse("@alice:Relay.COM").unwrap_err();
        assert!(
            err.to_string().contains("invalid character"),
            "expected invalid char error for domain, got: {err}"
        );

        // --- Valid: 64-char local_part (maximum allowed) ---

        let max_local = "a".repeat(64);
        let id = EntityId::parse(&format!("@{max_local}:relay.io")).unwrap();
        assert_eq!(id.local_part.len(), 64);

        // --- Valid: localhost domain ---

        let id = EntityId::parse("@test:localhost").unwrap();
        assert_eq!(id.relay_domain, "localhost");

        // --- Missing colon ---

        let err = EntityId::parse("@alice-relay.com").unwrap_err();
        assert!(
            err.to_string().contains("missing ':'"),
            "expected missing colon error, got: {err}"
        );
    }
}
