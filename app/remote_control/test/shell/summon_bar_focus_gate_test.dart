// Task 1 (13-09) — BAR-03's keyboard-icon focus gate, D-13-17's CORRECTED
// predicate, and 13-UI-SPEC CR-2's glyph swap. This is the one genuine
// security control in Phase 13: a pairing PIN typed on the phone must never be
// routed to the PC, where it would be typed into whatever window has focus and
// disclosed to every application there.
//
//  1. **The case the milestone's predicate fails.** With nothing focused the
//     keyboard icon is ENABLED. The original proposal gated on the focused node
//     being absent; it is essentially never absent (the focus manager reverts to
//     the root scope, and `WidgetsApp` autofocuses a scope around the
//     `Navigator`), so that predicate would have shipped a permanently disabled
//     button. This case is red against the wrong version and green against the
//     right one — it is the whole reason D-13-17 exists.
//  2. Focusing a text field IN THE BODY disables the keyboard icon; the
//     trackpad icon stays live and still raises. The gate is on one slot.
//  3. Unfocusing re-enables it. The gate is a state, not a latch.
//  4. **Disabled is not hidden** (13-RESEARCH §8, D-13-12). The disabled icon is
//     still `findsOneWidget`, and the bar's rect and BOTH slot rects are
//     identical within 0.01 across the swap. Geometry never moves.
//  5. CR-2 — the disabled state is a GLYPH SWAP, not a tint change. On the two
//     screens SC4 names the PC is by definition disconnected, so the icon is
//     already muted there and a tint-only disable would be invisible on exactly
//     those screens.
//  6. The disabled icon's tap does nothing and there is no ripple — `onTap` is
//     null, which is the whole implementation of "disabled" and removes the
//     splash for free.
//  7. **The Phase-15 escape.** A focus node the shell OWNS and declares as its
//     hidden IME node does not disable the icon, even though it is a real
//     editable text. Without this, raising the keyboard in Phase 15 would
//     disable the one affordance that dismisses it (13-RESEARCH Pitfall E), and
//     the only way out would be back.
//  8. The blocked-state sentence is DISCOVERABLE through the semantics tree
//     while the icon is disabled — not merely present as a constant. A disabled
//     button does not surface its own tooltip, so the tooltip rides as an
//     ANCESTOR of the tappable region (13-UI-SPEC § Copywriting Contract,
//     BINDING).
//  9. A focus change rebuilds ONLY the keyboard icon's subtree — the bar does
//     not rebuild and neither does the trackpad icon. The bar is mounted on the
//     trackpad's hot path on every screen, so the listener's scope is a
//     latency contract (P9).
//
// LOCATION BY KEY, NEVER BY GLYPH: `Symbols.keyboard_rounded` collides with
// `KeyboardTabBar`'s Type tab once Phase 15 mounts the tab bar inside the
// raised surface. Every glyph assertion below is scoped to a slot's key.
//
// NOTE ON SCREENS: this suite focuses fields it creates itself. It deliberately
// does NOT pump the pairing sheet or the device list, because the predicate
// under test is a property of the focused node and must hold for a screen that
// does not exist yet. A suite that proved the gate only on today's screens
// would pass for an allowlist too.

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_symbols_icons/symbols.dart';

import 'package:remote_control/shell/summon_bar.dart';
import 'package:remote_control/shell/summon_icon_button.dart';
import 'package:remote_control/shell/summon_scope.dart';

import 'summon_test_harness.dart';

/// The body's ordinary text field — stands in for the PIN field, both device
/// list fields, and any field a future screen grows.
const Key kProbeFieldKey = Key('focus-gate-probe-field');

/// A second field whose node the test hands to the shell as its hidden IME
/// node — the Phase-15 shape, built today.
const Key kShellFieldKey = Key('focus-gate-shell-field');

/// A body with one ordinary field, plus an optional field bound to [shellNode].
Widget _body({FocusNode? shellNode}) => Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(kHarnessRootText),
            const SizedBox(
              width: 200,
              child: TextField(key: kProbeFieldKey),
            ),
            if (shellNode != null)
              SizedBox(
                width: 200,
                child: TextField(key: kShellFieldKey, focusNode: shellNode),
              ),
          ],
        ),
      ),
    );

Finder _slot(Key key) => find.byKey(key);

