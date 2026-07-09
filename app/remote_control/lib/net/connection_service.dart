/// ConnectionService: the reconnect driver (CONN-03..CONN-06) + the
/// gate-proven TCP_NODELAY WebSocket construction (PAD-05 criterion 3).
///
/// TWO layers live here:
///
/// 1. **Construction** (Phase 2, kept verbatim): `web_socket_channel` exposes
///    no socket-option hook, and `dart:io` sockets default to Nagle ON — the
///    exact bug that produces 40-200ms cursor hitches on real WiFi. The fix:
///    an [HttpClient] whose `connectionFactory` sets
///    [SocketOption.tcpNoDelay] on the socket the WebSocket upgrade rides
///    over, passed as `customClient:` to [IOWebSocketChannel.connect].
///
/// 2. **Lifecycle** (Phase 3, this plan): [ConnectionService] executes the
///    pure `ReconnectFsm`'s effects with real IO — dialing via
///    [connectNoDelay], running one `HandshakeDriver` per attempt, persisting
///    tokens through `DeviceStore`, short-circuiting backoff on beacon
///    sightings, enforcing the RFC1918 dial guard ([isPrivateLanAddress] —
///    the code half of D-10's "LAN ranges only", since Android's
///    network-security-config XML cannot express IP ranges), and driving the
///    `LatencyProbe`'s idle-ping liveness (CONN-06).
///
/// Invariants carried from Phase 2: exactly ONE `channel.stream.listen`
/// (decode once, route handshake -> driver, pong -> probe); the hot move
/// path is a boolean gate + fire-and-forget send — it never rebuilds UI and
/// never pings [ConnectionService.changes]. Secrets discipline: the raw
/// token flows connect-time only (store -> HandshakeDriver ctor) — it is
/// never held on a service field, never logged, never on the wire
/// (challenge-response only, T-03-17/T-03-20).
library;

import 'dart:async';
import 'dart:io';

import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'package:remote_protocol/remote_protocol.dart';

import '../hud/latency_probe.dart';
import '../store/device_store.dart';
import '../trackpad/move_sender.dart';
import 'beacon.dart';
import 'handshake.dart';
import 'handshake_fsm.dart';
import 'reconnect_fsm.dart';
import 'send_policy.dart';

/// Sets TCP_NODELAY on a connected [socket] and returns the same socket.
///
/// This is the separately-callable unit-test seam: the connection factory
/// MUST route its socket through here so tests can prove the option is set
/// without opening a real connection.
Socket setTcpNoDelay(Socket socket) {
  socket.setOption(SocketOption.tcpNoDelay, true);
  return socket;
}

/// Wraps a [ConnectionTask] so its resolved socket has TCP_NODELAY set,
/// preserving the original cancel path (the WebSocket upgrade rides the
/// returned task's socket).
ConnectionTask<Socket> noDelayTask(ConnectionTask<Socket> task) {
  final Future<Socket> wrapped = task.socket.then(setTcpNoDelay);
  return ConnectionTask.fromSocket(wrapped, task.cancel);
}

/// [HttpClient.connectionFactory]-shaped callback: connects a plain TCP
/// socket to `uri` and applies TCP_NODELAY via [noDelayTask].
///
/// LAN-only `ws://` — no TLS branch (LAN-only binding is locked by spec);
/// proxies are ignored (no proxy on a LAN).
Future<ConnectionTask<Socket>> noDelayConnectionFactory(
  Uri uri,
  String? proxyHost,
  int? proxyPort,
) {
  return Socket.startConnect(uri.host, uri.port).then(noDelayTask);
}

/// Builds the [HttpClient] whose connections all carry TCP_NODELAY.
HttpClient buildNoDelayHttpClient() {
  return HttpClient()..connectionFactory = noDelayConnectionFactory;
}

/// Connects a WebSocket channel to [wsUri] over a TCP_NODELAY socket.
///
/// Phase 3 grows this into the full reconnect-FSM ConnectionService; the
/// construction path (customClient + connectionFactory) is permanent.
Future<IOWebSocketChannel> connectNoDelay(Uri wsUri) async {
  final channel = IOWebSocketChannel.connect(
    wsUri,
    customClient: buildNoDelayHttpClient(),
  );
  // Surface connect failures to the caller instead of only on the stream.
  await channel.ready;
  return channel;
}

