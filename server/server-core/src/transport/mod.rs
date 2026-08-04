//! WebSocket transport: accept loop + per-connection session tasks, plus
//! the UDP discovery beacon broadcaster ([`beacon`] — public because the
//! composition root spawns it with OS-injected identity).
//!
//! `run` is the crate's single entry point (re-exported as
//! `server_core::run`): the caller binds the listener (tests use
//! `127.0.0.1:0`; the real server binds LAN interfaces only) and injects
//! everything else via [`ServerDeps`].
//!
//! Transport limits (SPEC §13): `max_message_size` and `max_frame_size` are
//! 64 KB, enforced pre- and post-auth. Every accepted stream gets
//! `set_nodelay(true)` (Phase-2 latency prerequisite).

pub mod beacon;
pub mod ext;
mod listener;
mod session;

/// Re-exported so tests (and any composition root) asserting "the current
/// server version" reference the constant instead of duplicating the
/// literal (RESEARCH Pitfall 10).
pub use session::SERVER_PROTO_VERSION;

use std::sync::{Arc, Mutex};

use crate::auth::AuthManager;
use crate::executors::{BookmarksState, Executors, TabsState, UpdateProgress, WindowInfo};

/// Server-side volume state pushed to authed sessions as `vol.changed`
/// (MED-02, D-03). Core-owned plain data — ZERO OS deps, so server-core
/// keeps compiling on CI Linux; the Windows audio thread (05-05) is merely
/// a producer on the other end of the watch channel.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct VolumeState {
    /// Master volume percent, 0..=100.
    pub value: u8,
    /// Master mute flag.
    pub muted: bool,
}

/// Server-side clipboard text pushed to authed sessions as `clip.changed`
/// (CLIP-03). Core-owned plain data — ZERO OS deps, so server-core keeps
/// compiling on CI Linux; the Windows clip thread (06-04) is merely a
/// producer on the other end of the watch channel.
///
/// Unlike [`VolumeState`] there is DELIBERATELY no after-auth snapshot:
/// dumping the PC clipboard to every connecting phone is a privacy leak
/// (RESEARCH Pitfall 8). Clip is pull-only (`clip.get`) plus change-push,
/// and sensitive/oversized clips are skipped by the producer BEFORE they
/// ever reach this state. Not `Copy` (owns a `String`).
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct ClipState {
    /// The current PC clipboard text (already filtered by the producer:
    /// sensitive and >16 KiB clips never enter this snapshot).
    pub text: String,
}

