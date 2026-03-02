//! Index refresh strategies (bus-spec §3.4.2).
//!
//! The canonical [`RefreshStrategy`] enum is defined in
//! [`crate::registry::datatype`]. This module re-exports it for convenience
//! and may in the future contain helper logic related to refresh scheduling.

pub use crate::registry::datatype::RefreshStrategy;
