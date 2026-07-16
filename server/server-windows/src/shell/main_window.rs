//! The main dashboard window (Phase 10 handoff panel 1a): host status hero
//! card, live connected-device section, paired-device management, status
//! footer. On-demand like every shell window — the app stays tray-first.
//!
//! Data honesty: the shell only has the connected COUNT (`ShellCtx::
//! conn_count`) — per-session names/latency are not plumbed out of
//! server-core — so "connected now" renders count-based rows without
//! invented latency numbers or per-session disconnect buttons.

use winit::dpi::LogicalSize;
use winit::event_loop::{ActiveEventLoop, EventLoopProxy};
use winit::window::{Window, WindowId};

use super::chrome::{self, ShellAction};
use super::glwin::GlWindow;
use super::style::{self, icon};
use super::{ShellCtx, UserEvent};

/// Logical inner size of the dashboard (handoff: 760px wide shell).
const SIZE: (f64, f64) = (760.0, 560.0);

pub struct MainWindow {
    gl: GlWindow,
    /// LAN IP resolved once at open (display-only).
    ip_text: String,
}

impl MainWindow {
    pub fn new(
        event_loop: &ActiveEventLoop,
        proxy: EventLoopProxy<UserEvent>,
    ) -> anyhow::Result<Self> {
        let attrs = Window::default_attributes()
            .with_title("Remote Control")
            .with_inner_size(LogicalSize::new(SIZE.0, SIZE.1))
            .with_resizable(false)
            .with_decorations(false);
        let gl = GlWindow::new(event_loop, attrs, proxy)?;
        chrome::round_corners(gl.window());
        gl.show();
        gl.request_redraw();
        let ip_text = style::local_ip()
            .map(|ip| ip.to_string())
            .unwrap_or_else(|| "no network".to_string());
        Ok(Self { gl, ip_text })
    }

    pub fn window_id(&self) -> WindowId {
        self.gl.window_id()
    }
    pub fn focus(&self) {
        self.gl.focus();
    }
    pub fn request_redraw(&self) {
        self.gl.request_redraw();
    }
    pub fn resize(&self, size: winit::dpi::PhysicalSize<u32>) {
        self.gl.resize(size);
    }
    pub fn on_window_event(&mut self, event: &winit::event::WindowEvent) -> bool {
        self.gl.on_window_event(event)
    }
    pub fn minimize(&self) {
        self.gl.window().set_minimized(true);
    }
    pub fn destroy(&mut self) {
        self.gl.destroy();
    }

    /// One frame; returns the actions the shell should execute.
    pub fn redraw(&mut self, ctx: &ShellCtx, paused: bool) -> Vec<ShellAction> {
        let mut actions = Vec::new();
        let ip_text = self.ip_text.clone();
        self.gl.redraw(style::BG_CLEAR, |window, ui| {
            render(ui, window, ctx, paused, &ip_text, &mut actions);
        });
        actions
    }
}

fn render(
    ui: &mut egui::Ui,
    window: &Window,
    ctx: &ShellCtx,
    paused: bool,
    ip_text: &str,
    actions: &mut Vec<ShellAction>,
) {
    if let Some(a) = chrome::title_bar(ui, window, "Remote Control", true) {
        actions.push(a);
    }

    let conn = *ctx.conn_count.borrow();
    let footer_h = 38.0;
    let body_h = ui.available_height() - footer_h;

    ui.allocate_ui(egui::vec2(ui.available_width(), body_h), |ui| {
        egui::Frame::new()
            .inner_margin(egui::Margin {
                left: 22,
                right: 22,
                top: 22,
                bottom: 16,
            })
            .show(ui, |ui| {
                egui::ScrollArea::vertical()
                    .auto_shrink([false; 2])
                    .show(ui, |ui| {
                        hero_card(ui, ctx, paused, ip_text, actions);
                        ui.add_space(24.0);
                        style::section_label(ui, "CONNECTED NOW");
                        ui.add_space(12.0);
                        connected_now(ui, conn, paused);
                        ui.add_space(22.0);
                        style::section_label(ui, "PAIRED DEVICES");
                        ui.add_space(12.0);
                        paired_devices(ui, ctx, actions);
                    });
            });
    });

    footer(ui, paused, actions);
}

