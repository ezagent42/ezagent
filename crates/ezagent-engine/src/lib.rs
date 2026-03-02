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
pub mod operations;
pub mod events;
pub mod error;
pub mod sync;
