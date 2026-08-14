/// The summon shell's state object and the two `InheritedWidget`s that publish
/// it (13-01, SUM-04, D-13-19).
///
/// [SummonShellController] is a plain object — deliberately not a Riverpod
/// provider. It is created once by [SummonShell] above the `Navigator` and
/// lives for the whole app; there is nothing to scope, override or dispose
/// beyond the shell itself, and every consumer wants an imperative handle
/// (`raise`/`lower`/`toggle`) rather than a watched value.
///
/// **Route ownership is a monotonic `int` guard-id stack, never a retained
/// `Route`** (D-13-19). Each `SummonBackGuard` mints an id on mount, appends it
/// to [SummonShellController]'s stack, and removes it **by value** on dispose.
/// A raise records `ownerGuardId = stack.last`. Three consequences fall out
/// with no extra machinery:
///
///  * D-13-02 — only the route that raised the surface intercepts back, because
///    `ownsRaisedSurface` compares against that one id. A route pushed *after*
///    the raise has a different id, so its `canPop` is true and back pops it
///    normally while the surface rides along.
///  * D-13-03 — when the owning route is popped without a back gesture (the
///    AppBar arrow), its id leaves the stack and no live guard matches. Every
///    route's `canPop` is then true and back exits the app with the surface
///    still raised. That is the accepted trade, stated exactly; there is no
///    ownership-transfer machinery and none is wanted.
///  * Nothing retains a popped route's object graph while a surface is
///    orphaned, because "un-owned" is an *absent id*, not a dangling reference.
///
/// Both static lookups use the **non-subscribing**
/// `context.getInheritedWidgetOfExactType`, so a consumer never rebuilds off
/// summon state (P9's rebuild-scope rule; D-13-18's requirement for the
/// browser's back predicate). All reactivity rides the two [ValueNotifier]s,
/// which callers subscribe to explicitly where they want it.
library;

import 'package:flutter/widgets.dart';

/// Which surface the summon shell can raise. There is exactly one raised
/// surface at a time (SUM-01); a second raise is a swap, never a stack.
enum SummonSurfaceKind {
  /// The raised trackpad surface (Phase 14 fills it).
  trackpad,

  /// The raised keyboard surface (Phase 15 fills it).
  keyboard,
}

/// A raised surface plus the id of the guard that owns it.
///
/// Value-equal, so assigning an identical raise to
/// [SummonShellController.raised] costs no notification and therefore no
/// rebuild of any `ValueListenableBuilder` watching it.
///
/// [ownerGuardId] is legitimately `null` when the raise happened with an empty
/// guard stack (no route mounted a [SummonGuardScope] yet). A null owner is
/// owned by nobody, so no route intercepts back — the same shape as D-13-03's
/// orphan case.
class SummonRaise {
  /// Which surface is up.
  final SummonSurfaceKind surface;

  /// The guard id that was topmost when the raise happened, or null.
  final int? ownerGuardId;

  /// Creates a raise record.
  const SummonRaise({required this.surface, required this.ownerGuardId});

  @override
  bool operator ==(Object other) =>
      other is SummonRaise &&
      other.surface == surface &&
      other.ownerGuardId == ownerGuardId;

  @override
  int get hashCode => Object.hash(surface, ownerGuardId);
}

/// The app-scope summon state: what is raised, who owns it, and whether the bar
/// is currently suppressed.
///
/// Created once by [SummonShell]; the instance never changes for the app's
/// lifetime, which is why [SummonScope.updateShouldNotify] can return false.
class SummonShellController {
  /// The raised surface and its owner, or null when nothing is up.
  ///
  /// Subscribe to this where reactivity is genuinely wanted (the guard's
  /// `canPop`, the bar's tint). Never read it through a subscribing
  /// `dependOnInheritedWidgetOfExactType` — see the library doc.
  final ValueNotifier<SummonRaise?> raised = ValueNotifier<SummonRaise?>(null);

