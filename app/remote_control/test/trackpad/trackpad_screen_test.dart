// Task 1 (08-02, Wave 0) — TrackpadScreen composition smoke test.
//
// The behavior-neutrality safety net for the D8-04 extraction: this pins the
// chrome the slimmed screen must still render AFTER TrackpadCore is carved out
// of _TrackpadScreenState. It is green against the CURRENT (fat) screen and
// must stay green after Task 3 slims it — that green-through-the-refactor is
// the extraction's behavior-neutral guarantee (RESEARCH Pitfall 7: no
// trackpad_screen_test.dart existed before this plan).
//
// House harness idiom (quick_bar_test.dart): a ProviderScope override gives
// the screen an in-memory fake-KV-backed ConnectionService — no sockets, no
// platform channels. The global keep-awake singleton (which the fat screen
// acquires in initState) routes through a no-op WakelockPlus platform stub so
// the plugin call never throws in the test harness.

// The wakelock platform-interface import is a test-only stub seam; it is a
// transitive (not direct) dependency, hence the file-scoped ignore.
// ignore_for_file: depend_on_referenced_packages

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_protocol/remote_protocol.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:wakelock_plus_platform_interface/wakelock_plus_platform_interface.dart';

import 'package:remote_control/keyboard/key_pads.dart';
import 'package:remote_control/keyboard/key_rows.dart';
import 'package:remote_control/keyboard/keyboard_panel.dart';
import 'package:remote_control/net/connection_providers.dart';
import 'package:remote_control/net/connection_service.dart';
import 'package:remote_control/screens/connection_copy.dart';
import 'package:remote_control/store/device_store.dart';
import 'package:remote_control/trackpad/mouse_buttons.dart';
import 'package:remote_control/trackpad/trackpad_core.dart';
import 'package:remote_control/trackpad/trackpad_screen.dart';

/// No-op wakelock platform so the screen's keep-awake acquire/release never
/// hits an (absent) plugin in the test harness.
class _NoopWakelock extends WakelockPlusPlatformInterface {
  @override
  Future<void> toggle({required bool enable}) async {}

  @override
  Future<bool> get enabled async => false;
}

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

Widget _host() => ProviderScope(
      overrides: [
        connectionServiceProvider.overrideWith(
          (ref) => ConnectionService(
            store: DeviceStore(secure: _FakeSecureKv(), prefs: _FakePrefsKv()),
          ),
        ),
        // The docked panel reads its persisted pad at mount now (260809-ipc),
        // so the store must be in-memory here: the real one constructs a
        // SharedPreferencesAsync, which throws without a platform.
        panelPadStoreProvider.overrideWithValue(
          KeyboardPadStore(prefs: _FakePrefsKv(), key: kPanelPadPrefsKey),
        ),
      ],
      child: const MaterialApp(home: TrackpadScreen()),
    );

