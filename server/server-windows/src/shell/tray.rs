//! Tray icon (SRV-01/SRV-03): `TrayIcon` + a `muda` menu (Settings, Pair new
//! device, Pause, Quit) plus three RGBA icon states.
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
//! build-time asset pipeline needed, and the three colors reuse the D-12
//! locked Flutter palette (accent blue / muted gray / error red) for visual
//! consistency with the phone app.

use tray_icon::menu::{Menu, MenuId, MenuItem, PredefinedMenuItem};
use tray_icon::{Icon, TrayIcon, TrayIconBuilder};

/// Visual/tooltip state of the tray icon (SRV-01 pause + SRV-04 firewall
/// warning).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TrayState {
    /// Running normally, input flowing.
    Normal,
    /// Input paused via the tray menu (or 07-08's settings window).
    Paused,
    /// The startup self-test found a problem (port-in-use or
    /// firewall-blocked) — SRV-04 / D-06 loud warning.
    Warning,
}

/// Tray icon side (16x16 canvas is plenty for a solid-color glyph; Windows
/// scales it for the notification-area DPI).
const TRAY_ICON_SIZE: u32 = 32;

/// The tray icon + its menu. Built once on `StartCause::Init`
/// (RESEARCH Pitfall 3 — never at thread-spawn time).
pub struct Tray {
    icon: TrayIcon,
    settings_id: MenuId,
    pair_id: MenuId,
    pause_id: MenuId,
    quit_id: MenuId,
}

impl Tray {
    /// MUST be called from a thread that is already pumping a win32 message
    /// loop (RESEARCH Pitfall 2/3) — in practice, from
    /// `ApplicationHandler::new_events` on `StartCause::Init`.
    pub fn new() -> tray_icon::Result<Self> {
        // Settings opens the on-demand egui window (07-08); Pair-new opens a
        // fresh 60s PIN window WITHOUT opening settings — D-02 requires the
        // action in BOTH places.
        let settings_item = MenuItem::new("Settings…", true, None);
        let pair_item = MenuItem::new("Pair new device", true, None);
        let pause_item = MenuItem::new("Pause input", true, None);
        let quit_item = MenuItem::new("Quit", true, None);
        let settings_id = settings_item.id().clone();
        let pair_id = pair_item.id().clone();
        let pause_id = pause_item.id().clone();
        let quit_id = quit_item.id().clone();

        let menu = Menu::new();
        menu.append(&settings_item).map_err(menu_err)?;
        menu.append(&pair_item).map_err(menu_err)?;
        menu.append(&PredefinedMenuItem::separator())
            .map_err(menu_err)?;
        menu.append(&pause_item).map_err(menu_err)?;
        menu.append(&PredefinedMenuItem::separator())
            .map_err(menu_err)?;
        menu.append(&quit_item).map_err(menu_err)?;

        let icon = TrayIconBuilder::new()
            .with_menu(Box::new(menu))
            .with_icon(icon_for(TrayState::Normal))
            .with_tooltip(tooltip_text(0))
            .build()?;

        Ok(Self {
            icon,
            settings_id,
            pair_id,
            pause_id,
            quit_id,
        })
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

    /// The Settings menu item's id — opens the on-demand egui settings
    /// window (routed through `UserEvent::OpenSettings`).
    pub fn settings_id(&self) -> &MenuId {
        &self.settings_id
    }

    /// The Pair-new menu item's id — on-demand pairing straight from the
    /// tray, no settings window needed (D-02).
    pub fn pair_id(&self) -> &MenuId {
        &self.pair_id
    }

    /// The Pause menu item's id, compared against incoming `MenuEvent`s.
    pub fn pause_id(&self) -> &MenuId {
        &self.pause_id
    }

    /// The Quit menu item's id, compared against incoming `MenuEvent`s.
    pub fn quit_id(&self) -> &MenuId {
        &self.quit_id
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

/// Map a `muda` menu-build error into a `tray_icon::Error` so `Tray::new`'s
/// `?` chain stays uniform (muda's `Error` has no `From<muda::Error> for
/// tray_icon::Error`, so this adapts it into the `OsError(io::Error)` arm).
fn menu_err(e: tray_icon::menu::Error) -> tray_icon::Error {
    tray_icon::Error::OsError(std::io::Error::other(e.to_string()))
}

/// Build the state's solid-color circle icon (see module docs — no bundled
/// `.ico` asset needed).
fn icon_for(state: TrayState) -> Icon {
    let rgb = match state {
        TrayState::Normal => (0x4C, 0x8D, 0xFF),  // D-12 locked accent blue
        TrayState::Paused => (0x6B, 0x72, 0x80),  // D-12 muted token
        TrayState::Warning => (0xFF, 0x6B, 0x6B), // D-12 error token
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