/// The glyph a slot currently renders. Scoped to the slot, never global.
IconData _glyphOf(WidgetTester t, Key slot) => t
    .widget<Icon>(
      find.descendant(of: _slot(slot), matching: find.byType(Icon)),
    )
    .icon!;

/// The slot's tint.
Color? _tintOf(WidgetTester t, Key slot) => t
    .widget<Icon>(
      find.descendant(of: _slot(slot), matching: find.byType(Icon)),
    )
    .color;

/// True when the slot has a tap handler. `onTap: null` IS the disabled state
/// and is also what removes the ripple, so this one read covers both.
bool _enabled(WidgetTester t, Key slot) => t
        .widget<InkWell>(
          find.descendant(of: _slot(slot), matching: find.byType(InkWell)),
        )
        .onTap !=
    null;

SummonShellController _controllerOf(WidgetTester t) =>
    SummonScope.of(t.element(_slot(kProbeFieldKey)));

/// The first semantics node in the whole tree carrying [tooltip].
///
/// Walked from the root rather than read off the icon's element on purpose:
/// `Tooltip` publishes its message through an `OverlayPortal`, so the node is
/// NOT in the icon's own render-object ancestry and a lookup anchored on the
/// widget silently walks past it to the root. What the criterion asks is
/// whether a screen reader can reach the sentence, and this is that question.
SemanticsData? _semanticsWithTooltip(WidgetTester t, String tooltip) {
  final root = t.binding.rootElement!.renderObject!.debugSemantics!;
  SemanticsData? found;
  void visit(SemanticsNode node) {
    final data = node.getSemanticsData();
    if (data.tooltip == tooltip) {
      found ??= data;
      return;
    }
    node.visitChildren((child) {
      visit(child);
      return found == null;
    });
  }

  visit(root);
  return found;
}

