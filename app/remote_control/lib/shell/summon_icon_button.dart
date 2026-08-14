/// One bar icon slot: a 56x56 tap box with a total, strictly prioritised
/// four-state function (13-02, BAR-01, BAR-03, SUM-01, SUM-03, D-13-11,
/// D-13-13, 13-UI-SPEC CR-1 and CR-2).
///
/// Two instances of this widget are the whole bar. The state function is
/// **total** — every combination of raised / blocked / connected lands in
/// exactly one of four branches — and its order is defensive:
///
/// | # | Condition                                   | Glyph      | Tint      | Tap        |
/// |---|---------------------------------------------|------------|-----------|------------|
/// | 1 | this surface is raised                      | base       | `kAccent` | lowers     |
/// | 2 | keyboard icon, a local text field has focus | `_off`     | `kMuted`  | **none**   |
/// | 3 | the PC is not connected                     | base       | `kMuted`  | raises     |
/// | 4 | otherwise (resting, connected)              | base       | `kText`   | raises     |
///
/// **Why 1 beats 2.** Once Phase 15 lands, a raised keyboard focuses the
/// shell's *own* hidden IME node, which D-13-17's predicate explicitly
/// excludes, so the pair should be unreachable. The ordering exists so that an
/// unexpected focus can never disable the one affordance that dismisses the
/// thing holding focus.
///
/// **Why 1 beats 3.** Raised-while-disconnected is accent: the tint describes
/// the **overlay**, not the link. The raised surface shows its own disconnected
/// state (D-13-13), and the bar must not become a third connection channel
/// alongside the header chip and the reconnecting banner.
///
/// **Resting-and-connected is `kText`, not muted (CR-1).** D-13-11's literal
/// word is read as "never accent", which is what that sentence is for;
/// D-13-13's "when disconnected, both icons render muted" is vacuous unless the
/// connected resting state is something else. Owner-confirmed, and carried onto
/// this phase's UAT eyeball list because it is a one-const change if it reads
/// wrong on hardware.
///
/// **The disabled state is a glyph SWAP, not a tint change (CR-2).** SC4 names
/// the two screens where BAR-03 must be observable — the pairing sheet and the
/// device list — and on both the PC is by definition not connected, so the icon
/// is already muted there. A tint-only disable would be invisible on exactly
/// the screens the criterion names. The swap is also the only channel that
/// survives colour-blindness and a screen reader.
///
/// **Layout never shifts between any two states.** Same slot, same glyph size,
/// same gap, same bar rect — only the glyph identity, the tint and the presence
/// of a tap handler change. Disabling is `onTap: null` on the `InkWell` and
/// nothing else, which removes the ripple for free; that is the `_HubTile`
/// offline idiom verbatim (`hub_screen.dart:235`). No press flash, no scale,
/// no haptic: the anti-feature list bans haptics on summon and dismiss, and in
/// this app a haptic means *something happened on the PC* — a signal that must
/// not be muddied by chrome.
library;

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../theme/tokens.dart';
import 'summon_geometry.dart';
import 'summon_scope.dart';

/// Key on the trackpad slot. Tests locate the icons by key, never by glyph:
/// the keyboard glyph collides with `KeyboardTabBar`'s Type tab once Phase 15
/// mounts the tab bar inside the raised surface.
const Key kSummonTrackpadIconKey = Key('summon-icon-trackpad');

/// Key on the keyboard slot. See [kSummonTrackpadIconKey].
const Key kSummonKeyboardIconKey = Key('summon-icon-keyboard');

/// The trackpad slot's name — byte-identical to the hub tile label at
/// `hub_screen.dart:88`. Same word, same glyph, same destination; a second
/// vocabulary for the same two things is the single most confusing outcome
/// available to this phase, and Phase 17 is about to make these icons and those
/// tiles talk about each other.
const String kSummonTrackpadLabel = 'Trackpad';

