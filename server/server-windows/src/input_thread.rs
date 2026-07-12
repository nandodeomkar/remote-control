//! Dedicated OS input thread: owns the `!Sync` [`enigo::Enigo`] handle and
//! converts the executor's `f32` deltas into integer pixel moves with a
//! per-axis sub-pixel accumulator (RESEARCH Pattern 2, criterion 4 of
//! PAD-05: slow diagonals must not stair-step or lose motion).
//!
//! Cursor moves inject ABSOLUTE via raw `SendInput` with
//! `MOUSEEVENTF_VIRTUALDESK` (current pos + accumulated integer delta), which
//! bypasses the Windows "Enhance pointer precision" ballistics curve so slow
//! drags track 1:1 (D-01) and normalizes correctly across the multi-monitor
//! virtual desktop (D-03). Scroll stays on enigo — only the move arm needs
//! raw Win32 (RESEARCH Pattern 1).
//!
//! `Enigo` is created ON this thread and never leaves it — the executor
//! side holds only an `mpsc::Sender<Cmd>` (which is `Send + Sync`), so the
//! sync `MouseKeys` hot path stays non-blocking (RESEARCH Pitfall 2).

use enigo::{Axis, Direction, Enigo, Key, Keyboard, Mouse, Settings};
use server_core::executors::{Button, KeyCode, Modifier};
use windows::Win32::Foundation::POINT;
use windows::Win32::UI::Input::KeyboardAndMouse::{
    INPUT, INPUT_0, INPUT_MOUSE, MOUSEEVENTF_ABSOLUTE, MOUSEEVENTF_MOVE,
    MOUSEEVENTF_VIRTUALDESK, MOUSEINPUT, SendInput,
};
use windows::Win32::UI::WindowsAndMessaging::{
    GetCursorPos, GetSystemMetrics, SM_CXVIRTUALSCREEN, SM_CYVIRTUALSCREEN, SM_XVIRTUALSCREEN,
    SM_YVIRTUALSCREEN,
};

use crate::executors::keymap::{map_button, map_key, map_mod};

/// Command sent from the [`crate::executors::mouse_keys::EnigoMouseKeys`]
/// executor (hot path, non-blocking mpsc send) to the input thread.
///
/// NOT `Copy`: `KeyCode`/`String`/`Vec` variants own heap data; the mpsc
/// send is a move, so `Clone` alone is sufficient.
#[derive(Debug, Clone, PartialEq)]
pub enum Cmd {
    /// Relative cursor move in fractional pixels.
    Move(f32, f32),
    /// Scroll in fractional wheel units (dx = horizontal, dy = vertical).
    Scroll(f32, f32),
    /// Single click of a mouse button (PAD-02).
    Click(Button),
    /// Press-and-hold a mouse button (drag start, PAD-04).
    ButtonDown(Button),
    /// Release a held mouse button (drag end, PAD-04).
    ButtonUp(Button),
    /// Press-and-hold a key — Windows generates the autorepeat stream while
    /// held (KEY-04, RESEARCH Pattern 5 / D-11).
    KeyDown(KeyCode),
    /// Release a held key (stops the OS autorepeat).
    KeyUp(KeyCode),
    /// Tap a key with modifiers held around it (KEY-03 combo path).
    KeyTap(KeyCode, Vec<Modifier>),
    /// Type literal text, layout-independent Unicode incl. emoji (KEY-01).
    Type(String),
    /// Delete `n` graphemes via n backspace clicks (KEY-01).
    Backspace(u32),
}

/// Per-axis sub-pixel accumulator: carries the fractional remainder across
/// frames so slow sub-integer deltas emit the correct cumulative integer
/// sequence (no lost fraction, no stair-step).
#[derive(Debug, Default)]
pub struct SubPixelAccumulator {
    acc_x: f32,
    acc_y: f32,
}

impl SubPixelAccumulator {
    /// Fresh accumulator with zero carried remainder on both axes.
    pub fn new() -> Self {
        Self::default()
    }

