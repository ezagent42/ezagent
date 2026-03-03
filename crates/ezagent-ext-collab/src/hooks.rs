//! Collaborative content ACL validation hooks for the Collab extension.
//!
//! This module provides the core validation logic for collaborative
//! content access control. Three ACL modes govern write access:
//!
//! - `owner_only` — Only the document owner can write.
//! - `explicit` — Owner plus explicitly listed editors can write.
//! - `room_members` — All room members can write.
//!
//! # ACL Upgrade Path
//!
//! ```text
//! owner_only → explicit → room_members
//! ```
//!
//! Downgrades (e.g., `room_members → explicit`) are not permitted.

/// Valid ACL modes for collaborative content.
const VALID_ACL_MODES: &[&str] = &["owner_only", "explicit", "room_members"];

/// Errors from collab hook validation.
#[derive(Debug, thiserror::Error)]
pub enum CollabHookError {
    /// The signer is not the owner of the collaborative content.
    #[error("signer '{signer}' is not the owner '{owner}'")]
    NotOwner { owner: String, signer: String },

    /// The signer is not in the editors list.
    #[error("signer '{signer}' is not in the editors list")]
    NotInEditors { signer: String },

    /// The ACL mode is not recognized.
    #[error("invalid ACL mode '{mode}': must be one of owner_only, explicit, room_members")]
    InvalidAclMode { mode: String },
}

/// Validate that the signer is the owner.
///
/// Used when ACL mode is `owner_only`.
///
/// # Errors
///
/// Returns [`CollabHookError::NotOwner`] if `owner != signer`.
pub fn validate_acl_owner(owner: &str, signer: &str) -> Result<(), CollabHookError> {
    if owner != signer {
        return Err(CollabHookError::NotOwner {
            owner: owner.to_string(),
            signer: signer.to_string(),
        });
    }
    Ok(())
}

/// Validate that the ACL mode string is one of the recognized values.
///
/// # Errors
///
/// Returns [`CollabHookError::InvalidAclMode`] if `mode` is not one of
/// `"owner_only"`, `"explicit"`, or `"room_members"`.
pub fn validate_acl_mode(mode: &str) -> Result<(), CollabHookError> {
    if !VALID_ACL_MODES.contains(&mode) {
        return Err(CollabHookError::InvalidAclMode {
            mode: mode.to_string(),
        });
    }
    Ok(())
}

/// Returns the rank of an ACL mode for upgrade path validation.
///
/// Lower rank means more restrictive. Returns `None` for invalid modes.
fn acl_mode_rank(mode: &str) -> Option<u8> {
    match mode {
        "owner_only" => Some(0),
        "explicit" => Some(1),
        "room_members" => Some(2),
        _ => None,
    }
}

/// Validate an ACL mode upgrade.
///
/// The upgrade path is: `owner_only → explicit → room_members`.
/// Downgrades are not permitted.
///
/// # Errors
///
/// Returns [`CollabHookError::InvalidAclMode`] if either mode is
/// invalid or if the transition would be a downgrade.
pub fn validate_acl_upgrade(
    current_mode: &str,
    new_mode: &str,
) -> Result<(), CollabHookError> {
    let current_rank = acl_mode_rank(current_mode).ok_or_else(|| CollabHookError::InvalidAclMode {
        mode: current_mode.to_string(),
    })?;
    let new_rank = acl_mode_rank(new_mode).ok_or_else(|| CollabHookError::InvalidAclMode {
        mode: new_mode.to_string(),
    })?;

    if new_rank < current_rank {
        return Err(CollabHookError::InvalidAclMode {
            mode: format!("cannot downgrade from '{current_mode}' to '{new_mode}'"),
        });
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    // ── validate_acl_owner tests ─────────────────────────────────────

    #[test]
    fn owner_matches_signer() {
        validate_acl_owner(
            "@alice:relay.example.com",
            "@alice:relay.example.com",
        )
        .unwrap();
    }

    #[test]
    fn owner_does_not_match_signer() {
        let err = validate_acl_owner(
            "@alice:relay.example.com",
            "@bob:relay.example.com",
        )
        .unwrap_err();
        assert!(
            matches!(err, CollabHookError::NotOwner { .. }),
            "unexpected error: {err}"
        );
    }

    // ── validate_acl_mode tests ──────────────────────────────────────

    #[test]
    fn valid_acl_modes() {
        validate_acl_mode("owner_only").unwrap();
        validate_acl_mode("explicit").unwrap();
        validate_acl_mode("room_members").unwrap();
    }

    #[test]
    fn invalid_acl_mode() {
        let err = validate_acl_mode("public").unwrap_err();
        assert!(
            matches!(err, CollabHookError::InvalidAclMode { .. }),
            "unexpected error: {err}"
        );
    }

    #[test]
    fn empty_acl_mode() {
        let err = validate_acl_mode("").unwrap_err();
        assert!(
            matches!(err, CollabHookError::InvalidAclMode { .. }),
            "unexpected error: {err}"
        );
    }

    // ── validate_acl_upgrade tests ───────────────────────────────────

    #[test]
    fn valid_upgrade_owner_to_explicit() {
        validate_acl_upgrade("owner_only", "explicit").unwrap();
    }

    #[test]
    fn valid_upgrade_explicit_to_room_members() {
        validate_acl_upgrade("explicit", "room_members").unwrap();
    }

    #[test]
    fn valid_upgrade_owner_to_room_members() {
        validate_acl_upgrade("owner_only", "room_members").unwrap();
    }

    #[test]
    fn valid_same_mode() {
        validate_acl_upgrade("explicit", "explicit").unwrap();
    }

    #[test]
    fn invalid_downgrade_room_to_explicit() {
        let err = validate_acl_upgrade("room_members", "explicit").unwrap_err();
        assert!(
            matches!(err, CollabHookError::InvalidAclMode { .. }),
            "unexpected error: {err}"
        );
    }

    #[test]
    fn invalid_downgrade_explicit_to_owner() {
        let err = validate_acl_upgrade("explicit", "owner_only").unwrap_err();
        assert!(
            matches!(err, CollabHookError::InvalidAclMode { .. }),
            "unexpected error: {err}"
        );
    }

    #[test]
    fn invalid_downgrade_room_to_owner() {
        let err = validate_acl_upgrade("room_members", "owner_only").unwrap_err();
        assert!(
            matches!(err, CollabHookError::InvalidAclMode { .. }),
            "unexpected error: {err}"
        );
    }

    #[test]
    fn invalid_current_mode_in_upgrade() {
        let err = validate_acl_upgrade("bogus", "explicit").unwrap_err();
        assert!(
            matches!(err, CollabHookError::InvalidAclMode { .. }),
            "unexpected error: {err}"
        );
    }

    #[test]
    fn invalid_new_mode_in_upgrade() {
        let err = validate_acl_upgrade("owner_only", "bogus").unwrap_err();
        assert!(
            matches!(err, CollabHookError::InvalidAclMode { .. }),
            "unexpected error: {err}"
        );
    }
}