/// The device name this client sends in `hello` frames.
const String kDefaultDeviceName = 'Remote Control (Android)';

/// Coarse header-chip status (D-04 / UI-SPEC mapping).
enum ChipStatus {
  /// Authed — the session is live.
  connected,

  /// Connecting, handshaking, or waiting out a backoff.
  reconnecting,

  /// Idle or needs pairing.
  disconnected,
}

/// True when [a] is an RFC1918 private IPv4 address or 169.254/16 link-local
/// (phone-hotspot cases). IPv4 only — everything else is refused.
///
/// This is the ENFORCEABLE half of D-10's "cleartext to LAN ranges only"
/// (T-03-16): Android's network-security-config XML cannot express IP
/// ranges/CIDR, so the XML keeps base-config cleartext and THIS guard is the
/// real scoping — `ws://` dials to non-private addresses are refused in code
/// before any socket is opened (03-RESEARCH Pattern 5, verbatim).
bool isPrivateLanAddress(InternetAddress a) {
  if (a.type != InternetAddressType.IPv4) return false;
  final b = a.rawAddress;
  return b[0] == 10 ||
      (b[0] == 172 && b[1] >= 16 && b[1] <= 31) ||
      (b[0] == 192 && b[1] == 168) ||
      (b[0] == 169 && b[1] == 254); // link-local (phone hotspot cases)
}

/// The reconnect driver: composes `ReconnectFsm` (lifecycle policy),
/// `HandshakeDriver` (hello/pin/auth — one fresh driver per dial),
/// `DeviceStore` (token + metadata persistence), `SendPolicy`
/// (per-message-class gating), and `LatencyProbe` (header latency +
/// idle-ping liveness).
///
/// Every lifecycle event becomes an FSM input; every FSM effect is executed
/// here (Dial / StartBackoff / ClearToken / AuthStop / Close). The FSM stays
/// pure — timers, sockets, and storage all live on this side.
///
/// PIN retry model (verified against `session.rs`): the server leaves the
/// session open after `authFail`, but the client `HandshakeFsm` is terminal
/// on failure — so every PIN attempt is a FRESH dial (connect -> challenge ->
/// needPin), driven by the pairing sheet calling [connectTo] again.
///
/// All seams are constructor-injected for the fake-driven test suite:
/// [connect] (channel factory), [schedule] (one-shot timers), [nowMillis]
/// (clock), [random] (backoff jitter).
class ConnectionService {
  /// Idle-ping cadence while authed (CONN-06: ~2s; 3 missed pongs ≈ 6s dead).
  static const Duration _idlePingInterval = Duration(seconds: 2);

  final DeviceStore _store;
  final Future<WebSocketChannel> Function(Uri) _connect;
  final void Function(Duration, void Function()) _schedule;
  final int Function() _nowMillis;
  final ReconnectFsm _fsm;
  final SendPolicy _policy = SendPolicy();

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _sub;
  StreamSubscription<Beacon>? _beaconSub;
  HandshakeDriver? _driver;
  LatencyProbe? _probe;
  MoveSender? _sender;

  /// Whether the current dial started with a stored token (silent-reconnect
  /// path) — when false, an authed handshake is a NEW pairing to persist.
  bool _hadStoredToken = false;

  FailedEffect? _lastAuthFailure;
  Object? _lastDialError;

  /// Liveness generation: bumping it invalidates any in-flight tick chain
  /// (the schedule seam has no cancel — stale ticks no-op on a gen mismatch).
  int _livenessGen = 0;

  /// Backoff generation: the schedule seam has no cancel handle, so a scheduled
  /// backoff timer captures this value and no-ops if it changed by fire time.
  /// Bumped on every dial, so a short-circuit (Retry now / beacon / resume) out
  /// of backoff cannot let a stale timer fire a premature redial (WR-01).
  int _backoffGen = 0;

