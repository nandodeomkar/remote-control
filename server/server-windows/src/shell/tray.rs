//! Tray icon (SRV-01/SRV-03, Phase 10 redesign): a menu-less `TrayIcon`
//! whose clicks open the custom [`super::flyout::Flyout`] panel — the
//! OS-native muda context menu is fully replaced by the flyout (handoff 1b).
//!
//! **TaskbarCreated re-registration (RESEARCH Pitfall 1 / A1 — CONFIRMED):**
//! `tray-icon` 0.24 handles `TaskbarCreated` internally — its Win32
//! `tray_proc` re-calls `register_tray_icon` on that message (verified
//! against the vendored source, `platform_impl/windows/mod.rs`). No manual
//! re-register/`rebuild()` is needed; the tray survives an Explorer restart
//! as long as the shell thread keeps pumping its winit message loop, which
//! [`super::spawn_shell_thread`] does for the whole process lifetime.
//!
//! **Icon assets:** generated programmatically via [`Icon::from_rgba`]
//! (solid-color circles) instead of bundling a `.ico` resource file — no
//! build-time asset pipeline needed. Colors follow the handoff's 1e states:
//! accent blue #38BDF8 (normal), muted gray (paused), error red (warning).

use tray_icon::{Icon, TrayIcon, TrayIconBuilder};

/// Visual/tooltip state of the tray icon (SRV-01 pause + SRV-04 firewall
/// warning).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TrayState {
    /// Running normally, input flowing.
    Normal,
    /// Input paused via the flyout (or the main/settings windows).
    Paused,
    /// The startup self-test found a problem (port-in-use or
    /// firewall-blocked) — SRV-04 / D-06 loud warning.
    Warning,
}

/// Tray icon side (32x32 canvas; Windows scales it for the notification-area
/// DPI).
const TRAY_ICON_SIZE: u32 = 32;

/// The tray icon — deliberately menu-less: clicks route through
/// `TrayIconEvent` to the shell loop, which toggles the flyout.
pub struct Tray {
    icon: TrayIcon,
}

impl Tray {
    /// MUST be called from a thread that is already pumping a win32 message
    /// loop (RESEARCH Pitfall 2/3) — in practice, from
    /// `ApplicationHandler::new_events` on `StartCause::Init`.
    pub fn new() -> tray_icon::Result<Self> {
        let icon = TrayIconBuilder::new()
            .with_icon(icon_for(TrayState::Normal))
            .with_tooltip(tooltip_text(0))
            .build()?;
        Ok(Self { icon })
    }

    /// Sets the tooltip to the device COUNT only — NEVER paired device names
    /// (T-07-20 privacy backstop; the tooltip can be read on a shared
    /// screen). A failed OS-level set is swallowed (never panics the shell
    /// loop over a cosmetic failure).
    pub fn set_tooltip(&self, count: usize) {
        let _ = self.icon.set_tooltip(Some(tooltip_text(count)));
    }

    /// Swaps the icon glyph for the given state (SRV-01 pause / SRV-04
    /// warning). A failed OS-level set is swallowed, same discipline as
    /// [`Tray::set_tooltip`].
    pub fn set_state(&self, state: TrayState) {
        let _ = self.icon.set_icon(Some(icon_for(state)));
    }
}

/// Device-count-only tooltip text (T-07-20 — see [`Tray::set_tooltip`]).
fn tooltip_text(count: usize) -> String {
    match count {
        0 => "Remote Control — no devices connected".to_string(),
        1 => "Remote Control — 1 device connected".to_string(),
        n => format!("Remote Control — {n} devices connected"),
    }
}

/// Build the state's solid-color circle icon (see module docs — no bundled
/// `.ico` asset needed).
fn icon_for(state: TrayState) -> Icon {
    let rgb = match state {
        TrayState::Normal => (0x38, 0xBD, 0xF8),  // handoff accent #38BDF8
        TrayState::Paused => (0x6B, 0x72, 0x80),  // muted token
        TrayState::Warning => (0xFF, 0x6B, 0x6B), // error token
    };
    solid_circle_icon(rgb, TRAY_ICON_SIZE)
}

/// A filled circle on a transparent square canvas, `size`x`size`, opaque
/// `rgb` inside the circle and fully transparent outside it. Pure pixel math
/// — no file I/O, no OS calls — so [`Icon::from_rgba`]'s dimensions always
/// self-consistently match (the `.expect` below can never fire).
fn solid_circle_icon(rgb: (u8, u8, u8), size: u32) -> Icon {
    let center = (size as f32 - 1.0) / 2.0;
    let radius = size as f32 / 2.0 - 1.0;
    let mut rgba = Vec::with_capacity((size * size * 4) as usize);
    for y in 0..size {
        for x in 0..size {
            let dx = x as f32 - center;
            let dy = y as f32 - center;
            if dx * dx + dy * dy <= radius * radius {
                rgba.extend_from_slice(&[rgb.0, rgb.1, rgb.2, 255]);
            } else {
                rgba.extend_from_slice(&[0, 0, 0, 0]);
            }
        }
    }
    Icon::from_rgba(rgba, size, size).expect("solid_circle_icon dimensions are self-consistent")
}
