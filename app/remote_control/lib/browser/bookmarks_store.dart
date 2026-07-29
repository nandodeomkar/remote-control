/// The Bookmarks store (BROW, protoVersion 1.6) — the Riverpod-3 notifier
/// that turns the pushed [BookmarksSnapshot] into a value-equal view the
/// Browser screen's bookmarks section renders.
///
/// Clones the [TabsNotifier] shape (subscribe to `service.changes`,
/// re-snapshot `service.bookmarksSnapshot` into a value-equal state, expose
/// the commands over `sendReliable`) and adds the one thing no other store in
/// `lib/` has: LOCAL folder navigation. D-06 says the phone navigates the tree
/// itself, so drilling in and backing out send nothing on the wire, and the
/// position lives on the notifier — not in the snapshot — so a pushed
/// `bm.changed` cannot reset it (D-04: several bookmarks opened in a row from
/// a nested folder).
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:remote_protocol/remote_protocol.dart';

import '../net/connection_providers.dart';
import '../net/connection_service.dart';

/// Immutable, value-equal view of the bookmarks section: extension
/// connectivity + the flat node list + where the user currently is in the
/// tree. Value-equality lets the notifier skip no-op rebuilds on `changes`
/// pings that don't alter the visible state (house pattern — mirrors
/// [TabsViewState]).
class BookmarksViewState {
  /// Whether the Tab Bridge extension is connected on the PC — `false`
  /// renders the SHARED install hint (the same card the Tabs segment shows).
  final bool connected;

  /// The flat snapshot in wire order (breadth-first, extension order). The
  /// display ordering lives in [childrenByParent], not here.
  final List<BmNode> nodes;

  /// Snapshot-level truncation: nodes were dropped from the tail of the whole
  /// tree. Per-folder truncation is [currentFolderTruncated].
  final bool truncated;

  /// Where the user is. `'0'` is the VIRTUAL root (D-08) — it is never a real
  /// node, it is simply the `parentId` every Chrome root carries, which is why
  /// listing its children lists all the roots.
  final String currentFolderId;

  /// The folder ids to pop back through, oldest first. Empty at the root.
  final List<String> backStack;

  /// Parent id → its children, folders first then links, each kind preserving
  /// wire order. Derived from [nodes] in one pass per snapshot.
  final Map<String, List<BmNode>> childrenByParent;

  /// Creates a view snapshot.
  const BookmarksViewState({
    required this.connected,
    required this.nodes,
    required this.truncated,
    required this.currentFolderId,
    required this.backStack,
    required this.childrenByParent,
  });

  /// The rows the current folder renders (folders first, then links).
  List<BmNode> get currentChildren => childrenByParent[currentFolderId] ?? const [];

  /// The title of the folder the user is inside, or `null` at the virtual
  /// root — depth 0 renders no folder bar, the segment label already says
  /// `Bookmarks`.
  String? get currentFolderTitle {
    if (currentFolderId == '0') return null;
    for (final n in nodes) {
      if (n.id == currentFolderId) return n.title;
    }
    return null;
  }

  /// How deep the local navigation is; `0` at the roots level.
  int get depth => backStack.length;

  /// Whether the CURRENT folder's own children were dropped by the
  /// extension's byte budget (the inline "Some bookmarks here aren't shown."
  /// line). Always `false` at the virtual root, which is not a real node.
  bool get currentFolderTruncated {
    if (currentFolderId == '0') return false;
    for (final n in nodes) {
      if (n.id == currentFolderId) return n.truncated == true;
    }
    return false;
  }

  /// Whether any current child may be deleted — a link, or a folder with
  /// `count == 0`, and in both cases not `locked` (D-13/D-14). Drives the
  /// long-press discoverability hint: no deletable child, no hint.
  bool get hasDeletableChild {
    for (final n in currentChildren) {
      if (isDeletable(n)) return true;
    }
    return false;
  }

  /// Whether [node] may be offered the long-press delete affordance: never a
  /// locked (managed) node, never a non-empty folder — Chrome itself rejects
  /// the latter with `kFolderNotEmptyError`, and `removeTree` is never called
  /// anywhere in this app. A folder with no `count` is treated as non-empty
  /// (the conservative read).
  static bool isDeletable(BmNode node) {
    if (node.locked == true) return false;
    if (node.folder == true) return node.count == 0;
    return true;
  }

  @override
  bool operator ==(Object other) {
    if (other is! BookmarksViewState) return false;
    if (other.connected != connected) return false;
    if (other.truncated != truncated) return false;
    // Nav state is part of identity: without it a drill-down that happens to
    // land on an equal node list would produce no rebuild.
    if (other.currentFolderId != currentFolderId) return false;
    if (other.backStack.length != backStack.length) return false;
    for (var i = 0; i < backStack.length; i++) {
      if (other.backStack[i] != backStack[i]) return false;
    }
    if (other.nodes.length != nodes.length) return false;
    for (var i = 0; i < nodes.length; i++) {
      if (other.nodes[i] != nodes[i]) return false;
    }
    // childrenByParent is DERIVED from nodes (same input, same index), so it
    // is deliberately excluded from == and hashCode — comparing it would be
    // redundant work on every ping.
    return true;
  }

