/// The raised surface slab — **empty on purpose** (13-02, SUM-01, SUM-02,
/// SUM-03, D-13-07, D-13-08, 13-UI-SPEC § Geometry → The raised surface).
///
/// A [kSurface] slab with a square 1px [kHairline] top rule, holding the 48dp
/// handle band above an empty expanded region. **Its emptiness is the
/// deliverable** (D-13-08): no placeholder label, no hint, no illustration, no
/// debug height readout. An empty-state sentence would be the only string in
/// the phase that ships in order to be deleted, and it is precisely the kind of
/// throwaway artefact that can confuse a failure during the geometry UAT this
/// phase exists to run. Empty *is* the populated state here; Phases 14 and 15
/// fill the expanded region through the inherited content box
/// [summonSurfaceContentHeight].
///
/// The surface has no loading state (its height is computed synchronously from
/// the ancestor metrics and it awaits nothing — the 200ms translate is motion
/// and must never be dressed as a loading affordance) and no error state (a
/// pathologically small `available` yields a short *clamped* surface, not a
/// failure).
///
/// # `MediaQuery.removePadding(removeBottom: true)` is mandatory and
/// # load-bearing, even though nothing inside consumes padding yet
///
/// `KeyboardTabBar` carries its own `SafeArea` (`key_pads.dart:349-353`). In
/// the docked panel that inner `SafeArea` contributes exactly 0, because an
/// ancestor had already stripped the bottom padding. **Nothing has stripped it
/// here** — the surface is a `Positioned` sibling of the shell's injection, not
/// a descendant of any screen's `SafeArea` — so the moment Phase 15 mounts the
/// tab bar this surface would silently grow by the 24-48dp of the gesture-nav
/// inset. That is research failure mode F5: invisible in Phase 13, wrong in
/// Phase 15, and impossible to attribute by then.
///
/// # Square top edge — no radius, no shadow, no rounded clip
///
/// Four reasons, recorded so nobody "improves" it later:
///
///  1. a radius on a slab that is flush to both screen edges and resting on the
///     bar reads as a broken card, not a sheet;
///  2. honouring a radius means clipping the child, and a per-frame clip on the
///     surface that will hold the trackpad's hot path is exactly the
///     `saveLayer` cost research P9 names as one of only two real jank sources
///     here;
///  3. the in-tree precedent for this exact component — the docked keyboard
///     panel's 1px top rule — is square;
///  4. a drop shadow is a per-frame blur on a half-screen animating surface for
///     no information gain.
///
/// The `FloatingTrackpadWindow`'s 16px radius and shadow are correct **for a
/// floating card** and that card is being retired; do not port them.
library;

import 'package:flutter/widgets.dart';

import '../theme/tokens.dart';
import 'summon_geometry.dart';
import 'summon_handle.dart';
import 'summon_scope.dart';

/// Key on the surface slab. Tests read `surfaceRect` from this and assert
/// invariant I1 — `surfaceRect.bottom == barRect.top` — against it.
const Key kSummonSurfaceKey = Key('summon-surface');

/// The raised surface. See the library doc for the contract.
class SummonSurface extends StatelessWidget {
  /// Which surface this is.
  ///
  /// Both kinds render identically in Phase 13 — the difference is the height
  /// the shell hands over. The field is carried now because Phases 14 and 15
  /// branch their content on it, and because a test that asserts geometry per
  /// surface needs the slab to know which one it is.
  final SummonSurfaceKind kind;

  /// The slab's height, from the shell's [summonSurfaceHeight] — the one shared
  /// derivation. Never computed here: a second derivation site is how the two
  /// numbers drift apart.
  final double height;

  /// Creates the slab.
  const SummonSurface({
    super.key,
    required this.kind,
    required this.height,
  });

  @override
  Widget build(BuildContext context) {
    return MediaQuery.removePadding(
      context: context,
      removeBottom: true,
      child: SizedBox(
        key: kSummonSurfaceKey,
        height: height,
        width: double.infinity,
        child: const DecoratedBox(
          decoration: BoxDecoration(
            color: kSurface,
            border: Border(
              top: BorderSide(color: kHairline, width: kSummonHairline),
            ),
          ),
          child: Column(
            children: [
              SummonHandle(),
              Expanded(child: SizedBox.shrink()),
            ],
          ),
        ),
      ),
    );
  }
}
