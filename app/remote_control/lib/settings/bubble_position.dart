/// The D8-02 floating-bubble position: shared_preferences-backed store +
/// Riverpod 3 provider.
///
/// NON-SECRET by rule (CLAUDE.md / stack "What NOT to Use"): the bubble
/// position lives in shared_preferences ONLY — never flutter_secure_storage
/// (keystore ops are slow and can throw after OS updates; only the auth token
/// is secret).
///
/// TWO halves, cloning the [SensitivityStore]/[SensitivityNotifier] house
/// pattern (08-PATTERNS: exact clone):
///
/// 1. [BubblePositionStore] — a small typed store over an injectable
///    [SharedPreferencesAsync] (the same adapter choice as [SensitivityStore]).
///    The value is serialized as a small `{edge, yFraction}` JSON string.
///    A missing/corrupt read degrades to [kBubblePositionDefault] (right,
///    0.70) and `yFraction` is clamped to [0,1] on both read and write, so a
///    tampered/out-of-range pref can never place the bubble off-screen
///    (T-08-01).
/// 2. [BubblePositionNotifier] — a Riverpod 3 unified [Notifier] that seeds
///    the default synchronously, loads the persisted value on build, and
///    persists through the store on [BubblePositionNotifier.set]
///    (fire-and-forget — a failed prefs write costs persistence, never
///    responsiveness).
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The shared_preferences key holding the bubble position JSON (D8-02).
const String kBubblePositionPrefsKey = 'bubble.position';

/// Which screen edge the bubble is docked to.
enum Edge { left, right }

/// The default bubble position: docked to the right edge, 70% down the
/// screen (D8-02).
const BubblePosition kBubblePositionDefault =
    BubblePosition(edge: Edge.right, yFraction: 0.70);

/// The persisted bubble position: which [edge] it is docked to and how far
/// down that edge ([yFraction] in [0,1]). Value-equal so the notifier
/// suppresses no-op rebuilds (mirrors the ConnectionStatus house habit).
class BubblePosition {
  /// The edge the bubble is docked to.
  final Edge edge;

  /// The vertical position down [edge], clamped to [0,1].
  final double yFraction;

  const BubblePosition({required this.edge, required this.yFraction});

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BubblePosition &&
          other.edge == edge &&
          other.yFraction == yFraction;

  @override
  int get hashCode => Object.hash(edge, yFraction);

  @override
  String toString() => 'BubblePosition(edge: $edge, yFraction: $yFraction)';
}

Edge? _edgeFromName(Object? name) {
  switch (name) {
    case 'left':
      return Edge.left;
    case 'right':
      return Edge.right;
    default:
      return null;
  }
}

/// Typed store for the bubble position: clamped/degrading reads and clamped
/// writes over shared_preferences (non-secret — never secure storage).
class BubblePositionStore {
  final SharedPreferencesAsync _prefs;

  /// Creates the store over [prefs], defaulting to the real adapter. An
  /// instance may be injected for tests.
  BubblePositionStore({SharedPreferencesAsync? prefs})
      : _prefs = prefs ?? SharedPreferencesAsync();

  /// The persisted bubble position, with `yFraction` clamped to [0,1];
  /// [kBubblePositionDefault] (right, 0.70) when unset, when the stored JSON
  /// is corrupt/wrong-typed, or when the edge is unknown (a broken pref must
  /// never place the bubble off-screen — T-08-01).
  Future<BubblePosition> load() async {
    try {
      final raw = await _prefs.getString(kBubblePositionPrefsKey);
      if (raw == null) return kBubblePositionDefault;
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      final edge = _edgeFromName(decoded['edge']);
      if (edge == null) return kBubblePositionDefault;
      final y = (decoded['yFraction'] as num).toDouble().clamp(0.0, 1.0);
      return BubblePosition(edge: edge, yFraction: y.toDouble());
    } on Object {
      return kBubblePositionDefault;
    }
  }

  /// Persists [p] (with `yFraction` clamped to [0,1]) as a JSON string under
  /// [kBubblePositionPrefsKey].
  Future<void> save(BubblePosition p) => _prefs.setString(
        kBubblePositionPrefsKey,
        jsonEncode({
          'edge': p.edge.name,
          'yFraction': p.yFraction.clamp(0.0, 1.0).toDouble(),
        }),
      );
}

/// The [BubblePositionStore] singleton (overridable in tests).
final bubblePositionStoreProvider = Provider<BubblePositionStore>(
  (ref) => BubblePositionStore(),
);

/// Riverpod 3 unified [Notifier] over the bubble position: synchronous default
/// seed, async load on build, persist-through on [set].
class BubblePositionNotifier extends Notifier<BubblePosition> {
  @override
  BubblePosition build() {
    // Seed the default synchronously so the bubble has a valid dock the very
    // first frame; replace with the persisted value as soon as it loads.
    unawaited(_load(ref.watch(bubblePositionStoreProvider)));
    return kBubblePositionDefault;
  }

  Future<void> _load(BubblePositionStore store) async {
    state = await store.load();
  }

  /// Sets the bubble position, applying live and persisting immediately
  /// (fire-and-forget).
  void set(BubblePosition p) {
    state = p;
    unawaited(ref.read(bubblePositionStoreProvider).save(p));
  }
}

/// The D8-02 bubble position the bubble drag/edge-snap commits and the scaffold
/// reads to place the bubble.
final bubblePositionProvider =
    NotifierProvider<BubblePositionNotifier, BubblePosition>(
  BubblePositionNotifier.new,
);
