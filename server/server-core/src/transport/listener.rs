//! Accept-loop internals: TCP accept → `set_nodelay(true)` →
//! `accept_async_with_config` (64 KB message/frame caps, SPEC §13) → spawn
//! session task.
//!
//! Not part of the public API — everything external goes through
//! [`super::run`].

use std::sync::Arc;

use tokio::net::TcpListener;
use tokio_tungstenite::tungstenite::protocol::WebSocketConfig;

use super::{ServerDeps, session};

/// SPEC §13: both WebSocket size limits are 64 KB, enforced pre- AND
/// post-auth (pre-auth memory-DoS defense, threat T-01-26 / pitfall 7).
const MAX_WS_MESSAGE_BYTES: usize = 65536;

/// Accept connections until the task is aborted. Each accepted connection
/// runs as its own session task; a failed TCP accept or WebSocket handshake
/// never kills the loop.
pub(super) async fn accept_loop(listener: TcpListener, deps: ServerDeps) {
    let ServerDeps { executors, auth, pause, volume, apps, clip, conn_count, revoke, blocked } =
        deps;

    loop {
        let (stream, peer) = match listener.accept().await {
            Ok(conn) => conn,
            // Transient accept errors (aborted handshakes, fd pressure)
            // must not kill the server: skip and keep accepting.
            Err(_) => continue,
        };

        // Phase-2 latency prerequisite (project pitfall 3): disable Nagle
        // on EVERY accepted stream, before the WebSocket handshake.
        // Log-and-continue semantics — a failure here degrades latency,
        // never correctness (tracing arrives in Phase 2; nothing to log to
        // yet, and secrets-in-logs is moot for a socket option).
        let _ = stream.set_nodelay(true);

        // 64 KB caps applied AT ACCEPT so they bound even the very first
        // pre-auth frame (SPEC §13).
        let config = WebSocketConfig::default()
            .max_message_size(Some(MAX_WS_MESSAGE_BYTES))
            .max_frame_size(Some(MAX_WS_MESSAGE_BYTES));

        let executors = executors.clone();
        let auth = Arc::clone(&auth);
        let pause = pause.clone();
        let volume = volume.clone();
        let apps = apps.clone();
        let clip = clip.clone();
        let conn_count = Arc::clone(&conn_count);
        let revoke = revoke.clone();
        let blocked = blocked.clone();
        tokio::spawn(async move {
            let ws =
                match tokio_tungstenite::accept_async_with_config(stream, Some(config)).await {
                    Ok(ws) => ws,
                    // Failed WS handshake: no session ever existed, nothing
                    // was held, nothing to clean up.
                    Err(_) => return,
                };
            session::run_session(
                ws,
                peer.ip(),
                executors,
                auth,
                pause,
                volume,
                apps,
                clip,
                conn_count,
                revoke,
                blocked,
            )
            .await;
        });
    }
}
