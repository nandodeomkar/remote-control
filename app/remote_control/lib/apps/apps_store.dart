/// The Apps store (APPS-01/02/03, D-01/D-02) — the client-side favorites
/// persistence plus the Riverpod-3 notifier that turns the pushed
/// [AppsSnapshot] into a value-equal view the Apps screen renders.
///
/// TWO layers, mirroring the house split (pure persistence + a thin Notifier):
///
/// 1. [FavoritesStore] is a pure, [PrefsKv]-backed store (non-secrets only —
///    D-02 house rule, NEVER SecureKv). Favorites are pinned ONLY from a
///    running window's server-resolved [WindowInfo.path] (T-06-04: the client
///    never originates an arbitrary launch path); a UWP window (path==null) is
///    non-pinnable (Flag 1). Load/save is corruption-tolerant (`try/on Object`
///    degrade to empty, never throws — device_store discipline).
///
/// 2. [AppsNotifier] clones [VolumeNotifier]: it subscribes to
///    `service.changes`, re-snapshots `service.appsSnapshot` + the loaded
///    favorites into a value-equal [AppsViewState], and exposes focus/close/
///    launch (via `sendReliable`) + pin/unpin (via the store) commands.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:remote_protocol/remote_protocol.dart';

import '../net/connection_providers.dart';
import '../net/connection_service.dart';
import '../store/device_store.dart';

/// A pinned favorite app: a display [name], the server-resolved [path] used to
/// relaunch it (`apps.launch{path}`), and an optional base64 PNG [icon] cached
/// at pin time so relaunch needs no live window.
class Favorite {
  /// Display name (the window title at pin time).
  final String name;

  /// Server-resolved executable path (the launch target — never client-typed).
  final String path;

  /// Base64 PNG icon cached at pin time, or null.
  final String? icon;

  /// Creates a favorite.
  const Favorite({required this.name, required this.path, this.icon});

  /// Canonical JSON form: `{name, path, icon?}` (icon only when non-null).
  Map<String, Object?> toJson() => {
        'name': name,
        'path': path,
        if (icon != null) 'icon': icon,
      };

  /// Deserializes one favorites-list entry.
  factory Favorite.fromJson(Map<String, Object?> json) => Favorite(
        name: json['name']! as String,
        path: json['path']! as String,
        icon: json['icon'] as String?,
      );

  @override
  bool operator ==(Object other) =>
      other is Favorite &&
      other.name == name &&
      other.path == path &&
      other.icon == icon;

  @override
  int get hashCode => Object.hash(name, path, icon);
}

/// [PrefsKv]-backed favorites persistence (key `apps.favorites`, JSON list
/// `[{name, path, icon?}]`). Non-secret → PrefsKv ONLY (D-02, T-06-15).
class FavoritesStore {
  /// The prefs key holding the JSON favorites list.
  static const String prefsKey = 'apps.favorites';

  final PrefsKv _prefs;

  /// Creates a store over an injected [PrefsKv] (fakes in tests).
  FavoritesStore({required PrefsKv prefs})
      : _prefs = prefs; // ignore: prefer_initializing_formals

  /// All persisted favorites in stored order (empty when none or on corrupt
  /// data). Total by construction: a corrupt blob OR a corrupt row degrades to
  /// skipping rather than throwing (device_store posture, T-06-15).
  Future<List<Favorite>> load() async {
    final json = await _prefs.getString(prefsKey);
    if (json == null) return <Favorite>[];
    try {
      final raw = jsonDecode(json) as List;
      final out = <Favorite>[];
      for (final e in raw) {
        try {
          out.add(Favorite.fromJson((e as Map).cast<String, Object?>()));
        } on Object {
          // Skip a corrupt/incomplete row — never fail the whole load.
        }
      }
      return out;
    } on Object {
      // Corrupt top-level blob: degrade to "no favorites".
      return <Favorite>[];
    }
  }

  /// Pins [window] as a favorite. Rejected (returns false, no-op) when
  /// `window.path == null` — a UWP window is non-pinnable (Flag 1, D-01).
  /// Dedupes by path: pinning an already-pinned path is a no-op success.
  Future<bool> pin(WindowInfo window) async {
    final path = window.path;
    if (path == null) return false; // UWP non-pinnable (D-01/D-02)
    final favs = await load();
    if (favs.any((f) => f.path == path)) return true; // dedupe by path
    favs.add(Favorite(name: window.title, path: path, icon: window.icon));
    await _save(favs);
    return true;
  }

