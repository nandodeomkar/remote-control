//! Shared visual language for the redesigned Windows shell (Phase 10 —
//! Claude Design handoff `docs/superpowers/2026-07-16-windows-shell-redesign/`).
//!
//! One place for the design palette, the vendored fonts, the Material Symbols
//! icon codepoints, and the reusable egui painting helpers (cards, toggle
//! switches, pill badges, status dots, section labels). Every shell window
//! (settings / main / flyout / pair) installs these fonts into its own
//! `egui::Context` and paints against these tokens so the four surfaces read
//! as one product.
//!
//! **Fonts (subset, vendored in `assets/fonts/`):** egui has no OpenType
//! ligature shaping, so Material Symbols glyphs are addressed by their PUA
//! codepoint (see [`icon`]), NOT by ligature name. Space Grotesk and IBM Plex
//! Mono ship as two static weights each (400 + 600) because egui selects a
//! font by *family*, not by a weight axis — bold is a distinct named family.
//!
//! **Gradients / glass:** egui `Frame` fills are solid; the handoff's hero
//! gradient and the flyout's backdrop-blur are approximated with solid
//! mid-tones (the blur tradeoff was accepted up front).

#![allow(dead_code)] // helpers are consumed panel-by-panel as they land

use std::sync::Arc;

use egui::{
    Color32, CornerRadius, FontData, FontDefinitions, FontFamily, FontId, Frame, Margin, Response,
    RichText, Sense, Stroke, Ui, Vec2,
};

// ─────────────────────────────────────────────────────────────────────────
// Palette (handoff hex tokens → Color32)
// ─────────────────────────────────────────────────────────────────────────

/// #0E0F12 — the app window background.
pub const BG_APP: Color32 = Color32::from_rgb(0x0E, 0x0F, 0x12);
/// #0B0C0F — title-bar / status-bar chrome (a touch deeper than the body).
pub const BG_CHROME: Color32 = Color32::from_rgb(0x0B, 0x0C, 0x0F);
/// #0a0b0e — the canvas behind everything (flyout desktop scene).
pub const BG_CANVAS: Color32 = Color32::from_rgb(0x0A, 0x0B, 0x0E);
/// #16181D — the standard raised surface (cards, fields, list rows).
pub const SURFACE: Color32 = Color32::from_rgb(0x16, 0x18, 0x1D);
/// #1C1F26 — a slightly lighter inset (device-avatar tiles).
pub const SURFACE_2: Color32 = Color32::from_rgb(0x1C, 0x1F, 0x26);
/// #181B21 — hero-card top stop (the gradient is approximated solid).
pub const SURFACE_HERO: Color32 = Color32::from_rgb(0x17, 0x1A, 0x20);
/// #12141_9-ish glassy flyout body (opaque approximation of blur(28px)).
pub const SURFACE_GLASS: Color32 = Color32::from_rgb(0x14, 0x16, 0x1B);

/// #2A2D34 — the standard 1px border.
pub const BORDER: Color32 = Color32::from_rgb(0x2A, 0x2D, 0x34);
/// #23262d — a softer divider/hairline between list rows.
pub const BORDER_SOFT: Color32 = Color32::from_rgb(0x23, 0x26, 0x2D);
/// #191c22 — the chrome hairline (title/footer separators).
pub const HAIRLINE: Color32 = Color32::from_rgb(0x19, 0x1C, 0x22);

/// #38BDF8 — the accent (locked D-12 blue, matches the phone app).
pub const ACCENT: Color32 = Color32::from_rgb(0x38, 0xBD, 0xF8);
/// #0ea5e0 — accent gradient deep stop / hover.
pub const ACCENT_DEEP: Color32 = Color32::from_rgb(0x0E, 0xA5, 0xE0);
/// #06121a — near-black ink for text/glyphs sitting ON the accent.
pub const ACCENT_INK: Color32 = Color32::from_rgb(0x06, 0x12, 0x1A);

