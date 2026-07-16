/// The Tabs store (BROW-01, proto 1.4) — the Riverpod-3 notifier that turns
/// the pushed [TabsSnapshot] into a value-equal view the Browser screen's tab
/// section renders.
///
/// Clones the [AppsNotifier] shape minus favorites: subscribe to
/// `service.changes`, re-snapshot `service.tabsSnapshot` into a value-equal
/// [TabsViewState], and expose the primeList/activate/close commands over
/// `sendReliable`.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:remote_protocol/remote_protocol.dart';

import '../net/connection_providers.dart';
import '../net/connection_service.dart';

/// Immutable, value-equal view of the tab section: extension connectivity +
/// the live tab list (extension order — no client sort). Value-equality lets
/// the notifier skip no-op rebuilds on `changes` pings that don't alter the
/// visible state (house pattern — mirrors AppsViewState).
class TabsViewState {
  /// Whether the Tab Bridge extension is connected on the PC — `false`
  /// renders the install hint (locked fallback).
  final bool connected;

  /// Tabs in extension order (windowId then index, resolved extension-side).
  final List<TabInfo> tabs;

  /// Creates a view snapshot.
  const TabsViewState({required this.connected, required this.tabs});

  @override
  bool operator ==(Object other) {
    if (other is! TabsViewState) return false;
    if (other.connected != connected) return false;
    if (other.tabs.length != tabs.length) return false;
    for (var i = 0; i < tabs.length; i++) {
      if (other.tabs[i] != tabs[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(connected, Object.hashAll(tabs));
}

/// Re-snapshots [TabsViewState] on every service `changes` ping and drives
/// the primeList/activate/close commands (AppsNotifier clone minus
/// favorites).
class TabsNotifier extends Notifier<TabsViewState> {
  StreamSubscription<void>? _sub;
  late final ConnectionService _service;

  @override
  TabsViewState build() {
    _service = ref.watch(connectionServiceProvider);
    _sub?.cancel();
    _sub = _service.changes.listen((_) => _onChange());
    ref.onDispose(() {
      _sub?.cancel();
      _sub = null;
    });
    return _view();
  }

  void _onChange() {
    state = _view();
  }

  TabsViewState _view() {
    final snapshot = _service.tabsSnapshot;
    return TabsViewState(
      connected: snapshot?.connected ?? false,
      tabs: snapshot?.tabs ?? const [],
    );
  }

  /// Primes the tab list once on screen open (tabs.changed has NO after-auth
  /// snapshot — the same pull-on-open contract as apps; the reply also
  /// returns the connected:false hint state when the extension was never up).
  void primeList() => _service.sendReliable(const TabsListMsg());

  /// Switch the PC browser to tab [id] (`tabs.activate{id}` —
  /// fire-and-forget; a stale id self-heals on the next tabs.changed).
  void activate(int id) => _service.sendReliable(TabsActivateMsg(id: id));

  /// Close tab [id] (`tabs.close{id}`, fire-and-forget).
  void close(int id) => _service.sendReliable(TabsCloseMsg(id: id));
}

/// The tab-section view state the Browser screen watches.
final tabsStateProvider =
    NotifierProvider<TabsNotifier, TabsViewState>(TabsNotifier.new);
