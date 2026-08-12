/// KeyboardInputController — the SINGLE owner of the stuck-key model for
/// BOTH keyboard surfaces (260809-ipc Task 1, D-95).
///
/// The trackpad-docked panel and the full-screen keyboard each construct one
/// of these in `initState` and dispose it from their own `dispose()`. There is
/// no second copy anywhere: the [ModifierFsm], the held-code set, the CR-01
/// IME reset tick, the D-12 disconnect transition and the LIVE-only dispose
/// flush all live here, so a fix applied to this file lands on both surfaces
/// BY CONSTRUCTION. Before this file the whole model existed twice, verbatim,
/// and the second copy was only ever provable through a widget harness.
///
/// # Why a plain object, not a mixin and not a lifted holder
///
/// Ownership IS lifecycle. The panel is a docked child built and disposed with
/// the trackpad screen; the screen is a route pushed and popped. Nothing about
/// WHEN each `dispose()` runs changes here — only WHERE the flush code lives.
/// And because this is a plain object with injected seams, every invariant
/// below is directly unit-testable with no widget at all
/// (`keyboard_input_controller_test.dart`).
///
/// # The four seams
///
/// [send] is the reliable path (the panel forwards `widget.send`, the screen
/// passes `service.sendReliable`); `changes` is the service's ping stream;
/// [isDisconnected] is probed on each ping; [onChanged] is the surface's
/// setState hook, fired whenever chip state moves.
///
/// # D-12 reset on disconnect
///
/// On the transition INTO disconnected (the false->true edge only), the
/// controller calls [ModifierFsm.disconnected] — zero effects, because the
/// socket is gone and CONN-07 release_all already freed the real keys —
/// forgets ALL held key caps so no stale `up` is ever flushed into a NEW
/// session, and fires the CR-01 IME reset tick so the hidden field atomically
/// reseeds its diff producer AND controller to the sentinel. Pre-disconnect
/// typed text can never replay after reconnect (T-04-03).
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:remote_protocol/remote_protocol.dart';

import '../settings/haptics.dart';
import 'modifier_fsm.dart';

/// The shared stuck-key owner. See the library doc for the contract.
class KeyboardInputController {
  /// The reliable-path seam every emission rides.
  final void Function(RemoteMessage msg) send;

  /// Probed on each `changes` ping: true when the chip status is
  /// disconnected. The false->true transition triggers the D-12 reset.
  final bool Function() isDisconnected;

  /// The surface's rebuild hook — fired when chip state changes.
  final VoidCallback onChanged;

  /// The ONE sticky-modifier FSM (chips poll [stateOf] after each event).
  /// Private on purpose: the surfaces drive it only through this class.
  final ModifierFsm _fsm = ModifierFsm();

  /// The key caps currently held down server-side (each sent a `down` whose
  /// `up` is still owed). Multiple caps can be concurrently held — rollover
  /// between arrow keys is the normal pattern (CR-02): each KeyCap has its
  /// own GestureDetector and pointers are tracked independently. Cleared
  /// WITHOUT ups on disconnect (D-12) — CONN-07 release_all already freed
  /// the real keys and queued stale ups must never leak into a new session.
  final Set<String> _heldCodes = <String>{};

  /// The CR-01 atomic-IME-wipe trigger: incrementing it makes the
  /// `HiddenTextInput` purge pre-disconnect typed text (potentially a
  /// password) from BOTH the diff baseline and the controller buffer in one
  /// synchronous callback, so no post-reconnect diff can replay it through
  /// sendReliable (T-04-03).
  final ValueNotifier<int> imeResetTick = ValueNotifier<int>(0);

  /// D-12 transition detection off the changes pings.
  StreamSubscription<void>? _changesSub;
  bool _wasDisconnected = false;

  /// Creates the owner and subscribes to [changes], seeding the transition
  /// edge from the current [isDisconnected] probe.
  KeyboardInputController({
    required this.send,
    required Stream<void> changes,
    required this.isDisconnected,
    required this.onChanged,
  }) {
    _wasDisconnected = isDisconnected();
    _changesSub = changes.listen((_) {
      final disconnected = isDisconnected();
      if (disconnected && !_wasDisconnected) _onDisconnected();
      _wasDisconnected = disconnected;
    });
  }

  /// The held-code set, read-only — the CR-02 tracking seam for tests.
  @visibleForTesting
  Set<String> get debugHeldCodes => Set<String>.unmodifiable(_heldCodes);

  /// D-12: reset all armed/locked chips (zero send effects — the FSM
  /// guarantees it), forget ALL held caps so their ups are skipped, and fire
  /// the CR-01 IME wipe so the hidden field's producer + controller both
  /// return to the sentinel atomically.
  void _onDisconnected() {
    _fsm.disconnected();
    _heldCodes.clear();
    imeResetTick.value++;
    onChanged();
  }

  /// Detaches from the service and releases everything this owner still owes
  /// — see [_flushHolds] for the CR-01 contract and why it is LIVE-only.
  void dispose() {
    _changesSub?.cancel();
    _flushHolds();
    imeResetTick.dispose();
  }

