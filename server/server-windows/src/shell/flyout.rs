//! Custom tray flyout (Phase 10 handoff panel 1b): a borderless,
//! always-on-top panel that pops above the notification area on tray click,
//! replacing the OS-native muda context menu. Glass is approximated with an
//! opaque dark surface (egui cannot backdrop-blur — accepted tradeoff).
//!
//! Lifecycle: created on tray click, destroyed on focus loss / Esc / any
//! action. Positioned bottom-right of the primary work area (just above the
//! taskbar), like the Win11 quick-settings flyout.

use winit::dpi::{LogicalSize, PhysicalPosition, PhysicalSize};
use winit::event_loop::{ActiveEventLoop, EventLoopProxy};
use winit::platform::windows::WindowAttributesExtWindows as _;
use winit::window::{Window, WindowId, WindowLevel};

use super::chrome::ShellAction;
use super::glwin::GlWindow;
use super::style::{self, icon};
use super::{ShellCtx, UserEvent};

/// Gap between the flyout and the work-area edges (logical px).
const EDGE_GAP: f64 = 12.0;
/// Logical width (handoff: 344px wide flyout).
const WIDTH: f64 = 344.0;
/// Logical height at creation. Deliberately the *disconnected* height: the
/// common open then needs no correction, and only a connected open pays one
/// frame of catch-up.
const INITIAL_HEIGHT: f64 = 398.0;
/// Anti-oscillation tolerance for the content-driven resize (logical px).
/// The loop this guards is real, not hypothetical: at 125% scale a 458.0
/// logical request becomes 572.5 physical, rounds to 572 or 573, and reads
/// back as 457.6 or 458.4. Without the tolerance that 0.4px is a fresh resize
/// every frame, each resize forces a redraw, and the shell thread spins.
/// 1.5 sits far above that wobble and far below the ~60px signal.
const HEIGHT_EPSILON: f64 = 1.5;
/// Floor for the content-driven height (logical px).
const MIN_HEIGHT: f64 = 200.0;

/// The inner height to request, in logical px, for a frame that measured
/// `content_h` of content against a window currently `current_h` tall — or
/// `None` to leave the window alone.
fn next_height(content_h: f64, current_h: f64, max_h: f64) -> Option<f64> {
    // A frame that allocated nothing yields `Rect::NOTHING` (`max.y == -inf`),
    // and a NaN would sail straight through `clamp` into `request_inner_size`.
    if !content_h.is_finite() {
        return None;
    }
    // `max_h.max(MIN_HEIGHT)`, not `max_h`: `f64::clamp` panics when min > max,
    // and a tiny work area supplies exactly that.
    let target = content_h.clamp(MIN_HEIGHT, max_h.max(MIN_HEIGHT));
    ((target - current_h).abs() > HEIGHT_EPSILON).then_some(target)
}

/// Bottom-right anchor for a window of `size`, inset `gap` from the work
/// area's `right`/`bottom` edges. All physical px.
fn anchor_bottom_right(
    size: PhysicalSize<u32>,
    right: i32,
    bottom: i32,
    gap: i32,
) -> PhysicalPosition<i32> {
    PhysicalPosition::new(
        right - size.width as i32 - gap,
        bottom - size.height as i32 - gap,
    )
}

/// The primary work area's far edges and height, in physical px.
struct WorkArea {
    right: i32,
    bottom: i32,
    height: i32,
}

/// Read the primary work area (the desktop minus the taskbar). Falls back to
/// the current monitor when the work-area read fails.
fn work_area(window: &Window) -> Option<WorkArea> {
    use windows::Win32::Foundation::RECT;
    use windows::Win32::UI::WindowsAndMessaging::{
        SystemParametersInfoW, SPI_GETWORKAREA, SYSTEM_PARAMETERS_INFO_UPDATE_FLAGS,
    };
    let mut work = RECT::default();
    // SAFETY: SPI_GETWORKAREA writes a RECT into the provided pointer.
    let got = unsafe {
        SystemParametersInfoW(
            SPI_GETWORKAREA,
            0,
            Some(&mut work as *mut _ as *mut _),
            SYSTEM_PARAMETERS_INFO_UPDATE_FLAGS(0),
        )
    }
    .is_ok();
    if got {
        return Some(WorkArea {
            right: work.right,
            bottom: work.bottom,
            height: work.bottom - work.top,
        });
    }
    let mon = window.current_monitor()?;
    let pos = mon.position();
    let msize = mon.size();
    Some(WorkArea {
        right: pos.x + msize.width as i32,
        bottom: pos.y + msize.height as i32,
        height: msize.height as i32,
    })
}

