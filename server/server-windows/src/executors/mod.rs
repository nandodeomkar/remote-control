//! Windows executor implementations of the `server_core` OS-abstraction
//! traits: the real enigo-backed [`mouse_keys::EnigoMouseKeys`], the Phase-5
//! [`media::WinMedia`] and [`power::WinPower`] backends, and the Phase-6
//! [`apps::WinApps`] + [`clipboard::WinClipboard`] backends. All five traits
//! now have real Windows implementations — the interim `stubs` module is gone.

pub mod apps;
pub mod clipboard;
pub mod keymap;
pub mod media;
pub mod mouse_keys;
pub mod power;