/// #E6E8EB — primary text.
pub const TEXT: Color32 = Color32::from_rgb(0xE6, 0xE8, 0xEB);
/// #c7ccd4 — window-control / chrome text.
pub const TEXT_DIM: Color32 = Color32::from_rgb(0xC7, 0xCC, 0xD4);
/// #cdd2d9 — device-avatar glyph.
pub const TEXT_ICON: Color32 = Color32::from_rgb(0xCD, 0xD2, 0xD9);
/// #8b93a1 — secondary text / muted labels.
pub const MUTED: Color32 = Color32::from_rgb(0x8B, 0x93, 0xA1);
/// #6B7280 — tertiary text / section eyebrows / placeholder.
pub const MUTED_2: Color32 = Color32::from_rgb(0x6B, 0x72, 0x80);
/// #4a505c — faintest hint text (divider labels).
pub const FAINT: Color32 = Color32::from_rgb(0x4A, 0x50, 0x5C);

/// #FF6B6B — error / revoke / warning.
pub const RED: Color32 = Color32::from_rgb(0xFF, 0x6B, 0x6B);
/// #E8A33D — expiry / caution amber.
pub const AMBER: Color32 = Color32::from_rgb(0xE8, 0xA3, 0x3D);

/// Accent tint at ~14% over the app bg (hero-icon chip / active menu row).
pub const ACCENT_TINT: Color32 = Color32::from_rgb(0x16, 0x24, 0x30);
/// Accent tint border at ~32%.
pub const ACCENT_TINT_BORDER: Color32 = Color32::from_rgb(0x24, 0x45, 0x5A);
/// Red tint background (warning card).
pub const RED_TINT: Color32 = Color32::from_rgb(0x18, 0x11, 0x13);
/// Red tint border (~40%).
pub const RED_TINT_BORDER: Color32 = Color32::from_rgb(0x5E, 0x38, 0x3A);

/// Window clear color as GL floats (#0E0F12).
pub const BG_CLEAR: (f32, f32, f32) = (0.055, 0.059, 0.071);

// ─────────────────────────────────────────────────────────────────────────
// Fonts
// ─────────────────────────────────────────────────────────────────────────

const SG_REGULAR: &[u8] = include_bytes!("../../assets/fonts/SpaceGrotesk-Regular-subset.ttf");
const SG_SEMIBOLD: &[u8] = include_bytes!("../../assets/fonts/SpaceGrotesk-SemiBold-subset.ttf");
const PLEX_REGULAR: &[u8] = include_bytes!("../../assets/fonts/IBMPlexMono-Regular-subset.ttf");
const PLEX_SEMIBOLD: &[u8] = include_bytes!("../../assets/fonts/IBMPlexMono-SemiBold-subset.ttf");
const ICONS: &[u8] = include_bytes!("../../assets/fonts/MaterialSymbolsRounded-subset.ttf");

/// Named family: Space Grotesk 600 (headings / emphasis).
pub const FAM_SG_SB: &str = "sg_sb";
/// Named family: IBM Plex Mono 400 (ip/port/latency/eyebrows).
pub const FAM_MONO: &str = "mono";
/// Named family: IBM Plex Mono 600 (PIN digits / bold mono).
pub const FAM_MONO_SB: &str = "mono_sb";
/// Named family: Material Symbols Rounded (icon glyphs by codepoint).
pub const FAM_ICONS: &str = "icons";