#[cfg(test)]
mod tests {
    use super::{anchor_bottom_right, next_height, WIDTH};
    use winit::dpi::PhysicalSize;

    #[test]
    fn connecting_grows_the_flyout() {
        assert_eq!(next_height(458.0, 398.0, 900.0), Some(458.0));
    }

    #[test]
    fn disconnecting_shrinks_it_back() {
        assert_eq!(next_height(398.0, 458.0, 900.0), Some(398.0));
    }

    #[test]
    fn sub_pixel_wobble_requests_nothing() {
        assert_eq!(next_height(398.4, 398.0, 900.0), None);
        assert_eq!(next_height(397.6, 398.0, 900.0), None);
    }

    #[test]
    fn never_taller_than_the_work_area() {
        assert_eq!(next_height(2000.0, 398.0, 700.0), Some(700.0));
    }

    #[test]
    fn a_tiny_work_area_does_not_panic() {
        assert_eq!(next_height(458.0, 398.0, 100.0), Some(200.0));
    }

    #[test]
    fn an_unmeasured_frame_is_ignored() {
        assert_eq!(next_height(f64::NEG_INFINITY, 398.0, 900.0), None);
    }

    #[test]
    fn the_bottom_edge_never_moves() {
        let (right, bottom, gap) = (1920, 1040, 12);
        let short = anchor_bottom_right(PhysicalSize::new(344, 398), right, bottom, gap);
        let tall = anchor_bottom_right(PhysicalSize::new(344, 458), right, bottom, gap);
        assert_eq!(short.y + 398, tall.y + 458);
        assert_eq!(short.y + 398, bottom - gap);
        assert_eq!(short.x, tall.x);
        assert_eq!(short.x + WIDTH as i32, right - gap);
    }
}

pub struct Flyout {
    gl: GlWindow,
    ip_text: String,
    /// Creation time — focus-loss dismisses are ignored for a short grace
    /// period so a slow initial focus grant can't insta-close the flyout.
    opened_at: std::time::Instant,
}

impl Flyout {
    pub fn new(
        event_loop: &ActiveEventLoop,
        proxy: EventLoopProxy<UserEvent>,
    ) -> anyhow::Result<Self> {
        let attrs = Window::default_attributes()
            .with_title("Remote Control")
            .with_inner_size(LogicalSize::new(WIDTH, INITIAL_HEIGHT))
            .with_resizable(false)
            .with_decorations(false)
            .with_window_level(WindowLevel::AlwaysOnTop)
            .with_skip_taskbar(true);
        let gl = GlWindow::new(event_loop, attrs, proxy)?;
        super::chrome::round_corners(gl.window());
        position_above_tray(gl.window());
        gl.show();
        gl.focus(); // focus-loss dismiss needs initial focus
        gl.request_redraw();
        let ip_text = style::local_ip()
            .map(|ip| ip.to_string())
            .unwrap_or_else(|| "no network".to_string());
        Ok(Self {
            gl,
            ip_text,
            opened_at: std::time::Instant::now(),
        })
    }

    /// Whether a focus-loss event should dismiss the flyout (grace period
    /// for the initial focus grant).
    pub fn should_dismiss_on_blur(&self) -> bool {
        self.opened_at.elapsed() > std::time::Duration::from_millis(250)
    }

