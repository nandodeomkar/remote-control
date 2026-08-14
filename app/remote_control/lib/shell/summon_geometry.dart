/// The summon shell's chrome constants and its **one shared derivation**
/// (13-02, BAR-01, BAR-02, D-13-06, D-13-13, D-13-14, D-13-15).
///
/// Everything the bar and the raised surface are measured with lives here, and
/// **both surface heights come from one function**. That is D-13-06's actual
/// content: deriving `available` once and clamping both surfaces against it,
/// never forking the arithmetic per surface. The reason the phase pins this
/// ahead of the surfaces themselves is that the inset arithmetic is invisibly
/// wrong until a real device with gesture nav and a raised IME — validating it
/// against a placeholder number nothing ships would reproduce exactly that
/// failure.
///
/// # The four inputs, and where they must be read
///
/// ```
/// S     = MediaQuery.sizeOf(context).height        // full window, logical px
/// Ptop  = MediaQuery.viewPaddingOf(context).top    // status bar  — IME-independent
/// Pbot  = MediaQuery.viewPaddingOf(context).bottom // gesture nav — IME-independent
/// Ibot  = MediaQuery.viewInsetsOf(context).bottom  // system IME, 0 when down
/// ```
///
/// All four come from the shell's **un-injected** ancestor `MediaQuery` — read
/// into locals *before* `SummonShell` constructs its +56 `MediaQuery` wrap.
/// Reading the injected copy back is a silent 56px error on the reference
/// device with the IME down, which is the easiest case to get wrong and the
/// hardest to notice (RESEARCH F3).
///
/// **`viewPaddingOf`, never `paddingOf`** — `padding.bottom` collapses to 0
/// while the IME is up (the engine subtracts the inset) and `viewPadding` does
/// not, so the bar's own offset arithmetic must ride `viewPadding`. This is the
/// one piece of the docked panel's arithmetic that transfers verbatim
/// (`keyboard_panel.dart:399-403`). Reading `padding` here draws the bar
/// *behind* a raised IME, where it is untappable (RESEARCH F1).
///
/// # What this file must never borrow
///
/// The docked keyboard panel's sizing contract (`key_pads.dart:127-250`) is a
/// **structural** precedent only — its honesty-comment convention and its
/// const-composition style are copied, its numbers are not, and this library
/// deliberately imports nothing from it (D-13-15):
///
///  * its max-height fraction reserves room for a live trackpad *beneath* the
///    panel, and no trackpad lives beneath a raised summon surface;
///  * its column overhead carries a `+1` for the docked panel's in-`Column`
///    hidden-IME sliver, which costs exactly zero here because the shell's slot
///    is a `Positioned` sibling of the chrome;
///  * its per-pad height map and `panelPadHeight` are per-pad numbers this
///    phase must never acquire — D-13-15 requires Phase 15's pads to size
///    *inside* the fixed box with `Expanded`.
library;

import 'dart:math' as math;

import 'summon_scope.dart';

// ── Chrome constants (13-UI-SPEC § Geometry) ─────────────────────────────
//
// Every one of these is public because a test asserts against it — the
// public-vs-private rule the docked panel already follows (`kPanelChromeHeight`
// public, `_kPanelHairline` private). Phase 13 introduces no measurement
// outside the inherited 1 / 24 / 32 / 48 / 56 column plus the two height
// constants below.

/// The bar's own height, excluding the safe inset it sits above (D-13-13).
///
/// The gesture-nav inset is padded **below** this band, so total reserved space
/// is `kSummonBarHeight + viewPadding.bottom` and the glyphs never sit in the
/// system gesture zone where the trackpad icon would compete with
/// swipe-up-to-home.
const double kSummonBarHeight = 56;

/// The 1px top rule on the bar and on the raised surface — the phase's only
/// two hairlines. Drawn *inside* the band: a `Border` on a `DecoratedBox` adds
/// no height.
const double kSummonHairline = 1;

/// One bar icon's tap box, square. Equal to [kSummonBarHeight], which exceeds
/// the 48dp touch floor on both axes and makes the slot's rect trivially
/// derivable in a test from `barRect.height`.
const double kSummonIconSlot = 56;

/// The single gap between the two icon slots. Two slots plus this gap is
/// `56 + 32 + 56 = 144dp`, centred — see [kSummonIconPairWidth].
const double kSummonIconGap = 32;

/// Both bar glyphs and the handle glyph.
const double kSummonGlyphSize = 24;

/// The handle band reserved inside the raised surface (D-13-07 / SUM-05).
///
/// Rendered as inert chrome in Phase 13 so the geometry this phase pins is the
/// geometry that ships; Phase 14 attaches behaviour to a box that already
/// reserves the space, with no re-derivation.
const double kSummonHandleBandHeight = 48;

/// The centred icon pair's total width, composed from the two constants above
/// rather than written as a magic 144.
///
/// Against the narrowest plausible Android viewport (320dp) this leaves 88dp
/// dead on each side; on the 411dp reference device, 133.5dp. That dead width
/// is **deliberately and permanently empty** (D-13-12) — no third slot, no
/// placeholder, no `Spacer()` a future icon could be dropped into.
const double kSummonIconPairWidth =
    kSummonIconSlot + kSummonIconGap + kSummonIconSlot;

// ── The two surface heights ──────────────────────────────────────────────
//
// HONESTY ABOUT THE NUMBERS: every constant above is REAL — it is what the
// chrome actually lays out with, and each is fixed by 13-UI-SPEC. The two
// numbers below are NOT. They are declared design choices tuned on hardware at
// this phase's UAT (D-13-09, D-13-14), and a later reader must not treat them
// as arithmetic and go looking for the formula that produced them. There is no
// such formula. What IS arithmetic is the clamp they pass through —
// [summonSurfaceHeight] — and that is shared by both.