/// Install the vendored fonts into `ctx`. Call once per shell window right
/// after its `EguiGlow` is built. Space Grotesk 400 becomes the Proportional
/// default; the icon font is appended as a fallback to *every* family so an
/// icon codepoint resolves even inside a proportional/mono run.
pub fn install_fonts(ctx: &egui::Context) {
    let mut fonts = FontDefinitions::default();

    fonts
        .font_data
        .insert("sg_reg".into(), Arc::new(FontData::from_static(SG_REGULAR)));
    fonts
        .font_data
        .insert(FAM_SG_SB.into(), Arc::new(FontData::from_static(SG_SEMIBOLD)));
    fonts
        .font_data
        .insert(FAM_MONO.into(), Arc::new(FontData::from_static(PLEX_REGULAR)));
    fonts.font_data.insert(
        FAM_MONO_SB.into(),
        Arc::new(FontData::from_static(PLEX_SEMIBOLD)),
    );
    fonts
        .font_data
        .insert(FAM_ICONS.into(), Arc::new(FontData::from_static(ICONS)));

    // Proportional default → Space Grotesk 400, icon fallback last.
    let prop = fonts.families.entry(FontFamily::Proportional).or_default();
    prop.clear();
    prop.push("sg_reg".into());
    prop.push(FAM_ICONS.into());

    // Monospace default → IBM Plex Mono 400, icon fallback last.
    let mono = fonts.families.entry(FontFamily::Monospace).or_default();
    mono.clear();
    mono.push(FAM_MONO.into());
    mono.push(FAM_ICONS.into());

    // Named families for the weighted/icon variants.
    fonts.families.insert(
        FontFamily::Name(FAM_SG_SB.into()),
        vec![FAM_SG_SB.into(), FAM_ICONS.into()],
    );
    fonts.families.insert(
        FontFamily::Name(FAM_MONO.into()),
        vec![FAM_MONO.into(), FAM_ICONS.into()],
    );
    fonts.families.insert(
        FontFamily::Name(FAM_MONO_SB.into()),
        vec![FAM_MONO_SB.into(), FAM_ICONS.into()],
    );
    fonts
        .families
        .insert(FontFamily::Name(FAM_ICONS.into()), vec![FAM_ICONS.into()]);

    ctx.set_fonts(fonts);
}

/// A proportional (Space Grotesk 400) font at `size`.
pub fn sg(size: f32) -> FontId {
    FontId::new(size, FontFamily::Proportional)
}
/// Space Grotesk 600 at `size`.
pub fn sg_sb(size: f32) -> FontId {
    FontId::new(size, FontFamily::Name(FAM_SG_SB.into()))
}
/// IBM Plex Mono 400 at `size`.
pub fn mono(size: f32) -> FontId {
    FontId::new(size, FontFamily::Name(FAM_MONO.into()))
}
/// IBM Plex Mono 600 at `size`.
pub fn mono_sb(size: f32) -> FontId {
    FontId::new(size, FontFamily::Name(FAM_MONO_SB.into()))
}
/// Material Symbols glyph font at `size`.
pub fn icons(size: f32) -> FontId {
    FontId::new(size, FontFamily::Name(FAM_ICONS.into()))
}

// ─────────────────────────────────────────────────────────────────────────
// Material Symbols codepoints (see assets/fonts/icons.txt)
// ─────────────────────────────────────────────────────────────────────────

pub mod icon {
    pub const CAST: char = '\u{e307}';
    pub const CLOSE: char = '\u{e5cd}';
    pub const SENSORS: char = '\u{e51e}';
    pub const PAUSE: char = '\u{e034}';
    pub const PLAY: char = '\u{e037}';
    pub const ADD: char = '\u{e145}';
    pub const SMARTPHONE: char = '\u{e7ba}';
    pub const SETTINGS: char = '\u{e8b8}';
    pub const POWER: char = '\u{f8c7}';
    pub const SCHEDULE: char = '\u{efd6}';
    pub const INFO: char = '\u{e88e}';
    pub const WIFI: char = '\u{e63e}';
    pub const VOLUME_UP: char = '\u{e050}';
    pub const SEARCH: char = '\u{ef7a}';
    pub const FOLDER: char = '\u{e2c7}';
    pub const TERMINAL: char = '\u{eb8e}';
    pub const EXPAND_LESS: char = '\u{e5ce}';
    pub const CONTENT_COPY: char = '\u{e14d}';
    pub const QR: char = '\u{e00a}';
    pub const LOCK: char = '\u{e899}';
    pub const DESKTOP: char = '\u{e30c}';
}

/// A `RichText` icon glyph at `size`/`color`.
pub fn icon_rt(glyph: char, size: f32, color: Color32) -> RichText {
    RichText::new(glyph).font(icons(size)).color(color)
}

// ─────────────────────────────────────────────────────────────────────────
// Reusable widgets / frames
// ─────────────────────────────────────────────────────────────────────────

