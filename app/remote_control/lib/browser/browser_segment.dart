/// The Browser screen's `Tabs | Bookmarks` segment selection (phase 11, D-01)
/// and its persistence.
///
/// A [KeyboardPadStore] clone under a NEW prefs key: the same `PrefsKv` seam,
/// the same corrupt-read degradation, the same synchronous-seed-then-async-load
/// Riverpod-3 notifier. The pattern is copied deliberately rather than
/// generalised — two typed stores over two keys read better than one generic
/// enum store, and the keyboard's key must never be mutated from here.
///
/// The selection is NAVIGATION state, not a command: the segment bar is always
/// interactive (see `BrowserSegmentBar` in `browser_screen.dart`) and nothing
/// in this file touches the wire.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../store/device_store.dart';

/// Which list the Browser screen's swapped region renders.
enum BrowserSegment {
  /// The shipped PC tab list (the default — today's behaviour).
  tabs,

  /// The bookmark tree (phase 11).
  bookmarks,
}

/// The shared_preferences key holding the last-selected Browser segment
/// (11-UI-SPEC §Component 1 — Persistence).
///
/// A NEW key, deliberately distinct from `keyboard.pad`: the two surfaces
/// persist independently and neither store may read or write the other's key.
///
/// This is a NON-SECRET preference, so it belongs in `shared_preferences` and
/// NEVER in secure storage (house rule — keystore ops are slow and can throw
/// after an OS update; only the auth token is a secret).
const String kBrowserSegmentPrefsKey = 'browser.segment';

/// Typed store for the last-selected segment over the [PrefsKv] seam — the
/// [KeyboardPadStore]-shaped pattern under [kBrowserSegmentPrefsKey].
class BrowserSegmentStore {
  final PrefsKv _prefs;

  /// Creates the store over [prefs], defaulting to the real adapter. An
  /// instance may be injected for tests.
  BrowserSegmentStore({PrefsKv? prefs}) : _prefs = prefs ?? SharedPrefsKv();

  /// The persisted segment; [BrowserSegment.tabs] when unset, unknown,
  /// corrupt, or when the platform read THROWS — a broken prefs read must
  /// never take the Browser screen down (the T-10-04 precedent), and the
  /// default lands on today's shipped behaviour either way.
  Future<BrowserSegment> load() async {
    try {
      final stored = await _prefs.getString(kBrowserSegmentPrefsKey);
      return BrowserSegment.values.firstWhere(
        (segment) => segment.name == stored,
        orElse: () => BrowserSegment.tabs,
      );
    } on Object {
      return BrowserSegment.tabs;
    }
  }

  /// Persists [segment] (its enum name: 'tabs' | 'bookmarks') under
  /// [kBrowserSegmentPrefsKey]. Fire-and-forget — a failed write costs
  /// persistence only.
  Future<void> save(BrowserSegment segment) =>
      _prefs.setString(kBrowserSegmentPrefsKey, segment.name);
}

/// The [BrowserSegmentStore] singleton (overridable in tests).
final browserSegmentStoreProvider = Provider<BrowserSegmentStore>(
  (ref) => BrowserSegmentStore(),
);

/// Riverpod 3 unified [Notifier] over the selected segment: synchronous
/// [BrowserSegment.tabs] seed (the default), async load on build,
/// persist-through on [set].
class BrowserSegmentNotifier extends Notifier<BrowserSegment> {
  @override
  BrowserSegment build() {
    // Seed synchronously with the default so the first frame renders;
    // replace with the persisted value as soon as it loads.
    unawaited(_load(ref.watch(browserSegmentStoreProvider)));
    return BrowserSegment.tabs;
  }

  Future<void> _load(BrowserSegmentStore store) async {
    state = await store.load();
  }

  /// Selects [segment], applying live and persisting immediately
  /// (fire-and-forget — a failed prefs write costs persistence only).
  void set(BrowserSegment segment) {
    state = segment;
    unawaited(ref.read(browserSegmentStoreProvider).save(segment));
  }
}

/// The persisted segment the Browser screen's swapped region binds to.
final browserSegmentProvider =
    NotifierProvider<BrowserSegmentNotifier, BrowserSegment>(
  BrowserSegmentNotifier.new,
);
