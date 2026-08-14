/// The per-route back guard (13-01, SUM-04, D-13-02, D-13-03, D-13-19).
///
/// **Why this is per-route and not part of [SummonShell].** `PopScope`
/// registers with `ModalRoute.of(context)` in `didChangeDependencies`
/// (`widgets/pop_scope.dart:193-202`). Above the `Navigator` that returns null,
/// so `_route?.registerPopEntry(this)` is a null-aware no-op — a `PopScope` in
/// the shell never registers, never fires, and produces no error, assert or
/// log. The guard therefore has to live one scope **below** the shell, wrapping
/// each page route's content. Spike S3 pins that; spike S2 proves this guard
/// does intercept from a pushed route below the builder shell.
///
/// **Ownership, not mere raised-ness.** The only permitted `canPop` expression
/// is `!(raised && ownerGuardId == myId)`:
///
///  * a static `canPop` of false is forbidden twice over — it stops back exiting
///    the app from the hub (the root route, `main.dart`), so the phone appears
///    frozen on the dashboard (T-13-05), and it also kills Android's predictive
///    back animation, which `widgets/pop_scope.dart:162-163` states outright.
///  * `!raised` alone is forbidden because it makes **every** route intercept,
///    inverting D-13-02: back on a route pushed *after* the raise must pop that
///    route normally while the surface rides along.
///
/// With nothing raised, every guard's `canPop` is true and back exits the app
/// from the hub. When the owning route has been popped by other means (an
/// AppBar arrow), its id has left the stack, `ownsRaisedSurface` is false on
/// every live route, and back exits the app with the surface still raised —
/// D-13-03, verbatim, with zero extra code.
///
/// **Modal routes are deliberately un-guarded.** `showDialog` /
/// `showModalBottomSheet` push their own `ModalRoute`; with one open it is the
/// topmost present route, so back closes the dialog first and the raised
/// surface is untouched. That is intended behaviour — do not "fix" it.
library;

import 'package:flutter/material.dart';

import 'summon_scope.dart';

/// Wraps one page route so a system back lowers the surface **that route
/// raised** before it pops the route itself.
///
/// Every page route needs one or SUM-04 fails silently on the un-wrapped ones
/// (a later plan adds `pushGuarded<T>` plus a source-scanning guard test so an
/// un-wrapped push cannot ship). Modal routes deliberately do not — see the
/// library doc.
class SummonBackGuard extends StatefulWidget {
  /// The route's content.
  final Widget child;

  /// Creates the guard.
  const SummonBackGuard({super.key, required this.child});

  @override
  State<SummonBackGuard> createState() => _SummonBackGuardState();
}

class _SummonBackGuardState extends State<SummonBackGuard> {
  SummonShellController? _controller;

  /// This route's guard id. Minted once, never reused, never re-minted across
  /// a `didChangeDependencies` re-run.
  int? _id;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Non-subscribing lookup — this guard must never rebuild off summon state;
    // only the ValueListenableBuilder below reacts, and only its PopScope.
    final controller = SummonScope.of(context);
    if (identical(controller, _controller)) return;
    // The shell's controller is app-lifetime and never swaps in practice, so
    // this branch runs exactly once. Handle it anyway: retire the old id before
    // minting a new one, so a stale id can never linger in a live stack.
    final previous = _id;
    if (previous != null) _controller?.unregisterGuard(previous);
    _controller = controller;
    final id = controller.mintGuardId();
    _id = id;
    controller.registerGuard(id);
  }

  @override
  void dispose() {
    final id = _id;
    // Remove BY VALUE (see SummonShellController.unregisterGuard): routes can
    // be removed out of order, and index-based removal would retire the wrong
    // route's ownership.
    if (id != null) _controller?.unregisterGuard(id);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final id = _id;
    if (controller == null || id == null) return widget.child;

    // The outer ValueListenableBuilder exists ONLY so canPop stays reactive to
    // the raise state; its `child` (the route's whole content) is built exactly
    // once per SummonBackGuard build and is NEVER rebuilt by this notifier.
    // Same shape as bubble_scaffold.dart:152-166.
    return ValueListenableBuilder<SummonRaise?>(
      valueListenable: controller.raised,
      builder: (context, raise, child) => PopScope(
        canPop: !(raise != null && raise.ownerGuardId == id),
        onPopInvokedWithResult: (didPop, result) {
          // onPopInvokedWithResult also fires on a REAL pop
          // (navigator.dart:5620), so every callback starts here.
          if (didPop) return;
          // Not mine — do nothing. Another PopScope on this route (the
          // browser's folder-back) reads the same predicate, so exactly one
          // action runs per gesture regardless of which PopEntry the framework
          // iterates first. Never an order-dependent "consumed" latch.
          if (!controller.ownsRaisedSurface(id)) return;
          controller.lower();
        },
        child: child!,
      ),
      // Publishes this route's id downward so a descendant (the browser's own
      // PopScope) can ask "does MY route own the raise?" without knowing the id.
      child: SummonGuardScope(guardId: id, child: widget.child),
    );
  }
}
