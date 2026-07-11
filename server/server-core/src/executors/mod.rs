//! The five OS-abstraction executor traits + protocol-level input types.
//!
//! Traits are SYNC (`&self` methods, `Send + Sync`): input injection
//! (enigo's SendInput in Phase 2) is synchronous and cheap, sync traits keep
//! mocks trivial, and dispatch stays inline in the read task (hot-path
//! rule). NO OS types anywhere — window ids are plain `u64`, keys are
//! protocol strings. OS implementations live in a sibling crate (Phase 2+).

pub mod mock;

use std::sync::Arc;

use serde::{Deserialize, Serialize};

/// Protocol mouse button (`click.button` / `drag.button` wire values).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Button {
    Left,
    Middle,
    Right,
}

/// Protocol key code — the wire `key.code` string, opaque to the core.
/// The OS executor maps it to a real key; the dispatcher only needs
/// equality/hashing for held-input tracking.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct KeyCode(pub String);

/// Protocol keyboard modifier (`key.mods` wire values).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Modifier {
    Ctrl,
    Alt,
    Shift,
    Win,
}

/// One entry of the `apps.list` / `apps.changed` window table. `id` is an
/// opaque protocol-level identifier (NEVER an HWND-shaped OS type).
///
/// `icon`/`path` are the protocol-1.2 additive amendment (D-07 / APPS-02):
/// both are `Option` with `skip_serializing_if` so a legacy 1.0/1.1 window
/// (neither field) still decodes and re-encodes without emitting the keys.
/// `icon` is a base64 PNG (32×32); `path` is the resolved exe path (`None`
/// for non-pinnable/UWP windows). `Option<String>` keeps the `Eq` derive.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct WindowInfo {
    pub id: u64,
    pub title: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub icon: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub path: Option<String>,
}

/// Mouse + keyboard injection.
///
/// Explicit `*_down`/`*_up` pairs exist (not just tap/click) because the
/// dispatcher's held-input map updates on `down` and clears on `up`
/// (CONN-07).
pub trait MouseKeys: Send + Sync {
    fn move_rel(&self, dx: f32, dy: f32);
    fn scroll(&self, dx: f32, dy: f32);
    fn click(&self, button: Button);
    fn button_down(&self, button: Button);
    fn button_up(&self, button: Button);
    fn key_down(&self, code: KeyCode);
    fn key_up(&self, code: KeyCode);
    fn key_tap(&self, code: KeyCode, mods: &[Modifier]);
    fn type_text(&self, text: &str);
    fn backspace(&self, n: u32);
}

/// Media keys + absolute volume.
pub trait Media: Send + Sync {
    fn play_pause(&self);
    fn next(&self);
    fn prev(&self);
    fn vol_up(&self);
    fn vol_down(&self);
    fn mute(&self);
    fn set_volume(&self, pct: u8);
}

/// Power actions (always behind the `power` → `confirm` double-confirm gate,
/// SPEC §7).
pub trait Power: Send + Sync {
    fn lock(&self);
    fn sleep(&self);
    fn restart(&self);
    fn shutdown(&self);
}

/// Window enumeration and app control.
pub trait Apps: Send + Sync {
    fn list(&self) -> Vec<WindowInfo>;
    fn launch(&self, path: &str);
    fn focus(&self, id: u64);
    fn close(&self, id: u64);
}

/// Clipboard text get/set.
pub trait Clipboard: Send + Sync {
    fn get(&self) -> String;
    fn set(&self, text: &str);
}

/// The full executor bundle injected into dispatch and transport.
#[derive(Clone)]
pub struct Executors {
    pub mouse_keys: Arc<dyn MouseKeys>,
    pub media: Arc<dyn Media>,
    pub power: Arc<dyn Power>,
    pub apps: Arc<dyn Apps>,
    pub clipboard: Arc<dyn Clipboard>,
}
