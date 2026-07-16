//! Server tray-daemon shell (SRV-01/SRV-03, Phase 10 redesign): a dedicated
//! `std::thread` running a winit 0.30 event loop (`with_any_thread(true)`)
//! that owns the menu-less `tray-icon` tray, the custom [`flyout::Flyout`]
//! panel (replacing the OS context menu), and the on-demand egui windows —
//! main dashboard, settings, pair-new-device. `main.rs` stays
//! `#[tokio::main]`; this thread and the tokio runtime talk over
//! `tokio::sync::watch` channels plus an `EventLoopProxy<UserEvent>`
//! (RESEARCH Pattern 1 / SHARED-D).

pub mod chrome;
pub mod flyout;
pub mod glwin;
pub mod main_window;
pub mod pair_window;
pub mod settings;
pub mod style;
pub mod tray;

use std::sync::atomic::AtomicBool;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use server_core::auth::AuthManager;
use tokio::sync::watch;
use tray_icon::{MouseButton, MouseButtonState, TrayIconEvent};
use winit::application::ApplicationHandler;
use winit::event::{StartCause, WindowEvent};
use winit::event_loop::{ActiveEventLoop, ControlFlow, EventLoop, EventLoopProxy};
use winit::platform::windows::EventLoopBuilderExtWindows;
use winit::window::WindowId;

use crate::config::SharedSettings;
use crate::firewall::FirewallStatus;
use chrome::ShellAction;
use flyout::Flyout;
use main_window::MainWindow;
use pair_window::PairWindow;
use settings::SettingsWindow;
use tray::{Tray, TrayState};

/// Events delivered INTO the shell thread's winit loop: tray callbacks
/// (which the OS invokes on an arbitrary thread — forwarded via the
/// `Send + Sync` `EventLoopProxy`), the tokio→shell tooltip push, and the
/// window open/repaint requests.
pub enum UserEvent {
    /// Click/hover/enter/leave on the tray icon. A left/right click-up
    /// toggles the flyout; a double-click opens the dashboard.
    Tray(TrayIconEvent),
    /// Live connected-device COUNT — never names (T-07-20).
    Tooltip(usize),
    /// Open (or focus) the on-demand settings window (SRV-03). Interface-
    /// first: in-window actions route via `ShellAction`; these proxy events
    /// exist for any tokio-side caller (e.g. a future toast click).
    #[allow(dead_code)]
    OpenSettings,
    /// Open (or focus) the main dashboard window (handoff 1a).
    #[allow(dead_code)]
    OpenMain,
    /// Open (or focus) the pair-new-device window (handoff 1c).
    #[allow(dead_code)]
    OpenPair,
    /// egui requested a repaint in `delay` (zero = now; non-zero =
    /// cursor-blink/countdown schedule). One queue serves every open window.
    Repaint(Duration),
}

/// Everything the shell thread needs from the composition root (RESEARCH
/// SHARED-D, interface-first). See field docs — shared by all four windows.
pub struct ShellCtx {
    /// Live connected-device count (SRV-01 tooltip + dashboard/flyout).
    pub conn_count: watch::Receiver<usize>,
    /// The existing server-side pause seam (SPEC §11) — flyout/dashboard
    /// Pause actions flip this.
    pub pause_tx: watch::Sender<bool>,
    /// Shared pairing state: paired lists + Revoke + on-demand pairing all
    /// go through `crate::begin_on_demand_pairing` / `crate::revoke_device`.
    pub auth: Arc<Mutex<AuthManager>>,
    /// D-05 revocation epoch sender — Revoke advances it so the 07-05
    /// session branch drops the revoked phone's live connection.
    pub revoke_tx: watch::Sender<u64>,
    /// The shared editable settings (device name/port/autostart/clip-sync).
    pub config: Arc<Mutex<SharedSettings>>,
    /// The clip thread's LIVE clipboard auto-sync gate (RESEARCH Open Q5).
    pub clip_sync: Arc<AtomicBool>,
    /// The RESOLVED WebSocket port actually bound at startup.
    pub resolved_port: u16,
    /// The startup firewall/bind self-test verdict (SRV-04 / D-06).
    pub firewall_status: FirewallStatus,
    /// Whether the settings window shows the persistent firewall hint.
    pub notify_firewall: bool,
}

