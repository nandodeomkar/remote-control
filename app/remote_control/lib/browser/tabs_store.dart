/// The Tabs store (BROW-01, proto 1.4; groups proto 1.5, quick 260716-sme)
/// — the Riverpod-3 notifier that turns the pushed [TabsSnapshot] into a
/// value-equal view the Browser screen's tab section renders.
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

  /// Tab groups (proto 1.5) — empty when none exist or the server predates
  /// groups. View-only display metadata.
  final List<GroupInfo> groups;

  /// D-12 optimistic star overlay, keyed by tab id: the flip the user just
  /// made, rendered ahead of the PC agreeing. Cleared wholesale by the NEXT
  /// authoritative snapshot, whether or not that snapshot agrees.
  final Map<int, bool> optimisticStars;

  /// Creates a view snapshot.
  const TabsViewState({
    required this.connected,
    required this.tabs,
    required this.groups,
    this.optimisticStars = const {},
  });

  /// The star state to RENDER for [tab]: the optimistic flip if one is
  /// pending, otherwise the authoritative [TabInfo.bookmarked].
  ///
  /// `null` is a THIRD state, not a false: it means UNKNOWN (a server or
  /// extension that never reported one), and the widget layer renders NO star
  /// slot at all rather than an empty star, which would be a false negative
  /// (D-11, T-11-01).
  bool? bookmarkedFor(TabInfo tab) => optimisticStars[tab.id] ?? tab.bookmarked;

  @override
  bool operator ==(Object other) {
    if (other is! TabsViewState) return false;
    if (other.connected != connected) return false;
    if (other.optimisticStars.length != optimisticStars.length) return false;
    for (final entry in optimisticStars.entries) {
      if (other.optimisticStars[entry.key] != entry.value) return false;
    }
    if (other.tabs.length != tabs.length) return false;
    for (var i = 0; i < tabs.length; i++) {
      if (other.tabs[i] != tabs[i]) return false;
    }
    if (other.groups.length != groups.length) return false;
    for (var i = 0; i < groups.length; i++) {
      if (other.groups[i] != groups[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(
        connected,
        Object.hashAll(tabs),
        Object.hashAll(groups),
        // Order-independent so two equal overlays built in different insertion
        // orders still hash alike.
        Object.hashAllUnordered(
          optimisticStars.entries.map((e) => Object.hash(e.key, e.value)),
        ),
      );
}

/// Re-snapshots [TabsViewState] on every service `changes` ping and drives
/// the primeList/activate/close commands (AppsNotifier clone minus
/// favorites).
class TabsNotifier extends Notifier<TabsViewState> {
  StreamSubscription<void>? _sub;
  late final ConnectionService _service;

  /// D-12 pending star flips, keyed by tab id. Notifier-owned and mutable;
  /// only an unmodifiable COPY ever reaches the state.
  final Map<int, bool> _optimistic = {};

  /// The snapshot object the overlay was last reconciled against — tracked by
  /// IDENTITY, see [_onChange].
  TabsSnapshot? _lastSnapshot;

  @override
  TabsViewState build() {
    _service = ref.watch(connectionServiceProvider);
    _optimistic.clear();
    _lastSnapshot = null;
    _sub?.cancel();
    _sub = _service.changes.listen((_) => _onChange());
    ref.onDispose(() {
      _sub?.cancel();
      _sub = null;
    });
    return _view();
  }

  void _onChange() {
    // Reconcile the D-12 overlay on IDENTITY, not value equality.
    //
    // ConnectionService constructs a BRAND-NEW TabsSnapshot on every
    // `tabs.changed` and every `tabs.list` reply, so an identity change is
    // exactly "a new authoritative snapshot arrived" — even when the new
    // snapshot is value-equal to the old one. (Same identity-tracking
    // precedent as 06-05's clipFetchReply.)
    //
    // Value equality would be wrong twice over: an optimistic bit would stay
    // alive across a snapshot that DISAGREES with it, and `changes` also fires
    // for volume, apps and clipboard pings — clearing on every ping would
    // defeat the optimism entirely.
    final snapshot = _service.tabsSnapshot;
    if (!identical(snapshot, _lastSnapshot)) {
      _lastSnapshot = snapshot;
      _optimistic.clear();
    }
    state = _view();
  }

  TabsViewState _view() {
    final snapshot = _service.tabsSnapshot;
    return TabsViewState(
      connected: snapshot?.connected ?? false,
      tabs: snapshot?.tabs ?? const [],
      groups: snapshot?.groups ?? const [],
      // A COPY — passing the mutable field itself would alias the notifier's
      // map into the state, and a later flip could never compare unequal.
      optimisticStars: Map<int, bool>.unmodifiable(_optimistic),
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

  /// Bookmark tab [tabId]'s URL (`bm.star`, D-10/D-12). Flips the rendered
  /// star FIRST so the tap is instant, then sends — the extension resolves
  /// the URL locally, none of it crosses the wire.
  void star(int tabId) {
    _optimistic[tabId] = true;
    state = _view();
    _service.sendReliable(BmStarMsg(tabId: tabId));
  }

  /// Remove every bookmark matching tab [tabId]'s URL (`bm.unstar`, D-11).
  /// Same flip-then-send order. Opens NO dialog — the destructive confirm gate
  /// lives in the widget layer and this is only ever called after it resolves
  /// (T-11-06).
  void unstar(int tabId) {
    _optimistic[tabId] = false;
    state = _view();
    _service.sendReliable(BmUnstarMsg(tabId: tabId));
  }
}

/// The tab-section view state the Browser screen watches.
final tabsStateProvider =
    NotifierProvider<TabsNotifier, TabsViewState>(TabsNotifier.new);
