//! On-demand egui-on-winit settings window (SRV-03/SRV-02/SRV-04) hosted on
//! the shell thread's SHARED winit loop — egui + egui-winit + egui_glow
//! driven directly, deliberately NOT egui's `run_native` framework wrapper
//! (that wrapper owns its own event loop and cannot share the tray's —
//! RESEARCH Pitfall 4 / egui#2875).
//!
//! Lifecycle: created ON DEMAND when [`super::UserEvent::OpenSettings`]
//! fires (the tray's Settings item), destroyed when the owner closes the
//! window. The tray — and the whole server — outlives every open/close
//! cycle. The GL context/surface plumbing mirrors egui_glow 0.35's own
//! `pure_glow` example (glutin 0.32 + glutin-winit 0.5, the exact pairing
//! egui_glow tests against).
//!
//! What it manages (SRV-03):
//! - device name / port / clipboard-sync — persisted through the 07-07
//!   config path via the [`super::ShellCtx::config`] shared handle; a port
//!   or name change shows "Restart to apply" (RESEARCH Open Q3 — the
//!   listener and beacon bind once at startup, no live re-bind).
//! - autostart — [`crate::autostart`] HKCU Run toggle (SRV-02), applied
//!   immediately.
//! - repaint scheduling rides the shell loop's `UserEvent` queue (egui's
//!   request-repaint callback → `SettingsRepaint`), so delayed repaints
//!   (cursor blink) never busy-spin the loop.

use std::num::NonZeroU32;
use std::sync::atomic::Ordering;
use std::sync::Arc;

use egui_glow::glow;
use egui_glow::glow::HasContext as _;
use egui_glow::EguiGlow;
use glutin::config::ConfigTemplateBuilder;
use glutin::context::{ContextApi, ContextAttributesBuilder, PossiblyCurrentContext};
use glutin::display::GetGlDisplay as _;
use glutin::prelude::*;
use glutin::surface::{Surface, SurfaceAttributesBuilder, SwapInterval, WindowSurface};
use winit::dpi::{LogicalSize, PhysicalSize};
use winit::event::WindowEvent;
use winit::event_loop::{ActiveEventLoop, EventLoopProxy};
use winit::raw_window_handle::HasWindowHandle as _;
use winit::window::{Window, WindowId};

use super::{ShellCtx, UserEvent};
use crate::firewall::FirewallStatus;
use crate::{autostart, config};

/// D-12 locked palette (same tokens as the tray icons / Flutter app).
const ACCENT_BLUE: egui::Color32 = egui::Color32::from_rgb(0x4C, 0x8D, 0xFF);
const ERROR_RED: egui::Color32 = egui::Color32::from_rgb(0xFF, 0x6B, 0x6B);
const MUTED_GRAY: egui::Color32 = egui::Color32::from_rgb(0x6B, 0x72, 0x80);
/// Window clear color — the app's #0E0F12 dark background.
const BG_CLEAR: (f32, f32, f32) = (0.055, 0.059, 0.071);

/// The on-demand settings window: a winit `Window` + glutin GL context/
/// surface + [`EguiGlow`] (painter + egui-winit state), all owned together
/// so a close drops the whole stack at once.
pub struct SettingsWindow {
    window: Window,
    gl_context: PossiblyCurrentContext,
    gl_surface: Surface<WindowSurface>,
    gl: Arc<glow::Context>,
    egui_glow: EguiGlow,
    ui: UiState,
}

