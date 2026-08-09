/// The full-screen keyboard's four pads (Type / Arrows / Numpad / Fn) and its
/// bottom tab bar (KEY-02/KEY-04, 10-UI-SPEC §Pad layouts + §Bottom tab bar).
///
/// Widget-only and service-agnostic (mouse_buttons / [KeyRows] house style):
/// every pad takes the SAME injected-callback contract as [KeyRows], so their
/// widget tests need no service fake. The screen owner (10-05) mounts these in
/// a `PageView`, owns the one `ModifierFsm` + held-set, and wires the
/// callbacks to `service.sendReliable(KeyMsg(...))` + the haptic tick.
///
/// # These pads do not own the emission model
///
/// Every interactive cap here is the shared [KeyCap] from `key_rows.dart` —
/// the sacred press model (D-11 hold, D-10 deferred combo, IN-04 always-wired
/// releases, CR-01 dispose release) is shared BY REFERENCE with the D-07
/// trackpad-docked panel and can never drift between the two surfaces. This
/// file only lays caps out; it re-implements none of their press logic.
///
/// # No keep-alive, deliberately
///
/// Leaving a pad MUST dispose its caps: that dispose is what releases a key
/// held across a page switch (CR-01). Wrapping a pad in any keep-alive would
/// silently reintroduce the stuck-key door the model exists to close.
///
/// # Sizing
///
/// Caps size by `Expanded` flex so they fill the pad's height — "dramatically
/// larger than the old ~200px strip" is the user-locked acceptance bar
/// (UI-SPEC §Spacing exceptions). The 48/56/64px figures below are MINIMUMS,
/// not fixed heights.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../theme/tokens.dart';
import 'key_rows.dart';

/// The centered hint copy on the Type pad (Copywriting Contract, verbatim
/// from the prototype line 130). House rule: no inline copy literals.
const String kKeyboardHint =
    'The system keyboard handles typing. These are the extra keys.';

/// Hint text color (Prototype line 130, `#4a505c`). A local non-token const
/// mirroring `connection_header`/`dot_grid`'s pattern — it is NOT one of the
/// seven D-12 locked tokens, so it must not live in `tokens.dart` and does not
/// trip the palette guard. Grandfathered at 13/400 (UI-SPEC §Typography).
const Color _kKeyboardHintColor = Color(0xFF4A505C);

/// Bottom-tab labels (UI-SPEC §Bottom tab bar). No inline copy literals.
const Map<KeyboardPad, String> kKeyboardTabLabels = {
  KeyboardPad.type: 'Type',
  KeyboardPad.arrows: 'Arrows',
  KeyboardPad.numpad: 'Numpad',
  KeyboardPad.fn: 'Fn',
};

/// Bottom-tab icons (UI-SPEC §Bottom tab bar tab table). All four names exist
/// in the pinned `material_symbols_icons` — no substitution was needed.
const Map<KeyboardPad, IconData> kKeyboardTabIcons = {
  KeyboardPad.type: Symbols.keyboard_rounded,
  KeyboardPad.arrows: Symbols.open_with_rounded,
  KeyboardPad.numpad: Symbols.dialpad_rounded,
  KeyboardPad.fn: Symbols.function_rounded,
};

// ── Layout constants (UI-SPEC §Spacing scale) ─────────────────────────────

/// md — pad content padding.
const double _kPadPadding = 16;

/// sm — gap between caps.
const double _kGap = 8;

/// lg — gap between the Arrows pad's nav row and its inverted-T.
const double _kGapLg = 24;

/// The Type pad's slim extras row height (the 48px touch-target floor).
const double _kTypeRowHeight = 48;

/// The Arrows pad's Home/End/PgUp/PgDn row and the Fn pad's Esc cap height.
const double _kShortRowHeight = 56;

