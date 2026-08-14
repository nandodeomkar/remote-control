// Task 1 (13-02, Wave 2) — the summon shell's ONE SHARED DERIVATION, pinned as
// pure arithmetic. Pins the BAR-02 / D-13-06 / D-13-13 / D-13-14 must_haves:
//
//  1. chrome constants — the eight measurements 13-UI-SPEC § Geometry names are
//     the ones the code declares, and the centred pair composes from them
//     rather than from a magic 144.
//  2. barBottomOffset — max(Pbot, Ibot), never a sum: the IME draws OVER the
//     nav bar, so both are measured from the same window edge (D-13-13).
//  3. available — S - Ptop - max(Pbot, Ibot) - kSummonBarHeight, across the
//     five worked devices. Dropping the final term is RESEARCH F2: the
//     surface's bottom edge then overlaps the bar and BAR-02 is violated.
//  4. ONE derivation, both surfaces (D-13-06 / D-13-14) — the two heights are
//     plain dp design choices passed through a single min() clamp. No
//     per-surface formula, no screen fraction, no per-pad clamp.
//  5. the clamp binds where the arithmetic says it binds, and nowhere else —
//     the trackpad on the one short-and-IME-up device, the keyboard on that one
//     plus the mid-fall device whose available height sits under 432.
//  6. the content box Phases 14 and 15 inherit — height minus the top rule
//     minus the handle band, on every device, for both surfaces.
//
// ── THE TWO HALVES OF THIS FILE ────────────────────────────────────────────
//
// The FIRST half (13-02) is DELIBERATELY WIDGET-FREE. The four functions take
// plain doubles precisely so the arithmetic can be pinned without a pump.
//
// The SECOND half (13-04) drives five real viewports through the REAL shell and
// pins the RENDERED invariants — I1 `surfaceRect.bottom == barRect.top`, I2, I3
// and I4 — plus the five named failure modes F1/F1b, F2, F3, F4 and F5. It has
// its own preamble at the `THE RENDERED HALF` banner below, naming which cases
// are references and which are discriminators, and why an inset-free harness
// cannot catch this bug class at all.
//
// House rule, verbatim from test/trackpad/trackpad_screen_test.dart:143-145 —
// every asserted number is COMPUTED from the device inputs by the helpers
// below, never hard-coded, so an assertion cannot drift away from the
// guarantee it stands for. The helpers re-derive the arithmetic independently
// of the production functions; asserting a function against itself would pass
// for any formula.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:remote_control/shell/summon_bar.dart';
import 'package:remote_control/shell/summon_geometry.dart';
import 'package:remote_control/shell/summon_handle.dart';
import 'package:remote_control/shell/summon_icon_button.dart';
import 'package:remote_control/shell/summon_scope.dart';
import 'package:remote_control/shell/summon_surface.dart';

import 'summon_test_harness.dart';

/// One worked device from 13-RESEARCH §6.4.
///
/// None of the arithmetic in the first half is horizontal, so [width] is
/// carried purely so the rendered half can drive a real viewport with it.
class _Device {
  final String id;
  final double width;
  final double height;
  final double top;
  final double bottom;
  final double ime;

  const _Device(
    this.id, {
    required this.width,
    required this.height,
    required this.top,
    required this.bottom,
    this.ime = 0,
  });

  /// The viewport [driveView] is handed.
  Size get size => Size(width, height);
}

const _deviceA = _Device(
  'A — 411x891, gesture nav 48, IME down (the reference device)',
  width: 411,
  height: 891,
  top: 24,
  bottom: 48,
);
const _deviceB = _Device(
  'B — 360x640, nav 24, IME down (short)',
  width: 360,
  height: 640,
  top: 24,
  bottom: 24,
);
const _deviceC = _Device(
  'C — 411x891, nav 24, IME up (viewPadding-vs-padding discriminator)',
  width: 411,
  height: 891,
  top: 24,
  bottom: 24,
  ime: 290,
);
const _deviceD = _Device(
  'D — 360x640, nav 24, IME up (short AND covered: the clamp binds)',
  width: 360,
  height: 640,
  top: 24,
  bottom: 24,
  ime: 290,
);
const _deviceE = _Device(
  'E — 360x640, nav 24, IME mid-fall (retarget discriminator)',
  width: 360,
  height: 640,
  top: 24,
  bottom: 24,
  ime: 150,
);

const List<_Device> _devices = <_Device>[
  _deviceA,
  _deviceB,
  _deviceC,
  _deviceD,
  _deviceE,
];

/// The bar's offset above the window's bottom edge, re-derived. The IME draws
/// over the nav bar, so this is the larger of the two and never their sum.
double _offsetFor(_Device d) => d.ime > d.bottom ? d.ime : d.bottom;

