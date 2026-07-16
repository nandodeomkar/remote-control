/// The trackpad screen — since 08-02 a THIN composition of [TrackpadCore]
/// (the D8-04 hot-path engine) + its retained chrome.
///
/// The hot path (raw pointer routes → [GestureClassifier] → [TrackpadDriver] →
/// service, the D-05 sensitivity / D-11 scroll caches, the disconnect-hygiene
/// subscription, the D-14 keep-awake hold, and the CR-01 dispose flush) now
/// lives entirely in [TrackpadCore] so the floating window (08-04) mounts the
/// SAME engine. This screen mounts the core as its full-bleed gesture surface
/// and layers the chrome OVER it: the [MouseButtonsBar] docked beneath (PAD-02),
/// the drag-lock pill (top-center, PAD-04) reading the core's drag-lock
/// listenable, the tune affordance (bottom-right) that opens the D-05
/// sensitivity sheet, and the expandable [KeyboardPanel] (D-07) with its toggle
/// — hidden-IME typing rides the reliable path via [ImeDiffProducer]
/// (KEY-01, D-08).
///
/// The extraction is behavior-neutral (D8-04): the primitive gesture tests pass
/// unmodified and the composition smoke test renders the same chrome after the
/// slim. The pill rides a [ValueNotifier] the core drives (LOCALIZED rebuild —
/// the core's Listener subtree and the header chip never rebuild off it); the
/// header chip keeps its 500ms poll; the banner/bar chrome watches the
/// transition-only status provider.
library;

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:remote_protocol/remote_protocol.dart';

import '../keyboard/diff_ops.dart';
import '../keyboard/keyboard_panel.dart';
import '../net/connection_providers.dart';
import '../net/connection_service.dart';
import '../settings/haptics.dart';
import '../settings/sensitivity.dart';
import '../theme/tokens.dart';
import '../widgets/connection_header.dart';
import 'mouse_buttons.dart';
import 'trackpad_core.dart';
import 'tuning.dart';

/// The trackpad screen: hot-path surface + gesture chrome + header chip.
class TrackpadScreen extends ConsumerStatefulWidget {
  /// Creates the trackpad screen.
  const TrackpadScreen({super.key});

  @override
  ConsumerState<TrackpadScreen> createState() => _TrackpadScreenState();
}

class _TrackpadScreenState extends ConsumerState<TrackpadScreen> {
  /// Cached once for the chrome (mouse-button clicks, IME diffs, keyboard
  /// panel, header chip, banner retry). The hot path's own service read lives
  /// inside [TrackpadCore] — never a provider lookup per pointer event.
  late final ConnectionService _service;

  /// The shared drag-lock state: [TrackpadCore] drives it via
  /// `onDragLockChanged`, and the top-center pill reads it (localized rebuild;
  /// the core's Listener subtree and the header chip never rebuild off this).
  /// This screen owns and disposes it.
  final ValueNotifier<bool> _dragLock = ValueNotifier<bool>(false);

  /// Drives ONLY the keyboard panel slot + the toggle icon (D-07). Same
  /// localized-rebuild discipline: the core's surface is never a child of
  /// this notifier's builders (Pitfall 6 — panel animation off the hot path).
  final ValueNotifier<bool> _panelExpanded = ValueNotifier<bool>(false);

  /// Focus of the hidden IME field — focusing raises the system keyboard.
  final FocusNode _imeFocusNode = FocusNode(debugLabel: 'hidden-ime');

  /// KEY-01 committed-text diff producer (emit -> reliable path).
  late final ImeDiffProducer _imeProducer;

  @override
  void initState() {
    super.initState();
    _service = ref.read(connectionServiceProvider);

    // KEY-01: hidden-IME diffs ride the reliable path (queued pre-auth,
    // flushed on auth — SendPolicy owns the gating).
    _imeProducer = ImeDiffProducer(emit: _service.sendReliable);
  }

  @override
  void dispose() {
    _dragLock.dispose();
    _panelExpanded.dispose();
    _imeFocusNode.dispose();
    super.dispose();
  }

  // L/M/R bar press: reliable click + the same haptic tick as tap-clicks.
  void _onMouseButton(String button) {
    _service.sendReliable(ClickMsg(button: button));
    hapticTick();
  }

