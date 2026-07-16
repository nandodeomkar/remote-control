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

use std::sync::atomic::Ordering;

use winit::dpi::LogicalSize;
use winit::event_loop::{ActiveEventLoop, EventLoopProxy};
use winit::window::{Window, WindowId};

use super::chrome::{self, ShellAction};
use super::glwin::GlWindow;
use super::style::{self, icon};
use super::{ShellCtx, UserEvent};
use crate::firewall::FirewallStatus;
use crate::{autostart, config};

/// The on-demand settings window: a [`GlWindow`] (winit + glutin + egui)
/// plus the immediate-mode edit state.
pub struct SettingsWindow {
    gl: GlWindow,
    ui: UiState,
}

impl SettingsWindow {
    /// Build the window ON the shell loop (must be called from the shell
    /// thread with its `ActiveEventLoop`). Every fallible step surfaces as
    /// `anyhow::Error` so the caller can log-and-continue — a failed
    /// settings window must never kill the tray.
    pub fn new(
        event_loop: &ActiveEventLoop,
        ctx: &ShellCtx,
        proxy: EventLoopProxy<UserEvent>,
    ) -> anyhow::Result<Self> {
        let attrs = Window::default_attributes()
            .with_title("Remote Control — Settings")
            .with_inner_size(LogicalSize::new(440.0, 560.0))
            .with_resizable(false)
            .with_decorations(false);
        let gl = GlWindow::new(event_loop, attrs, proxy)?;
        chrome::round_corners(gl.window());
        gl.show();
        gl.request_redraw();

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
        Ok(Self { gl, ui })
    }

    /// The winit id — the shell loop routes `WindowEvent`s by it.
    pub fn window_id(&self) -> WindowId {
        self.gl.window_id()
    }

    /// Bring an already-open window to the front (second Settings click).
    pub fn focus(&self) {
        self.gl.focus();
    }

    /// Ask the OS for a redraw (egui repaint scheduling).
    pub fn request_redraw(&self) {
        self.gl.request_redraw();
    }

    /// Resize the GL surface with the window.
    pub fn resize(&self, size: winit::dpi::PhysicalSize<u32>) {
        self.gl.resize(size);
    }

    /// Forward a window event to egui; returns whether egui wants a repaint.
    pub fn on_window_event(&mut self, event: &winit::event::WindowEvent) -> bool {
        self.gl.on_window_event(event)
    }

    /// Run one egui frame + paint + swap (the `RedrawRequested` handler).
    pub fn redraw(&mut self, ctx: &ShellCtx) -> Vec<ShellAction> {
        let mut actions = Vec::new();
        let ui_state = &mut self.ui;
        self.gl.redraw(style::BG_CLEAR, |window, ui| {
            if let Some(a) = chrome::title_bar(ui, window, "Remote Control — Settings", false) {
                actions.push(a);
            }
            ui_state.render(ctx, ui);
        });
        actions
    }

    /// Commit any in-progress text edits (called on window close so a typed
    /// device name / port is never lost to a missing lost-focus event).
    pub fn commit_pending(&mut self, ctx: &ShellCtx) {
        self.ui.commit_device_name(ctx);
        self.ui.commit_port(ctx);
    }

