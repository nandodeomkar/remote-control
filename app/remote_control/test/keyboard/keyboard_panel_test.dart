/// KeyboardPanel widget tests (04-05 Task 3 shell, D-07; 04-06 Task 3 rows,
/// KEY-03/D-10/D-12).
///
/// Shell contract (04-05): expanding requests focus on the provided
/// FocusNode (raising the system IME on device), collapsing unfocuses, and
/// the HiddenTextInput stays mounted — SAME State — across the toggle so the
/// Android input connection survives (Pitfall 6).
///
/// Rows contract (04-06): chips row + switcher + active KeyRows in UI-SPEC
/// order; all three KeyMsg emission paths (modifier hold down/up, key-cap
/// down/up, tap+mods with auto-reset) ride the injected send seam; and the
/// D-12 disconnected transition — driven here by a FAKE changes stream —
/// provably resets the FSM with zero wire sends.
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
import 'package:remote_control/keyboard/keyboard_panel.dart';
import 'package:remote_control/store/device_store.dart';

/// In-memory [PrefsKv] so the pad store never touches the platform.
class _FakePrefsKv implements PrefsKv {
  final Map<String, String> map = {};

  @override
  Future<String?> getString(String key) async => map[key];

  @override
  Future<void> setString(String key, String value) async {
    map[key] = value;
  }
}