  // The D-05 sensitivity sheet: a modal route (OUTSIDE the Listener subtree,
  // so opening it never rebuilds the hot path). The slider writes through
  // sensitivityProvider — persisted immediately, applied live via the
  // listenManual cache above.
  void _openSensitivitySheet() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: kBg,
      shape: const Border(top: BorderSide(color: kHairline)),
      builder: (context) => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Pointer speed',
                style: TextStyle(
                  color: kText,
                  fontSize: 14,
                  fontWeight: FontWeight.w400,
                ),
              ),
              Consumer(
                builder: (context, ref, _) => Slider(
                  value: ref.watch(sensitivityProvider),
                  min: kSensitivityMin,
                  max: kSensitivityMax,
                  activeColor: kAccent,
                  inactiveColor: kHairline,
                  onChanged: ref.read(sensitivityProvider.notifier).set,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Transition-only snapshot (value-equal): rebuilds on lifecycle changes,
    // NEVER on the move path (Phase-2 invariant, RESEARCH Pitfall 9).
    final status = ref.watch(connectionStatusProvider);
    final authed = status.chip == ChipStatus.connected;

    return Scaffold(
      // D-07: the raised system IME pushes the whole Column up — the
      // trackpad shrinks above the panel but never hides, and stays live.
      resizeToAvoidBottomInset: true,
      backgroundColor: kBg,
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Stack(
                children: [
                  // The full-bleed trackpad surface + hot-path engine
                  // (D8-04): the SAME TrackpadCore the floating window mounts,
                  // so cursor behavior is identical by construction. It owns
                  // the pointer route, caches, keep-awake, and the CR-01
                  // dispose flush; this screen just supplies the authed hint
                  // and the shared drag-lock handle.
                  Positioned.fill(
                    child: TrackpadCore(
                      authed: authed,
                      dragLock: _dragLock,
                    ),
                  ),

                  // Banner (full-width, under the safe-area top) + header
                  // chip (top-right — the old HUD slot). The chip ignores
                  // pointers so the trackpad surface stays uninterrupted.
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        ReconnectingBannerSlot(
                          visible: status.chip == ChipStatus.reconnecting,
                          onRetry: _service.retryNow,
                        ),
                        Align(
                          alignment: Alignment.topRight,
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: IgnorePointer(
                              child: ConnectionHeaderChip.forService(_service),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                  // Drag-lock pill (PAD-04): top-center, visible ONLY while
                  // drag-lock is engaged. Rides its own ValueNotifier so the
                  // rebuild is LOCALIZED to this subtree — never the Listener
                  // or the header chip.
                  Positioned(
                    top: 16,
                    left: 0,
                    right: 0,
                    child: Center(
                      child: ValueListenableBuilder<bool>(
                        valueListenable: _dragLock,
                        builder: (context, locked, _) => IgnorePointer(
                          child: AnimatedOpacity(
                            opacity: locked ? 1.0 : 0.0,
                            duration: const Duration(milliseconds: 150),
                            child: const _DragLockPill(),
                          ),
                        ),
                      ),
                    ),
                  ),

                  // Bottom-right floating cluster (above the L/M/R bar):
                  // keyboard-panel toggle (D-07) over the tune affordance
                  // (D-05). Both neutral at rest — never accent. Only the
                  // toggle's icon rides the panel notifier (localized
                  // rebuild; the Listener subtree never rebuilds off it).
                  Positioned(
                    bottom: 16,
                    right: 16,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        ValueListenableBuilder<bool>(
                          valueListenable: _panelExpanded,
                          builder: (context, expanded, _) => Tooltip(
                            message: expanded ? 'Hide keys' : 'Show keys',
                            child: Material(
                              color: kSurface,
                              shape: const CircleBorder(
                                side: BorderSide(color: kHairline),
                              ),
                              child: InkWell(
                                customBorder: const CircleBorder(),
                                onTap: () =>
                                    _panelExpanded.value = !expanded,
                                child: SizedBox(
                                  width: 48,
                                  height: 48,
                                  child: Icon(
                                    expanded
                                        ? Symbols.keyboard_hide_rounded
                                        : Symbols.keyboard_rounded,
                                    size: 20,
                                    color: kText,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Tooltip(
                          message: 'Pointer speed',
                          child: Material(
                            color: kSurface,
                            shape: const CircleBorder(
                              side: BorderSide(color: kHairline),
                            ),
                            child: InkWell(
                              customBorder: const CircleBorder(),
                              onTap: _openSensitivitySheet,
                              child: const SizedBox(
                                width: 48,
                                height: 48,
                                child: Icon(
                                  Symbols.tune_rounded,
                                  size: 20,
                                  color: kText,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            // L/M/R mouse buttons (PAD-02): docked, always visible, gated
            // muted when not authed ("muted, not red").
            MouseButtonsBar(onPress: _onMouseButton, enabled: authed),

            // Keyboard panel (D-07): docked below the bar (trackpad -> bar
            // -> panel -> system IME). ONLY this slot rides the notifier —
            // the Expanded trackpad Stack above keeps its widget identity so
            // panel animation never rebuilds the hot path (Pitfall 6).
            ValueListenableBuilder<bool>(
              valueListenable: _panelExpanded,
              builder: (context, expanded, _) => KeyboardPanel(
                expanded: expanded,
                imeFocusNode: _imeFocusNode,
                producer: _imeProducer,
                // 04-06 rows wiring: chips/caps gate on auth; all KeyMsg
                // traffic rides the reliable path; the panel's own changes
                // subscription drives the D-12 reset (fsm + held cap).
                enabled: authed,
                send: _service.sendReliable,
                changes: _service.changes,
                isDisconnected: () =>
                    _service.chipStatus == ChipStatus.disconnected,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The drag-lock indicator pill (UI-SPEC): `#16181D` fill, `#4C8DFF` 1px
/// border, accent lock glyph + "Drag locked — tap to drop" (12/400).
class _DragLockPill extends StatelessWidget {
  const _DragLockPill();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: kSurface,
        border: Border.all(color: kAccent),
        borderRadius: BorderRadius.circular(999),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Symbols.lock_rounded, size: 14, color: kAccent),
          SizedBox(width: 4),
          Text(
            'Drag locked — tap to drop',
            style: TextStyle(
              color: kText,
              fontSize: 12,
              fontWeight: FontWeight.w400,
            ),
          ),
        ],
      ),
    );
  }
}
