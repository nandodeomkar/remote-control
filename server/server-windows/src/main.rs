//! server-windows binary — the composition root every later phase extends
//! (RESEARCH Pattern 5): DPI awareness, tracing subscriber, dedicated input
//! thread, `ServerDeps` assembly, and `server_core::run` on a LAN listener.

mod apps_thread;
mod audio_thread;
mod autostart;
mod clip_thread;
mod config;
mod executors;
mod firewall;
mod input_thread;
mod notify;
mod shell;

use std::sync::{Arc, Mutex};

use anyhow::Context;
use server_core::auth::pin::PIN_TTL_SECS;
use server_core::auth::AuthManager;
use server_core::executors::{Executors, WindowInfo};
use server_core::transport::{ClipState, ServerDeps, VolumeState};
use server_core::transport::beacon::{self, BeaconIdentity};
use tracing_subscriber::EnvFilter;

use apps_thread::AppsCmd;
use audio_thread::AudioCmd;
use clip_thread::ClipCmd;
use executors::apps::WinApps;
use executors::clipboard::WinClipboard;
use executors::media::WinMedia;
use executors::mouse_keys::EnigoMouseKeys;
use executors::power::WinPower;
use firewall::{BindProblem, FirewallStatus};
use input_thread::Cmd;
use shell::ShellCtx;

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
    //    `blocked_tx` is the SRV-05 UIPI epoch (07-04's foreground_blocked()
    //    proactive detection, debounced on the input thread itself) —
    //    created here, alongside the thread that owns it, rather than at
    //    step 6b with the other transport-seam channels (06-01 precedent:
    //    a channel's Sender lives with its real producer).
    let (tx, rx) = std::sync::mpsc::channel::<Cmd>();
    let (blocked_tx, blocked_rx) = tokio::sync::watch::channel(0u64);
    std::thread::spawn(move || input_thread::run_input_thread(rx, blocked_tx));

    // 3a. Dedicated COM audio thread (05-05, MED-02): owns all WASAPI/COM
    //     objects and is the REAL producer for the 05-03 volume watch seam.
    //     The watch Sender MOVES onto the thread (replacing 05-03's interim
    //     default-state sender); `volume_rx` feeds ServerDeps below. Endpoint
    //     is re-acquired per poll tick, so device switches survive (Pitfall 6).
    let (audio_tx, audio_rx) = std::sync::mpsc::channel::<AudioCmd>();
    let (volume_tx, volume_rx) = tokio::sync::watch::channel(VolumeState::default());
    std::thread::spawn(move || audio_thread::run_audio_thread(audio_rx, volume_tx));

    // 3b. Dedicated apps thread (06-02, APPS-01/02/03): owns EnumWindows +
    //     the shell-icon COM state + the foreground-lock focus dance, and is
    //     the REAL producer for the 06-01 apps.changed watch seam (replacing
    //     the interim placeholder). The watch Sender MOVES onto the thread;
    //     `apps_rx` feeds both WinApps (snapshot reads) and ServerDeps (the
    //     authed-gated push branch) below.
    let (apps_cmd_tx, apps_cmd_rx) = std::sync::mpsc::channel::<AppsCmd>();
    let (apps_tx, apps_rx) = tokio::sync::watch::channel(Vec::<WindowInfo>::new());
    std::thread::spawn(move || apps_thread::run_apps_thread(apps_cmd_rx, apps_tx));

    // 3c. Dedicated clip thread (06-04, CLIP-01/02/03): owns the single arboard
    //     instance + the sensitive/large/echo gates, and is the REAL producer
    //     for the 06-04 clip.changed watch seam (replacing the Task-1 interim
    //     placeholder). The watch Sender MOVES onto the thread; `clip_rx` feeds
    //     both WinClipboard (snapshot reads) and ServerDeps (the authed-gated
    //     push branch) below. NO CoInitializeEx — arboard needs no COM.
    let (clip_cmd_tx, clip_cmd_rx) = std::sync::mpsc::channel::<ClipCmd>();
    let (clip_tx, clip_rx) = tokio::sync::watch::channel(ClipState::default());
    std::thread::spawn(move || clip_thread::run_clip_thread(clip_cmd_rx, clip_tx));

    // 4. Executor bundle: real enigo mouse + real media/power (05-05) + real
    //    apps (06-02) + real clipboard (06-04) — every trait now has a Windows
    //    backend (the stubs module is gone). WinMedia holds the input-thread
    //    sender (media transport keys, MED-01) and the audio-thread sender
    //    (absolute volume/mute, MED-02); `tx` is cloned for the mouse path
    //    BEFORE it moves into WinMedia. WinApps holds the apps-thread command
    //    sender + a snapshot receiver clone (list reads); WinClipboard holds
    //    the clip-thread command sender + a snapshot receiver clone (get reads).
    let executors = Executors {
        mouse_keys: Arc::new(EnigoMouseKeys::new(tx.clone())),
        media: Arc::new(WinMedia::new(tx, audio_tx)),
        power: Arc::new(WinPower),
        apps: Arc::new(WinApps::new(apps_cmd_tx, apps_rx.clone())),
        clipboard: Arc::new(WinClipboard::new(clip_cmd_tx, clip_rx.clone())),
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

    // 6. Server-side pause flag (SPEC §11): the tray's Pause menu item
    //    (07-06) is now the real driver — `pause_tx` moves into `ShellCtx`
    //    below, alongside `auth`/`revoke_tx` (a clone taken BEFORE `auth`
    //    moves into `deps`, mirroring the `auth_for_repin` clone above).
    let (pause_tx, pause_rx) = tokio::sync::watch::channel(false);

    // 6b. conn_count (SRV-01 tooltip) + revoke (D-05, real sender lands in
    //     07-08's settings window) — the real conn_count SENDER already
    //     lives here (sessions bump/decrement it); `revoke_tx` stays a
    //     not-yet-driven real sender (07-08 wires its "Revoke" button) but
    //     is no longer an interim placeholder — it is handed to the shell
    //     thread's ShellCtx below so 07-08 has somewhere to reach it.
    let (conn_count_tx, _conn_count_rx) = tokio::sync::watch::channel(0usize);
    let conn_count = std::sync::Arc::new(conn_count_tx);
    let (revoke_tx, revoke_rx) = tokio::sync::watch::channel(0u64);

    // Clone BEFORE `auth` moves into `deps` (mirrors `auth_for_repin` above)
    // — the shell thread's ShellCtx needs its own handle for 07-08's
    // on-demand pairing/revoke UI.
    let auth_for_shell = std::sync::Arc::clone(&auth);

    // 6a. Apps watch (APPS-03): fed by the real apps thread spawned in step
    //     3b. `apps_rx` (the snapshot receiver) drives the session's authed-
    //     gated apps.changed push branch; WinApps holds its own clone for
    //     list reads. Moving it here consumes the receiver into ServerDeps.
    let deps = ServerDeps {
        executors,
        auth,
        pause: pause_rx,
        volume: volume_rx,
        apps: apps_rx,
        clip: clip_rx,
        conn_count: conn_count.clone(),
        revoke: revoke_rx,
        blocked: blocked_rx,
    };

    // 7. Bind the LAN interface (tests bind 127.0.0.1:0; the real binary
    //    binds 0.0.0.0 — LAN-only by network design, never internet-exposed).
    let port: u16 = match std::env::var("RC_PORT") {
        Ok(v) => v
            .parse()
            .with_context(|| format!("RC_PORT must be a valid port number, got {v:?}"))?,
        Err(_) => DEFAULT_PORT,
    };
    // 7 (SRV-04 / D-06): AddrInUse must NOT `?`-propagate straight into a
    // crash — classify it via `firewall::classify_bind_error` and surface a
    // LOUD, distinct warning (toast) instead (RESEARCH Pitfall 5). Without a
    // bound listener there is nothing left to run, so this still exits, but
    // the owner has already been told why via the toast — never a silent or
    // unexplained failure.
    let listener = match tokio::net::TcpListener::bind(("0.0.0.0", port)).await {
        Ok(l) => l,
        Err(e) => {
            return match firewall::classify_bind_error(&e) {
                Some(BindProblem::PortInUse) => {
                    tracing::warn!(port, "bind failed: port already in use (SRV-04)");
                    notify::notify_firewall_warning(&format!(
                        "Another app is using port {port}. Change the port in Settings or close the other app."
                    ));
                    Err(anyhow::anyhow!(
                        "port {port} already in use; see the tray warning toast"
                    ))
                }
                None => Err(e).with_context(|| format!("bind 0.0.0.0:{port}")),
            };
        }
    };
    tracing::info!(port, "server-windows listening");

    // 7b (SRV-04 / D-06): the startup firewall self-test. Bind succeeding
    // says nothing about whether the FIREWALL lets a phone's inbound
    // connection through (Pitfall 5 — bind is local, the firewall filters
    // *inbound from other hosts*), so query `INetFwPolicy2` separately.
    // READ-ONLY (T-07-07/ASVS V4, enforced in firewall.rs) — never creates or
    // modifies a rule. `Unknown` is fail-quiet (firewall.rs's documented
    // contract): only a confirmed `BlockedNoRule` fires the loud warning.
    let firewall_status = firewall::inbound_allowed(port);
    if firewall_status == FirewallStatus::BlockedNoRule {
        tracing::warn!(port, "firewall inbound check: no allow rule found (SRV-04)");
        notify::notify_firewall_warning(&format!(
            "Allow Remote Control through Windows Firewall (TCP {port}) so your phone can connect."
        ));
    }
    // 07-08's settings window shows a persistent hint whenever the verdict
    // is anything other than a confirmed Allowed (BlockedNoRule OR an
    // inconclusive Unknown read both merit keeping the hint visible).
    let notify_firewall = firewall_status != FirewallStatus::Allowed;

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

    // 7c (SRV-01). Spawn the tray shell thread: it reads `firewall_status`
    // at `StartCause::Init` to render the warning icon from the very first
    // frame, drives `pause_tx` (the tray's Pause menu item), and holds
    // `auth_for_shell`/`revoke_tx` for 07-08's on-demand settings window.
    // `config`/`autostart` are placeholder `()` handles until 07-07/07-08
    // land real ones (ShellCtx doc comment). MUST run before
    // `server_core::run` blocks this task forever (RESEARCH Pattern 1).
    let shell_proxy = shell::spawn_shell_thread(ShellCtx {
        conn_count: conn_count.subscribe(),
        pause_tx,
        auth: auth_for_shell,
        revoke_tx,
        config: (),
        autostart: (),
        firewall_status,
        notify_firewall,
    });

    // Forward every conn_count change to the shell thread's tooltip via the
    // EventLoopProxy (RESEARCH Pattern 1 — Send+Sync proxy, the tokio→shell
    // bridge). `borrow_and_update` primes the tray with the CURRENT value
    // first (defensive against a change landing between spawn and here);
    // the loop then blocks on `changed()` — zero busy-polling. A closed
    // channel (`changed()` errs) means `conn_count`'s sole Arc-held Sender
    // was dropped, which only happens at process teardown.
    let mut conn_count_for_tray = conn_count.subscribe();
    tokio::spawn(async move {
        loop {
            let count = *conn_count_for_tray.borrow_and_update();
            let _ = shell_proxy.send_event(shell::UserEvent::Tooltip(count));
            if conn_count_for_tray.changed().await.is_err() {
                break;
            }
        }
    });

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
