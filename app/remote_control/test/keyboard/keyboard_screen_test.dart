/// KeyboardScreen sacred-invariant suite (10-05) — the auditable proof that
/// every stuck-key contract survived the panel -> full-screen-pads rebuild.
///
/// The screen reads `connectionServiceProvider` / `connectionStatusProvider`,
/// so a recording [_FakeService] (controllable `changes` ping stream +
/// mutable `chipStatus` + recorded `sendReliable`) drives it via
/// ProviderScope overrides; an in-memory [PrefsKv] backs the `keyboard.pad`
/// store so persistence is asserted without a platform.
///
/// The five named contracts (10-UI-SPEC §Stuck-key invariants):
///
/// - **CR-01 cap-dispose release on page leave** — leaving a pad disposes
///   its caps (`allowImplicitScrolling: false`, no retained page State);
///   a cap disposed mid-hold releases its held key.
/// - **CR-02 held-set tracking** — rollover between concurrently held caps
///   sends every up; a disconnect mid-hold wipes the set so a later release
///   sends NO stale up.
/// - **IN-04 always-wired releases** — a cancelled press (a PageView drag
///   claiming the gesture, teardown, etc.) still emits the up.
/// - **D-12 disconnect reset** — the disconnected transition resets locked
///   chips with ZERO wire sends and fires the CR-01 atomic IME wipe (no
///   pre-disconnect text replay, T-04-03).
/// - **Screen-dispose LIVE flush** — popping the screen with keys/locked
///   mods held on a LIVE socket flushes every owed up + releaseAll(); a
///   DISCONNECTED dispose sends nothing.
///
/// Plus the screen contracts: `keyboard.pad` persistence + seeded landing,
/// IME raised only on the Type pad, and the persistent chip row / tab bar /
/// HiddenTextInput surviving page switches.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_protocol/remote_protocol.dart';

import 'package:remote_control/keyboard/diff_ops.dart';
import 'package:remote_control/keyboard/hidden_text_input.dart';
import 'package:remote_control/keyboard/key_pads.dart';
import 'package:remote_control/keyboard/key_rows.dart';
import 'package:remote_control/keyboard/keyboard_screen.dart';
import 'package:remote_control/net/connection_providers.dart';
import 'package:remote_control/net/connection_service.dart';
import 'package:remote_control/store/device_store.dart';

class _FakeSecureKv implements SecureKv {
  final Map<String, String> backing = {};
  @override
  Future<String?> read(String key) async => backing[key];
  @override
  Future<void> write(String key, String value) async => backing[key] = value;
  @override
  Future<void> delete(String key) async => backing.remove(key);
}

/// In-memory [PrefsKv]: backs both the fake service's DeviceStore and the
/// `keyboard.pad` store (asserted directly in the persistence test).
class _FakePrefsKv implements PrefsKv {
  final Map<String, String> backing = {};
  @override
  Future<String?> getString(String key) async => backing[key];
  @override
  Future<void> setString(String key, String value) async {
    backing[key] = value;
  }
}

/// Recording service with a controllable `changes` ping stream and a
/// mutable chip status — the seams the screen's D-12 wiring probes.
class _FakeService extends ConnectionService {
  _FakeService()
      : super(
          store: DeviceStore(secure: _FakeSecureKv(), prefs: _FakePrefsKv()),
        );

  ChipStatus chip = ChipStatus.connected;
  final List<RemoteMessage> reliable = [];
  final StreamController<void> pings = StreamController<void>.broadcast();

  @override
  ChipStatus get chipStatus => chip;

  @override
  bool get isAuthed => chip == ChipStatus.connected;

  @override
  Stream<void> get changes => pings.stream;

  @override
  void sendReliable(RemoteMessage msg) => reliable.add(msg);

  /// The WiFi drop: chip flips to disconnected + a changes ping (D-12).
  void drop() {
    chip = ChipStatus.disconnected;
    pings.add(null);
  }

  /// Reconnect: chip back to connected + a changes ping.
  void reconnect() {
    chip = ChipStatus.connected;
    pings.add(null);
  }
}

