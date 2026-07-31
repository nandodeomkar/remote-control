/// TrackpadCore — the D8-04 hot-path engine, extracted verbatim out of
/// `_TrackpadScreenState` so BOTH the full Trackpad screen and the new
/// floating window mount the SAME cursor engine. Because they share this one
/// widget, "cursor input in the window is behavior-identical to the full
/// screen" (SC2) holds by construction.
///
/// This widget owns everything on the raw pointer route and nothing of the
/// chrome:
///
/// - the cached [ConnectionService] read (the hot path never pays a provider
///   lookup per pointer event);
/// - the pure [GestureClassifier] + the [TrackpadDriver] executor, wired with
///   every seam (`onSendMove`/`onSendScroll`/`onSendReliable`/`onHaptic`/
///   `onDragLockChanged`/`onLongPressElapsed`/`sensitivity`/`scrollReversed`/
///   `onReset`) exactly as the screen wired them;
/// - the D-05 sensitivity cache (a `listenManual` seam updating a plain double)
///   and the D-11 scroll-direction cache binding;
/// - the disconnect-hygiene `changes` subscription (transition INTO
///   disconnected → `driver.reset()`);
/// - the D-14 keep-awake hold (this core is the SOLE owner — RESEARCH
///   Pitfall 4 — acquire on mount, release on dispose, so a Presenter hold
///   survives a window excursion);
/// - the CR-01 dispose flush: on unmount (window collapse OR screen pop) a
///   still-held drag-lock on a live authed socket flushes `DragMsg(end, left)`
///   so no mouse button is left stuck behind a collapsed surface (T-08-03,
///   SC5).
///
/// HOT-PATH INVARIANT (Phase 2/3, preserved): the four pointer handlers are
/// `classifier -> driver -> service` calls with ZERO setState — the per-event
/// intent list is the only allocation.
///
/// Drag-lock is surfaced to the parent's chrome via an injected
/// [ValueNotifier] (`dragLock`) driven by `onDragLockChanged`, exposed as
/// [dragLocked] — so both the full screen's top-center pill and the window's
/// header pill read the same source with a localized rebuild. The parent owns
/// (and disposes) that notifier.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:remote_protocol/remote_protocol.dart';

import '../net/connection_providers.dart';
import '../net/connection_service.dart';
import '../screens/connection_copy.dart';
import '../settings/haptics.dart';
import '../settings/scroll_direction.dart';
import '../settings/sensitivity.dart';
import '../trackpad/tuning.dart';
import '../widgets/keep_awake.dart';
import 'dot_grid.dart';
import 'gesture_classifier.dart';
import 'trackpad_driver.dart';

/// The reusable trackpad gesture surface + hot-path engine. Mount it where a
/// pointer surface is wanted (full screen: `Positioned.fill`; window: a sized
/// Column child); the parent supplies the [authed] hint flag and the chrome.
class TrackpadCore extends ConsumerStatefulWidget {
  /// Whether the session is authed — selects the surface hint text only. The
  /// live CR-01 flush guard reads [ConnectionService.isAuthed] directly, never
  /// this flag.
  final bool authed;

  /// Parent-owned drag-lock state: the core drives it via `onDragLockChanged`;
  /// the parent's pill reads it (both surfaces read the same source). The
  /// parent creates AND disposes this notifier — the core never disposes it.
  final ValueNotifier<bool> dragLock;

  /// The keep-awake hold owner (Pitfall 4). Defaults to the process-wide
  /// [keepAwake] singleton; tests inject a spy to assert the ref-count.
  final KeepAwake? keepAwake;

  /// Dot-grid tile size for the decorative [DotGridPainter] background. The
  /// full Trackpad screen keeps the default [kTrackpadDotTileFull] (24px); the
  /// floating window passes [kTrackpadDotTileWindow] (22px).
  final double dotTile;

  /// Test seam: inject a classifier to drive the FSM deterministically.
  /// Production callers pass none → the real construction is used.
  @visibleForTesting
  final GestureClassifier? classifier;

  /// Test seam: inject a driver so `dragLocked` can be set by hand (the CR-01
  /// 4-quadrant test). Production callers pass none → the real driver wired to
  /// the service is built.
  @visibleForTesting
  final TrackpadDriver? driver;

  /// Creates the core over an injected drag-lock handle.
  const TrackpadCore({
    super.key,
    required this.authed,
    required this.dragLock,
    this.keepAwake,
    this.dotTile = kTrackpadDotTileFull,
    this.classifier,
    this.driver,
  });

  @override
  ConsumerState<TrackpadCore> createState() => TrackpadCoreState();
}

/// Public so a parent (e.g. the floating window) may read [dragLocked] via a
/// [GlobalKey] if it does not own the notifier itself.
class TrackpadCoreState extends ConsumerState<TrackpadCore> {
  /// Cached once — the provider is an app-lifetime singleton, and the hot
  /// path must not pay a provider lookup per pointer event.
  late final ConnectionService _service;

  /// Pure gesture FSM (04-03) — constructed once, system clock seam.
  late final GestureClassifier _classifier;

