/// The volume store (MED-01/02, D-04) — the finger-wins volume policy plus
/// its Riverpod-3 wiring.
///
/// TWO layers, mirroring the house split (pure logic + a thin Notifier):
///
/// 1. [VolumeSliderPolicy] is a pure, clock-injected policy. It owns the D-04
///    contract: a `vol.changed` push is authoritative ONLY when the finger is
///    off the slider; during a drag the push is ignored whole and the finger
///    wins, `setvol` is emitted on a leading-edge [kSetvolThrottleMs] throttle,
///    and the final value is flushed on release unless it was already the last
///    value sent. While unauthed the policy DROPS setvol entirely — it never
///    queues (Pitfall 12: volume is continuous state, not a replayable command,
///    so a transport blip must not replay a stale volume). No Flutter, no
///    timers, no wire types — clock, auth, and send are injected.
///
/// 2. [VolumeNotifier] clones [ConnectionStatusNotifier]: it subscribes to
///    `service.changes`, reads the value-equal [VolumeSnapshot] the
///    ConnectionService parks from the `vol.changed` branch, feeds it to the
///    policy, and publishes a value-equal [VolumeViewState] the Media screen
///    watches. Drag callbacks delegate to the policy; the throttle clock is the
///    system clock, the auth gate is `service.isAuthed`, and sends go through
///    `service.sendReliable(MediaMsg(action: 'setvol', value: v))`.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:remote_protocol/remote_protocol.dart';

import '../net/connection_providers.dart';
import '../net/connection_service.dart';

/// The `setvol`-during-drag throttle window (D-04). One tunable place: the
/// leading-edge send fires immediately, then at most one send per this window
/// while the finger keeps moving; the final value is flushed on release.
const int kSetvolThrottleMs = 50;

/// Pure, clock-injected finger-wins volume policy (D-04).
///
/// State: [value] (0..100), [muted], [hasSnapshot] (a push has landed at least
/// once), [dragging]. All mutation goes through the event methods; the injected
/// [send] is invoked only for authed `setvol` emissions.
class VolumeSliderPolicy {
  /// Throttle clock (millis since epoch).
  final int Function() nowMillis;

  /// Auth gate — every send is dropped (never queued) while this returns false.
  final bool Function() isAuthed;

  /// Emits a clamped `setvol` value.
  final void Function(int value) send;

  /// The current slider value (0..100). During a drag this is the finger
  /// position; otherwise the last authoritative push.
  int value = 0;

  /// Server-authoritative mute state (follows the last push; no optimistic
  /// flip).
  bool muted = false;

  /// True once at least one push has landed (drives the pre-snapshot "--"
  /// disabled state).
  bool hasSnapshot = false;

  /// True between [dragStart] and [dragEnd] — while true, pushes are ignored.
  bool dragging = false;

  int? _lastSentValue;
  int? _lastSentAt;
  int? _pendingValue;

  /// Creates the policy. [nowMillis] is the throttle clock, [isAuthed] gates
  /// every send (drop-never-queue when false), [send] emits a clamped setvol
  /// value.
  VolumeSliderPolicy({
    required this.nowMillis,
    required this.isAuthed,
    required this.send,
  });

  /// A `vol.changed` push. Ignored WHOLE while dragging (the finger wins,
  /// D-04); otherwise value + mute are authoritative and [hasSnapshot] latches.
  void onPush(int newValue, {required bool muted}) {
    if (dragging) return; // finger wins — value AND mute ignored
    value = _clamp(newValue);
    this.muted = muted;
    hasSnapshot = true;
  }

  /// The finger touched the slider: pushes are now ignored, and the throttle
  /// bookkeeping resets so this drag's first update is a leading-edge send.
  void dragStart() {
    dragging = true;
    _lastSentValue = null;
    _lastSentAt = null;
    _pendingValue = null;
  }

  /// The finger moved to [newValue]. Emits a leading-edge setvol, then at most
  /// one send per [kSetvolThrottleMs]; dropped entirely while unauthed
  /// (never queued).
  void dragUpdate(int newValue) {
    final v = _clamp(newValue);
    value = v;
    if (!isAuthed()) return; // Pitfall 12: drop, never queue
    _pendingValue = v;
    final now = nowMillis();
    if (_lastSentAt == null || now - _lastSentAt! >= kSetvolThrottleMs) {
      _emit(v, now);
    }
  }

