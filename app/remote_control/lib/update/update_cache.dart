/// The D-07 update-check cache: when the feed was last checked and what
/// version it reported, behind the [PrefsKv] seam.
///
/// NON-SECRET by rule (stack "What NOT to Use"): a timestamp and a public
/// version string are not secrets, so they live in `shared_preferences` ONLY —
/// NEVER in secure storage (keystore ops are slow and can throw after OS
/// updates; only the auth token is a secret). This is also the T-12-20
/// disposition: nothing cached here is a token, a PIN, or a device identity,
/// so local readability costs nothing.
///
/// **A FAILED OR STALE BACKGROUND CHECK MUST NEVER INTERRUPT THE USER**
/// (D-07, D-22). Two consequences are baked into this file:
///
/// 1. Every read degrades. A missing, corrupt, or type-mismatched value loads
///    as [UpdateCacheState.neverChecked] and throws nothing. An empty cache is
///    the normal first run, not an error — it is never logged as one.
/// 2. [save] is only called on a SUCCESSFUL check. A check that fails leaves
///    the previous good entry untouched, so the footer keeps rendering its
///    last `Last checked …` line and the badge keeps its last known answer
///    instead of blanking.
///
/// The badge reads this cache, which is why it is correct offline and before
/// the Updates screen has ever been opened (UI-SPEC Badge truth rule) — the
/// app's own installed version is knowable without a socket, and the cached
/// latest version is the other half of that comparison.
///
/// **WHAT IS STORED, deliberately minimal:** the last check time and the last
/// seen latest app version. Asset sizes are NOT cached. The badge does not
/// need a size, and the Updates screen only renders `{size}` in the
/// `available` subtitle, which is reached from a live feed fetch; offline that
/// row reads `Couldn't check` (D-22) and no size is displayed. Caching bytes
/// that nothing can render would be state to keep consistent for free.
///
/// **THIS CACHE IS NOT A SECURITY BOUNDARY** (T-12-19, accepted). A tampered
/// entry buys a stale `Last checked` line or an early re-check; it cannot
/// cause a download, because nothing downloads until a button is tapped
/// (D-07), and the server re-resolves the feed itself before any apply
/// (D-15 `stale`).
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../store/device_store.dart';

/// How long a check stays fresh — the D-07 "at most once per 24 hours"
/// cadence. Exactly 24 hours old is already stale (the boundary is inclusive,
/// so a launch one day later always gets its check).
const Duration kUpdateCheckTtl = Duration(hours: 24);

/// The shared_preferences key holding the last successful check time, stored
/// as decimal epoch milliseconds in a string.
///
/// Namespaced under `update.` like `browser.segment` and `pointer.sensitivity`
/// before it. The [PrefsKv] seam is string-only, so the int is encoded rather
/// than stored natively — which is also what makes the corrupt-read path
/// straightforward to exercise.
const String kUpdateLastCheckAtPrefsKey = 'update.lastCheckAt';

/// The shared_preferences key holding the last version the feed reported.
const String kUpdateLastSeenVersionPrefsKey = 'update.lastSeenVersion';

/// The immutable cache entry: when the feed was last checked successfully and
/// what it said.
///
/// Both fields are nullable and both nulls mean the same thing — *not known* —
/// which is the state a first run, a cleared app, and a corrupt read all land
/// on.
class UpdateCacheState {
  /// Epoch milliseconds of the last SUCCESSFUL check, or null when the feed
  /// has never been checked (or the stored value was unusable).
  final int? lastCheckAtMillis;

  /// The latest app version the feed reported at [lastCheckAtMillis], verbatim
  /// from the tag, or null when unknown. Never normalized here — the version
  /// module owns that.
  final String? lastSeenVersion;

  /// Creates a cache entry from its two optional halves.
  const UpdateCacheState({this.lastCheckAtMillis, this.lastSeenVersion});

  /// The default every degraded read lands on: never checked, nothing seen.
  const UpdateCacheState.neverChecked()
      : lastCheckAtMillis = null,
        lastSeenVersion = null;

  /// True when the feed has never been successfully checked.
  bool get isNeverChecked => lastCheckAtMillis == null;

  /// [lastCheckAtMillis] as a [DateTime], or null when never checked.
  DateTime? get lastCheckAt => lastCheckAtMillis == null
      ? null
      : DateTime.fromMillisecondsSinceEpoch(lastCheckAtMillis!);