/// The space a raised surface may occupy, re-derived from the device inputs.
double _availableFor(_Device d) =>
    d.height - d.top - _offsetFor(d) - kSummonBarHeight;

/// The height [kind] asks for before any clamp — the design choice, not
/// arithmetic.
double _chosenFor(SummonSurfaceKind kind) =>
    kind == SummonSurfaceKind.trackpad
        ? kSummonTrackpadHeight
        : kSummonKeyboardHeight;

/// The surface height, re-derived: the request, clamped by what exists.
double _surfaceHeightFor(_Device d, SummonSurfaceKind kind) {
  final available = _availableFor(d);
  final chosen = _chosenFor(kind);
  return available < chosen ? available : chosen;
}

/// The devices on which [kind]'s clamp actually binds, computed rather than
/// listed.
List<String> _clampedOn(SummonSurfaceKind kind) => <String>[
      for (final d in _devices)
        if (_availableFor(d) < _chosenFor(kind)) d.id,
    ];

void main() {
  group('chrome constants (13-UI-SPEC § Geometry)', () {
    test('the eight measurements are the ones the contract names', () {
      expect(kSummonBarHeight, 56);
      expect(kSummonHairline, 1);
      expect(kSummonIconSlot, 56);
      expect(kSummonIconGap, 32);
      expect(kSummonGlyphSize, 24);
      expect(kSummonHandleBandHeight, 48);
      expect(kSummonTrackpadHeight, 280);
      expect(kSummonKeyboardHeight, 432);
    });

    test('the icon slot is the bar height square, so a test can derive the '
        'slot rect from barRect.height', () {
      expect(kSummonIconSlot, kSummonBarHeight);
    });

    test('the centred pair composes from the slot and the gap, never a magic '
        '144', () {
      expect(
        kSummonIconPairWidth,
        kSummonIconSlot + kSummonIconGap + kSummonIconSlot,
      );
    });

    test('the motion budgets are MOT-01\'s, with the swap ONE motion rather '
        'than a lower followed by a raise (D-13-10)', () {
      expect(kSummonRaiseDuration, const Duration(milliseconds: 200));
      expect(kSummonLowerDuration, const Duration(milliseconds: 150));
      expect(kSummonSwapDuration, kSummonRaiseDuration);
      expect(
        kSummonLowerDuration < kSummonRaiseDuration,
        isTrue,
        reason: 'exit is faster than enter — MOT-01',
      );
    });
  });

  group('summonBarBottomOffset — max(Pbot, Ibot), never a sum (D-13-13)', () {
    for (final d in _devices) {
      test(d.id, () {
        expect(
          summonBarBottomOffset(
            viewPaddingBottom: d.bottom,
            viewInsetsBottom: d.ime,
          ),
          closeTo(_offsetFor(d), 0.01),
          reason: 'the bar sits above whichever inset is larger; the IME draws '
              'OVER the nav bar, so summing them double-counts the overlap',
        );
      });
    }

    test('adding the two insets would be visibly wrong wherever both are '
        'non-zero', () {
      final summed = _deviceC.bottom + _deviceC.ime;
      expect(
        summonBarBottomOffset(
          viewPaddingBottom: _deviceC.bottom,
          viewInsetsBottom: _deviceC.ime,
        ),
        lessThan(summed),
        reason: 'a sum would float the bar a nav-bar height above the IME',
      );
    });
  });

  group('summonAvailableHeight — the one derivation (BAR-02, D-13-06)', () {
    for (final d in _devices) {
      test(d.id, () {
        expect(
          summonAvailableHeight(
            windowHeight: d.height,
            viewPaddingTop: d.top,
            viewPaddingBottom: d.bottom,
            viewInsetsBottom: d.ime,
          ),
          closeTo(_availableFor(d), 0.01),
        );
      });
    }

    test('the bar\'s own height is subtracted — omitting it is RESEARCH F2, '
        'where the surface overlaps the bar and BAR-02 is violated', () {
      final withBar = summonAvailableHeight(
        windowHeight: _deviceA.height,
        viewPaddingTop: _deviceA.top,
        viewPaddingBottom: _deviceA.bottom,
        viewInsetsBottom: _deviceA.ime,
      );
      final withoutBar =
          _deviceA.height - _deviceA.top - _offsetFor(_deviceA);
      expect(withoutBar - withBar, closeTo(kSummonBarHeight, 0.01));
    });
  });

  group('summonSurfaceHeight — ONE function, both surfaces (D-13-06/D-13-14)',
      () {
    for (final d in _devices) {
      for (final kind in SummonSurfaceKind.values) {
        test('${d.id} · ${kind.name}', () {
          final available = summonAvailableHeight(
            windowHeight: d.height,
            viewPaddingTop: d.top,
            viewPaddingBottom: d.bottom,
            viewInsetsBottom: d.ime,
          );
          expect(
            summonSurfaceHeight(kind, available),
            closeTo(_surfaceHeightFor(d, kind), 0.01),
          );
          expect(
            summonSurfaceHeight(kind, available),
            lessThanOrEqualTo(available + 0.01),
            reason: 'min(available, …) is what makes a short viewport safe — '
                'the chosen height can never push the surface past the space '
                'that exists, so it can never overlap the bar',
          );
        });
      }
    }

    test('the trackpad clamp binds on exactly the devices where the arithmetic '
        'says it binds', () {
      expect(_clampedOn(SummonSurfaceKind.trackpad), <String>[_deviceD.id]);
      for (final d in _devices) {
        final available = _availableFor(d);
        final clamps = available < kSummonTrackpadHeight;
        expect(
          summonSurfaceHeight(SummonSurfaceKind.trackpad, available),
          closeTo(clamps ? available : kSummonTrackpadHeight, 0.01),
        );
      }
    });

    test('the keyboard clamp binds on the short-and-covered device AND on the '
        'mid-fall device — the taller surface runs out of room sooner', () {
      expect(
        _clampedOn(SummonSurfaceKind.keyboard),
        <String>[_deviceD.id, _deviceE.id],
        reason: 'this is the shared derivation doing its job at the extremes; '
            'do not resolve it into two floors or a per-pad clamp (D-13-15)',
      );
    });

    test('a pathologically small available yields a short clamped surface, '
        'never a failure', () {
      for (final kind in SummonSurfaceKind.values) {
        expect(summonSurfaceHeight(kind, kSummonHandleBandHeight),
            closeTo(kSummonHandleBandHeight, 0.01));
      }
    });
  });

  group('summonSurfaceContentHeight — the box Phases 14 and 15 inherit', () {
    for (final d in _devices) {
      for (final kind in SummonSurfaceKind.values) {
        test('${d.id} · ${kind.name}', () {
          final available = summonAvailableHeight(
            windowHeight: d.height,
            viewPaddingTop: d.top,
            viewPaddingBottom: d.bottom,
            viewInsetsBottom: d.ime,
          );
          expect(
            summonSurfaceContentHeight(kind, available),
            closeTo(
              _surfaceHeightFor(d, kind) -
                  kSummonHairline -
                  kSummonHandleBandHeight,
              0.01,
            ),
            reason: 'content is the surface minus its 1px top rule and the '
                '48dp handle band — composed from the constants, never a '
                'magic 49',
          );
        });
      }
    }

    test('CR-3 — at the starting constant the raised trackpad is 3dp BEHIND '
        'the FloatingTrackpadWindow it replaces (Phase 14\'s RET-03 input)',
        () {
      const retiringPadHeight = 234.0; // ARCHITECTURE §4.4, device A
      final content = summonSurfaceContentHeight(
        SummonSurfaceKind.trackpad,
        _availableFor(_deviceA),
      );
      expect(
        retiringPadHeight - content,
        closeTo(3, 0.01),
        reason: 'recorded, not fixed: 280 is D-13-14\'s locked starting value '
            'and the tuning session is this phase\'s UAT. Do not let Phase 14 '
            'assume RET-03 passes',
      );
    });
  });

  // ═══ THE RENDERED HALF (13-04) ═══════════════════════════════════════════
  //
  // WHY A SECOND HALF EXISTS AT ALL. Everything above proves the formula is the
  // formula. None of it proves the SHELL feeds that formula the right inputs,
  // and that is the half of this phase which is invisibly wrong until a real
  // device with gesture nav and a raised IME. An inset-free harness cannot
  // catch this bug class at all: at zero insets `padding` and `viewPadding` are
  // the same number, the injected copy and the raw one differ by a reservation
  // nothing has consumed yet, and every failure below is green.
  //
  // REFERENCES vs DISCRIMINATORS. A viewport case is only worth writing when
  // the correct and the naive numbers differ VISIBLY. The five:
  //
  //   A  411x891, nav 48, IME down  REFERENCE. The device the phase is designed
  //                                 against. Not an F1 discriminator — IME down
  //                                 means padding == viewPadding — but it is
  //                                 where F2 and F3 live, and F3 is the nastiest
  //                                 of the set precisely because nothing about
  //                                 this device looks unusual.
  //   B  360x640, nav 24, IME down  REFERENCE. The short viewport, where the
  //                                 arithmetic has the least room to be sloppy.
  //   C  411x891, nav 24, IME up    DISCRIMINATOR (F1). The naive read draws the
  //                                 bar AT the window bottom — behind the raised
  //                                 keyboard, where it cannot be tapped.
  //   D  360x640, nav 24, IME up    DISCRIMINATOR (F1b), and the one device
  //                                 where the clamp binds for BOTH surfaces.
  //   E  360x640, nav 24, IME mid   the mid-fall metric, and F4's destination
  //                                 (Task 2).
  //
  // Every expected number is COMPUTED from the driven metrics by the harness
  // helpers (`availableOf`, `barBottomOffsetOf`, `summonSurfaceHeightFor`),
  // which re-derive the arithmetic independently of the production functions.
  // Nothing below quotes a pixel figure that is not a DRIVEN INPUT.
  //
  // NO SETTLE-UNTIL-IDLE PUMP IN THIS FILE, and the ban is enforced by a grep
  // in the plan's verify rather than by good intentions. A pump that advances
  // until no frames are scheduled makes a 200ms summon and a 900ms summon
  // indistinguishable, so every advance below is an explicit `pump(Duration)`.
  // The harness's `pumpShell` settles the initial ROUTE transition inside its
  // own file, which is navigation settling and never a geometry read.

  group('rendered on the five driven viewports (13-04)', () {
    setUp(installSummonTestPlatforms);

    /// One frame past the budget.
    ///
    /// `_InterpolationSimulation.isDone` is a STRICT `>`, so at exactly the
    /// budget the controller's value has arrived but its status has not yet
    /// flipped.
    const tick = Duration(milliseconds: 1);

    /// The bar icon that raises [kind]. Located BY KEY, never by glyph:
    /// `Symbols.keyboard_rounded` collides with `KeyboardTabBar`'s Type tab the
    /// moment Phase 15 mounts the tab bar inside the raised surface.
    Key iconFor(SummonSurfaceKind kind) => kind == SummonSurfaceKind.trackpad
        ? kSummonTrackpadIconKey
        : kSummonKeyboardIconKey;

    /// Taps [kind]'s icon and lands the motion exactly. Serves a first raise
    /// and a swap alike — the swap budget is the raise budget (D-13-10, one
    /// motion), so a single helper cannot silently paper over a lower-then-
    /// raise.
    Future<void> raiseAndLand(WidgetTester t, SummonSurfaceKind kind) async {
      await t.tap(find.byKey(iconFor(kind)));
      await t.pump();
      await t.pump(kSummonRaiseDuration);
      await t.pump(tick);
    }

    /// I1-I4 against the rendered tree, for one driven device and one raised
    /// surface. The `expectColumnFits` shape from
    /// `test/trackpad/trackpad_screen_test.dart:187-194`: one helper, four
    /// assertions, and a `reason:` on each that states the GUARANTEE rather
    /// than restating the assertion.
    void expectSurfaceInvariants(
      WidgetTester t,
      _Device d,
      SummonSurfaceKind kind,
    ) {
      final bar = t.getRect(find.byKey(kSummonBarKey));
      final surface = t.getRect(find.byKey(kSummonSurfaceKey));
      final available = availableOf(
        size: d.size,
        top: d.top,
        bottom: d.bottom,
        ime: d.ime,
      );
      final offset = barBottomOffsetOf(bottom: d.bottom, ime: d.ime);

      expect(
        surface.bottom,
        closeTo(bar.top, 0.01),
        reason: 'I1 — "the surface sits on top of the bar, never under it" is '
            'VERTICAL stacking, not z-order. The bar keeps every pixel of its '
            'own band, so it is never occluded by the thing it summoned',
      );
      expect(
        bar.bottom,
        closeTo(d.height - offset, 0.01),
        reason: 'I2 — the bar always clears whichever system chrome is '
            'present: the gesture-nav zone when the IME is down, the keyboard '
            'itself when it is up. Whichever is larger, never their sum',
      );
      expect(
        surface.top,
        greaterThanOrEqualTo(d.top - 0.01),
        reason: 'I3 — the surface never reaches under the status bar, so its '
            'top edge is always something the user can see meeting the screen '
            'behind it',
      );
      expect(
        surface.height,
        closeTo(summonSurfaceHeightFor(kind, available), 0.01),
        reason: 'I4 — the rendered height IS the one shared derivation over '
            'the live metrics; a second sizing site anywhere in the shell '
            'would show up here as a number that no longer tracks the device',
      );
    }

    for (final d in _devices) {
      testWidgets('${d.id} — both surfaces hold I1-I4', (t) async {
        driveView(
          t,
          size: d.size,
          top: d.top,
          bottom: d.bottom,
          ime: d.ime,
        );
        final nav = GlobalKey<NavigatorState>();
        await pumpShell(t, nav: nav);

        await raiseAndLand(t, SummonSurfaceKind.trackpad);
        expectSurfaceInvariants(t, d, SummonSurfaceKind.trackpad);

        // The SWAP, not a lower-then-raise. The taller surface rides the same
        // derivation and owes the same four invariants — one function, both
        // surfaces (D-13-06).
        await raiseAndLand(t, SummonSurfaceKind.keyboard);
        expectSurfaceInvariants(t, d, SummonSurfaceKind.keyboard);
      });
    }

    testWidgets(
        'D — the clamp binds for BOTH surfaces and they collapse to the same '
        'height: the documented consequence of ONE shared derivation, not a '
        'bug to be fixed into two floors', (t) async {
      const d = _deviceD;
      driveView(t, size: d.size, top: d.top, bottom: d.bottom, ime: d.ime);
      final nav = GlobalKey<NavigatorState>();
      await pumpShell(t, nav: nav);

      final available = availableOf(
        size: d.size,
        top: d.top,
        bottom: d.bottom,
        ime: d.ime,
      );

      await raiseAndLand(t, SummonSurfaceKind.trackpad);
      final trackpad = t.getRect(find.byKey(kSummonSurfaceKey));
      await raiseAndLand(t, SummonSurfaceKind.keyboard);
      final keyboard = t.getRect(find.byKey(kSummonSurfaceKey));

      expect(trackpad.height, closeTo(available, 0.01));
      expect(
        keyboard.height,
        closeTo(available, 0.01),
        reason: 'both chosen heights exceed what this device has, so both '
            'clamp to the same number. Do not resolve this into a per-surface '
            'fraction or a per-pad clamp — D-13-15 resolves it in Phase 15 by '
            'sizing the pads INSIDE the fixed box',
      );
      expect(keyboard.height, closeTo(trackpad.height, 0.01));

      // What the clamp actually buys at the extreme, stated honestly: the
      // surface fills `available` EXACTLY, so its top edge lands ON the status
      // inset. I3 holds with equality here and nowhere else — this is the
      // tightest the geometry ever gets, and the clamp is precisely what stops
      // it going one pixel further in either direction.
      expect(
        keyboard.top,
        closeTo(d.top, 0.01),
        reason: 'the host screen above the surface is the status band and '
            'nothing more on this device; without the clamp the surface would '
            'reach UNDER the status bar (I3) or over the bar (I1)',
      );
      final bar = t.getRect(find.byKey(kSummonBarKey));
      expect(
        keyboard.bottom,
        closeTo(bar.top, 0.01),
        reason: 'the bar keeps its full band even here — a clamped surface is '
            'a SHORT surface, never one that eats the bar',
      );
      expect(
        keyboard.height,
        greaterThan(kSummonHandleBandHeight + kSummonHairline),
        reason: 'a clamped surface is still a usable one: the handle band and '
            'its rule fit inside it, which is what makes "a pathologically '
            'small available yields a short surface, never a failure" true on '
            'a real viewport rather than only in the arithmetic',
      );
    });

    // ── The three geometry discriminators ────────────────────────────────
    //
    // Each of the three is a way the arithmetic can be written wrong that
    // still looks plausible in the source. The test names carry the wrong
    // outcome, so a reader who breaks one is told what they broke.

    testWidgets(
        'F1 on device C: the bar clears the RAISED IME — reading paddingOf '
        'instead of viewPaddingOf puts it AT the window bottom, behind the '
        'keyboard, where the dismiss affordance cannot be tapped at all',
        (t) async {
      const d = _deviceC;
      driveView(t, size: d.size, top: d.top, bottom: d.bottom, ime: d.ime);
      final nav = GlobalKey<NavigatorState>();
      await pumpShell(t, nav: nav);
      await raiseAndLand(t, SummonSurfaceKind.keyboard);

      final bar = t.getRect(find.byKey(kSummonBarKey));
      expect(
        d.height - bar.bottom,
        closeTo(barBottomOffsetOf(bottom: d.bottom, ime: d.ime), 0.01),
        reason: 'the bar sits the IME\'s own height above the window bottom. '
            'With the naive read this gap is ZERO — the bar is drawn behind '
            'the raised keyboard and is untappable, so "dismiss costs one '
            'gesture" would be false on exactly the surface that needs it',
      );
      expect(
        d.height - bar.bottom,
        greaterThan(d.bottom),
        reason: 'and the gap is the IME rather than the nav inset, which is '
            'what makes this device a discriminator instead of a second '
            'reference case',
      );
      expectSurfaceInvariants(t, d, SummonSurfaceKind.keyboard);
    });

    testWidgets(
        'F1b on device D: the same read on the short viewport — naively the '
        'bar AND the bottom of the surface both land behind the IME, which is '
        'most of the surface on a 640dp device', (t) async {
      const d = _deviceD;
      driveView(t, size: d.size, top: d.top, bottom: d.bottom, ime: d.ime);
      final nav = GlobalKey<NavigatorState>();
      await pumpShell(t, nav: nav);
      await raiseAndLand(t, SummonSurfaceKind.keyboard);

      final bar = t.getRect(find.byKey(kSummonBarKey));
      final surface = t.getRect(find.byKey(kSummonSurfaceKey));
      final offset = barBottomOffsetOf(bottom: d.bottom, ime: d.ime);

      expect(bar.bottom, closeTo(d.height - offset, 0.01));
      expect(
        surface.bottom,
        lessThanOrEqualTo(d.height - offset + 0.01),
        reason: 'nothing the shell draws crosses the IME\'s top edge. The '
            'naive read leaves the whole stack a full IME height too low, so '
            'the user sees a bar and a surface that are simply not there',
      );
      expectSurfaceInvariants(t, d, SummonSurfaceKind.keyboard);
    });

    testWidgets(
        'F2 on device A: the surface\'s bottom edge IS the bar\'s top edge — '
        'omitting kSummonBarHeight from `available` drops it a full bar height '
        'lower, so the surface overlaps the band it is supposed to rest on',
        (t) async {
      const d = _deviceA;
      driveView(t, size: d.size, top: d.top, bottom: d.bottom, ime: d.ime);
      final nav = GlobalKey<NavigatorState>();
      await pumpShell(t, nav: nav);
      await raiseAndLand(t, SummonSurfaceKind.keyboard);

      final bar = t.getRect(find.byKey(kSummonBarKey));
      final surface = t.getRect(find.byKey(kSummonSurfaceKey));

      expect(
        surface.bottom,
        closeTo(bar.top, 0.01),
        reason: 'I1 is what catches F2, and it catches it as a RELATIONSHIP '
            'rather than as a number: no single height assertion notices that '
            'the surface has been placed a bar height too low, because the '
            'height itself is still right',
      );
      expect(
        bar.bottom - surface.bottom,
        closeTo(kSummonBarHeight, 0.01),
        reason: 'the naive placement is exactly one bar height away — the '
            'surface would end at the bar\'s BOTTOM edge, covering both icons '
            'and violating BAR-02 for as long as anything is raised',
      );
    });

    testWidgets(
        'F3 on device A with the IME DOWN: `available` is the band between the '
        'status inset and the bar — reading the INJECTED MediaQuery back costs '
        'exactly one bar height of dead space and nothing looks broken',
        (t) async {
      const d = _deviceA;
      driveView(t, size: d.size, top: d.top, bottom: d.bottom, ime: d.ime);
      final nav = GlobalKey<NavigatorState>();
      await pumpShell(t, nav: nav);
      await raiseAndLand(t, SummonSurfaceKind.keyboard);

      final bar = t.getRect(find.byKey(kSummonBarKey));
      final available = availableOf(
        size: d.size,
        top: d.top,
        bottom: d.bottom,
        ime: d.ime,
      );

      // `available` IS the rendered band between the status inset and the top
      // of the bar — that is the whole content of the derivation, read off the
      // tree rather than trusted from the arithmetic.
      expect(
        bar.top - d.top,
        closeTo(available, 0.01),
        reason: 'the shell reads the RAW ancestor query into locals before it '
            'builds its +56 wrap. Reading that wrap back is the nastiest of '
            'the whole set: the IME is down, the device is the reference one, '
            'nothing looks broken, and the surface is simply short',
      );

      // The counterfactual, computed: the injected copy carries the bar's own
      // reservation on `viewPadding.bottom`, so re-reading it subtracts the
      // reservation twice.
      final injected = availableOf(
        size: d.size,
        top: d.top,
        bottom: d.bottom + kSummonBarHeight,
        ime: d.ime,
      );
      expect(
        available - injected,
        closeTo(kSummonBarHeight, 0.01),
        reason: 'the error is a bar height, not a rounding wobble',
      );

      // WHAT THE HAND-FALSIFICATION SHOWED, recorded because it decides where
      // the tripwire has to live. Feeding the injected `viewPadding.bottom`
      // through BOTH derivations reds this case by exactly one bar height, and
      // it reds it through I1 below — the surface lands a bar height clear of
      // the bar it should be resting on.
      //
      // Feeding it through `available` ALONE reds nothing on any of the five
      // devices, and that is not a gap in the case, it is a property of the
      // design: a fixed height only consults `available` through the clamp, the
      // clamp only binds where the IME is up, and where the IME is up it
      // dominates `max(Pbot, Ibot)` and swallows the injected term whole. The
      // offset half shares the same local, so I1 is the tripwire for both — and
      // that is precisely why the shell reads its metrics ONCE, into locals,
      // before it constructs the wrap.
      expectSurfaceInvariants(t, d, SummonSurfaceKind.keyboard);
    });

    // ── F4: the retarget discriminator ───────────────────────────────────
    //
    // The one failure in the set that no single-frame assertion can see. Every
    // case above would pass identically against a shell that snapshotted its
    // metrics once, because at a FIXED metric the snapshot and the live read
    // are the same number. What separates them is a metric that MOVES.
    //
    // This case runs after plan 13-03, deliberately. 13-03 replaced the resting
    // height with the swap lerp, and the lerp's two endpoints are re-derived
    // from the live `available` on every build precisely so that a stored dp
    // figure cannot hide in them. At REST — swap settled, both endpoints the
    // same kind, the lerp an identity that is still evaluated — is exactly
    // where a stored size would hide, so that is where this case sits. If it
    // ever goes red the fault is in the shell's height SOURCE and the repair
    // belongs there, never in this assertion.

    testWidgets(
        'F4: the surface RETARGETS on the very next frame when only the IME '
        'inset moves — a snapshot taken from the view registers no dependency, '
        'so it would sit at the covered height for the rest of the animation '
        'and never correct itself', (t) async {
      const covered = _deviceD; // 360x640 with the keyboard fully up
      const falling = _deviceE; // the same device, the IME mid-fall

      driveView(
        t,
        size: covered.size,
        top: covered.top,
        bottom: covered.bottom,
        ime: covered.ime,
      );
      final nav = GlobalKey<NavigatorState>();
      await pumpShell(t, nav: nav);
      await raiseAndLand(t, SummonSurfaceKind.keyboard);

      final coveredHeight = summonSurfaceHeightFor(
        SummonSurfaceKind.keyboard,
        availableOf(
          size: covered.size,
          top: covered.top,
          bottom: covered.bottom,
          ime: covered.ime,
        ),
      );
      final fallingHeight = summonSurfaceHeightFor(
        SummonSurfaceKind.keyboard,
        availableOf(
          size: falling.size,
          top: falling.top,
          bottom: falling.bottom,
          ime: falling.ime,
        ),
      );
      expect(
        fallingHeight,
        greaterThan(coveredHeight),
        reason: 'the two ends must actually differ, or a shell that ignored '
            'the change entirely would pass this case',
      );

      expect(
        t.getRect(find.byKey(kSummonSurfaceKey)).height,
        closeTo(coveredHeight, 0.01),
        reason: 'the starting point: with the keyboard fully up the clamp '
            'binds and the surface is exactly what is left',
      );

      // ONLY the IME inset changes. No icon is tapped, no controller is
      // touched, nothing is re-raised — this is the metric moving underneath a
      // surface that is already at rest.
      t.view.viewInsets = FakeViewPadding(bottom: falling.ime);
      await t.pump();

      expect(
        t.getRect(find.byKey(kSummonSurfaceKey)).height,
        closeTo(fallingHeight, 0.01),
        reason: 'ONE frame, no observer, no setState: the ancestor query is '
            'not value-equal across an IME animation, so the rebuild is '
            'automatic and the height is re-derived from the live metrics. A '
            'MediaQueryData.fromView(View.of(context)) read is numerically '
            'identical at any fixed metric and registers NO dependency, so it '
            'would still be showing the line above',
      );
      expectSurfaceInvariants(t, falling, SummonSurfaceKind.keyboard);
    });

    // ── F5: the padding-strip probe ──────────────────────────────────────
    //
    // A PROBE, not a rendering assertion, and the distinction is the whole
    // point of the case. Phase 13's surface contains no inner `SafeArea`, so
    // the absence of the strip changes NOTHING that can be measured with a
    // Rect today. It changes something in Phase 15: `KeyboardTabBar` carries
    // its own `SafeArea` (key_pads.dart:349-353), which contributes 0 in the
    // docked panel only because an ancestor had already stripped the bottom
    // padding. Nothing has stripped it here — the surface is a `Positioned`
    // sibling of the shell's injection, not a descendant of any screen's safe
    // area — so the tab bar would silently add the whole gesture-nav inset of
    // dead space, and by then it would be unattributable.
    //
    // ── A CORRECTION TO 13-RESEARCH §6.5 / THE PLAN'S F5 WORDING ──────────
    //
    // Both state the second assertion as "`viewPaddingOf` inside the surface
    // still reports 48". That is not what `MediaQuery.removePadding` does.
    // `MediaQueryData.removePadding` (media_query.dart:930-953) sets
    // `padding.bottom` to 0 AND sets `viewPadding.bottom` to
    // `max(0, viewPadding.bottom - padding.bottom)` — it SUBTRACTS the padding
    // it just consumed rather than leaving viewPadding alone. With the IME
    // DOWN, `padding.bottom == viewPadding.bottom`, so both land on 0 and the
    // quoted assertion is red against correct code.
    //
    // The guarantee is therefore split across the two cases below: the strip
    // is real and it is SCOPED to the surface's subtree (first case), and it
    // subtracts rather than zeroes (second case). Making the original wording
    // literally true would mean replacing `removePadding` with a hand-rolled
    // copyWith that leaves viewPadding at the full inset — which would WEAKEN
    // the guard, because a `SafeArea(maintainBottomViewPadding: true)` inside
    // the surface would then re-introduce exactly the dead space F5 exists to
    // prevent. The production code is right; the assertion was wrong.
    //
    // THE PROBE IS THE GUARD, THE COROLLARY IS NOT. Deleting the strip from
    // `summon_surface.dart` reds the probe by the full nav inset and leaves the
    // corollary GREEN — with the IME up there was nothing to strip in the first
    // place. Confirmed by hand while writing this plan. Anyone tempted to keep
    // only one of the two cases must keep the probe.

    testWidgets(
        'F5 PROBE: the raised surface\'s subtree has its bottom padding '
        'stripped, and the strip is scoped to that subtree — without it '
        'KeyboardTabBar\'s own SafeArea adds the whole gesture-nav inset of '
        'dead space the moment Phase 15 mounts it', (t) async {
      const d = _deviceA; // the reference device, IME down, nav inset 48
      driveView(t, size: d.size, top: d.top, bottom: d.bottom);
      final nav = GlobalKey<NavigatorState>();
      await pumpShell(t, nav: nav);
      await raiseAndLand(t, SummonSurfaceKind.keyboard);

      // The handle is the natural probe point: it is the only thing inside the
      // surface in Phase 13, and it is where Phase 15's chrome sits next to.
      final inside = t.element(find.byType(SummonHandle));
      final outside = t.element(find.byKey(kSummonBarKey));

      expect(
        MediaQuery.paddingOf(inside).bottom,
        closeTo(0, 0.01),
        reason: 'this is the entire deliverable of the strip. Nothing in '
            'Phase 13 consumes padding, so nothing in Phase 13 can see this '
            'go wrong — the probe is the only detector that exists, and it '
            'fails in Phase 15 if the strip is ever removed from here',
      );
      expect(
        MediaQuery.viewPaddingOf(outside).bottom,
        closeTo(d.bottom, 0.01),
        reason: 'the strip is SCOPED: the bar layer, a sibling of the surface, '
            'still sees the device\'s full inset. A strip that leaked upward '
            'would move the bar off the nav zone and I2 would be measuring a '
            'consequence of the test rather than of the shell',
      );
      expect(
        MediaQuery.viewInsetsOf(inside).bottom,
        closeTo(0, 0.01),
        reason: 'and only PADDING is touched — viewInsets pass through '
            'untouched, which is what keeps the IME state readable from '
            'inside the surface when Phase 15 needs it',
      );
    });

    testWidgets(
        'F5 corollary: removePadding SUBTRACTS the padding it consumed rather '
        'than zeroing viewPadding — with the IME up the inset survives inside '
        'the surface, which is where a maintainBottomViewPadding SafeArea '
        'would put the dead space back', (t) async {
      const d = _deviceC; // IME up: the engine has already collapsed padding
      driveView(t, size: d.size, top: d.top, bottom: d.bottom, ime: d.ime);
      final nav = GlobalKey<NavigatorState>();
      await pumpShell(t, nav: nav);
      await raiseAndLand(t, SummonSurfaceKind.keyboard);

      final inside = t.element(find.byType(SummonHandle));
      expect(
        MediaQuery.paddingOf(inside).bottom,
        closeTo(0, 0.01),
        reason: 'the strip holds in both IME states, which is what makes it a '
            'guarantee rather than a coincidence of the reference device',
      );
      expect(
        MediaQuery.viewPaddingOf(inside).bottom,
        closeTo(d.bottom, 0.01),
        reason: 'with the IME up the engine has already collapsed padding to '
            '0, so there is nothing to subtract and the nav inset survives on '
            'viewPadding. Phase 15 must therefore not reach for '
            'maintainBottomViewPadding inside the surface: it would read this '
            'number and reintroduce precisely the dead space the strip above '
            'exists to remove',
      );
    });
  });
}
