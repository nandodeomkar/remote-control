// Task 2 (13-03, Wave 3) — MOT-01, SUM-03 and D-13-10 made FALSIFIABLE.
//
// THE HEADER CONTRACT. MOT-01 is the one requirement in this phase whose test
// can look green while measuring nothing, so every case below is written to
// fail against a WRONG duration rather than merely to pass against the right
// one:
//
//  1. MOT-01 summon — the 200ms raise discriminates against an instant cut
//     (still fully lowered at frame 0), against a delayed cut (moved by
//     t=100), against a too-fast cut (NOT at final geometry at t=100) and
//     against anything longer than 250ms (at rest at t=250).
//  2. MOT-01 dismiss — the 150ms lower is pinned by the assertion at the
//     160ms mark, NOT by `kSummonLowerDuration`. Raising the constant to 200
//     makes case 2 fail; that is the whole reason the mark is 160 and not
//     "however long it takes".
//  3. SUM-03 / D-13-10 swap — the surface's bottom edge is on the bar's top
//     edge on EVERY frame of a swap, so a 150ms lower followed by a 200ms
//     raise (which would detach at some frame) cannot pass. The raise
//     controller is proven not to move: `surfaceRect.bottom - barRect.top` IS
//     its translate offset, and it stays 0 throughout.
//  4. SUM-03 mid-flight reverse — a tap landing mid-animation reverses from
//     the LIVE value with no queue and no input lockout, and a mid-swap tap on
//     the DESTINATION icon lowers immediately while the swap runs on
//     underneath (no cancel — no height jump on the tap frame; no hold — the
//     lower starts on the tap frame).
//  5. D-13-10 seam accounting — one named dismiss seam fires on the lower edge
//     AND on the swap edge, and across a swap followed by a mid-swap
//     destination tap each of the two surfaces reports exactly once. Never
//     twice, never zero times: a swap that reports zero times leaves a locked
//     modifier welded on the PC from Phase 15 onward, and one that reports
//     twice releases a modifier a later frame re-holds.
//
// NO SETTLE-UNTIL-IDLE PUMP ANYWHERE IN THIS FILE. The tester's settling pump
// (the one whose name this comment deliberately does not spell, because a grep
// in the plan's verify block asserts the token appears nowhere in this file)
// advances until no frames are scheduled, so a 200ms summon and a 900ms summon
// are indistinguishable and every assertion above would pass vacuously. The
// suite already reaches for it 95 times, so the habit is strong — every advance
// below is an explicit `pump(Duration)`.
//
// EVERY EXPECTED NUMBER IS COMPUTED from the driven metrics through the
// harness helpers. No absolute pixel figure is quoted anywhere.
//
// LOCATION BY KEY, NEVER BY GLYPH — `Symbols.keyboard_rounded` collides with
// `KeyboardTabBar`'s Type tab the moment Phase 15 mounts the tab bar inside the
// raised surface.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:remote_control/shell/summon_geometry.dart';
import 'package:remote_control/shell/summon_icon_button.dart';
import 'package:remote_control/shell/summon_scope.dart';
import 'package:remote_control/shell/summon_surface.dart';

import 'summon_test_harness.dart';

/// The reference device: 411x891, gesture nav 48, status 24, IME down.
const Size kRefSize = Size(411, 891);
const double kRefTop = 24;
const double kRefBottom = 48;

/// The mid-flight probe for the dismiss — half of the 150ms budget.
const Duration kDismissMidMark = Duration(milliseconds: 75);

