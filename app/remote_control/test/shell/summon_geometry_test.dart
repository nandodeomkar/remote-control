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
// THIS SUITE IS DELIBERATELY WIDGET-FREE. The four functions take plain
// doubles precisely so the arithmetic can be pinned without a pump; the
// RENDERED invariants (I1 surfaceRect.bottom == barRect.top, I2, I3, I4) and
// the driven-viewport discriminators land in plan 13-04 against a real tree.
//
// House rule, verbatim from test/trackpad/trackpad_screen_test.dart:143-145 —
// every asserted number is COMPUTED from the device inputs by the helpers
// below, never hard-coded, so an assertion cannot drift away from the
// guarantee it stands for. The helpers re-derive the arithmetic independently
// of the production functions; asserting a function against itself would pass
// for any formula.

import 'package:flutter_test/flutter_test.dart';

import 'package:remote_control/shell/summon_geometry.dart';
import 'package:remote_control/shell/summon_scope.dart';

/// One worked device from 13-RESEARCH §6.4. Width is carried in [id] only —
/// none of this arithmetic is horizontal.
class _Device {
  final String id;
  final double height;
  final double top;
  final double bottom;
  final double ime;

  const _Device(
    this.id, {
    required this.height,
    required this.top,
    required this.bottom,
    this.ime = 0,
  });
}

const _deviceA = _Device(
  'A — 411x891, gesture nav 48, IME down (the reference device)',
  height: 891,
  top: 24,
  bottom: 48,
);
const _deviceB = _Device(
  'B — 360x640, nav 24, IME down (short)',
  height: 640,
  top: 24,
  bottom: 24,
);
const _deviceC = _Device(
  'C — 411x891, nav 24, IME up (viewPadding-vs-padding discriminator)',
  height: 891,
  top: 24,
  bottom: 24,
  ime: 290,
);
const _deviceD = _Device(
  'D — 360x640, nav 24, IME up (short AND covered: the clamp binds)',
  height: 640,
  top: 24,
  bottom: 24,
  ime: 290,
);
const _deviceE = _Device(
  'E — 360x640, nav 24, IME mid-fall (retarget discriminator)',
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
}