  @override
  bool operator ==(Object other) =>
      other is UpdateCacheState &&
      other.lastCheckAtMillis == lastCheckAtMillis &&
      other.lastSeenVersion == lastSeenVersion;

  @override
  int get hashCode => Object.hash(lastCheckAtMillis, lastSeenVersion);

  @override
  String toString() =>
      'UpdateCacheState(lastCheckAtMillis: $lastCheckAtMillis, '
      'lastSeenVersion: $lastSeenVersion)';
}

/// True when a fresh check is permitted: no check has ever succeeded, or the
/// last one is at least [kUpdateCheckTtl] old.
///
/// **[now] is injected, never read from the clock**, so the TTL is testable
/// without waiting and without mocking `DateTime.now()`.
///
/// A stored time in the FUTURE also counts as stale. A timezone change, an NTP
/// correction, or a tampered entry would otherwise pin the cache fresh
/// indefinitely, and "the app stopped checking for updates forever" is a much
/// worse failure than one extra check.
bool isStale(UpdateCacheState state, {required DateTime now}) {
  final last = state.lastCheckAt;
  if (last == null) return true;
  final elapsed = now.difference(last);
  if (elapsed.isNegative) return true;
  return elapsed >= kUpdateCheckTtl;
}

/// Typed store for the update-check cache over the [PrefsKv] seam — the
/// [BrowserSegmentStore]-shaped pattern under the `update.` keys.
class UpdateCacheStore {
  final PrefsKv _prefs;

  /// Creates the store over [prefs], defaulting to the real adapter. An
  /// in-memory implementation may be injected for tests — no plugin required.
  UpdateCacheStore({PrefsKv? prefs}) : _prefs = prefs ?? SharedPrefsKv();

  /// The persisted cache entry; [UpdateCacheState.neverChecked] when unset,
  /// unparseable, negative, or when the platform read THROWS.
  ///
  /// Never throws and never logs the absent case: an empty cache is the normal
  /// first run. Degrading to "never checked" is always safe, because the only
  /// thing it causes is one extra feed check.
  Future<UpdateCacheState> load() async {
    try {
      final storedMillis = await _prefs.getString(kUpdateLastCheckAtPrefsKey);
      final storedVersion =
          await _prefs.getString(kUpdateLastSeenVersionPrefsKey);

      final millis =
          storedMillis == null ? null : int.tryParse(storedMillis.trim());
      // A negative epoch (pre-1970) is not a check this app ever performed —
      // treat it as corrupt rather than as a very old check.
      final safeMillis = (millis == null || millis < 0) ? null : millis;

      // The seam has no delete, so an absent version is written as the empty
      // string; read it back as null so both spellings mean "unknown".
      final version = (storedVersion == null || storedVersion.isEmpty)
          ? null
          : storedVersion;

      // A version without a time is not a usable entry — a check that never
      // happened cannot have seen anything, so collapse it to the default.
      if (safeMillis == null) return const UpdateCacheState.neverChecked();

      return UpdateCacheState(
        lastCheckAtMillis: safeMillis,
        lastSeenVersion: version,
      );
    } on Object {
      return const UpdateCacheState.neverChecked();
    }
  }

  /// Persists [state]. Fire-and-forget, matching the seam — a failed write
  /// costs persistence only, never responsiveness, and the in-memory state the
  /// UI is already rendering is unaffected.
  ///
  /// Call this only after a SUCCESSFUL check: overwriting a good entry with a
  /// failure would blank the `Last checked` line, which is precisely the
  /// visible interruption D-07 and D-22 forbid.
  Future<void> save(UpdateCacheState state) async {
    await _prefs.setString(
      kUpdateLastCheckAtPrefsKey,
      '${state.lastCheckAtMillis ?? ''}',
    );
    await _prefs.setString(
      kUpdateLastSeenVersionPrefsKey,
      state.lastSeenVersion ?? '',
    );
  }
}

/// The [UpdateCacheStore] singleton (overridable in tests), following the
/// `browserSegmentStoreProvider` / `hapticsStoreProvider` convention.
final updateCacheStoreProvider = Provider<UpdateCacheStore>(
  (ref) => UpdateCacheStore(),
);