/// The raised trackpad surface's height — a **design choice**, not a derived
/// number (D-13-14).
///
/// 280 is what "standard Android IME height" means, which is the sizing the
/// owner asked for in preference to a screen fraction. Clamped to `available`
/// by [summonSurfaceHeight]; never a per-surface formula.
///
/// **CR-3, the number Phase 14 inherits.** The 48dp handle band and the 1px
/// rule cost the pad `280 - 1 - 48 = 231dp` of content, against the retiring
/// `FloatingTrackpadWindow`'s **234dp** of pad on the reference device. At this
/// starting constant the raised trackpad is therefore **3dp behind the
/// affordance it replaces** — that is RET-03's input, it is a one-constant
/// change, and it is tuned at this phase's UAT. Record the tuned value there so
/// Phase 14 inherits a fact rather than an assumption.
const double kSummonTrackpadHeight = 280;

/// The raised keyboard surface's height — a **design choice**, not a derived
/// number (D-13-14).
///
/// D-13-14's "~430dp starting value", rounded onto the 4dp grid: 430 is not a
/// multiple of 4 and would be the phase's only off-grid measurement, while 432
/// is on-grid, inside the stated range, and buys 2dp more of very thin
/// headroom.
///
/// **The headroom is ~15dp — do not shave it.** `432 - 1 - 48 = 383` of
/// content; Phase 15's chip row (64) plus tab bar (56) take 120, leaving **263**
/// of pad viewport against a Numpad crushed to `KeyCap.minHeight: 48` needing
/// ~248. 432 is near the floor, not near the ceiling. There are two heights
/// rather than one because the four pads SURF-02 keeps (D-13-15) do not fit an
/// IME-height box at all.
const double kSummonKeyboardHeight = 432;

// ── Motion budgets (MOT-01, D-13-10) ─────────────────────────────────────

/// The summon (raise) budget — 200ms, MOT-01.
///
/// The value is the incumbent house transition (`kBubbleExpandDuration`), but
/// declared fresh here rather than imported: the bubble's const dies with the
/// bubble in Phase 16.
const Duration kSummonRaiseDuration = Duration(milliseconds: 200);

/// The dismiss (lower) budget — 150ms, MOT-01. Expressed as the raise
/// controller's `reverseDuration`: one controller, two budgets.
const Duration kSummonLowerDuration = Duration(milliseconds: 150);

/// The swap budget — 200ms, D-13-10. **One motion**, never a 150ms lower
/// followed by a 200ms raise.
const Duration kSummonSwapDuration = Duration(milliseconds: 200);

// ── The one shared derivation ────────────────────────────────────────────
//
// All four functions are pure and take plain doubles, so they are unit-testable
// without a widget and the five worked devices can be pinned with computed
// expectations rather than quoted ones.

/// How far above the window's bottom edge the bar's band starts.
///
/// `max(Pbot, Ibot)` and never a sum: the IME draws **over** the nav bar, so
/// both are measured from the same window edge and adding them double-counts
/// the overlap. Both inputs come from the un-injected ancestor query.
double summonBarBottomOffset({
  required double viewPaddingBottom,
  required double viewInsetsBottom,
}) =>
    math.max(viewPaddingBottom, viewInsetsBottom);

/// The vertical space a raised surface may occupy: the window, minus the status
/// inset, minus whatever the bar sits above, minus the bar itself.
///
/// Forgetting the final `- kSummonBarHeight` is RESEARCH F2 — the surface's
/// bottom edge then overlaps the bar and BAR-02 is violated. That failure is
/// caught by invariant I1 (`surfaceRect.bottom == barRect.top`), not by
/// eyeballing a number.
double summonAvailableHeight({
  required double windowHeight,
  required double viewPaddingTop,
  required double viewPaddingBottom,
  required double viewInsetsBottom,
}) =>
    windowHeight -
    viewPaddingTop -
    summonBarBottomOffset(
      viewPaddingBottom: viewPaddingBottom,
      viewInsetsBottom: viewInsetsBottom,
    ) -
    kSummonBarHeight;

/// The height of the raised surface for [kind] inside [available].
///
/// **This is the one derivation for both surfaces** (D-13-06). There is no
/// per-surface formula, no screen fraction (D-13-14 replaced them) and no
/// per-pad clamp (D-13-15). The `math.min` is what makes a short viewport safe:
/// the chosen height can never push the surface past the space that exists, so
/// the surface can never overlap the bar and never reach under the status bar.
///
/// **The device-D consequence, stated so nobody "fixes" it.** On a 360x640
/// device with the system IME up, `available` is 270 — smaller than either
/// chosen height — so the keyboard surface clamps to 270, leaving 221 of
/// content and 101 of pad viewport once Phase 15's 120dp of chrome is taken.
/// That is the shared derivation doing its job at the extreme, not a defect.
/// Do not resolve it into two floors, a per-surface fraction or a per-pad
/// clamp; D-13-15 resolves it in Phase 15 by sizing the pads *inside* the fixed
/// box with `Expanded`.
double summonSurfaceHeight(SummonSurfaceKind kind, double available) =>
    math.min(
      available,
      kind == SummonSurfaceKind.trackpad
          ? kSummonTrackpadHeight
          : kSummonKeyboardHeight,
    );

/// The content box Phases 14 and 15 inherit: the surface minus its top rule and
/// the reserved handle band.
///
/// Composed from the named constants rather than written as a magic 49, so a
/// later change to either constant flows through instead of silently
/// disagreeing with the rendered chrome.
double summonSurfaceContentHeight(SummonSurfaceKind kind, double available) =>
    summonSurfaceHeight(kind, available) -
    kSummonHairline -
    kSummonHandleBandHeight;