/// The Arrows pad's inverted-T width cap: arrow caps grow with the available
/// height, but a full-width arrow stops looking like a key — clamp the
/// cluster so they stay finger-shaped (UI-SPEC §Pad layouts — Arrows pad).
const double _kArrowCapMaxWidth = 96;

/// The Type row's relaxed width floor (UI-SPEC §Spacing exceptions: 7 caps
/// share one row, so each may be ~40–44dp wide on a narrow phone). The
/// height floor stays 48.
const double _kTypeRowCapMinWidth = 40;

/// Horizontal face padding for flex-sized caps: the `Expanded` cell owns the
/// width here, so the cap's own padding only reserves label breathing room —
/// and the default 12px each side would squeeze a 7-across row's labels off a
/// ~40dp cap.
const EdgeInsets _kFlexCapPadding = EdgeInsets.symmetric(horizontal: 4);

/// Heading face size — the pads' large-cap labels (UI-SPEC §Typography).
const double _kLargeLabelSize = 16;

/// Display face size — the numpad's digit faces (UI-SPEC §Typography).
const double _kDigitLabelSize = 28;

/// The Arrows pad's inverted-T arrow glyph size (UI-SPEC §Typography).
const double _kLargeIconSize = 28;

/// The bottom tab bar's height (excluding the bottom SafeArea inset).
const double _kTabBarHeight = 56;

/// Tab icon size (UI-SPEC §Bottom tab bar).
const double _kTabIconSize = 24;

/// Tab label size / xs icon→label gap (UI-SPEC §Bottom tab bar).
const double _kTabLabelSize = 12;
const double _kTabGap = 4;

/// The selected tab's accent top-edge underline weight; unselected tabs carry
/// the bar's 1px hairline top border instead (UI-SPEC §Bottom tab bar).
const double _kTabUnderlineWidth = 2;
const double _kTabHairlineWidth = 1;

// ── The docked panel's sizing contract (260809-ipc, D-93) ─────────────────
//
// The same four pads also mount INSIDE the trackpad-docked panel, where they
// share a fixed column with a trackpad that must stay LIVE. So the panel needs
// per-pad heights the full-screen surface never did (there, `Expanded` takes
// whatever is left).
//
// HONESTY ABOUT THE NUMBERS: the padding / gap / row consts above are REAL —
// they are what the pads actually lay out with. The 64px numpad row and the
// 76px arrows inverted-T cell below are CHOSEN TARGETS, not constants read
// back from the pads: the pads size their caps by `Expanded` flex, so a pad
// has no intrinsic height at all. The targets come from 10-UI-SPEC §Spacing
// ("64px minimum large-cap height") and are picked so a docked panel still
// yields finger-sized caps. They YIELD on short devices — the hard contract is
// only "never overflows", which KeyCap's `minHeight: 48` enforced against
// incoming constraints (BoxConstraints.enforce) guarantees.

/// The panel's 1px top hairline (continuous with the trackpad above).
const double _kPanelHairline = 1;

/// The panel's modifier-chip row: ModifierChip's 48px floor + 8px top and
/// bottom padding.
const double _kPanelChipRowHeight = 64;

/// Chosen target — the Numpad pad's row height inside the docked panel.
const double _kPanelNumpadRowTarget = 64;

/// Chosen target — one cell of the Arrows pad's inverted-T inside the panel
/// (two cells + one 8px gap = the 160px cluster).
const double _kPanelArrowCellTarget = 76;

/// The panel's constant chrome height: hairline + chip row + tab bar
/// (1 + 64 + 56 = 121). Everything except the animating pad viewport.
const double kPanelChromeHeight =
    _kPanelHairline + _kPanelChipRowHeight + _kTabBarHeight;