    /// Add one frame's fractional delta, return the integer part to inject,
    /// and carry the fractional remainder into the next frame.
    pub fn step(&mut self, dx: f32, dy: f32) -> (i32, i32) {
        self.acc_x += dx;
        self.acc_y += dy;
        let ix = self.acc_x.trunc() as i32;
        let iy = self.acc_y.trunc() as i32;
        self.acc_x -= ix as f32;
        self.acc_y -= iy as f32;
        (ix, iy)
    }
}

/// Virtual-desktop geometry: origin (left/top edge, can be negative on
/// multi-monitor setups) and total span across all monitors.
///
/// Plain `i32` fields ONLY — no `windows` types — so [`normalize_virtual`]
/// compiles and unit-tests on any host without a display (D-03 verification
/// without a second monitor).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct VirtualMetrics {
    /// Virtual-desktop left edge (`SM_XVIRTUALSCREEN`; `< 0` when a monitor
    /// sits left of the primary).
    pub x: i32,
    /// Virtual-desktop top edge (`SM_YVIRTUALSCREEN`).
    pub y: i32,
    /// Total width across all monitors (`SM_CXVIRTUALSCREEN`).
    pub w: i32,
    /// Total height across all monitors (`SM_CYVIRTUALSCREEN`).
    pub h: i32,
}

/// Map a virtual-desktop pixel to the 0..65535 absolute-injection grid per
/// the MS-documented convention `((p - origin) * 65535 + (span-1)/2) / (span-1)`
/// (the `+(span-1)/2` term rounds to nearest).
///
/// Targets are clamped to the virtual desktop first, so the result is always
/// within `0..=65535` — injection can never address outside the virtual
/// desktop (threat T-04-01). Intermediate math is `i64` to avoid `i32`
/// overflow on the `* 65535` multiply (RESEARCH Pattern 1).
pub fn normalize_virtual(target_x: i32, target_y: i32, m: VirtualMetrics) -> (i32, i32) {
    fn axis(target: i32, origin: i32, span: i32) -> i32 {
        // `last` = index of the final pixel on this axis; guard degenerate
        // metrics (span <= 1) against divide-by-zero.
        let last = i64::from(span - 1).max(1);
        let p = (i64::from(target) - i64::from(origin)).clamp(0, last);
        ((p * 65535 + last / 2) / last) as i32
    }
    (axis(target_x, m.x, m.w), axis(target_y, m.y, m.h))
}

/// `SECURITY_MANDATORY_MEDIUM_RID` (0x2000): the integrity level our own,
/// non-elevated process runs at. Mirrors the Win32 constant of the same name
/// (`windows::Win32::System::SystemServices::SECURITY_MANDATORY_MEDIUM_RID`)
/// as a plain `u32` so [`is_blocking_il`] stays a pure, OS-free predicate
/// (D-07 / RESEARCH Pitfall 6).
pub(crate) const SECURITY_MANDATORY_MEDIUM_RID: u32 = 0x2000;

/// `SECURITY_MANDATORY_HIGH_RID` (0x3000): the integrity level an elevated
/// ("Run as administrator" / UAC-elevated) foreground process runs at.
pub(crate) const SECURITY_MANDATORY_HIGH_RID: u32 = 0x3000;

/// D-07 / RESEARCH Pitfall 6: `SendInput` cannot report a UIPI (User
/// Interface Privilege Isolation) drop — neither its return value nor
/// `GetLastError` signals it — so detection must be PROACTIVE: compare the
/// foreground window's process integrity level to ours. A strictly higher
/// foreground integrity level silently discards our injected input; equal
/// or lower integrity accepts it normally.
///
/// Pure arithmetic — no OS state — so this is unit-tested directly (RESEARCH
/// A4: the HIGH/MEDIUM threshold is the detection signal; exact tuning is
/// validated on-device by the 07-06 wiring plan).
pub(crate) fn is_blocking_il(foreground_rid: u32, our_rid: u32) -> bool {
    foreground_rid > our_rid
}

