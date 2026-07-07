//! Dispatcher-owned held-input tracking (CONN-07, SPEC §11).
//!
//! The DISPATCHER — not the executor implementation — tracks what is
//! currently held per session, so release-on-session-end works with any
//! executor backend (mock today, enigo in Phase 2) for free. The
//! per-connection task MUST call [`HeldInput::release_all`] unconditionally
//! after its read loop exits — clean close, socket error, auth revoke, and
//! pause activation alike.

use std::collections::HashSet;

use crate::executors::{Button, KeyCode, MouseKeys};

/// Set of currently held mouse buttons and keys for one session.
#[derive(Debug, Default)]
pub struct HeldInput {
    buttons: HashSet<Button>,
    keys: HashSet<KeyCode>,
}

impl HeldInput {
    /// Record a button press (`drag start`).
    pub fn note_button_down(&mut self, button: Button) {
        self.buttons.insert(button);
    }

    /// Record a button release (`drag end`).
    pub fn note_button_up(&mut self, button: Button) {
        self.buttons.remove(&button);
    }

    /// Record a key press (`key down`).
    pub fn note_key_down(&mut self, code: KeyCode) {
        self.keys.insert(code);
    }

    /// Record a key release (`key up`).
    pub fn note_key_up(&mut self, code: KeyCode) {
        self.keys.remove(&code);
    }

    /// Release EVERYTHING still held: `button_up` for each held button,
    /// `key_up` for each held key, leaving this set empty (CONN-07 — no
    /// phantom held input survives a mid-drag disconnect).
    ///
    /// Idempotent: draining leaves both sets empty, so a second call emits
    /// nothing.
    pub fn release_all(&mut self, mk: &dyn MouseKeys) {
        for button in self.buttons.drain() {
            mk.button_up(button);
        }
        for code in self.keys.drain() {
            mk.key_up(code);
        }
    }

    /// True when nothing is held (used to assert clean session starts).
    pub fn is_empty(&self) -> bool {
        self.buttons.is_empty() && self.keys.is_empty()
    }
}
