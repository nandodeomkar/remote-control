/// The D8-03 floating-trackpad-window position: shared_preferences-backed
/// store + Riverpod 3 provider.
///
/// NON-SECRET by rule (CLAUDE.md / stack "What NOT to Use"): the window
/// position lives in shared_preferences ONLY — never flutter_secure_storage.
///
/// TWO halves, cloning the [BubblePositionStore]/[BubblePositionNotifier]
/// sibling (itself a clone of the SensitivityStore house pattern):
///
/// 1. [WindowPositionStore] — a small typed store over an injectable
///    [SharedPreferencesAsync]. The value is serialized as a small `{x, y}`
///    JSON string. A missing/corrupt read degrades to the UNSET sentinel
///    ([WindowPosition.unset]) so [FloatingTrackpadWindow] (08-04) knows to
///    derive its anchor from the bubble spot on first-ever open; after any
///    move it stores real fractions clamped to [0,1] on both read and write,
///    so a tampered/out-of-range pref can never place the window off-screen
///    (T-08-01 / SC4).
/// 2. [WindowPositionNotifier] — a Riverpod 3 unified [Notifier] that seeds
///    the unset sentinel synchronously, loads the persisted value on build,
///    and persists through the store on [WindowPositionNotifier.set]
///    (fire-and-forget).
///
/// Fully INDEPENDENT of the bubble store (SC4): a separate prefs key, no
/// cross-reference.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The shared_preferences key holding the window position JSON (D8-03).
const String kWindowPositionPrefsKey = 'window.position';

/// The persisted floating-window position: [xFraction]/[yFraction] in [0,1]
/// when [isSet], or the UNSET sentinel (all-zero, `isSet == false`) that means
/// "never moved — anchor from the bubble spot on first-ever open" (D8-03).
/// Value-equal so the notifier suppresses no-op rebuilds.
class WindowPosition {
  /// Whether real fractions have been stored (the window has been moved at
  /// least once). When false this is the unset sentinel and
  /// [xFraction]/[yFraction] are meaningless (0.0).
  final bool isSet;

  /// The horizontal position, clamped to [0,1] (meaningful only when [isSet]).
  final double xFraction;

  /// The vertical position, clamped to [0,1] (meaningful only when [isSet]).
  final double yFraction;

  /// A set position at ([xFraction], [yFraction]).
  const WindowPosition.at(this.xFraction, this.yFraction) : isSet = true;

  /// The unset sentinel: the window has never been moved, so 08-04 anchors
  /// from the bubble spot on first-ever open.
  const WindowPosition.unset()
      : isSet = false,
        xFraction = 0.0,
        yFraction = 0.0;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is WindowPosition &&
          other.isSet == isSet &&
          other.xFraction == xFraction &&
          other.yFraction == yFraction;

  @override
  int get hashCode => Object.hash(isSet, xFraction, yFraction);

  @override
  String toString() => isSet
      ? 'WindowPosition.at($xFraction, $yFraction)'
      : 'WindowPosition.unset()';
}

/// Typed store for the window position: clamped/degrading reads and clamped
/// writes over shared_preferences (non-secret — never secure storage).
class WindowPositionStore {
  final SharedPreferencesAsync _prefs;

  /// Creates the store over [prefs], defaulting to the real adapter. An
  /// instance may be injected for tests.
  WindowPositionStore({SharedPreferencesAsync? prefs})
      : _prefs = prefs ?? SharedPreferencesAsync();

  /// The persisted window position with fractions clamped to [0,1]; the UNSET
  /// sentinel when unset or when the stored JSON is corrupt/wrong-typed (a
  /// broken pref must never place the window off-screen — T-08-01).
  Future<WindowPosition> load() async {
    try {
      final raw = await _prefs.getString(kWindowPositionPrefsKey);
      if (raw == null) return const WindowPosition.unset();
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      final x = (decoded['x'] as num).toDouble().clamp(0.0, 1.0);
      final y = (decoded['y'] as num).toDouble().clamp(0.0, 1.0);
      return WindowPosition.at(x.toDouble(), y.toDouble());
    } on Object {
      return const WindowPosition.unset();
    }
  }

  /// Persists [p] (with fractions clamped to [0,1]) as a JSON string under
  /// [kWindowPositionPrefsKey]. The unset sentinel is written as (0,0); callers
  /// only ever save a real, moved position.
  Future<void> save(WindowPosition p) => _prefs.setString(
        kWindowPositionPrefsKey,
        jsonEncode({
          'x': p.xFraction.clamp(0.0, 1.0).toDouble(),
          'y': p.yFraction.clamp(0.0, 1.0).toDouble(),
        }),
      );
}

/// The [WindowPositionStore] singleton (overridable in tests).
final windowPositionStoreProvider = Provider<WindowPositionStore>(
  (ref) => WindowPositionStore(),
);

/// Riverpod 3 unified [Notifier] over the window position: synchronous unset
/// seed, async load on build, persist-through on [set].
class WindowPositionNotifier extends Notifier<WindowPosition> {
  @override
  WindowPosition build() {
    // Seed the unset sentinel synchronously so 08-04 can anchor from the
    // bubble spot until the persisted value loads.
    unawaited(_load(ref.watch(windowPositionStoreProvider)));
    return const WindowPosition.unset();
  }

  Future<void> _load(WindowPositionStore store) async {
    state = await store.load();
  }

  /// Sets the window position, applying live and persisting immediately
  /// (fire-and-forget).
  void set(WindowPosition p) {
    state = p;
    unawaited(ref.read(windowPositionStoreProvider).save(p));
  }
}

/// The D8-03 window position the floating window's header-drag commits and the
/// window reads to place itself.
final windowPositionProvider =
    NotifierProvider<WindowPositionNotifier, WindowPosition>(
  WindowPositionNotifier.new,
);