  final StreamController<void> _changes = StreamController<void>.broadcast();

  /// Creates the service.
  ///
  /// [connect] defaults to the gate-proven [connectNoDelay]; [schedule]
  /// defaults to one-shot [Timer]s; [nowMillis] to the system clock;
  /// [random] (0.0..1.0) seeds the FSM's backoff jitter.
  ConnectionService({
    required DeviceStore store,
    Future<WebSocketChannel> Function(Uri) connect = connectNoDelay,
    void Function(Duration, void Function())? schedule,
    int Function()? nowMillis,
    double Function()? random,
  })  : _store = store, // ignore: prefer_initializing_formals
        _connect = connect, // ignore: prefer_initializing_formals
        _schedule = schedule ?? _timerSchedule,
        _nowMillis = nowMillis ?? _systemNowMillis,
        _fsm = ReconnectFsm(random: random);

  static void _timerSchedule(Duration delay, void Function() fn) {
    Timer(delay, fn);
  }

  static int _systemNowMillis() => DateTime.now().millisecondsSinceEpoch;

  // -- Read surface (UI reads via [changes] + these snapshots) ---------------

  /// The current lifecycle state.
  ReconnectState get fsmState => _fsm.state;

  /// The in-flight handshake's status, or null when no channel is up.
  HandshakeStatus? get handshakeStatus => _driver?.status;

  /// The header-chip mapping: authed -> connected; connecting/handshaking/
  /// backoff -> reconnecting; idle/needPairing -> disconnected.
  ChipStatus get chipStatus {
    switch (_fsm.state) {
      case ReconnectState.authed:
        return ChipStatus.connected;
      case ReconnectState.connecting:
      case ReconnectState.handshaking:
      case ReconnectState.backoff:
        return ChipStatus.reconnecting;
      case ReconnectState.idle:
      case ReconnectState.needPairing:
        return ChipStatus.disconnected;
    }
  }

  /// Whether the session is live (move frames may flow).
  bool get isAuthed => _fsm.state == ReconnectState.authed;

  /// The per-connection latency/liveness probe, or null when disconnected.
  LatencyProbe? get probe => _probe;

  /// The current dial target, or null when idle.
  DeviceTarget? get target => _fsm.target;

  /// The last definitive auth failure (reason + extras), or null.
  FailedEffect? get lastAuthFailure => _lastAuthFailure;

  /// The needPairing copy ([kRevokedExplanation] for noPairing/badMac).
  String? get pairingExplanation => _fsm.explanation;

  /// The last dial error: guard refusal or connect exception, or null.
  Object? get lastDialError => _lastDialError;

  /// Pinged after every state-affecting transition; the hot move path NEVER
  /// pings it (UI reads snapshots off this via the providers).
  Stream<void> get changes => _changes.stream;

  // -- Commands ---------------------------------------------------------------

  /// Connects to [target] (fresh dial; resets failure bookkeeping). When a
  /// session is already live it is dropped first — switching PCs is a
  /// disconnect + dial, never two sockets.
  Future<void> connectTo(DeviceTarget target) async {
    _lastDialError = null;
    _lastAuthFailure = null;
    if (_fsm.state == ReconnectState.authed) {
      await _applyStep(_fsm.disconnectRequested());
    }
    await _applyStep(_fsm.connectRequested(target));
  }

  /// The user's "Retry now" affordance (D-04): short-circuits backoff.
  void retryNow() {
    unawaited(_applyStep(_fsm.retryNowPressed()));
  }

  /// App returned to the foreground (D-06): short-circuits backoff.
  void onAppResumed() {
    unawaited(_applyStep(_fsm.appResumed()));
  }

  /// Drops the connection and returns to idle — never a retry.
  void disconnect() {
    unawaited(_applyStep(_fsm.disconnectRequested()));
  }

  /// Feeds the user-entered PIN to the in-flight handshake (pairing sheet).
  void feedPin(String pin) {
    _driver?.feedPin(pin);
    _notify();
  }