/// The keyboard slot's name — byte-identical to the hub tile label at
/// `hub_screen.dart:96`.
///
/// The nouns never become verbs and never change with state (not "Show" /
/// "Hide"). Raised-ness is announced **structurally**, through
/// `Semantics(selected:)`, because Phase 17 adds a second selected-ish concept
/// ("you are here" for the screen you are on) to these same two icons and a
/// string vocabulary would have to multiply to cover the cross product.
const String kSummonKeyboardLabel = 'Keyboard';

/// State 2's label — the one place this phase spends words.
///
/// A muted slashed glyph is legible but not self-explaining, and a non-visual
/// user gets nothing from either the glyph or the tint. This names the problem
/// and the next step, with no jargon, no blame and no mechanism: not "focus",
/// not "IME", not "PIN", not "disabled". The separator is the house spaced em
/// dash. Precedent: `kSettingsWithUpdateTooltip`.
const String kSummonKeyboardBlockedLabel =
    'Keyboard — finish typing on the phone first';

/// One 56x56 bar icon slot. See the library doc for the four-state contract.
class SummonIconButton extends StatelessWidget {
  /// Which surface this slot raises and lowers.
  final SummonSurfaceKind kind;

  /// True when [kind] is the surface currently raised (state 1).
  final bool raised;

  /// True when the PC is `ChipStatus.connected`. False mutes the glyph and
  /// changes nothing else — the tap still raises (D-13-13).
  final bool connected;

  /// True when a local text field holds focus (BAR-03, state 2). Only ever
  /// consulted for the keyboard slot: the trackpad icon never enters state 2,
  /// and `touch_app_rounded` has no `_off` variant in this contract.
  final bool blocked;

  /// Fired on tap. Always the shell controller's toggle and nothing else — the
  /// summon path pushes, pops and replaces no route.
  final VoidCallback onTap;

  /// Creates one bar icon slot.
  const SummonIconButton({
    super.key,
    required this.kind,
    required this.raised,
    required this.connected,
    required this.blocked,
    required this.onTap,
  });

  /// The two glyphs already const in the tree at `hub_screen.dart:89, :97`.
  IconData get _baseGlyph => kind == SummonSurfaceKind.trackpad
      ? Symbols.touch_app_rounded
      : Symbols.keyboard_rounded;

  /// State 2's predicate. BAR-03 gates the keyboard slot only.
  bool get _isBlocked => kind == SummonSurfaceKind.keyboard && blocked;

  /// The noun, or state 2's sentence.
  String get _label {
    if (!raised && _isBlocked) return kSummonKeyboardBlockedLabel;
    return kind == SummonSurfaceKind.trackpad
        ? kSummonTrackpadLabel
        : kSummonKeyboardLabel;
  }

  @override
  Widget build(BuildContext context) {
    // The four-state function, in priority order. Every branch returns; there
    // is no fall-through and no combination outside it.
    final IconData glyph;
    final Color tint;
    final bool enabled;
    if (raised) {
      glyph = _baseGlyph;
      tint = kAccent;
      enabled = true;
    } else if (_isBlocked) {
      glyph = Symbols.keyboard_off_rounded;
      tint = kMuted;
      enabled = false;
    } else if (!connected) {
      glyph = _baseGlyph;
      tint = kMuted;
      enabled = true;
    } else {
      glyph = _baseGlyph;
      tint = kText;
      enabled = true;
    }

    // BINDING (13-UI-SPEC E2/long-text): the Tooltip is an ANCESTOR of the
    // InkWell, never a `tooltip:` property on a disabled button. A disabled
    // button does not surface its own tooltip, so riding state 2's label there
    // would make the one string this phase spends words on unreachable by both
    // long-press and TalkBack — which would undo the whole accessibility
    // rationale for the glyph swap.
    return Tooltip(
      message: _label,
      child: Semantics(
        selected: raised,
        child: SizedBox(
          width: kSummonIconSlot,
          height: kSummonIconSlot,
          child: InkWell(
            onTap: enabled ? onTap : null,
            child: Center(
              child: Icon(glyph, size: kSummonGlyphSize, color: tint),
            ),
          ),
        ),
      ),
    );
  }
}
