//! Server tray-daemon shell (SRV-01/SRV-03): a dedicated `std::thread`
//! running a winit 0.30 event loop (`with_any_thread(true)`) that owns the
//! `tray-icon` system-tray icon and the on-demand egui settings window
//! (07-08). `main.rs` stays `#[tokio::main]`; this thread and the tokio
//! runtime talk over `tokio::sync::watch` channels plus an
//! `EventLoopProxy<UserEvent>` (RESEARCH Pattern 1 / SHARED-D — the same
//! dedicated-OS-thread idiom as the input/audio/apps/clip threads in
//! `main.rs`).

pub mod settings;
pub mod tray;

use std::sync::atomic::AtomicBool;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use server_core::auth::AuthManager;
use tokio::sync::watch;
use tray_icon::menu::MenuEvent;
use tray_icon::TrayIconEvent;
use winit::application::ApplicationHandler;
use winit::event::{StartCause, WindowEvent};
use winit::event_loop::{ActiveEventLoop, ControlFlow, EventLoop, EventLoopProxy};
use winit::platform::windows::EventLoopBuilderExtWindows;
use winit::window::WindowId;

use crate::config::SharedSettings;
use crate::firewall::FirewallStatus;
use settings::SettingsWindow;
use tray::{Tray, TrayState};

/// Events delivered INTO the shell thread's winit loop: tray/menu callbacks
/// (which the OS invokes on an arbitrary thread — forwarded via the
/// `Send + Sync` `EventLoopProxy`), the tokio→shell tooltip push, and the
/// settings-window open/repaint requests (07-08).
pub enum UserEvent {
    /// Click/hover/enter/leave on the tray icon itself. Carried through as
    /// an interface-first field (e.g. a left-click could one day open the
    /// settings window); today's `ShellApp::user_event` intentionally
    /// discards the payload — muda/tray-icon already draws the OS-native
    /// context menu without our help (hence `#[allow(dead_code)]`).
    #[allow(dead_code)]
    Tray(TrayIconEvent),
    Menu(MenuEvent),
    /// Live connected-device COUNT — never names (T-07-20).
    Tooltip(usize),
    /// Open (or focus) the on-demand egui settings window (SRV-03). Sent by
    /// the tray's Settings menu item; any future caller (e.g. a tray
    /// left-click) can push the same event through the proxy.
    OpenSettings,
    /// egui requested a repaint in `delay` (its request-repaint callback —
    /// zero = now, non-zero = cursor-blink/animation schedule). Riding the
    /// user-event queue keeps delayed repaints off a busy render loop.
    SettingsRepaint(Duration),
}

/// Everything the shell thread needs from the composition root (RESEARCH
/// SHARED-D, interface-first): the tray bootstrap (07-06) reads/drives
/// `conn_count`/`pause_tx`/quit/`firewall_status`/`notify_firewall`; the
/// settings window (07-08) additionally drives `auth` (Pair-new / paired
/// list), `revoke_tx` (per-row Revoke), `config` (the shared editable
/// settings persisted via the 07-07 save path), and `clip_sync` (the clip
/// thread's LIVE auto-sync gate).
pub struct ShellCtx {
    /// Live connected-device count (SRV-01 tooltip source).
    pub conn_count: watch::Receiver<usize>,
    /// The existing server-side pause seam (SPEC §11) — the tray's Pause
    /// menu item flips this.
    pub pause_tx: watch::Sender<bool>,
    /// Shared pairing state: the settings paired-device list + Revoke and
    /// the on-demand "Pair new device" (both tray and settings) read/drive
    /// it via `crate::begin_on_demand_pairing` / `crate::revoke_device`.
    pub auth: Arc<Mutex<AuthManager>>,
    /// D-05 revocation epoch sender — the settings Revoke button advances it
    /// (via `crate::revoke_device`) so the 07-05 session branch drops the
    /// revoked phone's live connection.
    pub revoke_tx: watch::Sender<u64>,
    /// The shared editable settings (device name/port/autostart/clip-sync).
    /// The settings window mutates it; the composition root's auth-change
    /// save task reads it on every config re-serialize (07-07/07-08).
    pub config: Arc<Mutex<SharedSettings>>,
    /// The clip thread's LIVE clipboard auto-sync gate (RESEARCH Open Q5):
    /// the settings checkbox flips it immediately; the config write makes
    /// the choice stick across restarts.
    pub clip_sync: Arc<AtomicBool>,
    /// The RESOLVED WebSocket port actually bound at startup (`RC_PORT` env
    /// > config > default) — shown by the settings port field's hint and the
    /// firewall fix text. Display-only; edits go to `config.port`.
    pub resolved_port: u16,
    /// The startup firewall/bind self-test verdict (SRV-04 / D-06), set by
    /// `main.rs` BEFORE spawning this thread so the tray can render the
    /// warning state from `StartCause::Init` onward.
    pub firewall_status: FirewallStatus,
    /// Whether the settings window should show the persistent firewall-hint
    /// banner: `true` whenever `firewall_status` is anything other than
    /// `Allowed` (a `BlockedNoRule` warning OR an inconclusive `Unknown`
    /// read both merit the hint — only a confirmed `Allowed` suppresses it).
    pub notify_firewall: bool,
}