  /// The finger lifted: flush the final value iff it differs from the last one
  /// sent (no duplicate). Nothing is sent or queued while unauthed.
  void dragEnd() {
    dragging = false;
    final pending = _pendingValue;
    _pendingValue = null;
    if (!isAuthed()) return; // drop, never queue
    if (pending != null && pending != _lastSentValue) {
      _emit(pending, nowMillis());
    }
  }

  void _emit(int v, int now) {
    send(v);
    _lastSentValue = v;
    _lastSentAt = now;
  }

  int _clamp(int v) => v < 0 ? 0 : (v > 100 ? 100 : v);
}

/// Immutable, value-equal view of the volume state the Media screen renders.
///
/// Value-equality lets the [Notifier] skip no-op rebuilds on `changes` pings
/// that don't alter the visible volume (house pattern — mirrors
/// [ConnectionStatus]).
class VolumeViewState {
  /// Current slider value (0..100).
  final int value;

  /// Server-authoritative mute state.
  final bool muted;

  /// Whether a push has landed (false → pre-snapshot "--" disabled slider).
  final bool hasSnapshot;

  /// Whether a drag is in progress (the finger owns the value).
  final bool dragging;

  /// Creates a view snapshot.
  const VolumeViewState({
    required this.value,
    required this.muted,
    required this.hasSnapshot,
    required this.dragging,
  });

  @override
  bool operator ==(Object other) =>
      other is VolumeViewState &&
      other.value == value &&
      other.muted == muted &&
      other.hasSnapshot == hasSnapshot &&
      other.dragging == dragging;

  @override
  int get hashCode => Object.hash(value, muted, hasSnapshot, dragging);
}

/// Re-snapshots [VolumeViewState] on every service `changes` ping and drives
/// the drag policy. Clones [ConnectionStatusNotifier]'s subscribe-and-snapshot
/// shape; adds the D-04 policy delegation.
class VolumeNotifier extends Notifier<VolumeViewState> {
  StreamSubscription<void>? _sub;
  late final ConnectionService _service;
  late final VolumeSliderPolicy _policy;

  @override
  VolumeViewState build() {
    _service = ref.watch(connectionServiceProvider);
    _policy = VolumeSliderPolicy(
      nowMillis: () => DateTime.now().millisecondsSinceEpoch,
      isAuthed: () => _service.isAuthed,
      send: (v) => _service.sendReliable(MediaMsg(action: 'setvol', value: v)),
    );
    _sub?.cancel();
    _sub = _service.changes.listen((_) => _onChange());
    ref.onDispose(() {
      _sub?.cancel();
      _sub = null;
    });
    _ingestSnapshot(); // seed policy from any push already parked
    return _view();
  }

  void _onChange() {
    _ingestSnapshot();
    state = _view();
  }

  void _ingestSnapshot() {
    final snap = _service.volumeSnapshot;
    if (snap != null) {
      _policy.onPush(snap.value, muted: snap.muted);
    }
  }

  VolumeViewState _view() => VolumeViewState(
        value: _policy.value,
        muted: _policy.muted,
        hasSnapshot: _policy.hasSnapshot,
        dragging: _policy.dragging,
      );

  /// The finger touched the slider (onChangeStart).
  void dragStart() {
    _policy.dragStart();
    state = _view();
  }

  /// The finger moved (onChanged) — [value] is the rounded slider position.
  void dragUpdate(int value) {
    _policy.dragUpdate(value);
    state = _view();
  }

  /// The finger lifted (onChangeEnd).
  void dragEnd() {
    _policy.dragEnd();
    state = _view();
  }

  /// Tap the mute button: send `media {mute}`. The rendered mute state follows
  /// the next `vol.changed` push — NO optimistic flip (UI-SPEC).
  void toggleMute() {
    _service.sendReliable(const MediaMsg(action: 'mute'));
  }
}

/// The volume state snapshot the Media screen watches (slider + mute).
final volumeStateProvider =
    NotifierProvider<VolumeNotifier, VolumeViewState>(VolumeNotifier.new);