void main() {
  setUpAll(() {
    wakelockPlusPlatformInstance = _NoopWakelock();
  });

  testWidgets('renders the surface hint + L/M/R bar + tune + keyboard toggle',
      (t) async {
    await t.pumpWidget(_host());
    await t.pump();

    // The gesture surface hint (not connected in the harness — idle service).
    expect(find.text(kTrackpadHintNotConnected), findsOneWidget);

    // The docked L/M/R mouse-button bar (PAD-02).
    expect(find.byType(MouseButtonsBar), findsOneWidget);
    expect(find.text('L'), findsOneWidget);
    expect(find.text('M'), findsOneWidget);
    expect(find.text('R'), findsOneWidget);

    // The bottom-right cluster: tune affordance (D-05) + keyboard toggle (D-07).
    expect(find.byIcon(Symbols.tune_rounded), findsOneWidget);
    expect(find.byIcon(Symbols.keyboard_rounded), findsOneWidget);

    // Dispose the tree so the header chip's throttle timer is cancelled and
    // the keep-awake hold is released before the harness tears down.
    await t.pumpWidget(const SizedBox());
  });

  // ── B2 REGRESSION GUARDS (260809-ipc, D-91/D-93) ────────────────────────
  //
  // These three cases exist to prove the docked panel measures the column it
  // ACTUALLY shares with the trackpad, not the whole window. In this tree the
  // obvious read —
  //
  //     MediaQuery.sizeOf(context).height
  //       - MediaQuery.paddingOf(context).top
  //       - MediaQuery.viewInsetsOf(context).bottom
  //
  // — silently returns the full window height, because the Scaffold's
  // resizeToAvoidBottomInset has already stripped the body's bottom view
  // insets and the SafeArea has already stripped its padding. The panel then
  // clamps against a column bigger than the real one, by the status inset,
  // the bottom safe inset AND the entire IME, which is exactly where the
  // live-trackpad guarantee needs the clamp to bind.
  //
  // Cases 2 and 3 are the DISCRIMINATORS: they go red against the naive
  // formula (80 and 176 respectively, both under the floor). Case 1 has no
  // IME up, so both formulas agree there — it is the reference-device number
  // and the "still moves the cursor" proof, not a discriminator. An
  // inset-free harness cannot catch this class of bug at all: at zero insets
  // the wrong formula and the right one are identical.
  //
  // Every asserted floor is COMPUTED from the driven metrics
  // (0.45 x columnHeight - 64), never hard-coded, so the assertion cannot
  // drift away from the guarantee it stands for.

  /// Drives the raw view metrics. devicePixelRatio 1 keeps FakeViewPadding
  /// values 1:1 with logical pixels. When an IME inset is present, `padding`
  /// bottom is 0 while `viewPadding` keeps the nav-bar value — that is how
  /// the platform reports it, and the difference is the whole point.
  void driveView(
    WidgetTester t, {
    required Size size,
    required double top,
    required double bottom,
    double ime = 0,
  }) {
    t.view.devicePixelRatio = 1.0;
    t.view.physicalSize = size;
    t.view.viewPadding = FakeViewPadding(top: top, bottom: bottom);
    t.view.padding = FakeViewPadding(top: top, bottom: ime > 0 ? 0 : bottom);
    t.view.viewInsets = FakeViewPadding(bottom: ime);
    addTearDown(t.view.reset);
  }

  /// The column the panel and the trackpad actually share.
  double columnOf({
    required Size size,
    required double top,
    required double bottom,
    double ime = 0,
  }) =>
      size.height - top - (ime > bottom ? ime : bottom);

  /// The live-trackpad guarantee, computed rather than quoted.
  double floorFor(double column) => 0.45 * column - 64;

  /// The no-VERTICAL-overflow proof: in an overflowing Flex the children keep
  /// their natural sizes and their sum exceeds the constraint, so a sum equal
  /// to the shared column is exactly the assertion that the panel fits.
  ///
  /// Deliberately NOT `takeException(), isNull`: at 360dp the modifier chips'
  /// "Shift" label overflows its quarter-row by ~7px HORIZONTALLY. That is
  /// the shared chip-row geometry (identical in the full-screen keyboard and
  /// in the panel that shipped before this task), it predates this change,
  /// and it is logged in deferred-items.md rather than fixed here.
  void expectColumnFits(WidgetTester t, double column) {
    final trackpad = t.getSize(find.byType(TrackpadCore)).height;
    final bar = t.getSize(find.byType(MouseButtonsBar)).height;
    final panel = t.getSize(find.byType(KeyboardPanel)).height;
    expect(trackpad + bar + panel, closeTo(column, 0.01),
        reason: 'trackpad + button bar + panel must EXACTLY fill the shared '
            'column — a larger sum is a vertical overflow');
  }

  Widget hostWith(ConnectionService service, PrefsKv padPrefs) => ProviderScope(
        overrides: [
          connectionServiceProvider.overrideWith((ref) => service),
          panelPadStoreProvider.overrideWithValue(
            KeyboardPadStore(prefs: padPrefs, key: kPanelPadPrefsKey),
          ),
        ],
        child: const MaterialApp(home: TrackpadScreen()),
      );

  /// Mounts the screen with the docked panel seeded to [pad] and opened.
  Future<_RecordingService> openPanelOn(WidgetTester t, KeyboardPad pad) async {
    final service = _RecordingService()..authed = true;
    final prefs = _FakePrefsKv()..backing[kPanelPadPrefsKey] = pad.name;

    await t.pumpWidget(hostWith(service, prefs));
    await t.pump(); // the async pad load lands (panel still collapsed)
    await t.pump();

    // The keyboard toggle — the only keyboard_rounded glyph while collapsed
    // (the Type tab carries the same icon, but the tab bar is not mounted).
    await t.tap(find.byIcon(Symbols.keyboard_rounded));
    await t.pump();
    await t.pump(const Duration(milliseconds: 250)); // panel slide
    await t.pump();
    await t.pump(const Duration(milliseconds: 250)); // pad-height ease
    return service;
  }

  testWidgets(
      'B2/D-91: reference device, Numpad open — the trackpad is 322dp and '
      'still MOVES THE CURSOR (present is not enough)', (t) async {
    const size = Size(411, 891);
    driveView(t, size: size, top: 24, bottom: 48);
    final column = columnOf(size: size, top: 24, bottom: 48); // 819

    final service = await openPanelOn(t, KeyboardPad.numpad);
    expect(find.byType(NumpadPad), findsOneWidget);

    final trackpad = t.getSize(find.byType(TrackpadCore)).height;
    expect(trackpad, closeTo(322, 1),
        reason: 'column 819 - 64 button bar - 433 panel');
    expect(trackpad, greaterThanOrEqualTo(floorFor(column)));

    // The tallest pad is open and the surface has shrunk — it must still be
    // a trackpad, not a decoration.
    final centre = t.getCenter(find.byType(TrackpadCore));
    final gesture = await t.startGesture(centre);
    await gesture.moveBy(const Offset(30, 0));
    await gesture.moveBy(const Offset(30, 0));
    await gesture.up();
    await t.pump(const Duration(seconds: 1));

    expect(service.moves, isNotEmpty,
        reason: 'a drag on the shrunken surface must still produce moves');
    expectColumnFits(t, column);

    await t.pumpWidget(const SizedBox());
  });

  testWidgets(
      'B2 DISCRIMINATOR: IME still raised 290dp mid-transition with Numpad '
      'open — the floor holds (the naive read yields 80 and fails)', (t) async {
    const size = Size(411, 891);
    driveView(t, size: size, top: 24, bottom: 24, ime: 290);
    final column = columnOf(size: size, top: 24, bottom: 24, ime: 290); // 577

    await openPanelOn(t, KeyboardPad.numpad);
    expect(find.byType(NumpadPad), findsOneWidget);

    final trackpad = t.getSize(find.byType(TrackpadCore)).height;
    expect(trackpad, greaterThanOrEqualTo(floorFor(column) - 0.001),
        reason: 'the clamp must bind against the REAL column (577), not the '
            'full 891 window the stripped MediaQuery would report');
    expect(trackpad, closeTo(195.65, 0.5));
    expectColumnFits(t, column);

    await t.pumpWidget(const SizedBox());
  });

  testWidgets(
      'B2 DISCRIMINATOR: short 360x640 viewport with Numpad open — the floor '
      'holds (the naive read yields 176 and fails)', (t) async {
    const size = Size(360, 640);
    driveView(t, size: size, top: 24, bottom: 24);
    final column = columnOf(size: size, top: 24, bottom: 24); // 592

    await openPanelOn(t, KeyboardPad.numpad);
    expect(find.byType(NumpadPad), findsOneWidget);

    final trackpad = t.getSize(find.byType(TrackpadCore)).height;
    expect(trackpad, greaterThanOrEqualTo(floorFor(column) - 0.001));
    expect(trackpad, closeTo(202.4, 0.5));
    expectColumnFits(t, column);

    // Drain the pre-existing HORIZONTAL chip-label overflow (see
    // expectColumnFits for why it is not this task's). It re-reports on every
    // paint, so drain to empty rather than once — and assert that every drained
    // error is that one, so a genuine new failure here still fails the test.
    var overflows = 0;
    for (var e = t.takeException(); e != null; e = t.takeException()) {
      expect(e.toString(), contains('overflowed'),
          reason: 'the ONLY exception tolerated here is the 360dp chip-label '
              'overflow logged in deferred-items.md');
      overflows++;
    }
    expect(overflows, greaterThan(0),
        reason: 'if this ever reaches zero, the chip row was fixed — delete '
            'this drain and restore a plain takeException-is-null assertion');

    await t.pumpWidget(const SizedBox());
  });
}

/// Recording service with a settable authed flag — the trackpad_core_test
/// idiom, reused so the B2 guards can prove the surface still MOVES.
class _RecordingService extends ConnectionService {
  _RecordingService()
      : super(
          store: DeviceStore(secure: _FakeSecureKv(), prefs: _FakePrefsKv()),
        );

  final List<(double, double)> moves = [];
  final List<RemoteMessage> reliable = [];
  bool authed = false;

  @override
  bool get isAuthed => authed;

  @override
  ChipStatus get chipStatus =>
      authed ? ChipStatus.connected : ChipStatus.disconnected;

  @override
  void sendMove(double dx, double dy) => moves.add((dx, dy));

  @override
  void sendReliable(RemoteMessage msg) => reliable.add(msg);
}
