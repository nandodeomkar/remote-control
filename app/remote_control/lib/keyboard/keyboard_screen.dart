/// KeyboardScreen (10-05, KEY-01/KEY-03/KEY-04) — the full-screen swipeable
/// keyboard: a [PageView] of four pads (Type | Arrows | Numpad | Fn) with a
/// persistent modifier chip row and a bottom [KeyboardTabBar].
///
/// # The screen-level owner (the auditable stuck-key migration)
///
/// The sacred FSM / held-set / D-12 / dispose-flush logic is LIFTED — copied
/// intact, not re-derived — from the trackpad-docked `keyboard_panel.dart`
/// (which stays byte-untouched for the D-07 surface). This State owns:
///
/// - ONE [ModifierFsm] serving every pad (chips are persistent across pads,
///   so combos like Ctrl+F5 or Win+D work from any pad);
/// - the [_heldCodes] set (CR-02 rollover tracking; `up` sends only when
///   `remove()` succeeds — idempotent with each cap's own dispose release);
/// - the [_imeResetTick] CR-01 atomic-IME-wipe trigger (T-04-03);
/// - the D-12 disconnect transition off the service `changes` ping stream;
/// - the dispose() LIVE-only flush (owed cap ups + `releaseAll()` modifier
///   ups on a live socket; zero sends when disconnected — CONN-07
///   release_all already freed the real keys).
///
/// # Page lifecycle IS the release mechanism (CR-01)
///
/// `allowImplicitScrolling: false` and the default PageView child lifecycle
/// mean leaving a pad DISPOSES its caps, and a cap disposed mid-hold releases
/// its key (KeyCap.dispose). Nothing here may retain an off-screen pad's
/// State — that would silently reintroduce the stuck-key door.
///
/// # IME contract (user-locked: IME on Type only)
///
/// [HiddenTextInput] is mounted OUTSIDE the PageView so the Android input
/// connection survives page switches (Pitfall 6). Landing on / paging to the
/// Type pad requests focus (raises the system IME); any other page unfocuses
/// (the destination pad gets the full height via
/// `resizeToAvoidBottomInset: true`).
///
/// # Pad persistence
///
/// The last-open pad persists under `keyboard.pad` (10-03 store); entry seeds
/// the landing page from the persisted value (a one-shot restore jump covers
/// the async prefs load). `keyboard.rowGroup` stays owned by the docked panel.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:remote_protocol/remote_protocol.dart';

import '../net/connection_providers.dart';
import '../net/connection_service.dart';
import '../settings/haptics.dart';
import '../theme/tokens.dart';
import '../widgets/connection_header.dart';
import 'diff_ops.dart';
import 'hidden_text_input.dart';
import 'key_pads.dart';
import 'key_rows.dart';
import 'modifier_chip.dart';
import 'modifier_fsm.dart';

/// App-bar title (house rule: no inline literals).
const String kKeyboardTitle = 'Keyboard';

/// The full-screen swipeable keyboard. See the library doc for the contract.
class KeyboardScreen extends ConsumerStatefulWidget {
  /// Creates the keyboard screen.
  const KeyboardScreen({super.key});

  @override
  ConsumerState<KeyboardScreen> createState() => _KeyboardScreenState();
}

class _KeyboardScreenState extends ConsumerState<KeyboardScreen> {
  /// Cached once — app-lifetime singleton (house pattern).
  late final ConnectionService _service;

  /// Focus of the hidden IME field — focusing raises the system keyboard.
  final FocusNode _imeFocusNode = FocusNode(debugLabel: 'keyboard-screen-ime');

  /// KEY-01 committed-text diff producer (emit -> reliable path).
  late final ImeDiffProducer _imeProducer;

  // ── The sacred owners, lifted from keyboard_panel.dart ───────────────────

  /// The ONE sticky-modifier FSM (chips poll stateOf after each event).
  final ModifierFsm _fsm = ModifierFsm();

  /// The key caps currently held down server-side (each sent a `down` whose
  /// `up` is still owed). Multiple caps can be concurrently held — rollover
  /// between arrow keys is the normal pattern (CR-02): each KeyCap has its
  /// own GestureDetector and pointers are tracked independently. Cleared
  /// WITHOUT ups on disconnect (D-12) — CONN-07 release_all already freed
  /// the real keys and queued stale ups must never leak into a new session.
  final Set<String> _heldCodes = <String>{};

  /// The CR-01 atomic-IME-wipe trigger: incrementing it makes the
  /// [HiddenTextInput] purge pre-disconnect typed text (potentially a
  /// password) from BOTH the diff baseline and the controller buffer in one
  /// synchronous callback, so no post-reconnect diff can replay it through
  /// sendReliable (T-04-03).
  final ValueNotifier<int> _imeResetTick = ValueNotifier<int>(0);

  /// D-12 transition detection off the changes pings.
  StreamSubscription<void>? _changesSub;
  bool _wasDisconnected = false;

  // ── Pad paging state ──────────────────────────────────────────────────────