/// The unclamped viewport height each pad asks for inside the docked panel —
/// the height of the animating box around the panel's `PageView`.
///
/// Arithmetic, per pad (all four carry the pad's own 2 × 16px padding):
///
/// - **type** 32 + 48 extras row = **80** (D-93: Type stays a slim strip,
///   ≈ the ~200px panel this replaced, since chrome adds 121);
/// - **arrows** 32 + 56 top row + 24 lg gap + 160 inverted-T
///   (2 × 76 + 8) = **272**;
/// - **numpad** 32 + 4 × 64 rows + 3 × 8 gaps = **312** (the tallest);
/// - **fn** 32 + 56 Esc + 8 + 3 × 64 rows + 2 × 8 gaps = **304**.
const Map<KeyboardPad, double> kPanelPadHeights = {
  KeyboardPad.type: 2 * _kPadPadding + _kTypeRowHeight,
  KeyboardPad.arrows: 2 * _kPadPadding +
      _kShortRowHeight +
      _kGapLg +
      (2 * _kPanelArrowCellTarget + _kGap),
  KeyboardPad.numpad:
      2 * _kPadPadding + 4 * _kPanelNumpadRowTarget + 3 * _kGap,
  KeyboardPad.fn: 2 * _kPadPadding +
      _kShortRowHeight +
      _kGap +
      3 * _kPanelNumpadRowTarget +
      2 * _kGap,
};

/// The share of the shared column the docked panel may ever take, chrome
/// included. The trackpad keeps the rest — and the rest is what makes D-07
/// (type while the cursor stays live) true rather than nominal.
const double kPanelMaxHeightFraction = 0.55;

/// The pad viewport's absolute floor. Below this a pad stops being a keyboard,
/// so the fraction yields to it (see the guarantee below).
const double kPanelMinPadHeight = 96;

/// The docked panel's pad viewport height for [pad] inside a column of
/// [columnHeight] logical pixels.
///
/// GUARANTEE, at any window size:
///
/// > live trackpad height >= 0.45 × columnHeight − 64
///
/// with ONE documented exception: when [kPanelMinPadHeight] binds (a column
/// below ~290dp, reachable only with the IME raised on a very short device)
/// the fraction yields to the 96px floor. Even then the panel totals 217 and
/// the trackpad keeps `columnHeight − 281`, which stays positive on every
/// plausible device.
///
/// When the ceiling binds, caps flex below their target height rather than
/// overflowing: KeyCap's fixed 48px height floor is enforced against the
/// incoming constraints, so a tight cell wins and there is no RenderFlex
/// overflow.
///
/// [columnHeight] is the height of the column the panel SHARES with the
/// trackpad — see `keyboard_panel.dart`, which must read it from the raw view
/// metrics because the ancestor MediaQuery in that tree has had both the
/// padding and the IME inset stripped out from under it.
///
/// The floor is applied to the CEILING, not to the pad's own request:
/// `min(request, max(floor, ceiling))`. A pad never grows past what it asked
/// for — Type's 80px strip stays 80px on every device — while a ceiling that
/// has collapsed below the floor is lifted back to it.
double panelPadHeight(KeyboardPad pad, double columnHeight) {
  final ceiling = columnHeight * kPanelMaxHeightFraction - kPanelChromeHeight;
  return math.min(
    kPanelPadHeights[pad]!,
    math.max(kPanelMinPadHeight, ceiling),
  );
}

// ── Pads ──────────────────────────────────────────────────────────────────

/// Shared plumbing for the four pads: the [KeyRows] callback contract plus
/// the [cap] factory that binds it to a [KeyCap].
///
/// Private on purpose — the pads are the API; this only spares each of them
/// six identical fields and keeps every cap on the one shared press model.
abstract class _KeyPad extends StatelessWidget {
  /// False renders the gated all-muted, non-interactive state.
  final bool enabled;

  /// Press-down with no armed mods: `key {action: down}` (KEY-04 hold).
  final void Function(String code) onKeyDown;

  /// Release of a non-deferred press: `key {action: up}`.
  final void Function(String code) onKeyUp;

