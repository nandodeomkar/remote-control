/// Riverpod 3 wiring for [ConnectionService] (CONN-03..CONN-06 consumers).
///
/// Two providers:
///
/// - [connectionServiceProvider]: the app-wide service singleton over REAL
///   dependencies (DeviceStore on SecureStorageKv + SharedPrefsKv, the
///   gate-proven [connectNoDelay] dialer). Screens call commands on it
///   directly (`connectTo`, `feedPin`, `sendMove`, ...) — the hot move path
///   goes through the service, never through provider rebuilds.
/// - [connectionStatusProvider]: cheap immutable [ConnectionStatus] snapshots
///   ([ChipStatus] + [ReconnectState]) re-read off the service's `changes`
///   pings — the header chip and pairing sheet watch THIS, so UI rebuilds
///   only on state-affecting transitions (Phase-2 invariant).
///
/// Riverpod 3 unified [Notifier] only (per the locked stack rules — no
/// legacy v2 notifier patterns).
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../store/device_store.dart';
import 'beacon_listener.dart';
import 'connection_service.dart';
import 'reconnect_fsm.dart';

/// The app-wide [BeaconListener] — **the only one that may exist**.
///
/// This provider is a pure factory: it CONSTRUCTS the listener and registers
/// its teardown, and starts nothing. It is the single owner of both — no
/// consumer calls `stop()`, and disposal happens once, with the ProviderScope.
///
/// [BeaconListener.start] is idempotent BY CONTRACT, so any consumer that
/// needs beacons flowing may call it (the app-start binding does; the device
/// list does too, so it still works under an entry point that never ran the
/// binding). Calling it twice costs nothing.
///
/// **A second instance is forbidden.** `MainActivity.kt` creates ONE native
/// `WifiManager.MulticastLock` and calls `setReferenceCounted(false)`, so two
/// Dart [MulticastLock] clients share one un-refcounted native lock: whichever
/// listener stops FIRST drops the lock for the one still running. Construct
/// beacon listeners here and nowhere else.
final beaconListenerProvider = Provider<BeaconListener>((ref) {
  final listener = BeaconListener();
  ref.onDispose(() => unawaited(listener.stop()));
  return listener;
});

/// The app-wide [ConnectionService] over real storage + the TCP_NODELAY
/// dialer. Disposed with the ProviderScope (cancels subscriptions, closes
/// any live channel).
final connectionServiceProvider = Provider<ConnectionService>((ref) {
  final service = ConnectionService(
    store: DeviceStore(
      secure: SecureStorageKv(),
      prefs: SharedPrefsKv(),
    ),
  );
  ref.onDispose(service.dispose);
  return service;
});

/// Hands the app-scope beacon stream to the [ConnectionService] and starts the
/// listener. Call ONCE from `initState` near the app root, exactly like
/// `bindHapticsCache` — this is the whole CONN-04 fix.
///
/// It exists because beacon attachment used to live in `DeviceListNotifier`,
/// which builds only when a screen watches the device list. A cold start that
/// landed on the hub therefore had no beacon stream, and the D-06 short-circuit
/// (`ReconnectFsm.beaconSighted`, which acts only in [ReconnectState.backoff])
/// could never fire — so a PC that changed IP was unreachable until the user
/// happened to open Settings.
///
/// A bind failure is swallowed: it is retryable OEM/port noise (the same
/// posture the device list has always used) and must NEVER crash the launch
/// path.
void bindBeacons(WidgetRef ref) {
  final listener = ref.read(beaconListenerProvider);
  ref.read(connectionServiceProvider).attachBeacons(listener.stream);
  unawaited(listener.start().catchError((Object _) {}));
}

/// Immutable UI snapshot of the connection lifecycle.
///
/// Value-equal so [Notifier] state assignment skips no-op notifications
/// (changes pings that don't alter the visible status cost no rebuild).
class ConnectionStatus {
  /// Header-chip mapping (authed / in-motion / disconnected).
  final ChipStatus chip;

  /// The underlying lifecycle state (pairing sheet + screens branch on it).
  final ReconnectState fsmState;

  /// Creates a snapshot.
  const ConnectionStatus({required this.chip, required this.fsmState});

  @override
  bool operator ==(Object other) =>
      other is ConnectionStatus &&
      other.chip == chip &&
      other.fsmState == fsmState;

  @override
  int get hashCode => Object.hash(chip, fsmState);
}

/// Re-snapshots [ConnectionStatus] on every service `changes` ping.
class ConnectionStatusNotifier extends Notifier<ConnectionStatus> {
  StreamSubscription<void>? _sub;

  @override
  ConnectionStatus build() {
    final service = ref.watch(connectionServiceProvider);
    _sub?.cancel();
    _sub = service.changes.listen((_) => state = _snapshot(service));
    ref.onDispose(() {
      _sub?.cancel();
      _sub = null;
    });
    return _snapshot(service);
  }

  static ConnectionStatus _snapshot(ConnectionService service) =>
      ConnectionStatus(chip: service.chipStatus, fsmState: service.fsmState);
}

/// The status snapshot the header chip (03-07) and pairing sheet watch.
final connectionStatusProvider =
    NotifierProvider<ConnectionStatusNotifier, ConnectionStatus>(
  ConnectionStatusNotifier.new,
);
