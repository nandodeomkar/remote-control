// Task 1 (05-02) — RED: the browser macro vocabulary + grid (BROW-01).
// Task 4 (260716-oi2) — the tab section on the full BrowserScreen (proto
// 1.4): hint card / empty state / rows, activate on tap-down, close on
// swipe + long-press, ChipStatus.connected gating, favicon fallback.
//
// House widget-test style (mouse_buttons_test.dart): pump the callback-taking
// grid widget with a recording onAction — no service fake needed. The action
// strings must byte-match the server router's browser_macro table
// (server-core/src/dispatch/router.rs): back, forward, newtab, closetab,
// refresh, zoomin, zoomout — unknown actions are silently dropped server-side,
// so any drift here is an invisible no-op in production.
//
// The screen-level tab-section tests pump the full BrowserScreen under a
// ProviderScope overriding connectionServiceProvider with a recording fake
// (the media_screen_test seam).

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_protocol/remote_protocol.dart';

import 'package:remote_control/browser/bookmark_confirm.dart';
import 'package:remote_control/browser/browser_screen.dart';
import 'package:remote_control/browser/browser_segment.dart';
import 'package:remote_control/net/connection_providers.dart';
import 'package:remote_control/net/connection_service.dart';
import 'package:remote_control/store/device_store.dart';
import 'package:remote_control/theme/tokens.dart';

/// The exact router vocabulary (router.rs `browser_macro`).
const Set<String> kRouterBrowserVocabulary = {
  'back',
  'forward',
  'newtab',
  'closetab',
  'refresh',
  'zoomin',
  'zoomout',
};

Widget host({
  required void Function(String action) onAction,
  required bool enabled,
}) {
  return MaterialApp(
    home: Scaffold(
      body: BrowserMacroGrid(onAction: onAction, enabled: enabled),
    ),
  );
}

// -- Task 4 (260716-oi2) screen-level harness --------------------------------

class _FakeSecureKv implements SecureKv {
  final Map<String, String> backing = {};

  @override
  Future<String?> read(String key) async => backing[key];

  @override
  Future<void> write(String key, String value) async => backing[key] = value;

  @override
  Future<void> delete(String key) async => backing.remove(key);
}

class _FakePrefsKv implements PrefsKv {
  final Map<String, String> backing = {};

  @override
  Future<String?> getString(String key) async => backing[key];

  @override
  Future<void> setString(String key, String value) async {
    backing[key] = value;
  }
}

/// Recording fake (media_screen_test seam): mutable chip status, a parked
/// [TabsSnapshot], and every [sendReliable] message recorded.
class _FakeService extends ConnectionService {
  _FakeService({this.chip = ChipStatus.connected})
      : super(
          store: DeviceStore(secure: _FakeSecureKv(), prefs: _FakePrefsKv()),
        );

  final List<RemoteMessage> reliable = [];
  ChipStatus chip;
  TabsSnapshot? parked;
  BookmarksSnapshot? parkedBm;

  @override
  ChipStatus get chipStatus => chip;

  @override
  bool get isAuthed => chip == ChipStatus.connected;

  @override
  TabsSnapshot? get tabsSnapshot => parked;

  @override
  BookmarksSnapshot? get bookmarksSnapshot => parkedBm;

  @override
  void sendReliable(RemoteMessage msg) => reliable.add(msg);
}

/// Recording segment store (the `keyboard_screen_test` seam): `load` returns
/// [initial] and every `save` is recorded. Extends the real store over a fake
/// [PrefsKv] so no `SharedPreferencesAsync` platform instance is ever needed —
/// the screen watches `browserSegmentStoreProvider` on EVERY mount now, so the
/// override belongs in the shared harness, not in individual tests.
class _FakeSegmentStore extends BrowserSegmentStore {
  _FakeSegmentStore({this.initial = BrowserSegment.tabs})
      : super(prefs: _FakePrefsKv());

  /// What `load()` resolves to (the "restored from prefs" seam).
  final BrowserSegment initial;

  /// Every persisted selection, in order.
  final List<BrowserSegment> saved = [];

  @override
  Future<BrowserSegment> load() async => initial;

  @override
  Future<void> save(BrowserSegment segment) async => saved.add(segment);
}

/// Pumps the full BrowserScreen over [service] on a tall surface (the tab
/// rows + the whole macro grid must be on-screen for taps) and runs the
/// post-frame primeList.
Future<void> _pumpScreen(
  WidgetTester t,
  _FakeService service, {
  _FakeSegmentStore? store,
}) async {
  await t.binding.setSurfaceSize(const Size(800, 1600));
  addTearDown(() => t.binding.setSurfaceSize(null));
  await t.pumpWidget(
    ProviderScope(
      overrides: [
        connectionServiceProvider.overrideWith((ref) => service),
        browserSegmentStoreProvider.overrideWithValue(
          store ?? _FakeSegmentStore(),
        ),
      ],
      child: const MaterialApp(home: BrowserScreen()),
    ),
  );
  await t.pump(); // post-frame primeList + the async segment load
}

/// Unmounts the screen so the header chip's periodic ticker is cancelled
/// (no pending timer at teardown — the media_screen_test discipline).
Future<void> _unmount(WidgetTester t) => t.pumpWidget(const SizedBox());

const TabsSnapshot _twoTabs = TabsSnapshot(
  connected: true,
  tabs: [
    TabInfo(id: 7, title: 'GitHub', active: true),
    TabInfo(id: 9, title: 'Docs', active: false),
  ],
  groups: [],
);

/// One blue "Work" group owning two tabs + one ungrouped tab (proto 1.5,
/// 260716-sme) — drives the group-header rendering assertions.
const TabsSnapshot _groupedTabs = TabsSnapshot(
  connected: true,
  tabs: [
    TabInfo(id: 7, title: 'GitHub', active: true, groupId: 1),
    TabInfo(id: 8, title: 'PRs', active: false, groupId: 1),
    TabInfo(id: 9, title: 'Docs', active: false),
  ],
  groups: [
    GroupInfo(id: 1, title: 'Work', color: 'blue', collapsed: false),
  ],
);

