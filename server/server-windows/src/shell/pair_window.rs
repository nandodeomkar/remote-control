//! Pair-new-device window (Phase 10 handoff panel 1c): the 6-digit PIN in
//! digit boxes, a live expiry countdown, an OR-SCAN divider and a real QR
//! code of the pairing payload — replacing the toast as the primary pairing
//! surface (the toast still fires for tray-initiated pairing).
//!
//! Opening the window begins a fresh 60s pairing window (same
//! `crate::begin_on_demand_pairing` path as the tray/settings actions, D-02).
//! When the countdown hits zero a "New PIN" action re-begins pairing.

use std::time::Instant;

use qrcode::QrCode;
use winit::dpi::LogicalSize;
use winit::event_loop::{ActiveEventLoop, EventLoopProxy};
use winit::window::{Window, WindowId};

use server_core::auth::pin::PIN_TTL_SECS;

use super::chrome::{self, ShellAction};
use super::glwin::GlWindow;
use super::style::{self, icon};
use super::{ShellCtx, UserEvent};

/// Logical inner size (handoff: 392px wide dialog).
const SIZE: (f64, f64) = (392.0, 560.0);

pub struct PairWindow {
    gl: GlWindow,
    /// The active PIN's digits (ASCII, 6 chars).
    pin: String,
    /// When the current PIN was issued (countdown baseline).
    issued_at: Instant,
    /// Pre-rendered QR module matrix (true = dark) + side length.
    qr: Option<(Vec<bool>, usize)>,
    ip_text: String,
}

impl PairWindow {
    pub fn new(
        event_loop: &ActiveEventLoop,
        ctx: &ShellCtx,
        proxy: EventLoopProxy<UserEvent>,
    ) -> anyhow::Result<Self> {
        let attrs = Window::default_attributes()
            .with_title("Pair a new phone")
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

        let mut this = Self {
            gl,
            pin: String::new(),
            issued_at: Instant::now(),
            qr: None,
            ip_text,
        };
        this.begin_pairing(ctx);
        Ok(this)
    }