/// Apply the shell's global dark visuals: selection accent, transparent
/// window/panel fills (each panel paints its own bg), tightened spacing.
pub fn apply_theme(ctx: &egui::Context) {
    ctx.set_theme(egui::Theme::Dark);
    ctx.all_styles_mut(|style| {
        let v = &mut style.visuals;
        v.override_text_color = Some(TEXT);
        v.selection.bg_fill = ACCENT.gamma_multiply(0.35);
        v.selection.stroke = Stroke::new(1.0, ACCENT);
        v.panel_fill = BG_APP;
        v.window_fill = BG_APP;
        v.extreme_bg_color = SURFACE; // TextEdit background
        v.text_cursor.stroke = Stroke::new(1.5, ACCENT);
        // Fields + buttons: SURFACE fill, BORDER stroke, 10px corners across
        // every interaction state (the handoff's flat, quiet controls).
        let r = CornerRadius::same(10);
        for w in [
            &mut v.widgets.inactive,
            &mut v.widgets.hovered,
            &mut v.widgets.active,
            &mut v.widgets.open,
        ] {
            w.bg_fill = SURFACE;
            w.weak_bg_fill = SURFACE;
            w.bg_stroke = Stroke::new(1.0, BORDER);
            w.corner_radius = r;
            w.fg_stroke = Stroke::new(1.0, TEXT);
        }
        v.widgets.hovered.bg_stroke = Stroke::new(1.0, ACCENT_TINT_BORDER);
        v.widgets.noninteractive.bg_stroke = Stroke::new(1.0, BORDER);
        v.widgets.noninteractive.corner_radius = r;
        style.spacing.item_spacing = Vec2::new(8.0, 8.0);
        style.spacing.button_padding = Vec2::new(12.0, 8.0);
    });
}

/// A rounded surface card: `fill` + 1px `stroke` + `radius`, `pad` inner
/// margin. The workhorse container for every grouped section in the handoff.
pub fn card(fill: Color32, stroke: Color32, radius: u8, pad: i8) -> Frame {
    Frame::new()
        .fill(fill)
        .stroke(Stroke::new(1.0, stroke))
        .corner_radius(CornerRadius::same(radius))
        .inner_margin(Margin::same(pad))
}

/// Letter-spaced text as a `LayoutJob` (egui's `extra_letter_spacing` is the
/// real CSS-`letter-spacing` equivalent — no fake spacer characters).
pub fn tracked(text: &str, font: FontId, color: Color32, spacing: f32) -> egui::text::LayoutJob {
    let mut job = egui::text::LayoutJob::default();
    let mut format = egui::TextFormat::simple(font, color);
    format.extra_letter_spacing = spacing;
    job.append(text, 0.0, format);
    job
}

/// The mono uppercase section eyebrow (e.g. `CONNECTED NOW`), tracked to
/// match the handoff's `letter-spacing:2.5px`.
pub fn section_label(ui: &mut Ui, text: &str) {
    ui.label(tracked(text, mono(10.0), MUTED_2, 2.5));
}

/// A solid status dot of `color`, `d` px diameter, allocated inline.
pub fn status_dot(ui: &mut Ui, color: Color32, d: f32) {
    let (rect, _) = ui.allocate_exact_size(Vec2::splat(d), Sense::hover());
    ui.painter().circle_filled(rect.center(), d / 2.0, color);
}

/// A rounded pill badge: `[dot] TEXT` inside a tinted 999px capsule (the
/// CONNECTED / LISTENING chips). Returns nothing — decorative.
pub fn pill_badge(ui: &mut Ui, text: &str, color: Color32, fill: Color32, border: Color32) {
    card(fill, border, u8::MAX, 0)
        .inner_margin(Margin::symmetric(9, 4))
        .show(ui, |ui| {
            ui.horizontal(|ui| {
                ui.spacing_mut().item_spacing.x = 6.0;
                status_dot(ui, color, 7.0);
                ui.label(tracked(text, mono(10.0), color, 0.5));
            });
        });
}

