//! Key pattern templates for document addressing.
//!
//! A key pattern is a path template like `rooms/{room_id}/messages/{msg_id}`
//! that can be instantiated with concrete values.

use std::collections::HashMap;

use serde::{Deserialize, Serialize};

use crate::error::ProtocolError;

/// A key pattern template with `{var}` placeholders.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct KeyPattern {
    template: String,
}

impl KeyPattern {
    /// Create a new key pattern from a template string.
    pub fn new(template: impl Into<String>) -> Self {
        Self {
            template: template.into(),
        }
    }

    /// Return the raw template string.
    pub fn template(&self) -> &str {
        &self.template
    }

    /// Instantiate the template by replacing `{var}` placeholders with values.
    ///
    /// Returns an error if a placeholder has no corresponding value.
    pub fn instantiate(&self, vars: &HashMap<&str, &str>) -> Result<String, ProtocolError> {
        let mut result = self.template.clone();
        let mut start = 0;

        // Find all {var} placeholders and replace them
        while let Some(pos) = result[start..].find('{') {
            let open = start + pos;
            let close = match result[open..].find('}') {
                Some(pos) => open + pos,
                None => break,
            };

            let var_name = &result[open + 1..close];
            let value = vars.get(var_name).ok_or_else(|| {
                ProtocolError::InvalidKeyPattern(format!("missing variable: {var_name}"))
            })?;

            result.replace_range(open..=close, value);
            start = open + value.len();
        }

        Ok(result)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn instantiate_single_var() {
        let kp = KeyPattern::new("rooms/{room_id}/messages");
        let mut vars = HashMap::new();
        vars.insert("room_id", "abc123");
        let result = kp.instantiate(&vars).unwrap();
        assert_eq!(result, "rooms/abc123/messages");
    }

    #[test]
    fn instantiate_multiple_vars() {
        let kp = KeyPattern::new("rooms/{room_id}/messages/{msg_id}");
        let mut vars = HashMap::new();
        vars.insert("room_id", "room-1");
        vars.insert("msg_id", "msg-42");
        let result = kp.instantiate(&vars).unwrap();
        assert_eq!(result, "rooms/room-1/messages/msg-42");
    }

    #[test]
    fn missing_variable_errors() {
        let kp = KeyPattern::new("rooms/{room_id}/messages/{msg_id}");
        let mut vars = HashMap::new();
        vars.insert("room_id", "abc");
        let err = kp.instantiate(&vars).unwrap_err();
        assert!(err.to_string().contains("missing variable: msg_id"));
    }

    #[test]
    fn no_placeholders() {
        let kp = KeyPattern::new("static/path");
        let vars = HashMap::new();
        let result = kp.instantiate(&vars).unwrap();
        assert_eq!(result, "static/path");
    }

    #[test]
    fn template_accessor() {
        let kp = KeyPattern::new("rooms/{room_id}");
        assert_eq!(kp.template(), "rooms/{room_id}");
    }

    #[test]
    fn serde_roundtrip() {
        let kp = KeyPattern::new("rooms/{room_id}/data");
        let json = serde_json::to_string(&kp).unwrap();
        let kp2: KeyPattern = serde_json::from_str(&json).unwrap();
        assert_eq!(kp.template(), kp2.template());
    }
}
