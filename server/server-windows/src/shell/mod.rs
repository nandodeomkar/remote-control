//! Server tray-daemon shell (SRV-01): a dedicated `std::thread` running a
//! winit 0.30 event loop (`with_any_thread(true)`) that owns the `tray-icon`
//! system-tray icon and (later, 07-08) an on-demand egui settings window.
//! `main.rs` stays `#[tokio::main]`; this thread and the tokio runtime talk
//! over `tokio::sync::watch` channels plus an `EventLoopProxy<UserEvent>`
//! (RESEARCH Pattern 1 / SHARED-D — the same dedicated-OS-thread idiom as
//! the input/audio/apps/clip threads in `main.rs`).

pub mod tray;

use std::sync::{Arc, Mutex};

use server_core::auth::AuthManager;
use tokio::sync::watch;
use tray_icon::menu::MenuEvent;
use tray_icon::TrayIconEvent;
use winit::application::ApplicationHandler;
use winit::event::{StartCause, WindowEvent};
use winit::event_loop::{ActiveEventLoop, EventLoop, EventLoopProxy};
use winit::platform::windows::EventLoopBuilderExtWindows;
use winit::window::WindowId;

use crate::firewall::FirewallStatus;
use tray::{Tray, TrayState};

/// Events delivered INTO the shell thread's winit loop: tray/menu callbacks
/// (which the OS invokes on an arbitrary thread — forwarded via the
/// `Send + Sync` `EventLoopProxy`) plus the one tokio→shell push (`Tooltip`)
/// the composition root drives off the `conn_count` watch.
pub enum UserEvent {
    /// Click/hover/enter/leave on the tray icon itself. Carried through for
    /// 07-08 (e.g. a left-click could one day open the settings window);
    /// today's `ShellApp::user_event` intentionally discards the payload —
    /// muda/tray-icon already draws the OS-native context menu without our
    /// help (hence `#[allow(dead_code)]`: this is an interface-first field,
    /// not a bug).
    #[allow(dead_code)]
    Tray(TrayIconEvent),
    Menu(MenuEvent),
    /// Live connected-device COUNT — never names (T-07-20).
    Tooltip(usize),
}

/// Everything the shell thread needs from the composition root. ALL fields
/// are defined now (interface-first, RESEARCH SHARED-D): this plan's
/// bootstrap only reads/drives `conn_count`/`pause_tx`/quit/`firewall_status`
/// /`notify_firewall`; `auth`/`revoke_tx` are unused until 07-08's on-demand
/// settings window (Pair-new / paired-list revoke) consumes them.
/// `config`/`autostart` are placeholder `()` handles — 07-07 has not landed
/// `config.rs` yet, and `crate::autostart::{enable,disable,is_enabled}` are
/// today free functions needing no state; 07-08 will retype both fields to
/// whatever real handle its settings window needs.
pub struct ShellCtx {
    /// Live connected-device count (SRV-01 tooltip source).
    pub conn_count: watch::Receiver<usize>,
    /// The existing server-side pause seam (SPEC §11) — the tray's Pause
    /// menu item flips this.
    pub pause_tx: watch::Sender<bool>,
    /// Shared pairing state — unused by this plan's bootstrap; 07-08's
    /// on-demand "Pair new device" / paired-list revoke reads/drives it.
    #[allow(dead_code)]
    pub auth: Arc<Mutex<AuthManager>>,
    /// D-05 revocation epoch sender — unused by this plan's bootstrap;
    /// 07-08's settings-window revoke button drives it.
    #[allow(dead_code)]
    pub revoke_tx: watch::Sender<u64>,
    /// Placeholder until 07-07's `config.rs` lands a real config handle.
    #[allow(dead_code)]
    pub config: (),
    /// Placeholder until 07-08's settings window needs a real autostart
    /// handle.
    #[allow(dead_code)]
    pub autostart: (),
    /// The startup firewall/bind self-test verdict (SRV-04 / D-06), set by
    /// `main.rs` BEFORE spawning this thread so the tray can render the
    /// warning state from `StartCause::Init` onward.
    pub firewall_status: FirewallStatus,
    /// Whether the (07-08) settings window should show the persistent
    /// firewall-hint banner: `true` whenever `firewall_status` is anything
    /// other than `Allowed` (a `BlockedNoRule` warning OR an inconclusive
    /// `Unknown` read both merit the hint — only a confirmed `Allowed`
    /// suppresses it). Unread until 07-08's settings window exists.
    #[allow(dead_code)]
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
        let _ = proxy_tx.send(proxy);

        let mut app = ShellApp {
            ctx,
            tray: None,
            paused: false,
        };
        let _ = event_loop.run_app(&mut app);
    });

    proxy_rx
        .recv()
        .expect("shell thread panicked before handing back its EventLoopProxy")
}

/// The winit `ApplicationHandler` driving the tray. Owns the [`Tray`] (built
/// lazily on `StartCause::Init` — RESEARCH Pitfall 3, never at spawn time).
struct ShellApp {
    ctx: ShellCtx,
    tray: Option<Tray>,
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
}

impl ApplicationHandler<UserEvent> for ShellApp {
    fn new_events(&mut self, _event_loop: &ActiveEventLoop, cause: StartCause) {
        // Tray MUST be created on StartCause::Init, never at thread-spawn
        // time (RESEARCH Pitfall 3). Guard against a spurious re-fire.
        if cause != StartCause::Init || self.tray.is_some() {
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
                // WebSocket listener runs regardless) — log and keep the
                // loop alive.
                tracing::warn!(error = %e, "tray icon creation failed");
            }
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
                if *menu_event.id() == *tray.pause_id() {
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
            UserEvent::Tray(_) => {
                // Click/hover: tray-icon/muda already draws the OS-native
                // context menu on left/right click — nothing else to do.
            }
        }
    }

    fn window_event(&mut self, _event_loop: &ActiveEventLoop, _window_id: WindowId, _event: WindowEvent) {
        // The tray owns no winit Window (its message-only HWND lives inside
        // tray-icon's platform_impl) — nothing to route here. 07-08's
        // on-demand egui settings window will handle real WindowEvents.
    }
}
