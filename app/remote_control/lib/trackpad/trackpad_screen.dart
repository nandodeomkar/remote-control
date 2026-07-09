/// The trackpad surface — a pure [ConnectionService] consumer (03-07, D-08),
/// grown in 04-04 into the full PAD-01..04 gesture surface.
///
/// The raw pointer routes now feed the [GestureClassifier] (pure FSM) whose
/// intents the [TrackpadDriver] executes: accelGain-scaled moves w/ the D-05
/// sensitivity, tap/two-finger-tap clicks, momentum scroll with instant
/// touch-stop, and long-press drag with drag-lock. Chrome added this plan:
/// the [MouseButtonsBar] docked beneath the surface (PAD-02), the drag-lock
/// pill (top-center, PAD-04), and the tune affordance (bottom-right) that
/// opens the D-05 sensitivity sheet. 04-05 adds the expandable
/// [KeyboardPanel] (D-07) docked below the bar with its toggle in the
/// bottom-right cluster — hidden-IME typing rides the reliable path via
/// [ImeDiffProducer] (KEY-01, D-08).
///
/// HOT-PATH INVARIANT (Phase 2/3, preserved): the pointer routes are
/// `classifier -> driver -> service` calls with ZERO setState — the per-event
/// intent list is the only allocation. The pill rides its own
/// [ValueNotifier] + [ValueListenableBuilder] (LOCALIZED rebuild — the
/// Listener subtree and header chip never rebuild); the header chip keeps its
/// 500ms poll; the banner/bar chrome watches the transition-only status
/// provider. The screen holds ONE `changes` subscription solely for
/// disconnect hygiene (driver.reset — no stale drag pill / momentum survives
/// a drop; the server half is CONN-07 release_all).
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'package:remote_protocol/remote_protocol.dart';

import '../keyboard/diff_ops.dart';
import '../keyboard/keyboard_panel.dart';
import '../net/connection_providers.dart';
import '../net/connection_service.dart';
import '../screens/connection_copy.dart';
import '../settings/sensitivity.dart';
import '../widgets/connection_header.dart';
import 'gesture_classifier.dart';
import 'mouse_buttons.dart';
import 'trackpad_driver.dart';
import 'tuning.dart';

/// The trackpad screen: hot-path surface + gesture chrome + header chip.
class TrackpadScreen extends ConsumerStatefulWidget {
  /// Creates the trackpad screen.
  const TrackpadScreen({super.key});

  @override
  ConsumerState<TrackpadScreen> createState() => _TrackpadScreenState();
}

class _TrackpadScreenState extends ConsumerState<TrackpadScreen> {
  /// Cached once — the provider is an app-lifetime singleton, and the hot
  /// path must not pay a provider lookup per pointer event.
  late final ConnectionService _service;

  /// Pure gesture FSM (04-03) — constructed once, system clock seam.
  late final GestureClassifier _classifier;

  /// Intent executor (04-04 Task 1) — real seams wired below.
  late final TrackpadDriver _driver;

  /// Drives ONLY the drag-lock pill (ValueListenableBuilder — localized
  /// rebuild; the Listener subtree and header chip never rebuild off this).
  final ValueNotifier<bool> _dragLockPill = ValueNotifier<bool>(false);

  /// Drives ONLY the keyboard panel slot + the toggle icon (D-07). Same
  /// localized-rebuild discipline: the Listener subtree is never a child of
  /// this notifier's builders (Pitfall 6 — panel animation off the hot path).
  final ValueNotifier<bool> _panelExpanded = ValueNotifier<bool>(false);

  /// Focus of the hidden IME field — focusing raises the system keyboard.
  final FocusNode _imeFocusNode = FocusNode(debugLabel: 'hidden-ime');

  /// KEY-01 committed-text diff producer (emit -> reliable path).
  late final ImeDiffProducer _imeProducer;

  /// Disconnect-hygiene subscription (transition detection, not UI).
  StreamSubscription<void>? _changesSub;
  ChipStatus _lastChip = ChipStatus.disconnected;

  /// Cached D-05 sensitivity — the driver's getter reads THIS double; the
  /// [sensitivityProvider] listener below updates it on change (never a
  /// provider lookup per pointer event — hot-path invariant).
  double _sensitivity = kSensitivityDefault;

  @override
  void initState() {
    super.initState();
    _service = ref.read(connectionServiceProvider);

    // D-05 sensitivity cache: listenManual (no widget rebuild) seeds the
    // double immediately and follows every slider change; the subscription
    // closes with the element. The hot path only ever reads _sensitivity.
    ref.listenManual<double>(
      sensitivityProvider,
      (_, next) => _sensitivity = next,
      fireImmediately: true,
    );

    _classifier = GestureClassifier(
      nowMillis: () => DateTime.now().millisecondsSinceEpoch,
    );
    _driver = TrackpadDriver(
      onSendMove: _service.sendMove,
      onSendScroll: _service.sendScroll,
      onSendReliable: _service.sendReliable,
      onHaptic: HapticFeedback.lightImpact,
      onDragLockChanged: (locked) => _dragLockPill.value = locked,
      // The timer fires back INTO the classifier; its verdict (drag start or
      // stale no-op) round-trips through the driver like any other intent.
      onLongPressElapsed: () => _driver.handle(_classifier.onLongPressFire()),
      sensitivity: () => _sensitivity,
      onReset: _classifier.reset,
    );

    // KEY-01: hidden-IME diffs ride the reliable path (queued pre-auth,
    // flushed on auth — SendPolicy owns the gating).
    _imeProducer = ImeDiffProducer(emit: _service.sendReliable);

    // Disconnect hygiene: on the transition INTO disconnected, clear the
    // client gesture state (drag pill, momentum, pending long-press) AND the
    // IME diff state (stale committed text must not skew the next diff). The
    // server's held buttons are released by CONN-07 release_all. The panel
    // may stay open; its keys render gated in 04-06.
    _lastChip = _service.chipStatus;
    _changesSub = _service.changes.listen((_) {
      final chip = _service.chipStatus;
      if (chip == ChipStatus.disconnected &&
          _lastChip != ChipStatus.disconnected) {
        _driver.reset();
        _imeProducer.reset();
      }
      _lastChip = chip;
    });

    // Keep the screen awake so it never dims mid-drag.
    WakelockPlus.enable();
  }

