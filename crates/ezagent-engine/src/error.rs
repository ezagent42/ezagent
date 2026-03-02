//! Engine-level error types.

use thiserror::Error;

/// Errors originating from the Engine layer.
#[derive(Debug, Error)]
pub enum EngineError {
    #[error("circular dependency detected: {cycle}")]
    CircularDependency { cycle: String },

    #[error("dependency not met: {ext} requires {requires}")]
    DependencyNotMet { ext: String, requires: String },

    #[error("duplicate datatype: {0}")]
    DuplicateDatatype(String),

    #[error("datatype not found: {0}")]
    DatatypeNotFound(String),

    #[error("extensions cannot register global hooks")]
    ExtensionCannotRegisterGlobalHook,

    #[error("hook rejected: {0}")]
    HookRejected(String),

    #[error("not a member: {entity_id} is not in room {room_id}")]
    NotAMember { entity_id: String, room_id: String },

    #[error("permission denied: {0}")]
    PermissionDenied(String),

    #[error("extension disabled: {extension} in room {room_id}")]
    ExtensionDisabled { extension: String, room_id: String },

    #[error("protocol error: {0}")]
    Protocol(#[from] ezagent_protocol::ProtocolError),

    #[error("backend error: {0}")]
    Backend(#[from] ezagent_backend::BackendError),
}