  /// Release of a DEFERRED press: `key {action: tap, mods: [...]}` (D-10).
  final void Function(String code) onKeyTapWithMods;

  /// Polled at press-down to pick the down/up vs tap+mods branch.
  final bool Function() hasArmedMods;

  /// Fired on every press-down (the haptic tick — UI-SPEC: on key-down).
  final VoidCallback? onPressHaptic;

  const _KeyPad({
    super.key,
    required this.enabled,
    required this.onKeyDown,
    required this.onKeyUp,
    required this.onKeyTapWithMods,
    required this.hasArmedMods,
    this.onPressHaptic,
  });

  /// Builds one cap on the shared emission model. `width` stays null: the
  /// pads size by flex, so the enclosing `Expanded` cell owns the width.
  KeyCap cap(
    KeyCapDef def, {
    double minWidth = 48,
    double labelSize = 14,
    FontWeight labelWeight = FontWeight.w400,
    double iconSize = 20,
  }) =>
      KeyCap(
        def: def,
        enabled: enabled,
        minWidth: minWidth,
        padding: _kFlexCapPadding,
        labelSize: labelSize,
        labelWeight: labelWeight,
        iconSize: iconSize,
        onKeyDown: onKeyDown,
        onKeyUp: onKeyUp,
        onKeyTapWithMods: onKeyTapWithMods,
        hasArmedMods: hasArmedMods,
        onPressHaptic: onPressHaptic,
      );
}

/// The bottom pad selector: icon over label, accent top-edge underline on the
/// selected tab (UI-SPEC §Bottom tab bar). The [KeyRowGroupSwitcher] idiom,
/// re-shaped from segment to tab.
///
/// # Always interactive — there is deliberately no `enabled` parameter
///
/// Tabs are NAVIGATION, not sends: they must work offline and unauthed, so
/// the user can still reach a pad while the socket is down. The caps and the
/// modifier chips carry the gating. Do not add a gated variant.
///
/// # Selection only — no haptics, no animation
///
/// The bar reports the tap and nothing else; the screen owner (10-05) runs
/// `hapticTick()` and animates the PageView on [onSelect]. Keeping the effect
/// out of here is what lets the bar be tested without a service or a
/// controller, and lets swipe-settle reuse the same selection path without
/// double-firing a haptic (UI-SPEC: swipe settle has no extra haptic).
class KeyboardTabBar extends StatelessWidget {
  /// The selected pad — accent icon + label + the 2px top underline.
  final KeyboardPad current;

  /// Fired with the tapped pad (including a re-tap of [current] — the screen
  /// owner decides what a same-page select means).
  final void Function(KeyboardPad pad) onSelect;

