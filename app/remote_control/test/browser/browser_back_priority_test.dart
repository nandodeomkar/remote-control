// The Browser route is the ONLY place in the app with two back handlers on one
// route, and this suite is the invariant that keeps them from both acting.
//
// 1. SUM-04 — the Android back gesture dismisses a raised surface before it
//    pops the screen. On Browser that ordering has a third rung: surface, then
//    bookmark folder, then route.
//
// 2. D-13-05 — STRICT one-thing-per-gesture. One back inside a bookmark folder
//    with a surface raised must lower the surface AND LEAVE THE FOLDER DEPTH
//    ALONE. Two things resolving on one gesture is the violation, and it is
//    exactly what happens if either handler acts unconditionally.
//
// 3. D-13-18 — the resolution must be PREDICATE-based, never order-based. Three
//    framework facts force it: both `onPopInvokedWithResult` callbacks on a
//    route fire whenever either `canPop` is false
//    (widgets/routes.dart:2044-2050); the registration container is an
//    unordered `Set` (routes.dart:1980) that re-registers on route changes; and
//    the callback also fires on a genuine pop (navigator.dart:5620). A
//    "consumed" latch set by whichever callback ran first is therefore
//    forbidden — it works today and breaks silently the moment a third handler
//    appears.
//
// 4. Case 3 pins the rebuild scope. The browser reads shell state through the
//    NON-SUBSCRIBING `SummonScope.ownsRaisedSurface`, so a raise must not
//    rebuild a screen the owner opens constantly — its tab list and its whole
//    bookmark tree.
//
// Settle-until-idle pumping appears here for NAVIGATION and for the raise/lower
// animations only; no assertion in this file is a geometry or timing
// assertion, so it cannot hide a wrong duration the way it would in
// `test/shell/summon_motion_test.dart`.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_protocol/remote_protocol.dart';

import 'package:remote_control/browser/bookmarks_store.dart';
import 'package:remote_control/browser/browser_screen.dart';
import 'package:remote_control/net/connection_service.dart';
import 'package:remote_control/shell/summon_back_guard.dart';
import 'package:remote_control/shell/summon_scope.dart';
import 'package:remote_control/shell/summon_surface.dart';

import '../shell/summon_test_harness.dart';

/// The shell harness's [RecordingService] plus the two snapshots the Browser
/// screen reads. Extending it rather than re-rolling a fake keeps the summon
/// wiring (`authed`, `chipStatus`) identical to every other shell suite.
class _BmService extends RecordingService {
  /// The parked bookmark tree.
  BookmarksSnapshot? parkedBm;

  /// The parked tab list.
  TabsSnapshot? parkedTabs;

  /// Every reliable message the screen sent, so a case can prove the folder
  /// walk stayed local (D-06 — nothing crosses the wire).
  final List<RemoteMessage> reliable = [];

  @override
  BookmarksSnapshot? get bookmarksSnapshot => parkedBm;

  @override
  TabsSnapshot? get tabsSnapshot => parkedTabs;

  @override
  void sendReliable(RemoteMessage msg) => reliable.add(msg);
}

/// One locked root holding two links — the smallest tree with a real subfolder
/// level, so `depth` moves 0 -> 1 on a single tap.
final BookmarksSnapshot _tree = BookmarksSnapshot(
  connected: true,
  truncated: false,
  nodes: const [
    BmNode(
      id: '1',
      parentId: '0',
      title: 'Bookmarks bar',
      folder: true,
      count: 2,
      locked: true,
    ),
    BmNode(id: '10', parentId: '1', title: 'Jira'),
    BmNode(id: '11', parentId: '1', title: 'Wiki'),
  ],
);

/// Counts rebuilds of the pushed route's subtree ABOVE the Browser screen.
/// Catches the regression where a later plan wraps the guarded content in a
/// `ValueListenableBuilder` over the raise notifier.
class _BuildCounter extends StatelessWidget {
  const _BuildCounter({required this.counts, required this.child});

  /// Single-cell counter, incremented on every build.
  final List<int> counts;

  /// The counted subtree.
  final Widget child;

  @override
  Widget build(BuildContext context) {
    counts[0]++;
    return child;
  }
}

/// Everything a case needs after the shell + pushed Browser route are up.
class _Pumped {
  _Pumped({required this.controller, required this.service, required this.counts});

  /// The app-scope summon controller, captured from the ROOT route before the
  /// push — an opaque route puts the root offstage and a default `Finder`
  /// cannot reach it afterwards (13-05's lesson).
  final SummonShellController controller;

  /// The recording service backing the screen.
  final _BmService service;

  /// The route-subtree build counter.
  final List<int> counts;
}

/// The current bookmark folder depth, read from the real notifier the screen
/// watches — a number, so "unchanged" can be asserted numerically instead of
/// inferred from which rows happen to be on screen.
int _depth(WidgetTester t) => ProviderScope.containerOf(
      t.element(find.byType(BrowserScreen)),
      listen: false,
    ).read(bookmarksStateProvider).depth;

/// The widget instance `BrowserScreen.build` returned. Identical across two
/// pumps means that build did not re-run — a build count, observed directly.
Scaffold _screenScaffold(WidgetTester t) => t.widget<Scaffold>(
      find
          .descendant(
            of: find.byType(BrowserScreen),
            matching: find.byType(Scaffold),
          )
          .first,
    );