    pub fn window_id(&self) -> WindowId {
        self.gl.window_id()
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

    pub fn redraw(&mut self, ctx: &ShellCtx, paused: bool) -> Vec<ShellAction> {
        let mut actions = Vec::new();
        let ip_text = self.ip_text.clone();
        self.gl.redraw(glass_clear(), |_window, ui| {
            render(ui, ctx, paused, &ip_text, &mut actions);
        });
        actions
    }
}

/// The flyout's GL clear — the glass-approximation surface tone.
fn glass_clear() -> (f32, f32, f32) {
    let c = style::SURFACE_GLASS;
    (
        c.r() as f32 / 255.0,
        c.g() as f32 / 255.0,
        c.b() as f32 / 255.0,
    )
}

/// Anchor the flyout to the bottom-right of the primary work area (above
/// the taskbar). No-op when the work area is unreadable.
fn position_above_tray(window: &Window) {
    let Some(area) = work_area(window) else {
        return;
    };
    let gap = (EDGE_GAP * window.scale_factor()) as i32;
    window.set_outer_position(anchor_bottom_right(
        window.outer_size(),
        area.right,
        area.bottom,
        gap,
    ));
}

fn render(
    ui: &mut egui::Ui,
    ctx: &ShellCtx,
    paused: bool,
    ip_text: &str,
    actions: &mut Vec<ShellAction>,
) {
    // Esc dismisses like a menu.
    if ui.input(|i| i.key_pressed(egui::Key::Escape)) {
        actions.push(ShellAction::Close);
    }
    let conn = *ctx.conn_count.borrow();

    // 1px panel border over the whole flyout.
    let full = ui.max_rect();
    ui.painter().rect_stroke(
        full,
        egui::CornerRadius::same(8),
        egui::Stroke::new(1.0, style::BORDER),
        egui::StrokeKind::Inside,
    );

    // Header.
    egui::Frame::new()
        .inner_margin(egui::Margin {
            left: 16,
            right: 16,
            top: 16,
            bottom: 14,
        })
        .show(ui, |ui| {
            ui.horizontal(|ui| {
                ui.spacing_mut().item_spacing.x = 10.0;
                let (glyph, _) =
                    ui.allocate_exact_size(egui::vec2(24.0, 24.0), egui::Sense::hover());
                ui.painter()
                    .rect_filled(glyph, egui::CornerRadius::same(7), style::ACCENT);
                ui.painter().text(
                    glyph.center(),
                    egui::Align2::CENTER_CENTER,
                    icon::CAST,
                    style::icons(15.0),
                    style::ACCENT_INK,
                );
                ui.label(
                    egui::RichText::new("Remote Control")
                        .font(style::sg_sb(14.0))
                        .color(style::TEXT),
                );
                ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                    let (text, color) = if paused {
                        ("PAUSED", style::MUTED_2)
                    } else if conn > 0 {
                        ("CONNECTED", style::ACCENT)
                    } else {
                        ("LISTENING", style::ACCENT)
                    };
                    style::pill_badge(ui, text, color, style::ACCENT_TINT, {
                        if paused {
                            style::BORDER
                        } else {
                            style::ACCENT_TINT_BORDER
                        }
                    });
                });
            });
            ui.add_space(12.0);
            ui.horizontal(|ui| {
                ui.label(
                    egui::RichText::new(device_name(ctx))
                        .font(style::sg_sb(16.0))
                        .color(style::TEXT),
                );
                ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                    ui.label(
                        egui::RichText::new(format!(":{}", ctx.resolved_port))
                            .font(style::mono(11.0))
                            .color(style::MUTED_2),
                    );
                });
            });
            ui.label(
                egui::RichText::new(format!("{ip_text} · Wi-Fi"))
                    .font(style::mono(11.0))
                    .color(style::MUTED_2),
            );
        });
    style::hairline(ui, style::BORDER_SOFT);

    // Connected-device section (count-based — no per-session names in shell).
    egui::Frame::new()
        .inner_margin(egui::Margin {
            left: 16,
            right: 16,
            top: 12,
            bottom: 6,
        })
        .show(ui, |ui| {
            let eyebrow = match conn {
                0 => "NO DEVICES CONNECTED".to_string(),
                1 => "1 DEVICE CONNECTED".to_string(),
                n => format!("{n} DEVICES CONNECTED"),
            };
            style::section_label(ui, &eyebrow);
            if conn > 0 {
                ui.add_space(10.0);
                style::card(style::SURFACE, style::BORDER, 10, 8).show(ui, |ui| {
                    ui.horizontal(|ui| {
                        ui.spacing_mut().item_spacing.x = 11.0;
                        let (tile, _) =
                            ui.allocate_exact_size(egui::vec2(34.0, 34.0), egui::Sense::hover());
                        ui.painter().rect_filled(
                            tile,
                            egui::CornerRadius::same(9),
                            style::SURFACE_2,
                        );
                        ui.painter().text(
                            tile.center(),
                            egui::Align2::CENTER_CENTER,
                            icon::SMARTPHONE,
                            style::icons(19.0),
                            style::TEXT_ICON,
                        );
                        ui.label(
                            egui::RichText::new(if conn == 1 {
                                "Phone streaming input".to_string()
                            } else {
                                format!("{conn} phones streaming input")
                            })
                            .font(style::sg(13.5))
                            .color(style::TEXT),
                        );
                    });
                });
            }
        });

    // Action rows.
    egui::Frame::new()
        .inner_margin(egui::Margin::same(8))
        .show(ui, |ui| {
            ui.spacing_mut().item_spacing.y = 1.0;
            if action_row(ui, icon::ADD, "Pair new device", None, false).clicked() {
                actions.push(ShellAction::OpenPair);
                actions.push(ShellAction::Close);
            }
            let (pglyph, plabel, ptag) = if paused {
                (icon::PLAY, "Resume input", "paused")
            } else {
                (icon::PAUSE, "Pause input", "running")
            };
            if action_row(ui, pglyph, plabel, Some(ptag), !paused).clicked() {
                actions.push(ShellAction::TogglePause);
            }
            if action_row(ui, icon::DESKTOP, "Open dashboard", None, false).clicked() {
                actions.push(ShellAction::OpenMain);
                actions.push(ShellAction::Close);
            }
            if action_row(ui, icon::SETTINGS, "Settings", None, false).clicked() {
                actions.push(ShellAction::OpenSettings);
                actions.push(ShellAction::Close);
            }
            ui.add_space(6.0);
            ui.horizontal(|ui| {
                ui.add_space(8.0);
                let w = ui.available_width() - 8.0;
                let (r, _) = ui.allocate_exact_size(egui::vec2(w, 1.0), egui::Sense::hover());
                ui.painter()
                    .rect_filled(r, egui::CornerRadius::ZERO, style::BORDER_SOFT);
            });
            ui.add_space(6.0);
            if action_row(ui, icon::POWER, "Quit", None, false).clicked() {
                actions.push(ShellAction::Quit);
            }
        });
}

