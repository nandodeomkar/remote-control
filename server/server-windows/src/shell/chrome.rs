//! Custom borderless window chrome (Phase 10 handoff): the 42px title bar
//! with the accent app glyph, drag-to-move, minimize/close controls — plus
//! the Win11 DWM rounded-corner hint so a decorationless winit window still
//! gets the system's 8px rounding + shadow.

use winit::raw_window_handle::{HasWindowHandle as _, RawWindowHandle};
use winit::window::Window;

use super::style::{self, icon};

/// What the shell should do in response to UI interactions this frame.
/// Returned by every window's render pass; the `ShellApp` executes them
/// after the frame (render code never borrows the app).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ShellAction {
    /// Close THIS window (chrome ✕ or Esc).
    Close,
    /// Minimize THIS window.
    Minimize,
    /// Open (or focus) the settings window.
    OpenSettings,
    /// Open (or focus) the main dashboard window.
    OpenMain,
    /// Open (or focus) the pair-new-device window.
    OpenPair,
    /// Flip the input-pause seam.
    TogglePause,
    /// Quit the whole server.
    Quit,
}

/// Ask DWM to round the window's corners (Win11 `DWMWCP_ROUND`). Silent
/// no-op when unsupported (Win10) — the window just stays square.
pub fn round_corners(window: &Window) {
    use windows::Win32::Graphics::Dwm::{
        DwmSetWindowAttribute, DWMWA_WINDOW_CORNER_PREFERENCE, DWMWCP_ROUND,
    };
    let Ok(handle) = window.window_handle() else {
        return;
    };
    let RawWindowHandle::Win32(win32) = handle.as_raw() else {
        return;
    };
    let hwnd = windows::Win32::Foundation::HWND(win32.hwnd.get() as *mut _);
    let pref = DWMWCP_ROUND;
    // SAFETY: valid HWND from winit; attribute struct is POD by-value.
    unsafe {
        let _ = DwmSetWindowAttribute(
            hwnd,
            DWMWA_WINDOW_CORNER_PREFERENCE,
            &pref as *const _ as *const _,
            std::mem::size_of_val(&pref) as u32,
        );
    }
}

/// Paint the 42px title bar: accent app glyph + `title`, right-aligned
/// window controls. Dragging any empty run of the bar moves the window.
/// Returns `Close`/`Minimize` when a control is clicked.
pub fn title_bar(
    ui: &mut egui::Ui,
    window: &Window,
    title: &str,
    minimizable: bool,
) -> Option<ShellAction> {
    let mut action = None;
    let bar_h = 42.0;
    let full_w = ui.available_width();
    let (bar_rect, _) = ui.allocate_exact_size(egui::vec2(full_w, bar_h), egui::Sense::hover());
    let p = ui.painter();

    // Chrome background + bottom hairline.
    p.rect_filled(
        egui::Rect::from_min_size(bar_rect.min, egui::vec2(full_w, bar_h)),
        egui::CornerRadius::ZERO,
        style::BG_CHROME,
    );
    p.line_segment(
        [
            egui::pos2(bar_rect.left(), bar_rect.bottom()),
            egui::pos2(bar_rect.right(), bar_rect.bottom()),
        ],
        egui::Stroke::new(1.0, style::HAIRLINE),
    );

    // App glyph: 17px rounded-5 accent square with the cast icon.
    let glyph_rect = egui::Rect::from_min_size(
        egui::pos2(bar_rect.left() + 15.0, bar_rect.center().y - 8.5),
        egui::vec2(17.0, 17.0),
    );
    p.rect_filled(glyph_rect, egui::CornerRadius::same(5), style::ACCENT);
    p.text(
        glyph_rect.center(),
        egui::Align2::CENTER_CENTER,
        icon::CAST,
        style::icons(12.0),
        style::ACCENT_INK,
    );

    // Title.
    p.text(
        egui::pos2(glyph_rect.right() + 11.0, bar_rect.center().y),
        egui::Align2::LEFT_CENTER,
        title,
        style::sg(12.5),
        style::TEXT,
    );

    // Window controls, right to left: close, then (optionally) minimize.
    let mut cx = bar_rect.right();
    let close_rect = egui::Rect::from_min_max(
        egui::pos2(cx - 46.0, bar_rect.top()),
        egui::pos2(cx, bar_rect.bottom() - 1.0),
    );
    cx -= 46.0;
    let close_resp = ui.interact(close_rect, ui.id().with("chrome_close"), egui::Sense::click());
    if close_resp.hovered() {
        ui.painter()
            .rect_filled(close_rect, egui::CornerRadius::ZERO, style::RED_TINT);
    }
    ui.painter().text(
        close_rect.center(),
        egui::Align2::CENTER_CENTER,
        icon::CLOSE,
        style::icons(18.0),
        if close_resp.hovered() {
            style::RED
        } else {
            style::TEXT_DIM
        },
    );
    if close_resp.clicked() {
        action = Some(ShellAction::Close);
    }

    if minimizable {
        let min_rect = egui::Rect::from_min_max(
            egui::pos2(cx - 44.0, bar_rect.top()),
            egui::pos2(cx, bar_rect.bottom() - 1.0),
        );
        let min_resp = ui.interact(min_rect, ui.id().with("chrome_min"), egui::Sense::click());
        if min_resp.hovered() {
            ui.painter()
                .rect_filled(min_rect, egui::CornerRadius::ZERO, style::SURFACE);
        }
        // The minimize dash (11×1px, sitting low like the OS control).
        let dash = egui::Rect::from_center_size(
            egui::pos2(min_rect.center().x, min_rect.center().y + 5.0),
            egui::vec2(11.0, 1.0),
        );
        ui.painter()
            .rect_filled(dash, egui::CornerRadius::ZERO, style::TEXT_DIM);
        if min_resp.clicked() {
            action = Some(ShellAction::Minimize);
        }
    }

    // Drag anywhere left of the controls moves the window (custom chrome).
    let drag_rect = egui::Rect::from_min_max(
        bar_rect.min,
        egui::pos2(cx, bar_rect.bottom()),
    );
    let drag_resp = ui.interact(drag_rect, ui.id().with("chrome_drag"), egui::Sense::drag());
    if drag_resp.drag_started() {
        if let Err(e) = window.drag_window() {
            tracing::debug!(error = %e, "drag_window unsupported");
        }
    }

    action
}
