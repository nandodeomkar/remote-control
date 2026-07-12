/// The D-14 keep-awake ref-count (Pitfall 8).
///
/// [WakelockPlus] is a GLOBAL, non-ref-counted flag: whoever calls
/// `disable()` last wins, regardless of who else still wants the screen awake.
/// Today only the trackpad and presenter screens toggle it (paired in
/// initState/dispose — individually correct). The new D-10 quick-bar introduces
/// a `Presenter -> (quick-bar) -> Trackpad -> back` navigation path where
/// `Trackpad.dispose()` would call the global `disable()` while the underlying
/// Presenter still wants the screen awake — dropping keep-awake mid-use.
///
/// This wrapper fixes that by counting active requesters: [acquire] enables the
/// wakelock only on the 0->1 transition and [release] disables it only on the
/// final 1->0, guarding against underflow. Both screens route through the
/// shared [keepAwake] singleton instead of the raw global flag (wired in
/// 07-10). This helper is the concrete, actionable output of the D-14 "audit".
library;

import 'dart:async';

import 'package:wakelock_plus/wakelock_plus.dart';

/// A ref-counted wrapper over [WakelockPlus]: the screen stays awake while at
/// least one requester holds it, and the underlying platform flag toggles only
/// on the first [acquire] and the last [release].
///
/// The enable/disable calls are injectable so the ref-count transitions can be
/// unit-tested without the platform channel; production code uses the shared
/// [keepAwake] singleton, which defaults to the real [WakelockPlus] calls.
class KeepAwake {
  final Future<void> Function() _enable;
  final Future<void> Function() _disable;

  int _count = 0;

  /// Creates a ref-counter over [enable]/[disable], defaulting to the real
  /// [WakelockPlus] toggles. Tests inject spies to prove the transitions.
  KeepAwake({
    Future<void> Function()? enable,
    Future<void> Function()? disable,
  })  : _enable = enable ?? WakelockPlus.enable,
        _disable = disable ?? WakelockPlus.disable;

  /// The number of active requesters currently holding the wakelock.
  int get activeCount => _count;

  /// Registers a requester. Enables the wakelock only on the 0->1 transition;
  /// subsequent acquires just bump the count (the flag is already on).
  void acquire() {
    if (_count == 0) {
      unawaited(_enable());
    }
    _count++;
  }

  /// Releases a requester. Disables the wakelock only on the final 1->0
  /// transition. A release while the count is already 0 is a no-op — it never
  /// drives the count negative or calls `disable()` spuriously.
  void release() {
    if (_count == 0) return;
    _count--;
    if (_count == 0) {
      unawaited(_disable());
    }
  }
}

/// The process-wide keep-awake ref-counter. Every screen that needs the screen
/// to stay awake (trackpad, presenter) calls [keepAwake].acquire() in initState
/// and [keepAwake].release() in dispose — sharing one count so overlapping
/// screens can't drop each other's keep-awake (Pitfall 8).
final KeepAwake keepAwake = KeepAwake();
