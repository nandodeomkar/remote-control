//! Real `MouseKeys` executor: forwards move/scroll deltas to the dedicated
//! input thread over an mpsc channel (RESEARCH Pattern 1).
//!
//! The trait is SYNC and called inline in the session read task (hot-path
//! rule), so every method must return immediately: `move_rel`/`scroll` are a
//! single non-blocking `send` (send-and-forget — a closed channel drops the
//! frame, never blocks or panics). Accumulation happens on the input thread
//! (see [`crate::input_thread`]), NOT here.

use std::sync::mpsc::Sender;

use server_core::executors::{Button, KeyCode, Modifier, MouseKeys};

use crate::input_thread::Cmd;

/// Enigo-backed `MouseKeys`: holds only the `Send + Sync` channel sender;
/// the `!Sync` `Enigo` handle lives on the input thread.
pub struct EnigoMouseKeys {
    tx: Sender<Cmd>,
}

impl EnigoMouseKeys {
    /// Wrap the input-thread sender created by the composition root.
    pub fn new(tx: Sender<Cmd>) -> Self {
        Self { tx }
    }
}

impl MouseKeys for EnigoMouseKeys {
    fn move_rel(&self, dx: f32, dy: f32) {
        let _ = self.tx.send(Cmd::Move(dx, dy));
    }
    fn scroll(&self, dx: f32, dy: f32) {
        let _ = self.tx.send(Cmd::Scroll(dx, dy));
    }
    fn zoom(&self, dx: f32, dy: f32) {
        let _ = self.tx.send(Cmd::Zoom(dx, dy));
    }
    fn click(&self, button: Button) {
        let _ = self.tx.send(Cmd::Click(button));
    }
    fn button_down(&self, button: Button) {
        let _ = self.tx.send(Cmd::ButtonDown(button));
    }
    fn button_up(&self, button: Button) {
        let _ = self.tx.send(Cmd::ButtonUp(button));
    }
    fn key_down(&self, code: KeyCode) {
        let _ = self.tx.send(Cmd::KeyDown(code));
    }
    fn key_up(&self, code: KeyCode) {
        let _ = self.tx.send(Cmd::KeyUp(code));
    }
    fn key_tap(&self, code: KeyCode, mods: &[Modifier]) {
        let _ = self.tx.send(Cmd::KeyTap(code, mods.to_vec()));
    }
    fn type_text(&self, text: &str) {
        // NEVER log `text` — SPEC §12 redaction (T-04-03).
        let _ = self.tx.send(Cmd::Type(text.to_string()));
    }
    fn backspace(&self, n: u32) {
        let _ = self.tx.send(Cmd::Backspace(n));
    }
}