/// An iOS-style toggle switch (48×28 track, 22px knob) bound to `on`. Accent
/// track when on, `BORDER` track when off; returns the click `Response`.
pub fn toggle(ui: &mut Ui, on: &mut bool) -> Response {
    let size = Vec2::new(48.0, 28.0);
    let (rect, mut resp) = ui.allocate_exact_size(size, Sense::click());
    if resp.clicked() {
        *on = !*on;
        resp.mark_changed();
    }
    let how_on = ui.ctx().animate_bool_responsive(resp.id, *on);
    let track = lerp_color(BORDER, ACCENT, how_on);
    let painter = ui.painter();
    painter.rect_filled(rect, CornerRadius::same(14), track);
    let knob_x = egui::lerp((rect.left() + 15.0)..=(rect.right() - 15.0), how_on);
    let knob_c = egui::pos2(knob_x, rect.center().y);
    let knob_fill = lerp_color(TEXT, ACCENT_INK, how_on);
    painter.circle_filled(knob_c, 11.0, knob_fill);
    resp
}

/// A 1px divider spanning the current available width.
pub fn hairline(ui: &mut Ui, color: Color32) {
    let (rect, _) = ui.allocate_exact_size(egui::vec2(ui.available_width(), 1.0), Sense::hover());
    ui.painter().rect_filled(rect, CornerRadius::ZERO, color);
}

/// A paired-device list row: avatar glyph + name/subtitle + right-aligned
/// red `Revoke`. Runs `on_revoke` when Revoke is clicked.
pub fn device_row(ui: &mut Ui, name: &str, sub: &str, revocable: bool, on_revoke: impl FnOnce()) {
    ui.allocate_ui(Vec2::new(ui.available_width(), 52.0), |ui| {
        ui.horizontal_centered(|ui| {
            ui.add_space(14.0);
            ui.label(icon_rt(icon::SMARTPHONE, 20.0, MUTED_2));
            ui.add_space(12.0);
            ui.vertical(|ui| {
                ui.spacing_mut().item_spacing.y = 1.0;
                ui.label(RichText::new(name).font(sg(14.0)).color(TEXT));
                ui.label(RichText::new(sub).font(sg(11.5)).color(MUTED_2));
            });
            if revocable {
                ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                    ui.add_space(14.0);
                    let revoke = ui.add(
                        egui::Label::new(RichText::new("Revoke").font(sg(13.0)).color(RED))
                            .sense(Sense::click()),
                    );
                    if revoke.clicked() {
                        on_revoke();
                    }
                });
            }
        });
    });
}

/// The accent "Pair new device" action row at the foot of a device card.
pub fn pair_row(ui: &mut Ui) -> Response {
    let (rect, resp) =
        ui.allocate_exact_size(Vec2::new(ui.available_width(), 48.0), Sense::click());
    if resp.hovered() {
        ui.painter().rect_filled(rect, CornerRadius::ZERO, SURFACE_2);
    }
    let p = ui.painter();
    let cy = rect.center().y;
    p.text(
        egui::pos2(rect.left() + 16.0, cy),
        egui::Align2::LEFT_CENTER,
        icon::ADD,
        icons(19.0),
        ACCENT,
    );
    p.text(
        egui::pos2(rect.left() + 43.0, cy),
        egui::Align2::LEFT_CENTER,
        "Pair new device",
        sg_sb(13.5),
        ACCENT,
    );
    resp
}

/// This machine's LAN IPv4, via a connected-but-silent UDP socket (no packet
/// is sent — `connect` just resolves the route). `None` off-network.
pub fn local_ip() -> Option<std::net::IpAddr> {
    let sock = std::net::UdpSocket::bind("0.0.0.0:0").ok()?;
    sock.connect("8.8.8.8:80").ok()?;
    Some(sock.local_addr().ok()?.ip())
}

/// Linear blend between two colors (`t` in 0..=1), per channel.
pub fn lerp_color(a: Color32, b: Color32, t: f32) -> Color32 {
    let t = t.clamp(0.0, 1.0);
    let l = |x: u8, y: u8| (x as f32 + (y as f32 - x as f32) * t).round() as u8;
    Color32::from_rgba_unmultiplied(
        l(a.r(), b.r()),
        l(a.g(), b.g()),
        l(a.b(), b.b()),
        l(a.a(), b.a()),
    )
}
