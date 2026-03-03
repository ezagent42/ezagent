//! EZAgent Bus Engine.
//!
//! Core protocol engine implementing Datatype Registry, Hook Pipeline,
//! Annotation Pattern, and Index Builder, plus the four Built-in Datatypes
//! (Identity, Room, Timeline, Message).

pub mod annotation;
pub mod builtins;
pub mod engine;
pub mod error;
pub mod events;
pub mod hooks;
pub mod index;
pub mod loader;
pub mod operations;
pub mod registry;
pub mod sync;
pub mod uri_registry;

/// Timestamp tolerance for signature verification: +/- 5 minutes in milliseconds.
pub const TIMESTAMP_TOLERANCE_MS: i64 = 5 * 60 * 1000;