  /// False while any route has suppressed the bar (BAR-04 — the QR scanner).
  ///
  /// Backed by [_suppressDepth], not a bool: on push the incoming route's
  /// `initState` runs while the outgoing route is still mounted, and on pop
  /// `dispose` runs after the transition completes. A bool flickers at both
  /// boundaries; a depth counter does not.
  final ValueNotifier<bool> barVisible = ValueNotifier<bool>(true);

  /// The hidden IME field's focus node. **Always null in Phase 13** — the shell
  /// mounts an empty slot and Phase 15 sets this when it drops
  /// `HiddenTextInput` in. BAR-03's keyboard-icon gate (plan 13-09) needs it to
  /// tell "a real text field is focused" from "our own hidden field is
  /// focused"; without the second clause Phase 15's keyboard would disable its
  /// own dismiss affordance (D-13-17, RESEARCH correction X1).
  FocusNode? hiddenImeNode;

  /// **The single dismiss seam** (D-13-10).
  ///
  /// Invoked with the *outgoing* surface from **both** paths that take a
  /// surface off screen:
  ///
  ///  * the lower — the surface goes away entirely.
  ///  * the swap — a *different* kind is raised while one is showing. The
  ///    outgoing surface is dismissed as the incoming one takes over. There is
  ///    no lower-then-raise anywhere in the code path; the swap is one motion.
  ///
  /// **`SummonShell` owns both call expressions, not this class** (plan 13-03).
  /// The seam reports a surface *leaving the screen*, and the screen is what
  /// the shell knows about: it holds the animation state, so it is the only
  /// place that can report the outgoing kind exactly once per departure. Firing
  /// it from here as well would report every surface twice, which is worse than
  /// reporting it zero times.
  ///
  /// One seam, not two seams, precisely so a later phase cannot wire its
  /// dismiss handling to only one of them. Its two future consumers are
  /// Phase 14's `TrackpadCoreState.dismissed()` (release held mouse buttons)
  /// and Phase 15's `KeyboardInputController.dismissed()` (release held
  /// modifiers — a Shift left locked on the PC with no chip to release it is
  /// the defect this seam exists to prevent).
  void Function(SummonSurfaceKind outgoing)? onSurfaceDismissed;

  int _nextGuardId = 0;

  /// Push on guard mount, remove **by value** on guard dispose. Never indexed.
  final List<int> _guardStack = <int>[];

  int _suppressDepth = 0;

  /// True once [dispose] has run. Both suppression mutators check it, because
  /// a suppressor releases its count from a **post-frame callback** (its own
  /// lifecycle edges land inside the build phase, where notifying a listener in
  /// a sibling subtree is illegal). If the whole shell is torn down in that
  /// same frame, that callback would otherwise reach a disposed notifier and
  /// throw during teardown. Mutating a dead controller is a no-op, not a crash.
  bool _disposed = false;

  /// Mints a fresh, never-reused guard id. Monotonic by construction.
  int mintGuardId() => _nextGuardId++;

  /// Appends [id] to the guard stack. Called once per guard, from the guard's
  /// `didChangeDependencies` (the first moment the controller is reachable).
  void registerGuard(int id) => _guardStack.add(id);

  /// Removes [id] from the guard stack **by value**.
  ///
  /// By value, never by index: routes can be removed out of order
  /// (`Navigator.removeRoute`), and an index-based removal would silently
  /// retire the wrong route's ownership.
  void unregisterGuard(int id) => _guardStack.remove(id);

  /// True when a surface is raised **and** [guardId] is the guard that raised
  /// it. This is the only ownership question the guard is allowed to ask.
  bool ownsRaisedSurface(int guardId) {
    final current = raised.value;
    return current != null && current.ownerGuardId == guardId;
  }

