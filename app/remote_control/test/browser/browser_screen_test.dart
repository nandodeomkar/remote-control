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

import 'package:remote_control/browser/browser_screen.dart';
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

  @override
  ChipStatus get chipStatus => chip;

  @override
  bool get isAuthed => chip == ChipStatus.connected;

  @override
  TabsSnapshot? get tabsSnapshot => parked;

  @override
  void sendReliable(RemoteMessage msg) => reliable.add(msg);
}

/// Pumps the full BrowserScreen over [service] on a tall surface (the tab
/// rows + the whole macro grid must be on-screen for taps) and runs the
/// post-frame primeList.
Future<void> _pumpScreen(WidgetTester t, _FakeService service) async {
  await t.binding.setSurfaceSize(const Size(800, 1600));
  addTearDown(() => t.binding.setSurfaceSize(null));
  await t.pumpWidget(
    ProviderScope(
      overrides: [
        connectionServiceProvider.overrideWith((ref) => service),
      ],
      child: const MaterialApp(home: BrowserScreen()),
    ),
  );
  await t.pump(); // post-frame primeList
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
);

/// The row-chrome border color: the nearest Material ancestor's shape side.
Color _rowBorder(WidgetTester t, String title) {
  final material = t.widget<Material>(
    find.ancestor(of: find.text(title), matching: find.byType(Material)).first,
  );
  final shape = material.shape! as RoundedRectangleBorder;
  return shape.side.color;
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
        ..parked = const TabsSnapshot(connected: true, tabs: []);
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
        'a broken base64 favicon renders the fallback glyph (never throws)',
        (t) async {
      final service = _FakeService()
        ..parked = const TabsSnapshot(
          connected: true,
          tabs: [
            TabInfo(id: 1, title: 'Bad', active: true, icon: '%%%not-b64%%%'),
            TabInfo(id: 2, title: 'None', active: false), // null icon
          ],
        );
      await _pumpScreen(t, service);

      expect(find.byIcon(Symbols.language_rounded), findsNWidgets(2));
      expect(t.takeException(), isNull);

      await _unmount(t);
    });
  });
}