/// The hero status card: icon chip + status/name/address column + the
/// Pause and Pair actions.
fn hero_card(
    ui: &mut egui::Ui,
    ctx: &ShellCtx,
    paused: bool,
    ip_text: &str,
    actions: &mut Vec<ShellAction>,
) {
    style::card(style::SURFACE_HERO, style::BORDER, 18, 0)
        .inner_margin(egui::Margin::symmetric(22, 20))
        .show(ui, |ui| {
            ui.horizontal(|ui| {
                ui.spacing_mut().item_spacing.x = 20.0;

                // 52px accent icon chip.
                let (chip, _) =
                    ui.allocate_exact_size(egui::vec2(52.0, 52.0), egui::Sense::hover());
                let p = ui.painter();
                p.rect_filled(chip, egui::CornerRadius::same(15), style::ACCENT_TINT);
                p.rect_stroke(
                    chip,
                    egui::CornerRadius::same(15),
                    egui::Stroke::new(1.0, style::ACCENT_TINT_BORDER),
                    egui::StrokeKind::Inside,
                );
                p.text(
                    chip.center(),
                    egui::Align2::CENTER_CENTER,
                    if paused { icon::PAUSE } else { icon::SENSORS },
                    style::icons(28.0),
                    style::ACCENT,
                );

                // Status column.
                ui.vertical(|ui| {
                    ui.spacing_mut().item_spacing.y = 7.0;
                    ui.horizontal(|ui| {
                        ui.spacing_mut().item_spacing.x = 8.0;
                        let (dot_color, label) = if paused {
                            (style::MUTED_2, "PAUSED")
                        } else {
                            (style::ACCENT, "LISTENING")
                        };
                        style::status_dot(ui, dot_color, 9.0);
                        ui.label(style::tracked(label, style::mono_sb(11.0), dot_color, 1.8));
                    });
                    ui.label(
                        egui::RichText::new(device_name(ctx))
                            .font(style::sg_sb(22.0))
                            .color(style::TEXT),
                    );
                    ui.label(
                        egui::RichText::new(format!(
                            "{ip_text} : {} · Wi-Fi",
                            ctx.resolved_port
                        ))
                        .font(style::mono(12.5))
                        .color(style::MUTED),
                    );
                });

                // Right-aligned actions.
                ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                    ui.spacing_mut().item_spacing.x = 10.0;
                    if accent_button(ui, icon::ADD, "Pair new device").clicked() {
                        actions.push(ShellAction::OpenPair);
                    }
                    let (glyph, label) = if paused {
                        (icon::PLAY, "Resume")
                    } else {
                        (icon::PAUSE, "Pause")
                    };
                    if ghost_button(ui, glyph, label).clicked() {
                        actions.push(ShellAction::TogglePause);
                    }
                });
            });
        });
}

/// Count-based connected section (no per-session identity is plumbed to the
/// shell — see module docs).
fn connected_now(ui: &mut egui::Ui, conn: usize, paused: bool) {
    style::card(style::SURFACE, style::BORDER, 14, 0)
        .inner_margin(egui::Margin::symmetric(16, 14))
        .show(ui, |ui| {
            ui.horizontal(|ui| {
                ui.spacing_mut().item_spacing.x = 14.0;
                // 40px avatar tile.
                let (tile, _) =
                    ui.allocate_exact_size(egui::vec2(40.0, 40.0), egui::Sense::hover());
                ui.painter()
                    .rect_filled(tile, egui::CornerRadius::same(11), style::SURFACE_2);
                ui.painter().text(
                    tile.center(),
                    egui::Align2::CENTER_CENTER,
                    icon::SMARTPHONE,
                    style::icons(22.0),
                    style::TEXT_ICON,
                );
                ui.vertical(|ui| {
                    ui.spacing_mut().item_spacing.y = 3.0;
                    let (title, sub) = match (conn, paused) {
                        (0, _) => (
                            "No device connected".to_string(),
                            "waiting for your phone".to_string(),
                        ),
                        (n, true) => (
                            connected_title(n),
                            "input paused — connection stays alive".to_string(),
                        ),
                        (n, false) => (connected_title(n), "streaming input".to_string()),
                    };
                    ui.label(
                        egui::RichText::new(title)
                            .font(style::sg_sb(15.0))
                            .color(style::TEXT),
                    );
                    ui.label(
                        egui::RichText::new(sub)
                            .font(style::sg(12.5))
                            .color(style::MUTED_2),
                    );
                });
                if conn > 0 {
                    ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                        style::pill_badge(
                            ui,
                            "LIVE",
                            style::ACCENT,
                            style::BG_APP,
                            style::BORDER,
                        );
                    });
                }
            });
        });
}

fn connected_title(n: usize) -> String {
    if n == 1 {
        "1 device connected".to_string()
    } else {
        format!("{n} devices connected")
    }
}

/// Paired-device management card (same rows as settings — one source of
/// truth for the row painting in `style`).
fn paired_devices(ui: &mut egui::Ui, ctx: &ShellCtx, actions: &mut Vec<ShellAction>) {
    let records = ctx
        .auth
        .lock()
        .expect("auth mutex poisoned rendering the paired list")
        .paired_records()
        .to_vec();

    style::card(style::SURFACE, style::BORDER, 14, 0).show(ui, |ui| {
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
            style::device_row(ui, &device.name, &paired_ago(device.paired_at), true, || {
                crate::revoke_device(&ctx.auth, &ctx.revoke_tx, &device.hash);
            });
            style::hairline(ui, style::BORDER_SOFT);
        }
        if style::pair_row(ui).clicked() {
            actions.push(ShellAction::OpenPair);
        }
    });
}