/// Spawn the shell thread and return its `EventLoopProxy` so the composition
/// root can push `UserEvent::Tooltip` from a tokio task watching
/// `conn_count`. MUST be called exactly once, from `main.rs`, AFTER the
/// startup firewall self-test and BEFORE `server_core::run` blocks.
pub fn spawn_shell_thread(ctx: ShellCtx) -> EventLoopProxy<UserEvent> {
    let (proxy_tx, proxy_rx) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let event_loop = EventLoop::<UserEvent>::with_user_event()
            .with_any_thread(true) // off-main: keeps main.rs on #[tokio::main] (Pitfall 2)
            .build()
            .expect("winit event loop on the shell thread");

        // Forward tray events into THIS loop's queue. EventLoopProxy is
        // Send + Sync so the callback (invoked on whatever thread the OS
        // delivers it from) can safely push across (RESEARCH Pattern 1).
        let proxy = event_loop.create_proxy();
        let p = proxy.clone();
        TrayIconEvent::set_event_handler(Some(move |event| {
            let _ = p.send_event(UserEvent::Tray(event));
        }));

        // Hand the proxy back to the caller BEFORE the blocking run_app call
        // below — the caller is waiting on proxy_rx.recv().
        let _ = proxy_tx.send(proxy.clone());

        let mut app = ShellApp {
            ctx,
            proxy,
            tray: None,
            settings: None,
            main: None,
            pair: None,
            flyout: None,
            paused: false,
        };
        let _ = event_loop.run_app(&mut app);
    });

    proxy_rx
        .recv()
        .expect("shell thread panicked before handing back its EventLoopProxy")
}

/// The winit `ApplicationHandler` driving the tray + every shell window.
/// The tray is built lazily on `StartCause::Init` (RESEARCH Pitfall 3);
/// windows are built on demand and destroyed on close (Pitfall 4 topology).
struct ShellApp {
    ctx: ShellCtx,
    /// This loop's own proxy — egui repaint callbacks + action fan-out.
    proxy: EventLoopProxy<UserEvent>,
    tray: Option<Tray>,
    settings: Option<SettingsWindow>,
    main: Option<MainWindow>,
    pair: Option<PairWindow>,
    flyout: Option<Flyout>,
    paused: bool,
}

impl ShellApp {
    /// The icon state implied by current pause/firewall status (pause takes
    /// visual precedence — the owner explicitly asked for it).
    fn current_state(&self) -> TrayState {
        if self.paused {
            TrayState::Paused
        } else if self.ctx.firewall_status != FirewallStatus::Allowed {
            TrayState::Warning
        } else {
            TrayState::Normal
        }
    }

    fn open_settings(&mut self, event_loop: &ActiveEventLoop) {
        if let Some(open) = &self.settings {
            open.focus();
            return;
        }
        match SettingsWindow::new(event_loop, &self.ctx, self.proxy.clone()) {
            Ok(w) => self.settings = Some(w),
            Err(e) => tracing::warn!(error = %e, "settings window creation failed"),
        }
    }

    fn open_main(&mut self, event_loop: &ActiveEventLoop) {
        if let Some(open) = &self.main {
            open.focus();
            return;
        }
        match MainWindow::new(event_loop, self.proxy.clone()) {
            Ok(w) => self.main = Some(w),
            Err(e) => tracing::warn!(error = %e, "main window creation failed"),
        }
    }

    fn open_pair(&mut self, event_loop: &ActiveEventLoop) {
        if let Some(open) = &self.pair {
            open.focus();
            return;
        }
        match PairWindow::new(event_loop, &self.ctx, self.proxy.clone()) {
            Ok(w) => self.pair = Some(w),
            Err(e) => tracing::warn!(error = %e, "pair window creation failed"),
        }
    }

