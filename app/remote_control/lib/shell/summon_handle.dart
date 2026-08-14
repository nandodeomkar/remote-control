/// The raised surface's 48dp handle band — **inert chrome** in Phase 13
/// (13-02, D-13-07, SUM-05, 13-UI-SPEC § Geometry → The handle).
///
/// D-13-07 ships the band now so the geometry this phase pins is the geometry
/// that ships: Phase 14 attaches behaviour to a box that already reserves the
/// space, with no re-derivation and no second round of five-device viewport
/// tests. The band is [kSummonHandleBandHeight] tall and full width; the tap
/// target inside it is a **real 48x48 box**, not an icon-sized hit region, so
/// an accessibility service has something to drive in Phase 14 (SUM-05).
///
/// # In Phase 13 this widget has no gesture recognizer at all
///
/// Not a no-op one "for later" — an affordance that swallows a tap and does
/// nothing is worse than one that visibly does nothing. Inert is also not
/// pending: no spinner, no extra dimming, no "coming soon" treatment. The glyph
/// is always [kMuted], with no enabled / disabled / raised / connected
/// variation, because it is an affordance rather than a state.
///
/// # The rule Phase 14 must not get wrong
///
/// Phase 14 attaches its recognizer to the 48x48 target as a **sibling** of the
/// surface content, never as an ancestor of it — the
/// `floating_trackpad_window.dart:245-257` rule verbatim. The reason is
/// invisible until the trackpad is actually inside the surface: the trackpad is
/// a raw pointer listener that never enters the gesture arena, so an ancestor
/// recognizer would win uncontested after ~18dp of slop while the cursor has
/// been moving since 10dp — and every dismiss would nudge the PC cursor
/// invisibly.
///
/// # Why this glyph
///
/// `drag_handle_rounded`, not the six-dot grip the floating window uses. That
/// one means "drag me around the screen" — the wrong verb for a dismiss handle.
/// And not a hand-drawn pill, which would be a new off-grid measurement for a
/// glyph that already exists in the pinned icon family.
library;

import 'package:flutter/widgets.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../theme/tokens.dart';
import 'summon_geometry.dart';

/// Key on the 48dp band.
const Key kSummonHandleKey = Key('summon-handle');

/// The handle's screen-reader name. Phase 13 ships the label on an **inert**
/// target; Phase 14 wires the action to it (SUM-05). It is a semantics label
/// rather than visible text — this phase renders no text at all.
const String kSummonHandleLabel = 'Dismiss';

/// The inert 48dp handle band. See the library doc for the contract.
class SummonHandle extends StatelessWidget {
  /// Creates the handle band.
  const SummonHandle({super.key});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      key: kSummonHandleKey,
      height: kSummonHandleBandHeight,
      width: double.infinity,
      child: Center(
        child: Semantics(
          label: kSummonHandleLabel,
          child: const SizedBox(
            // Square: the band's height is also the app's 48dp touch-target
            // floor, so the target is the band height on both axes.
            width: kSummonHandleBandHeight,
            height: kSummonHandleBandHeight,
            child: Icon(
              Symbols.drag_handle_rounded,
              size: kSummonGlyphSize,
              color: kMuted,
            ),
          ),
        ),
      ),
    );
  }
}
