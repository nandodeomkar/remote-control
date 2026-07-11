//! Windows executor implementations of the `server_core` OS-abstraction
//! traits: the real enigo-backed [`mouse_keys::EnigoMouseKeys`], the Phase-5
//! [`media::WinMedia`] and [`power::WinPower`] backends, plus runtime no-op
//! [`stubs`] for the two remaining non-mouse traits (Apps/Clipboard — Phase 6).

pub mod keymap;
pub mod media;
pub mod mouse_keys;
pub mod power;
pub mod stubs;