    fn toggle_flyout(&mut self, event_loop: &ActiveEventLoop) {
        if self.flyout.is_some() {
            self.close_flyout();
            return;
        }
        match Flyout::new(event_loop, self.proxy.clone()) {
            Ok(w) => self.flyout = Some(w),
            Err(e) => tracing::warn!(error = %e, "flyout creation failed"),
        }
    }

    fn close_flyout(&mut self) {
        if let Some(mut f) = self.flyout.take() {
            f.destroy();
        }
    }

    fn close_settings(&mut self, event_loop: &ActiveEventLoop) {
        if let Some(mut window) = self.settings.take() {
            window.commit_pending(&self.ctx);
            window.destroy();
        }
        event_loop.set_control_flow(ControlFlow::Wait);
    }

    fn close_main(&mut self, event_loop: &ActiveEventLoop) {
        if let Some(mut w) = self.main.take() {
            w.destroy();
        }
        event_loop.set_control_flow(ControlFlow::Wait);
    }

    fn close_pair(&mut self, event_loop: &ActiveEventLoop) {
        if let Some(mut w) = self.pair.take() {
            w.destroy();
        }
        event_loop.set_control_flow(ControlFlow::Wait);
    }

    /// Ask every open window for a fresh frame (state changed somewhere).
    fn redraw_all(&self) {
        if let Some(w) = &self.settings {
            w.request_redraw();
        }
        if let Some(w) = &self.main {
            w.request_redraw();
        }
        if let Some(w) = &self.pair {
            w.request_redraw();
        }
        if let Some(w) = &self.flyout {
            w.request_redraw();
        }
    }

    /// Execute the actions a window's frame returned. `source` identifies
    /// which window "Close"/"Minimize" applies to.
    fn handle_actions(
        &mut self,
        event_loop: &ActiveEventLoop,
        source: WindowKind,
        actions: Vec<ShellAction>,
    ) {
        for action in actions {
            match action {
                ShellAction::Close => match source {
                    WindowKind::Settings => self.close_settings(event_loop),
                    WindowKind::Main => self.close_main(event_loop),
                    WindowKind::Pair => self.close_pair(event_loop),
                    WindowKind::Flyout => self.close_flyout(),
                },
                ShellAction::Minimize => {
                    if source == WindowKind::Main {
                        if let Some(w) = &self.main {
                            w.minimize();
                        }
                    }
                }
                ShellAction::OpenSettings => self.open_settings(event_loop),
                ShellAction::OpenMain => self.open_main(event_loop),
                ShellAction::OpenPair => self.open_pair(event_loop),
                ShellAction::TogglePause => {
                    self.paused = !self.paused;
                    // Send-and-forget: a closed receiver means the process
                    // is already tearing down, not an error to recover from.
                    let _ = self.ctx.pause_tx.send(self.paused);
                    if let Some(tray) = &self.tray {
                        tray.set_state(self.current_state());
                    }
                    self.redraw_all();
                }
                ShellAction::Quit => {
                    event_loop.exit();
                    std::process::exit(0);
                }
            }
        }
    }
}

