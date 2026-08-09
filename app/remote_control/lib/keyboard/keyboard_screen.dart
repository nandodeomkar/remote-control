/// KeyboardScreen (10-05, KEY-01/KEY-03/KEY-04) — the full-screen swipeable
/// keyboard: a [PageView] of four pads (Type | Arrows | Numpad | Fn) with a
/// persistent modifier chip row and a bottom [KeyboardTabBar].
///
/// # The shared stuck-key owner (D-95)
///
/// The sacred FSM / held-set / D-12 / dispose-flush logic is not written here
/// and is not written twice: it lives in [KeyboardInputController], which this
/// State constructs in `initState` and disposes in `dispose()`. The
/// trackpad-docked panel constructs the SAME class, so the two surfaces cannot
/// drift. That owner holds:
///
/// - ONE modifier FSM serving every pad (chips are persistent across pads,
///   so combos like Ctrl+F5 or Win+D work from any pad);
/// - the held-code set (CR-02 rollover tracking; `up` sends only when
///   `remove()` succeeds — idempotent with each cap's own dispose release);
/// - the CR-01 atomic-IME-wipe trigger (T-04-03);
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

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../net/connection_providers.dart';
import '../net/connection_service.dart';
import '../settings/haptics.dart';
import '../theme/tokens.dart';
import '../widgets/connection_header.dart';
import 'diff_ops.dart';
import 'hidden_text_input.dart';
import 'key_pads.dart';
import 'key_rows.dart';
import 'keyboard_input_controller.dart';
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

  // ── The shared stuck-key owner (D-95) ────────────────────────────────────

  /// The one owner of the FSM, the held set, the CR-01 IME reset tick, the
  /// D-12 transition and the LIVE-only dispose flush — the SAME class the
  /// trackpad-docked panel constructs.
  late final KeyboardInputController _controller;

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

    // The shared owner, with the service seams read directly (this screen
    // owns the service reference).
    _controller = KeyboardInputController(
      send: _service.sendReliable,
      changes: _service.changes,
      isDisconnected: () => _isDisconnected,
      onChanged: () {
        if (mounted) setState(() {});
      },
    );

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

  @override
  void dispose() {
    _padSub?.close();
    // The owner cancels its subscription and runs the LIVE-only flush at
    // exactly the position the inline flush block occupied — see
    // KeyboardInputController.dispose.
    _controller.dispose();
    _pageController.dispose();
    _imeFocusNode.dispose();
    super.dispose();
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
                state: _controller.stateOf(mod),
                enabled: authed,
                onTap: () => _controller.chipTap(mod),
                onLongPress: () => _controller.chipLongPress(mod),
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
    // one shared owner.
    final hasArmedMods = _controller.hasArmedMods;

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
                    onKeyDown: _controller.keyDown,
                    onKeyUp: _controller.keyUp,
                    onKeyTapWithMods: _controller.keyTapWithMods,
                    hasArmedMods: hasArmedMods,
                    onPressHaptic: hapticTick,
                  ),
                  ArrowsPad(
                    enabled: authed,
                    onKeyDown: _controller.keyDown,
                    onKeyUp: _controller.keyUp,
                    onKeyTapWithMods: _controller.keyTapWithMods,
                    hasArmedMods: hasArmedMods,
                    onPressHaptic: hapticTick,
                  ),
                  NumpadPad(
                    enabled: authed,
                    onKeyDown: _controller.keyDown,
                    onKeyUp: _controller.keyUp,
                    onKeyTapWithMods: _controller.keyTapWithMods,
                    hasArmedMods: hasArmedMods,
                    onPressHaptic: hapticTick,
                  ),
                  FnPad(
                    enabled: authed,
                    onKeyDown: _controller.keyDown,
                    onKeyUp: _controller.keyUp,
                    onKeyTapWithMods: _controller.keyTapWithMods,
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
              resetSignal: _controller.imeResetTick,
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