/// A 40px flyout menu row: icon + label (+ right mono tag). `active` tints
/// the row with the accent wash (the handoff's Pause row).
fn action_row(
    ui: &mut egui::Ui,
    glyph: char,
    label: &str,
    tag: Option<&str>,
    active: bool,
) -> egui::Response {
    let (rect, resp) =
        ui.allocate_exact_size(egui::vec2(ui.available_width(), 40.0), egui::Sense::click());
    let p = ui.painter();
    if active {
        p.rect_filled(rect, egui::CornerRadius::same(9), style::ACCENT_TINT);
    } else if resp.hovered() {
        p.rect_filled(rect, egui::CornerRadius::same(9), style::SURFACE);
    }
    let cy = rect.center().y;
    p.text(
        egui::pos2(rect.left() + 10.0, cy),
        egui::Align2::LEFT_CENTER,
        glyph,
        style::icons(20.0),
        if active { style::ACCENT } else { style::MUTED },
    );
    p.text(
        egui::pos2(rect.left() + 42.0, cy),
        egui::Align2::LEFT_CENTER,
        label,
        style::sg(13.5),
        style::TEXT,
    );
    if let Some(tag) = tag {
        p.text(
            egui::pos2(rect.right() - 10.0, cy),
            egui::Align2::RIGHT_CENTER,
            tag,
            style::mono(10.0),
            style::MUTED_2,
        );
    }
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
