/// The permanent two-icon summon bar (13-02, BAR-01, BAR-02, D-13-12,
/// D-13-13, 13-UI-SPEC § Geometry → The bar).
///
/// A 56dp band filled with [kBg] and separated from the screen above by a
/// single 1px [kHairline] rule. The bar reads as **the edge of the screen**,
/// not as a component sitting on it (D-13-12) — the icons carry all the visual
/// weight, and there is no resting accent anywhere in this phase.
///
/// # Deliberate differences from `KeyboardTabBar` (`key_pads.dart:332-402`)
///
/// That widget is the in-tree 56dp bottom icon bar and this one copies its
/// fill, its band height, its 1px top border, its 24px glyph, its
/// accent-vs-muted tint switch and its "the ripple is the entire press
/// feedback" rule. Four things differ, all binding:
///
///  * **No flex on the slots and no inner `SafeArea`.** The shell's
///    `Positioned(bottom: barBottomOffset)` owns the inset, so a second inset
///    consumer here would double-count it.
///  * **The pair is centred, not distributed.** Both icons must land in one
///    thumb's arc, and the composition must survive a hypothetical third icon
///    (v2+) without moving the existing two to new absolute positions.
///  * **The top border stays 1px [kHairline] across the full width.** It never
///    becomes the 2px accent underline — that treatment belongs to
///    `KeyboardTabBar`'s selected tab and must stay there, or Phase 17's
///    "you are here" identity has nothing left to say.
///  * **Exactly two slots, as a compile-time constant.** The 88-133.5dp of dead
///    width either side is deliberately and permanently empty (D-13-12): no
///    third slot, no placeholder, no filler widget a future icon could be
///    dropped into. The dead width absorbs taps across the full band and
///    reaches nothing beneath it, which is correct for bottom chrome — and
///    nothing is placed under it to be swallowed, because BAR-05 reserves the
///    band through the shell's one `MediaQuery` injection.
///
/// # Rebuild scope is a latency contract, not a tidiness preference
///
/// This is a `ConsumerWidget` rather than a plain `StatelessWidget` fed from
/// the shell precisely so the connection read rebuilds **the bar** and not the
/// host. It watches the value-equal `connectionStatusProvider` and nothing
/// else: never a `ConnectionService.changes` subscription, never a periodic
/// timer (D-13-13, research P9). The bar is mounted on the trackpad's hot path
/// on every screen, so a per-packet rebuild here is a cursor-latency
/// regression against the project's <30ms constraint, not a cosmetic one.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../net/connection_providers.dart';
import '../net/connection_service.dart';
import '../theme/tokens.dart';
import 'summon_geometry.dart';
import 'summon_icon_button.dart';
import 'summon_scope.dart';

/// Key on the bar's 56dp band. Tests read `barRect` from this and derive both
/// slot rects from `barRect.height`, which is [kSummonIconSlot] by definition.
const Key kSummonBarKey = Key('summon-bar');

/// The permanent two-icon bar. See the library doc for the contract.
class SummonBar extends ConsumerWidget {
  /// Creates the bar.
  const SummonBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Value-equal snapshot: ConnectionStatus implements operator == over
    // (chip, fsmState), so a changes ping that does not alter the visible
    // status costs no rebuild here.
    final status = ref.watch(connectionStatusProvider);
    final connected = status.chip == ChipStatus.connected;

    // Non-subscribing lookup — reactivity is opt-in below, through the
    // controller's own notifier, so the bar rebuilds on a raise and on nothing
    // else.
    final controller = SummonScope.of(context);

    // BAR-03's gate lands in plan 13-09, which implements D-13-17's corrected
    // predicate (the focused node has an EditableText ancestor AND is not the
    // shell's own hidden IME node). Until then no local field can block the
    // icon, so state 2 is unreachable in production and reachable only in a
    // widget test. It is wired as a value rather than omitted so 13-09 changes
    // one expression instead of adding a parameter.
    const bool keyboardBlocked = false;

    return DecoratedBox(
      key: kSummonBarKey,
      decoration: const BoxDecoration(
        color: kBg,
        border: Border(
          top: BorderSide(color: kHairline, width: kSummonHairline),
        ),
      ),
      child: ValueListenableBuilder<SummonRaise?>(
        valueListenable: controller.raised,
        builder: (context, raise, _) => Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SummonIconButton(
              key: kSummonTrackpadIconKey,
              kind: SummonSurfaceKind.trackpad,
              raised: raise?.surface == SummonSurfaceKind.trackpad,
              connected: connected,
              blocked: false,
              onTap: () => controller.toggle(SummonSurfaceKind.trackpad),
            ),
            const SizedBox(width: kSummonIconGap),
            SummonIconButton(
              key: kSummonKeyboardIconKey,
              kind: SummonSurfaceKind.keyboard,
              raised: raise?.surface == SummonSurfaceKind.keyboard,
              connected: connected,
              blocked: keyboardBlocked,
              onTap: () => controller.toggle(SummonSurfaceKind.keyboard),
            ),
          ],
        ),
      ),
    );
  }
}