impl SettingsWindow {
    /// Build the window + GL stack ON the shell loop (must be called from
    /// the shell thread with its `ActiveEventLoop`). Every fallible step
    /// surfaces as `anyhow::Error` so the caller can log-and-continue — a
    /// failed settings window must never kill the tray.
    pub fn new(
        event_loop: &ActiveEventLoop,
        ctx: &ShellCtx,
        proxy: EventLoopProxy<UserEvent>,
    ) -> anyhow::Result<Self> {
        let attrs = Window::default_attributes()
            .with_title("Remote Control — Settings")
            .with_inner_size(LogicalSize::new(460.0, 560.0))
            // Hidden until the GL stack is up; shown at the end of new().
            .with_visible(false);

        // A bare RGBA config — no depth/stencil needed for a 2D UI.
        let template = ConfigTemplateBuilder::new()
            .prefer_hardware_accelerated(None)
            .with_depth_size(0)
            .with_stencil_size(0)
            .with_transparency(false);

        let (window, gl_config) = glutin_winit::DisplayBuilder::new()
            .with_preference(glutin_winit::ApiPreference::FallbackEgl)
            .with_window_attributes(Some(attrs.clone()))
            .build(event_loop, template, |mut configs| {
                // A Windows desktop always exposes at least one GL config;
                // an empty iterator here means the GPU stack is broken
                // beyond anything we could recover from.
                configs.next().expect("no OpenGL config available")
            })
            .map_err(|e| anyhow::anyhow!("GL display/config creation failed: {e}"))?;

        // DisplayBuilder MAY create the window while probing configs; if it
        // didn't, finalize it against the chosen config now.
        let window = match window {
            Some(w) => w,
            None => glutin_winit::finalize_window(event_loop, attrs, &gl_config)
                .map_err(|e| anyhow::anyhow!("settings window creation failed: {e}"))?,
        };

        let raw_handle = window
            .window_handle()
            .map_err(|e| anyhow::anyhow!("window handle unavailable: {e}"))?
            .as_raw();
        let gl_display = gl_config.display();

        // Core GL first; GLES fallback second (egui_glow example discipline).
        let context_attrs = ContextAttributesBuilder::new().build(Some(raw_handle));
        let fallback_attrs = ContextAttributesBuilder::new()
            .with_context_api(ContextApi::Gles(None))
            .build(Some(raw_handle));
        // SAFETY: raw_handle belongs to `window`, which this struct owns for
        // at least as long as the context/surface built from it.
        let not_current = unsafe {
            gl_display
                .create_context(&gl_config, &context_attrs)
                .or_else(|_| gl_display.create_context(&gl_config, &fallback_attrs))
        }
        .map_err(|e| anyhow::anyhow!("GL context creation failed: {e}"))?;

        let (width, height): (u32, u32) = window.inner_size().into();
        let surface_attrs = SurfaceAttributesBuilder::<WindowSurface>::new().build(
            raw_handle,
            NonZeroU32::new(width).unwrap_or(NonZeroU32::MIN),
            NonZeroU32::new(height).unwrap_or(NonZeroU32::MIN),
        );
        // SAFETY: same raw_handle ownership argument as create_context above.
        let gl_surface = unsafe { gl_display.create_window_surface(&gl_config, &surface_attrs) }
            .map_err(|e| anyhow::anyhow!("GL surface creation failed: {e}"))?;
        let gl_context = not_current
            .make_current(&gl_surface)
            .map_err(|e| anyhow::anyhow!("make_current failed: {e}"))?;
        // Block swap on vsync so a repaint-happy frame can never spin the
        // shell thread (best-effort — some drivers refuse; that's fine).
        let _ = gl_surface.set_swap_interval(&gl_context, SwapInterval::Wait(NonZeroU32::MIN));

        // SAFETY: the display outlives `gl` (both owned by this struct); the
        // loader closure only resolves symbol addresses.
        let gl = Arc::new(unsafe {
            glow::Context::from_loader_function(|symbol| {
                let c = std::ffi::CString::new(symbol)
                    .expect("GL symbol names never contain interior NULs");
                gl_display.get_proc_address(&c)
            })
        });

        let egui_glow = EguiGlow::new(event_loop, Arc::clone(&gl), None, None, true);
        // Match the app's locked dark theme regardless of the OS setting.
        egui_glow.egui_ctx.set_theme(egui::Theme::Dark);
        // Delayed repaints (cursor blink, animations) ride the shell loop's
        // user-event queue — `SettingsRepaint` sets Wait/WaitUntil there.
        let repaint_proxy = egui::mutex::Mutex::new(proxy);
        egui_glow.egui_ctx.set_request_repaint_callback(move |info| {
            let _ = repaint_proxy
                .lock()
                .send_event(UserEvent::SettingsRepaint(info.delay));
        });

        // Seed the edit buffers from the live shared settings (07-07 values
        // as edited so far this run) + the real registry autostart state.
        let shared = ctx
            .config
            .lock()
            .expect("settings mutex poisoned at window open")
            .clone();
        let ui = UiState {
            device_name: shared.device_name.unwrap_or_default(),
            port_text: shared.port.map(|p| p.to_string()).unwrap_or_default(),
            autostart_enabled: autostart::is_enabled(),
            restart_needed: false,
            autostart_error: false,
        };

        window.set_visible(true);
        Ok(Self {
            window,
            gl_context,
            gl_surface,
            gl,
            egui_glow,
            ui,
        })
    }

    /// The winit id — the shell loop routes `WindowEvent`s by it.
    pub fn window_id(&self) -> WindowId {
        self.window.id()
    }

