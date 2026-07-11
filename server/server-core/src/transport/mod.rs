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
mod listener;
mod session;

/// Re-exported so tests (and any composition root) asserting "the current
/// server version" reference the constant instead of duplicating the
/// literal (RESEARCH Pitfall 10).
pub use session::SERVER_PROTO_VERSION;

use std::sync::{Arc, Mutex};

use crate::auth::AuthManager;
use crate::executors::Executors;

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
}

/// Run the accept loop on an already-bound listener until the task is
/// aborted. Each accepted connection gets its own session task; held input
/// is released unconditionally when a session ends for ANY reason
/// (CONN-07).
pub async fn run(listener: tokio::net::TcpListener, deps: ServerDeps) {
    listener::accept_loop(listener, deps).await
}
