//! Windows executor implementations of the `server_core` OS-abstraction
//! traits: the real enigo-backed [`mouse_keys::EnigoMouseKeys`], the Phase-5
//! [`media::WinMedia`] and [`power::WinPower`] backends, the Phase-6
//! [`apps::WinApps`] backend, plus a runtime no-op [`stubs`] `StubClipboard`
//! (Clipboard becomes real in 06-04).

pub mod apps;
pub mod keymap;
pub mod media;
pub mod mouse_keys;
pub mod power;
pub mod stubs;