    /// Bring an already-open window to the front (second Settings click).
    pub fn focus(&self) {
        self.window.focus_window();
    }

    /// Ask the OS for a redraw (egui repaint scheduling).
    pub fn request_redraw(&self) {
        self.window.request_redraw();
    }

    /// Resize the GL surface with the window (a zero dimension — minimize —
    /// is skipped; GL surfaces reject it).
    pub fn resize(&self, size: PhysicalSize<u32>) {
        if size.width == 0 || size.height == 0 {
            return;
        }
        self.gl_surface.resize(
            &self.gl_context,
            NonZeroU32::new(size.width).unwrap_or(NonZeroU32::MIN),
            NonZeroU32::new(size.height).unwrap_or(NonZeroU32::MIN),
        );
    }

    /// Forward a window event to egui; returns whether egui wants a repaint.
    pub fn on_window_event(&mut self, event: &WindowEvent) -> bool {
        self.egui_glow.on_window_event(&self.window, event).repaint
    }

    /// Run one egui frame + paint + swap (the `RedrawRequested` handler).
    pub fn redraw(&mut self, ctx: &ShellCtx) {
        let Self {
            window,
            gl_context,
            gl_surface,
            gl,
            egui_glow,
            ui,
        } = self;
        egui_glow.run(window, |root| ui.render(ctx, root));
        // SAFETY: plain state-set + clear on our own current GL context.
        unsafe {
            gl.clear_color(BG_CLEAR.0, BG_CLEAR.1, BG_CLEAR.2, 1.0);
            gl.clear(glow::COLOR_BUFFER_BIT);
        }
        egui_glow.paint(window);
        if let Err(e) = gl_surface.swap_buffers(gl_context) {
            // Cosmetic failure — never panic the shell loop over a frame.
            tracing::warn!(error = %e, "settings window swap_buffers failed");
        }
    }

    /// Commit any in-progress text edits (called on window close so a typed
    /// device name / port is never lost to a missing lost-focus event).
    pub fn commit_pending(&mut self, ctx: &ShellCtx) {
        self.ui.commit_device_name(ctx);
        self.ui.commit_port(ctx);
    }

    /// Release GPU resources (called right before the window is dropped).
    pub fn destroy(&mut self) {
        self.egui_glow.destroy();
    }
}

/// Immediate-mode UI state: the text-edit buffers + inline note flags.
struct UiState {
    /// Device-name edit buffer (empty = use `COMPUTERNAME`).
    device_name: String,
    /// Port edit buffer (empty = use the default port).
    port_text: String,
    /// Cached HKCU Run state — refreshed only on toggle, never per frame.
    autostart_enabled: bool,
    /// A committed name/port change needs a restart (RESEARCH Open Q3 —
    /// the listener and beacon bind once at startup; no live re-bind).
    restart_needed: bool,
    /// The last autostart toggle failed (registry write error).
    autostart_error: bool,
}

impl UiState {
    /// One immediate-mode frame: fields bound to the shared settings handle,
    /// the autostart toggle, the paired-device list, and the firewall hint.
    fn render(&mut self, ctx: &ShellCtx, ui: &mut egui::Ui) {
        egui::Frame::new()
            .inner_margin(16)
            .show(ui, |ui| {
                egui::ScrollArea::vertical()
                    .auto_shrink([false; 2])
                    .show(ui, |ui| {
                        ui.heading("Settings");
                        ui.add_space(10.0);

                        self.render_firewall_hint(ctx, ui);
                        self.render_general(ctx, ui);
                        self.render_paired_devices(ctx, ui);
                    });
            });
    }

    /// SRV-04 / D-06: the PERSISTENT firewall hint — rendered every frame
    /// the window is open, whenever the startup self-test could not confirm
    /// inbound is allowed. Read-only status; the text carries no secret
    /// (T-07-34).
    fn render_firewall_hint(&mut self, ctx: &ShellCtx, ui: &mut egui::Ui) {
        if !ctx.notify_firewall {
            return;
        }
        let port = ctx.resolved_port;
        match ctx.firewall_status {
            FirewallStatus::BlockedNoRule => {
                ui.colored_label(
                    ERROR_RED,
                    format!(
                        "Windows Firewall is blocking inbound TCP {port} — your phone \
                         can't connect. Fix: Windows Security → Firewall & network \
                         protection → Allow an app through firewall → add Remote Control."
                    ),
                );
            }
            _ => {
                ui.colored_label(
                    MUTED_GRAY,
                    format!(
                        "Couldn't confirm Windows Firewall allows inbound TCP {port}. \
                         If your phone can't connect, allow Remote Control through the \
                         firewall."
                    ),
                );
            }
        }
        ui.add_space(10.0);
    }