/// Spawn the shell thread and return its `EventLoopProxy` so the composition
/// root can push `UserEvent::Tooltip` from a tokio task watching
/// `conn_count`. MUST be called exactly once, from `main.rs`, AFTER the
/// startup firewall self-test (`ctx.firewall_status` is read at
/// `StartCause::Init`) and BEFORE `server_core::run` blocks the tokio main
/// task forever.
///
/// The proxy is handed back over a one-shot `mpsc` (SHARED-D idiom: build
/// the channel pair BEFORE spawning, same shape as every other dedicated
/// thread in `main.rs`) because `create_proxy()` needs the `EventLoop`,
/// which can only be constructed ON the new thread (Pitfall 2).
pub fn spawn_shell_thread(ctx: ShellCtx) -> EventLoopProxy<UserEvent> {
    let (proxy_tx, proxy_rx) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let event_loop = EventLoop::<UserEvent>::with_user_event()
            .with_any_thread(true) // off-main: keeps main.rs on #[tokio::main] (Pitfall 2)
            .build()
            .expect("winit event loop on the shell thread");

        // Forward tray + menu events into THIS loop's queue. EventLoopProxy
        // is Send + Sync so the callback (invoked on whatever thread the OS
        // delivers it from) can safely push across (RESEARCH Pattern 1).
        let proxy = event_loop.create_proxy();
        let p = proxy.clone();
        TrayIconEvent::set_event_handler(Some(move |event| {
            let _ = p.send_event(UserEvent::Tray(event));
        }));
        let p = proxy.clone();
        MenuEvent::set_event_handler(Some(move |event| {
            let _ = p.send_event(UserEvent::Menu(event));
        }));

        // Hand the proxy back to the caller BEFORE the blocking run_app call
        // below — the caller is waiting on proxy_rx.recv().
        let _ = proxy_tx.send(proxy.clone());

        let mut app = ShellApp {
            ctx,
            proxy,
            tray: None,
            settings: None,
            paused: false,
        };
        let _ = event_loop.run_app(&mut app);
    });

    proxy_rx
        .recv()
        .expect("shell thread panicked before handing back its EventLoopProxy")
}

/// The winit `ApplicationHandler` driving the tray + settings window. Owns
/// the [`Tray`] (built lazily on `StartCause::Init` — RESEARCH Pitfall 3,
/// never at spawn time) and the on-demand [`SettingsWindow`] (built when a
/// Settings event fires, destroyed on close — Pitfall 4's egui-on-winit
/// topology).
struct ShellApp {
    ctx: ShellCtx,
    /// This loop's own proxy — the settings window's egui repaint callback
    /// pushes `SettingsRepaint` through it; menu handlers route
    /// `OpenSettings` through it.
    proxy: EventLoopProxy<UserEvent>,
    tray: Option<Tray>,
    settings: Option<SettingsWindow>,
    paused: bool,
}

impl ShellApp {
    /// The icon state implied by current pause/firewall status (pause takes
    /// visual precedence — the owner explicitly asked for it; the firewall
    /// warning stays informative-but-secondary once paused).
    fn current_state(&self) -> TrayState {
        if self.paused {
            TrayState::Paused
        } else if self.ctx.firewall_status != FirewallStatus::Allowed {
            TrayState::Warning
        } else {
            TrayState::Normal
        }
    }

    /// Create the settings window ON DEMAND on this loop — or focus the one
    /// already open (a second Settings click must not spawn a twin). A
    /// creation failure is log-and-continue: a dead settings window must
    /// never take the tray down with it.
    fn open_settings(&mut self, event_loop: &ActiveEventLoop) {
        if let Some(open) = &self.settings {
            open.focus();
            return;
        }
        match SettingsWindow::new(event_loop, &self.ctx, self.proxy.clone()) {
            Ok(window) => {
                window.request_redraw(); // first frame
                self.settings = Some(window);
            }
            Err(e) => tracing::warn!(error = %e, "settings window creation failed"),
        }
    }

