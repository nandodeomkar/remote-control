//! server-windows binary — the composition root every later phase extends
//! (RESEARCH Pattern 5): DPI awareness, tracing subscriber, dedicated input
//! thread, `ServerDeps` assembly, and `server_core::run` on a LAN listener.

mod executors;
mod input_thread;

use std::sync::{Arc, Mutex};

use anyhow::Context;
use server_core::auth::pin::PIN_TTL_SECS;
use server_core::auth::AuthManager;
use server_core::executors::Executors;
use server_core::transport::ServerDeps;
use tracing_subscriber::EnvFilter;

use executors::mouse_keys::EnigoMouseKeys;
use executors::stubs::{StubApps, StubClipboard, StubMedia, StubPower};
use input_thread::Cmd;

/// Default WebSocket port. The spec leaves the port configurable (settings
/// window, Phase 7); until then this default is override-able via `RC_PORT`.
const DEFAULT_PORT: u16 = 17777;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    // 1. DPI awareness FIRST, before any Enigo op (RESEARCH Pattern 3 /
    //    D-04): enigo 0.6.1 re-exports `set_dpi_awareness` at the crate
    //    root (win_impl::set_dpi_awareness — the enigo helper path; the
    //    windows-crate SetProcessDpiAwarenessContext fallback was not
    //    needed). Without this, deltas are DPI-virtualized on scaled
    //    displays.
    enigo::set_dpi_awareness().ok();

    // 2. This binary OWNS logging (server-core is deliberately log-free).
    //    SECURITY (threat T-02-ID): log only lifecycle events and counts —
    //    NEVER frame contents, move deltas, PINs, or tokens.
    tracing_subscriber::fmt()
        .with_env_filter(EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info")))
        .init();

    // 3. Dedicated input thread: the only place the !Sync Enigo lives.
    let (tx, rx) = std::sync::mpsc::channel::<Cmd>();
    std::thread::spawn(move || input_thread::run_input_thread(rx));

    // 4. Executor bundle: real enigo mouse path + Phase 4-6 stub seeds.
    let executors = Executors {
        mouse_keys: Arc::new(EnigoMouseKeys::new(tx)),
        media: Arc::new(StubMedia),
        power: Arc::new(StubPower),
        apps: Arc::new(StubApps),
        clipboard: Arc::new(StubClipboard),
    };

    // 5. Auth: real Phase 1 pairing (D-01/D-02) — show the PIN on the
    //    console (the tray display comes in Phase 7). The PIN goes to
    //    stdout as the pairing UX, NOT through the tracing subscriber.
    let auth = Arc::new(Mutex::new(AuthManager::new()));
    let pin = auth
        .lock()
        .expect("auth mutex poisoned at startup")
        .begin_pairing();
    println!("Pairing PIN: {pin}");

    // 5a. Re-pair loop (WR-01): the initial PIN expires after PIN_TTL_SECS.
    //     Without this, pairing is permanently impossible ~60s after launch
    //     with no console indication. Refresh the window (reprint a fresh PIN)
    //     each TTL while still unpaired; stop once a phone pairs. Clone the
    //     Arc BEFORE `auth` is moved into ServerDeps below.
    let auth_for_repin = Arc::clone(&auth);
    tokio::spawn(async move {
        loop {
            tokio::time::sleep(std::time::Duration::from_secs(PIN_TTL_SECS)).await;
            let refreshed = {
                let mut guard = auth_for_repin
                    .lock()
                    .expect("auth mutex poisoned during re-pair refresh");
                if guard.is_paired() {
                    break; // a device paired — stop refreshing
                }
                guard.begin_pairing()
                // guard dropped here, before the println! below
            };
            println!("Pairing PIN (refreshed): {refreshed}");
        }
    });

    // 6. Server-side pause flag (SPEC §11) — no pause UI in the spike.
    let (_pause_tx, pause_rx) = tokio::sync::watch::channel(false);
    let deps = ServerDeps {
        executors,
        auth,
        pause: pause_rx,
    };

    // 7. Bind the LAN interface (tests bind 127.0.0.1:0; the real binary
    //    binds 0.0.0.0 — LAN-only by network design, never internet-exposed).
    let port: u16 = match std::env::var("RC_PORT") {
        Ok(v) => v
            .parse()
            .with_context(|| format!("RC_PORT must be a valid port number, got {v:?}"))?,
        Err(_) => DEFAULT_PORT,
    };
    let listener = tokio::net::TcpListener::bind(("0.0.0.0", port))
        .await
        .with_context(|| format!("bind 0.0.0.0:{port}"))?;
    tracing::info!(port, "server-windows listening");

    // 8. The whole loop lives in server-core (Phase 1, unchanged).
    server_core::run(listener, deps).await;
    Ok(())
}