void main() {
  late FocusNode focusNode;
  late ImeDiffProducer producer;
  late List<TextMsg> emitted;
  late List<RemoteMessage> sent;
  late StreamController<void> changes;
  late bool disconnected;
  late _FakePrefsKv padPrefs;
  late KeyboardPadStore padStore;

  setUp(() {
    focusNode = FocusNode(debugLabel: 'test-ime');
    emitted = <TextMsg>[];
    producer = ImeDiffProducer(emit: emitted.add);
    sent = <RemoteMessage>[];
    changes = StreamController<void>.broadcast();
    disconnected = false;
    // Hoisted into setUp on purpose: successive host(...) pumps must share
    // ONE store value, or the persistence test would face a fresh (empty)
    // backing map on every rebuild.
    padPrefs = _FakePrefsKv();
    padStore = KeyboardPadStore(
      prefs: padPrefs,
      key: kPanelPadPrefsKey,
      migrateRetiredPanelKey: true,
    );
  });

  tearDown(() {
    focusNode.dispose();
    changes.close();
  });

  Widget host({required bool expanded, bool enabled = true}) => ProviderScope(
        overrides: [
          panelPadStoreProvider.overrideWithValue(padStore),
        ],
        child: MaterialApp(
          home: Scaffold(
            // Mirrors trackpad_screen.dart: resizeToAvoidBottomInset + an
            // outer SafeArea. Both matter — the Scaffold strips the body's
            // bottom view insets and the SafeArea strips its padding, which
            // is exactly why the panel reads the RAW view for its column
            // height, and why KeyboardTabBar's inner SafeArea contributes 0.
            resizeToAvoidBottomInset: true,
            body: SafeArea(
              child: SingleChildScrollView(
                child: Column(
                  children: [
                    KeyboardPanel(
                      expanded: expanded,
                      imeFocusNode: focusNode,
                      producer: producer,
                      enabled: enabled,
                      send: sent.add,
                      changes: changes.stream,
                      isDisconnected: () => disconnected,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );

  List<KeyMsg> sentKeys() => sent.whereType<KeyMsg>().toList();

  testWidgets('expanding focuses the IME node; collapsing unfocuses',
      (tester) async {
    await tester.pumpWidget(host(expanded: false));
    await tester.pumpAndSettle();
    expect(focusNode.hasFocus, isFalse);

    await tester.pumpWidget(host(expanded: true));
    await tester.pumpAndSettle();
    expect(focusNode.hasFocus, isTrue);

    await tester.pumpWidget(host(expanded: false));
    await tester.pumpAndSettle();
    expect(focusNode.hasFocus, isFalse);
  });

  testWidgets('HiddenTextInput stays mounted (same State) across the toggle',
      (tester) async {
    await tester.pumpWidget(host(expanded: false));
    await tester.pumpAndSettle();
    expect(find.byType(HiddenTextInput), findsOneWidget);
    final collapsedState =
        tester.state<State<HiddenTextInput>>(find.byType(HiddenTextInput));

    await tester.pumpWidget(host(expanded: true));
    await tester.pumpAndSettle();
    expect(find.byType(HiddenTextInput), findsOneWidget);
    final expandedState =
        tester.state<State<HiddenTextInput>>(find.byType(HiddenTextInput));

    // Same State object — the input connection is never detached.
    expect(identical(collapsedState, expandedState), isTrue);

    await tester.pumpWidget(host(expanded: false));
    await tester.pumpAndSettle();
    final recollapsedState =
        tester.state<State<HiddenTextInput>>(find.byType(HiddenTextInput));
    expect(identical(collapsedState, recollapsedState), isTrue);
  });

  testWidgets('typing into the hidden field emits diffs on the wire seam',
      (tester) async {
    await tester.pumpWidget(host(expanded: true));
    await tester.pumpAndSettle();
    expect(focusNode.hasFocus, isTrue);

    await tester.enterText(
      find.byType(TextField),
      '${kImeSentinel}hi',
    );
    await tester.pump();

    expect(emitted, hasLength(1));
    expect(emitted.single.bs, 0);
    expect(emitted.single.ins, 'hi');
  });

  testWidgets(
      'expanded panel renders the SAME four-pad deck as the full-screen '
      'keyboard: chips + tab bar with the shared labels and icons (D-92)',
      (tester) async {
    await tester.pumpWidget(host(expanded: true));
    await tester.pumpAndSettle();

    for (final label in ['Ctrl', 'Alt', 'Shift', 'Win']) {
      expect(find.text(label), findsOneWidget);
    }
    // The shared vocabulary, by reference — not a second copy of it.
    expect(find.byType(KeyboardTabBar), findsOneWidget);
    for (final pad in KeyboardPad.values) {
      expect(find.text(kKeyboardTabLabels[pad]!), findsOneWidget);
      expect(find.byIcon(kKeyboardTabIcons[pad]!), findsOneWidget);
    }
    // Type is the default landing pad: its slim extras row, no hint.
    expect(find.byType(TypePad), findsOneWidget);
    expect(find.text(kKeyboardHint), findsNothing);
    expect(find.text('Esc'), findsOneWidget);
    expect(find.byIcon(Symbols.arrow_forward_rounded), findsOneWidget);
  });

  testWidgets(
      'modifier long-press locks: hold-code down sent + lock icon; tap-off '
      'sends up (D-10 physical hold)', (tester) async {
    await tester.pumpWidget(host(expanded: true));
    await tester.pumpAndSettle();

    await tester.longPress(find.text('Win'));
    await tester.pumpAndSettle();

    expect(sentKeys(), hasLength(1));
    expect(sentKeys().single.code, 'WinLeft');
    expect(sentKeys().single.action, 'down');
    expect(find.byIcon(Symbols.lock_rounded), findsOneWidget);

    await tester.tap(find.text('Win'));
    await tester.pumpAndSettle();

    expect(sentKeys(), hasLength(2));
    expect(sentKeys().last.code, 'WinLeft');
    expect(sentKeys().last.action, 'up');
    expect(find.byIcon(Symbols.lock_rounded), findsNothing);
  });

  testWidgets(
      'key cap press-and-release sends down then up (KEY-04 autorepeat '
      'path)', (tester) async {
    await tester.pumpWidget(host(expanded: true));
    await tester.pumpAndSettle();

    // The arrow cluster sits below the 600px test viewport — bring it in.
    final rightCap = find.byKey(const ValueKey('cap-Right'));
    await tester.ensureVisible(rightCap);
    await tester.pumpAndSettle();

    final gesture = await tester.startGesture(tester.getCenter(rightCap));
    await tester.pump();
    await gesture.up();
    await tester.pump();

    expect(sentKeys(), hasLength(2));
    expect(sentKeys()[0].code, 'Right');
    expect(sentKeys()[0].action, 'down');
    expect(sentKeys()[1].code, 'Right');
    expect(sentKeys()[1].action, 'up');
  });

  testWidgets(
      'armed chip + key cap = one tap with mods, then the chip auto-resets '
      '(D-10 combo path)', (tester) async {
    await tester.pumpWidget(host(expanded: true));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Ctrl'));
    await tester.pumpAndSettle();
    expect(sentKeys(), isEmpty, reason: 'arming is client-local');

    await tester.tap(find.text('Esc'));
    await tester.pumpAndSettle();

    expect(sentKeys(), hasLength(1));
    expect(sentKeys().single.code, 'Esc');
    expect(sentKeys().single.action, 'tap');
    expect(sentKeys().single.mods, ['ctrl']);

    // Auto-reset (D-10): a second cap tap now rides the down/up path.
    await tester.tap(find.text('Esc'));
    await tester.pumpAndSettle();
    expect(sentKeys(), hasLength(3));
    expect(sentKeys()[1].action, 'down');
    expect(sentKeys()[2].action, 'up');
  });

  testWidgets(
      'D-12: the disconnected transition resets locked chips with ZERO '
      'wire sends (fake changes stream)', (tester) async {
    await tester.pumpWidget(host(expanded: true));
    await tester.pumpAndSettle();

    await tester.longPress(find.text('Win'));
    await tester.pumpAndSettle();
    expect(find.byIcon(Symbols.lock_rounded), findsOneWidget);
    final sendsBeforeDrop = sent.length;

    // The service drops: chip status flips to disconnected + a changes ping.
    disconnected = true;
    changes.add(null);
    await tester.pumpAndSettle();

    // Visual reset... but NO KeyMsg up — the socket is gone and CONN-07
    // release_all already freed the real key server-side.
    expect(find.byIcon(Symbols.lock_rounded), findsNothing);
    expect(sent.length, sendsBeforeDrop);
  });

  testWidgets(
      'CR-01: disconnect wipes producer and controller atomically — first '
      'post-reconnect keystroke emits only the new char', (tester) async {
    await tester.pumpWidget(host(expanded: true));
    await tester.pumpAndSettle();

    // Steady-state baseline: typed text diffs onto the wire.
    await tester.enterText(find.byType(TextField), '${kImeSentinel}secret');
    await tester.pump();
    expect(emitted.last.ins, 'secret');

    // The WiFi drop: chip flips to disconnected + a changes ping (D-12).
    disconnected = true;
    changes.add(null);
    await tester.pumpAndSettle();

    // The controller was wiped back to EXACTLY the sentinel — the atomic
    // reseed purged the pre-disconnect text from the buffer (T-04-03).
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      kImeSentinel,
    );
    final emissionsAfterWipe = emitted.length;

    // Reconnect: the true->false transition must NOT fire another reset,
    // and neither the wipe write-back nor the ping emits anything.
    disconnected = false;
    changes.add(null);
    await tester.pump();
    expect(emitted.length, emissionsAfterWipe,
        reason: 'the reset write-back itself must emit NO TextMsg');

    // First post-reconnect keystroke: ONLY the new char — never a replay
    // of the pre-disconnect text (KEY-01 across disconnects).
    await tester.enterText(find.byType(TextField), '${kImeSentinel}x');
    await tester.pump();
    expect(emitted.last.bs, 0);
    expect(emitted.last.ins, 'x');
    expect(emitted.last.ins.contains('secret'), isFalse,
        reason: 'pre-disconnect text must never replay after reconnect');
  });

  testWidgets('CR-01: post-reconnect backspace emits bs:1, never an insert',
      (tester) async {
    await tester.pumpWidget(host(expanded: true));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '${kImeSentinel}secret');
    await tester.pump();
    expect(emitted.last.ins, 'secret');

    // Drop, then reconnect.
    disconnected = true;
    changes.add(null);
    await tester.pumpAndSettle();
    disconnected = false;
    changes.add(null);
    await tester.pump();

    // A backspace on the wiped field: one trailing sentinel ZWSP shrinks.
    await tester.enterText(
      find.byType(TextField),
      kImeSentinel.substring(0, kImeSentinel.length - 1),
    );
    await tester.pump();

    // With the old one-sided reset this emitted ins:'secre' — an insert.
    expect(emitted.last.bs, 1);
    expect(emitted.last.ins, isEmpty);

    // The boundary reseed then restored the FULL sentinel — the existing
    // needsReseed/reseed path still works after the wipe.
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      kImeSentinel,
    );
  });

  testWidgets(
      'CR-02: rollover — press Right, press Down, release Right, release '
      'Down sends up for BOTH keys', (tester) async {
    await tester.pumpWidget(host(expanded: true));
    await tester.pumpAndSettle();

    // Both caps sit in the arrow cluster below the 600px test viewport.
    final rightCap = find.byKey(const ValueKey('cap-Right'));
    final downCap = find.byKey(const ValueKey('cap-Down'));
    await tester.ensureVisible(rightCap);
    await tester.pumpAndSettle();
    await tester.ensureVisible(downCap);
    await tester.pumpAndSettle();

    // Two concurrent pointers — each _KeyCap has its own GestureDetector so
    // both tap arenas win independently. Pump past the 100ms press deadline
    // after each press so onTapDown fires eagerly (the scrollable's drag
    // recognizer shares the arena and would otherwise defer it to release).
    final g1 = await tester.startGesture(tester.getCenter(rightCap));
    await tester.pump(const Duration(milliseconds: 150));
    final g2 = await tester.startGesture(tester.getCenter(downCap));
    await tester.pump(const Duration(milliseconds: 150));
    await g1.up();
    await tester.pump();
    await g2.up();
    await tester.pump();

    // Pre-fix, the single-slot _heldCode was overwritten by down:Down and
    // up:Right was swallowed — Right autorepeated on the PC indefinitely.
    expect(
      sentKeys().map((k) => '${k.action}:${k.code}').toList(),
      ['down:Right', 'down:Down', 'up:Right', 'up:Down'],
    );
  });

  testWidgets(
      'CR-02/D-12: disconnect mid-hold clears ALL held caps — a later '
      'release sends NO stale up', (tester) async {
    await tester.pumpWidget(host(expanded: true));
    await tester.pumpAndSettle();

    final rightCap = find.byKey(const ValueKey('cap-Right'));
    await tester.ensureVisible(rightCap);
    await tester.pumpAndSettle();

    final gesture = await tester.startGesture(tester.getCenter(rightCap));
    await tester.pump(const Duration(milliseconds: 150));
    expect(sentKeys(), hasLength(1));
    expect(sentKeys().single.action, 'down');

    // The service drops mid-hold: the D-12 transition wipes the held set.
    disconnected = true;
    changes.add(null);
    await tester.pumpAndSettle();
    final before = sent.length;

    await gesture.up();
    await tester.pump();

    // The release found remove('Right') false — no stale up rides into the
    // next session (CONN-07 release_all already freed the real key).
    expect(sent.length, before);
    expect(sentKeys().last.action, 'down');
  });

  testWidgets('gated panel renders chips and caps muted and inert',
      (tester) async {
    await tester.pumpWidget(host(expanded: true, enabled: false));
    await tester.pumpAndSettle();

    await tester.longPress(find.text('Win'));
    await tester.tap(find.text('Esc'));
    await tester.pumpAndSettle();

    expect(sent, isEmpty);
    expect(find.byIcon(Symbols.lock_rounded), findsNothing);
  });

  // ── The panel surface's own dispose / IN-04 / collapse proofs ────────────
  //
  // Added by 260809-ipc Task 1. The full-screen keyboard has had these since
  // 10-05; the docked panel had none of them, so "proven on both surfaces"
  // was a claim rather than a fact. The collapse case is a path this surface
  // has shipped since 04-05 and that no test has ever covered: collapsing
  // swaps the chrome for a zero-height box, which unmounts the caps while the
  // panel State itself survives.

  /// Presses and holds the cap keyed `cap-[code]`, pumping past the 100ms
  /// press deadline so onTapDown fires eagerly (the host scrollable's drag
  /// recognizer shares the arena and would otherwise defer it to release).
  Future<TestGesture> holdCap(WidgetTester tester, String code) async {
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(ValueKey('cap-$code'))),
    );
    await tester.pump(const Duration(milliseconds: 150));
    return gesture;
  }

  List<String> wire() =>
      sentKeys().map((k) => '${k.action}:${k.code}').toList();

  testWidgets(
      'panel-dispose LIVE flush: a held cap AND a locked modifier both get '
      'their ups when the host unmounts on a live socket', (tester) async {
    await tester.pumpWidget(host(expanded: true));
    await tester.pumpAndSettle();

    final gesture = await holdCap(tester, 'Esc');
    await tester.longPress(find.text('Win'));
    await tester.pump(const Duration(milliseconds: 250));
    expect(wire(), ['down:Esc', 'down:WinLeft']);

    // Unmount the whole host mid-hold. The cap-level dispose release and the
    // owner's flush are idempotent through the remove() guard — each owed up
    // fires exactly ONCE.
    await tester.pumpWidget(const SizedBox());

    final ups = wire().skip(2).toList();
    expect(ups.toSet(), {'up:Esc', 'up:WinLeft'},
        reason: 'every owed cap up + the releaseAll modifier up must flush');
    expect(ups.length, 2, reason: 'exactly once each — no duplicates');

    await gesture.up();
    expect(wire().length, 4);
  });

  testWidgets(
      'panel-dispose on a DISCONNECTED socket sends NOTHING — stale ups must '
      'never leak into a new session', (tester) async {
    await tester.pumpWidget(host(expanded: true));
    await tester.pumpAndSettle();

    final gesture = await holdCap(tester, 'Esc');
    await tester.longPress(find.text('Win'));
    await tester.pump(const Duration(milliseconds: 250));
    expect(wire(), ['down:Esc', 'down:WinLeft']);

    disconnected = true;
    changes.add(null);
    await tester.pump();
    await tester.pump();
    final before = sent.length;

    await tester.pumpWidget(const SizedBox());
    await gesture.up();

    expect(sent.length, before,
        reason: 'a disconnected dispose flushes NOTHING (CONN-07 already '
            'freed the real keys)');
  });

  testWidgets(
      'IN-04: a cancelled press on the panel still emits the up',
      (tester) async {
    await tester.pumpWidget(host(expanded: true));
    await tester.pumpAndSettle();

    final gesture = await holdCap(tester, 'Esc');
    expect(wire(), ['down:Esc']);

    // What a scroll/drag recognizer claiming the pointer does to the cap.
    await gesture.cancel();
    await tester.pump();

    expect(wire(), ['down:Esc', 'up:Esc'],
        reason: 'release handlers are always wired — a cancelled press must '
            'still free the held key');

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('collapsing the panel mid-hold releases the held key exactly '
      'once', (tester) async {
    await tester.pumpWidget(host(expanded: true));
    await tester.pumpAndSettle();

    final gesture = await holdCap(tester, 'Esc');
    expect(wire(), ['down:Esc']);

    // Collapse (NOT unmount): the chrome becomes a zero-height box, so the
    // caps dispose while the panel State — and the owner — live on.
    await tester.pumpWidget(host(expanded: false));
    await tester.pump();

    expect(wire(), ['down:Esc', 'up:Esc'],
        reason: 'the cap dispose must free the key when the panel collapses');

    // The later pointer release finds remove() false — no duplicate up.
    await gesture.up();
    await tester.pump();
    expect(wire(), ['down:Esc', 'up:Esc']);

    await tester.pumpWidget(const SizedBox());
  });

  // ── The four-pad deck: height, IME and persistence (D-92 / D-93 / D-94) ──

  /// Drives the raw view metrics the panel measures. `devicePixelRatio = 1`
  /// keeps FakeViewPadding values 1:1 with logical pixels.
  void driveView(
    WidgetTester tester, {
    Size size = const Size(411, 891),
    double top = 24,
    double bottom = 24,
  }) {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = size;
    tester.view.viewPadding = FakeViewPadding(top: top, bottom: bottom);
    tester.view.padding = FakeViewPadding(top: top, bottom: bottom);
    tester.view.viewInsets = FakeViewPadding.zero;
    addTearDown(tester.view.reset);
  }

  /// Taps [pad]'s tab and pumps through the 200ms page animation plus a
  /// settle frame (the outgoing page disposes after the settle). The
  /// zero-duration pump starts the ticker; the 250ms pump runs it out.
  Future<void> goToTab(WidgetTester tester, KeyboardPad pad) async {
    await tester.tap(find.text(kKeyboardTabLabels[pad]!));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pump();
    // ...then let the pad-height AnimatedSize run out too.
    await tester.pump(const Duration(milliseconds: 250));
  }

  double deckHeight(WidgetTester tester) =>
      tester.getSize(find.byType(PageView)).height;

  double panelHeight(WidgetTester tester) =>
      tester.getSize(find.byType(AnimatedSize)).height;

  testWidgets(
      'each pad gets its sizing-contract height, and Type < Arrows < Fn < '
      'Numpad (D-93)', (tester) async {
    // 411x891 with 24dp top and 24dp gesture-nav insets: columnHeight 843,
    // ceiling 342.65 — above every table value, so nothing clamps here.
    driveView(tester);
    await tester.pumpWidget(host(expanded: true));
    await tester.pumpAndSettle();

    final measured = <KeyboardPad, double>{};
    for (final pad in KeyboardPad.values) {
      if (pad != KeyboardPad.type) await goToTab(tester, pad);
      expect(deckHeight(tester), kPanelPadHeights[pad],
          reason: '${pad.name} pad viewport');
      expect(panelHeight(tester), kPanelPadHeights[pad]! + kPanelChromeHeight,
          reason: '${pad.name} panel total (viewport + 121 chrome)');
      measured[pad] = panelHeight(tester);
    }

    expect(measured[KeyboardPad.type], 201);
    expect(measured[KeyboardPad.arrows], 393);
    expect(measured[KeyboardPad.fn], 425);
    expect(measured[KeyboardPad.numpad], 433);

    expect(measured[KeyboardPad.type]!, lessThan(measured[KeyboardPad.arrows]!));
    expect(measured[KeyboardPad.arrows]!, lessThan(measured[KeyboardPad.fn]!));
    expect(measured[KeyboardPad.fn]!, lessThan(measured[KeyboardPad.numpad]!));

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the pad height change ANIMATES over the existing 200ms ease',
      (tester) async {
    driveView(tester);
    await tester.pumpWidget(host(expanded: true));
    await tester.pumpAndSettle();
    expect(panelHeight(tester), 201);

    // Page to Numpad; the height only starts moving once the page settles.
    await tester.tap(find.text(kKeyboardTabLabels[KeyboardPad.numpad]!));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pump();

    // Mid-tween: strictly between the two totals, i.e. not a jump cut.
    await tester.pump(const Duration(milliseconds: 100));
    final mid = panelHeight(tester);
    expect(mid, greaterThan(201));
    expect(mid, lessThan(433));

    await tester.pump(const Duration(milliseconds: 200));
    expect(panelHeight(tester), 433);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'the system IME rises on the Type pad only: paging to Numpad lowers it, '
      'paging back raises it', (tester) async {
    driveView(tester);
    await tester.pumpWidget(host(expanded: true));
    await tester.pumpAndSettle();
    expect(focusNode.hasFocus, isTrue, reason: 'landing on Type raises it');

    await goToTab(tester, KeyboardPad.numpad);
    expect(find.byType(NumpadPad), findsOneWidget);
    expect(focusNode.hasFocus, isFalse,
        reason: 'a non-Type pad wants the height, not the IME');

    await goToTab(tester, KeyboardPad.type);
    expect(focusNode.hasFocus, isTrue);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'persistence: a page change writes keyboard.panelPad; a fresh mount '
      'over the same prefs lands on the persisted pad (D-94)', (tester) async {
    driveView(tester);
    await tester.pumpWidget(host(expanded: true));
    await tester.pumpAndSettle();
    expect(find.byType(TypePad), findsOneWidget);

    await goToTab(tester, KeyboardPad.numpad);
    expect(padPrefs.map[kPanelPadPrefsKey], 'numpad');
    expect(padPrefs.map.containsKey(kKeyboardPadPrefsKey), isFalse,
        reason: "the panel must never write the full-screen keyboard's key");

    // Unmount, then remount over the SAME store — a cold panel open.
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(host(expanded: true));
    await tester.pump(); // async prefs load lands + restore jump
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.byType(NumpadPad), findsOneWidget,
        reason: 'the landing pad must be the persisted one');
    expect(find.byType(TypePad), findsNothing);
    expect(focusNode.hasFocus, isFalse,
        reason: 'a non-Type landing must not raise the IME');

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'persistence survives the REAL open path: the panel mounts COLLAPSED, '
      'the prefs load lands with no deck to jump, and expanding still arrives '
      'on the persisted pad', (tester) async {
    // The production sequence — trackpad_screen.dart mounts the panel
    // collapsed and it stays that way until the keyboard toggle is tapped.
    // A restore that gave up on finding a PageView here would make the
    // persisted pad unreachable on every real open.
    driveView(tester);
    padPrefs.map[kPanelPadPrefsKey] = 'numpad';

    await tester.pumpWidget(host(expanded: false));
    await tester.pump(); // the async prefs load lands while collapsed
    await tester.pump();

    await tester.pumpWidget(host(expanded: true));
    await tester.pumpAndSettle();

    expect(find.byType(NumpadPad), findsOneWidget,
        reason: 'the owed restore must land as soon as the deck exists');
    expect(find.byType(TypePad), findsNothing);
    expect(focusNode.hasFocus, isFalse,
        reason: 'expanding onto a non-Type pad must not raise the IME at all '
            '— not even for a frame');
    expect(panelHeight(tester), 433);

    await tester.pumpWidget(const SizedBox());
  });
}