    /// Device name / port / clipboard-sync / autostart (SRV-03 + SRV-02).
    fn render_general(&mut self, ctx: &ShellCtx, ui: &mut egui::Ui) {
        ui.label("Device name (shown on your phone)");
        let name = ui.add(
            egui::TextEdit::singleline(&mut self.device_name)
                .hint_text("This computer's name")
                .desired_width(260.0),
        );
        if name.lost_focus() {
            self.commit_device_name(ctx);
        }
        ui.add_space(8.0);

        ui.label("Port");
        let port = ui.add(
            egui::TextEdit::singleline(&mut self.port_text)
                .hint_text(format!("{} (current)", ctx.resolved_port))
                .desired_width(100.0),
        );
        if !self.port_text.trim().is_empty() && parse_port(self.port_text.trim()).is_none() {
            ui.colored_label(ERROR_RED, "Not a valid port (1–65535)");
        }
        if port.lost_focus() {
            self.commit_port(ctx);
        }
        if self.restart_needed {
            // RESEARCH Open Q3: restart-required — the listener and beacon
            // bind once at startup; no live re-bind.
            ui.colored_label(ACCENT_BLUE, "Restart Remote Control to apply.");
        }
        ui.add_space(10.0);

        // Clipboard sync (RESEARCH Open Q5): the AtomicBool is the LIVE gate
        // the clip thread's auto-sync push reads — flipping it applies
        // immediately; the config write makes it stick across restarts.
        let mut clip = ctx.clip_sync.load(Ordering::Relaxed);
        if ui
            .checkbox(&mut clip, "Clipboard sync (send PC clipboard to phone)")
            .changed()
        {
            ctx.clip_sync.store(clip, Ordering::Relaxed);
            ctx.config
                .lock()
                .expect("settings mutex poisoned (clipboard toggle)")
                .clipboard_sync = clip;
            persist(ctx);
        }

        // Autostart (SRV-02): HKCU-only Run entry via crate::autostart —
        // reflects/drives autostart::is_enabled/enable/disable (T-07-32:
        // per-user, no admin, absolute exe path, visible + togglable here).
        if ui
            .checkbox(&mut self.autostart_enabled, "Start with Windows (this user)")
            .changed()
        {
            let result = if self.autostart_enabled {
                autostart::enable()
            } else {
                autostart::disable()
            };
            match result {
                Ok(()) => {
                    self.autostart_error = false;
                    ctx.config
                        .lock()
                        .expect("settings mutex poisoned (autostart toggle)")
                        .autostart = self.autostart_enabled;
                    persist(ctx);
                }
                Err(e) => {
                    // Degrade-never-panic: reflect the registry truth and
                    // surface an inline warning; the toggle stays usable.
                    tracing::warn!(error = %e, "autostart toggle failed");
                    self.autostart_enabled = autostart::is_enabled();
                    self.autostart_error = true;
                }
            }
        }
        if self.autostart_error {
            ui.colored_label(ERROR_RED, "Couldn't update the Windows startup entry.");
        }
    }

