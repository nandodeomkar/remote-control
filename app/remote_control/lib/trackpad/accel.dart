/// Velocity acceleration curve for the trackpad move path (PAD-01, D-05 —
/// the Remote Mouse benchmark's feel).
///
/// The curve is velocity-based: per-event pointer speed lerps the gain from
/// [kAccelMinGain] (slow, precise, ~1:1 — preserving the server sub-pixel
/// accumulator's fidelity, D-02) up to [kAccelMaxGain] at
/// [kAccelRefSpeedPx], then saturates. The user's sensitivity setting
/// multiplies the whole curve linearly. Every coefficient is a D-06 tunable
/// in tuning.dart — retune there, never here.
///
/// [accelGain] intentionally returns a SCALAR gain (not a scaled tuple): the
/// driver computes `sendMove(dx * g, dy * g)` so the move hot path allocates
/// nothing. Pure Dart — imports only dart:math and tuning.dart.
library;

import 'dart:math' as math;

import 'tuning.dart';

/// Returns the move-delta multiplier for one pointer event.
///
/// `gain = sensitivity * lerp(kAccelMinGain, kAccelMaxGain,
///          min(1.0, speed / kAccelRefSpeedPx))` where
/// `speed = sqrt(dx*dx + dy*dy)` — stateless and deterministic.
double accelGain(double dx, double dy, double sensitivity) {
  final speed = math.sqrt(dx * dx + dy * dy);
  final t = math.min(1.0, speed / kAccelRefSpeedPx);
  return sensitivity * (kAccelMinGain + (kAccelMaxGain - kAccelMinGain) * t);
}