  late final PageController _pageController;

  /// The visible page — drives the tab bar's selected state.
  late int _currentPage;

  /// One-shot guard for the async persisted-pad restore: flips true on the
  /// first provider update OR the first user page change, whichever wins —
  /// a late prefs load must never yank a pad the user already navigated to.
  bool _padRestoreDone = false;
  ProviderSubscription<KeyboardPad>? _padSub;

  bool get _isDisconnected =>
      _service.chipStatus == ChipStatus.disconnected;

  @override
  void initState() {
    super.initState();
    _service = ref.read(connectionServiceProvider);
    _imeProducer = ImeDiffProducer(emit: _service.sendReliable);

    // Seed the landing page from the persisted pad. ref.read in initState is
    // not reactive and the store loads async, so this usually reads the
    // synchronous default; the listenManual below performs the one-shot
    // restore jump when the persisted value lands differing.
    _currentPage = ref.read(keyboardPadProvider).index;
    _pageController = PageController(initialPage: _currentPage);
    _padSub = ref.listenManual(keyboardPadProvider, (_, next) {
      _restorePad(next);
    });

    // D-12 transition detection — exactly the panel's wiring, with the
    // service seams read directly (this screen owns the service reference).
    _wasDisconnected = _isDisconnected;
    _changesSub = _service.changes.listen((_) {
      final disconnected = _isDisconnected;
      if (disconnected && !_wasDisconnected) _onDisconnected();
      _wasDisconnected = disconnected;
    });

    // IME raised only when the landing pad is Type (post-frame: the hidden
    // field must be attached before it can take focus).
    if (_currentPage == KeyboardPad.type.index) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _currentPage == KeyboardPad.type.index) {
          _imeFocusNode.requestFocus();
        }
      });
    }
  }

  /// One-shot restore jump for the async `keyboard.pad` load: the notifier
  /// seeds `type` synchronously and replaces it when the prefs read lands —
  /// if that lands on a different pad and the user hasn't navigated yet,
  /// jump there (onPageChanged then handles IME + tab state).
  void _restorePad(KeyboardPad pad) {
    if (_padRestoreDone) return;
    _padRestoreDone = true;
    if (pad.index == _currentPage) return;
    if (_pageController.hasClients) {
      _pageController.jumpToPage(pad.index);
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _pageController.hasClients) {
          _pageController.jumpToPage(pad.index);
        }
      });
    }
  }

  /// D-12: reset all armed/locked chips (zero send effects — the FSM
  /// guarantees it), forget ALL held caps so their ups are skipped, and fire
  /// the CR-01 IME wipe so the hidden field's producer + controller both
  /// return to the sentinel atomically.
  void _onDisconnected() {
    _fsm.disconnected();
    _heldCodes.clear();
    _imeResetTick.value++;
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _padSub?.close();
    _changesSub?.cancel();
    // CR-01: the session may still be authed (the screen was popped
    // mid-hold). Flush every owed release before going away — otherwise the
    // server holds the input indefinitely (Windows autorepeats a held key; a
    // locked modifier stays physically held). On a LIVE socket only: a
    // disconnected session already had its held input freed by CONN-07
    // release_all, and sending into a NEW session would be wrong (mirrors
    // the D-12 zero-effect path). _onKeyUp's remove() guard keeps this
    // idempotent with each cap's own dispose-time release.
    if (!_isDisconnected) {
      for (final code in _heldCodes.toList()) {
        _service.sendReliable(KeyMsg(code: code, action: 'up'));
      }
      _sendEffects(_fsm.releaseAll()); // ups for any locked-modifier holds
    }
    _heldCodes.clear();
    _imeResetTick.dispose();
    _pageController.dispose();
    _imeFocusNode.dispose();
    super.dispose();
  }

  // ── Wiring: FSM effects + key-cap emissions -> the reliable path ─────────

  void _sendEffects(List<ModifierEffect> effects) {
    for (final effect in effects) {
      switch (effect) {
        case SendModifierDown(:final holdCode):
          _service.sendReliable(KeyMsg(code: holdCode, action: 'down'));
        case SendModifierUp(:final holdCode):
          _service.sendReliable(KeyMsg(code: holdCode, action: 'up'));
      }
    }
  }

  void _onChipTap(Mod mod) {
    hapticTick();
    _sendEffects(_fsm.tap(mod));
    setState(() {});
  }

  void _onChipLongPress(Mod mod) {
    hapticTick();
    _sendEffects(_fsm.longPress(mod));
    setState(() {});
  }

  void _onKeyDown(String code) {
    _heldCodes.add(code);
    _service.sendReliable(KeyMsg(code: code, action: 'down'));
  }

  void _onKeyUp(String code) {
    // Only release a key whose down survived: remove() returning false
    // covers both the D-12 disconnect wipe (the server already released)
    // AND releases forwarded by the always-wired cap handlers when no down
    // ever fired (IN-04).
    if (!_heldCodes.remove(code)) return;
    _service.sendReliable(KeyMsg(code: code, action: 'up'));
  }

  void _onKeyTapWithMods(String code) {
    _service.sendReliable(
      KeyMsg(code: code, action: 'tap', mods: _fsm.modsForTap()),
    );
    _fsm.onNonModifierTap();
    setState(() {}); // armed chips visually auto-reset (D-10)
  }

  // ── Paging ────────────────────────────────────────────────────────────────

  /// Swipe settle AND restore/tab jumps land here: persist the pad, raise
  /// the IME on Type / lower it elsewhere, update the tab bar. No haptic —
  /// the tab tap already ticked in [_onTabSelected]; swipe settle carries
  /// none (UI-SPEC).
  void _onPageChanged(int i) {
    _padRestoreDone = true; // user (or restore) navigation wins over a late load
    ref.read(keyboardPadProvider.notifier).set(KeyboardPad.values[i]);
    if (i == KeyboardPad.type.index) {
      _imeFocusNode.requestFocus();
    } else {
      _imeFocusNode.unfocus();
    }
    setState(() => _currentPage = i);
  }

  /// Tab tap: haptic + 200ms ease page animation (UI-SPEC §Bottom tab bar);
  /// [_onPageChanged] handles persistence + IME as the page settles.
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

  /// The persistent modifier chip row (UI-SPEC: visible on EVERY pad — equal
  /// Expanded widths, sm gaps, md horizontal / sm vertical padding).
  Widget _chipRow(bool authed) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          for (final (mod, label) in _chipMods) ...[
            if (mod != Mod.ctrl) const SizedBox(width: 8),
            Expanded(
              child: ModifierChip(
                label: label,
                state: _fsm.stateOf(mod),
                enabled: authed,
                onTap: () => _onChipTap(mod),
                onLongPress: () => _onChipLongPress(mod),
              ),
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Transition-only snapshot: rebuilds on lifecycle changes only.
    final status = ref.watch(connectionStatusProvider);
    final authed = status.chip == ChipStatus.connected;

    // Every pad takes the same six-field KeyRows contract, closing over the
    // one screen-level FSM + held set.
    bool hasArmedMods() => _fsm.modsForTap().isNotEmpty;

    return Scaffold(
      // The raised system IME pushes the whole column up, so the chip row
      // and tab bar stay visible above it on the Type pad (UI-SPEC).
      resizeToAvoidBottomInset: true,
      backgroundColor: kBg,
      appBar: AppBar(
        backgroundColor: kBg,
        title: const Text(
          kKeyboardTitle,
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: kText,
          ),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Center(child: ConnectionHeaderChip.forService(_service)),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            // D-02: non-blocking drop strip under the app bar.
            ReconnectingBannerSlot(
              visible: status.chip == ChipStatus.reconnecting,
              onRetry: _service.retryNow,
            ),
            Expanded(
              child: PageView(
                controller: _pageController,
                // Leaving a pad disposes its caps — CR-01's release
                // mechanism. Implicit scrolling would pre-build neighbors
                // and retain the outgoing page's State; never enable it.
                allowImplicitScrolling: false,
                onPageChanged: _onPageChanged,
                children: [
                  TypePad(
                    enabled: authed,
                    onKeyDown: _onKeyDown,
                    onKeyUp: _onKeyUp,
                    onKeyTapWithMods: _onKeyTapWithMods,
                    hasArmedMods: hasArmedMods,
                    onPressHaptic: hapticTick,
                  ),
                  ArrowsPad(
                    enabled: authed,
                    onKeyDown: _onKeyDown,
                    onKeyUp: _onKeyUp,
                    onKeyTapWithMods: _onKeyTapWithMods,
                    hasArmedMods: hasArmedMods,
                    onPressHaptic: hapticTick,
                  ),
                  NumpadPad(
                    enabled: authed,
                    onKeyDown: _onKeyDown,
                    onKeyUp: _onKeyUp,
                    onKeyTapWithMods: _onKeyTapWithMods,
                    hasArmedMods: hasArmedMods,
                    onPressHaptic: hapticTick,
                  ),
                  FnPad(
                    enabled: authed,
                    onKeyDown: _onKeyDown,
                    onKeyUp: _onKeyUp,
                    onKeyTapWithMods: _onKeyTapWithMods,
                    hasArmedMods: hasArmedMods,
                    onPressHaptic: hapticTick,
                  ),
                ],
              ),
            ),
            // ALWAYS mounted, OUTSIDE the PageView: a 1x1 invisible sliver so
            // page switches never detach the IME connection (Pitfall 6).
            HiddenTextInput(
              producer: _imeProducer,
              focusNode: _imeFocusNode,
              resetSignal: _imeResetTick,
            ),
            // Persistent modifier chips — on every pad, gated on auth.
            _chipRow(authed),
            // Bottom pad selector — always interactive (navigation, not
            // sends; the caps and chips carry the gating).
            KeyboardTabBar(
              current: KeyboardPad.values[_currentPage],
              onSelect: _onTabSelected,
            ),
          ],
        ),
      ),
    );
  }
}