/// Everything the transport needs, injected by the composition root (the
/// Phase-2 binary, or a test).
///
/// The [`AuthManager`] is shared and externally visible so the host UI can
/// drive pairing (display the PIN) — and so tests can read the active PIN.
pub struct ServerDeps {
    /// Executor bundle (mocks in tests, OS backends in Phase 2+).
    pub executors: Executors,
    /// Shared auth/pairing state machine (lockout state outlives sessions).
    pub auth: Arc<Mutex<AuthManager>>,
    /// Server-side pause flag; sessions observe changes live (SPEC §11).
    pub pause: tokio::sync::watch::Receiver<bool>,
    /// Latest server volume state (D-03): authed sessions receive one
    /// `vol.changed` snapshot right after auth and a push on every change.
    pub volume: tokio::sync::watch::Receiver<VolumeState>,
    /// Latest window list (APPS-03): authed sessions receive an
    /// `apps.changed` push on every change. Unlike volume there is NO
    /// after-auth snapshot — the client pulls the current list via
    /// `apps.list` on the Apps screen. Core-owned plain data (WindowInfo is
    /// all `String`s), so server-core keeps compiling on CI Linux; the
    /// Windows apps thread (06-02) is merely a producer on the other end.
    pub apps: tokio::sync::watch::Receiver<Vec<WindowInfo>>,
    /// Latest PC clipboard text (CLIP-03): authed sessions receive a
    /// `clip.changed` push on every change. Unlike volume there is NO
    /// after-auth snapshot — dumping the PC clipboard to a connecting phone
    /// is a privacy leak (RESEARCH Pitfall 8); the client pulls the current
    /// value via `clip.get`. The producer (06-04 clip thread) skips
    /// sensitive/oversized clips before they reach this watch, so a push is
    /// always a policy-clean text change.
    pub clip: tokio::sync::watch::Receiver<ClipState>,
    /// Live connected-device count (SRV-01): every session bumps this by one
    /// on its Authed transition and decrements it in the CONN-07 cleanup.
    /// `Arc`-shared so every session clones a handle to the SAME sender; the
    /// tray thread subscribes a `Receiver` off it for the tooltip.
    pub conn_count: std::sync::Arc<tokio::sync::watch::Sender<usize>>,
    /// Revocation epoch (D-05): bumped whenever `AuthManager::revoke` removes
    /// a paired hash. A session whose authed hash is no longer in
    /// `AuthManager::paired_hashes()` force-disconnects on the next advance —
    /// landing on the existing CONN-07 cleanup, no new teardown code.
    pub revoke: tokio::sync::watch::Receiver<u64>,
    /// Input-blocked epoch (SRV-05): bumped by the input thread's proactive
    /// UIPI detection on every foreground-blocked transition. Authed sessions
    /// push an `input.blocked` frame on each advance. Unlike volume there is
    /// NO after-auth snapshot (mirrors apps/clip) — this is a transition
    /// event, not a state prime.
    pub blocked: tokio::sync::watch::Receiver<u64>,
    /// Latest tab-relay state (BROW-01, protoVersion 1.4): authed sessions
    /// receive a `tabs.changed` push on every change — including the
    /// extension connect/disconnect flips. Apps-style: NO after-auth
    /// snapshot; the phone pulls the current state via `tabs.list` on the
    /// Browser screen. Producer is [`ext::run_ext`] on the loopback
    /// extension listener.
    pub tabs: tokio::sync::watch::Receiver<TabsState>,
    /// Latest bookmark-relay state (protoVersion 1.6, phase 11): authed
    /// sessions receive a `bm.changed` push on every change — INCLUDING the
    /// extension connect/disconnect flips, which is what flips both browser
    /// segments to the install hint together. Apps-style: there is NO
    /// after-auth snapshot; the phone pulls the current state via `bm.list`
    /// on first Bookmarks-segment display (D-03 lazy prime). Producer is
    /// [`ext::run_ext`] on the loopback extension listener.
    pub bookmarks: tokio::sync::watch::Receiver<BookmarksState>,
    /// Latest in-app update progress (protoVersion 1.8, phase 12, D-10):
    /// authed sessions receive an `update.progress` push on every change.
    ///
    /// Apps-style: there is NO after-auth snapshot, and here that is stronger
    /// than a convention — progress is a TRANSITION event, not a state prime.
    /// Pushing the last value at connect time would paint a finished (or
    /// failed) update onto a session that never asked for one; the phone pulls
    /// what it needs via `update.check`/`update.status` instead.
    ///
    /// Producer is the Windows update thread (`server-windows`'s
    /// `update::update_thread`) — the only tier allowed to do update I/O — plus
    /// `WinUpdate` itself for the immediate pre-fetch refusals. Core-owned
    /// plain data ([`UpdateProgress`] is all `String`s and an `Option<u8>`), so
    /// server-core keeps compiling on CI Linux.
    ///
    /// **The watch's default value carries an EMPTY `stage`, which the session
    /// arm SKIPS.** The D-10 vocabulary has no idle value and a watch needs an
    /// initial one; rather than invent an eighth stage the phone would have to
    /// learn to ignore, the initial value is a shape the protocol cannot
    /// express. See [`UpdateProgress`] for the full rationale.
    pub update: tokio::sync::watch::Receiver<UpdateProgress>,
}

/// Run the accept loop on an already-bound listener until the task is
/// aborted. Each accepted connection gets its own session task; held input
/// is released unconditionally when a session ends for ANY reason
/// (CONN-07).
pub async fn run(listener: tokio::net::TcpListener, deps: ServerDeps) {
    listener::accept_loop(listener, deps).await
}