void main() {
  setUp(installSummonTestPlatforms);

  testWidgets(
    'with NOTHING focused the keyboard icon is enabled — the case the '
    "milestone's absent-focus predicate would fail",
    (t) async {
      final nav = GlobalKey<NavigatorState>();
      await pumpShell(t, nav: nav, body: _body());

      // The focused node here is the framework's own scope, which is exactly
      // what makes the wrong predicate wrong: it is present, so a
      // "nothing focused" gate never fires, and the icon would be dead forever.
      expect(
        FocusManager.instance.primaryFocus,
        isNotNull,
        reason: 'the focus manager reverts to the root scope, so a predicate '
            'gating on an ABSENT focused node disables the icon permanently',
      );
      expect(localTextFieldHasFocus(null), isFalse);

      expect(_enabled(t, kSummonKeyboardIconKey), isTrue);
      expect(_glyphOf(t, kSummonKeyboardIconKey), Symbols.keyboard_rounded);

      // And the tap actually works — enabled is behaviour, not a field read.
      await t.tap(_slot(kSummonKeyboardIconKey));
      await t.pump();
      expect(
        _controllerOf(t).raised.value?.surface,
        SummonSurfaceKind.keyboard,
      );
    },
  );

  testWidgets(
    'focusing a text field in the body disables the keyboard icon and leaves '
    'the trackpad icon live',
    (t) async {
      final nav = GlobalKey<NavigatorState>();
      await pumpShell(t, nav: nav, body: _body());

      await t.tap(_slot(kProbeFieldKey));
      await t.pump();

      expect(_enabled(t, kSummonKeyboardIconKey), isFalse);
      expect(_glyphOf(t, kSummonKeyboardIconKey), Symbols.keyboard_off_rounded);

      // The gate is on ONE slot. The trackpad icon never enters state 2 and
      // there is no off-variant for its glyph.
      expect(_enabled(t, kSummonTrackpadIconKey), isTrue);
      expect(_glyphOf(t, kSummonTrackpadIconKey), Symbols.touch_app_rounded);
      await t.tap(_slot(kSummonTrackpadIconKey));
      await t.pump();
      expect(
        _controllerOf(t).raised.value?.surface,
        SummonSurfaceKind.trackpad,
        reason: 'BAR-03 gates the keyboard slot only',
      );
    },
  );

  testWidgets('unfocusing the field re-enables the keyboard icon', (t) async {
    final nav = GlobalKey<NavigatorState>();
    await pumpShell(t, nav: nav, body: _body());

    await t.tap(_slot(kProbeFieldKey));
    await t.pump();
    expect(_enabled(t, kSummonKeyboardIconKey), isFalse);

    FocusManager.instance.primaryFocus?.unfocus();
    await t.pump();

    expect(_enabled(t, kSummonKeyboardIconKey), isTrue);
    expect(_glyphOf(t, kSummonKeyboardIconKey), Symbols.keyboard_rounded);
  });

  testWidgets(
    'DISABLED IS NOT HIDDEN: the icon is still findable and the bar rect and '
    'both slot rects are unchanged across the swap',
    (t) async {
      final nav = GlobalKey<NavigatorState>();
      await pumpShell(t, nav: nav, body: _body());

      final barBefore = t.getRect(find.byKey(kSummonBarKey));
      final trackpadBefore = t.getRect(_slot(kSummonTrackpadIconKey));
      final keyboardBefore = t.getRect(_slot(kSummonKeyboardIconKey));

      await t.tap(_slot(kProbeFieldKey));
      await t.pump();

      expect(_slot(kSummonKeyboardIconKey), findsOneWidget);
      expect(_glyphOf(t, kSummonKeyboardIconKey), Symbols.keyboard_off_rounded);

      final barAfter = t.getRect(find.byKey(kSummonBarKey));
      final trackpadAfter = t.getRect(_slot(kSummonTrackpadIconKey));
      final keyboardAfter = t.getRect(_slot(kSummonKeyboardIconKey));

      for (final pair in <List<Rect>>[
        [barBefore, barAfter],
        [trackpadBefore, trackpadAfter],
        [keyboardBefore, keyboardAfter],
      ]) {
        expect(pair[1].left, closeTo(pair[0].left, 0.01));
        expect(pair[1].top, closeTo(pair[0].top, 0.01));
        expect(pair[1].width, closeTo(pair[0].width, 0.01));
        expect(pair[1].height, closeTo(pair[0].height, 0.01));
      }
    },
  );

  testWidgets(
    'CR-2: the disabled state is a GLYPH swap, not a tint change — the tint is '
    'kMuted on both sides of the disconnected/blocked boundary',
    (t) async {
      final nav = GlobalKey<NavigatorState>();
      await pumpShell(t, nav: nav, body: _body());

      // Disconnected and resting: already muted. This is the state the user is
      // in on the two screens SC4 names, which is why the disable cannot be
      // carried by colour.
      final restingTint = _tintOf(t, kSummonKeyboardIconKey);

      await t.tap(_slot(kProbeFieldKey));
      await t.pump();

      expect(
        _tintOf(t, kSummonKeyboardIconKey),
        restingTint,
        reason: 'the tint is IDENTICAL either side of the disable, so a '
            'tint-only implementation would be invisible on exactly the two '
            'screens the success criterion names',
      );
      expect(
        _glyphOf(t, kSummonKeyboardIconKey),
        isNot(Symbols.keyboard_rounded),
        reason: 'the glyph is the only channel that changed',
      );
    },
  );

  testWidgets(
    "the disabled icon's tap does nothing and produces no ripple",
    (t) async {
      final nav = GlobalKey<NavigatorState>();
      await pumpShell(t, nav: nav, body: _body());

      await t.tap(_slot(kProbeFieldKey));
      await t.pump();

      await t.tap(_slot(kSummonKeyboardIconKey));
      await t.pump();

      expect(
        _controllerOf(t).raised.value,
        isNull,
        reason: 'a blocked keyboard icon raises nothing',
      );
      // `onTap: null` is the entire implementation of disabled, and it is also
      // what removes the splash — there is no separate no-ripple branch to
      // regress independently.
      final ink = t.widget<InkWell>(
        find.descendant(
          of: _slot(kSummonKeyboardIconKey),
          matching: find.byType(InkWell),
        ),
      );
      expect(ink.onTap, isNull);
      expect(find.byType(InkSparkle), findsNothing);
    },
  );

  testWidgets(
    "THE PHASE-15 ESCAPE: a focus node the shell owns as its hidden IME node "
    'does NOT disable the icon',
    (t) async {
      final shellNode = FocusNode(debugLabel: 'fake hidden IME node');
      addTearDown(shellNode.dispose);

      final nav = GlobalKey<NavigatorState>();
      await pumpShell(t, nav: nav, body: _body(shellNode: shellNode));

      _controllerOf(t).hiddenImeNode = shellNode;

      // A REAL editable text takes focus — the exact shape Phase 15 creates
      // when a raised keyboard focuses the shell's hidden field.
      await t.tap(_slot(kShellFieldKey));
      await t.pump();

      expect(
        FocusManager.instance.primaryFocus?.context
            ?.findAncestorWidgetOfExactType<EditableText>(),
        isNotNull,
        reason: 'the escape must be exercised against a genuine EditableText, '
            'or it proves nothing',
      );
      expect(
        _enabled(t, kSummonKeyboardIconKey),
        isTrue,
        reason: 'without the reference-identity escape, raising the keyboard '
            'in Phase 15 would disable the affordance that dismisses it',
      );
      expect(_glyphOf(t, kSummonKeyboardIconKey), Symbols.keyboard_rounded);

      // Reference identity, never equality: a DIFFERENT node still blocks.
      await t.tap(_slot(kProbeFieldKey));
      await t.pump();
      expect(_enabled(t, kSummonKeyboardIconKey), isFalse);
    },
  );

  testWidgets(
    'the blocked-state sentence is DISCOVERABLE while the icon is disabled',
    (t) async {
      final semantics = t.ensureSemantics();
      final nav = GlobalKey<NavigatorState>();
      await pumpShell(t, nav: nav, body: _body());

      await t.tap(_slot(kProbeFieldKey));
      await t.pump();

      // The tooltip is an ANCESTOR of the tappable region, never a property of
      // a button with no tap handler — a disabled button does not surface its
      // own tooltip, and the sentence would be unreachable by both long-press
      // and a screen reader.
      expect(find.byTooltip(kSummonKeyboardBlockedLabel), findsOneWidget);

      final blocked = _semanticsWithTooltip(t, kSummonKeyboardBlockedLabel);
      expect(
        blocked,
        isNotNull,
        reason: 'the one sentence this phase spends words on must reach a '
            'screen reader in the state it explains',
      );
      // And it is attached to the icon it explains, not floating somewhere:
      // exactly one node in the tree carries it, and that node is the slot's
      // own 56x56 box. (Only the SIZE is compared — a semantics node's origin
      // rides its `transform`, not its `rect`.)
      final slotRect = t.getRect(_slot(kSummonKeyboardIconKey));
      expect(blocked!.rect.width, closeTo(slotRect.width, 0.01));
      expect(blocked.rect.height, closeTo(slotRect.height, 0.01));
      // Disabled reaches the screen reader structurally too: no tap action,
      // where the live trackpad slot next to it has one.
      expect(
        blocked.hasAction(SemanticsAction.tap),
        isFalse,
        reason: 'a blocked slot must not advertise a tap it will not honour',
      );
      expect(
        _semanticsWithTooltip(t, kSummonTrackpadLabel)!
            .hasAction(SemanticsAction.tap),
        isTrue,
        reason: 'the control assertion — the live slot DOES advertise its tap, '
            'so the absence above is the disable and not a harness artefact',
      );

      semantics.dispose();
    },
  );

  testWidgets(
    'a focus change rebuilds ONLY the keyboard icon subtree — not the bar, not '
    'the trackpad icon',
    (t) async {
      final nav = GlobalKey<NavigatorState>();
      await pumpShell(t, nav: nav, body: _body());

      final rebuilt = <String>[];
      debugOnRebuildDirtyWidget = (element, _) =>
          rebuilt.add(element.widget.toStringShort());
      addTearDown(() => debugOnRebuildDirtyWidget = null);

      await t.tap(_slot(kProbeFieldKey));
      await t.pump();

      debugOnRebuildDirtyWidget = null;

      expect(
        rebuilt.where((w) => w.startsWith('SummonBar')),
        isEmpty,
        reason: 'the bar sits on the trackpad hot path on every screen; a '
            'focus change must not rebuild it',
      );
      expect(
        rebuilt.where((w) => w.contains('summon-icon-trackpad')),
        isEmpty,
        reason: 'the trackpad slot has nothing to do with BAR-03',
      );
      expect(
        rebuilt.where((w) => w.contains('summon-icon-keyboard')),
        isNotEmpty,
        reason: 'the gated slot is the ONE thing that rebuilt',
      );
    },
  );
}
