//! PyO3 bridge exposing the full Engine operations API to Python.
//!
//! `PyEngine` wraps `ezagent_engine::engine::Engine` and delegates every
//! method through a thin conversion layer:
//!
//! - Rust `EngineError` → Python `RuntimeError`
//! - Complex return types (RoomConfig, MessageContent, serde_json::Value) →
//!   JSON strings
//! - JSON string input parameters → `serde_json::Value`

use pyo3::exceptions::PyRuntimeError;
use pyo3::prelude::*;

use ezagent_engine::engine::Engine;
use ezagent_engine::error::EngineError;
use ezagent_protocol::{EntityId, Keypair};

/// Convert an `EngineError` into a Python `RuntimeError`.
fn engine_err(e: EngineError) -> PyErr {
    PyRuntimeError::new_err(format!("{e}"))
}

/// Python-facing wrapper around the Rust `Engine`.
///
/// The Engine contains raw pointers from `libloading::Library`, making it
/// `!Send`. We use `#[pyclass(unsendable)]` to tell PyO3 that this class
/// must not be transferred across threads.
#[pyclass(unsendable)]
pub struct PyEngine {
    inner: Engine,
}

#[pymethods]
impl PyEngine {
    /// Create a new Engine with all built-in datatypes registered.
    #[new]
    fn new() -> PyResult<Self> {
        let inner = Engine::new().map_err(engine_err)?;
        Ok(Self { inner })
    }

    /// Initialize identity with an entity_id string and 32-byte secret key bytes.
    ///
    /// Args:
    ///     entity_id: Entity ID in `@local:relay.domain` format.
    ///     keypair_bytes: Exactly 32 bytes of Ed25519 secret key material.
    ///
    /// Raises:
    ///     RuntimeError: If the entity_id is invalid, keypair_bytes length is
    ///         wrong, or hook registration fails.
    fn identity_init(&mut self, entity_id: &str, keypair_bytes: &[u8]) -> PyResult<()> {
        let eid = EntityId::parse(entity_id)
            .map_err(|e| PyRuntimeError::new_err(format!("{e}")))?;

        let bytes: &[u8; 32] = keypair_bytes.try_into().map_err(|_| {
            PyRuntimeError::new_err(format!(
                "keypair_bytes must be exactly 32 bytes, got {}",
                keypair_bytes.len()
            ))
        })?;
        let keypair = Keypair::from_bytes(bytes);
        self.inner.identity_init(eid, keypair).map_err(engine_err)
    }

    /// Return the local entity ID as a string.
    ///
    /// Raises:
    ///     RuntimeError: If identity has not been initialized.
    fn identity_whoami(&self) -> PyResult<String> {
        self.inner.identity_whoami().map_err(engine_err)
    }

    /// Retrieve the hex-encoded public key for the given entity.
    ///
    /// Returns:
    ///     64-character hex string (32 bytes).
    ///
    /// Raises:
    ///     RuntimeError: If no public key is cached for the entity.
    fn identity_get_pubkey(&self, entity_id: &str) -> PyResult<String> {
        self.inner.identity_get_pubkey(entity_id).map_err(engine_err)
    }

    /// Create a new room and return its configuration as a JSON string.
    ///
    /// Returns:
    ///     JSON string of the created `RoomConfig`.
    ///
    /// Raises:
    ///     RuntimeError: If identity has not been initialized.
    fn room_create(&self, name: &str) -> PyResult<String> {
        let room = self.inner.room_create(name).map_err(engine_err)?;
        serde_json::to_string(&room)
            .map_err(|e| PyRuntimeError::new_err(format!("{e}")))
    }

    /// List all known room IDs.
    fn room_list(&self) -> PyResult<Vec<String>> {
        self.inner.room_list().map_err(engine_err)
    }

    /// Retrieve room configuration as a JSON string.
    ///
    /// Raises:
    ///     RuntimeError: If the room does not exist.
    fn room_get(&self, room_id: &str) -> PyResult<String> {
        let val = self.inner.room_get(room_id).map_err(engine_err)?;
        serde_json::to_string(&val)
            .map_err(|e| PyRuntimeError::new_err(format!("{e}")))
    }

    /// Apply partial updates to a room's configuration.
    ///
    /// Args:
    ///     room_id: The room to update.
    ///     updates_json: JSON string of the fields to update (e.g. `{"name": "New Name"}`).
    ///
    /// Raises:
    ///     RuntimeError: If JSON is invalid or the room does not exist.
    fn room_update_config(&mut self, room_id: &str, updates_json: &str) -> PyResult<()> {
        let updates: serde_json::Value = serde_json::from_str(updates_json)
            .map_err(|e| PyRuntimeError::new_err(format!("invalid JSON: {e}")))?;
        self.inner
            .room_update_config(room_id, updates)
            .map_err(engine_err)
    }

