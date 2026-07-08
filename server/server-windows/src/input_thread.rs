//! Dedicated OS input thread: owns the `!Sync` [`enigo::Enigo`] handle and
//! converts the executor's `f32` deltas into integer pixel moves with a
//! per-axis sub-pixel accumulator (RESEARCH Pattern 2, criterion 4 of
//! PAD-05: slow diagonals must not stair-step or lose motion).
//!
//! `Enigo` is created ON this thread and never leaves it — the executor
//! side holds only an `mpsc::Sender<Cmd>` (which is `Send + Sync`), so the
//! sync `MouseKeys` hot path stays non-blocking (RESEARCH Pitfall 2).

use enigo::{Axis, Coordinate, Enigo, Mouse, Settings};

/// Command sent from the [`crate::executors::mouse_keys::EnigoMouseKeys`]
/// executor (hot path, non-blocking mpsc send) to the input thread.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Cmd {
    /// Relative cursor move in fractional pixels.
    Move(f32, f32),
    /// Scroll in fractional wheel units (dx = horizontal, dy = vertical).
    Scroll(f32, f32),
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
                let (ix, iy) = move_acc.step(dx, dy);
                if ix != 0 || iy != 0 {
                    // Injection failure is non-fatal on the hot path: drop
                    // the frame (send-and-forget contract), never panic.
                    let _ = enigo.move_mouse(ix, iy, Coordinate::Rel);
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
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

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
}
