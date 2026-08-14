/// Route-scoped suppression of the summon bar (13-09, BAR-04, 13-RESEARCH §9).
///
/// The shell is mounted above the `Navigator` and therefore cannot read route
/// identity — it does not know which screen is on top and must not learn. So
/// the screen that needs the bar gone says so itself, by wrapping its own
/// content: the wrapper takes a suppression while it is mounted and gives it
/// back when it is not. Nothing else in the app needs to know that any of this
/// happened.
///
/// # Why depth-counted and NOT a boolean
///
/// A boolean flickers the bar at **both** lifecycle boundaries, because a route
/// transition is not an instant:
///
///  * **On push**, the incoming route's `initState` runs while the outgoing
///    route is still mounted and still on screen. A boolean set by the incoming
///    route is correct for it and wrong for the one still being looked at.
///  * **On pop**, `dispose` runs only *after* the transition completes. A
///    boolean cleared by the outgoing route would put the bar back over a
///    scanner that is still visible, for the length of the transition.
///
/// The counter makes both boundaries no-ops: the bar's visibility is a function
/// of *how many* suppressions are outstanding, so overlapping lifetimes compose
/// instead of fighting. The defect a boolean produces is worth naming, because
/// it is the kind that gets misfiled: a bar blinking once per navigation reads
/// as a rendering glitch, and someone goes looking in the paint path for a
/// state bug.
///
/// # Exactly one mount site
///
/// The QR pairing scanner, and nothing else. It is the one screen where the
/// bar could sit over live credential capture, and the scanner's own route is
/// pushed from exactly one place in the app.
///
/// **Nesting, stated once so it stays consistent:** the back guard is
/// **outermost** and this wrapper sits **inside** it. That falls out of the
/// guarded-push seam owning route construction — the guard wraps whatever
/// widget it is handed — and either order would be correct on its own, so the
/// rule here is simply that there is one order and this is it.
///
/// # Both edges are applied at the END of the frame, and they have to be
///
/// The counter lives behind a `ValueNotifier` that the bar's own layer listens
/// to, and that layer is a **sibling subtree** of the `Navigator` — not an
/// ancestor of this widget and not a descendant. Both of this widget's
/// lifecycle edges land inside the frame's build phase:
///
///  * `initState` for a pushed route runs while the framework is building
///    (`markNeedsBuild` on a widget outside the current build target throws
///    *"setState() or markNeedsBuild() called during build"*).
///  * `dispose` runs from `BuildOwner.finalizeTree`, which unmounts inside
///    `lockState` (`framework.dart:3344`), so a notification there throws
///    *"setState() ... called when widget tree was locked"*.
///
/// So each edge is applied in a post-frame callback. The cost is one frame at
/// each boundary, and neither is observable, which is the only reason this is
/// acceptable rather than a defect:
///
///  * **On push**, the extra frame is the frame in which the incoming route's
///    transition value is still 0 — the screen is translated entirely off the
///    viewport. The bar is present in that frame the same way it was present in
///    every frame before the push, and it is not drawn over a single visible
///    pixel of the suppressed screen. There is no on/off/on anywhere.
///  * **On pop**, the route is disposed only after its transition has finished,
///    so the bar returns one frame after the screen has completely gone. Late,
///    never early — which is the correct direction for the one boundary where
///    being early would put chrome back over live credential capture.
///
/// This is the exact reason the shape is a counter rather than a flag: with
/// deferral in play, the push and pop edges of two routes overlap even more
/// than they already did, and only a counter composes.
///
/// # The consequence this does NOT fix
///
/// The bar renders **over** modal routes — the pairing sheet, the sensitivity
/// sheet, the power confirm dialog. That is an accepted consequence of an
/// app-scope host, and the success criterion actively **requires** it: the
/// keyboard icon must be visibly disabled *on the pairing sheet*, which is only
/// observable if the bar is there. Do not add a second suppressor for a modal
/// route. The power confirm dialog with the bar over it is on this phase's UAT
/// eyeball list, deliberately, as an observation rather than a defect.
library;

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import 'summon_scope.dart';

/// Wraps a route's content so the summon bar is hidden for as long as that
/// content is mounted (BAR-04). See the library doc for why this is counted
/// rather than flagged, and why there is exactly one mount site.
class SummonBarSuppressor extends StatefulWidget {
  /// The route's content. Rendered unchanged — this widget adds no box, no
  /// padding and no layout of any kind, so wrapping a screen in it cannot move
  /// a single pixel of that screen.
  final Widget child;

  /// Creates the suppressor.
  const SummonBarSuppressor({super.key, required this.child});

  @override
  State<SummonBarSuppressor> createState() => _SummonBarSuppressorState();
}

class _SummonBarSuppressorState extends State<SummonBarSuppressor> {
  /// The controller this state took its suppression from, held so the release
  /// can only ever land on the same object that was incremented.
  late final SummonShellController _controller;

  @override
  void initState() {
    super.initState();
    // Safe in initState, and deliberately here rather than in
    // didChangeDependencies: the lookup is NON-SUBSCRIBING (it registers no
    // dependency, so this widget never rebuilds off summon state) and
    // inherited widgets are wired up in `Element.mount`, which runs before
    // `initState`. didChangeDependencies would be the wrong home anyway — it
    // can run more than once, and a suppression taken twice and released once
    // hides the bar forever.
    _controller = SummonScope.of(context);
    _atEndOfFrame(_controller.suppressBar);
  }

  @override
  void dispose() {
    _atEndOfFrame(_controller.releaseBar);
    super.dispose();
  }

  /// Runs [mutate] as soon as it is legal to notify a listener that lives
  /// outside this subtree — see the library doc for why neither edge may do it
  /// inline. Immediate when the framework is not mid-frame, so nothing pays for
  /// this except the two lifecycle edges that have to.
  void _atEndOfFrame(VoidCallback mutate) {
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) => mutate());
    } else {
      mutate();
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
