//! Annotation pattern validation (bus-spec §3).
//!
//! Annotations are NOT a separate store — they are a design pattern for keys
//! within CRDT maps. An annotation key follows the format `{semantic}:{entity_id}`,
//! where `entity_id` starts with `@` and may itself contain colons (e.g.,
//! `@bob:relay-a.example.com`).
//!
//! Key rules:
//! 1. **Namespace:** `ext.{ext_id}` within a CRDT map
//! 2. **Key format:** `{semantic}:{entity_id}` (e.g., `note:@bob:relay-a.example.com`)
//! 3. **Writer restriction:** Writer can only modify keys containing their own entity_id
//! 4. **Preservation:** Unknown `ext.*` fields MUST be preserved (CRDT default)
//! 5. **Sync:** Annotations sync with their host document

use crate::error::EngineError;

/// Validate that an annotation key follows the format `{semantic}:{entity_id}`.
///
/// The key is split at the first `:` — the left part is the semantic portion
/// and the right part is the entity_id. The entity_id must start with `@`.
///
/// # Returns
///
/// A `(semantic, entity_id)` tuple on success.
///
/// # Errors
///
/// Returns `EngineError::InvalidAnnotationKey` if the key has no colon,
/// or if the entity_id portion does not start with `@`.
pub fn validate_annotation_key(key: &str) -> Result<(String, String), EngineError> {
    let colon_pos = key.find(':').ok_or_else(|| {
        EngineError::InvalidAnnotationKey(format!("key must contain ':' separator, got '{key}'"))
    })?;

    let semantic = &key[..colon_pos];
    let entity_id = &key[colon_pos + 1..];

    if semantic.is_empty() {
        return Err(EngineError::InvalidAnnotationKey(
            "semantic part must not be empty".to_string(),
        ));
    }

    if !entity_id.starts_with('@') {
        return Err(EngineError::InvalidAnnotationKey(format!(
            "entity_id must start with '@', got '{entity_id}'"
        )));
    }

    Ok((semantic.to_string(), entity_id.to_string()))
}

/// Check if the signer entity_id is allowed to write this annotation key.
///
/// The key must contain the signer's entity_id. This enforces the writer
/// restriction: a writer can only modify annotation keys that reference
/// their own entity_id.
///
/// # Errors
///
/// Returns `EngineError::PermissionDenied` if the entity_id extracted from
/// the key does not match the signer's entity_id.
pub fn check_annotation_writer(key: &str, signer_entity_id: &str) -> Result<(), EngineError> {
    let (_semantic, entity_id) = validate_annotation_key(key)?;

    if entity_id != signer_entity_id {
        return Err(EngineError::PermissionDenied(format!(
            "signer '{signer_entity_id}' cannot write annotation key for entity '{entity_id}'"
        )));
    }

    Ok(())
}

/// Validate an annotation namespace prefix (e.g., `"ext.reactions"`).
///
/// The namespace must start with `"ext."` and the extension id after the
/// prefix must not be empty.
///
/// # Returns
///
/// The extension id (the part after `"ext."`) on success.
///
/// # Errors
///
/// Returns `EngineError::InvalidNamespace` if the namespace does not start
/// with `"ext."` or if the extension id is empty.
pub fn validate_namespace(namespace: &str) -> Result<String, EngineError> {
    let ext_id = namespace.strip_prefix("ext.").ok_or_else(|| {
        EngineError::InvalidNamespace(format!(
            "namespace must start with 'ext.', got '{namespace}'"
        ))
    })?;

    if ext_id.is_empty() {
        return Err(EngineError::InvalidNamespace(
            "extension id after 'ext.' must not be empty".to_string(),
        ));
    }

    Ok(ext_id.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// TC-1-ANNOT-001: valid annotation key parses correctly.
    #[test]
    fn tc_1_annot_001_valid_annotation_key() {
        let result = validate_annotation_key("note:@bob:relay.example.com");
        assert!(result.is_ok(), "expected Ok, got {result:?}");
        let (semantic, entity_id) = result.unwrap();
        assert_eq!(semantic, "note");
        assert_eq!(entity_id, "@bob:relay.example.com");
    }

    /// TC-1-ANNOT-002: key without colon is rejected.
    #[test]
    fn tc_1_annot_002_invalid_key_no_colon() {
        let result = validate_annotation_key("invalid");
        assert!(result.is_err(), "expected Err for key without colon");
        let err = result.unwrap_err();
        assert!(
            matches!(err, EngineError::InvalidAnnotationKey(_)),
            "expected InvalidAnnotationKey, got {err:?}"
        );
    }

    /// TC-1-ANNOT-003: writer restriction passes when signer matches key entity.
    #[test]
    fn tc_1_annot_003_writer_restriction_ok() {
        let result =
            check_annotation_writer("note:@bob:relay.example.com", "@bob:relay.example.com");
        assert!(
            result.is_ok(),
            "expected Ok for matching signer, got {result:?}"
        );
    }

    /// TC-1-ANNOT-004: writer restriction denied when signer doesn't match.
    #[test]
    fn tc_1_annot_004_writer_restriction_denied() {
        let result =
            check_annotation_writer("note:@bob:relay.example.com", "@alice:relay.example.com");
        assert!(result.is_err(), "expected Err for mismatched signer");
        let err = result.unwrap_err();
        assert!(
            matches!(err, EngineError::PermissionDenied(_)),
            "expected PermissionDenied, got {err:?}"
        );
    }

    /// TC-1-ANNOT-005: namespace validation accepts valid and rejects invalid.
    #[test]
    fn tc_1_annot_005_namespace_validation() {
        // Valid namespace
        let result = validate_namespace("ext.reactions");
        assert!(
            result.is_ok(),
            "expected Ok for 'ext.reactions', got {result:?}"
        );
        assert_eq!(result.unwrap(), "reactions");

        // Invalid namespace — no "ext." prefix
        let result = validate_namespace("invalid");
        assert!(
            result.is_err(),
            "expected Err for namespace without 'ext.' prefix"
        );
        let err = result.unwrap_err();
        assert!(
            matches!(err, EngineError::InvalidNamespace(_)),
            "expected InvalidNamespace, got {err:?}"
        );

        // Invalid namespace — empty ext_id
        let result = validate_namespace("ext.");
        assert!(result.is_err(), "expected Err for empty ext_id");
        let err = result.unwrap_err();
        assert!(
            matches!(err, EngineError::InvalidNamespace(_)),
            "expected InvalidNamespace, got {err:?}"
        );
    }
}
