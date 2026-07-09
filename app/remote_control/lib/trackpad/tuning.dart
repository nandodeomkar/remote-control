/// The ONE trackpad-feel constants file (D-06).
///
/// Every threshold and coefficient the gesture classifier (D-04), the
/// acceleration curve (PAD-01/D-05), and the momentum driver (PAD-03) use
/// lives HERE and nowhere else — no magic numbers in the classifier or the
/// curve. These values are D-06 ON-DEVICE TUNING starting points (RESEARCH
/// A6), NOT finals: the end-of-phase feel gate against the Remote Mouse
/// benchmark adjusts them in this file and in this file only.
///
/// Pure Dart — no IO, no Flutter imports (house style).
library;

// -- Tap / move classification (PAD-02, Pitfall 4) ----------------------------

/// Max accumulated travel (px) for a touch episode to still count as a tap
/// (single-finger tap = left click, two-finger tap = right click).
const double kTapSlopPx = 10.0;

/// Max down-to-up duration (ms) for a single-finger tap to fire a left click.
const int kTapMaxMs = 180;

/// Max first-down-to-last-up window (ms) for two downs to count as a
/// two-finger tap (right click) rather than the start of a scroll.
const int kTwoFingerTapWindowMs = 200;

/// Hold-still duration (ms) before a single finger enters long-press
/// drag-lock (PAD-04). The driver owns the timer; the classifier only emits
/// arm/disarm intents carrying this delay.
const int kLongPressMs = 250;

// -- Scroll momentum / fling (PAD-03, RESEARCH Pattern 2) ---------------------

/// Per-tick velocity decay factor for the momentum loop (~60Hz ticks).
const double kMomentumDecay = 0.92;

/// Momentum loop tick interval (ms), ~60Hz.
const int kMomentumTickMs = 16;

/// Velocity magnitude (px/ms) below which the momentum loop stops.
const double kMomentumStopVelocity = 0.05;

/// Min two-finger lift velocity (px/ms) required to seed a fling at all.
const double kFlingMinVelocityPxMs = 0.3;

/// Lookback window (ms) of recent scroll samples used to seed fling velocity.
const int kVelocityWindowMs = 100;

/// Wheel units per pixel of two-finger travel when emitting 0x02 frames.
const double kScrollUnitPerPx = 0.05;

/// Scroll direction sign: -1.0 = natural scroll (content follows fingers).
/// Flip to 1.0 on device if the owner prefers reverse.
const double kScrollDirection = -1.0;

// -- Velocity acceleration curve (PAD-01, D-05) -------------------------------

/// Gain multiplier at (near-)zero speed — slow precise moves stay ~1:1 so the
/// server's sub-pixel accumulator (D-02) keeps its fidelity end-to-end.
const double kAccelMinGain = 1.0;

/// Gain multiplier at/above [kAccelRefSpeedPx] — fast flicks cross the screen.
const double kAccelMaxGain = 2.5;

/// Per-event speed (px) at which the gain saturates at [kAccelMaxGain].
const double kAccelRefSpeedPx = 24.0;

// -- User sensitivity setting (D-05, shared_preferences non-secret) -----------

/// Default sensitivity multiplier applied linearly on top of the accel gain.
const double kSensitivityDefault = 1.0;

/// Lower bound of the sensitivity slider.
const double kSensitivityMin = 0.5;

/// Upper bound of the sensitivity slider.
const double kSensitivityMax = 2.0;