  /// The surface was DISMISSED while this owner lives on — the docked panel
  /// collapsed (260812-tsw).
  ///
  /// Collapsing swaps the chrome for a zero-height box, so the caps unmount
  /// and each held one frees itself through `KeyCap.dispose`. But the panel's
  /// `State` — and therefore this object — survives, so [dispose] never runs
  /// and a LOCKED modifier stays PHYSICALLY HELD on the PC with no chip left
  /// on screen to release it. Lock Shift, dismiss, and the PC behaves as
  /// though Shift is welded down.
  ///
  /// The chosen semantic is RELEASE ON DISMISS: predictable, and dismissing
  /// always leaves the PC holding nothing. The alternative — keep the lock and
  /// surface it on the collapsed chrome — was considered and rejected for the
  /// persistent chrome and the second un-lock path it costs. The trade is that
  /// "lock Shift, dismiss, drag-select on the still-live trackpad" is gone.
  ///
  /// Shares [_flushHolds] with [dispose] rather than repeating it, so a
  /// dismiss followed by a teardown emits each owed up exactly ONCE.
  ///
  /// Deliberately does NOT fire [imeResetTick]: that wipe is the CR-01 answer
  /// to a dead socket, not something hiding the keys earns.
  void dismissed() {
    _flushHolds();
    onChanged();
  }

  /// Releases everything this owner still owes, on a LIVE socket only.
  ///
  /// CR-01: the session may still be authed (the screen was popped, the
  /// hosting trackpad screen disposed, or the panel collapsed mid-hold).
  /// Flush every owed release — otherwise the server holds the input
  /// indefinitely (Windows autorepeats a held key; a locked modifier stays
  /// physically held). On a disconnected socket CONN-07 release_all already
  /// freed the real keys and sending into a NEW session would be wrong
  /// (mirrors the D-12 zero-effect path), so the FSM is reset through
  /// [ModifierFsm.disconnected] — state only, no wire traffic. That branch is
  /// inert for [dispose], whose object is being discarded; it is there for
  /// [dismissed], whose object lives on and must not keep showing locked
  /// chips for keys nothing holds.
  ///
  /// [keyUp]'s remove() guard keeps this idempotent with each cap's own
  /// dispose-time release, which Flutter runs FIRST (children unmount before
  /// parents).
  void _flushHolds() {
    if (isDisconnected()) {
      _fsm.disconnected(); // zero effects by construction
    } else {
      for (final code in _heldCodes.toList()) {
        send(KeyMsg(code: code, action: 'up'));
      }
      _sendEffects(_fsm.releaseAll()); // ups for any locked-modifier holds
    }
    _heldCodes.clear();
  }

  // ── Wiring: FSM effects + key-cap emissions -> the reliable path ─────────

  void _sendEffects(List<ModifierEffect> effects) {
    for (final effect in effects) {
      switch (effect) {
        case SendModifierDown(:final holdCode):
          send(KeyMsg(code: holdCode, action: 'down'));
        case SendModifierUp(:final holdCode):
          send(KeyMsg(code: holdCode, action: 'up'));
      }
    }
  }

  /// The current state of [mod] — the chips poll this after each event.
  ModifierState stateOf(Mod mod) => _fsm.stateOf(mod);

  /// Whether armed modifiers are pending — polled by a cap at press-down to
  /// pick the down/up vs tap+mods branch.
  bool hasArmedMods() => _fsm.modsForTap().isNotEmpty;

  /// Chip tap: arm / disarm, or release a lock's physical hold (D-10).
  void chipTap(Mod mod) {
    hapticTick();
    _sendEffects(_fsm.tap(mod));
    onChanged();
  }

  /// Chip long-press: lock, starting the physical hold (D-10).
  void chipLongPress(Mod mod) {
    hapticTick();
    _sendEffects(_fsm.longPress(mod));
    onChanged();
  }

  /// Press-down with no armed mods: `key {action: down}` (KEY-04 hold —
  /// Windows autorepeats until the up).
  void keyDown(String code) {
    _heldCodes.add(code);
    send(KeyMsg(code: code, action: 'down'));
  }

  /// Release of a non-deferred press: `key {action: up}`.
  void keyUp(String code) {
    // Only release a key whose down survived: remove() returning false
    // covers both the D-12 disconnect wipe (the server already released)
    // AND releases forwarded by the always-wired cap handlers when no down
    // ever fired (IN-04).
    if (!_heldCodes.remove(code)) return;
    send(KeyMsg(code: code, action: 'up'));
  }

  /// Release of a DEFERRED press (armed mods were pending at press-down):
  /// the combo path — `key {action: tap, mods: [...]}` (D-10).
  void keyTapWithMods(String code) {
    send(KeyMsg(code: code, action: 'tap', mods: _fsm.modsForTap()));
    _fsm.onNonModifierTap();
    onChanged(); // armed chips visually auto-reset (D-10)
  }
}