  @override
  int get hashCode => Object.hash(
        connected,
        truncated,
        currentFolderId,
        Object.hashAll(backStack),
        Object.hashAll(nodes),
      );
}

/// Re-snapshots [BookmarksViewState] on every service `changes` ping, owns the
/// local folder navigation, and drives the
/// primeList/enterFolder/goBack/open/remove commands ([TabsNotifier] clone
/// plus the nav state).
class BookmarksNotifier extends Notifier<BookmarksViewState> {
  StreamSubscription<void>? _sub;
  late final ConnectionService _service;

  /// Notifier-owned so a pushed snapshot cannot reset the user's position
  /// (D-04). `'0'` is the virtual root (D-08).
  String _currentFolderId = '0';

  /// Folder ids to pop back through, oldest first — also notifier-owned.
  final List<String> _backStack = [];

  @override
  BookmarksViewState build() {
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

  BookmarksViewState _view() {
    final snapshot = _service.bookmarksSnapshot;
    final nodes = snapshot?.nodes ?? const <BmNode>[];

    // Stale-folder self-heal: the folder the user is standing in vanished from
    // the new snapshot (deleted on the PC, or dropped by truncation). Fall
    // back to the root level SILENTLY — no toast, no dialog; the whole
    // bookmarks surface is fire-and-forget and self-healing.
    if (_currentFolderId != '0' && !nodes.any((n) => n.id == _currentFolderId)) {
      _currentFolderId = '0';
      _backStack.clear();
    }

    // One pass to bucket by parent (wire order preserved inside each bucket).
    final buckets = <String, List<BmNode>>{};
    for (final n in nodes) {
      (buckets[n.parentId] ??= <BmNode>[]).add(n);
    }
    // Then a STABLE partition per bucket: folders first, links after, each
    // kind keeping its wire order (the extension emits BFS, which preserves
    // Chrome's own per-parent index order). A comparator could reorder equal
    // elements; a partition cannot.
    final index = <String, List<BmNode>>{};
    buckets.forEach((parentId, bucket) {
      final folders = <BmNode>[];
      final links = <BmNode>[];
      for (final n in bucket) {
        if (n.folder == true) {
          folders.add(n);
        } else {
          links.add(n);
        }
      }
      index[parentId] = List<BmNode>.unmodifiable([...folders, ...links]);
    });

    return BookmarksViewState(
      connected: snapshot?.connected ?? false,
      nodes: nodes,
      truncated: snapshot?.truncated ?? false,
      currentFolderId: _currentFolderId,
      // Copies, never the notifier's own mutable containers — a state value
      // that aliased them could never compare unequal to its successor.
      backStack: List<String>.unmodifiable(_backStack),
      childrenByParent: Map<String, List<BmNode>>.unmodifiable(index),
    );
  }

  /// Primes the bookmark tree once on first Bookmarks-segment display (D-03).
  /// `bm.changed` has no after-auth snapshot, so this pull is the only way to
  /// get the first tree — and its reply also carries the connected:false hint
  /// state when the extension was never up.
  void primeList() => _service.sendReliable(const BmListMsg());

  /// Drill into folder [id] — LOCAL only, nothing crosses the wire (D-06).
  void enterFolder(String id) {
    _backStack.add(_currentFolderId);
    _currentFolderId = id;
    state = _view();
  }

  /// Pop one folder level. Returns `false` when already at the root, which is
  /// the screen's signal to let `PopScope` leave the route instead.
  bool goBack() {
    if (_backStack.isEmpty) return false;
    _currentFolderId = _backStack.removeLast();
    state = _view();
    return true;
  }

  /// Open bookmark [nodeId] in a new PC tab (`bm.open`, fire-and-forget; a
  /// stale id self-heals on the next `bm.changed`). Deliberately does NOT
  /// change the current folder and does NOT touch the segment — D-04 wants
  /// several bookmarks opened in a row with zero position loss.
  void open(String nodeId) => _service.sendReliable(BmOpenMsg(nodeId: nodeId));

  /// Remove ONE bookmark or ONE empty folder ([nodeId], `bm.remove`). There is
  /// no bulk and no recursive form anywhere — a subtree wipe from the phone is
  /// structurally impossible (D-14, T-11-04). The confirm gate lives in the
  /// widget layer; this store opens no UI.
  void remove(String nodeId) =>
      _service.sendReliable(BmRemoveMsg(nodeId: nodeId));
}

/// The bookmarks-section view state the Browser screen watches.
final bookmarksStateProvider =
    NotifierProvider<BookmarksNotifier, BookmarksViewState>(
        BookmarksNotifier.new);
