//! server-windows binary — the composition root every later phase extends
//! (RESEARCH Pattern 5): DPI awareness, tracing subscriber, dedicated input
//! thread, `ServerDeps` assembly, and `server_core::run` on a LAN listener.

mod apps_thread;
mod audio_thread;
mod executors;
mod input_thread;
mod notify;

use std::sync::{Arc, Mutex};

use anyhow::Context;
use server_core::auth::pin::PIN_TTL_SECS;
use server_core::auth::AuthManager;
use server_core::executors::{Executors, WindowInfo};
use server_core::transport::{ServerDeps, VolumeState};
use server_core::transport::beacon::{self, BeaconIdentity};
use tracing_subscriber::EnvFilter;

use audio_thread::AudioCmd;
use executors::media::WinMedia;
use executors::mouse_keys::EnigoMouseKeys;
use executors::power::WinPower;
use executors::stubs::{StubApps, StubClipboard};
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

    // 3a. Dedicated COM audio thread (05-05, MED-02): owns all WASAPI/COM
    //     objects and is the REAL producer for the 05-03 volume watch seam.
    //     The watch Sender MOVES onto the thread (replacing 05-03's interim
    //     default-state sender); `volume_rx` feeds ServerDeps below. Endpoint
    //     is re-acquired per poll tick, so device switches survive (Pitfall 6).
    let (audio_tx, audio_rx) = std::sync::mpsc::channel::<AudioCmd>();
    let (volume_tx, volume_rx) = tokio::sync::watch::channel(VolumeState::default());
    std::thread::spawn(move || audio_thread::run_audio_thread(audio_rx, volume_tx));

    // 4. Executor bundle: real enigo mouse + real media/power (05-05);
    //    Apps/Clipboard stay on stubs (Phase 6). WinMedia holds the
    //    input-thread sender (media transport keys, MED-01) and the
    //    audio-thread sender (absolute volume/mute, MED-02); `tx` is cloned
    //    for the mouse path BEFORE it moves into WinMedia.
    let executors = Executors {
        mouse_keys: Arc::new(EnigoMouseKeys::new(tx.clone())),
        media: Arc::new(WinMedia::new(tx, audio_tx)),
        power: Arc::new(WinPower),
        apps: Arc::new(StubApps),
        clipboard: Arc::new(StubClipboard),
    };

    // 5. Auth: real Phase 1 pairing (D-01/D-02) — show the PIN via a
    //    Windows toast with the console print as guaranteed fallback
    //    (D-09; the tray-proper display comes in Phase 7). The PIN goes to
    //    stdout + toast as the pairing UX, NOT through the tracing
    //    subscriber.
    let auth = Arc::new(Mutex::new(AuthManager::new()));
    let pin = auth
        .lock()
        .expect("auth mutex poisoned at startup")
        .begin_pairing();
    notify::notify_pin(&pin);

    // 5a. Re-pair loop (WR-01): the initial PIN expires after PIN_TTL_SECS.
    //     Without this, pairing is permanently impossible ~60s after launch
    //     with no indication. Refresh the window (re-notify a fresh PIN)
    //     each TTL while still unpaired; stop once a phone pairs. Both the
    //     initial and refreshed PIN route through the same notify path
    //     (toast + console). Clone the Arc BEFORE `auth` is moved into
    //     ServerDeps below.
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
                // guard dropped here, before the notify below
            };
            notify::notify_pin(&refreshed);
        }
    });

    // 6. Server-side pause flag (SPEC §11) — no pause UI in the spike.
    //    (The volume watch is now driven by the real audio thread spawned in
    //    step 3a; its `volume_rx` is consumed below.)
    let (_pause_tx, pause_rx) = tokio::sync::watch::channel(false);

    // 6a. Placeholder apps watch (APPS-03): the real producer — the Windows
    //     apps thread that enumerates/pushes the live window list — lands in
    //     06-02. Until then this default-empty channel keeps the session's
    //     apps.changed branch wired without ever pushing (the sender is held
    //     as `_apps_tx` so the receiver's branch is not immediately disabled).
    let (_apps_tx, apps_rx) = tokio::sync::watch::channel(Vec::<WindowInfo>::new());
    let deps = ServerDeps {
        executors,
        auth,
        pause: pause_rx,
        volume: volume_rx,
        apps: apps_rx,
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

    // 7a. Discovery beacon (CONN-01): identity is Windows-specific (winreg
    //     MachineGuid + COMPUTERNAME) and injected HERE so server-core
    //     keeps its zero-Windows-deps invariant. `ws_port` must be the
    //     RESOLVED WebSocket port from step 7 (after the RC_PORT override),
    //     which is why this step lives after the port resolution. The
    //     beacon payload carries no secrets (protocol/BEACON.md).
    let guid = machine_guid().unwrap_or_else(|| {
        // Never crash the server over identity: derive a stable fallback id.
        tracing::warn!("MachineGuid registry read failed; using name-derived beacon id");
        format!("name-{}", device_name())
    });
    let beacon_port: u16 = match std::env::var("RC_BEACON_PORT") {
        Ok(v) => v
            .parse()
            .with_context(|| format!("RC_BEACON_PORT must be a valid port number, got {v:?}"))?,
        Err(_) => beacon::DEFAULT_BEACON_PORT,
    };
    tokio::spawn(beacon::run_beacon(
        BeaconIdentity {
            name: device_name(),
            guid,
            ws_port: port,
        },
        beacon_port,
    ));

    // 8. The whole loop lives in server-core (Phase 1, unchanged).
    server_core::run(listener, deps).await;
    Ok(())
}

/// Stable machine GUID: REG_SZ `MachineGuid` under
/// `HKLM\SOFTWARE\Microsoft\Cryptography` (readable unelevated; the x86_64
/// build sees the 64-bit registry view by default).
fn machine_guid() -> Option<String> {
    winreg::RegKey::predef(winreg::enums::HKEY_LOCAL_MACHINE)
        .open_subkey(r"SOFTWARE\Microsoft\Cryptography")
        .ok()?
        .get_value::<String, _>("MachineGuid")
        .ok()
}

/// Human-readable device name for the beacon: `COMPUTERNAME` with a literal
/// fallback (assumption A5 — the env var is standard on Windows).
fn device_name() -> String {
    std::env::var("COMPUTERNAME").unwrap_or_else(|_| "Windows PC".to_string())
}