/// Two adjacent single-tab groups (260729-58x) — the run-boundary fixture:
/// each group must render as its OWN block, so the two tints differing is the
/// proof that the chunker split the runs instead of merging them.
const TabsSnapshot _twoGroups = TabsSnapshot(
  connected: true,
  tabs: [
    TabInfo(id: 7, title: 'GitHub', active: true, groupId: 1),
    TabInfo(id: 8, title: 'PRs', active: false, groupId: 2),
  ],
  groups: [
    GroupInfo(id: 1, title: 'Work', color: 'blue', collapsed: false),
    GroupInfo(id: 2, title: 'Play', color: 'green', collapsed: false),
  ],
);

/// The D-11 tri-state star fixture: one bookmarked tab, one explicitly not
/// bookmarked, and one whose state was never reported — `bookmarked: null`
/// means UNKNOWN, which is a THIRD state and not a `false`.
const TabsSnapshot _triStateTabs = TabsSnapshot(
  connected: true,
  tabs: [
    TabInfo(id: 7, title: 'Starred', active: true, bookmarked: true),
    TabInfo(id: 8, title: 'Plain', active: false, bookmarked: false),
    TabInfo(id: 9, title: 'Unknown', active: false),
  ],
  groups: [],
);

/// Three Chrome roots (D-08). `Bookmarks bar` holds one subfolder plus twenty
/// links, so the Bookmarks segment's scroll region is FAR taller than the
/// two-tab list — which is exactly the height difference that would have moved
/// the macro grid under the old single-`SingleChildScrollView` layout, and is
/// therefore what makes the D-02 rect-equality assertion meaningful.
final BookmarksSnapshot _bmTree = BookmarksSnapshot(
  connected: true,
  truncated: false,
  nodes: [
    // Roots arrive locked (managed by Chrome) — no delete affordance.
    const BmNode(
      id: '1',
      parentId: '0',
      title: 'Bookmarks bar',
      folder: true,
      count: 21,
      locked: true,
    ),
    const BmNode(
      id: '2',
      parentId: '0',
      title: 'Other bookmarks',
      folder: true,
      count: 0,
      locked: true,
    ),
    const BmNode(
      id: '3',
      parentId: '0',
      title: 'Mobile bookmarks',
      folder: true,
      count: 0,
      locked: true,
    ),
    const BmNode(
      id: '10',
      parentId: '1',
      title: 'Work',
      folder: true,
      count: 2,
    ),
    for (var i = 0; i < 20; i++)
      BmNode(id: 'b$i', parentId: '1', title: 'Link $i'),
    const BmNode(id: '20', parentId: '10', title: 'Jira'),
    const BmNode(id: '21', parentId: '10', title: 'Wiki'),
  ],
);

/// The screen's back-interception state, read straight off its `PopScope`:
/// `canPop == false` is the frame in which Android back pops a folder level
/// instead of the route.
Finder _popScope({required bool canPop}) =>
    find.byWidgetPredicate((w) => w is PopScope && w.canPop == canPop);

/// Taps a segment button and settles the rebuild.
Future<void> _selectSegment(WidgetTester t, String label) async {
  await t.tap(find.text(label));
  await t.pump();
  await t.pump();
}

/// The row-chrome border color: the nearest Material ancestor's shape side.
Color _rowBorder(WidgetTester t, String title) {
  final material = t.widget<Material>(
    find.ancestor(of: find.text(title), matching: find.byType(Material)).first,
  );
  final shape = material.shape! as RoundedRectangleBorder;
  return shape.side.color;
}

/// The group block's [BoxDecoration] (260729-58x): the NEAREST [Container]
/// ancestor of the header title. The header's color dot is a Container
/// SIBLING of the title, not an ancestor, so `.first` resolves to the block
/// container — the same nearest-ancestor idiom [_rowBorder] relies on.
BoxDecoration _blockDecoration(WidgetTester t, String headerTitle) {
  final container = t.widget<Container>(
    find
        .ancestor(of: find.text(headerTitle), matching: find.byType(Container))
        .first,
  );
  return container.decoration! as BoxDecoration;
}

/// One tab row, addressed by its title: the NEAREST [Material] ancestor of
/// the title text is the row itself (the same idiom [_rowBorder] relies on).
/// Scoping through this is what keeps a per-row star lookup from picking up a
/// sibling row's star.
Finder _rowOf(String title) =>
    find.ancestor(of: find.text(title), matching: find.byType(Material)).first;

/// The star [Icon] inside [title]'s row — `findsNothing` when the row renders
/// no slot at all (the D-11 UNKNOWN case).
Finder _star(String title) => find.descendant(
      of: _rowOf(title),
      matching: find.byIcon(Symbols.star_rounded),
    );

/// A [Semantics] widget inside [title]'s row carrying exactly [label] — the
/// widget-level form, so the label can be pinned to a SPECIFIC row without
/// enabling the semantics tree.
Finder _rowSemantics(String title, String label) => find.descendant(
      of: _rowOf(title),
      matching: find.byWidgetPredicate(
        (w) => w is Semantics && w.properties.label == label,
      ),
    );

/// A tab row's corner radius: the nearest Material ancestor's shape radius
/// (16 flat, 10 nested inside a group block — the concentric-radius rule).
double _rowRadius(WidgetTester t, String title) {
  final material = t.widget<Material>(
    find.ancestor(of: find.text(title), matching: find.byType(Material)).first,
  );
  final shape = material.shape! as RoundedRectangleBorder;
  return (shape.borderRadius as BorderRadius).topLeft.x;
}