  /// Hot path: volatile move frame. A plain boolean gate pre-auth (no
  /// allocation, nothing queued — queued deltas teleport the cursor), then
  /// fire-and-forget 9-byte binary + probe cadence tick.
  void sendMove(double dx, double dy) {
    if (!_policy.shouldSendVolatile()) return;
    _sender?.sendMove(dx, dy);
    _probe?.onMove();
  }

  /// Reliable-class message: sent immediately when authed, queued (bounded,
  /// FIFO, ≤10) during blips and flushed on auth (design spec §8).
  void sendReliable(RemoteMessage msg) {
    _policy.enqueueOrSendReliable(encodeMessage(msg), _addToSink);
  }

  /// Attaches the discovery beacon stream: a sighting of the CURRENT target's
  /// guid updates its last-known address and short-circuits backoff (D-06).
  /// Device-list merging is the store/UI's job, not the service's.
  void attachBeacons(Stream<Beacon> beacons) {
    _beaconSub?.cancel();
    _beaconSub = beacons.listen((beacon) {
      unawaited(_applyStep(
        _fsm.beaconSighted(beacon.guid, beacon.host, beacon.port),
      ));
    });
  }

  /// Releases everything (provider teardown).
  void dispose() {
    _beaconSub?.cancel();
    _beaconSub = null;
    _teardownChannel();
    _changes.close();
  }

  // -- FSM effect execution ---------------------------------------------------

  Future<void> _applyStep(ReconnectStep step) async {
    for (final effect in step.effects) {
      switch (effect) {
        case DialEffect(:final target):
          await _dial(target);
        case StartBackoffEffect(:final delay):
          final gen = _backoffGen;
          _schedule(delay, () {
            if (gen != _backoffGen) return; // superseded episode — ignore
            unawaited(_applyStep(_fsm.backoffElapsed()));
          });
        case ClearTokenEffect(:final deviceKey):
          await _store.deleteToken(deviceKey);
        case AuthStopEffect():
          _policy
            ..authed = false
            ..clear(); // auth-stop drops the queue: the target must re-pair
        case CloseEffect():
          _teardownChannel();
      }
    }
    _notify();
  }

  Future<void> _dial(DeviceTarget target) async {
    _backoffGen++; // a dial supersedes any pending backoff timer (WR-01)
    _teardownChannel(); // a fresh dial never rides an old socket (idempotent)

    final addr = InternetAddress.tryParse(target.host);
    if (addr == null || !isPrivateLanAddress(addr)) {
      // Guard refusal is a terminal user-input error, NOT a transport blip:
      // backoff-retrying a non-LAN address would hammer a public host
      // (T-03-16) — record the error and land in idle instead.
      _lastDialError = ArgumentError.value(
        target.host,
        'host',
        'refused: not a private LAN address (RFC1918/link-local only)',
      );
      await _applyStep(_fsm.disconnectRequested());
      return;
    }

    // Token read happens at dial time only; it flows straight into the
    // HandshakeDriver ctor and is never held on a service field (T-03-20).
    final token = await _store.tokenFor(target.key);

    final WebSocketChannel channel;
    try {
      channel =
          await _connect(Uri.parse('ws://${target.host}:${target.port}'));
    } catch (e) {
      _lastDialError = e;
      await _applyStep(_fsm.transportFailed());
      return;
    }

    if (_fsm.state != ReconnectState.connecting) {
      // The world moved on during the await (e.g. disconnect) — stale dial.
      unawaited(channel.sink.close());
      return;
    }

    _channel = channel;
    _sender = MoveSender(channel.sink);
    _hadStoredToken = token != null;
    _probe = LatencyProbe(
      nowMillis: _nowMillis,
      send: channel.sink.add,
      onDead: _onDeadConnection,
    );
    final driver = HandshakeDriver(channel, token: token);
    _driver = driver;
    await _applyStep(_fsm.socketConnected());

    // The SINGLE stream listener: decode each frame once, route pong ->
    // probe, handshake families -> driver (Phase-2 invariant, T-03-19).
    _sub = channel.stream.listen(
      _onFrame,
      onError: (Object _) => _onTransportLost(),
      onDone: _onTransportLost,
    );

    driver.start(kDefaultDeviceName);
    _notify();
  }