/// Which shell window a frame's actions came from.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum WindowKind {
    Settings,
    Main,
    Pair,
    Flyout,
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
            // A scheduled egui repaint came due — redraw open windows.
            StartCause::ResumeTimeReached { .. } => self.redraw_all(),
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
                // Dashboard/flyout show the live count — refresh them.
                self.redraw_all();
            }
            UserEvent::Tray(tray_event) => match tray_event {
                TrayIconEvent::Click {
                    button: MouseButton::Left | MouseButton::Right,
                    button_state: MouseButtonState::Up,
                    ..
                } => self.toggle_flyout(event_loop),
                TrayIconEvent::DoubleClick {
                    button: MouseButton::Left,
                    ..
                } => {
                    self.close_flyout();
                    self.open_main(event_loop);
                }
                _ => {}
            },
            UserEvent::OpenSettings => self.open_settings(event_loop),
            UserEvent::OpenMain => self.open_main(event_loop),
            UserEvent::OpenPair => self.open_pair(event_loop),
            UserEvent::Repaint(delay) => {
                // egui's repaint schedule: zero = redraw now; non-zero =
                // wake the loop when it comes due (cursor blink / countdown,
                // not a Poll spin).
                if delay.is_zero() {
                    self.redraw_all();
                } else if let Some(due) = Instant::now().checked_add(delay) {
                    event_loop.set_control_flow(ControlFlow::WaitUntil(due));
                }
            }
        }
    }

    fn window_event(&mut self, event_loop: &ActiveEventLoop, window_id: WindowId, event: WindowEvent) {
        let kind = if self.settings.as_ref().map(SettingsWindow::window_id) == Some(window_id) {
            WindowKind::Settings
        } else if self.main.as_ref().map(MainWindow::window_id) == Some(window_id) {
            WindowKind::Main
        } else if self.pair.as_ref().map(PairWindow::window_id) == Some(window_id) {
            WindowKind::Pair
        } else if self.flyout.as_ref().map(Flyout::window_id) == Some(window_id) {
            WindowKind::Flyout
        } else {
            return;
        };

        match event {
            // On-demand lifecycle: close destroys the window; the tray (and
            // server) live on. Reopening builds a fresh one.
            WindowEvent::CloseRequested | WindowEvent::Destroyed => {
                self.handle_actions(event_loop, kind, vec![ShellAction::Close]);
            }
            // The flyout dismisses like a menu when it loses focus (after a
            // short grace period — a slow initial focus grant must not
            // insta-close it).
            WindowEvent::Focused(false) if kind == WindowKind::Flyout => {
                if self.flyout.as_ref().is_some_and(Flyout::should_dismiss_on_blur) {
                    self.close_flyout();
                }
            }
            WindowEvent::RedrawRequested => {
                let actions = match kind {
                    WindowKind::Settings => self
                        .settings
                        .as_mut()
                        .map(|w| w.redraw(&self.ctx))
                        .unwrap_or_default(),
                    WindowKind::Main => {
                        let paused = self.paused;
                        self.main
                            .as_mut()
                            .map(|w| w.redraw(&self.ctx, paused))
                            .unwrap_or_default()
                    }
                    WindowKind::Pair => self
                        .pair
                        .as_mut()
                        .map(|w| w.redraw(&self.ctx))
                        .unwrap_or_default(),
                    WindowKind::Flyout => {
                        let paused = self.paused;
                        self.flyout
                            .as_mut()
                            .map(|w| w.redraw(&self.ctx, paused))
                            .unwrap_or_default()
                    }
                };
                self.handle_actions(event_loop, kind, actions);
            }
            other => {
                let repaint = match kind {
                    WindowKind::Settings => self.settings.as_mut().map(|w| {
                        if let WindowEvent::Resized(size) = &other {
                            w.resize(*size);
                        }
                        w.on_window_event(&other)
                    }),
                    WindowKind::Main => self.main.as_mut().map(|w| {
                        if let WindowEvent::Resized(size) = &other {
                            w.resize(*size);
                        }
                        w.on_window_event(&other)
                    }),
                    WindowKind::Pair => self.pair.as_mut().map(|w| {
                        if let WindowEvent::Resized(size) = &other {
                            w.resize(*size);
                        }
                        w.on_window_event(&other)
                    }),
                    WindowKind::Flyout => self.flyout.as_mut().map(|w| {
                        if let WindowEvent::Resized(size) = &other {
                            w.resize(*size);
                        }
                        w.on_window_event(&other)
                    }),
                };
                if repaint.unwrap_or(false) {
                    match kind {
                        WindowKind::Settings => {
                            if let Some(w) = &self.settings {
                                w.request_redraw();
                            }
                        }
                        WindowKind::Main => {
                            if let Some(w) = &self.main {
                                w.request_redraw();
                            }
                        }
                        WindowKind::Pair => {
                            if let Some(w) = &self.pair {
                                w.request_redraw();
                            }
                        }
                        WindowKind::Flyout => {
                            if let Some(w) = &self.flyout {
                                w.request_redraw();
                            }
                        }
                    }
                }
            }
        }
    }
}
