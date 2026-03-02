//! Hook Pipeline — 3-phase lifecycle callback system (bus-spec SS3.2).
//!
//! The Hook Pipeline is one of the four Engine pillars. It provides a
//! deterministic execution framework for hooks across three phases:
//! `PreSend`, `AfterWrite`, and `AfterRead`.

pub mod executor;
pub mod phase;

pub use executor::{HookEntry, HookExecutor, HookFn};
pub use phase::{HookContext, HookDeclaration, HookPhase, TriggerEvent};
