/// The app-scope summon host (13-01/13-02, BAR-01, BAR-02, BAR-05, SUM-01,
/// SUM-02, SUM-03, SAFE-03, MOT-01).
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
/// that adds [kSummonBarHeight] to `padding.bottom` **and** `viewPadding.bottom`
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
///
/// # The five-child `Stack`, and why the ordering is load-bearing
///
/// 1. the injected-`MediaQuery` `Navigator`; 2. the rehomed banner slot;
/// 3. the hidden-IME slot; 4. the raised surface; 5. **the bar, last**.
///
/// Later `Stack` children **paint on top**, so the bar occludes the surface
/// while the surface slides up from behind it — that is what makes the
/// "emerges from behind the bar" effect free, with no clip and no offscreen
/// layer (research P9 names `saveLayer` as one of only two real jank sources
/// here). And `Stack` hit-tests in **reverse paint order**, so the bar wins
/// taps inside its own rect on every frame of a raise and a lower, which is
/// BAR-02's "stays visible and tappable the whole time".
///
/// The surface is a `Positioned` **sibling** of the `Navigator` and never an
/// ancestor of it, so nothing beneath it is re-laid-out, resized, reflowed or
/// scrolled (SUM-02). This is not an IME-style resize contract.
///
/// # Why the bar layer is an `Overlay`
///
/// `SummonIconButton` carries a `Tooltip` as an ancestor of its `InkWell` —
/// binding, because a disabled button does not surface its own tooltip and
/// BAR-03's blocked label is the one string this phase spends words on. A
/// `Tooltip` asserts on an `Overlay` ancestor **at build time**, and the shell's
/// chrome is a *sibling* of the `Navigator`, so the `Navigator`'s own overlay is
/// below it and out of reach. The bar therefore rides in its own full-screen
/// `Overlay`: full-screen so a tooltip is positioned against the window rather
/// than squeezed into the 56dp band, and its own so nothing about the
/// `Navigator` changes. The layer passes hit tests through everywhere except
/// the bar's rect, which is asserted in `summon_shell_test.dart`.
///
/// The bar's offset is re-read inside that layer from the layer's own context.
/// That context is a sibling of the injection, not a descendant of it, so it
/// sees the same raw ancestor metrics this widget reads — and it registers its
/// own dependency, so the bar retargets across an IME animation on its own.
/// Both sites call [summonBarBottomOffset], so they cannot disagree; invariant
/// I1 (`surfaceRect.bottom == barRect.top`) is the executable proof.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../net/connection_providers.dart';
import '../theme/tokens.dart';
import '../widgets/uipi_banner.dart';
import 'summon_bar.dart';
import 'summon_geometry.dart';
import 'summon_scope.dart';
import 'summon_surface.dart';

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