  @override
  void dispose() {
    _changesSub?.cancel();
    _driver.dispose();
    _dragLockPill.dispose();
    _panelExpanded.dispose();
    _imeFocusNode.dispose();
    WakelockPlus.disable();
    super.dispose();
  }

  // Hot path: classifier -> driver -> service, NO setState, and the
  // per-event intent list is the only allocation. The service owns gating
  // (volatile drop unless authed) and the probe cadence.
  void _onPointerDown(PointerDownEvent e) {
    _driver.handle(
      _classifier.onPointerDown(e.pointer, e.position.dx, e.position.dy),
    );
  }

  void _onPointerMove(PointerMoveEvent e) {
    _driver.handle(
      _classifier.onPointerMove(e.pointer, e.position.dx, e.position.dy),
    );
  }

  void _onPointerUp(PointerUpEvent e) {
    _driver.handle(_classifier.onPointerUp(e.pointer));
  }

  void _onPointerCancel(PointerCancelEvent e) {
    _driver.handle(_classifier.onPointerCancel(e.pointer));
  }

  // L/M/R bar press: reliable click + the same haptic tick as tap-clicks.
  void _onMouseButton(String button) {
    _service.sendReliable(ClickMsg(button: button));
    unawaited(HapticFeedback.lightImpact());
  }

  // The D-05 sensitivity sheet: a modal route (OUTSIDE the Listener subtree,
  // so opening it never rebuilds the hot path). The slider writes through
  // sensitivityProvider — persisted immediately, applied live via the
  // listenManual cache above.
  void _openSensitivitySheet() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF0E0F12),
      shape: const Border(top: BorderSide(color: Color(0xFF2A2D34))),
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
                  color: Color(0xFFE6E8EB),
                  fontSize: 14,
                  fontWeight: FontWeight.w400,
                ),
              ),
              Consumer(
                builder: (context, ref, _) => Slider(
                  value: ref.watch(sensitivityProvider),
                  min: kSensitivityMin,
                  max: kSensitivityMax,
                  activeColor: const Color(0xFF4C8DFF),
                  inactiveColor: const Color(0xFF2A2D34),
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
      backgroundColor: const Color(0xFF0E0F12),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Stack(
                children: [
                  // The full-bleed trackpad surface: Listener is a raw pointer
                  // route with zero gesture arena / rebuild on the hot path.
                  Positioned.fill(
                    child: Listener(
                      onPointerDown: _onPointerDown,
                      onPointerMove: _onPointerMove,
                      onPointerUp: _onPointerUp,
                      onPointerCancel: _onPointerCancel,
                      behavior: HitTestBehavior.opaque,
                      child: Container(
                        color: const Color(0xFF0E0F12),
                        alignment: Alignment.center,
                        child: Text(
                          authed
                              ? kTrackpadHintAuthed
                              : kTrackpadHintNotConnected,
                          style: const TextStyle(color: Color(0xFF6B7280)),
                        ),
                      ),
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
                        valueListenable: _dragLockPill,
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
                              color: const Color(0xFF16181D),
                              shape: const CircleBorder(
                                side: BorderSide(color: Color(0xFF2A2D34)),
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
                                        ? Icons.keyboard_hide
                                        : Icons.keyboard,
                                    size: 20,
                                    color: const Color(0xFFE6E8EB),
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
                            color: const Color(0xFF16181D),
                            shape: const CircleBorder(
                              side: BorderSide(color: Color(0xFF2A2D34)),
                            ),
                            child: InkWell(
                              customBorder: const CircleBorder(),
                              onTap: _openSensitivitySheet,
                              child: const SizedBox(
                                width: 48,
                                height: 48,
                                child: Icon(
                                  Icons.tune,
                                  size: 20,
                                  color: Color(0xFFE6E8EB),
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
        color: const Color(0xFF16181D),
        border: Border.all(color: const Color(0xFF4C8DFF)),
        borderRadius: BorderRadius.circular(999),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.lock, size: 14, color: Color(0xFF4C8DFF)),
          SizedBox(width: 4),
          Text(
            'Drag locked — tap to drop',
            style: TextStyle(
              color: Color(0xFFE6E8EB),
              fontSize: 12,
              fontWeight: FontWeight.w400,
            ),
          ),
        ],
      ),
    );
  }
}
