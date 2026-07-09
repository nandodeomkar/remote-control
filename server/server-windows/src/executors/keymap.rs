//! Wire `key.code` → enigo mapping tables (KEY-02) + the ONE locked
//! `key.code` vocabulary (Open Q3 — resolved here).
//!
//! # The locked `key.code` contract (CLIENT_KEY_CODES)
//!
//! [`CLIENT_KEY_CODES`] is the canonical vocabulary the Flutter key rows
//! (04-06 `key_rows.dart`, `kClientKeyCodes`) MUST emit — byte-for-byte.
//! Any change lands in BOTH files. The terse style follows the existing
//! router macro tables (`router.rs` browser/present: "F5", "Right", "Esc").
//!
//! - Nav cluster: `Esc Tab Home End PgUp PgDn Del`
//! - Arrows: `Up Down Left Right`
//! - Function row: `F1` .. `F12`
//! - Numpad: `Num0` .. `Num9`, plus `NumEnter` and `NumDot` (numpad-prefixed
//!   over bare `Enter`/`.` so a future main-Enter key can't collide;
//!   `NumEnter` injects `Key::Return` — enigo 0.6.1 has no distinct
//!   numpad-enter variant — and `NumDot` injects `Key::Decimal`)
//! - Modifier HOLD codes: `ControlLeft AltLeft ShiftLeft WinLeft` — a LOCKED
//!   modifier is a physical hold via `key {action: down/up}` with these
//!   codes (D-10, RESEARCH Open Q2 / Pitfall 7), so held-key combos
//!   autorepeat with the modifier and CONN-07 release_all frees them.
//!
//! The router's Phase-1 browser/present macro tables also reach [`map_key`]
//! via `key_tap` — those codes ([`ROUTER_MACRO_CODES`]) are covered too so
//! browser/present actions execute instead of silently no-opping.
//!
//! Lives in server-windows ONLY: server-core keeps `KeyCode` opaque
//! (zero-Windows-deps rule); the enigo `Key` mapping is OS-specific per the
//! Architectural Responsibility Map.
//!
//! An unknown `key.code` maps to `None` → the input thread drops that
//! command silently (router unknown-input convention, ASVS V5 input
//! validation, threat T-04-02) — no probing oracle, no panic.

use enigo::Key;
use server_core::executors::{Button, KeyCode, Modifier};

/// The canonical client `key.code` vocabulary — the single source of truth
/// shared with the Flutter key rows' `kClientKeyCodes` (04-06) and the
/// coverage test below. Every string here MUST map to `Some` in [`map_key`].
pub const CLIENT_KEY_CODES: &[&str] = &[
    // Nav cluster (UI-SPEC key rows: Nav group)
    "Esc", "Tab", "Home", "End", "PgUp", "PgDn", "Del",
    // Arrows (inverted-T cluster)
    "Up", "Down", "Left", "Right",
    // Function row
    "F1", "F2", "F3", "F4", "F5", "F6", "F7", "F8", "F9", "F10", "F11", "F12",
    // Numpad (3-column grid + Enter + decimal)
    "Num0", "Num1", "Num2", "Num3", "Num4", "Num5", "Num6", "Num7", "Num8",
    "Num9", "NumEnter", "NumDot",
    // Modifier hold codes (D-10 locked-modifier physical hold path)
    "ControlLeft", "AltLeft", "ShiftLeft", "WinLeft",
];

/// Codes the router's Phase-1 browser/present macro tables emit through
/// `key_tap` (router.rs `browser_macro`/`present_macro`) that are NOT part
/// of the client key-row vocabulary. They must map too, or browser/present
/// actions silently no-op ("F5"/"Right"/"Left"/"Esc" overlap
/// [`CLIENT_KEY_CODES`] and are covered there).
pub const ROUTER_MACRO_CODES: &[&str] =
    &["BrowserBack", "BrowserForward", "T", "W", "B", "Plus", "Minus"];

/// Map a wire `key.code` string to the enigo key it injects.
///
/// `None` = unknown code → the caller drops the command silently.
pub fn map_key(_code: &KeyCode) -> Option<Key> {
    // 04-02 Task 2 GREEN fills the vocabulary table.
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

#[cfg(test)]
mod tests {
    use super::*;

    /// KEY-02 coverage gate: EVERY code in the locked client vocabulary maps
    /// to a real enigo key — no silently dropped key caps.
    #[test]
    fn keymap_covers_all_codes() {
        for code in CLIENT_KEY_CODES {
            assert!(
                map_key(&KeyCode((*code).to_string())).is_some(),
                "CLIENT_KEY_CODES entry {code:?} must map to Some(enigo Key)"
            );
        }
    }

    /// The router's Phase-1 browser/present macros reach map_key via
    /// key_tap — their codes must execute, not silently no-op.
    #[test]
    fn router_macro_codes_covered() {
        for code in ROUTER_MACRO_CODES {
            assert!(
                map_key(&KeyCode((*code).to_string())).is_some(),
                "router macro code {code:?} must map to Some(enigo Key)"
            );
        }
    }

    /// T-04-02: a genuinely unknown code is `None` (drop, never panic).
    #[test]
    fn unknown_code_maps_none() {
        assert_eq!(map_key(&KeyCode("NotAKey".into())), None);
    }

    /// Modifier and button tables are exact: ctrl/alt/shift/win →
    /// Control/Alt/Shift/Meta; left/middle/right → the enigo mouse buttons.
    #[test]
    fn modifier_and_button_tables() {
        assert_eq!(map_mod(Modifier::Ctrl), Key::Control);
        assert_eq!(map_mod(Modifier::Alt), Key::Alt);
        assert_eq!(map_mod(Modifier::Shift), Key::Shift);
        assert_eq!(map_mod(Modifier::Win), Key::Meta);
        assert_eq!(map_button(Button::Left), enigo::Button::Left);
        assert_eq!(map_button(Button::Middle), enigo::Button::Middle);
        assert_eq!(map_button(Button::Right), enigo::Button::Right);
    }
}