    /// Join a room as the local identity.
    ///
    /// Raises:
    ///     RuntimeError: If identity not initialized or room not found.
    fn room_join(&mut self, room_id: &str) -> PyResult<()> {
        self.inner.room_join(room_id).map_err(engine_err)
    }

    /// Leave a room as the local identity.
    ///
    /// Raises:
    ///     RuntimeError: If identity not initialized or room not found.
    fn room_leave(&mut self, room_id: &str) -> PyResult<()> {
        self.inner.room_leave(room_id).map_err(engine_err)
    }

    /// Invite an entity to a room.
    ///
    /// Raises:
    ///     RuntimeError: If the room does not exist.
    fn room_invite(&mut self, room_id: &str, entity_id: &str) -> PyResult<()> {
        self.inner
            .room_invite(room_id, entity_id)
            .map_err(engine_err)
    }

    /// List members of a room.
    ///
    /// Returns:
    ///     List of entity ID strings.
    ///
    /// Raises:
    ///     RuntimeError: If the room does not exist.
    fn room_members(&self, room_id: &str) -> PyResult<Vec<String>> {
        self.inner.room_members(room_id).map_err(engine_err)
    }

    /// Send a message to a room.
    ///
    /// Args:
    ///     room_id: Target room.
    ///     body: JSON string of the message body.
    ///     format: MIME-like format (e.g. "text/plain").
    ///
    /// Returns:
    ///     JSON string of the created `MessageContent`.
    ///
    /// Raises:
    ///     RuntimeError: If body JSON is invalid, identity not initialized, or
    ///         a pre_send hook rejects the message.
    fn message_send(&self, room_id: &str, body: &str, format: &str) -> PyResult<String> {
        let body_val: serde_json::Value = serde_json::from_str(body)
            .map_err(|e| PyRuntimeError::new_err(format!("invalid body JSON: {e}")))?;
        let content = self
            .inner
            .message_send(room_id, body_val, format)
            .map_err(engine_err)?;
        serde_json::to_string(&content)
            .map_err(|e| PyRuntimeError::new_err(format!("{e}")))
    }

    /// List timeline ref IDs for a room.
    fn timeline_list(&self, room_id: &str) -> PyResult<Vec<String>> {
        self.inner.timeline_list(room_id).map_err(engine_err)
    }

    /// Retrieve a timeline ref by ID as a JSON string.
    ///
    /// Raises:
    ///     RuntimeError: If the ref does not exist.
    fn timeline_get_ref(&self, room_id: &str, ref_id: &str) -> PyResult<String> {
        let val = self
            .inner
            .timeline_get_ref(room_id, ref_id)
            .map_err(engine_err)?;
        serde_json::to_string(&val)
            .map_err(|e| PyRuntimeError::new_err(format!("{e}")))
    }

    /// Soft-delete a message by ref ID.
    ///
    /// Raises:
    ///     RuntimeError: If the ref does not exist.
    fn message_delete(&mut self, room_id: &str, ref_id: &str) -> PyResult<()> {
        self.inner
            .message_delete(room_id, ref_id)
            .map_err(engine_err)
    }

    /// List annotations on a timeline ref as `key=value` strings.
    fn annotation_list(&self, room_id: &str, ref_id: &str) -> PyResult<Vec<String>> {
        self.inner
            .annotation_list(room_id, ref_id)
            .map_err(engine_err)
    }

    /// Add an annotation to a timeline ref.
    fn annotation_add(
        &mut self,
        room_id: &str,
        ref_id: &str,
        key: &str,
        value: &str,
    ) -> PyResult<()> {
        self.inner
            .annotation_add(room_id, ref_id, key, value)
            .map_err(engine_err)
    }

    /// Remove an annotation from a timeline ref.
    ///
    /// Raises:
    ///     RuntimeError: If no annotation with the given key exists.
    fn annotation_remove(&mut self, room_id: &str, ref_id: &str, key: &str) -> PyResult<()> {
        self.inner
            .annotation_remove(room_id, ref_id, key)
            .map_err(engine_err)
    }

    /// Get engine status.
    ///
    /// Returns:
    ///     Tuple of (identity_initialized: bool, registered_datatypes: list[str]).
    fn status(&self) -> PyResult<(bool, Vec<String>)> {
        let s = self.inner.status();
        Ok((s.identity_initialized, s.registered_datatypes))
    }
}