/// The 38px status-bar footer: run state + a Settings action.
fn footer(ui: &mut egui::Ui, paused: bool, actions: &mut Vec<ShellAction>) {
    let (rect, _) = ui.allocate_exact_size(
        egui::vec2(ui.available_width(), ui.available_height().max(38.0)),
        egui::Sense::hover(),
    );
    let p = ui.painter();
    p.rect_filled(rect, egui::CornerRadius::ZERO, style::BG_CHROME);
    p.line_segment(
        [rect.left_top(), rect.right_top()],
        egui::Stroke::new(1.0, style::HAIRLINE),
    );
    let cy = rect.center().y;
    let (dot, text) = if paused {
        (style::MUTED_2, "Paused · protocol 1.1")
    } else {
        (style::ACCENT, "Running · protocol 1.1")
    };
    p.circle_filled(egui::pos2(rect.left() + 20.0, cy), 3.5, dot);
    p.text(
        egui::pos2(rect.left() + 32.0, cy),
        egui::Align2::LEFT_CENTER,
        text,
        style::mono(11.0),
        style::MUTED_2,
    );

    // Right-aligned Settings action.
    let hit = egui::Rect::from_min_max(
        egui::pos2(rect.right() - 110.0, rect.top()),
        rect.max,
    );
    let resp = ui.interact(hit, ui.id().with("footer_settings"), egui::Sense::click());
    let color = if resp.hovered() {
        style::TEXT
    } else {
        style::MUTED
    };
    p.text(
        egui::pos2(rect.right() - 78.0, cy),
        egui::Align2::LEFT_CENTER,
        "Settings",
        style::sg(12.5),
        color,
    );
    p.text(
        egui::pos2(rect.right() - 96.0, cy),
        egui::Align2::LEFT_CENTER,
        icon::SETTINGS,
        style::icons(17.0),
        color,
    );
    if resp.clicked() {
        actions.push(ShellAction::OpenSettings);
    }
}

/// Accent (filled) button: icon + label on the accent fill, ink text.
fn accent_button(ui: &mut egui::Ui, glyph: char, label: &str) -> egui::Response {
    pill_button(ui, glyph, label, style::ACCENT, style::ACCENT_INK, None)
}

/// Ghost (outlined) button on the card surface.
fn ghost_button(ui: &mut egui::Ui, glyph: char, label: &str) -> egui::Response {
    pill_button(
        ui,
        glyph,
        label,
        style::SURFACE,
        style::TEXT,
        Some(style::BORDER),
    )
}

fn pill_button(
    ui: &mut egui::Ui,
    glyph: char,
    label: &str,
    fill: egui::Color32,
    fg: egui::Color32,
    border: Option<egui::Color32>,
) -> egui::Response {
    let text_w = 8.0 * label.len() as f32; // Space Grotesk ~8px/char at 14
    let w = 16.0 + 19.0 + 8.0 + text_w + 16.0;
    let (rect, resp) = ui.allocate_exact_size(egui::vec2(w, 40.0), egui::Sense::click());
    let p = ui.painter();
    let fill = if resp.hovered() {
        style::lerp_color(fill, egui::Color32::WHITE, 0.06)
    } else {
        fill
    };
    p.rect_filled(rect, egui::CornerRadius::same(10), fill);
    if let Some(b) = border {
        p.rect_stroke(
            rect,
            egui::CornerRadius::same(10),
            egui::Stroke::new(1.0, b),
            egui::StrokeKind::Inside,
        );
    }
    p.text(
        egui::pos2(rect.left() + 15.0, rect.center().y),
        egui::Align2::LEFT_CENTER,
        glyph,
        style::icons(19.0),
        fg,
    );
    p.text(
        egui::pos2(rect.left() + 15.0 + 19.0 + 8.0, rect.center().y),
        egui::Align2::LEFT_CENTER,
        label,
        style::sg_sb(14.0),
        fg,
    );
    resp
}

/// Resolved device name: config override, else `COMPUTERNAME`.
fn device_name(ctx: &ShellCtx) -> String {
    ctx.config
        .lock()
        .expect("settings mutex poisoned reading device name")
        .device_name
        .clone()
        .unwrap_or_else(|| std::env::var("COMPUTERNAME").unwrap_or_else(|_| "This PC".into()))
}

/// Human "paired N days ago" (same rule as the settings window).
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