/// Current cursor position in virtual-desktop coordinates, read FRESH each
/// frame (RESEARCH Pitfall 3: never track a floating internal target, or the
/// cursor fights the physical mouse — the OS carries the position, the
/// accumulator carries only the fraction).
///
/// `None` = `GetCursorPos` failed; the caller drops the frame (non-fatal).
fn cursor_pos() -> Option<(i32, i32)> {
    let mut p = POINT::default();
    // SAFETY: GetCursorPos writes into a valid, live POINT.
    unsafe { GetCursorPos(&mut p) }.ok().map(|()| (p.x, p.y))
}

/// Inject one absolute `INPUT_MOUSE` at the given virtual-desktop pixel.
///
/// Builds [`VirtualMetrics`] from `SM_*VIRTUALSCREEN` and normalizes via
/// [`normalize_virtual`], injecting with `MOUSEEVENTF_VIRTUALDESK` so the
/// 0..65535 grid spans the WHOLE virtual desktop — enigo 0.6.1's Abs path
/// omits that flag and normalizes against the primary monitor only, jumping
/// or clamping on secondary displays (RESEARCH Pitfall 2). A failed
/// `SendInput` (returns 0 injected events) drops the frame; injection is
/// never fatal (threat T-04-01).
fn inject_absolute(target_x: i32, target_y: i32) {
    // SAFETY: GetSystemMetrics is a pure read; SendInput receives one fully
    // initialized INPUT with the matching cbSize.
    unsafe {
        let metrics = VirtualMetrics {
            x: GetSystemMetrics(SM_XVIRTUALSCREEN),
            y: GetSystemMetrics(SM_YVIRTUALSCREEN),
            w: GetSystemMetrics(SM_CXVIRTUALSCREEN),
            h: GetSystemMetrics(SM_CYVIRTUALSCREEN),
        };
        let (nx, ny) = normalize_virtual(target_x, target_y, metrics);
        let input = INPUT {
            r#type: INPUT_MOUSE,
            Anonymous: INPUT_0 {
                mi: MOUSEINPUT {
                    dx: nx,
                    dy: ny,
                    mouseData: 0,
                    dwFlags: MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK,
                    time: 0,
                    dwExtraInfo: 0,
                },
            },
        };
        let _ = SendInput(&[input], size_of::<INPUT>() as i32);
    }
}