class _SummonShellState extends ConsumerState<SummonShell>
    with TickerProviderStateMixin {
  /// The app-lifetime controller. Created here and never replaced, which is why
  /// [SummonScope.updateShouldNotify] can return false — all reactivity rides
  /// the controller's notifiers, not the inherited widget's identity.
  late final SummonShellController _controller = SummonShellController();

  /// The one raise controller: **one controller, two budgets**. 200ms up
  /// (MOT-01), 150ms down as the reverse duration. `TickerProviderStateMixin`
  /// rather than the single-ticker mixin because plan 13-03 adds the swap
  /// controller (D-13-10) to this same `State`.
  late final AnimationController _raise = AnimationController(
    vsync: this,
    duration: kSummonRaiseDuration,
    reverseDuration: kSummonLowerDuration,
  );

  /// Enter decelerates, exit accelerates — the house vocabulary, and no new
  /// curve type. A tap landing mid-animation reverses from the **live** value
  /// with no queue and no input lockout, which is the framework default: a
  /// 150ms reverse from 0.5 settles in ~75ms because the duration scales by the
  /// remaining distance.
  late final CurvedAnimation _curvedRaise = CurvedAnimation(
    parent: _raise,
    curve: Curves.easeOut,
    reverseCurve: Curves.easeIn,
  );

  /// Which surface is on screen, including while it animates back down. Null
  /// only once the lower has fully settled, so the slab is never yanked out
  /// from under its own exit animation.
  SummonSurfaceKind? _rendered;

  /// The bar's own layer. Created once — an `OverlayEntry` must not be rebuilt
  /// into existence per frame.
  late final OverlayEntry _barLayer = OverlayEntry(builder: _buildBarLayer);

  @override
  void initState() {
    super.initState();
    _controller.raised.addListener(_onRaisedChanged);
    _raise.addStatusListener(_onRaiseStatus);
  }

  @override
  void dispose() {
    _controller.raised.removeListener(_onRaisedChanged);
    _raise.removeStatusListener(_onRaiseStatus);
    _curvedRaise.dispose();
    _raise.dispose();
    _controller.dispose();
    super.dispose();
  }

  /// Drives the one controller off the controller's own notifier. The bar's tap
  /// handler calls `SummonShellController.toggle(kind)` and nothing else — the
  /// summon path pushes, pops and replaces no route.
  void _onRaisedChanged() {
    final raise = _controller.raised.value;
    if (raise == null) {
      unawaited(_raise.reverse());
      return;
    }
    setState(() => _rendered = raise.surface);
    unawaited(_raise.forward());
  }

  void _onRaiseStatus(AnimationStatus status) {
    if (status == AnimationStatus.dismissed && _rendered != null) {
      setState(() => _rendered = null);
    }
  }

  /// The bar layer, built inside its own `Overlay` — see the library doc.
  Widget _buildBarLayer(BuildContext context) {
    // Sibling of the injection, so this is the RAW ancestor query, and reading
    // it here registers the layer's own metrics dependency.
    final viewPadding = MediaQuery.viewPaddingOf(context);
    final viewInsets = MediaQuery.viewInsetsOf(context);
    final barBottomOffset = summonBarBottomOffset(
      viewPaddingBottom: viewPadding.bottom,
      viewInsetsBottom: viewInsets.bottom,
    );

    // BAR-04's suppression (the QR scanner) rebuilds ONLY this Positioned; the
    // cached child means the bar itself is not rebuilt by a suppression change,
    // and the rest of the shell never hears about it at all.
    return ValueListenableBuilder<bool>(
      valueListenable: _controller.barVisible,
      builder: (context, visible, child) => visible
          ? Positioned(
              left: 0,
              right: 0,
              bottom: barBottomOffset,
              height: kSummonBarHeight,
              child: child!,
            )
          : const SizedBox.shrink(),
      child: const SummonBar(),
    );
  }

  @override
  Widget build(BuildContext context) {
    // App-lifetime singleton — watching a plain Provider never rebuilds. The
    // shell sits on the trackpad's hot path on every screen, so it deliberately
    // does NOT watch connectionStatusProvider: the bar watches the value-equal
    // connectionStatusProvider itself, keeping that rebuild scoped to the bar.
    final service = ref.watch(connectionServiceProvider);

    // The RAW, UN-INJECTED ancestor query — read into locals BEFORE any
    // MediaQuery wrap is constructed below, and BEFORE any geometry is
    // computed. Reading the injected (+56) copy back for arithmetic is a silent
    // 56px error on the reference device with the IME down (RESEARCH F3, the
    // nastiest discriminator: nothing looks broken, there is just dead space).
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

    final barBottomOffset = summonBarBottomOffset(
      viewPaddingBottom: viewPadding.bottom,
      viewInsetsBottom: mq.viewInsets.bottom,
    );
    final available = summonAvailableHeight(
      windowHeight: mq.size.height,
      viewPaddingTop: viewPadding.top,
      viewPaddingBottom: viewPadding.bottom,
      viewInsetsBottom: mq.viewInsets.bottom,
    );

    final rendered = _rendered;
    final surfaceHeight =
        rendered == null ? 0.0 : summonSurfaceHeight(rendered, available);

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
                    bottom: mq.padding.bottom + kSummonBarHeight,
                  ),
                  viewPadding: viewPadding.copyWith(
                    bottom: viewPadding.bottom + kSummonBarHeight,
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
            // 4. The raised surface. Its bottom edge rests exactly on the bar's
            //    top edge (invariant I1), and it slides in with a translate and
            //    nothing else: an opacity wrapper would force an offscreen
            //    layer per frame and an implicitly-animated position would
            //    re-lay-out per frame. The chrome is passed as AnimatedBuilder's
            //    cached `child`, so it is built once per raise rather than once
            //    per frame.
            //
            //    The slot is ALWAYS present and collapses to a zero-height box
            //    when nothing is up, rather than dropping out of the children
            //    list: a `Stack` matches its children by position, so a slot
            //    that appears and disappears shifts the bar's layer onto a
            //    fresh element and its already-mounted `OverlayEntry` is then
            //    re-inserted into a second `Overlay`, which asserts. The keys
            //    below are the belt to that braces.
            Positioned(
              key: const ValueKey<String>('summon-surface-layer'),
              left: 0,
              right: 0,
              bottom: barBottomOffset + kSummonBarHeight,
              height: surfaceHeight,
              child: rendered == null
                  ? const SizedBox.shrink()
                  : AnimatedBuilder(
                      animation: _curvedRaise,
                      builder: (context, child) => Transform.translate(
                        offset:
                            Offset(0, (1 - _curvedRaise.value) * surfaceHeight),
                        child: child,
                      ),
                      child: SummonSurface(
                        kind: rendered,
                        height: surfaceHeight,
                      ),
                    ),
            ),
            // 5. The bar — LAST, so it paints over the sliding surface and
            //    hit-tests before it. See the library doc for why the layer is
            //    an Overlay rather than a bare Positioned.
            //
            //    The bar renders over modal routes — the pairing sheet, the
            //    sensitivity sheet, the power confirm dialog. That is an
            //    accepted consequence of an app-scope host AND SC4 requires it
            //    (the keyboard icon must be visibly disabled ON the pairing
            //    sheet, which is only possible if the bar is there). Do not add
            //    a second suppressor for it.
            Positioned.fill(
              key: const ValueKey<String>('summon-bar-layer'),
              child: Overlay(initialEntries: [_barLayer]),
            ),
          ],
        ),
      ),
    );
  }
}