  /// Removes the favorite whose path equals [path] (no-op when absent).
  Future<void> unpin(String path) async {
    final favs = await load();
    favs.removeWhere((f) => f.path == path);
    await _save(favs);
  }

  Future<void> _save(List<Favorite> favs) => _prefs.setString(
        prefsKey,
        jsonEncode(favs.map((f) => f.toJson()).toList()),
      );
}

/// Immutable, value-equal view of the Apps screen state: the live open-window
/// list (server order, D-07) + the persisted favorites. Value-equality lets
/// the notifier skip no-op rebuilds on `changes` pings that don't alter the
/// visible state (house pattern — mirrors [VolumeViewState]).
class AppsViewState {
  /// Open windows in server Z-order (no client sort — D-07).
  final List<WindowInfo> windows;

  /// Persisted favorites (client-side, D-02).
  final List<Favorite> favorites;

  /// Creates a view snapshot.
  const AppsViewState({required this.windows, required this.favorites});

  @override
  bool operator ==(Object other) =>
      other is AppsViewState &&
      _listEq(other.windows, windows) &&
      _listEq(other.favorites, favorites);

  @override
  int get hashCode => Object.hash(Object.hashAll(windows), Object.hashAll(favorites));

  static bool _listEq<T>(List<T> a, List<T> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// Re-snapshots [AppsViewState] on every service `changes` ping and drives the
/// pin/unpin/focus/close/launch commands. Clones [VolumeNotifier]'s
/// subscribe-and-snapshot shape; adds the D-01/D-02 favorites plumbing.
class AppsNotifier extends Notifier<AppsViewState> {
  StreamSubscription<void>? _sub;
  late final ConnectionService _service;
  late final FavoritesStore _store;
  List<Favorite> _favorites = const [];

  @override
  AppsViewState build() {
    _service = ref.watch(connectionServiceProvider);
    _store = ref.watch(favoritesStoreProvider);
    _sub?.cancel();
    _sub = _service.changes.listen((_) => _onChange());
    ref.onDispose(() {
      _sub?.cancel();
      _sub = null;
    });
    unawaited(_loadFavorites()); // async prime — publishes when loaded
    return _view();
  }

  Future<void> _loadFavorites() async {
    _favorites = await _store.load();
    state = _view();
  }

  void _onChange() {
    state = _view();
  }

  AppsViewState _view() => AppsViewState(
        windows: _service.appsSnapshot?.windows ?? const [],
        favorites: _favorites,
      );

  /// The last server `err` frame (windowGone / launchFailed), or null. Screens
  /// surface it as a transient toast.
  ErrMsg? get lastError => _service.lastError;

  /// Primes the open-windows list once on screen open (apps.changed has no
  /// after-auth snapshot — the client pulls via apps.list, 06-01 decision).
  void primeList() => _service.sendReliable(const AppsListMsg());

  /// Focus a window (`apps.focus{id}`); failure returns as err → toast.
  void focus(int id) => _service.sendReliable(AppsFocusMsg(id: id));

  /// Close a window (`apps.close{id}`, graceful WM_CLOSE).
  void close(int id) => _service.sendReliable(AppsCloseMsg(id: id));

  /// Launch a favorite by its server-resolved path (`apps.launch{path}`).
  void launch(Favorite fav) =>
      _service.sendReliable(AppsLaunchMsg(path: fav.path));

  /// Pins [window] to favorites (D-01). Returns false when non-pinnable
  /// (UWP, path==null) so the screen can raise the non-pinnable toast.
  Future<bool> pin(WindowInfo window) async {
    final ok = await _store.pin(window);
    if (ok) {
      _favorites = await _store.load();
      state = _view();
    }
    return ok;
  }

  /// Unpins the favorite whose path equals [path] and refreshes state.
  Future<void> unpin(String path) async {
    await _store.unpin(path);
    _favorites = await _store.load();
    state = _view();
  }
}

/// The favorites store over real (non-secret) shared_preferences (D-02).
final favoritesStoreProvider = Provider<FavoritesStore>(
  (ref) => FavoritesStore(prefs: SharedPrefsKv()),
);

/// The Apps view state the Apps screen watches (favorites + open windows).
final appsStateProvider =
    NotifierProvider<AppsNotifier, AppsViewState>(AppsNotifier.new);
