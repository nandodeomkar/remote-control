// No console window in release builds (quick 260729-4rg). The app is
// tray-first: every launch point the installer creates — Start Menu, desktop
// icon, autostart Run entry — used to pop a terminal beside the tray icon.
//
// Gated on `debug_assertions` so `cargo run` keeps its console and its stdout
// logs during development. Losing stdout in release is survivable only
// because `logging.rs` writes a rolling file — do not remove one without the
// other.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

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
mod logging;
mod notify;
mod shell;
mod single_instance;
mod update;

use std::sync::{Arc, Mutex};

use anyhow::Context;
use server_core::auth::pin::PIN_TTL_SECS;
use server_core::auth::AuthManager;
use server_core::executors::{
    BookmarksState, Executors, ExtInfo, TabsState, UpdateProgress, WindowInfo,
};
use server_core::transport::{ClipState, ServerDeps, VolumeState};
use server_core::transport::beacon::{self, BeaconIdentity};
use server_core::transport::ext::{self, BookmarksRelay, ExtCmd, TabsRelay};

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
use update::WinUpdate;
use update::update_thread::{self, UpdateCmd};

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
    //    NEVER frame contents, move deltas, PINs, or tokens. That rule binds
    //    harder now that the sink is a file on disk rather than a console
    //    that closes with the process (logging.rs).
    //
    //    The guard is bound at `main` scope on purpose: it owns the
    //    non-blocking writer's background thread, and dropping it early
    //    truncates the log to nothing.
    let _log_guard = logging::init();

    // 2a. Single-instance gate (quick 260729-38z), AFTER the subscriber (so
    //     the refusal is logged) and BEFORE any config load, thread spawn or
    //     bind. Without it a duplicate launch — routine once the installer
    //     gives the owner a Start Menu entry, a desktop icon and an autostart
    //     entry for the same exe — walks the whole composition root and dies
    //     at step 7's bind() with a misleading "another app is using port"
    //     toast, the other app being itself.
    //
    //     Returning Ok is deliberate: a second click is expected user
    //     behaviour, not a failure. The guard binds to a local that lives for
    //     the rest of `main`, so the mutex is held for the process lifetime.
    let _instance_guard = match single_instance::acquire() {
        Some(guard) => guard,
        None => {
            tracing::warn!("another instance already holds the instance mutex; exiting");
            notify::notify_already_running();
            return Ok(());
        }
    };

    // 2b. Persistent config (SRV-03 / D-01): load %APPDATA%/RemoteControl/
    //     config.toml FIRST — it seeds the auth store (step 5), the resolved
    //     device name/port (steps 7/7a), and the clipboard-sync gate (step
    //     3c). The load is fail-safe end to end (corrupt file ⇒ defaults,
    //     bad hash entries skipped — config.rs, T-07-27); a first run with
    //     no file simply yields defaults.
    let cfg = config::load();
    let resolved_device_name = cfg.device_name.clone().unwrap_or_else(device_name);

    // 2c. The LIVE editable settings (07-08): seeded from the startup config
    //     (never the RC_PORT env override — env must never get baked into
    //     the file). The settings window mutates it; the step-5b save task
    //     reads it on every re-serialize — so a pairing/revoke save can't
    //     clobber a settings edit with stale startup values, and vice versa.
    let settings = Arc::new(Mutex::new(config::SharedSettings::from_config(&cfg)));

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
    //     `clip_sync_enabled` is the config's clipboard_sync toggle (07-07,
    //     RESEARCH Open Q5): OFF stops the PC→phone mirror push while a
    //     phone-initiated clip.set keeps working. The Arc is shared with the
    //     thread; 07-08's settings window flips it live.
    let (clip_cmd_tx, clip_cmd_rx) = std::sync::mpsc::channel::<ClipCmd>();
    let (clip_tx, clip_rx) = tokio::sync::watch::channel(ClipState::default());

    // 3d. Tab-relay channels (BROW-01, SPEC §15): the ext listener task
    //     (spawned at step 7d) is the REAL producer on `tabs_tx` and the
    //     consumer of `ext_cmd_rx`; TabsRelay (the Tabs executor) pairs a
    //     snapshot receiver with the command sender, exactly how WinApps
    //     pairs its command sender with the apps snapshot receiver.
    let (tabs_tx, tabs_rx) = tokio::sync::watch::channel(TabsState::default());
    //     The bookmark watch (protoVersion 1.6, phase 11) is the SECOND
    //     channel the same ext task produces into — one socket, two
    //     snapshots (D-06 pushes the whole tree in one flattened frame). It
    //     shares `ext_cmd_tx` with TabsRelay: one command stream to the one
    //     extension. `bm_rx` is CLONED into the relay (snapshot reads for
    //     `bm.list`) and moved into ServerDeps below, which drives the
    //     authed-gated `bm.changed` push — exactly how `tabs_rx` is split.
    let (bm_tx, bm_rx) = tokio::sync::watch::channel(BookmarksState::default());
    //     The ext-info watch (protoVersion 1.8, phase 12) is the THIRD channel
    //     the same ext task produces into — filled from `ext.hello`'s
    //     extVersion (D-09/D-18). It is the odd one out: it drives NO session
    //     push arm, so it is deliberately absent from ServerDeps. Its only
    //     consumer is WinUpdate, which reads it to answer `update.status`'s
    //     extConnected/extVersion, so the receiver goes straight there.
    let (ext_info_tx, ext_info_rx) = tokio::sync::watch::channel(ExtInfo::default());
    let (ext_cmd_tx, ext_cmd_rx) = tokio::sync::mpsc::channel::<ExtCmd>(16);
    //     The shell's settings window holds its own clone (07-08): its
    //     clipboard-sync checkbox flips the gate LIVE — clone BEFORE the
    //     Arc moves onto the clip thread.
    let clip_sync_enabled = Arc::new(std::sync::atomic::AtomicBool::new(cfg.clipboard_sync));
    let clip_sync_for_shell = Arc::clone(&clip_sync_enabled);
    std::thread::spawn(move || clip_thread::run_clip_thread(clip_cmd_rx, clip_tx, clip_sync_enabled));

    // 3e. Dedicated update thread (12-11, D-05): owns ALL blocking update I/O
    //     — the release-feed fetch, the ~5 MB asset download, the sha256
    //     verification and the installer hand-off — because `ureq` is blocking
    //     and a download on the tokio runtime would stall a runtime worker for
    //     the whole transfer. It is the REAL producer for the `update.progress`
    //     watch seam (12-13's authed-gated session arm is the consumer);
    //     `update_rx` feeds ServerDeps below.
    //
    //     Two departures from the 3a-3c three-line shape, both deliberate:
    //     the watch Sender is wrapped in an `Arc` and CLONED rather than moved
    //     onto the thread, because `WinUpdate` publishes the immediate
    //     pre-fetch refusals itself (a second tap must be answered `busy` now,
    //     not 30 seconds later when the first download ends); and the busy
    //     flag is shared so the thread can clear it at its one exit site
    //     whatever the outcome (T-12-37).
    let (update_cmd_tx, update_cmd_rx) = std::sync::mpsc::channel::<UpdateCmd>();
    let (update_progress_tx, update_rx) = tokio::sync::watch::channel(UpdateProgress::default());
    let update_progress_tx = Arc::new(update_progress_tx);
    let update_busy = Arc::new(std::sync::atomic::AtomicBool::new(false));
    {
        let progress = Arc::clone(&update_progress_tx);
        let busy = Arc::clone(&update_busy);
        std::thread::spawn(move || update_thread::run_update_thread(update_cmd_rx, progress, busy));
    }

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
        tabs: Arc::new(TabsRelay::new(tabs_rx.clone(), ext_cmd_tx.clone())),
        bookmarks: Arc::new(BookmarksRelay::new(bm_rx.clone(), ext_cmd_tx)),
        // WinUpdate holds the update-thread command sender, a clone of the
        // shared progress Sender (refusals) and of the busy flag, plus the
        // ext-info receiver (update.status reads). D-14: `apply` still takes
        // ONE string — nothing constructed here can carry a locator.
        update: Arc::new(WinUpdate::new(
            update_cmd_tx,
            Arc::clone(&update_progress_tx),
            Arc::clone(&update_busy),
            ext_info_rx,
        )),
    };

    // 5. Auth (SRV-03 / D-01): seed the store from config.toml's paired
    //    records — pairings now survive restarts. Malformed entries were
    //    already skipped fail-safe by `to_paired_devices` (T-07-27).
    let auth = Arc::new(Mutex::new(AuthManager::from_paired(config::to_paired_devices(&cfg))));

    // 5a. SMART STARTUP (D-03): ≥1 paired device ⇒ start silent (no PIN
    //     toast — the phone reconnects with its stored token); zero paired ⇒
    //     open a pairing window and show the PIN (D-09: toast + console,
    //     never through tracing). The decision is the pure `smart_startup_pin`
    //     below (unit-tested).
    let startup_pin = smart_startup_pin(
        &mut auth.lock().expect("auth mutex poisoned at startup"),
    );
    if let Some(pin) = startup_pin {
        notify::notify_pin(&pin);

        // Bounded re-pin refresh (WR-01): the startup PIN expires after
        // PIN_TTL_SECS; refresh (re-notify a fresh PIN) each TTL ONLY while
        // no device has paired for this open startup window — the loop ends
        // the moment a phone pairs. It is spawned ONLY on the zero-paired
        // branch, so it is no longer the permanent process-lifetime loop
        // (D-02/D-03 rework; on-demand re-pairing is `begin_on_demand_pairing`
        // driven from the tray/settings shell, 07-08). Clone the Arc BEFORE
        // `auth` is moved into ServerDeps below.
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
    }

    // 5b. Config re-serialization (D-01/D-05): subscribe to the auth store's
    //     change-signal and rewrite config.toml on EVERY paired-set mutation
    //     — a completed pairing AND a revoke both persist immediately. The
    //     settings values re-serialized alongside come from the LIVE shared
    //     handle (step 2c) — the CURRENT edits, never the RC_PORT env
    //     override and never a stale startup snapshot (07-08's settings
    //     window mutates the same handle). Subscribe BEFORE `auth` moves
    //     into ServerDeps.
    let mut auth_changes = auth
        .lock()
        .expect("auth mutex poisoned at config subscription")
        .changes();
    let auth_for_save = Arc::clone(&auth);
    let settings_for_save = Arc::clone(&settings);
    tokio::spawn(async move {
        while auth_changes.changed().await.is_ok() {
            let snapshot = {
                // Take the two locks SEQUENTIALLY (settings first, dropped
                // before auth) — never nested, no ordering to deadlock on.
                let s = settings_for_save
                    .lock()
                    .expect("settings mutex poisoned during config save")
                    .clone();
                let guard = auth_for_save
                    .lock()
                    .expect("auth mutex poisoned during config save");
                config::from_auth(
                    guard.paired_records(),
                    s.device_name,
                    s.port,
                    s.autostart,
                    s.clipboard_sync,
                )
                // guard dropped here, before the file write below
            };
            config::save(&snapshot);
        }
    });

    // 6. Server-side pause flag (SPEC §11): the tray's Pause menu item
    //    (07-06) is now the real driver — `pause_tx` moves into `ShellCtx`
    //    below, alongside `auth`/`revoke_tx` (a clone taken BEFORE `auth`
    //    moves into `deps`, mirroring the `auth_for_repin` clone above).
    let (pause_tx, pause_rx) = tokio::sync::watch::channel(false);

    // 6b. conn_count (SRV-01 tooltip) + revoke (D-05) — the real conn_count
    //     SENDER lives here (sessions bump/decrement it); `revoke_tx` is
    //     driven by the settings window's Revoke button (07-08, via
    //     `revoke_device`) through the shell thread's ShellCtx below.
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
        tabs: tabs_rx,
        bookmarks: bm_rx,
        update: update_rx,
    };

    // 7. Bind the LAN interface (tests bind 127.0.0.1:0; the real binary
    //    binds 0.0.0.0 — LAN-only by network design, never internet-exposed).
    //    Precedence (07-07): RC_PORT env > config.port > DEFAULT_PORT; an
    //    invalid RC_PORT now warns and falls through instead of aborting
    //    (fail-safe, T-07-27 — config.rs owns the resolution).
    let port: u16 = config::resolve_port(std::env::var("RC_PORT").ok().as_deref(), &cfg);
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
            // Config's device_name (07-07) overrides COMPUTERNAME when set;
            // the guid fallback above deliberately stays COMPUTERNAME-based
            // so the beacon IDENTITY survives a display-name change.
            name: resolved_device_name,
            guid,
            ws_port: port,
        },
        beacon_port,
    ));

    // 7d. Extension listener (BROW-01, SPEC §15): 127.0.0.1 ONLY — the
    //     loopback bind is the auth boundary for the Tab Bridge extension
    //     leg. RC_EXT_PORT env override mirrors RC_BEACON_PORT above. A bind
    //     FAILURE degrades to no-tab-support AND no-bookmark-support (the
    //     phone renders the install hint via BOTH watch defaults) — the
    //     feature is optional; never kill the server for it (contrast with
    //     the mandatory main listener).
    let ext_port: u16 = match std::env::var("RC_EXT_PORT") {
        Ok(v) => v
            .parse()
            .with_context(|| format!("RC_EXT_PORT must be a valid port number, got {v:?}"))?,
        Err(_) => ext::DEFAULT_EXT_PORT,
    };
    match tokio::net::TcpListener::bind(("127.0.0.1", ext_port)).await {
        Ok(ext_listener) => {
            tracing::info!(port = ext_port, "extension listener on 127.0.0.1");
            tokio::spawn(ext::run_ext(ext_listener, tabs_tx, bm_tx, ext_info_tx, ext_cmd_rx));
        }
        Err(e) => {
            tracing::warn!(
                port = ext_port,
                error = %e,
                "extension listener bind failed; browser tab support disabled"
            );
        }
    }

    // 7c (SRV-01/SRV-03). Spawn the tray + settings shell thread: it reads
    // `firewall_status` at `StartCause::Init` to render the warning icon
    // from the very first frame, drives `pause_tx` (the tray's Pause menu
    // item), and holds `auth_for_shell`/`revoke_tx` for the on-demand
    // settings window (07-08) — its Pair-new action calls
    // `crate::begin_on_demand_pairing(&ctx.auth)` and its revoke button
    // `crate::revoke_device(&ctx.auth, &ctx.revoke_tx, hash)` (both defined
    // below; the step-5b subscription persists either mutation). `config` is
    // the step-2c live settings handle; `clip_sync` the clip thread's live
    // gate; `resolved_port` display-only (the port field hint + firewall fix
    // text). MUST run before `server_core::run` blocks this task forever
    // (RESEARCH Pattern 1).
    let shell_proxy = shell::spawn_shell_thread(ShellCtx {
        conn_count: conn_count.subscribe(),
        pause_tx,
        auth: auth_for_shell,
        revoke_tx,
        config: Arc::clone(&settings),
        clip_sync: clip_sync_for_shell,
        resolved_port: port,
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
/// fallback (assumption A5 — the env var is standard on Windows). Since
/// 07-07 this is the FALLBACK only — `config.device_name` overrides it when
/// set (see step 2b).
fn device_name() -> String {
    std::env::var("COMPUTERNAME").unwrap_or_else(|_| "Windows PC".to_string())
}

/// Pure D-03 smart-startup decision: `Some(pin)` when a pairing window was
/// opened (zero paired devices), `None` when startup is silent (≥1 paired —
/// the phone reconnects with its stored token, no PIN toast). The caller
/// notifies ONLY on `Some`, so "paired ⇒ no begin_pairing/notify" is proven
/// by this function alone.
fn smart_startup_pin(auth: &mut AuthManager) -> Option<String> {
    if auth.is_paired() {
        None
    } else {
        Some(auth.begin_pairing())
    }
}

/// On-demand pairing trigger (D-02): opens a fresh 60s PIN window ANY time —
/// including when devices are already paired (multi-device, SRV-03) — and
/// shows the PIN via the standard notify path (toast + console, never
/// tracing). The tray's "Pair new device" item and the settings window's
/// button (07-08) both call this through the `auth` Arc `ShellCtx` holds.
pub fn begin_on_demand_pairing(auth: &Arc<Mutex<AuthManager>>) -> String {
    let pin = auth
        .lock()
        .expect("auth mutex poisoned during on-demand pairing")
        .begin_pairing();
    notify::notify_pin(&pin);
    pin
}

/// Settings revoke path (D-05): drop `hash` from the auth store and, iff it
/// was present, advance the revocation epoch so the live session's revoke
/// `select!` branch (07-05) force-disconnects it. The auth store's own
/// change-signal bump (inside `revoke`) independently triggers the step-5b
/// config save — persistence and disconnect ride separate seams on purpose.
/// Returns whether anything was removed. The settings window's per-row
/// Revoke button (07-08) drives this via the `auth`/`revoke_tx` handles its
/// `ShellCtx` holds.
pub fn revoke_device(
    auth: &Arc<Mutex<AuthManager>>,
    revoke_tx: &tokio::sync::watch::Sender<u64>,
    hash: &[u8; 32],
) -> bool {
    let removed = auth
        .lock()
        .expect("auth mutex poisoned during revoke")
        .revoke(hash);
    if removed {
        revoke_tx.send_modify(|epoch| *epoch += 1);
    }
    removed
}

#[cfg(test)]
mod tests {
    //! Smart-startup (D-03) + revoke-wiring (D-05) unit tests — the
    //! `cargo test -p server-windows startup` validation surface.

    use std::sync::{Arc, Mutex};

    use server_core::auth::{AuthManager, PairedDevice};

    use super::{revoke_device, smart_startup_pin};

    /// D-03: ≥1 paired device ⇒ silent startup — NO pairing window opens, so
    /// no PIN can reach notify (the caller notifies only on `Some`).
    #[test]
    fn startup_paired_is_silent() {
        let mut auth = AuthManager::from_paired(vec![PairedDevice::new(
            [7u8; 32],
            "Pixel".to_owned(),
            1_700_000_000,
        )]);
        assert_eq!(
            smart_startup_pin(&mut auth),
            None,
            "a paired store must start silent — no begin_pairing, no notify"
        );
    }

    /// D-03: zero paired devices ⇒ a pairing window opens and the PIN goes
    /// to notify (a real 6-digit PIN comes back).
    #[test]
    fn startup_unpaired_opens_a_pin_window() {
        let mut auth = AuthManager::new();
        let pin = smart_startup_pin(&mut auth).expect("zero paired opens a pairing window");
        assert_eq!(pin.len(), 6, "6-digit zero-padded PIN");
        assert!(pin.chars().all(|c| c.is_ascii_digit()));
    }

    /// D-05 wiring: revoking a present hash advances the revocation epoch
    /// (live-session drop) AND the auth change-signal (config re-save); an
    /// absent hash advances neither.
    #[test]
    fn startup_revoke_bumps_epoch_and_change_signal() {
        let mut mgr = AuthManager::new();
        let paired = mgr.complete_pairing_named("Pixel".to_owned());
        let auth = Arc::new(Mutex::new(mgr));

        let (revoke_tx, mut revoke_rx) = tokio::sync::watch::channel(0u64);
        let mut changes = auth.lock().unwrap().changes();
        let _ = changes.borrow_and_update(); // clear the pairing bump

        assert!(
            revoke_device(&auth, &revoke_tx, &paired.hash),
            "revoking a present hash reports removal"
        );
        assert!(
            revoke_rx.has_changed().unwrap(),
            "revoke advances the D-05 revocation epoch (session drop)"
        );
        assert!(
            changes.has_changed().unwrap(),
            "revoke bumps the change-signal (config re-save)"
        );

        let _ = revoke_rx.borrow_and_update();
        assert!(
            !revoke_device(&auth, &revoke_tx, &[9u8; 32]),
            "an absent hash removes nothing"
        );
        assert!(
            !revoke_rx.has_changed().unwrap(),
            "an absent hash must never advance the revocation epoch"
        );
    }
}