    /// Release GPU resources (called right before the window is dropped).
    pub fn destroy(&mut self) {
        self.gl.destroy();
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
    /// the autostart toggle, the paired-device list, and the firewall hint —
    /// restyled to the Phase 10 handoff (panel 1d).
    fn render(&mut self, ctx: &ShellCtx, ui: &mut egui::Ui) {
        egui::Frame::new()
            .inner_margin(egui::Margin::symmetric(22, 20))
            .show(ui, |ui| {
                egui::ScrollArea::vertical()
                    .auto_shrink([false; 2])
                    .show(ui, |ui| {
                        self.render_firewall_hint(ctx, ui);
                        style::section_label(ui, "GENERAL");
                        ui.add_space(12.0);
                        self.render_general(ctx, ui);
                        ui.add_space(22.0);
                        style::section_label(ui, "PAIRED DEVICES");
                        ui.add_space(12.0);
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
        let (title, body, accent, fill, border) = match ctx.firewall_status {
            FirewallStatus::BlockedNoRule => (
                format!("Firewall is blocking TCP {port}"),
                "Your phone can't connect. Allow Remote Control through Windows Firewall."
                    .to_string(),
                style::RED,
                style::RED_TINT,
                style::RED_TINT_BORDER,
            ),
            _ => (
                format!("Couldn't confirm the firewall allows TCP {port}"),
                "If your phone can't connect, allow Remote Control through Windows Firewall."
                    .to_string(),
                style::AMBER,
                style::SURFACE,
                style::BORDER,
            ),
        };
        style::card(fill, border, 14, 14).show(ui, |ui| {
            ui.horizontal_top(|ui| {
                ui.spacing_mut().item_spacing.x = 12.0;
                style::status_dot(ui, accent, 14.0);
                ui.vertical(|ui| {
                    ui.spacing_mut().item_spacing.y = 4.0;
                    ui.label(egui::RichText::new(title).font(style::sg_sb(14.0)).color(accent));
                    ui.label(
                        egui::RichText::new(body)
                            .font(style::sg(12.0))
                            .color(style::MUTED),
                    );
                });
            });
        });
        ui.add_space(16.0);
    }

    /// Device name / port / clipboard-sync / autostart (SRV-03 + SRV-02).
    fn render_general(&mut self, ctx: &ShellCtx, ui: &mut egui::Ui) {
        // Device name.
        field_label(ui, "Device name", Some("(shown on your phone)"));
        ui.add_space(7.0);
        let name = ui.add(
            egui::TextEdit::singleline(&mut self.device_name)
                .hint_text("This computer's name")
                .font(style::sg(14.0))
                .margin(egui::Margin::symmetric(13, 12))
                .desired_width(f32::INFINITY),
        );
        if name.lost_focus() {
            self.commit_device_name(ctx);
        }
        ui.add_space(16.0);

        // Port + restart hint.
        field_label(ui, "Port", None);
        ui.add_space(7.0);
        ui.horizontal(|ui| {
            ui.spacing_mut().item_spacing.x = 12.0;
            let port = ui.add(
                egui::TextEdit::singleline(&mut self.port_text)
                    .hint_text(ctx.resolved_port.to_string())
                    .font(style::mono(14.0))
                    .margin(egui::Margin::symmetric(13, 12))
                    .desired_width(84.0),
            );
            if port.lost_focus() {
                self.commit_port(ctx);
            }
            ui.horizontal(|ui| {
                ui.spacing_mut().item_spacing.x = 6.0;
                ui.label(style::icon_rt(icon::INFO, 15.0, style::ACCENT));
                ui.label(
                    egui::RichText::new("Restart to apply")
                        .font(style::sg(12.0))
                        .color(style::ACCENT),
                );
            });
        });
        if !self.port_text.trim().is_empty() && parse_port(self.port_text.trim()).is_none() {
            ui.add_space(4.0);
            ui.label(
                egui::RichText::new("Not a valid port (1–65535)")
                    .font(style::sg(12.0))
                    .color(style::RED),
            );
        }
        ui.add_space(20.0);
        hairline(ui);
        ui.add_space(20.0);

        // Clipboard sync (RESEARCH Open Q5): the AtomicBool is the LIVE gate
        // the clip thread's auto-sync push reads — flipping it applies
        // immediately; the config write makes it stick across restarts.
        let mut clip = ctx.clip_sync.load(Ordering::Relaxed);
        if toggle_row(
            ui,
            "Clipboard sync",
            "Send this PC's clipboard to the phone",
            &mut clip,
        ) {
            ctx.clip_sync.store(clip, Ordering::Relaxed);
            ctx.config
                .lock()
                .expect("settings mutex poisoned (clipboard toggle)")
                .clipboard_sync = clip;
            persist(ctx);
        }
        ui.add_space(6.0);

        // Autostart (SRV-02): HKCU-only Run entry via crate::autostart.
        let mut auto = self.autostart_enabled;
        if toggle_row(
            ui,
            "Start with Windows",
            "Launch for this user at sign-in",
            &mut auto,
        ) {
            self.autostart_enabled = auto;
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
            ui.add_space(4.0);
            ui.label(
                egui::RichText::new("Couldn't update the Windows startup entry.")
                    .font(style::sg(12.0))
                    .color(style::RED),
            );
        }
    }

    /// D-04/D-05/D-02: the paired-device list with per-row Revoke + the
    /// on-demand "Pair new device" action. Names render ONLY here — the
    /// local operator's screen; the tray tooltip stays count-only (T-07-33).
    fn render_paired_devices(&mut self, ctx: &ShellCtx, ui: &mut egui::Ui) {
        // Clone the records so the auth lock is NOT held while rendering —
        // revoke_device below re-takes it.
        let records = ctx
            .auth
            .lock()
            .expect("auth mutex poisoned rendering the paired list")
            .paired_records()
            .to_vec();

        style::card(style::SURFACE, style::BORDER, 12, 0).show(ui, |ui| {
            ui.spacing_mut().item_spacing = egui::Vec2::ZERO;
            if records.is_empty() {
                ui.allocate_ui(egui::vec2(ui.available_width(), 50.0), |ui| {
                    ui.add_space(9.0);
                    ui.horizontal(|ui| {
                        ui.add_space(14.0);
                        ui.label(
                            egui::RichText::new("No phones paired yet.")
                                .font(style::sg(13.5))
                                .color(style::MUTED),
                        );
                    });
                });
            }
            for device in &records {
                device_row(
                    ui,
                    &device.name,
                    &paired_ago(device.paired_at),
                    true,
                    || {
                        // D-05 (T-07-31): crate::revoke_device drops the
                        // stored hash + advances the revocation epoch so the
                        // live session force-disconnects.
                        crate::revoke_device(&ctx.auth, &ctx.revoke_tx, &device.hash);
                    },
                );
                hairline_full(ui);
            }
            // "Pair new device" accent action row.
            let resp = pair_row(ui);
            if resp.clicked() {
                // D-02 on demand: a fresh 60s PIN window + toast.
                crate::begin_on_demand_pairing(&ctx.auth);
            }
        });
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

// ─────────────────────────────────────────────────────────────────────────
// Panel 1d row/field painting helpers (Phase 10 redesign)
// ─────────────────────────────────────────────────────────────────────────

/// A field caption: `Label (optional muted suffix)`.
fn field_label(ui: &mut egui::Ui, label: &str, sub: Option<&str>) {
    ui.horizontal(|ui| {
        ui.spacing_mut().item_spacing.x = 5.0;
        ui.label(
            egui::RichText::new(label)
                .font(style::sg(12.5))
                .color(style::MUTED),
        );
        if let Some(s) = sub {
            ui.label(
                egui::RichText::new(s)
                    .font(style::sg(12.5))
                    .color(style::MUTED_2),
            );
        }
    });
}

/// A 1px divider spanning the current available width.
fn hairline(ui: &mut egui::Ui) {
    style::hairline(ui, style::BORDER_SOFT);
}

/// A divider spanning the full width of the enclosing card (list rows).
fn hairline_full(ui: &mut egui::Ui) {
    hairline(ui);
}

/// A title + subtitle row with a right-aligned [`style::toggle`]. Returns
/// whether the toggle changed this frame.
fn toggle_row(ui: &mut egui::Ui, title: &str, sub: &str, on: &mut bool) -> bool {
    let mut changed = false;
    ui.allocate_ui(egui::vec2(ui.available_width(), 44.0), |ui| {
        ui.horizontal_centered(|ui| {
            ui.vertical(|ui| {
                ui.spacing_mut().item_spacing.y = 2.0;
                ui.label(
                    egui::RichText::new(title)
                        .font(style::sg_sb(14.5))
                        .color(style::TEXT),
                );
                ui.label(
                    egui::RichText::new(sub)
                        .font(style::sg(12.0))
                        .color(style::MUTED_2),
                );
            });
            ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                changed = style::toggle(ui, on).changed();
            });
        });
    });
    changed
}

use super::style::{device_row, pair_row};

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
