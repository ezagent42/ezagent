//! EZAgent Bus Engine.
//!
//! Core protocol engine implementing Datatype Registry, Hook Pipeline,
//! Annotation Pattern, and Index Builder, plus the four Built-in Datatypes
//! (Identity, Room, Timeline, Message).

pub mod registry;
pub mod hooks;
pub mod annotation;
pub mod index;
pub mod builtins;
pub mod engine;
pub mod loader;
pub mod uri_registry;
pub mod operations;
pub mod events;
pub mod error;
pub mod sync;

/// Timestamp tolerance for signature verification: +/- 5 minutes in milliseconds.
pub const TIMESTAMP_TOLERANCE_MS: i64 = 5 * 60 * 1000;