  /// Intent executor (04-04) — real seams wired below.
  late final TrackpadDriver _driver;

  /// The keep-awake hold owner (this core is the SOLE owner — Pitfall 4).
  late final KeepAwake _keep;

  /// Disconnect-hygiene subscription (transition detection, not UI).
  StreamSubscription<void>? _changesSub;
  ChipStatus _lastChip = ChipStatus.disconnected;

  /// Cached D-05 sensitivity — the driver's getter reads THIS double; the
  /// [sensitivityProvider] listener below updates it on change (never a
  /// provider lookup per pointer event — hot-path invariant).
  double _sensitivity = kSensitivityDefault;

  /// The drag-lock state both surfaces' pills read (localized rebuild).
  ValueListenable<bool> get dragLocked => widget.dragLock;

  @override
  void initState() {
    super.initState();
    _service = ref.read(connectionServiceProvider);
    _keep = widget.keepAwake ?? keepAwake;

    // D-05 sensitivity cache: listenManual (no widget rebuild) seeds the
    // double immediately and follows every slider change; the subscription
    // closes with the element. The hot path only ever reads _sensitivity.
    ref.listenManual<double>(
      sensitivityProvider,
      (_, next) => _sensitivity = next,
      fireImmediately: true,
    );

    // D-11 scroll-direction cache: same listenManual seam, but the cache lives
    // in scroll_direction.dart itself so the driver's scrollReversed getter
    // reads scrollReversedCached directly below — no local double needed here.
    bindScrollDirectionCache(ref);

    _classifier = widget.classifier ??
        GestureClassifier(
          nowMillis: () => DateTime.now().millisecondsSinceEpoch,
        );
    _driver = widget.driver ??
        TrackpadDriver(
          onSendMove: _service.sendMove,
          onSendScroll: _service.sendScroll,
          onSendZoom: _service.sendZoom,
          onSendReliable: _service.sendReliable,
          onHaptic: hapticTick,
          onDragLockChanged: (locked) => widget.dragLock.value = locked,
          // The timer fires back INTO the classifier; its verdict (drag start
          // or stale no-op) round-trips through the driver like any other
          // intent.
          onLongPressElapsed: () =>
              _driver.handle(_classifier.onLongPressFire()),
          sensitivity: () => _sensitivity,
          scrollReversed: () => scrollReversedCached,
          onReset: _classifier.reset,
        );

    // Disconnect hygiene: on the transition INTO disconnected, clear the
    // client gesture state (drag pill, momentum, pending long-press). The
    // server's held buttons are released by CONN-07 release_all.
    _lastChip = _service.chipStatus;
    _changesSub = _service.changes.listen((_) {
      final chip = _service.chipStatus;
      if (chip == ChipStatus.disconnected &&
          _lastChip != ChipStatus.disconnected) {
        _driver.reset();
      }
      _lastChip = chip;
    });

    // Keep the screen awake so it never dims mid-drag (D-14: ref-counted so a
    // Presenter -> window -> back excursion never drops the other's hold —
    // Pitfall 4/8). This core is the SOLE owner of the hold.
    _keep.acquire();
  }

  @override
  void dispose() {
    _changesSub?.cancel();
    // CR-01: if drag-lock is engaged and the session is still live (the surface
    // was popped/collapsed mid-drag), the PC's left button stays held —
    // _driver.dispose() deliberately sends nothing. Flush the owed drag end
    // here first, on a live socket only (a dropped session was freed by
    // CONN-07 release_all). This fires on both window collapse AND screen pop.
    if (_driver.dragLocked && _service.isAuthed) {
      _service.sendReliable(const DragMsg(action: 'end', button: 'left'));
    }
    _driver.dispose();
    _keep.release();
    super.dispose();
  }

  // Hot path: classifier -> driver -> service, NO setState, and the per-event
  // intent list is the only allocation. The service owns gating (volatile drop
  // unless authed) and the probe cadence.
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

  @override
  Widget build(BuildContext context) {
    // Raw pointer route: a zero-gesture-arena Listener with no rebuild on the
    // hot path. The parent positions this (Positioned.fill / Column child).
    return Listener(
      onPointerDown: _onPointerDown,
      onPointerMove: _onPointerMove,
      onPointerUp: _onPointerUp,
      onPointerCancel: _onPointerCancel,
      behavior: HitTestBehavior.opaque,
      // The dot-grid texture (09-01) is a decorative CustomPaint UNDER this
      // Listener: it has no child and no hitTest, so every pointer event still
      // reaches the Listener above (the drag/tap route is untouched). The hint
      // Text is layered above in an IgnorePointer so it never swallows a touch
      // either. No fake cursor dot / tap ripple (locked exclusion).
      child: Stack(
        fit: StackFit.expand,
        children: [
          CustomPaint(painter: DotGridPainter(tile: widget.dotTile)),
          IgnorePointer(
            child: Center(
              child: Text(
                widget.authed
                    ? kTrackpadHintAuthed
                    : kTrackpadHintNotConnected,
                style: const TextStyle(color: kTrackpadHintColor),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