/// **The discriminator.** A 150ms lower has settled by here; a 200ms lower has
/// not. This mark, not `kSummonLowerDuration`, is what pins the 150 — the
/// constant only says what the code intends, and an assertion that pumped
/// `kSummonLowerDuration` itself would stay green if the constant changed.
const Duration kDismissRestMark = Duration(milliseconds: 160);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(installSummonTestPlatforms);

  /// One frame past a budget. `_InterpolationSimulation.isDone` is a strict
  /// `>`, so at exactly the budget the value has arrived but the status has
  /// not yet flipped.
  const tick = Duration(milliseconds: 1);

  final available =
      availableOf(size: kRefSize, top: kRefTop, bottom: kRefBottom);
  final trackpadSlab =
      summonSurfaceHeightFor(SummonSurfaceKind.trackpad, available);
  final keyboardSlab =
      summonSurfaceHeightFor(SummonSurfaceKind.keyboard, available);

  /// The bar's top edge — the surface rests on it (invariant I1).
  final barTop = kRefSize.height -
      barBottomOffsetOf(bottom: kRefBottom) -
      kSummonBarHeight;

  /// Where a slab of [slab] sits when the raise controller is at rest.
  double restTopOf(double slab) => barTop - slab;

  /// The fully-lowered top, for ANY slab height: the surface is translated
  /// down by exactly its own height, so `restTop + slab` collapses to the
  /// bar's top edge regardless of which surface is up.
  final downTop = barTop;

  /// The surface's top, or [downTop] when the shell has already unmounted the
  /// slab.
  ///
  /// The shell drops the slab the instant the lower settles, so "gone" and "at
  /// the fully-lowered position" are the same fact one frame apart. This helper
  /// is NOT a loophole: a lower that had not settled is still mounted and its
  /// top is measurably above [downTop], which is exactly how a 200ms dismiss
  /// fails the 160ms mark.
  double loweredTop(WidgetTester t) => t.any(find.byKey(kSummonSurfaceKey))
      ? t.getRect(find.byKey(kSummonSurfaceKey)).top
      : downTop;

  /// The surface's rect right now.
  Rect surfaceOf(WidgetTester t) => t.getRect(find.byKey(kSummonSurfaceKey));

  /// Raises [icon]'s surface (or swaps to it) and lands the 200ms motion.
  Future<void> raiseAndLand(WidgetTester t, Key icon) async {
    await t.tap(find.byKey(icon));
    await t.pump();
    await t.pump(kSummonRaiseDuration);
    await t.pump(tick);
  }

  /// Lowers whatever is up and lands the 150ms motion.
  Future<void> lowerAndLand(WidgetTester t, Key icon) async {
    await t.tap(find.byKey(icon));
    await t.pump();
    await t.pump(kSummonLowerDuration);
    await t.pump(tick);
  }

  testWidgets(
      'MOT-01 case 1: the summon takes 200ms — not a cut, and not longer '
      'than 250ms', (t) async {
    driveView(t, size: kRefSize, top: kRefTop, bottom: kRefBottom);
    final nav = GlobalKey<NavigatorState>();
    await pumpShell(t, nav: nav);

    final restTop = restTopOf(keyboardSlab);

    await t.tap(find.byKey(kSummonKeyboardIconKey));
    await t.pump(); // t = 0 — the controller starts, nothing has moved yet
    expect(
      surfaceOf(t).top,
      closeTo(downTop, 0.5),
      reason: 'frame 0 must still be FULLY LOWERED — an instant cut would '
          'already be at rest here, and this is the only frame that can tell '
          'the two apart',
    );

    await t.pump(const Duration(milliseconds: 100)); // t = 100
    final midTop = surfaceOf(t).top;
    expect(
      midTop,
      lessThan(downTop - 1),
      reason: 'it must have MOVED by t=100 — otherwise this is a delayed cut '
          'wearing an animation',
    );
    expect(
      midTop,
      greaterThan(restTop + 1),
      reason: 'it must NOT be at final geometry at t=100 — a 200ms summon is '
          'mid-flight here, a 100ms one is already done',
    );

    await t.pump(const Duration(milliseconds: 150)); // t = 250
    expect(
      surfaceOf(t).top,
      closeTo(restTop, 0.5),
      reason: 'a 200ms summon is complete by t=250; a 300ms one is not',
    );
  });

  testWidgets(
      'MOT-01 case 2: the dismiss takes 150ms — and a 200ms dismiss fails the '
      '160ms mark', (t) async {
    driveView(t, size: kRefSize, top: kRefTop, bottom: kRefBottom);
    final nav = GlobalKey<NavigatorState>();
    await pumpShell(t, nav: nav);

    final restTop = restTopOf(keyboardSlab);
    await raiseAndLand(t, kSummonKeyboardIconKey);
    expect(surfaceOf(t).top, closeTo(restTop, 0.5));

    await t.tap(find.byKey(kSummonKeyboardIconKey));
    await t.pump(); // t = 0
    await t.pump(kDismissMidMark); // t = 75 — mid-flight
    final mid = surfaceOf(t).top;
    expect(
      mid,
      greaterThan(restTop + 1),
      reason: 'it has left the raised position by t=75',
    );
    expect(
      mid,
      lessThan(downTop - 1),
      reason: 'and it has NOT arrived — a cut would already be down',
    );

    await t.pump(kDismissRestMark - kDismissMidMark); // t = 160
    expect(
      loweredTop(t),
      closeTo(downTop, 0.5),
      reason: 'THIS ASSERTION, NOT THE CONSTANT, IS WHAT PINS THE 150. A '
          '150ms dismiss has settled by the 160ms mark; a 200ms dismiss is '
          'still mounted and still a quarter of its travel above the bar, so '
          'raising kSummonLowerDuration to 200 turns this case red',
    );
    expect(
      find.byKey(kSummonSurfaceKey),
      findsNothing,
      reason: 'the shell drops the slab the instant the lower settles — the '
          'surface is never yanked out from under its own exit animation, and '
          'it is never left mounted after it',
    );
  });

  testWidgets(
      'SUM-03/D-13-10 case 3: the swap is ONE motion — the surface never '
      'leaves the bar and the raise controller never moves', (t) async {
    driveView(t, size: kRefSize, top: kRefTop, bottom: kRefBottom);
    final nav = GlobalKey<NavigatorState>();
    await pumpShell(t, nav: nav);

    await raiseAndLand(t, kSummonKeyboardIconKey);
    expect(surfaceOf(t).height, closeTo(keyboardSlab, 0.5));

    final floor = math.min(keyboardSlab, trackpadSlab);
    final ceiling = math.max(keyboardSlab, trackpadSlab);
    final seen = <double>[];

    await t.tap(find.byKey(kSummonTrackpadIconKey));
    await t.pump();
    for (var ms = 0; ms <= 200; ms += 25) {
      await t.pump(const Duration(milliseconds: 25));
      final r = surfaceOf(t);
      expect(
        r.bottom,
        closeTo(barTop, 0.5),
        reason: 'the surface never leaves the bar during a swap — a 150ms '
            'lower followed by a 200ms raise would detach at some frame, and '
            'this loop looks at every one of them',
      );
      expect(
        r.bottom - barTop,
        closeTo(0, 0.5),
        reason: 'that gap IS the raise controller\'s translate offset, so it '
            'staying 0 is the statement that the raise controller never left '
            'its rest value while the swap ran',
      );
      expect(
        r.height,
        greaterThanOrEqualTo(floor - 0.5),
        reason: 'the slab never dips below the smaller of the two surfaces — '
            'a lower-then-raise would pass through zero',
      );
      expect(r.height, lessThanOrEqualTo(ceiling + 0.5));
      seen.add(r.height);
    }

    expect(
      surfaceOf(t).height,
      closeTo(trackpadSlab, 0.5),
      reason: 'the swap ARRIVED at the other surface\'s height',
    );
    expect(
      seen.any((h) => h > floor + 1 && h < ceiling - 1),
      isTrue,
      reason: 'and it got there by RESIZING, not by cutting: at least one '
          'frame is strictly between the two heights',
    );
  });

  testWidgets(
      'SUM-03 case 4: a tap landing mid-animation reverses from the LIVE '
      'value, and a mid-swap tap on the destination icon lowers', (t) async {
    driveView(t, size: kRefSize, top: kRefTop, bottom: kRefBottom);
    final nav = GlobalKey<NavigatorState>();
    await pumpShell(t, nav: nav);

    // ── Scenario A: mid-RAISE reverse ────────────────────────────────────
    await t.tap(find.byKey(kSummonKeyboardIconKey));
    await t.pump();
    await t.pump(const Duration(milliseconds: 100)); // half way up
    final halfway = surfaceOf(t).top;

    await t.tap(find.byKey(kSummonKeyboardIconKey));
    await t.pump(); // the tap frame — no time advances
    await t.pump(const Duration(milliseconds: 25));
    final justAfter = surfaceOf(t).top;
    expect(
      justAfter,
      greaterThan(halfway + 1),
      reason: 'the reverse begins on the tap frame — no queue, no input '
          'lockout, nothing waiting for the raise to finish first',
    );
    expect(
      justAfter,
      lessThan(downTop - 1),
      reason: 'and it is animating rather than snapping',
    );

    await t.pump(const Duration(milliseconds: 100)); // tap + 125 < 150
    expect(
      loweredTop(t),
      closeTo(downTop, 0.5),
      reason: 'a reverse from a half-raised surface settles in LESS than a '
          'full lower duration, because the controller scales by the '
          'remaining distance — from 0.5 a 150ms reverse takes about 75ms',
    );

    // ── Scenario B: mid-SWAP tap on the DESTINATION icon ─────────────────
    await raiseAndLand(t, kSummonKeyboardIconKey);
    await t.tap(find.byKey(kSummonTrackpadIconKey)); // swap keyboard → trackpad
    await t.pump();
    await t.pump(const Duration(milliseconds: 100)); // mid-swap
    final beforeTap = surfaceOf(t);
    expect(
      beforeTap.height,
      greaterThan(trackpadSlab + 1),
      reason: 'the swap must genuinely be in flight for this scenario to mean '
          'anything',
    );

    await t.tap(find.byKey(kSummonTrackpadIconKey)); // the DESTINATION icon
    await t.pump(); // the tap frame — no time advances
    final onTapFrame = surfaceOf(t);
    expect(
      onTapFrame.height,
      closeTo(beforeTap.height, 0.5),
      reason: 'NO RENDERED-HEIGHT JUMP on the tap frame — the swap is not '
          'cancelled, it runs on underneath; cancelling it would snap the '
          'slab to the destination height in one frame',
    );

    await t.pump(const Duration(milliseconds: 25));
    expect(
      surfaceOf(t).bottom - barTop,
      greaterThan(1),
      reason: 'the lower STARTS on the tap frame rather than after the swap\'s '
          'remaining time — a late start is the input lockout this transition '
          'rule exists to prevent',
    );

    await t.pump(const Duration(milliseconds: 125)); // tap + 150 == one lower
    expect(
      loweredTop(t),
      closeTo(downTop, 0.5),
      reason: 'the destination icon lowers the surface within ONE full lower '
          'duration of the tap: under D-13-10 the showing surface\'s own icon '
          'dismisses it, and by then the shell is committed to the '
          'destination kind',
    );
  });

  testWidgets(
      'D-13-10 case 5: the ONE dismiss seam fires on the lower edge AND the '
      'swap edge, and each surface reports exactly once', (t) async {
    driveView(t, size: kRefSize, top: kRefTop, bottom: kRefBottom);
    final nav = GlobalKey<NavigatorState>();
    await pumpShell(t, nav: nav);

    final controller = SummonScope.of(contextOf(t, kHarnessRootText));
    final log = <SummonSurfaceKind>[];
    controller.onSurfaceDismissed = log.add;

    // A plain raise dismisses nothing; the plain lower reports the surface.
    await raiseAndLand(t, kSummonTrackpadIconKey);
    expect(log, isEmpty, reason: 'a raise from nothing has no outgoing surface');
    await lowerAndLand(t, kSummonTrackpadIconKey);
    expect(
      log,
      <SummonSurfaceKind>[SummonSurfaceKind.trackpad],
      reason: 'the lower edge reports the outgoing surface exactly once',
    );

    // The swap edge is a dismiss for the OUTGOING surface.
    log.clear();
    await raiseAndLand(t, kSummonKeyboardIconKey);
    expect(log, isEmpty);
    await raiseAndLand(t, kSummonTrackpadIconKey); // swap keyboard → trackpad
    expect(
      log,
      <SummonSurfaceKind>[SummonSurfaceKind.keyboard],
      reason: 'THE SWAP EDGE IS A DISMISS. A seam that fired only on "surface '
          'to nothing" would leave a locked Shift welded on the PC every time '
          'the owner swapped, with no chip on screen to release it',
    );
    await lowerAndLand(t, kSummonTrackpadIconKey);
    expect(
      log,
      <SummonSurfaceKind>[
        SummonSurfaceKind.keyboard,
        SummonSurfaceKind.trackpad,
      ],
      reason: 'across a swap then a lower, each of the two surfaces reports '
          'exactly once — one seam, both edges',
    );

    // The mid-swap destination tap: the second report is the DESTINATION kind,
    // fired once, on the lower it triggers.
    log.clear();
    await raiseAndLand(t, kSummonKeyboardIconKey);
    await t.tap(find.byKey(kSummonTrackpadIconKey)); // swap starts
    await t.pump();
    expect(
      log,
      <SummonSurfaceKind>[SummonSurfaceKind.keyboard],
      reason: 'the swap edge reported the ORIGIN kind when the swap started',
    );

    await t.pump(const Duration(milliseconds: 100));
    await t.tap(find.byKey(kSummonTrackpadIconKey)); // the DESTINATION icon
    await t.pump();
    expect(
      log,
      <SummonSurfaceKind>[
        SummonSurfaceKind.keyboard,
        SummonSurfaceKind.trackpad,
      ],
      reason: 'and this lower reports the DESTINATION kind once, so the '
          'accounting stays exact across the pair — Phase 15 releases each '
          'surface\'s modifiers exactly once, never twice and never zero times',
    );

    await t.pump(kSummonRaiseDuration);
    await t.pump(kSummonRaiseDuration);
    await t.pump(tick);
    expect(
      log,
      <SummonSurfaceKind>[
        SummonSurfaceKind.keyboard,
        SummonSurfaceKind.trackpad,
      ],
      reason: 'nothing reports again once both motions settle — the swap '
          'running on underneath is a motion, not a second departure',
    );
  });
}