  /// Creates the tab bar.
  const KeyboardTabBar({
    super.key,
    required this.current,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: kBg,
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: _kTabBarHeight,
          child: Row(
            children: [
              for (final pad in KeyboardPad.values)
                Expanded(
                  child: InkWell(
                    onTap: () => onSelect(pad),
                    child: Container(
                      decoration: BoxDecoration(
                        // The bar's 1px hairline top border, with the
                        // selected tab's 2px accent segment replacing it.
                        border: Border(
                          top: BorderSide(
                            color: pad == current ? kAccent : kHairline,
                            width: pad == current
                                ? _kTabUnderlineWidth
                                : _kTabHairlineWidth,
                          ),
                        ),
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            kKeyboardTabIcons[pad],
                            size: _kTabIconSize,
                            color: pad == current ? kAccent : kMuted,
                          ),
                          const SizedBox(height: _kTabGap),
                          Text(
                            kKeyboardTabLabels[pad]!,
                            style: TextStyle(
                              color: pad == current ? kAccent : kMuted,
                              fontSize: _kTabLabelSize,
                              fontWeight: FontWeight.w400,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Page 1 (default) — the system IME's canvas plus one slim extras row.
///
/// The IME itself is NOT mounted here: `HiddenTextInput` lives at screen level
/// OUTSIDE the PageView so its input connection survives page switches
/// (UI-SPEC §Structure). This pad renders the hint and the extras row only.
class TypePad extends _KeyPad {
  /// Whether the centered hint canvas renders above the extras row.
  ///
  /// False in the trackpad-docked panel (260809-ipc): an 80px strip under a
  /// live trackpad has no room for a centered paragraph, and the hint's job —
  /// explaining that the system keyboard does the typing — is already obvious
  /// there, where the IME sits directly below. With it off the Column docks
  /// the extras row at the bottom instead of reserving flex for the canvas.
  final bool showHint;

  /// Creates the Type pad.
  const TypePad({
    super.key,
    required super.enabled,
    required super.onKeyDown,
    required super.onKeyUp,
    required super.onKeyTapWithMods,
    required super.hasArmedMods,
    super.onPressHaptic,
    this.showHint = true,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(_kPadPadding),
      child: Column(
        mainAxisAlignment:
            showHint ? MainAxisAlignment.start : MainAxisAlignment.end,
        children: [
          if (showHint)
            const Expanded(
              child: Center(
                child: Text(
                  kKeyboardHint,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: _kKeyboardHintColor,
                    fontSize: 13,
                    fontWeight: FontWeight.w400,
                    height: 1.7,
                  ),
                ),
              ),
            ),
          // Esc | Tab | ← | ↑ | ↓ | → | Del — 7 equal caps in one row
          // (user-locked). Width relaxes below the 48px floor on narrow
          // phones; the 48px HEIGHT floor is what keeps them tappable.
          SizedBox(
            height: _kTypeRowHeight,
            child: Row(
              children: [
                for (var i = 0; i < kTypeExtrasCaps.length; i++) ...[
                  if (i > 0) const SizedBox(width: _kGap),
                  Expanded(
                    child: cap(
                      kTypeExtrasCaps[i],
                      minWidth: _kTypeRowCapMinWidth,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Page 2 — Home/End/PgUp/PgDn over the large inverted-T.
///
/// Hold-to-repeat is retained by construction: the caps are [KeyCap]s, so
/// press-down sends `down`, release sends `up`, and WINDOWS autorepeats
/// between them (KEY-04) — identical to the docked panel.
class ArrowsPad extends _KeyPad {
  /// Creates the Arrows pad.
  const ArrowsPad({
    super.key,
    required super.enabled,
    required super.onKeyDown,
    required super.onKeyUp,
    required super.onKeyTapWithMods,
    required super.hasArmedMods,
    super.onPressHaptic,
  });

  /// One inverted-T arrow: fills its cell, 28px glyph.
  Widget _arrow(KeyCapDef def) =>
      Expanded(child: cap(def, iconSize: _kLargeIconSize));

  @override
  Widget build(BuildContext context) {
    // [Up, Left, Down, Right] — the inverted-T order (see kNavArrowCaps).
    const up = 0, left = 1, down = 2, right = 3;

    return Padding(
      padding: const EdgeInsets.all(_kPadPadding),
      child: Column(
        children: [
          SizedBox(
            height: _kShortRowHeight,
            child: Row(
              children: [
                for (var i = 0; i < kArrowsTopCaps.length; i++) ...[
                  if (i > 0) const SizedBox(width: _kGap),
                  Expanded(
                    child: cap(
                      kArrowsTopCaps[i],
                      labelSize: _kLargeLabelSize,
                      labelWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: _kGapLg),
          Expanded(
            child: Center(
              child: ConstrainedBox(
                // 3 caps + 2 gaps — the cluster's finger-shaped ceiling.
                constraints: const BoxConstraints(
                  maxWidth: _kArrowCapMaxWidth * 3 + _kGap * 2,
                ),
                child: Column(
                  children: [
                    // Up, centered over Down: an empty cell either side keeps
                    // it column-aligned with the row below.
                    Expanded(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const Expanded(child: SizedBox()),
                          const SizedBox(width: _kGap),
                          _arrow(kNavArrowCaps[up]),
                          const SizedBox(width: _kGap),
                          const Expanded(child: SizedBox()),
                        ],
                      ),
                    ),
                    const SizedBox(height: _kGap),
                    Expanded(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _arrow(kNavArrowCaps[left]),
                          const SizedBox(width: _kGap),
                          _arrow(kNavArrowCaps[down]),
                          const SizedBox(width: _kGap),
                          _arrow(kNavArrowCaps[right]),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Page 3 — the calculator-layout numpad with the big Enter (user-locked).
///
/// Codes are the existing `Num0`–`Num9` / `NumEnter` / `NumDot` — UI-SPEC
/// adds no numpad codes, so [kNumCaps] is rendered as-is.
class NumpadPad extends _KeyPad {
  /// Creates the Numpad pad.
  const NumpadPad({
    super.key,
    required super.enabled,
    required super.onKeyDown,
    required super.onKeyUp,
    required super.onKeyTapWithMods,
    required super.hasArmedMods,
    super.onPressHaptic,
  });

  /// A digit cap (28/400 Display face).
  Widget _digit(KeyCapDef def) => cap(def, labelSize: _kDigitLabelSize);

  /// A word cap — `Enter` / `.` (16/600 Heading face).
  Widget _word(KeyCapDef def) => cap(
        def,
        labelSize: _kLargeLabelSize,
        labelWeight: FontWeight.w600,
      );

  @override
  Widget build(BuildContext context) {
    // kNumCaps is row-major: 7 8 9 / 4 5 6 / 1 2 3 / Num0, NumEnter, NumDot.
    const zero = 9, enter = 10, dot = 11;

    return Padding(
      padding: const EdgeInsets.all(_kPadPadding),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            flex: 3,
            child: Column(
              children: [
                for (var row = 0; row < 3; row++) ...[
                  if (row > 0) const SizedBox(height: _kGap),
                  Expanded(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (var col = 0; col < 3; col++) ...[
                          if (col > 0) const SizedBox(width: _kGap),
                          Expanded(child: _digit(kNumCaps[row * 3 + col])),
                        ],
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: _kGap),
                // `0` spans two columns, `.` takes the third.
                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(flex: 2, child: _digit(kNumCaps[zero])),
                      const SizedBox(width: _kGap),
                      Expanded(child: _word(kNumCaps[dot])),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: _kGap),
          // The big Enter: one cap spanning the full block height.
          Expanded(child: _word(kNumCaps[enter])),
        ],
      ),
    );
  }
}

/// Page 4 — a full-width Esc over the F1–F12 grid.
///
/// Esc is on this pad too (user-locked) even though the Type pad's slim row
/// also carries it: the Fn pad is where Esc is reached for, and only one pad
/// is mounted at a time so the two caps never collide.
class FnPad extends _KeyPad {
  /// Creates the Fn pad.
  const FnPad({
    super.key,
    required super.enabled,
    required super.onKeyDown,
    required super.onKeyUp,
    required super.onKeyTapWithMods,
    required super.hasArmedMods,
    super.onPressHaptic,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(_kPadPadding),
      child: Column(
        children: [
          SizedBox(
            height: _kShortRowHeight,
            width: double.infinity,
            child: cap(
              kFnEscCap,
              labelSize: _kLargeLabelSize,
              labelWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: _kGap),
          // F1–F4 / F5–F8 / F9–F12 — the physical-keyboard grouping.
          for (var row = 0; row < 3; row++) ...[
            if (row > 0) const SizedBox(height: _kGap),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var col = 0; col < 4; col++) ...[
                    if (col > 0) const SizedBox(width: _kGap),
                    Expanded(
                      child: cap(
                        kFnCaps[row * 4 + col],
                        labelSize: _kLargeLabelSize,
                        labelWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}