void main() {
  late _FakeService svc;
  late _FakePrefsKv padPrefs;

  setUp(() {
    svc = _FakeService();
    padPrefs = _FakePrefsKv();
  });

  tearDown(() {
    svc.pings.close();
  });

  Widget host({_FakeService? service, _FakePrefsKv? prefs}) => ProviderScope(
        overrides: [
          connectionServiceProvider.overrideWith((ref) => service ?? svc),
          keyboardPadStoreProvider.overrideWithValue(
            KeyboardPadStore(prefs: prefs ?? padPrefs),
          ),
        ],
        child: const MaterialApp(home: KeyboardScreen()),
      );

  List<KeyMsg> sentKeys() => svc.reliable.whereType<KeyMsg>().toList();

  List<String> wire() =>
      sentKeys().map((k) => '${k.action}:${k.code}').toList();

  /// Taps [label]'s bottom tab and pumps through the 200ms page animation
  /// plus a settle frame (the outgoing page disposes after the settle).
  /// The zero-duration pump starts the ticker (its first tick is elapsed 0);
  /// the 250ms pump then runs the animation to completion.
  Future<void> goToTab(WidgetTester tester, String label) async {
    await tester.tap(find.text(label));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pump();
  }

  /// Presses and holds the cap keyed `cap-[code]`, pumping past the 100ms
  /// press deadline so onTapDown fires eagerly (the PageView's horizontal
  /// drag recognizer shares the arena and would otherwise defer it).
  Future<TestGesture> holdCap(WidgetTester tester, String code) async {
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(ValueKey('cap-$code'))),
    );
    await tester.pump(const Duration(milliseconds: 150));
    return gesture;
  }

  testWidgets(
      'CR-01: a cap held across a PAGE LEAVE releases — the outgoing pad '
      'disposes and fires the up (no retained page State)', (tester) async {
    await tester.pumpWidget(host());
    await tester.pump();

    await goToTab(tester, 'Arrows');
    expect(find.byType(ArrowsPad), findsOneWidget);

    final gesture = await holdCap(tester, 'Down');
    expect(wire(), ['down:Down']);

    // Page to Numpad while the cap is still held: the PageView disposes the
    // Arrows caps (default child lifecycle, allowImplicitScrolling: false) —
    // that dispose IS the release mechanism.
    await goToTab(tester, 'Numpad');
    expect(find.byType(ArrowsPad), findsNothing);
    expect(wire(), ['down:Down', 'up:Down'],
        reason: 'leaving the pad must release the held key');

    // The later pointer release finds remove() false — no duplicate up.
    await gesture.up();
    await tester.pump();
    expect(wire(), ['down:Down', 'up:Down']);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'CR-02: rollover — press Right, press Down, release Right, release '
      'Down sends up for BOTH keys', (tester) async {
    await tester.pumpWidget(host());
    await tester.pump();
    await goToTab(tester, 'Arrows');

    final g1 = await holdCap(tester, 'Right');
    final g2 = await holdCap(tester, 'Down');
    await g1.up();
    await tester.pump();
    await g2.up();
    await tester.pump();

    expect(wire(), ['down:Right', 'down:Down', 'up:Right', 'up:Down']);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'CR-02/D-12: disconnect mid-hold wipes the held set — a later release '
      'sends NO stale up', (tester) async {
    await tester.pumpWidget(host());
    await tester.pump();
    await goToTab(tester, 'Arrows');

    final gesture = await holdCap(tester, 'Right');
    expect(wire(), ['down:Right']);

    svc.drop();
    await tester.pump();
    await tester.pump();
    final before = svc.reliable.length;

    await gesture.up();
    await tester.pump();

    // remove('Right') found nothing — no stale up rides into a new session
    // (CONN-07 release_all already freed the real key).
    expect(svc.reliable.length, before,
        reason: 'the disconnected transition itself and the late release '
            'must send ZERO frames');
    expect(wire().last, 'down:Right');

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'IN-04: a cancelled non-deferred press (onTapCancel path) still emits '
      'the up', (tester) async {
    await tester.pumpWidget(host());
    await tester.pump();

    // Type pad slim extras row: hold Esc, then cancel the gesture (what a
    // PageView drag claiming the pointer does to the cap).
    final gesture = await holdCap(tester, 'Esc');
    expect(wire(), ['down:Esc']);

    await gesture.cancel();
    await tester.pump();
    expect(wire(), ['down:Esc', 'up:Esc'],
        reason: 'release handlers are always wired — a cancelled press must '
            'still free the held key');

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'D-12: the disconnected transition resets a locked chip with ZERO '
      'wire sends and fires the atomic IME wipe (no text replay)',
      (tester) async {
    await tester.pumpWidget(host());
    await tester.pump();

    // Pre-disconnect typed text diffs onto the wire.
    await tester.enterText(find.byType(TextField), '${kImeSentinel}secret');
    await tester.pump();
    final textMsgs = svc.reliable.whereType<TextMsg>().toList();
    expect(textMsgs.last.ins, 'secret');

    // Lock Ctrl: the hold-down rides the wire, the lock glyph renders.
    await tester.longPress(find.text('Ctrl'));
    await tester.pump(const Duration(milliseconds: 250));
    expect(wire(), ['down:ControlLeft']);
    expect(find.byIcon(Symbols.lock_rounded), findsOneWidget);
    final sendsBeforeDrop = svc.reliable.length;

    svc.drop();
    await tester.pump();
    await tester.pump();

    // Visual reset with NO KeyMsg up — the socket is gone and CONN-07
    // release_all already freed the real key server-side.
    expect(find.byIcon(Symbols.lock_rounded), findsNothing);
    expect(svc.reliable.length, sendsBeforeDrop);

    // The CR-01 IME wipe: the hidden field's controller returned to EXACTLY
    // the sentinel — pre-disconnect text purged from the buffer (T-04-03).
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      kImeSentinel,
    );

    // Reconnect: the chip stays at rest (the FSM was reset, not just gated)
    // and the first post-reconnect keystroke emits ONLY the new char.
    svc.reconnect();
    await tester.pump();
    expect(find.byIcon(Symbols.lock_rounded), findsNothing);

    await tester.enterText(find.byType(TextField), '${kImeSentinel}x');
    await tester.pump();
    final afterReconnect = svc.reliable.whereType<TextMsg>().toList().last;
    expect(afterReconnect.bs, 0);
    expect(afterReconnect.ins, 'x',
        reason: 'pre-disconnect text must never replay after reconnect');

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'screen-dispose LIVE flush: a held cap AND a locked modifier both get '
      'their ups when the screen is popped on a live socket', (tester) async {
    await tester.pumpWidget(host());
    await tester.pump();

    final gesture = await holdCap(tester, 'Esc');
    await tester.longPress(find.text('Win'));
    await tester.pump(const Duration(milliseconds: 250));
    expect(wire(), ['down:Esc', 'down:WinLeft']);

    // Pop/dispose the whole screen mid-hold. Cap-level dispose release and
    // the screen-level flush are idempotent via the remove() guard — each
    // owed up fires exactly ONCE.
    await tester.pumpWidget(const SizedBox());

    final ups = wire().skip(2).toList();
    expect(ups.toSet(), {'up:Esc', 'up:WinLeft'},
        reason: 'every owed cap up + the releaseAll modifier up must flush');
    expect(ups.length, 2, reason: 'exactly once each — no duplicates');

    await gesture.up();
    expect(wire().length, 4);
  });

  testWidgets(
      'screen-dispose on a DISCONNECTED socket: NO sends — stale ups must '
      'never leak into a new session', (tester) async {
    await tester.pumpWidget(host());
    await tester.pump();

    final gesture = await holdCap(tester, 'Esc');
    await tester.longPress(find.text('Win'));
    await tester.pump(const Duration(milliseconds: 250));
    expect(wire(), ['down:Esc', 'down:WinLeft']);

    svc.drop();
    await tester.pump();
    await tester.pump();
    final before = svc.reliable.length;

    await tester.pumpWidget(const SizedBox());
    await gesture.up();

    expect(svc.reliable.length, before,
        reason: 'a disconnected dispose flushes NOTHING (CONN-07 already '
            'freed the real keys)');
  });

  testWidgets(
      'persistence: a page change persists keyboard.pad; the next mount '
      'seeds the landing pad from it', (tester) async {
    await tester.pumpWidget(host());
    await tester.pump();
    expect(find.byType(TypePad), findsOneWidget);

    await goToTab(tester, 'Numpad');
    expect(padPrefs.backing[kKeyboardPadPrefsKey], 'numpad');

    // Unmount, then remount over the SAME prefs (a fresh ProviderScope —
    // a cold screen open).
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(host());
    await tester.pump(); // async prefs load lands + restore jump
    await tester.pump();

    expect(find.byType(NumpadPad), findsOneWidget,
        reason: 'the landing pad must be the persisted one');
    expect(find.byType(TypePad), findsNothing);

    // Non-Type landing: the IME is NOT raised.
    expect(
      tester.widget<TextField>(find.byType(TextField)).focusNode!.hasFocus,
      isFalse,
    );

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'IME raise/lower: focused on the Type pad, unfocused on any other pad, '
      're-focused on return', (tester) async {
    await tester.pumpWidget(host());
    await tester.pump(); // post-frame requestFocus

    FocusNode imeNode() =>
        tester.widget<TextField>(find.byType(TextField)).focusNode!;

    expect(imeNode().hasFocus, isTrue,
        reason: 'landing on Type raises the IME');

    await goToTab(tester, 'Arrows');
    expect(imeNode().hasFocus, isFalse,
        reason: 'leaving Type lowers the IME — the pad gets full height');

    await goToTab(tester, 'Type');
    expect(imeNode().hasFocus, isTrue,
        reason: 'returning to Type raises the IME again');

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'persistent chrome: chip row + tab bar render on every pad and the '
      'HiddenTextInput keeps the SAME State across a page switch',
      (tester) async {
    await tester.pumpWidget(host());
    await tester.pump();

    for (final label in ['Ctrl', 'Alt', 'Shift', 'Win']) {
      expect(find.text(label), findsOneWidget);
    }
    expect(find.byType(KeyboardTabBar), findsOneWidget);
    final typeState =
        tester.state<State<HiddenTextInput>>(find.byType(HiddenTextInput));

    await goToTab(tester, 'Fn');
    expect(find.byType(FnPad), findsOneWidget);
    for (final label in ['Ctrl', 'Alt', 'Shift', 'Win']) {
      expect(find.text(label), findsOneWidget,
          reason: 'the modifier chips are persistent across pads');
    }
    expect(find.byType(KeyboardTabBar), findsOneWidget);

    // Mounted OUTSIDE the PageView: the input connection never detaches on
    // a page switch (Pitfall 6).
    final fnState =
        tester.state<State<HiddenTextInput>>(find.byType(HiddenTextInput));
    expect(identical(typeState, fnState), isTrue);

    await tester.pumpWidget(const SizedBox());
  });
}