    /// Start (or restart) a pairing window and rebuild the QR payload.
    fn begin_pairing(&mut self, ctx: &ShellCtx) {
        self.pin = crate::begin_on_demand_pairing(&ctx.auth);
        self.issued_at = Instant::now();
        // Payload the phone app can parse: host + port + pin. The PIN is
        // already shown on this same screen, so encoding it adds no exposure
        // beyond what the operator's display already reveals.
        let payload = format!(
            "rc://pair?host={}&port={}&pin={}",
            self.ip_text, ctx.resolved_port, self.pin
        );
        self.qr = QrCode::new(payload.as_bytes())
            .map(|code| {
                let w = code.width();
                let modules: Vec<bool> = code
                    .to_colors()
                    .iter()
                    .map(|c| *c == qrcode::Color::Dark)
                    .collect();
                (modules, w)
            })
            .map_err(|e| tracing::warn!(error = %e, "QR encode failed"))
            .ok();
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
    pub fn destroy(&mut self) {
        self.gl.destroy();
    }

    pub fn redraw(&mut self, ctx: &ShellCtx) -> Vec<ShellAction> {
        let mut actions = Vec::new();
        let mut renew = false;
        let remaining = PIN_TTL_SECS.saturating_sub(self.issued_at.elapsed().as_secs());
        let pin = self.pin.clone();
        let qr = self.qr.clone();
        let ip_text = self.ip_text.clone();
        let device = device_name(ctx);
        let port = ctx.resolved_port;
        self.gl.redraw(style::BG_CLEAR, |window, ui| {
            if let Some(a) = chrome::title_bar(ui, window, "Pair a new phone", false) {
                actions.push(a);
            }
            // Tick the countdown once a second while the window is open.
            ui.ctx().request_repaint_after(std::time::Duration::from_millis(250));

            egui::Frame::new()
                .inner_margin(egui::Margin {
                    left: 28,
                    right: 28,
                    top: 26,
                    bottom: 28,
                })
                .show(ui, |ui| {
                    ui.vertical_centered(|ui| {
                        style::section_label(ui, "ENTER THIS PIN ON YOUR PHONE");
                        ui.add_space(18.0);
                        pin_boxes(ui, &pin);
                        ui.add_space(14.0);

                        if remaining > 0 {
                            ui.horizontal(|ui| {
                                center_pad(ui, 118.0);
                                ui.spacing_mut().item_spacing.x = 8.0;
                                ui.label(style::icon_rt(icon::SCHEDULE, 16.0, style::AMBER));
                                ui.label(
                                    egui::RichText::new(format!("Expires in {remaining}s"))
                                        .font(style::mono(12.0))
                                        .color(style::AMBER),
                                );
                            });
                        } else if new_pin_button(ui).clicked() {
                            renew = true;
                        }

                        ui.add_space(22.0);
                        or_scan_divider(ui);
                        ui.add_space(22.0);
                        qr_box(ui, qr.as_ref(), remaining > 0);

                        ui.add_space(20.0);
                        ui.label(
                            egui::RichText::new(
                                "Open Remote Control on your phone, tap Add PC, then \
                                 enter the PIN or scan the code.",
                            )
                            .font(style::sg(12.5))
                            .color(style::MUTED),
                        );
                        ui.add_space(10.0);
                        ui.label(
                            egui::RichText::new(format!("{device} · {ip_text}:{port}"))
                                .font(style::mono(11.0))
                                .color(style::MUTED_2),
                        );
                    });
                });
        });
        if renew {
            self.begin_pairing(ctx);
        }
        actions
    }
}

/// The six 42×56 digit boxes.
fn pin_boxes(ui: &mut egui::Ui, pin: &str) {
    ui.horizontal(|ui| {
        // Center the 6-box strip: 6*42 + 5*9 = 297; pad = (width-297)/2.
        let pad = ((ui.available_width() - 297.0) / 2.0).max(0.0);
        ui.add_space(pad);
        ui.spacing_mut().item_spacing.x = 9.0;
        for i in 0..6 {
            let ch = pin.chars().nth(i).unwrap_or('·');
            let (rect, _) =
                ui.allocate_exact_size(egui::vec2(42.0, 56.0), egui::Sense::hover());
            let p = ui.painter();
            p.rect_filled(rect, egui::CornerRadius::same(10), style::SURFACE);
            p.rect_stroke(
                rect,
                egui::CornerRadius::same(10),
                egui::Stroke::new(1.0, style::BORDER),
                egui::StrokeKind::Inside,
            );
            p.text(
                rect.center(),
                egui::Align2::CENTER_CENTER,
                ch,
                style::mono_sb(28.0),
                style::TEXT,
            );
        }
    });
}

/// Pad the horizontal cursor so following inline content sits centered.
fn center_pad(ui: &mut egui::Ui, content_w: f32) {
    let pad = ((ui.available_width() - content_w) / 2.0).max(0.0);
    ui.add_space(pad);
}

/// Accent "Generate new PIN" action shown once the window expires.
fn new_pin_button(ui: &mut egui::Ui) -> egui::Response {
    let w = 168.0;
    ui.horizontal(|ui| {
        center_pad(ui, w);
        let (rect, resp) = ui.allocate_exact_size(egui::vec2(w, 36.0), egui::Sense::click());
        let p = ui.painter();
        let fill = if resp.hovered() {
            style::ACCENT_DEEP
        } else {
            style::ACCENT
        };
        p.rect_filled(rect, egui::CornerRadius::same(10), fill);
        p.text(
            rect.center(),
            egui::Align2::CENTER_CENTER,
            "Generate new PIN",
            style::sg_sb(13.5),
            style::ACCENT_INK,
        );
        resp
    })
    .inner
}

/// `──── OR SCAN ────` divider.
fn or_scan_divider(ui: &mut egui::Ui) {
    ui.horizontal(|ui| {
        ui.spacing_mut().item_spacing.x = 14.0;
        let side = (ui.available_width() - 14.0 * 2.0 - 70.0) / 2.0;
        let (l, _) = ui.allocate_exact_size(egui::vec2(side, 1.0), egui::Sense::hover());
        ui.painter()
            .rect_filled(l, egui::CornerRadius::ZERO, style::BORDER_SOFT);
        ui.label(
            egui::RichText::new("OR SCAN")
                .font(style::mono(10.0))
                .color(style::FAINT),
        );
        let (r, _) = ui.allocate_exact_size(egui::vec2(side, 1.0), egui::Sense::hover());
        ui.painter()
            .rect_filled(r, egui::CornerRadius::ZERO, style::BORDER_SOFT);
    });
}

/// The 132px QR tile: real modules while the PIN is live, a muted "expired"
/// state once it isn't (a stale QR must not look scannable).
fn qr_box(ui: &mut egui::Ui, qr: Option<&(Vec<bool>, usize)>, live: bool) {
    let tile = 132.0;
    ui.horizontal(|ui| {
        center_pad(ui, tile);
        let (rect, _) = ui.allocate_exact_size(egui::vec2(tile, tile), egui::Sense::hover());
        let p = ui.painter();
        p.rect_filled(rect, egui::CornerRadius::same(12), style::BG_CHROME);
        p.rect_stroke(
            rect,
            egui::CornerRadius::same(12),
            egui::Stroke::new(1.0, style::BORDER),
            egui::StrokeKind::Inside,
        );
        match qr {
            Some((modules, w)) if live && *w > 0 => {
                // Quiet zone: 8px inset; module size fits the remaining tile.
                let inner = rect.shrink(8.0);
                let cell = inner.width() / *w as f32;
                for y in 0..*w {
                    for x in 0..*w {
                        if modules[y * w + x] {
                            let r = egui::Rect::from_min_size(
                                egui::pos2(
                                    inner.left() + x as f32 * cell,
                                    inner.top() + y as f32 * cell,
                                ),
                                egui::vec2(cell + 0.5, cell + 0.5),
                            );
                            p.rect_filled(r, egui::CornerRadius::ZERO, style::TEXT);
                        }
                    }
                }
            }
            _ => {
                p.text(
                    rect.center(),
                    egui::Align2::CENTER_CENTER,
                    if live { "QR CODE" } else { "EXPIRED" },
                    style::mono(10.0),
                    style::FAINT,
                );
            }
        }
    });
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