  void _onFrame(dynamic frame) {
    if (frame is! String) {
      return; // inbound binary is not part of the client surface — ignore
    }
    final RemoteMessage msg;
    try {
      msg = decodeText(frame).msg;
    } on FormatException {
      return; // total parse: malformed inbound frame is silently dropped
    }
    if (msg is PongMsg) {
      _probe?.onPong(msg);
      return;
    }
    final driver = _driver;
    if (driver == null) return;
    final before = driver.status;
    driver.onMessage(msg);
    final after = driver.status;
    if (after == before) return;
    switch (after) {
      case HandshakeStatus.authed:
        _onAuthed(driver);
      case HandshakeStatus.failed:
        _onAuthFailed(driver);
      case HandshakeStatus.connecting:
      case HandshakeStatus.needPin:
      case HandshakeStatus.authenticating:
        _notify(); // pairing sheet visibility etc.
    }
  }

  void _onAuthed(HandshakeDriver driver) {
    unawaited(_applyStep(_fsm.authedOk()));
    if (!_hadStoredToken) {
      // Newly paired (pairOk): persist token + metadata + last-device pointer
      // (D-01/D-07). Silent reconnects skip this — nothing changed.
      final token = driver.token;
      final target = _fsm.target;
      if (token != null && target != null) {
        unawaited(_persistNewPairing(target, token));
      }
    }
    _policy.authed = true;
    _policy.flushOnAuthed(_addToSink);
    _startLiveness();
    _notify();
  }

  Future<void> _persistNewPairing(DeviceTarget target, String token) async {
    await _store.saveToken(target.key, token);
    await _store.upsertDevice(DeviceMeta(
      key: target.key,
      name: target.name,
      host: target.host,
      port: target.port,
      lastConnectedAt: _nowMillis(),
    ));
    await _store.setLastDevice(target.key);
  }

  void _onAuthFailed(HandshakeDriver driver) {
    final failure = driver.failure;
    _lastAuthFailure = failure;
    if (failure == null) return;
    // D-05 auth-stop: the FSM decides ClearToken (revoked only) + AuthStop +
    // Close — never a retry for ANY auth reason.
    unawaited(_applyStep(_fsm.authRejected(
      failure.reason,
      attemptsRemaining: failure.attemptsRemaining,
      retryAfterSecs: failure.retryAfterSecs,
    )));
  }

  void _onTransportLost() {
    if (_channel == null) return; // already torn down deliberately
    _teardownChannel();
    unawaited(_applyStep(_fsm.transportFailed()));
  }

  void _onDeadConnection() {
    // 3 consecutive missed pongs (~6s): treat the socket as dead — close it
    // and feed the transport-failure input (backoff redial follows).
    _teardownChannel();
    unawaited(_applyStep(_fsm.transportFailed()));
  }

  // -- Liveness (CONN-06) -----------------------------------------------------

  void _startLiveness() {
    final gen = ++_livenessGen;
    void tick() {
      if (gen != _livenessGen) return; // superseded / torn down
      if (_fsm.state != ReconnectState.authed) return;
      _probe?.onIdleTick(); // may fire onDead -> teardown (gen bumps)
      if (gen != _livenessGen) return;
      _schedule(_idlePingInterval, tick);
    }

    _schedule(_idlePingInterval, tick);
  }

  void _stopLiveness() {
    _livenessGen++;
  }

  // -- Plumbing ---------------------------------------------------------------

  void _addToSink(Object frame) {
    _channel?.sink.add(frame);
  }

  void _teardownChannel() {
    _stopLiveness();
    _sub?.cancel();
    _sub = null;
    final channel = _channel;
    _channel = null;
    if (channel != null) {
      unawaited(channel.sink.close());
    }
    _driver = null;
    _sender = null;
    _probe?.reset();
    _probe = null;
    // Volatile gating drops with the channel; the reliable queue is KEPT so
    // frames sent during a blip flush after the redial auths.
    _policy.authed = false;
  }

  void _notify() {
    if (!_changes.isClosed) {
      _changes.add(null);
    }
  }
}
