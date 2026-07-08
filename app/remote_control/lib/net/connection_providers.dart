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
import 'connection_service.dart';
import 'reconnect_fsm.dart';

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
