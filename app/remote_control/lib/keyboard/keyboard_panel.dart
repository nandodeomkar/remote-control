/// KeyboardPanel — the trackpad-docked keyboard (04-05 shell, D-07;
/// rebuilt as a four-pad deck by 260809-ipc, D-91/D-92/D-93).
///
/// NOT a separate screen: it docks at the bottom of the trackpad screen
/// Column (trackpad -> L/M/R bar -> panel -> system IME) and slides
/// open/closed in 200ms ease. The trackpad shrinks above it and stays LIVE
/// for cursor movement while typing — that is the whole reason this surface
/// exists, and it is a hard contract, not a nicety.
///
/// # The same keyboard as the full-screen one, at a second mount point (D-92)
///
/// The deck here is the SAME four pads in the SAME order as `KeyboardScreen`
/// (Type | Arrows | Numpad | Fn), with the same labels, the same icons, the
/// same [KeyboardTabBar] and the same swipe. Top→bottom: the pad viewport,
/// the four-chip modifier row, the tab bar. Only the paging glue is written
/// twice, deliberately — a paging bug is cosmetic where a stuck-key bug holds
/// a real key down on the owner's PC.
///
/// # The stuck-key model is NOT owned here (D-95)
///
/// Every emission path — chip tap/long-press, key-cap down/up, key-cap
/// tap+mods, the D-12 disconnect reset, the CR-01 IME wipe and the LIVE-only
/// dispose flush — belongs to the shared [KeyboardInputController], which this
/// State constructs in `initState` and disposes in `dispose()`. The full-screen
/// keyboard constructs the SAME class, so the two surfaces cannot drift: a fix
/// there lands here by construction. This file supplies the seams
/// ([send] / [changes] / [isDisconnected]) and the layout, nothing else.
///
/// Chip/pad rebuilds ride a panel-local setState — NEVER the trackpad
/// surface (the panel subtree is isolated from the Listener per 04-05).
///
/// # IME on the Type pad only
///
/// The [HiddenTextInput] is mounted in BOTH states and OUTSIDE the animating
/// chrome — only the chrome height animates — so the Android input connection
/// survives toggling AND paging (Pitfall 6). Expanding onto Type requests
/// focus (raising the system IME); paging away from Type, or collapsing,
/// unfocuses.
///
/// # Height, and why the column is measured from the raw view
///
/// The pad viewport is per-pad ([panelPadHeight]) and animates on the existing
/// 200ms ease: Type is a slim strip, Arrows medium, Numpad and Fn tallest
/// (D-93). The clamp that keeps the trackpad usable is fed by RAW window
/// metrics rather than the ancestor MediaQuery, because in THIS tree that
/// MediaQuery has had the very insets the clamp depends on stripped out from
/// under it. See the comment at the call site in `build` — it is load-bearing.
///
/// # Pad persistence
///
/// The last-open pad persists under [kPanelPadPrefsKey] via [panelPadProvider]
/// (one model, two mount-point keys — D-94); the full-screen keyboard keeps
/// `keyboard.pad`. Entry seeds the landing page from the persisted value, with
/// a one-shot restore jump covering the async prefs load.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:remote_protocol/remote_protocol.dart';

import '../settings/haptics.dart';
import '../theme/tokens.dart';
import 'diff_ops.dart';
import 'hidden_text_input.dart';
import 'key_pads.dart';
import 'key_rows.dart';
import 'keyboard_input_controller.dart';
import 'modifier_chip.dart';
import 'modifier_fsm.dart';

/// The expandable keyboard panel (D-07 shell + the D-92 four-pad deck).
class KeyboardPanel extends ConsumerStatefulWidget {
  /// Whether the panel is open (chrome visible, IME raised).
  final bool expanded;

  /// The hidden field's focus node — focusing it raises the system IME.
  final FocusNode imeFocusNode;

  /// The committed-text diff producer feeding the reliable path.
  final ImeDiffProducer producer;

  /// False renders chips + caps gated (muted, inert — "muted, not red").
  final bool enabled;

  /// The reliable-path seam: the screen wires `service.sendReliable`.
  final void Function(RemoteMessage msg) send;

  /// The service `changes` ping stream (state-affecting transitions only).
  final Stream<void> changes;

