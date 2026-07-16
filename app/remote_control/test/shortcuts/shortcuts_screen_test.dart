// Task 1 (10-02) — Shortcut catalog integrity + vocabulary membership +
// ShortcutButton press/gating (the house press-down + muted-not-red pattern).
//
// The catalog is the single ordered source of truth: this suite iterates
// kShortcutCatalog, cross-checks every code against the locked kClientKeyCodes
// vocabulary (keymap.rs mirror — drift fails the build, T-10-03), asserts the
// section counts (7/3/9/6 = 25), and proves the excluded combos never render
// (Alt+Tab, Win+L lock, Ctrl+Alt+Del — user-locked exclusions).
//
// ShortcutButton is the _TransportButton press-down twin: enabled fires exactly
// one onPress on tap-DOWN; gated (enabled:false) fires nothing and renders
// muted-not-red.

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_protocol/remote_protocol.dart';

import 'package:remote_control/keyboard/key_rows.dart' show kClientKeyCodes;
import 'package:remote_control/net/connection_providers.dart';
import 'package:remote_control/net/connection_service.dart';
import 'package:remote_control/shortcuts/shortcuts_screen.dart';
import 'package:remote_control/store/device_store.dart';

/// The wire modifier vocabulary (modifier_fsm _kWireMods).
const Set<String> _kWireMods = {'ctrl', 'alt', 'shift', 'win'};

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

/// A recording service reporting a fixed chip status — the media-screen seam.
class _FakeService extends ConnectionService {
  _FakeService({required this.connected})
      : super(
          store: DeviceStore(secure: _FakeSecureKv(), prefs: _FakePrefsKv()),
        );

  final bool connected;
  final List<RemoteMessage> reliable = [];

  @override
  bool get isAuthed => connected;

  @override
  ChipStatus get chipStatus =>
      connected ? ChipStatus.connected : ChipStatus.disconnected;

  @override
  void sendReliable(RemoteMessage msg) => reliable.add(msg);
}

Widget _host(ConnectionService service) => ProviderScope(
      overrides: [
        connectionServiceProvider.overrideWith((ref) => service),
      ],
      child: const MaterialApp(home: ShortcutsScreen()),
    );

