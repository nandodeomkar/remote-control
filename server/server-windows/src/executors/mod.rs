//! Windows executor implementations of the `server_core` OS-abstraction
//! traits: the real enigo-backed [`mouse_keys::EnigoMouseKeys`] plus runtime
//! no-op [`stubs`] for the four non-mouse traits (seeds for Phases 4-6).

pub mod mouse_keys;
pub mod stubs;