  /// Probed on each [changes] ping: true when the chip status is
  /// disconnected. The false->true transition triggers the D-12 reset.
  final bool Function() isDisconnected;

  /// Creates the panel.
  const KeyboardPanel({
    super.key,
    required this.expanded,
    required this.imeFocusNode,
    required this.producer,
    required this.enabled,
    required this.send,
    required this.changes,
    required this.isDisconnected,
  });

  @override
  ConsumerState<KeyboardPanel> createState() => _KeyboardPanelState();
}

class _KeyboardPanelState extends ConsumerState<KeyboardPanel>
    with WidgetsBindingObserver {
  /// The shared stuck-key owner (D-95) — the SAME class the full-screen
  /// keyboard constructs. Built here, disposed here: ownership is lifecycle,
  /// and the panel's teardown moment (the docked child unmounting with the
  /// trackpad screen) is exactly when the LIVE-only flush must fire.
  late final KeyboardInputController _controller;

  // ── Pad paging state (the screen's shape, with this surface's rules) ─────

  late final PageController _pageController;

  /// The visible page — drives the tab bar, the pad height and the IME rule.
  late int _currentPage;

  /// One-shot guard for the async persisted-pad restore: flips true on the
  /// first provider update OR the first user page change, whichever wins —
  /// a late prefs load must never yank a pad the user already navigated to.
  bool _padRestoreDone = false;
  ProviderSubscription<KeyboardPad>? _padSub;

  /// A restore that arrived while the deck was NOT mounted, still owed.
  ///
  /// This surface differs from the full-screen one in a way the restore has
  /// to respect: the panel mounts COLLAPSED and stays that way until the user
  /// taps the keyboard toggle, and a collapsed panel has no `PageView` — so
  /// the prefs load, which lands within a frame or two of mount, always finds
  /// a controller with no clients. Dropping the jump there (the full-screen
  /// shape, where the deck is mounted from the first frame) would make the
  /// persisted pad silently unreachable on every real open. Instead the pad
  /// is held here and applied the moment the deck exists.
  KeyboardPad? _pendingRestore;

  KeyboardPad get _pad => KeyboardPad.values[_currentPage];

  @override
  void initState() {
    super.initState();

    // The panel measures the raw view (see build), and the view scope does
    // NOT rebuild on metric changes — this observer is the other half of
    // that read. Without it the panel never learns the IME rose or fell.
    WidgetsBinding.instance.addObserver(this);

    // Seed the landing page from the persisted pad. ref.read in initState is
    // not reactive and the store loads async, so this usually reads the
    // synchronous default; the listenManual below performs the one-shot
    // restore jump when the persisted value lands differing.
    _currentPage = ref.read(panelPadProvider).index;
    _pageController = PageController(initialPage: _currentPage);
    _padSub = ref.listenManual(panelPadProvider, (_, next) {
      _restorePad(next);
    });

    // Forwarding closures, NOT the raw widget fields: the trackpad screen
    // rebuilds this panel with fresh `send` / `isDisconnected` closures on
    // every build, and the owner outlives each of them.
    _controller = KeyboardInputController(
      send: (msg) => widget.send(msg),
      changes: widget.changes,
      isDisconnected: () => widget.isDisconnected(),
      onChanged: () {
        if (mounted) setState(() {});
      },
    );

    // IME raised only when the landing pad is Type (post-frame: the hidden
    // field must be attached before it can take focus).
    if (widget.expanded && _currentPage == KeyboardPad.type.index) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted &&
            widget.expanded &&
            _currentPage == KeyboardPad.type.index) {
          widget.imeFocusNode.requestFocus();
        }
      });
    }
  }

  /// The IME rising or falling changes the column this panel shares with the
  /// trackpad. Nothing else notifies us of it — see build.
  @override
  void didChangeMetrics() {
    if (mounted) setState(() {});
  }

  /// One-shot restore jump for the async pad load: the notifier seeds `type`
  /// synchronously and replaces it when the prefs read (or the migration)
  /// lands — if that lands on a different pad and the user hasn't navigated
  /// yet, jump there (onPageChanged then handles IME + tab state).
  void _restorePad(KeyboardPad pad) {
    if (_padRestoreDone) return;
    _padRestoreDone = true;
    if (pad.index == _currentPage) return;
    _pendingRestore = pad;
    _applyPendingRestore();
    if (_pendingRestore != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _applyPendingRestore();
      });
    }
  }

  /// Jumps the deck to a restore owed from [_restorePad], if the deck is
  /// mounted. A no-op while collapsed — [didUpdateWidget] retries on expand.
  void _applyPendingRestore() {
    final pending = _pendingRestore;
    if (pending == null || !_pageController.hasClients) return;
    _pendingRestore = null;
    _pageController.jumpToPage(pending.index);
  }

  @override
  void didUpdateWidget(KeyboardPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.expanded != oldWidget.expanded) {
      if (widget.expanded) {
        // Only the Type pad raises the IME; the other three want the height.
        // A restore owed from a collapsed load names the landing pad here,
        // so the IME is never raised only to be lowered a frame later.
        final landing = _pendingRestore ?? _pad;
        if (landing == KeyboardPad.type) widget.imeFocusNode.requestFocus();
        // The deck exists from this build onward — land the owed restore.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _applyPendingRestore();
        });
      } else {
        widget.imeFocusNode.unfocus();
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _padSub?.close();
    // The owner cancels its subscription and runs the LIVE-only flush — see
    // KeyboardInputController.dispose. Flutter unmounts children before
    // parents, so a held cap has already released through KeyCap.dispose by
    // the time this runs; the remove() guard makes the pair idempotent.
    _controller.dispose();
    _pageController.dispose();
    super.dispose();
  }

  // ── Paging ────────────────────────────────────────────────────────────────

  /// Swipe settle AND restore/tab jumps land here: persist the pad, raise the
  /// IME on Type / lower it elsewhere (only while open — a collapsed panel
  /// must never pull the keyboard up), resize the deck and update the tab bar.
  void _onPageChanged(int i) {
    _padRestoreDone = true; // navigation wins over a late prefs load
    _pendingRestore = null;
    ref.read(panelPadProvider.notifier).set(KeyboardPad.values[i]);
    if (widget.expanded) {
      if (i == KeyboardPad.type.index) {
        widget.imeFocusNode.requestFocus();
      } else {
        widget.imeFocusNode.unfocus();
      }
    }
    setState(() => _currentPage = i);
  }

  /// Tab tap: haptic + the 200ms ease page animation; [_onPageChanged]
  /// handles persistence, IME and height as the page settles.
  void _onTabSelected(KeyboardPad pad) {
    hapticTick();
    _pageController.animateToPage(
      pad.index,
      duration: const Duration(milliseconds: 200),
      curve: Curves.ease,
    );
  }

  static const _chipMods = [
    (Mod.ctrl, 'Ctrl'),
    (Mod.alt, 'Alt'),
    (Mod.shift, 'Shift'),
    (Mod.win, 'Win'),
  ];

  /// The persistent modifier chip row — visible on every pad, the same shape
  /// as the full-screen surface's (equal Expanded widths, sm gaps, md
  /// horizontal / sm vertical padding).
  Widget _chipRow() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          for (final (mod, label) in _chipMods) ...[
            if (mod != Mod.ctrl) const SizedBox(width: 8),
            Expanded(
              child: ModifierChip(
                label: label,
                state: _controller.stateOf(mod),
                enabled: widget.enabled,
                onTap: () => _controller.chipTap(mod),
                onLongPress: () => _controller.chipLongPress(mod),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// The swipeable deck: the SAME four pads the full-screen keyboard mounts.
  ///
  /// No keep-alive of any kind, ever: leaving a pad MUST dispose its caps,
  /// because that dispose IS the CR-01 release for a key held across a swipe.
  Widget _deck() {
    return PageView(
      controller: _pageController,
      allowImplicitScrolling: false,
      onPageChanged: _onPageChanged,
      children: [
        TypePad(
          // No room for the centered hint in a docked strip — and the system
          // IME sitting right below it makes the point anyway.
          showHint: false,
          enabled: widget.enabled,
          onKeyDown: _controller.keyDown,
          onKeyUp: _controller.keyUp,
          onKeyTapWithMods: _controller.keyTapWithMods,
          hasArmedMods: _controller.hasArmedMods,
          onPressHaptic: hapticTick,
        ),
        ArrowsPad(
          enabled: widget.enabled,
          onKeyDown: _controller.keyDown,
          onKeyUp: _controller.keyUp,
          onKeyTapWithMods: _controller.keyTapWithMods,
          hasArmedMods: _controller.hasArmedMods,
          onPressHaptic: hapticTick,
        ),
        NumpadPad(
          enabled: widget.enabled,
          onKeyDown: _controller.keyDown,
          onKeyUp: _controller.keyUp,
          onKeyTapWithMods: _controller.keyTapWithMods,
          hasArmedMods: _controller.hasArmedMods,
          onPressHaptic: hapticTick,
        ),
        FnPad(
          enabled: widget.enabled,
          onKeyDown: _controller.keyDown,
          onKeyUp: _controller.keyUp,
          onKeyTapWithMods: _controller.keyTapWithMods,
          hasArmedMods: _controller.hasArmedMods,
          onPressHaptic: hapticTick,
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    // THE COLUMN HEIGHT — read from the RAW view, deliberately, and do not
    // "simplify" this into MediaQuery.sizeOf/paddingOf/viewInsetsOf. Inside
    // THIS tree that formula silently returns the full window height:
    //
    //  - the trackpad screen's Scaffold has resizeToAvoidBottomInset: true,
    //    which passes removeBottomInset into _addIfNonNull ->
    //    data.removeViewInsets(removeBottom: true), so viewInsets.bottom is
    //    ZERO in the body — the whole IME height is already gone;
    //  - its SafeArea wraps the child in MediaQuery.removePadding, so
    //    padding.top and padding.bottom are ZERO too;
    //  - neither touches `size`, so size.height is still the FULL window.
    //
    // The panel would then clamp against a column larger than the one it
    // actually shares with the trackpad — over by the status inset, the
    // bottom safe inset and the entire IME — which is precisely where the
    // live-trackpad guarantee needs the clamp to bind. Worse, the resulting
    // MediaQueryData is value-equal across an IME animation, so the panel
    // would not even be notified: a stale (too large) reading racing a
    // growing panel is a RenderFlex overflow waiting to happen.
    //
    // viewPadding is IME-independent, so viewPadding.top is the status inset
    // SafeArea consumes either way. At the bottom the Column loses whichever
    // is larger: the IME (removed by resizeToAvoidBottomInset) or the bottom
    // safe inset (removed by SafeArea) — both are measured from the window
    // edge, so max() is exact and never double-counts. didChangeMetrics
    // above supplies the rebuild the view scope does not.
    final view = MediaQueryData.fromView(View.of(context));
    final columnHeight = view.size.height -
        view.viewPadding.top -
        math.max(view.viewPadding.bottom, view.viewInsets.bottom);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // ALWAYS mounted (both states, every pad): a 1x1 invisible sliver
        // outside the animating chrome, so neither toggling nor paging ever
        // detaches the IME connection.
        HiddenTextInput(
          producer: widget.producer,
          focusNode: widget.imeFocusNode,
          resetSignal: _controller.imeResetTick,
        ),

        // The animating chrome: 200ms ease between zero height and the
        // current pad's total height (D-93 — the trackpad shrinks above and
        // stays live at every one of them).
        AnimatedSize(
          duration: const Duration(milliseconds: 200),
          curve: Curves.ease,
          alignment: Alignment.topCenter,
          child: widget.expanded
              ? Container(
                  width: double.infinity,
                  decoration: const BoxDecoration(
                    // Continuous with the trackpad above.
                    color: kBg,
                    border: Border(
                      top: BorderSide(color: kHairline),
                    ),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // The pads carry their own 16px padding, so the panel
                      // adds none — the vertical vocabulary matches the
                      // full-screen surface exactly.
                      SizedBox(
                        height: panelPadHeight(_pad, columnHeight),
                        child: _deck(),
                      ),
                      _chipRow(),
                      KeyboardTabBar(
                        current: _pad,
                        onSelect: _onTabSelected,
                      ),
                    ],
                  ),
                )
              : const SizedBox(width: double.infinity, height: 0),
        ),
      ],
    );
  }
}
