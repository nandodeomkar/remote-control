/// The app-scope summon host (13-01, BAR-05, SUM-02, SAFE-03).
///
/// Mounted **once**, at `MaterialApp.builder`, so its subtree is an ancestor of
/// the `Navigator` and therefore reaches all 14 screens including `home:` with
/// zero per-screen edits. The alternative — a per-route shell — was rejected
/// because it yields N `KeyboardInputController`s, so a Shift locked on the hub
/// would stay physically held on the PC with no chip anywhere to release it.
///
/// Because there is **no route above the `Navigator`**, this widget deliberately
/// contains **no `PopScope`**: `PopScope` registers with `ModalRoute.of(context)`
/// and that is null here, making a shell-level `PopScope` a silent no-op — no
/// error, no assert, no log (`widgets/pop_scope.dart:196-201`). Back handling
/// lives one scope down, in the per-route [SummonBackGuard]. Test S3 in
/// `test/shell/summon_back_guard_spike_test.dart` exists precisely so that
/// anyone who later "simplifies" the guard up into this file gets a red test
/// naming the reason.
///
/// **The BAR-05 reservation.** The `Navigator` is wrapped in one `MediaQuery`
/// that adds [_kBarReservation] to `padding.bottom` **and** `viewPadding.bottom`
/// and leaves `viewInsets` **deliberately untouched**. That last part is the
/// load-bearing half: `Scaffold` strips `viewInsets.bottom` from its body
/// (`resizeToAvoidBottomInset`, default true) but passes `padding` through
/// unchanged when there is no `bottomNavigationBar` or `persistentFooterButtons`
/// — and no screen in `lib/` has either. So the Scaffold still shrinks by the
/// real IME while every screen's `SafeArea` additionally consumes the injected
/// 56. Both IME states land on the bar's top edge with no conditional logic:
///
/// | IME  | padding.bottom here | injected | Scaffold body bottom | after SafeArea |
/// |------|---------------------|----------|----------------------|----------------|
/// | down | Pbot (e.g. 48)      | Pbot + 56| window bottom        | bottom − 48 − 56 |
/// | up   | 0 (engine-collapsed)| 0 + 56   | IME top              | IME top − 56     |
///
/// Every screen's child order is byte-identical before and after this
/// injection — nothing is inserted into any screen's tree, only the inherited
/// metrics change.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../net/connection_providers.dart';
import '../theme/tokens.dart';
import '../widgets/uipi_banner.dart';
import 'summon_scope.dart';

/// The bar's reserved height.
///
/// A local literal **only for plan 13-01**: the next plan introduces
/// `summon_geometry.dart` and this is replaced by the imported
/// `kSummonBarHeight`. Keeping it local here keeps the tracer's blast radius to
/// the three shell files.
const double _kBarReservation = 56;

/// The app-scope host for the summon bar and its raised surface.
///
/// Takes the `Navigator` as [child] (that is what `MaterialApp.builder` hands
/// it) and renders it as a `Positioned.fill` **sibling** of the shell's own
/// chrome — never an ancestor of it. That is SUM-02: raising a surface
/// re-lays-out nothing beneath it, and a tappable widget in the body outside
/// the surface's rect keeps receiving taps.
class SummonShell extends ConsumerStatefulWidget {
  /// The `Navigator` subtree handed over by `MaterialApp.builder`.
  final Widget child;

  /// Creates the shell.
  const SummonShell({super.key, required this.child});

  @override
  ConsumerState<SummonShell> createState() => _SummonShellState();
}

class _SummonShellState extends ConsumerState<SummonShell> {
  /// The app-lifetime controller. Created here and never replaced, which is why
  /// [SummonScope.updateShouldNotify] can return false — all reactivity rides
  /// the controller's notifiers, not the inherited widget's identity.
  late final SummonShellController _controller = SummonShellController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // App-lifetime singleton — watching a plain Provider never rebuilds. The
    // shell sits on the trackpad's hot path on every screen, so it deliberately
    // does NOT watch connectionStatusProvider in this plan: nothing here is
    // tinted by connection state yet. When the bar lands it watches the
    // value-equal connectionStatusProvider, never ConnectionService.changes.
    final service = ref.watch(connectionServiceProvider);