  /// Raises [kind], recording the topmost live guard as its owner.
  ///
  /// If a *different* surface is already up this is a swap; the shell fires the
  /// dismiss seam for the outgoing surface off this notification. If the *same*
  /// surface is already up this is a no-op re-raise — ownership is deliberately
  /// **not** re-pointed at the current top of the stack, because re-raising is
  /// not a new gesture.
  void raise(SummonSurfaceKind kind) {
    final current = raised.value;
    if (current != null && current.surface == kind) return;
    raised.value = SummonRaise(
      surface: kind,
      ownerGuardId: _guardStack.isEmpty ? null : _guardStack.last,
    );
  }

  /// Lowers whatever is raised. A no-op when nothing is up. The shell fires the
  /// dismiss seam off this notification — see the seam's own doc for why the
  /// call does not live here.
  void lower() {
    final current = raised.value;
    if (current == null) return;
    raised.value = null;
  }

  /// Raises [kind] if it is not up, lowers if it is (SUM-01's toggle).
  void toggle(SummonSurfaceKind kind) {
    final current = raised.value;
    if (current != null && current.surface == kind) {
      lower();
    } else {
      raise(kind);
    }
  }

  /// Hides the bar for as long as the matching [releaseBar] has not run
  /// (BAR-04). Reentrant — see [barVisible] for why this is a depth counter.
  void suppressBar() {
    if (_disposed) return;
    _suppressDepth++;
    barVisible.value = _suppressDepth == 0;
  }

  /// Releases one suppression. The bar reappears only when every suppressor has
  /// released.
  void releaseBar() {
    if (_disposed) return;
    if (_suppressDepth > 0) _suppressDepth--;
    barVisible.value = _suppressDepth == 0;
  }

  /// Disposes the notifiers. Called by [SummonShell]'s state.
  void dispose() {
    _disposed = true;
    raised.dispose();
    barVisible.dispose();
  }
}

/// Publishes the app-scope [SummonShellController] to the whole subtree,
/// including the `Navigator` and therefore every route.
class SummonScope extends InheritedWidget {
  /// The app-scope controller. The instance never changes.
  final SummonShellController controller;

  /// Creates the scope.
  const SummonScope({
    super.key,
    required this.controller,
    required super.child,
  });

  /// The controller, looked up **without creating a dependency**.
  ///
  /// `getInheritedWidgetOfExactType`, never `dependOn…`: a caller that
  /// subscribed here would rebuild on every summon, which is exactly the
  /// per-packet-adjacent rebuild P9 forbids on the trackpad's hot path.
  /// Reactivity is opt-in through the controller's notifiers.
  static SummonShellController of(BuildContext context) {
    final scope = context.getInheritedWidgetOfExactType<SummonScope>();
    assert(scope != null, 'No SummonScope above this context');
    return scope!.controller;
  }

  /// True when the enclosing [SummonGuardScope]'s route owns the raised
  /// surface. False with no guard above (nothing to own it) and false with no
  /// shell above.
  ///
  /// This is the predicate D-13-18 requires the browser's `PopScope` callback
  /// to consult, so that exactly one action runs per back gesture regardless of
  /// which `PopEntry` the framework iterates first. Non-subscribing on both
  /// lookups — `browser_screen` must never rebuild off summon state.
  static bool ownsRaisedSurface(BuildContext context) {
    final scope = context.getInheritedWidgetOfExactType<SummonScope>();
    if (scope == null) return false;
    final guard = context.getInheritedWidgetOfExactType<SummonGuardScope>();
    if (guard == null) return false;
    return scope.controller.ownsRaisedSurface(guard.guardId);
  }

  @override
  bool updateShouldNotify(SummonScope oldWidget) => false;
}

/// Publishes the enclosing route's guard id downward, so a descendant can ask
/// "does *my* route own the raised surface?" without knowing the id itself.
class SummonGuardScope extends InheritedWidget {
  /// The id minted by the enclosing `SummonBackGuard`.
  final int guardId;

  /// Creates the guard scope.
  const SummonGuardScope({
    super.key,
    required this.guardId,
    required super.child,
  });

  @override
  bool updateShouldNotify(SummonGuardScope oldWidget) =>
      oldWidget.guardId != guardId;
}
