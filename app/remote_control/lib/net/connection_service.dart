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

/// The last server-pushed volume state (D-03 `vol.changed`). Value-equal so
/// the volume Notifier suppresses no-op rebuilds on identical pushes (mirrors
/// [ChipStatus]/ConnectionStatus discipline).
class VolumeSnapshot {
  /// Absolute volume 0..100.
  final int value;

  /// Server-authoritative mute state.
  final bool muted;

  /// Creates a snapshot.
  const VolumeSnapshot({required this.value, required this.muted});

  @override
  bool operator ==(Object other) =>
      other is VolumeSnapshot && other.value == value && other.muted == muted;

  @override
  int get hashCode => Object.hash(value, muted);
}

/// The last server-pushed window list (APPS-03 `apps.changed` / `apps.list`
/// reply). Value-equal over element equality so the apps Notifier suppresses
/// no-op rebuilds on identical pushes (mirrors [VolumeSnapshot] discipline).
class AppsSnapshot {
  /// The window list in server Z-order (no client sort — D-07).
  final List<WindowInfo> windows;

  /// Creates a snapshot over [windows].
  const AppsSnapshot(this.windows);

  @override
  bool operator ==(Object other) {
    if (other is! AppsSnapshot) return false;
    if (other.windows.length != windows.length) return false;
    for (var i = 0; i < windows.length; i++) {
      if (other.windows[i] != windows[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll(windows);
}

/// The last server-pushed browser tab state (BROW-01 `tabs.changed` /
/// `tabs.list` reply, proto 1.4; groups proto 1.5, quick 260716-sme).
/// Value-equal over element equality so the tabs Notifier suppresses no-op
/// rebuilds on identical pushes (mirrors [AppsSnapshot] discipline —
/// hand-rolled element-wise ==, 06-03 no-package:collection rule).
class TabsSnapshot {
  /// Whether the Tab Bridge extension is connected on the PC —
  /// `false` renders the install hint.
  final bool connected;

  /// The tab list in extension order (no client sort).
  final List<TabInfo> tabs;

  /// The tab groups (proto 1.5) — empty when the server sent none (or is a
  /// 1.4 server without the field).
  final List<GroupInfo> groups;

  /// Creates a snapshot.
  const TabsSnapshot({
    required this.connected,
    required this.tabs,
    required this.groups,
  });

  @override
  bool operator ==(Object other) {
    if (other is! TabsSnapshot) return false;
    if (other.connected != connected) return false;
    if (other.tabs.length != tabs.length) return false;
    for (var i = 0; i < tabs.length; i++) {
      if (other.tabs[i] != tabs[i]) return false;
    }
    if (other.groups.length != groups.length) return false;
    for (var i = 0; i < groups.length; i++) {
      if (other.groups[i] != groups[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode =>
      Object.hash(connected, Object.hashAll(tabs), Object.hashAll(groups));
}

/// The last server-pushed bookmark tree (BROW `bm.changed` / `bm.list` reply,
/// protoVersion 1.6). Value-equal over element equality so the bookmarks
/// Notifier suppresses no-op rebuilds on identical pushes (mirrors
/// [TabsSnapshot] discipline — hand-rolled element-wise ==, 06-03
/// no-package:collection rule).
///
/// [connected] `false` renders the SHARED install hint — the exact same card
/// and copy the Tabs segment shows, not a bookmarks-specific variant.
class BookmarksSnapshot {
  /// Whether the Tab Bridge extension is connected on the PC — `false`
  /// renders the shared install hint.
  final bool connected;

  /// The flat, breadth-first node list in wire order (no client sort here —
  /// the folders-first ordering is the store's job). Root `"0"` is never
  /// shipped; its children carry `parentId: "0"` (D-08).
  final List<BmNode> nodes;

  /// Snapshot-level budget truncation: nodes were dropped from the tail of
  /// the whole tree. Distinct from [BmNode.truncated], which means one
  /// folder's children were dropped.
  final bool truncated;

  /// Creates a snapshot.
  const BookmarksSnapshot({
    required this.connected,
    required this.nodes,
    required this.truncated,
  });

  @override
  bool operator ==(Object other) {
    if (other is! BookmarksSnapshot) return false;
    if (other.connected != connected) return false;
    if (other.truncated != truncated) return false;
    if (other.nodes.length != nodes.length) return false;
    for (var i = 0; i < nodes.length; i++) {
      if (other.nodes[i] != nodes[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(connected, truncated, Object.hashAll(nodes));
}

/// The last server-pushed clipboard state (D-03 `clip.changed`). Value-equal so
/// the clipboard Notifier suppresses no-op rebuilds on identical pushes
/// (mirrors [VolumeSnapshot] discipline). Distinct from the fetch reply below:
/// this follows the live auto-sync push, the reply follows an explicit
/// `clip.get`.
class ClipSnapshot {
  /// The pushed clipboard text.
  final String text;

  /// Creates a snapshot over [text].
  const ClipSnapshot(this.text);

  @override
  bool operator ==(Object other) =>
      other is ClipSnapshot && other.text == text;

  @override
  int get hashCode => text.hashCode;
}

/// The last server-pushed UIPI advisory (SRV-05/D-07 `input.blocked`,
/// proto 1.3). Value-equal over BOTH [reason] and [at] — unlike the other
/// snapshots, a repeat transition with the SAME reason must still notify the
/// banner as a fresh event (e.g. the elevated window stays foreground and a
/// second injection attempt is dropped again), so equality intentionally
/// includes the timestamp rather than deduping on [reason] alone.
class InputBlockedSnapshot {
  /// Fixed-vocabulary block reason (e.g. `"elevated"`), never a window
  /// title/exe/PID (T-07-18).
  final String reason;

  /// When this transition was observed — lets the banner tell a fresh push
  /// apart from an unrelated `changes` ping.
  final DateTime at;

  /// Creates a snapshot.
  const InputBlockedSnapshot({required this.reason, required this.at});

  @override
  bool operator ==(Object other) =>
      other is InputBlockedSnapshot && other.reason == reason && other.at == at;

  @override
  int get hashCode => Object.hash(reason, at);
}

/// The `err` code a server that predates protoVersion 1.8 answers an
/// `update.*` frame with (SPEC section 10: an unknown message type is refused
/// and the session SURVIVES). Seeing it in reply to an update check is the
/// only way the phone can learn the PC is too old to update itself (D-13).
const String kUnknownTypeErrCode = 'unknownType';

/// The last `update.status` reply (protoVersion 1.8, D-09), projected into a
/// value-equal snapshot so the update store suppresses no-op rebuilds on
/// identical replies (mirrors [VolumeSnapshot] discipline).
///
/// A projection rather than the raw [UpdateStatusMsg] because [RemoteMessage]
/// has no value equality: two identical replies would otherwise compare
/// unequal and rebuild three rows for no change.
class UpdateStatusSnapshot {
  /// Version of the running server, verbatim (D-05 — the server reads its own
  /// `CARGO_PKG_VERSION`, it is never configured).
  final String serverVersion;

  /// Whether the browser extension is currently connected to the server.
  final bool extConnected;

  /// Version of the connected extension; null when it has never connected.
  final String? extVersion;

  /// Outcome of the PREVIOUS update attempt (D-12), or null when there is no
  /// marker — the normal case, never an error.
  final LastUpdate? lastUpdate;

  /// Creates a snapshot.
  const UpdateStatusSnapshot({
    required this.serverVersion,
    required this.extConnected,
    this.extVersion,
    this.lastUpdate,
  });

  /// Projects an `update.status` frame.
  factory UpdateStatusSnapshot.fromMessage(UpdateStatusMsg msg) =>
      UpdateStatusSnapshot(
        serverVersion: msg.serverVersion,
        extConnected: msg.extConnected,
        extVersion: msg.extVersion,
        lastUpdate: msg.lastUpdate,
      );

  @override
  bool operator ==(Object other) =>
      other is UpdateStatusSnapshot &&
      other.serverVersion == serverVersion &&
      other.extConnected == extConnected &&
      other.extVersion == extVersion &&
      other.lastUpdate == lastUpdate;

  @override
  int get hashCode =>
      Object.hash(serverVersion, extConnected, extVersion, lastUpdate);
}

/// The last `update.progress` push (protoVersion 1.8, D-10), value-equal.
///
/// The server throttles progress to about one percent or 250ms; value
/// equality is the second half of that guard — an unchanged tick that does
/// arrive rebuilds nothing (T-12-49).
class UpdateProgressSnapshot {
  /// Closed-vocabulary stage name (D-10).
  final String stage;

  /// Download percentage; present on `downloading` only.
  final int? pct;

  /// Version being installed, when there is one.
  final String? version;

  /// Closed-vocabulary failure reason (D-11); present on `failed`.
  final String? error;

  /// Creates a snapshot.
  const UpdateProgressSnapshot({
    required this.stage,
    this.pct,
    this.version,
    this.error,
  });

  /// Projects an `update.progress` frame.
  factory UpdateProgressSnapshot.fromMessage(UpdateProgressMsg msg) =>
      UpdateProgressSnapshot(
        stage: msg.stage,
        pct: msg.pct,
        version: msg.version,
        error: msg.error,
      );

  @override
  bool operator ==(Object other) =>
      other is UpdateProgressSnapshot &&
      other.stage == stage &&
      other.pct == pct &&
      other.version == version &&
      other.error == error;

  @override
  int get hashCode => Object.hash(stage, pct, version, error);
}

/// Everything this session has learned about updates: the last
/// `update.status` reply, the last `update.progress` push, and whether this
/// server refused `update.check` as an unknown type (D-13).
///
/// **Session-scoped by design.** It is cleared with the channel, so a
/// `serverVersion` can never outlive the session that reported it — a stale
/// one would let the Updates screen claim a PC is up to date after the user
/// switched to a different PC.
class UpdateSnapshot {
  /// The last `update.status` reply, or null before the first one.
  final UpdateStatusSnapshot? status;

  /// The last `update.progress` push, or null when none has arrived.
  final UpdateProgressSnapshot? progress;

  /// True once this server answered an outstanding update check with
  /// `err {code: "unknownType"}` — it predates protoVersion 1.8 (D-13).
  final bool serverTooOld;

  /// Creates a snapshot.
  const UpdateSnapshot({
    this.status,
    this.progress,
    this.serverTooOld = false,
  });

  /// The nothing-known state: what every session starts and ends on.
  static const UpdateSnapshot empty = UpdateSnapshot();

  /// This snapshot with [status] replaced (and the too-old flag cleared — a
  /// server that answers `update.status` is by definition new enough).
  UpdateSnapshot withStatus(UpdateStatusSnapshot value) =>
      UpdateSnapshot(status: value, progress: progress);

  /// This snapshot with [progress] replaced.
  UpdateSnapshot withProgress(UpdateProgressSnapshot value) =>
      UpdateSnapshot(status: status, progress: value, serverTooOld: serverTooOld);

  @override
  bool operator ==(Object other) =>
      other is UpdateSnapshot &&
      other.status == status &&
      other.progress == progress &&
      other.serverTooOld == serverTooOld;

  @override
  int get hashCode => Object.hash(status, progress, serverTooOld);
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
  VolumeSnapshot? _volumeSnapshot;
  AppsSnapshot? _appsSnapshot;
  TabsSnapshot? _tabsSnapshot;
  BookmarksSnapshot? _bookmarksSnapshot;
  ClipSnapshot? _clipSnapshot;
  String? _clipFetchReply;
  ErrMsg? _lastError;
  InputBlockedSnapshot? _inputBlocked;
  UpdateSnapshot _updateSnapshot = UpdateSnapshot.empty;

  /// Whether an `update.check` sent on THIS channel is still unanswered.
  ///
  /// The protocol carries no request ids, so there is no correlation
  /// mechanism to bind an `err` to the send that provoked it. This flag is the
  /// narrowest correlation available: an `unknownType` refusal is read as "too
  /// old to update itself" ONLY while a check is outstanding. Every other
  /// `unknownType` (a future message family this build sends and this server
  /// does not know) leaves the update snapshot alone.
  bool _updateCheckOutstanding = false;

  /// Liveness generation: bumping it invalidates any in-flight tick chain
  /// (the schedule seam has no cancel — stale ticks no-op on a gen mismatch).
  int _livenessGen = 0;

  /// Backoff generation: the schedule seam has no cancel handle, so a scheduled
  /// backoff timer captures this value and no-ops if it changed by fire time.
  /// Bumped on every dial, so a short-circuit (Retry now / beacon / resume) out
  /// of backoff cannot let a stale timer fire a premature redial (WR-01).
  int _backoffGen = 0;

  /// Dial generation: distinguishes dial EPISODES, not merely FSM state
  /// (WR-02). Bumped at the top of every [_dial]; a dial whose `_connect`
  /// await resolves AFTER a newer dial started sees a mismatch and bails
  /// (closing its own socket) instead of installing a channel + HandshakeDriver
  /// bound to a superseded target. The bare `_fsm.state == connecting` check
  /// cannot catch this — two overlapping dials are both in `connecting`.
  int _dialGen = 0;

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

  /// The last server-pushed volume state (D-03), or null before the first
  /// `vol.changed`. The volume store reads this off a [changes] ping.
  VolumeSnapshot? get volumeSnapshot => _volumeSnapshot;

  /// The last server-pushed window list (APPS-03 `apps.changed` / `apps.list`
  /// reply), or null before the first push. The apps store reads this off a
  /// [changes] ping.
  AppsSnapshot? get appsSnapshot => _appsSnapshot;

  /// The last server-pushed browser tab state (BROW-01 `tabs.changed` /
  /// `tabs.list` reply), or null before the first push. The tabs store reads
  /// this off a [changes] ping.
  TabsSnapshot? get tabsSnapshot => _tabsSnapshot;

  /// The last server-pushed bookmark tree (BROW `bm.changed` / `bm.list`
  /// reply, protoVersion 1.6), or null before the first push. The bookmarks
  /// store reads this off a [changes] ping.
  BookmarksSnapshot? get bookmarksSnapshot => _bookmarksSnapshot;

  /// The last server-pushed clipboard state (D-03 `clip.changed`), or null
  /// before the first push. The clipboard store reads this off a [changes]
  /// ping. Distinct from [clipFetchReply] — this is the live auto-sync push.
  ClipSnapshot? get clipSnapshot => _clipSnapshot;

  /// The last server-pushed UIPI advisory (SRV-05/D-07 `input.blocked`), or
  /// null before the first push. Transient — the UipiBanner widget reads this
  /// off a [changes] ping and auto-dismisses on its own timer; this service
  /// never clears it on a timeout (that's a UI concern, not connection state).
  InputBlockedSnapshot? get inputBlockedSnapshot => _inputBlocked;

  /// The last `clip.get` reply text (the server answers with a `clip.set`
  /// frame), or null before any Fetch. Kept SEPARATE from [clipSnapshot] so an
  /// explicit Fetch is never confused with an auto-sync push. Each reply frame
  /// decodes to a fresh String instance, so the clipboard store identity-tracks
  /// this to know a NEW reply landed (vs a stale, unrelated `changes` ping).
  String? get clipFetchReply => _clipFetchReply;

  /// Everything this session knows about updates (protoVersion 1.8): the last
  /// `update.status` reply, the last `update.progress` push, and the
  /// server-too-old flag. Never null — [UpdateSnapshot.empty] is the
  /// nothing-known state. The update store reads this off a [changes] ping.
  UpdateSnapshot get updateSnapshot => _updateSnapshot;

  /// Consecutive transport-failure count from the reconnect FSM (0 while
  /// authed). D-25 reads it INSTEAD of starting a timer: after a PC update the
  /// socket drops, the existing FSM rides it out, and a high attempt count is
  /// what "the PC never came back" looks like without a second reconnect path
  /// (D-17).
  int get reconnectAttempt => _fsm.attempt;

  /// The last `err` frame the server sent (windowGone / launchFailed etc.),
  /// or null. Screens surface it as a transient toast off a [changes] ping.
  ErrMsg? get lastError => _lastError;

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

  /// Hot path: volatile scroll frame (PAD-03). Identical policy shape to
  /// [sendMove]: 0x02 binary, dropped (never queued) unless authed — queued
  /// deltas teleport-scroll on reconnect, same rule as moves. Scroll frames
  /// ride the interleaved-ping cadence exactly like moves.
  void sendScroll(double dx, double dy) {
    if (!_policy.shouldSendVolatile()) return;
    _sender?.sendScroll(dx, dy);
    _probe?.onMove();
  }

  /// Hot path: volatile zoom frame (pinch, SPEC section 9 opcode 0x03). The
  /// third volatile binary class, with the identical policy shape to
  /// [sendMove]/[sendScroll]: dropped, never queued, unless authed — a queued
  /// zoom would fire a burst of zoom steps on reconnect, the same teleport
  /// failure queued moves and scrolls have. `dx` is reserved — pass 0.0.
  void sendZoom(double dx, double dy) {
    if (!_policy.shouldSendVolatile()) return;
    _sender?.sendZoom(dx, dy);
    _probe?.onMove();
  }

  /// Reliable-class message: sent immediately when authed, queued (bounded,
  /// FIFO, ≤10) during blips and flushed on auth (design spec §8).
  void sendReliable(RemoteMessage msg) {
    _policy.enqueueOrSendReliable(encodeMessage(msg), _addToSink);
  }

  /// Asks the PC what it and the extension are running (`update.check`, D-09).
  ///
  /// The payload is empty — everything the answer contains is resolved
  /// server-side. Rides the existing reliable path, so a check tapped during a
  /// blip flushes on reauth instead of being lost.
  void sendUpdateCheck() {
    _updateCheckOutstanding = true;
    sendReliable(const UpdateCheckMsg());
  }

  /// Tells the PC to install [target] (`update.apply`, D-14).
  ///
  /// **One `String` parameter, and there will never be a second.** The server
  /// resolves the asset URL and its sha256 itself from a compiled-in repo
  /// constant and refuses anything supplied, implied or influenced by the
  /// wire; a wire-supplied locator would turn a paired phone into arbitrary
  /// code execution on the PC (T-12-01). There is deliberately no overload and
  /// no options object, so a future caller has nowhere to put one.
  void sendUpdateApply(String target) {
    sendReliable(UpdateApplyMsg(target: target));
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
    final gen = ++_dialGen; // WR-02: this dial episode; supersedes older dials
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
    // WR-03: keystore reads are slow and CAN THROW after an OS update
    // (CLAUDE.md). An uncaught throw here escapes the `unawaited(_applyStep())`
    // callers (retryNow / onAppResumed / beacon sightings) as a zone error and
    // strands the FSM in `connecting` with no `transportFailed` — the reconnect
    // loop stalls permanently. Degrade a lost token to null: the PIN path is
    // the correct fallback.
    String? token;
    try {
      token = await _store.tokenFor(target.key);
    } catch (_) {
      token = null;
    }

    final WebSocketChannel channel;
    try {
      channel =
          await _connect(Uri.parse('ws://${target.host}:${target.port}'));
    } catch (e) {
      _lastDialError = e;
      await _applyStep(_fsm.transportFailed());
      return;
    }

    if (gen != _dialGen || _fsm.state != ReconnectState.connecting) {
      // A newer dial episode started (WR-02), or the world moved on during the
      // await (e.g. disconnect) — stale dial: close our socket and bail rather
      // than install a channel/driver bound to a superseded target or leak the
      // subscription by overwriting _channel/_sub.
      unawaited(channel.sink.close());
      return;
    }

    _channel = channel;
    // From here to auth is the ONLY window a reliable frame may queue in
    // (260812-uge); with no socket installed they are dropped instead.
    _policy.channelUp = true;
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
    if (msg is VolChangedMsg) {
      // D-03 server volume push: park the value-equal snapshot and ping the
      // volume store via changes. S→C only — never routed to the driver, no
      // payload logged (SPEC §12).
      _volumeSnapshot = VolumeSnapshot(value: msg.value, muted: msg.muted);
      _notify();
      return;
    }
    if (msg is AppsChangedMsg) {
      // APPS-03 live window list push: park the value-equal snapshot and ping
      // the apps store. S→C only — never routed to the driver, no payload
      // logged (SPEC §12).
      _appsSnapshot = AppsSnapshot(msg.windows);
      _notify();
      return;
    }
    if (msg is AppsListMsg) {
      // apps.list reply (the screen-open prime): park the same snapshot. A
      // request has no `windows`; a reply always does — default to empty.
      _appsSnapshot = AppsSnapshot(msg.windows ?? const []);
      _notify();
      return;
    }
    if (msg is TabsChangedMsg) {
      // BROW-01 live tab push: park the value-equal snapshot and ping the
      // tabs store. S→C only — never routed to the driver, and NO payload
      // logging anywhere (SPEC §12 — tab titles are browsing data).
      _tabsSnapshot = TabsSnapshot(
        connected: msg.connected,
        tabs: msg.tabs,
        groups: msg.groups ?? const [],
      );
      _notify();
      return;
    }
    if (msg is TabsListMsg) {
      // tabs.list reply (the Browser-screen-open prime): park the same
      // snapshot. A request has neither field; a reply always carries both —
      // default to the never-connected hint shape. No payload logging.
      _tabsSnapshot = TabsSnapshot(
        connected: msg.connected ?? false,
        tabs: msg.tabs ?? const [],
        groups: msg.groups ?? const [],
      );
      _notify();
      return;
    }
    if (msg is BmChangedMsg) {
      // BROW live bookmark-tree push (proto 1.6): park the value-equal
      // snapshot and ping the bookmarks store. S→C only — never routed to the
      // driver, and NO payload logging anywhere (SPEC §12 — bookmark titles
      // are browsing data).
      _bookmarksSnapshot = BookmarksSnapshot(
        connected: msg.connected,
        nodes: msg.nodes,
        truncated: msg.truncated ?? false,
      );
      _notify();
      return;
    }
    if (msg is BmListMsg) {
      // bm.list reply (the Bookmarks-segment-open prime, D-03): park the same
      // snapshot. A request carries neither field; a reply always carries
      // both — default to the never-connected hint shape. NO payload logging
      // anywhere (SPEC §12 — bookmark titles are browsing data).
      _bookmarksSnapshot = BookmarksSnapshot(
        connected: msg.connected ?? false,
        nodes: msg.nodes ?? const [],
        truncated: msg.truncated ?? false,
      );
      _notify();
      return;
    }
    if (msg is UpdateStatusMsg) {
      // The update.check reply (protoVersion 1.8, D-09): park the value-equal
      // projection and ping the update store. Answering at all proves the
      // server is new enough, so this also clears the too-old flag. S→C only,
      // no payload logged (three public version strings, but SPEC §12 is a
      // rule about payloads, not about which payloads look harmless).
      _updateCheckOutstanding = false;
      _updateSnapshot =
          _updateSnapshot.withStatus(UpdateStatusSnapshot.fromMessage(msg));
      _notify();
      return;
    }
    if (msg is UpdateProgressMsg) {
      // Live apply progress push (D-10). Parked verbatim: deciding which
      // stages and which D-11 error codes may reach the screen is the update
      // store's job (busy is swallowed, downgrade degrades) — the service
      // records what the wire said and nothing more.
      _updateSnapshot =
          _updateSnapshot.withProgress(UpdateProgressSnapshot.fromMessage(msg));
      _notify();
      return;
    }
    if (msg is ClipChangedMsg) {
      // D-03 live clipboard push: park the value-equal snapshot and ping the
      // clipboard store. S→C only — never routed to the driver, no payload
      // logged (SPEC §12, T-06-09).
      _clipSnapshot = ClipSnapshot(msg.text);
      _notify();
      return;
    }
    if (msg is InputBlockedMsg) {
      // SRV-05/D-07 UIPI advisory push: park a transient snapshot and ping
      // the banner via changes. S→C only — never routed to the driver, no
      // payload logged (the reason vocabulary carries no window title/exe,
      // T-07-18).
      _inputBlocked = InputBlockedSnapshot(reason: msg.reason, at: DateTime.now());
      _notify();
      return;
    }
    if (msg is ClipSetMsg) {
      // The clip.get reply arrives as a clip.set frame (router replies
      // Msg::ClipSet{text}). Park it in the DISTINCT fetch-reply slot — kept
      // separate from the live push so an explicit Fetch is not confused with
      // an auto-sync push. S→C only, no payload logged (T-06-09).
      _clipFetchReply = msg.text;
      _notify();
      return;
    }
    if (msg is ErrMsg) {
      // err{windowGone|launchFailed|...}: park for toast surfacing. The
      // code/msg are operator-facing prose and carry no HWND/path (T-06-14).
      // NOT returned early — a handshake-phase err{versionMismatch} must still
      // reach the driver below (handshake_fsm terminal-fail path).
      _lastError = msg;
      if (msg.code == kUnknownTypeErrCode && _updateCheckOutstanding) {
        // SPEC §10: a server that predates protoVersion 1.8 refuses the frame
        // and KEEPS the session. That refusal is the only signal the phone
        // gets, so it is recorded here (D-13) and the Updates screen renders
        // both PC-side rows as "needs one more update by hand".
        _updateCheckOutstanding = false;
        _updateSnapshot = const UpdateSnapshot(serverTooOld: true);
      }
      _notify();
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
        // WR-03: _persistNewPairing does keystore WRITES (saveToken) that can
        // throw after an OS update (CLAUDE.md). Swallow the failure so it never
        // becomes an uncaught async error; the only cost is that this pairing
        // isn't remembered and the user can re-pair. (Surfacing a "couldn't
        // remember this PC" hint to the UI is left for a follow-up.)
        unawaited(_persistNewPairing(target, token).catchError((Object _) {}));
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
    // Volatile gating drops with the channel, and so does the reliable queue
    // (260812-uge — this REVERSES the original "keep it so a blip is
    // lossless" rule). Clearing `channelUp` is the load-bearing half: it makes
    // every reliable frame sent from here until the next socket a DROP rather
    // than a deferred delivery. The clear() is belt and braces for anything a
    // half-finished handshake left behind, so it can never outlive its socket.
    //
    // What this costs, knowingly: a sub-second blip is no longer lossless.
    // What it buys: nothing typed, clicked or confirmed during an outage is
    // replayed minutes later into whatever window is focused at re-auth —
    // including a `power` + `confirm` pair, which this queue carried too.
    _policy
      ..authed = false
      ..channelUp = false
      ..clear();
    // The update snapshot is session-scoped and dies WITH the session — unlike
    // the volume/apps/tabs snapshots, which describe a PC that is still the
    // same PC after a blip. A stale serverVersion outliving its session is the
    // one way the Updates screen could claim a PC is up to date when the phone
    // has since been pointed at a different one (or the PC has just installed
    // the update it is being asked about). The re-check on reconnect is what
    // repopulates it, and that re-check is also how a PC update is confirmed
    // (D-17) — so clearing here is load-bearing, not hygiene.
    _updateSnapshot = UpdateSnapshot.empty;
    _updateCheckOutstanding = false;
  }

  void _notify() {
    if (!_changes.isClosed) {
      _changes.add(null);
    }
  }
}