    // The RAW, UN-INJECTED ancestor query — read into locals BEFORE any
    // MediaQuery wrap is constructed below. Reading the injected (+56) copy
    // back for arithmetic is a silent 56px error on the reference device with
    // the IME down (RESEARCH F3, the nastiest discriminator).
    //
    // MediaQuery.of subscribes to ALL metrics on purpose: the shell must
    // rebuild across the whole IME animation. Building the data straight off
    // `View.of(context)` is banned here for exactly that reason — it registers
    // no dependency, so the shell would freeze at whatever metrics it first saw
    // (RESEARCH F4). For the same reason this widget installs NO metrics
    // observer at all: at this scope the query is not value-equal across the
    // IME animation, so rebuilds are already automatic. The docked panel's
    // observer is deleted, not ported.
    final mq = MediaQuery.of(context);
    // viewPaddingOf, never paddingOf: `padding.bottom` collapses to 0 while the
    // IME is up (the engine subtracts the inset) and `viewPadding` does not, so
    // the bar's own offset arithmetic must ride viewPadding. Same rule the
    // docked panel states at keyboard_panel.dart:399-403.
    final viewPadding = MediaQuery.viewPaddingOf(context);

    return SummonScope(
      controller: _controller,
      child: Material(
        color: kBg,
        child: Stack(
          children: [
            // 1. The Navigator, with the bar reserved. `viewInsets` is
            //    deliberately NOT modified here — see the library doc: the
            //    Scaffold must keep shrinking by the real IME, and only
            //    padding/viewPadding carry the bar's reservation.
            Positioned.fill(
              child: MediaQuery(
                data: mq.copyWith(
                  padding: mq.padding.copyWith(
                    bottom: mq.padding.bottom + _kBarReservation,
                  ),
                  viewPadding: viewPadding.copyWith(
                    bottom: viewPadding.bottom + _kBarReservation,
                  ),
                ),
                child: widget.child,
              ),
            ),
            // 2. The rehomed UIPI-banner slot (SAFE-03). Copied from
            //    bubble_scaffold.dart:175-183, which is the sole production
            //    mount in lib/ today. Phase 16 moves that mount here when it
            //    deletes BubbleScaffold — without this slot the deletion
            //    silently removes the SRV-05 advisory and no test catches it.
            //    Top-anchored, IgnorePointer inside UipiBanner, never steals a
            //    body touch.
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: SafeArea(
                bottom: false,
                child: UipiBanner.forService(service),
              ),
            ),
            // 3. The hidden-IME slot. Empty in Phase 13; Phase 15 drops
            //    `HiddenTextInput` in here.
            //
            //    THE CONSTRAINT (RESEARCH OQ-2 / PITFALLS P4, and the reason
            //    the host shape is a one-way door): the hidden field must be a
            //    SIBLING of the animating chrome, never a descendant of it. A
            //    field inside a Transform/animated subtree loses its connection
            //    to the platform text input while that subtree animates or
            //    rebuilds, and the IME closes mid-gesture.
            //
            //    SECURITY (T-13-04): this slot carries no Semantics label and
            //    the shell logs nothing about focus. `HiddenTextInput`'s
            //    existing ExcludeSemantics / no-logging contract must NOT be
            //    weakened when Phase 15 fills the slot — a pairing PIN typed on
            //    the phone is a credential that must never leave the phone, and
            //    must never reach the semantics tree either.
            const Positioned(
              left: 0,
              bottom: 0,
              width: 1,
              height: 1,
              child: SizedBox.shrink(),
            ),
          ],
        ),
      ),
    );
  }
}