void main() {
  test('kBrowserActions is exactly the 7-action router vocabulary', () {
    expect(kBrowserActions, hasLength(7));
    expect(
      kBrowserActions.map((s) => s.action).toSet(),
      kRouterBrowserVocabulary,
      reason: 'action strings must byte-match router.rs browser_macro — '
          'anything else is silently dropped by the server',
    );
    // No duplicates: 7 specs, 7 distinct actions.
    expect(kBrowserActions.map((s) => s.action).toSet(), hasLength(7));
    for (final spec in kBrowserActions) {
      expect(spec.label, isNotEmpty);
      expect(spec.icon, isNotNull);
    }
  });

  testWidgets('tapping each of the 7 buttons records its action string',
      (t) async {
    final actions = <String>[];
    await t.pumpWidget(host(onAction: actions.add, enabled: true));

    // UI-SPEC labels, tapped in grid reading order.
    const labelToAction = <String, String>{
      'Back': 'back',
      'Forward': 'forward',
      'New tab': 'newtab',
      'Close tab': 'closetab',
      'Refresh': 'refresh',
      'Zoom out': 'zoomout',
      'Zoom in': 'zoomin',
    };
    for (final label in labelToAction.keys) {
      await t.tap(find.text(label));
      await t.pump();
    }

    expect(actions, labelToAction.values.toList());
  });

  testWidgets('Refresh renders full-width on its own row (unpaired)',
      (t) async {
    await t.pumpWidget(host(onAction: (_) {}, enabled: true));

    Size keyBox(String label) {
      final box = find
          .ancestor(of: find.text(label), matching: find.byType(Container))
          .first;
      return t.getSize(box);
    }

    // A paired key (Back) sits in a 2-column Row with an Expanded sibling, so
    // it is roughly half the grid width; Refresh spans its own stretched row.
    final refreshWidth = keyBox('Refresh').width;
    final backWidth = keyBox('Back').width;
    expect(
      refreshWidth,
      greaterThan(backWidth * 1.5),
      reason: 'Refresh must be full-width (its own row), not paired',
    );
  });

  testWidgets('a pressed key flashes accent border + label', (t) async {
    await t.pumpWidget(host(onAction: (_) {}, enabled: true));

    Color labelColor(String label) =>
        t.widget<Text>(find.text(label)).style!.color!;
    Color borderColor(String label) {
      final container = t.widget<Container>(
        find
            .ancestor(of: find.text(label), matching: find.byType(Container))
            .first,
      );
      final decoration = container.decoration! as BoxDecoration;
      return decoration.border!.top.color;
    }

    // At rest: text is kText, border is kHairline.
    expect(labelColor('Refresh'), kText);
    expect(borderColor('Refresh'), kHairline);

    // Press-down (hold): the key flashes accent border + accent label.
    final gesture = await t.startGesture(t.getCenter(find.text('Refresh')));
    await t.pump();

    expect(labelColor('Refresh'), kAccent);
    expect(borderColor('Refresh'), kAccent);

    await gesture.up();
    await t.pump();
    // Released: back to the rest palette.
    expect(labelColor('Refresh'), kText);
    expect(borderColor('Refresh'), kHairline);
  });

  testWidgets('disabled grid records nothing', (t) async {
    final actions = <String>[];
    await t.pumpWidget(host(onAction: actions.add, enabled: false));

    for (final label in [
      'Back',
      'Forward',
      'New tab',
      'Close tab',
      'Refresh',
      'Zoom out',
      'Zoom in',
    ]) {
      await t.tap(find.text(label), warnIfMissed: false);
      await t.pump();
    }

    expect(actions, isEmpty);
  });

  // -- Task 4 (260716-oi2): the tab section on the full screen ---------------

  group('tab section (260716-oi2)', () {
    testWidgets('primes the tab list once on open (tabs.list request)',
        (t) async {
      final service = _FakeService();
      await _pumpScreen(t, service);

      expect(service.reliable.whereType<TabsListMsg>(), hasLength(1));

      await _unmount(t);
    });

    testWidgets(
        'extension not connected: hint card shown AND the full macro grid '
        'still renders and fires (locked fallback)', (t) async {
      final service = _FakeService(); // authed, no snapshot → hint state
      await _pumpScreen(t, service);

      // The hint card, never a tab list.
      expect(find.text('Install the browser extension'), findsOneWidget);
      expect(find.byIcon(Symbols.extension_rounded), findsOneWidget);
      expect(find.text('No tabs open.'), findsNothing);

      // ALL 7 existing macro controls render...
      for (final label in [
        'Back',
        'Forward',
        'New tab',
        'Close tab',
        'Refresh',
        'Zoom out',
        'Zoom in',
      ]) {
        expect(find.text(label), findsOneWidget);
      }

      // ...and still fire on tap.
      await t.tap(find.text('Back'));
      await t.pump();
      expect(
        service.reliable.whereType<BrowserMsg>().map((m) => m.action),
        contains('back'),
      );

      await _unmount(t);
    });

    testWidgets('connected with zero tabs shows the muted one-liner',
        (t) async {
      final service = _FakeService()
        ..parked = const TabsSnapshot(connected: true, tabs: [], groups: []);
      await _pumpScreen(t, service);

      expect(find.text('No tabs open.'), findsOneWidget);
      expect(find.text('Install the browser extension'), findsNothing);

      await _unmount(t);
    });

    testWidgets(
        'rows render titles; the active tab carries the kAccent border, '
        'inactive rows kHairline', (t) async {
      final service = _FakeService()..parked = _twoTabs;
      await _pumpScreen(t, service);

      expect(find.text('GitHub'), findsOneWidget);
      expect(find.text('Docs'), findsOneWidget);

      expect(_rowBorder(t, 'GitHub'), kAccent,
          reason: 'active tab must be visually marked (locked)');
      expect(_rowBorder(t, 'Docs'), kHairline);

      await _unmount(t);
    });

    testWidgets('tap-down on a row sends tabs.activate for that id',
        (t) async {
      final service = _FakeService()..parked = _twoTabs;
      await _pumpScreen(t, service);

      await t.tap(find.text('Docs'));
      await t.pump(const Duration(milliseconds: 150)); // flush press-flash

      expect(
        service.reliable.whereType<TabsActivateMsg>().map((m) => m.id),
        contains(9),
      );

      await _unmount(t);
    });

    testWidgets('swipe-dismiss sends tabs.close for that id', (t) async {
      final service = _FakeService()..parked = _twoTabs;
      await _pumpScreen(t, service);

      await t.drag(find.text('Docs'), const Offset(500, 0));
      await t.pumpAndSettle();

      expect(
        service.reliable.whereType<TabsCloseMsg>().map((m) => m.id),
        contains(9),
      );
      // The row springs back (server-driven removal) — never dismissed while
      // the state list still contains it.
      expect(find.text('Docs'), findsOneWidget);

      await _unmount(t);
    });

    testWidgets('long-press on a row sends tabs.close for that id',
        (t) async {
      final service = _FakeService()..parked = _twoTabs;
      await _pumpScreen(t, service);

      await t.longPress(find.text('GitHub'));
      await t.pump(const Duration(milliseconds: 150)); // flush press-flash

      expect(
        service.reliable.whereType<TabsCloseMsg>().map((m) => m.id),
        contains(7),
      );

      await _unmount(t);
    });

    testWidgets(
        'not authed: rows render muted and tap/swipe/long-press send nothing',
        (t) async {
      final service = _FakeService(chip: ChipStatus.disconnected)
        ..parked = _twoTabs;
      await _pumpScreen(t, service);

      expect(
        t.widget<Text>(find.text('GitHub')).style!.color,
        kMuted,
        reason: 'gated rows are muted, never red',
      );

      await t.tap(find.text('GitHub'), warnIfMissed: false);
      await t.pump();
      await t.drag(find.text('Docs'), const Offset(500, 0));
      await t.pumpAndSettle();
      await t.longPress(find.text('GitHub'), warnIfMissed: false);
      await t.pump();

      expect(service.reliable.whereType<TabsActivateMsg>(), isEmpty);
      expect(service.reliable.whereType<TabsCloseMsg>(), isEmpty);

      await _unmount(t);
    });

    testWidgets(
        'grouped tabs render ONE header tinted the mapped Chrome color; '
        'the ungrouped tab has no header (proto 1.5)', (t) async {
      final service = _FakeService()..parked = _groupedTabs;
      await _pumpScreen(t, service);

      // Exactly one "Work" header for the two-tab consecutive run.
      expect(find.text('Work'), findsOneWidget);
      expect(
        t.widget<Text>(find.text('Work')).style!.color,
        kGroupColors['blue'],
        reason: 'header title must be tinted the mapped group color',
      );
      // All three tab rows still render (grouped rows unchanged chrome).
      expect(find.text('GitHub'), findsOneWidget);
      expect(find.text('PRs'), findsOneWidget);
      expect(find.text('Docs'), findsOneWidget);
      expect(_rowBorder(t, 'GitHub'), kAccent,
          reason: 'active-tab accent border survives grouping');

      await _unmount(t);
    });

    testWidgets(
        'a collapsed group header renders dimmed inside Opacity(0.5) '
        'with the unfold-less glyph', (t) async {
      final service = _FakeService()
        ..parked = const TabsSnapshot(
          connected: true,
          tabs: [TabInfo(id: 7, title: 'GitHub', active: true, groupId: 1)],
          groups: [
            GroupInfo(id: 1, title: 'Work', color: 'blue', collapsed: true),
          ],
        );
      await _pumpScreen(t, service);

      final opacity = t.widget<Opacity>(
        find.ancestor(of: find.text('Work'), matching: find.byType(Opacity)),
      );
      expect(opacity.opacity, 0.5, reason: 'collapsed = dimmed header');
      expect(find.byIcon(Symbols.unfold_less_rounded), findsOneWidget);

      await _unmount(t);
    });

    testWidgets(
        'the group header is view-only: tapping it fires no activate/close',
        (t) async {
      final service = _FakeService()..parked = _groupedTabs;
      await _pumpScreen(t, service);

      await t.tap(find.text('Work'), warnIfMissed: false);
      await t.pump();
      await t.longPress(find.text('Work'), warnIfMissed: false);
      await t.pump();

      expect(service.reliable.whereType<TabsActivateMsg>(), isEmpty,
          reason: 'header has no gesture handlers — view-only is structural');
      expect(service.reliable.whereType<TabsCloseMsg>(), isEmpty);

      await _unmount(t);
    });

    testWidgets(
        'an unresolved groupId (group past the cap) renders flat — no header',
        (t) async {
      final service = _FakeService()
        ..parked = const TabsSnapshot(
          connected: true,
          // groupId 99 has NO GroupInfo — the group fell past the 16 cap.
          tabs: [TabInfo(id: 7, title: 'GitHub', active: true, groupId: 99)],
          groups: [],
        );
      await _pumpScreen(t, service);

      expect(find.text('GitHub'), findsOneWidget);
      expect(find.byIcon(Symbols.unfold_less_rounded), findsNothing);
      expect(t.takeException(), isNull);

      await _unmount(t);
    });

    testWidgets(
        'a broken base64 favicon renders the fallback glyph (never throws)',
        (t) async {
      final service = _FakeService()
        ..parked = const TabsSnapshot(
          connected: true,
          tabs: [
            TabInfo(id: 1, title: 'Bad', active: true, icon: '%%%not-b64%%%'),
            TabInfo(id: 2, title: 'None', active: false), // null icon
          ],
          groups: [],
        );
      await _pumpScreen(t, service);

      expect(find.byIcon(Symbols.language_rounded), findsNWidgets(2));
      expect(t.takeException(), isNull);

      await _unmount(t);
    });
  });

  // -- 260729-58x: tab-group visual hierarchy --------------------------------
  //
  // A floating label above flat rows gave a group a visible START but no
  // visible END, so a tab inside a group looked identical to the tab after
  // it. These pin the fix: one tinted, bordered container per consecutive
  // grouped run, nested-radius rows inside it, and a separate count suffix.

  group('tab-group visual hierarchy (260729-58x)', () {
    testWidgets(
        'a grouped run renders inside a tinted group block; grouped rows use '
        'the nested radius, flat rows keep 16', (t) async {
      final service = _FakeService()..parked = _groupedTabs;
      await _pumpScreen(t, service);

      final blue = kGroupColors['blue']!;
      final decoration = _blockDecoration(t, 'Work');
      expect(decoration.color, blue.withValues(alpha: 0.06),
          reason: 'block fill is the group color at 6% — derived with '
              'withValues, never an Opacity wrapper');
      expect(decoration.border!.top.color, blue.withValues(alpha: 0.40),
          reason: 'the block border is what gives the group a visible END');
      expect(decoration.border!.top.width, 1);
      expect((decoration.borderRadius! as BorderRadius).topLeft.x, 16);

      // Concentric-radius rule: outer 16 − 6px block padding = nested 10.
      expect(_rowRadius(t, 'GitHub'), 10);
      expect(_rowRadius(t, 'PRs'), 10);
      expect(_rowRadius(t, 'Docs'), 16,
          reason: 'the tab AFTER the group keeps the flat radius-16 chrome');

      expect(_rowBorder(t, 'GitHub'), kAccent,
          reason: 'active-tab marking survives nesting');
      expect(t.takeException(), isNull);

      await _unmount(t);
    });

    testWidgets(
        'two adjacent groups render as two separate blocks, each with exactly '
        'one header', (t) async {
      final service = _FakeService()..parked = _twoGroups;
      await _pumpScreen(t, service);

      expect(find.text('Work'), findsOneWidget);
      expect(find.text('Play'), findsOneWidget);
      // Differing tints prove two DISTINCT block Containers — i.e. the run
      // chunker split at the group boundary instead of merging.
      expect(
        _blockDecoration(t, 'Work').color,
        kGroupColors['blue']!.withValues(alpha: 0.06),
      );
      expect(
        _blockDecoration(t, 'Play').color,
        kGroupColors['green']!.withValues(alpha: 0.06),
      );
      expect(
        find.ancestor(of: find.text('Work'), matching: find.byType(Opacity)),
        findsNothing,
        reason: 'an expanded group must introduce NO Opacity — the collapsed '
            'header owns the only one in the tab section, which is what keeps '
            "the collapsed test's single-Opacity lookup unambiguous",
      );

      await _unmount(t);
    });

    testWidgets(
        'a grouped run shows a separate muted count suffix; the title Text is '
        'unchanged', (t) async {
      final service = _FakeService()..parked = _groupedTabs;
      await _pumpScreen(t, service);

      expect(find.text('· 2'), findsOneWidget);
      expect(t.widget<Text>(find.text('· 2')).style!.color, kMuted);
      // The count must be a SEPARATE Text, never concatenated into the title.
      expect(find.text('Work'), findsOneWidget);
      expect(
        t.widget<Text>(find.text('Work')).style!.color,
        kGroupColors['blue'],
      );

      await _unmount(t);
    });

    testWidgets('an untitled group falls back to the dot plus the count alone',
        (t) async {
      final service = _FakeService()
        ..parked = const TabsSnapshot(
          connected: true,
          tabs: [TabInfo(id: 7, title: 'GitHub', active: true, groupId: 1)],
          groups: [
            GroupInfo(id: 1, title: '', color: 'red', collapsed: false),
          ],
        );
      await _pumpScreen(t, service);

      expect(find.text('· 1'), findsOneWidget);
      expect(t.takeException(), isNull);

      // No title to hang _blockDecoration off — reach the block through the
      // count Text instead (still the nearest Container ancestor).
      final block = t.widget<Container>(
        find
            .ancestor(of: find.text('· 1'), matching: find.byType(Container))
            .first,
      );
      expect(
        (block.decoration! as BoxDecoration).color,
        kGroupColors['red']!.withValues(alpha: 0.06),
      );

      await _unmount(t);
    });
  });

  // -- Phase 11 (11-10): the Tabs | Bookmarks segment ------------------------
  //
  // D-01 swaps ONLY the list region, D-02 is read as pixel-pinned (the macro
  // grid must occupy the same rect in both segments), D-03 primes bm.list
  // exactly once per mount however Bookmarks is reached, and D-04 keeps both
  // the segment and the folder position across consecutive opens.

  group('segmented browser screen (11-10)', () {
    testWidgets(
        'D-02: the macro grid occupies an IDENTICAL rect in both segments, '
        'even with a bookmarks list far taller than the tab list', (t) async {
      final service = _FakeService()
        ..parked = _twoTabs
        ..parkedBm = _bmTree;
      await _pumpScreen(t, service);

      // One key cap (the nearest Container ancestor of its label — the
      // existing `keyBox` idiom) and the whole grid, measured in both
      // segments.
      Rect capRect(String label) => t.getRect(
            find
                .ancestor(
                  of: find.text(label),
                  matching: find.byType(Container),
                )
                .first,
          );

      final capOnTabs = capRect('Refresh');
      final gridOnTabs = t.getRect(find.byType(BrowserMacroGrid));

      await _selectSegment(t, kSegmentBookmarksLabel);
      expect(find.text('Bookmarks bar'), findsOneWidget);

      expect(
        capRect('Refresh'),
        capOnTabs,
        reason: 'D-02 is pixel-pinned: the grid lives OUTSIDE the swapped '
            'scroll region, so a taller list cannot move it',
      );
      expect(t.getRect(find.byType(BrowserMacroGrid)), gridOnTabs);

      // Drill into the 21-child folder — the tallest list this fixture can
      // render, and the case the old single-scroll-view layout would have
      // pushed the grid far down the screen.
      await t.tap(find.text('Bookmarks bar'));
      await t.pump(const Duration(milliseconds: 150));
      expect(find.text('Link 0'), findsOneWidget);

      expect(
        capRect('Refresh'),
        capOnTabs,
        reason: 'the grid must not move when the folder list overflows either',
      );
      expect(t.getRect(find.byType(BrowserMacroGrid)), gridOnTabs);

      await _unmount(t);
    });

    testWidgets(
        'D-01: the segment swaps ONLY the list; the 7 macro buttons render in '
        'both', (t) async {
      final service = _FakeService()
        ..parked = _twoTabs
        ..parkedBm = _bmTree;
      await _pumpScreen(t, service);

      const macroLabels = [
        'Back',
        'Forward',
        'New tab',
        'Close tab',
        'Refresh',
        'Zoom out',
        'Zoom in',
      ];

      // Tabs: tab rows, no bookmark rows.
      expect(find.text('GitHub'), findsOneWidget);
      expect(find.text('Docs'), findsOneWidget);
      expect(find.text('Bookmarks bar'), findsNothing);
      for (final label in macroLabels) {
        expect(find.text(label), findsOneWidget);
      }

      await _selectSegment(t, kSegmentBookmarksLabel);

      // Bookmarks: bookmark rows, no tab rows — same grid.
      expect(find.text('Bookmarks bar'), findsOneWidget);
      expect(find.text('Other bookmarks'), findsOneWidget);
      expect(find.text('GitHub'), findsNothing);
      expect(find.text('Docs'), findsNothing);
      for (final label in macroLabels) {
        expect(find.text(label), findsOneWidget);
      }

      await _unmount(t);
    });

    testWidgets(
        'D-03: screen open primes tabs.list ONLY; the first Bookmarks display '
        'primes bm.list exactly once, and a second switch primes nothing',
        (t) async {
      final service = _FakeService()
        ..parked = _twoTabs
        ..parkedBm = _bmTree;
      await _pumpScreen(t, service);

      expect(service.reliable.whereType<TabsListMsg>(), hasLength(1));
      expect(
        service.reliable.whereType<BmListMsg>(),
        isEmpty,
        reason: 'a phone that never opens the segment never asks the PC for '
            'bookmark titles at all (T-11-12)',
      );

      await _selectSegment(t, kSegmentBookmarksLabel);
      expect(service.reliable.whereType<BmListMsg>(), hasLength(1));

      await _selectSegment(t, kSegmentTabsLabel);
      await _selectSegment(t, kSegmentBookmarksLabel);
      expect(
        service.reliable.whereType<BmListMsg>(),
        hasLength(1),
        reason: 'the tree is kept live by bm.changed pushes after the first '
            'prime — a second switch must send nothing',
      );
      // The tab prime is likewise once per mount, not once per switch.
      expect(service.reliable.whereType<TabsListMsg>(), hasLength(1));

      await _unmount(t);
    });

    testWidgets(
        'D-03: a segment RESTORED from prefs primes bm.list once too — the '
        'prime follows display, not the tap', (t) async {
      final service = _FakeService()
        ..parked = _twoTabs
        ..parkedBm = _bmTree;
      final store = _FakeSegmentStore(initial: BrowserSegment.bookmarks);
      await _pumpScreen(t, service, store: store);
      await t.pump();

      expect(find.text('Bookmarks bar'), findsOneWidget,
          reason: 'the persisted segment must be the one displayed');
      expect(service.reliable.whereType<BmListMsg>(), hasLength(1));
      expect(service.reliable.whereType<TabsListMsg>(), hasLength(1),
          reason: 'tabs.list still primes on open regardless of segment');

      await _unmount(t);
    });

    testWidgets(
        'D-04: opening bookmarks in a row changes neither the segment nor the '
        'folder position', (t) async {
      final service = _FakeService()
        ..parked = _twoTabs
        ..parkedBm = _bmTree;
      await _pumpScreen(t, service);
      await _selectSegment(t, kSegmentBookmarksLabel);

      // Drill two levels in: roots → Bookmarks bar → Work.
      await t.tap(find.text('Bookmarks bar'));
      await t.pump(const Duration(milliseconds: 150));
      await t.tap(find.text('Work'));
      await t.pump(const Duration(milliseconds: 150));
      expect(find.text('Jira'), findsOneWidget);
      expect(find.text('Wiki'), findsOneWidget);

      for (final title in ['Jira', 'Wiki', 'Jira']) {
        await t.tap(find.text(title));
        await t.pump(const Duration(milliseconds: 150));
        // Still inside Work, still on the Bookmarks segment, every time.
        expect(find.text('Work'), findsOneWidget,
            reason: 'the folder bar must still name the current folder');
        expect(find.text('Jira'), findsOneWidget);
        expect(find.text('GitHub'), findsNothing,
            reason: 'opening a bookmark must never switch back to Tabs');
      }

      expect(
        service.reliable.whereType<BmOpenMsg>().map((m) => m.nodeId).toList(),
        ['20', '21', '20'],
      );

      await _unmount(t);
    });

    testWidgets(
        'the segment is never gated: switching works unauthed while the macro '
        'grid and the rows stay inert', (t) async {
      final service = _FakeService(chip: ChipStatus.disconnected)
        ..parked = _twoTabs
        ..parkedBm = _bmTree;
      await _pumpScreen(t, service);

      // Gated tab row + gated macro button record nothing.
      await t.tap(find.text('GitHub'), warnIfMissed: false);
      await t.pump();
      await t.tap(find.text('Back'), warnIfMissed: false);
      await t.pump();
      expect(service.reliable.whereType<TabsActivateMsg>(), isEmpty);
      expect(service.reliable.whereType<BrowserMsg>(), isEmpty);

      // ...but the segment still switches — navigation, not a send.
      await _selectSegment(t, kSegmentBookmarksLabel);
      expect(find.text('Bookmarks bar'), findsOneWidget);
      expect(find.text('GitHub'), findsNothing);

      // Gated bookmark rows are inert as well.
      await t.tap(find.text('Bookmarks bar'), warnIfMissed: false);
      await t.pump(const Duration(milliseconds: 150));
      expect(service.reliable.whereType<BmOpenMsg>(), isEmpty);
      expect(find.text('Link 0'), findsNothing,
          reason: 'a gated row fires neither a send nor a local drill-in');

      await _selectSegment(t, kSegmentTabsLabel);
      expect(find.text('GitHub'), findsOneWidget);

      await _unmount(t);
    });

    testWidgets('selecting Bookmarks persists the choice exactly once',
        (t) async {
      final service = _FakeService()
        ..parked = _twoTabs
        ..parkedBm = _bmTree;
      final store = _FakeSegmentStore();
      await _pumpScreen(t, service, store: store);

      expect(store.saved, isEmpty, reason: 'a mount persists nothing');

      await _selectSegment(t, kSegmentBookmarksLabel);
      expect(store.saved, [BrowserSegment.bookmarks]);

      await _unmount(t);
    });

    testWidgets(
        'the segment bar renders both labels, accent on the selected one',
        (t) async {
      final service = _FakeService()
        ..parked = _twoTabs
        ..parkedBm = _bmTree;
      await _pumpScreen(t, service);

      Color labelColor(String label) =>
          t.widget<Text>(find.text(label)).style!.color!;

      expect(find.byType(BrowserSegmentBar), findsOneWidget);
      expect(labelColor(kSegmentTabsLabel), kAccent);
      expect(labelColor(kSegmentBookmarksLabel), kMuted);

      await _selectSegment(t, kSegmentBookmarksLabel);

      expect(labelColor(kSegmentTabsLabel), kMuted);
      expect(labelColor(kSegmentBookmarksLabel), kAccent);
      // The removed section header must not come back.
      expect(find.text('Tabs'), findsOneWidget);

      await _unmount(t);
    });

    testWidgets(
        'Android system back pops one folder level, then leaves the screen',
        (t) async {
      final service = _FakeService()
        ..parked = _twoTabs
        ..parkedBm = _bmTree;
      await _pumpScreen(t, service);
      await _selectSegment(t, kSegmentBookmarksLabel);

      await t.tap(find.text('Bookmarks bar'));
      await t.pump(const Duration(milliseconds: 150));
      await t.tap(find.text('Work'));
      await t.pump(const Duration(milliseconds: 150));
      expect(find.text('Jira'), findsOneWidget);

      expect(_popScope(canPop: false), findsOneWidget,
          reason: 'inside a folder the screen intercepts system back');

      // depth 2 → back walks up one level, the route stays.
      await t.binding.handlePopRoute();
      await t.pumpAndSettle();
      expect(find.text('Link 0'), findsOneWidget);
      expect(find.text('Jira'), findsNothing);

      // depth 1 → back walks to the roots level.
      await t.binding.handlePopRoute();
      await t.pumpAndSettle();
      expect(find.text('Bookmarks bar'), findsOneWidget);
      expect(find.text('Link 0'), findsNothing);

      // depth 0 → nothing is intercepted any more; back leaves the screen.
      expect(_popScope(canPop: true), findsOneWidget);

      // ...and the Tabs segment never intercepts at all.
      await _selectSegment(t, kSegmentTabsLabel);
      expect(_popScope(canPop: true), findsOneWidget);

      await _unmount(t);
    });
  });

  // -- Phase 11 (11-11): the trailing star slot on a tab row -----------------
  //
  // D-09 exists because the row's gesture budget was already spent, so the
  // star had to be a nested BUTTON — and RESEARCH Pitfall 8 / assumption A6
  // says that arena isolation must be pinned by OBSERVATION rather than by
  // reasoning about `TapGestureRecognizer` deadlines. D-11 is the truthfulness
  // rule (UNKNOWN renders nothing; removing is confirm-gated) and D-12 is the
  // optimistic flip.

  group('tab row star (11-11)', () {
    testWidgets(
        'D-11 tri-state: filled+accent when bookmarked, outline+muted when '
        'not, and NO slot at all when unknown', (t) async {
      // Disposed inside the body: the framework verifies semantics handles
      // BEFORE tearDowns run (the bookmarks_section_test discipline).
      final handle = t.ensureSemantics();
      final service = _FakeService()..parked = _triStateTabs;
      await _pumpScreen(t, service);

      final starred = t.widget<Icon>(_star('Starred'));
      expect(starred.fill, 1, reason: 'the FILL axis IS the state signal');
      expect(starred.color, kAccent);

      final plain = t.widget<Icon>(_star('Plain'));
      expect(plain.fill, 0);
      expect(plain.color, kMuted);

      // The UNKNOWN row renders neither a glyph nor an accessibility node —
      // an empty star on a tab whose bookmark state could not be read would
      // be a false negative (T-11-01).
      expect(_star('Unknown'), findsNothing);
      expect(_rowSemantics('Unknown', kStarSemantic), findsNothing);
      expect(_rowSemantics('Unknown', kUnstarSemantic), findsNothing);
      expect(find.byIcon(Symbols.star_rounded), findsNWidgets(2),
          reason: 'exactly two of the three rows may carry a star');

      // Never the destructive red, in any rendered state.
      for (final title in ['Starred', 'Plain']) {
        expect(t.widget<Icon>(_star(title)).color, isNot(kError));
      }

      await _unmount(t);
      handle.dispose();
    });

    testWidgets(
        'A6/Pitfall 8: a star tap sends exactly one bm.star and ZERO '
        'tabs.activate', (t) async {
      final service = _FakeService()..parked = _triStateTabs;
      await _pumpScreen(t, service);

      await t.tap(_star('Plain'));
      await t.pump(const Duration(milliseconds: 150)); // flush any flash

      final stars = service.reliable.whereType<BmStarMsg>().toList();
      expect(stars, hasLength(1));
      expect(stars.single.tabId, 8);
      expect(
        service.reliable.whereType<TabsActivateMsg>(),
        isEmpty,
        reason: 'the nested star recognizer must win the arena — this is an '
            'observation, not an inference about tap deadlines',
      );
      expect(service.reliable.whereType<TabsCloseMsg>(), isEmpty);
      expect(service.reliable.whereType<BmUnstarMsg>(), isEmpty);

      await _unmount(t);
    });

    testWidgets(
        'gated: the star keeps its geometry and its label, renders kMuted '
        '(never kError), and sends nothing', (t) async {
      final handle = t.ensureSemantics();

      // Reference geometry from the CONNECTED state, same fixture and same
      // surface size — so an equal rect afterwards means the layout truly did
      // not shift between the two states.
      final live = _FakeService()..parked = _triStateTabs;
      await _pumpScreen(t, live);
      final liveStarRect = t.getRect(_star('Starred'));
      final liveRowRect = t.getRect(_rowOf('Starred'));
      await _unmount(t);

      final service = _FakeService(chip: ChipStatus.disconnected)
        ..parked = _triStateTabs;
      await _pumpScreen(t, service);

      expect(t.getRect(_star('Starred')), liveStarRect,
          reason: 'the gated slot occupies the same box');
      expect(t.getRect(_rowOf('Starred')), liveRowRect,
          reason: 'and the row around it does not move either');

      final gatedStar = t.widget<Icon>(_star('Starred'));
      expect(gatedStar.color, kMuted, reason: 'gated is muted, never red');
      expect(gatedStar.color, isNot(kError));
      expect(gatedStar.fill, 1,
          reason: 'a gated star still tells the truth about the state');
      expect(t.widget<Icon>(_star('Plain')).color, kMuted);

      // The label is KEPT — Flutter marks the node disabled via the null
      // callback, so the control reads as disabled rather than absent.
      expect(_rowSemantics('Starred', kUnstarSemantic), findsOneWidget);
      expect(_rowSemantics('Plain', kStarSemantic), findsOneWidget);
      expect(find.bySemanticsLabel(kUnstarSemantic), findsOneWidget);

      await t.tap(_star('Starred'), warnIfMissed: false);
      await t.pump();
      await t.tap(_star('Plain'), warnIfMissed: false);
      await t.pump();

      expect(service.reliable.whereType<BmStarMsg>(), isEmpty);
      expect(service.reliable.whereType<BmUnstarMsg>(), isEmpty);
      expect(find.text(kBmUnstarTitle), findsNothing,
          reason: 'a gated star cannot even open the confirm');
      expect(service.reliable.whereType<TabsActivateMsg>(), isEmpty);

      await _unmount(t);
      handle.dispose();
    });

    testWidgets(
        'T-11-06: unstar is confirm-gated — the tap alone sends nothing, '
        'Cancel keeps the star filled, Remove sends exactly one bm.unstar',
        (t) async {
      final service = _FakeService()..parked = _triStateTabs;
      await _pumpScreen(t, service);

      await t.tap(_star('Starred'));
      await t.pumpAndSettle();

      expect(find.text(kBmUnstarTitle), findsOneWidget);
      expect(find.text(kBmUnstarBody), findsOneWidget,
          reason: 'the body must state the blast radius plainly');
      expect(service.reliable.whereType<BmUnstarMsg>(), isEmpty,
          reason: 'the dialog opens and NOTHING has been sent yet');

      await t.tap(find.text(kBmConfirmCancel));
      await t.pumpAndSettle();

      expect(service.reliable.whereType<BmUnstarMsg>(), isEmpty);
      final afterCancel = t.widget<Icon>(_star('Starred'));
      expect(afterCancel.fill, 1, reason: 'cancel changes nothing');
      expect(afterCancel.color, kAccent);

      // Second attempt, confirmed this time.
      await t.tap(_star('Starred'));
      await t.pumpAndSettle();
      await t.tap(find.text(kBmUnstarConfirm));
      await t.pumpAndSettle();

      final unstars = service.reliable.whereType<BmUnstarMsg>().toList();
      expect(unstars, hasLength(1));
      expect(unstars.single.tabId, 7);
      expect(service.reliable.whereType<TabsActivateMsg>(), isEmpty,
          reason: 'neither the star tap nor the dialog may activate the tab');

      await _unmount(t);
    });

    testWidgets(
        'D-12: the optimistic flip is visible in the next frame with no new '
        'snapshot, and the semantic label flips with it', (t) async {
      final handle = t.ensureSemantics();
      final service = _FakeService()..parked = _triStateTabs;
      await _pumpScreen(t, service);

      expect(t.widget<Icon>(_star('Plain')).fill, 0);
      expect(_rowSemantics('Plain', kStarSemantic), findsOneWidget);

      await t.tap(_star('Plain'));
      await t.pump(); // ONE frame — no authoritative snapshot delivered

      final flipped = t.widget<Icon>(_star('Plain'));
      expect(flipped.fill, 1, reason: 'the flip must read as immediate (0 ms)');
      expect(flipped.color, kAccent);
      expect(
        _rowSemantics('Plain', kUnstarSemantic),
        findsOneWidget,
        reason: 'the label is the only channel a screen reader has for the '
            'state, so it must flip too',
      );
      expect(_rowSemantics('Plain', kStarSemantic), findsNothing);
      expect(find.bySemanticsLabel(kUnstarSemantic), findsNWidgets(2));
      expect(find.bySemanticsLabel(kStarSemantic), findsNothing);
      expect(service.parked, same(_triStateTabs),
          reason: 'the flip came from the overlay, not from the PC');

      // The row untouched by the tap is unaffected.
      expect(t.widget<Icon>(_star('Starred')).fill, 1);
      expect(_star('Unknown'), findsNothing);

      await t.pump(const Duration(milliseconds: 150));
      await _unmount(t);
      handle.dispose();
    });

    testWidgets(
        'the star labels are pinned to the right rows and announce WHICH '
        'state the star is in', (t) async {
      final handle = t.ensureSemantics();
      final service = _FakeService()..parked = _triStateTabs;
      await _pumpScreen(t, service);

      expect(_rowSemantics('Starred', kUnstarSemantic), findsOneWidget);
      expect(_rowSemantics('Starred', kStarSemantic), findsNothing);
      expect(_rowSemantics('Plain', kStarSemantic), findsOneWidget);
      expect(_rowSemantics('Plain', kUnstarSemantic), findsNothing);

      expect(find.bySemanticsLabel(kStarSemantic), findsOneWidget);
      expect(find.bySemanticsLabel(kUnstarSemantic), findsOneWidget);

      await _unmount(t);
      handle.dispose();
    });

    testWidgets(
        'regression: an UNKNOWN-state row carries no star and its tap-down / '
        'long-press / swipe behave exactly as before the phase', (t) async {
      final handle = t.ensureSemantics();
      // Every tab in _twoTabs omits `bookmarked` — i.e. null throughout.
      final service = _FakeService()..parked = _twoTabs;
      await _pumpScreen(t, service);

      expect(find.byIcon(Symbols.star_rounded), findsNothing);
      expect(find.bySemanticsLabel(kStarSemantic), findsNothing);
      expect(find.bySemanticsLabel(kUnstarSemantic), findsNothing);

      await t.tap(find.text('Docs'));
      await t.pump(const Duration(milliseconds: 150));
      await t.longPress(find.text('GitHub'));
      await t.pump(const Duration(milliseconds: 150));
      await t.drag(find.text('Docs'), const Offset(500, 0));
      await t.pumpAndSettle();

      expect(service.reliable.whereType<TabsActivateMsg>().map((m) => m.id),
          contains(9));
      final closed =
          service.reliable.whereType<TabsCloseMsg>().map((m) => m.id).toList();
      expect(closed, contains(7), reason: 'long-press still closes');
      expect(closed, contains(9), reason: 'swipe still closes');
      expect(service.reliable.whereType<BmStarMsg>(), isEmpty);
      expect(service.reliable.whereType<BmUnstarMsg>(), isEmpty);

      await _unmount(t);
      handle.dispose();
    });
  });
}