    /// D-04/D-05/D-02: the paired-device list with per-row Revoke + the
    /// on-demand "Pair new device" action. Names render ONLY here — the
    /// local operator's screen; the tray tooltip stays count-only (T-07-33).
    fn render_paired_devices(&mut self, ctx: &ShellCtx, ui: &mut egui::Ui) {
        ui.add_space(12.0);
        ui.separator();
        ui.add_space(6.0);
        ui.heading("Paired devices");
        ui.add_space(6.0);

        // Clone the records so the auth lock is NOT held while rendering —
        // revoke_device below re-takes it.
        let records = ctx
            .auth
            .lock()
            .expect("auth mutex poisoned rendering the paired list")
            .paired_records()
            .to_vec();

        if records.is_empty() {
            ui.weak("No phones paired yet.");
        }
        for device in &records {
            ui.horizontal(|ui| {
                ui.label(&device.name);
                ui.weak(paired_ago(device.paired_at));
                ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                    if ui.button("Revoke").clicked() {
                        // D-05 (T-07-31): crate::revoke_device =
                        // AuthManager::revoke via the ShellCtx auth Arc
                        // (drops the stored hash + bumps auth.changes() →
                        // the 07-07 config re-save) AND revoke_tx.send_modify
                        // (advances the revocation epoch → the 07-05 select!
                        // branch force-disconnects the live session; the
                        // phone re-pairs with kRevokedExplanation).
                        crate::revoke_device(&ctx.auth, &ctx.revoke_tx, &device.hash);
                    }
                });
            });
        }

        ui.add_space(8.0);
        if ui.button("Pair new device").clicked() {
            // D-02 on demand: crate::begin_on_demand_pairing =
            // AuthManager::begin_pairing via the ShellCtx auth Arc (a fresh
            // 60s PIN window — works with devices already paired, D-04
            // multi-phone) + notify::notify_pin (toast + console, never
            // tracing).
            crate::begin_on_demand_pairing(&ctx.auth);
        }
    }

    /// Commit the device-name buffer to the shared settings + config file
    /// (empty/whitespace = clear the override, back to `COMPUTERNAME`).
    fn commit_device_name(&mut self, ctx: &ShellCtx) {
        let trimmed = self.device_name.trim();
        let value = if trimmed.is_empty() {
            None
        } else {
            Some(trimmed.to_owned())
        };
        let mut shared = ctx
            .config
            .lock()
            .expect("settings mutex poisoned (device name)");
        if shared.device_name != value {
            shared.device_name = value;
            drop(shared);
            // The beacon identity binds the name once at startup — same
            // restart-to-apply story as the port (Open Q3).
            self.restart_needed = true;
            persist(ctx);
        }
    }

    /// Commit the port buffer (empty = clear back to the default; an invalid
    /// value is NEVER written — the inline error already shows).
    fn commit_port(&mut self, ctx: &ShellCtx) {
        let trimmed = self.port_text.trim();
        let value = if trimmed.is_empty() {
            None
        } else {
            match parse_port(trimmed) {
                Some(p) => Some(p),
                None => return,
            }
        };
        let mut shared = ctx.config.lock().expect("settings mutex poisoned (port)");
        if shared.port != value {
            shared.port = value;
            drop(shared);
            // Open Q3: restart-required — no live re-bind.
            self.restart_needed = true;
            persist(ctx);
        }
    }
}

/// Strict settings-side port parse: an integer in `1..=65535` (port 0 is not
/// a usable listen port — same rule as config.rs's lenient loader).
fn parse_port(text: &str) -> Option<u16> {
    text.parse::<u16>().ok().filter(|p| *p != 0)
}

/// Human "paired N days ago" for the device list (D-04).
fn paired_ago(paired_at: u64) -> String {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    match now.saturating_sub(paired_at) / 86_400 {
        0 => "paired today".to_owned(),
        1 => "paired yesterday".to_owned(),
        n => format!("paired {n} days ago"),
    }
}

/// Serialize the CURRENT shared settings + live auth records to config.toml
/// — the settings window's write path through the 07-07 config module. The
/// paired records come from the auth store (single source of truth), so a
/// settings save can never drop a pairing that landed mid-edit.
fn persist(ctx: &ShellCtx) {
    let s = ctx
        .config
        .lock()
        .expect("settings mutex poisoned during save")
        .clone();
    let records = ctx
        .auth
        .lock()
        .expect("auth mutex poisoned during settings save")
        .paired_records()
        .to_vec();
    let cfg = config::from_auth(&records, s.device_name, s.port, s.autostart, s.clipboard_sync);
    config::save(&cfg);
}

#[cfg(test)]
mod tests {
    use super::{paired_ago, parse_port};

    /// The settings-side port validation: numeric, in-range, never 0.
    #[test]
    fn settings_port_parse_accepts_valid_rejects_garbage() {
        assert_eq!(parse_port("17777"), Some(17777));
        assert_eq!(parse_port("1"), Some(1));
        assert_eq!(parse_port("65535"), Some(65535));
        assert_eq!(parse_port("0"), None, "port 0 is not a usable listen port");
        assert_eq!(parse_port("65536"), None, "out of u16 range");
        assert_eq!(parse_port("-1"), None);
        assert_eq!(parse_port("abc"), None);
        assert_eq!(parse_port(""), None);
    }

    /// Human paired-at formatting for the device list.
    #[test]
    fn settings_paired_ago_is_humane() {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_secs();
        assert_eq!(paired_ago(now), "paired today");
        assert_eq!(paired_ago(now - 90_000), "paired yesterday");
        assert_eq!(paired_ago(now - 86_400 * 12), "paired 12 days ago");
        // A future timestamp (clock skew) saturates to "today", never panics.
        assert_eq!(paired_ago(now + 86_400), "paired today");
    }
}