/// Pumps the REAL shell over a guarded root, then pushes the Browser screen as
/// a guarded route — the production shape, not a stand-in.
Future<_Pumped> _pumpBrowserInShell(WidgetTester t) async {
  await t.binding.setSurfaceSize(const Size(800, 1600));
  addTearDown(() => t.binding.setSurfaceSize(null));

  final nav = GlobalKey<NavigatorState>();
  final service = _BmService()
    ..authed = true
    ..parkedBm = _tree
    ..parkedTabs = const TabsSnapshot(connected: true, tabs: [], groups: []);
  await pumpShell(t, nav: nav, service: service);

  final controller = SummonScope.of(contextOf(t, kHarnessRootText));
  final counts = <int>[0];

  unawaited(
    nav.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => SummonBackGuard(
          child: _BuildCounter(
            counts: counts,
            child: const BrowserScreen(),
          ),
        ),
      ),
    ),
  );
  await t.pumpAndSettle();
  await t.pump(); // the screen's post-frame primeList + async segment load

  return _Pumped(controller: controller, service: service, counts: counts);
}

/// Switches to the Bookmarks segment and drills one folder deep.
Future<void> _enterFolder(WidgetTester t) async {
  await t.tap(find.text(kSegmentBookmarksLabel));
  await t.pump();
  await t.pump();
  await t.tap(find.text('Bookmarks bar'));
  await t.pumpAndSettle();
}

/// Unmounts so the header chip's periodic ticker is cancelled (no pending timer
/// at teardown — the media_screen_test discipline).
Future<void> _unmount(WidgetTester t) => t.pumpWidget(const SizedBox());

void main() {
  setUp(installSummonTestPlatforms);

  group('one back gesture, one thing (SUM-04, D-13-05, D-13-18)', () {
    testWidgets(
        'case 1: in a folder with a surface raised — back lowers ONLY, then '
        'exits the folder, then pops the route', (t) async {
      final p = await _pumpBrowserInShell(t);
      await _enterFolder(t);

      final depthBefore = _depth(t);
      expect(depthBefore, 1, reason: 'the fixture must actually be in a folder');
      expect(find.text('Jira'), findsOneWidget);

      p.controller.raise(SummonSurfaceKind.trackpad);
      await t.pumpAndSettle();
      expect(find.byKey(kSummonSurfaceKey), findsOneWidget);
      expect(
        p.controller.raised.value?.ownerGuardId,
        isNotNull,
        reason: 'the pushed Browser route must OWN the raise, or the guard '
            'never intercepts and this case measures nothing',
      );

      // BACK 1 — the surface, and nothing else.
      expect(await t.binding.handlePopRoute(), isTrue,
          reason: 'the framework handled the gesture; Android must not exit');
      await t.pumpAndSettle();

      expect(p.controller.raised.value, isNull, reason: 'the surface lowered');
      expect(find.byKey(kSummonSurfaceKey), findsNothing);
      expect(
        _depth(t),
        depthBefore,
        reason: 'D-13-05: the folder depth must be UNCHANGED. A different '
            'number here is two things resolving on one gesture — the exact '
            'violation, and what happens if either handler acts '
            'unconditionally or the Set iteration order is assumed.',
      );
      expect(find.byType(BrowserScreen), findsOneWidget,
          reason: 'and the route did not pop either');

      // BACK 2 — now the folder.
      expect(await t.binding.handlePopRoute(), isTrue);
      await t.pumpAndSettle();

      expect(_depth(t), depthBefore - 1,
          reason: 'the bookmarks handler steps up exactly one level');
      expect(find.byType(BrowserScreen), findsOneWidget);
      expect(find.text('Bookmarks bar'), findsOneWidget);

      // BACK 3 — now the route.
      expect(await t.binding.handlePopRoute(), isTrue);
      await t.pumpAndSettle();

      expect(find.byType(BrowserScreen), findsNothing);
      expect(find.text(kHarnessRootText), findsOneWidget);

      await _unmount(t);
    });

    testWidgets(
        'case 2: in a folder with NOTHING raised — the first back steps up the '
        'folder', (t) async {
      final p = await _pumpBrowserInShell(t);
      await _enterFolder(t);

      expect(_depth(t), 1);
      expect(p.controller.raised.value, isNull,
          reason: 'the reverse configuration — nothing is up');

      expect(await t.binding.handlePopRoute(), isTrue);
      await t.pumpAndSettle();

      expect(
        _depth(t),
        0,
        reason: 'the guard clause must not have simply DISABLED the bookmarks '
            'handler — with no raised surface it still owns the gesture',
      );
      expect(find.byType(BrowserScreen), findsOneWidget);
      expect(
        p.service.reliable.whereType<BmOpenMsg>(),
        isEmpty,
        reason: 'the folder walk is local (D-06) — nothing crossed the wire',
      );

      await _unmount(t);
    });

    testWidgets(
        'case 3: the Browser screen does not rebuild when a surface is raised '
        'or lowered', (t) async {
      final p = await _pumpBrowserInShell(t);
      await _enterFolder(t);

      final countsBefore = p.counts[0];
      final scaffoldBefore = _screenScaffold(t);

      p.controller.raise(SummonSurfaceKind.trackpad);
      await t.pumpAndSettle();
      expect(find.byKey(kSummonSurfaceKey), findsOneWidget,
          reason: 'the raise must actually have happened, or the counts below '
              'are unchanged for the wrong reason');

      p.controller.lower();
      await t.pumpAndSettle();
      expect(find.byKey(kSummonSurfaceKey), findsNothing);

      expect(
        p.counts[0],
        countsBefore,
        reason: 'the pushed route subtree must stay off the summon rebuild '
            'path — a ValueListenableBuilder wrapped around the guarded '
            'content would move this number',
      );
      expect(
        identical(_screenScaffold(t), scaffoldBefore),
        isTrue,
        reason: 'BrowserScreen.build did not re-run. The non-subscribing '
            'lookup is what keeps a screen the owner opens constantly — its '
            'tab list and its whole bookmark tree — off the summon rebuild '
            'path.',
      );

      await _unmount(t);
    });
  });
}