    /// Destroy the settings window (close button): commit any in-progress
    /// text edits first, release GPU resources, drop the whole GL stack, and
    /// fall back to a plain Wait control flow (no window left to repaint).
    fn close_settings(&mut self, event_loop: &ActiveEventLoop) {
        if let Some(mut window) = self.settings.take() {
            window.commit_pending(&self.ctx);
            window.destroy();
        }
        event_loop.set_control_flow(ControlFlow::Wait);
    }
}

impl ApplicationHandler<UserEvent> for ShellApp {
    fn new_events(&mut self, _event_loop: &ActiveEventLoop, cause: StartCause) {
        match cause {
            // Tray MUST be created on StartCause::Init, never at thread-spawn
            // time (RESEARCH Pitfall 3). Guard against a spurious re-fire.
            StartCause::Init => {
                if self.tray.is_some() {
                    return;
                }
                match Tray::new() {
                    Ok(tray) => {
                        tray.set_tooltip(*self.ctx.conn_count.borrow());
                        tray.set_state(self.current_state());
                        self.tray = Some(tray);
                    }
                    Err(e) => {
                        // A dead tray is not fatal to the server itself (the
                        // WebSocket listener runs regardless) — log and keep
                        // the loop alive.
                        tracing::warn!(error = %e, "tray icon creation failed");
                    }
                }
            }
            // A scheduled egui repaint (SettingsRepaint set WaitUntil) came
            // due — redraw the settings window.
            StartCause::ResumeTimeReached { .. } => {
                if let Some(window) = &self.settings {
                    window.request_redraw();
                }
            }
            _ => {}
        }
    }

    fn resumed(&mut self, _event_loop: &ActiveEventLoop) {}

    fn user_event(&mut self, event_loop: &ActiveEventLoop, event: UserEvent) {
        match event {
            UserEvent::Tooltip(count) => {
                if let Some(tray) = &self.tray {
                    tray.set_tooltip(count);
                }
            }
            UserEvent::Menu(menu_event) => {
                let Some(tray) = &self.tray else { return };
                if *menu_event.id() == *tray.settings_id() {
                    // Route through OpenSettings (not a direct call) so the
                    // tray item and any future opener share one entry point.
                    let _ = self.proxy.send_event(UserEvent::OpenSettings);
                } else if *menu_event.id() == *tray.pair_id() {
                    // D-02: on-demand pairing straight from the tray —
                    // AuthManager::begin_pairing + notify_pin via the
                    // ShellCtx auth Arc, no settings window needed.
                    crate::begin_on_demand_pairing(&self.ctx.auth);
                } else if *menu_event.id() == *tray.pause_id() {
                    self.paused = !self.paused;
                    // Send-and-forget: a closed receiver means the process
                    // is already tearing down, not an error to recover from.
                    let _ = self.ctx.pause_tx.send(self.paused);
                    tray.set_state(self.current_state());
                } else if *menu_event.id() == *tray.quit_id() {
                    event_loop.exit();
                    std::process::exit(0);
                }
            }
            UserEvent::OpenSettings => self.open_settings(event_loop),
            UserEvent::SettingsRepaint(delay) => {
                // egui's repaint schedule: zero = redraw now; non-zero =
                // wake the loop when it comes due (cursor blink at ~2Hz, not
                // a Poll spin). Ignored when the window has already closed.
                let Some(window) = &self.settings else { return };
                if delay.is_zero() {
                    window.request_redraw();
                } else if let Some(due) = Instant::now().checked_add(delay) {
                    event_loop.set_control_flow(ControlFlow::WaitUntil(due));
                }
            }
            UserEvent::Tray(_) => {
                // Click/hover: tray-icon/muda already draws the OS-native
                // context menu on left/right click — nothing else to do.
            }
        }
    }

    fn window_event(&mut self, event_loop: &ActiveEventLoop, window_id: WindowId, event: WindowEvent) {
        // The only winit Window this loop owns is the settings window (the
        // tray's message-only HWND lives inside tray-icon's platform_impl).
        if self.settings.as_ref().map(SettingsWindow::window_id) != Some(window_id) {
            return;
        }
        match event {
            // On-demand lifecycle: close destroys the window; the tray (and
            // server) live on. Reopening builds a fresh one.
            WindowEvent::CloseRequested | WindowEvent::Destroyed => {
                self.close_settings(event_loop);
            }
            WindowEvent::RedrawRequested => {
                if let Some(window) = self.settings.as_mut() {
                    window.redraw(&self.ctx);
                }
            }
            other => {
                if let Some(window) = self.settings.as_mut() {
                    if let WindowEvent::Resized(size) = &other {
                        window.resize(*size);
                    }
                    // Forward to egui; repaint when it consumed something.
                    if window.on_window_event(&other) {
                        window.request_redraw();
                    }
                }
            }
        }
    }
}
