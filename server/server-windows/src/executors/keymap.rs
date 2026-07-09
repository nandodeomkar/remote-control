//! Wire `key.code` → enigo mapping tables (KEY-02).
//!
//! Lives in server-windows ONLY: server-core keeps `KeyCode` opaque
//! (zero-Windows-deps rule); the enigo `Key` mapping is OS-specific per the
//! Architectural Responsibility Map.
//!
//! An unknown `key.code` maps to `None` → the input thread drops that
//! command silently (router unknown-input convention, ASVS V5 input
//! validation, threat T-04-02) — no probing oracle, no panic.

use enigo::Key;
use server_core::executors::{Button, Modifier};
use server_core::executors::KeyCode;

/// Map a wire `key.code` string to the enigo key it injects.
///
/// `None` = unknown code → the caller drops the command silently.
pub fn map_key(_code: &KeyCode) -> Option<Key> {
    // 04-02 Task 2 locks the CLIENT_KEY_CODES vocabulary and fills this.
    None
}

/// Map a protocol modifier to its enigo key (total — `Modifier` is a closed
/// enum; `Meta` is the Windows key).
pub fn map_mod(m: Modifier) -> Key {
    match m {
        Modifier::Ctrl => Key::Control,
        Modifier::Alt => Key::Alt,
        Modifier::Shift => Key::Shift,
        Modifier::Win => Key::Meta,
    }
}

/// Map a protocol mouse button to its enigo button (total — `Button` is a
/// closed enum).
pub fn map_button(b: Button) -> enigo::Button {
    match b {
        Button::Left => enigo::Button::Left,
        Button::Middle => enigo::Button::Middle,
        Button::Right => enigo::Button::Right,
    }
}