void main() {
  group('kShortcutCatalog integrity', () {
    test('has exactly 4 sections with counts 7/3/9/6 (25 total)', () {
      expect(kShortcutCatalog.length, 4);
      expect(
        kShortcutCatalog.map((s) => s.items.length).toList(),
        [7, 3, 9, 6],
      );
      final total =
          kShortcutCatalog.fold<int>(0, (a, s) => a + s.items.length);
      expect(total, 25);
    });

    test('section headers are the locked copy in order', () {
      expect(
        kShortcutCatalog.map((s) => s.header).toList(),
        ['Windows & Desktop', 'Screenshot', 'Browser & App', 'Editing'],
      );
    });

    test('every code is in the locked kClientKeyCodes vocabulary', () {
      for (final section in kShortcutCatalog) {
        for (final s in section.items) {
          expect(
            kClientKeyCodes,
            contains(s.code),
            reason: '${s.label} code "${s.code}" must be in keymap.rs vocab',
          );
        }
      }
    });

    test('every mods entry is one of ctrl/alt/shift/win', () {
      for (final section in kShortcutCatalog) {
        for (final s in section.items) {
          for (final m in s.mods) {
            expect(_kWireMods, contains(m),
                reason: '${s.label} mod "$m" is not a wire modifier');
          }
        }
      }
    });

    test('no excluded combo renders (Alt+Tab, Win+L lock, Ctrl+Alt+Del)', () {
      for (final section in kShortcutCatalog) {
        for (final s in section.items) {
          // Alt+Tab (Apps remote covers this).
          expect(
            s.code == 'Tab' && s.mods.contains('alt'),
            isFalse,
            reason: 'Alt+Tab is user-excluded',
          );
          // Win+L lock — no L code, no lock chord.
          expect(
            s.code == 'L' && s.mods.contains('win'),
            isFalse,
            reason: 'Win+L lock is user-excluded',
          );
          // Ctrl+Alt+Del — uninjectable secure attention sequence.
          final ctrlAltDel = s.mods.contains('ctrl') &&
              s.mods.contains('alt') &&
              (s.code == 'Del' || s.code == 'Delete');
          expect(ctrlAltDel, isFalse, reason: 'Ctrl+Alt+Del is user-excluded');
        }
      }
    });

    test('the anchor rows carry their locked code/mods', () {
      ShortcutSpec byLabel(String label) => kShortcutCatalog
          .expand((s) => s.items)
          .firstWhere((s) => s.label == label);

      final showDesktop = byLabel('Show desktop');
      expect(showDesktop.code, 'D');
      expect(showDesktop.mods, ['win']);
      expect(showDesktop.combo, 'Win+D');

      final taskMgr = byLabel('Task Manager');
      expect(taskMgr.code, 'Esc');
      expect(taskMgr.mods, ['ctrl', 'shift']);

      final clip = byLabel('Screenshot to clipboard');
      expect(clip.code, 'PrintScreen');
      expect(clip.mods, isEmpty);

      final zoomReset = byLabel('Zoom reset');
      expect(zoomReset.code, '0');
      expect(zoomReset.mods, ['ctrl']);

      final copy = byLabel('Copy');
      expect(copy.code, 'C');
      expect(copy.mods, ['ctrl']);
    });

    test('kShortcutsTitle is "Shortcuts"', () {
      expect(kShortcutsTitle, 'Shortcuts');
    });
  });

  group('ShortcutButton press + gating', () {
    const spec = ShortcutSpec(
      label: 'Show desktop',
      combo: 'Win+D',
      icon: Symbols.desktop_windows_rounded,
      code: 'D',
      mods: ['win'],
    );

    testWidgets('enabled: a press-DOWN fires onPress exactly once', (t) async {
      var fired = 0;
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ShortcutButton(
            spec: spec,
            enabled: true,
            onPress: () => fired++,
          ),
        ),
      ));

      final gesture = await t.startGesture(
        t.getCenter(find.text('Show desktop')),
      );
      await t.pump();
      expect(fired, 1, reason: 'onPress fires on tap-DOWN, once');

      await gesture.up();
      await t.pump(const Duration(milliseconds: 120));
      expect(fired, 1, reason: 'tap-up does not fire again');
    });

    testWidgets('disabled: a press fires no onPress', (t) async {
      var fired = 0;
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ShortcutButton(
            spec: spec,
            enabled: false,
            onPress: () => fired++,
          ),
        ),
      ));

      await t.tap(find.text('Show desktop'));
      await t.pump();
      expect(fired, 0, reason: 'gated button is inert (muted-not-red)');
    });

    testWidgets('renders effect label 14/w600, combo 12/w400, icon size 24',
        (t) async {
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ShortcutButton(
            spec: spec,
            enabled: true,
            onPress: () {},
          ),
        ),
      ));

      final effect = t.widget<Text>(find.text('Show desktop'));
      expect(effect.style?.fontSize, 14);
      expect(effect.style?.fontWeight, FontWeight.w600);

      final combo = t.widget<Text>(find.text('Win+D'));
      expect(combo.style?.fontSize, 12);
      expect(combo.style?.fontWeight, FontWeight.w400);

      final icon = t.widget<Icon>(find.byType(Icon));
      expect(icon.size, 24);
    });
  });

  group('ShortcutsScreen render + wiring', () {
    testWidgets('renders all 4 section headers and 25 buttons', (t) async {
      t.view.physicalSize = const Size(1000, 4000);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);

      await t.pumpWidget(_host(_FakeService(connected: true)));

      for (final header in const [
        'Windows & Desktop',
        'Screenshot',
        'Browser & App',
        'Editing',
      ]) {
        expect(find.text(header), findsOneWidget, reason: 'missing "$header"');
      }

      expect(find.byType(ShortcutButton), findsNWidgets(25));

      await t.pumpWidget(const SizedBox());
    });

    testWidgets('connected: tapping "Show desktop" sends one Win+D KeyMsg',
        (t) async {
      t.view.physicalSize = const Size(1000, 4000);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);

      final svc = _FakeService(connected: true);
      await t.pumpWidget(_host(svc));

      await t.tap(find.text('Show desktop'));
      await t.pump();

      expect(svc.reliable, hasLength(1));
      final msg = svc.reliable.single as KeyMsg;
      expect(msg.code, 'D');
      expect(msg.action, 'tap');
      expect(msg.mods, ['win']);

      // Let the 100ms accent-flash timer settle before teardown.
      await t.pump(const Duration(milliseconds: 120));
      await t.pumpWidget(const SizedBox());
    });

    testWidgets('connected: tapping "Copy" sends Ctrl+C', (t) async {
      t.view.physicalSize = const Size(1000, 4000);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);

      final svc = _FakeService(connected: true);
      await t.pumpWidget(_host(svc));

      // "Copy" sits at the bottom (Editing section) — scroll it into view.
      await t.scrollUntilVisible(find.text('Copy'), 300);
      await t.tap(find.text('Copy'));
      await t.pump();

      expect(svc.reliable, hasLength(1));
      final msg = svc.reliable.single as KeyMsg;
      expect(msg.code, 'C');
      expect(msg.action, 'tap');
      expect(msg.mods, ['ctrl']);

      // Let the 100ms accent-flash timer settle before teardown.
      await t.pump(const Duration(milliseconds: 120));
      await t.pumpWidget(const SizedBox());
    });

    testWidgets('disconnected: pressing a button sends nothing (gated muted)',
        (t) async {
      t.view.physicalSize = const Size(1000, 4000);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);

      final svc = _FakeService(connected: false);
      await t.pumpWidget(_host(svc));

      // Same 25 buttons render (layout unchanged) — but inert.
      expect(find.byType(ShortcutButton), findsNWidgets(25));

      await t.tap(find.text('Show desktop'));
      await t.pump();

      expect(svc.reliable, isEmpty, reason: 'unauthed buttons are inert');

      // Gated content renders kMuted, not red.
      final effect = t.widget<Text>(find.text('Show desktop'));
      expect(effect.style?.color, const Color(0xFF6B7280));

      await t.pumpWidget(const SizedBox());
    });
  });
}
