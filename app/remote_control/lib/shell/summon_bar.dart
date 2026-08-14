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
///
/// The same rule governs BAR-03's focus gate below: the focus listener wraps
/// **only the keyboard icon**, never this whole widget, never the shell and
/// never the `Navigator`.
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

/// BAR-03's predicate: **a local text field holds focus** (D-13-17, 13-RESEARCH
/// §8, correction X1).
///
/// This is the one genuine security control in this phase. The pairing PIN is a
/// credential; if the summon keyboard could steal focus from the phone's PIN
/// field, the PIN would be typed into whatever window has focus on the laptop
/// and disclosed to every application there. So the keyboard icon is disabled
/// for exactly as long as something on the phone is taking typed characters.
///
/// **It is a property of the focused node, never of the screen.** There is no
/// allowlist, no per-screen flag and no name of any screen anywhere in this
/// file — a future screen that gains a text field is covered the day it is
/// written, with no edit here and nothing to remember. That property is the
/// entire reason focus gating was chosen over an allowlist.
///
/// Each clause earns its place, and the first one is the correction:
///
///  * **Do NOT gate on the focused node being absent.** It is essentially never
///    absent in a live app — the focus manager reverts to the root scope
///    whenever nothing else claims focus (`widgets/focus_manager.dart`
///    1965-1969: *"If we don't have any current focus, and nobody has asked to
///    focus yet, then revert to the root scope"*), and `WidgetsApp` autofocuses
///    a `FocusScope` around the `Navigator` (`widgets/app.dart:1692-1694`). The
///    milestone's original predicate was exactly that gate, and it would have
///    shipped a **permanently disabled** keyboard icon. The wrong version reads
///    more natural than the right one, which is why this paragraph exists.
///  * **Reference identity against the shell's own hidden field, never
///    equality, key or label.** Once Phase 15 mounts the hidden IME field, a
///    raised keyboard focuses it and the focused node genuinely *is* inside an
///    editable text. Without this escape the keyboard icon would disable itself
///    the instant the keyboard was raised, and tap-to-dismiss (SUM-03) would
///    become impossible — the only way out would be back. Shipped here, in
///    Phase 13, with a test, even though the field itself arrives later
///    (13-RESEARCH Pitfall E).
///  * **A node with no build context is not a field.** The root scope has none,
///    which is precisely the case the wrong predicate got backwards.
///  * **An exact-type ancestor lookup for the editable-text widget.** Its build
///    wraps the caller-supplied node in a `Focus` that is a *descendant* of the
///    editable text itself (`widgets/editable_text.dart:5750, 5804-5805`), and
///    both `TextField` and `TextFormField` delegate to it — so this covers
///    every text field and form field in the app, present and future, without
///    naming one of them.
bool localTextFieldHasFocus(FocusNode? shellImeNode) {
  final node = FocusManager.instance.primaryFocus;
  if (node == null) return false;
  if (identical(node, shellImeNode)) return false;
  final ctx = node.context;
  if (ctx == null) return false;
  return ctx.findAncestorWidgetOfExactType<EditableText>() != null;
}

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
            // BAR-03's gate, and its rebuild scope is the point of this
            // wrapper. The focus manager is a ChangeNotifier that notifies
            // precisely when the primary focus changed
            // (`widgets/focus_manager.dart:1636, 1999-2001`), and the listener
            // wraps ONE 56x56 slot — not the Row, not the bar, not the shell,
            // not the Navigator. A wider scope here is a cursor-latency
            // regression on the trackpad's hot path, not a tidiness question.
            ListenableBuilder(
              listenable: FocusManager.instance,
              builder: (context, _) => SummonIconButton(
                key: kSummonKeyboardIconKey,
                kind: SummonSurfaceKind.keyboard,
                raised: raise?.surface == SummonSurfaceKind.keyboard,
                connected: connected,
                // Read live, every rebuild: the shell's hidden field is null
                // until Phase 15 sets it, and the predicate must see whatever
                // it is at the moment focus changed.
                blocked: localTextFieldHasFocus(controller.hiddenImeNode),
                onTap: () => controller.toggle(SummonSurfaceKind.keyboard),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