/// Run the input-injection loop until every `Sender<Cmd>` is dropped.
///
/// MUST be called on a dedicated `std::thread` — `Enigo` is `!Sync` and this
/// is the only place it lives. DPI awareness is declared once in `main`
/// BEFORE this thread starts (RESEARCH Pattern 3), so the integer deltas
/// injected here map to physical pixels on scaled displays.
pub fn run_input_thread(rx: std::sync::mpsc::Receiver<Cmd>) {
    let mut enigo = Enigo::new(&Settings::default()).expect("enigo init on input thread");
    let mut move_acc = SubPixelAccumulator::new();
    let mut scroll_acc = SubPixelAccumulator::new();
    while let Ok(cmd) = rx.recv() {
        match cmd {
            Cmd::Move(dx, dy) => {
                // D-02: the accumulator is unchanged — it yields the integer
                // delta to consume and carries the fraction across frames.
                let (ix, iy) = move_acc.step(dx, dy);
                if ix != 0 || iy != 0 {
                    // Absolute inject = current REAL cursor + integer delta,
                    // bypassing the "Enhance pointer precision" ballistics
                    // curve so slow drags track 1:1 (D-01). A failed
                    // GetCursorPos drops the frame (send-and-forget
                    // contract), never panics.
                    if let Some((cx, cy)) = cursor_pos() {
                        inject_absolute(cx.saturating_add(ix), cy.saturating_add(iy));
                    }
                }
            }
            Cmd::Scroll(dx, dy) => {
                let (sx, sy) = scroll_acc.step(dx, dy);
                // Wheel-direction sign convention verified in the Plan 04
                // manual smoke test (RESEARCH assumption A4).
                if sy != 0 {
                    let _ = enigo.scroll(sy, Axis::Vertical);
                }
                if sx != 0 {
                    let _ = enigo.scroll(sx, Axis::Horizontal);
                }
            }
            // Every arm below follows the non-fatal-drop rule (T-04-01):
            // injection failures and unknown key codes drop, never panic.
            Cmd::Click(b) => {
                let _ = enigo.button(map_button(b), Direction::Click);
            }
            Cmd::ButtonDown(b) => {
                let _ = enigo.button(map_button(b), Direction::Press);
            }
            Cmd::ButtonUp(b) => {
                let _ = enigo.button(map_button(b), Direction::Release);
            }
            Cmd::KeyDown(c) => {
                // Held press: Windows itself generates the key-repeat stream
                // while the key stays down (KEY-04, RESEARCH Pattern 5).
                if let Some(k) = map_key(&c) {
                    let _ = enigo.key(k, Direction::Press);
                }
            }
            Cmd::KeyUp(c) => {
                if let Some(k) = map_key(&c) {
                    let _ = enigo.key(k, Direction::Release);
                }
            }
            Cmd::KeyTap(c, mods) => {
                // Unknown code → drop the WHOLE command (never press mods
                // around a key that won't fire; T-04-02 silent-drop rule).
                if let Some(k) = map_key(&c) {
                    for m in &mods {
                        let _ = enigo.key(map_mod(*m), Direction::Press);
                    }
                    let _ = enigo.key(k, Direction::Click);
                    for m in mods.iter().rev() {
                        let _ = enigo.key(map_mod(*m), Direction::Release);
                    }
                }
            }
            Cmd::Type(s) => {
                // Layout-independent Unicode incl. emoji (KEYEVENTF_UNICODE,
                // KEY-01). NEVER log `s` — SPEC §12 redaction (T-04-03).
                let _ = enigo.text(&s);
            }
            Cmd::Backspace(n) => {
                for _ in 0..n {
                    let _ = enigo.key(Key::Backspace, Direction::Click);
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// D-07 / RESEARCH Pitfall 6: a strictly higher-integrity foreground
    /// window (elevated / UAC) blocks our injected input.
    #[test]
    fn is_blocking_il_high_foreground_over_medium_blocks() {
        assert!(
            is_blocking_il(SECURITY_MANDATORY_HIGH_RID, SECURITY_MANDATORY_MEDIUM_RID),
            "a HIGH-integrity foreground over our MEDIUM integrity must block"
        );
    }

    /// Equal integrity (the common case: a normal, non-elevated foreground
    /// window) never blocks.
    #[test]
    fn is_blocking_il_equal_integrity_does_not_block() {
        assert!(
            !is_blocking_il(SECURITY_MANDATORY_MEDIUM_RID, SECURITY_MANDATORY_MEDIUM_RID),
            "equal integrity levels must not block"
        );
    }

    /// A lower-integrity foreground (e.g. AppContainer/LOW, RID 0x1000) never
    /// blocks our MEDIUM-integrity input either.
    #[test]
    fn is_blocking_il_lower_foreground_does_not_block() {
        const SECURITY_MANDATORY_LOW_RID: u32 = 0x1000;
        assert!(
            !is_blocking_il(SECURITY_MANDATORY_LOW_RID, SECURITY_MANDATORY_MEDIUM_RID),
            "a LOW-integrity foreground under our MEDIUM integrity must not block"
        );
    }

    /// Crit 4 (D-04): a stream of sub-integer deltas emits the cumulative
    /// integer sequence with the fractional remainder carried. Over 5 frames
    /// of dx=0.4 the emitted integers are [0, 0, 1, 0, 1] (cumulative trunc:
    /// 0.4, 0.8, 1.2, 1.6, 2.0) — summing to 2, no lost fraction.
    #[test]
    fn sub_integer_deltas_carry_fraction_across_frames() {
        let mut acc = SubPixelAccumulator::new();
        let emitted: Vec<i32> = (0..5).map(|_| acc.step(0.4, 0.0).0).collect();
        assert_eq!(
            emitted,
            vec![0, 0, 1, 0, 1],
            "0.4px/frame must emit the cumulative-trunc sequence"
        );
        assert_eq!(
            emitted.iter().sum::<i32>(),
            2,
            "5 frames of 0.4px must sum to 2 integer pixels (no lost fraction)"
        );
    }

    /// Exact-integer deltas pass through unchanged and immediately.
    #[test]
    fn exact_integer_deltas_pass_through_unchanged() {
        let mut acc = SubPixelAccumulator::new();
        assert_eq!(acc.step(3.0, -2.0), (3, -2), "integer deltas emit immediately");
        assert_eq!(acc.step(3.0, -2.0), (3, -2), "no residue accumulates from exact integers");
    }

    /// Negative deltas accumulate and flush symmetrically: dx=-0.6/frame
    /// emits -1 on the second frame (cumulative -0.6, -1.2).
    #[test]
    fn negative_deltas_accumulate_and_flush_symmetrically() {
        let mut acc = SubPixelAccumulator::new();
        assert_eq!(acc.step(-0.6, 0.0).0, 0, "frame 1: -0.6 has no integer part yet");
        assert_eq!(acc.step(-0.6, 0.0).0, -1, "frame 2: cumulative -1.2 flushes -1");
    }

    /// Test A (D-01): a 1920x1080 primary at origin maps its corner pixels to
    /// the exact ends of the 0..65535 absolute grid per the MS convention
    /// `((p - origin) * 65535 + (span-1)/2) / (span-1)`, and the center
    /// rounds to nearest (not truncates).
    #[test]
    fn normalize_virtual_primary_origin_maps_corners_and_center() {
        let m = VirtualMetrics { x: 0, y: 0, w: 1920, h: 1080 };
        assert_eq!(normalize_virtual(0, 0, m), (0, 0), "top-left pixel is grid origin");
        assert_eq!(
            normalize_virtual(1919, 1079, m),
            (65535, 65535),
            "bottom-right pixel is the grid max"
        );
        // 960*65535/1919 = 32784.575 -> 32785; 540*65535/1079 = 32797.868 -> 32798
        assert_eq!(
            normalize_virtual(960, 540, m),
            (32785, 32798),
            "center must round to nearest, not truncate"
        );
    }

    /// Test B (D-03): a virtual desktop with a negative-origin left edge
    /// (secondary at x=-1920, total span 3840x1080). Points anywhere on the
    /// virtual desktop — including the negative-coordinate monitor — map
    /// INSIDE 0..65535 instead of overshooting (the enigo 0.6.1
    /// primary-monitor-only bug this fn exists to fix).
    #[test]
    fn normalize_virtual_negative_origin_secondary_maps_inside_grid() {
        let m = VirtualMetrics { x: -1920, y: 0, w: 3840, h: 1080 };
        assert_eq!(normalize_virtual(-1920, 0, m).0, 0, "leftmost virtual pixel -> nx=0");
        assert_eq!(normalize_virtual(1919, 0, m).0, 65535, "rightmost virtual pixel -> nx=65535");
        // A point on the right-hand (positive-x) monitor stays strictly inside.
        let (nx, _) = normalize_virtual(500, 0, m);
        assert!(
            nx > 0 && nx < 65535,
            "secondary-monitor point must map inside the grid, got {nx}"
        );
    }

    /// Test C (T-04-01 clamp/no-overshoot): every in-bounds target stays in
    /// 0..=65535 on both axes, and out-of-bounds targets (cursor at an edge
    /// plus a delta) clamp to the grid ends — injection can never address
    /// outside the virtual desktop.
    #[test]
    fn normalize_virtual_never_leaves_absolute_grid() {
        let m = VirtualMetrics { x: -1920, y: -500, w: 3840, h: 1580 };
        for tx in [-1920, -1919, -1, 0, 1, 960, 1918, 1919] {
            for ty in [-500, -499, -1, 0, 1, 539, 1078, 1079] {
                let (nx, ny) = normalize_virtual(tx, ty, m);
                assert!(
                    (0..=65535).contains(&nx) && (0..=65535).contains(&ny),
                    "in-bounds target ({tx},{ty}) escaped the grid: ({nx},{ny})"
                );
            }
        }
        // Out-of-bounds targets clamp (never overshoot, never wrap).
        assert_eq!(normalize_virtual(i32::MIN, i32::MIN, m), (0, 0));
        assert_eq!(normalize_virtual(i32::MAX, i32::MAX, m), (65535, 65535));
    }
}
