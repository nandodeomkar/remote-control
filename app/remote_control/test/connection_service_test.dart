// Task 2 (TDD) — ConnectionService: the reconnect driver that turns 03-02
// FSM effects into real IO, proven entirely against fakes (no socket).
//
// Covers: pair flow persistence (CONN-02/03), silent challenge-response
// reconnect with the raw token never on the wire (CONN-03, T-03-17),
// auth-stop on revocation (D-05, T-03-18), drop -> backoff -> redial +
// resume/beacon short-circuits (CONN-04, D-06), the RFC1918 private-range
// dial guard (CONN-05, D-10, T-03-16), the per-message-class send policy,
// and idle-ping liveness -> dead-connection -> backoff (CONN-06).

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control/net/beacon.dart';
import 'package:remote_control/net/connection_service.dart';
import 'package:remote_control/net/handshake.dart';
import 'package:remote_control/net/reconnect_fsm.dart';
import 'package:remote_control/store/device_store.dart';
import 'package:remote_protocol/remote_protocol.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------

/// A [WebSocketChannel] fake: StreamController-backed inbound stream + a
/// recording sink. Everything else is satisfied via [noSuchMethod].
class FakeWsChannel implements WebSocketChannel {
  /// Feed inbound frames through this controller; closing it simulates a
  /// transport drop (stream onDone).
  final StreamController<dynamic> incoming = StreamController<dynamic>();

  final _RecordingWsSink _sink = _RecordingWsSink();

  @override
  Stream<dynamic> get stream => incoming.stream;

  @override
  WebSocketSink get sink => _sink;

  /// Every frame added to the sink, in order (String JSON or binary).
  List<Object?> get sent => _sink.added;

  /// Only the text frames (JSON protocol messages).
  List<String> get sentText => _sink.added.whereType<String>().toList();

  /// Decoded protocol messages from the text frames, in send order.
  List<RemoteMessage> get sentMessages =>
      sentText.map((f) => decodeText(f).msg).toList();

  /// Whether the service closed the sink.
  bool get closed => _sink.closed;

  /// Encodes [msg] and feeds it as one inbound text frame.
  void feed(RemoteMessage msg) => incoming.add(encodeMessage(msg));

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _RecordingWsSink implements WebSocketSink {
  final List<Object?> added = <Object?>[];
  bool closed = false;

  @override
  void add(dynamic data) => added.add(data);

  @override
  Future<dynamic> close([int? closeCode, String? closeReason]) async {
    closed = true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class MemSecureKv implements SecureKv {
  final Map<String, String> map = <String, String>{};

  @override
  Future<String?> read(String key) async => map[key];

  @override
  Future<void> write(String key, String value) async => map[key] = value;

  @override
  Future<void> delete(String key) async => map.remove(key);
}

class MemPrefsKv implements PrefsKv {
  final Map<String, String> map = <String, String>{};

  @override
  Future<String?> getString(String key) async => map[key];

  @override
  Future<void> setString(String key, String value) async => map[key] = value;
}

/// A real [DeviceStore] over in-memory seams, recording mutating calls.
class RecordingStore extends DeviceStore {
  final List<String> calls = <String>[];
  final MemSecureKv secureKv;
  final MemPrefsKv prefsKv;

  RecordingStore._(this.secureKv, this.prefsKv)
      : super(secure: secureKv, prefs: prefsKv);

  factory RecordingStore() => RecordingStore._(MemSecureKv(), MemPrefsKv());

  /// Preload a token WITHOUT polluting the call log (test arrangement).
  void preloadToken(String deviceKey, String token) =>
      secureKv.map['token.$deviceKey'] = token;

  @override
  Future<void> saveToken(String deviceKey, String token) {
    calls.add('saveToken:$deviceKey');
    return super.saveToken(deviceKey, token);
  }

  @override
  Future<void> deleteToken(String deviceKey) {
    calls.add('deleteToken:$deviceKey');
    return super.deleteToken(deviceKey);
  }

  @override
  Future<void> upsertDevice(DeviceMeta meta) {
    calls.add('upsertDevice:${meta.key}');
    return super.upsertDevice(meta);
  }

  @override
  Future<void> setLastDevice(String deviceKey) {
    calls.add('setLastDevice:$deviceKey');
    return super.setLastDevice(deviceKey);
  }
}

/// Wires a [ConnectionService] to a fake connect closure, captured schedule
/// callbacks, a fixed clock, and a fixed jitter source (factor exactly 1.0).
class Harness {
  final RecordingStore store = RecordingStore();
  final List<Uri> dialed = <Uri>[];
  final List<FakeWsChannel> channels = <FakeWsChannel>[];
  final List<(Duration, void Function())> scheduled =
      <(Duration, void Function())>[];
  int now = 0;

  /// When set, the next connect attempt throws this instead of connecting.
  Object? nextDialError;

  late final ConnectionService service;

  Harness() {
    service = ConnectionService(
      store: store,
      connect: (uri) async {
        dialed.add(uri);
        final err = nextDialError;
        if (err != null) {
          nextDialError = null;
          throw err;
        }
        final ch = FakeWsChannel();
        channels.add(ch);
        return ch;
      },
      schedule: (delay, fn) => scheduled.add((delay, fn)),
      nowMillis: () => now,
      random: () => 0.5, // 0.8 + 0.4*0.5 = jitter factor exactly 1.0
    );
  }

  /// The most recently dialed fake channel.
  FakeWsChannel get channel => channels.last;

  /// Lets queued stream events and chained futures settle.
  Future<void> pump() async {
    for (var i = 0; i < 6; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }
}

// ---------------------------------------------------------------------------
// Shared fixtures
// ---------------------------------------------------------------------------

const String kGuid = 'guid-0af7';

// 64 lowercase hex chars each (SPEC shapes).
final String testToken = 'ab' * 32;
final String testNonce = 'cd' * 32;

const DeviceTarget kTarget = DeviceTarget(
  key: kGuid,
  name: 'OMKAR-LAPTOP',
  host: '192.168.1.7',
  port: 17777,
);

/// Preloads a token and drives the service to authed over the fake channel.
Future<void> connectAndAuth(Harness h) async {
  h.store.preloadToken(kGuid, testToken);
  await h.service.connectTo(kTarget);
  h.channel.feed(ChallengeMsg(nonce: testNonce));
  await h.pump();
  h.channel.feed(const AuthOkMsg());
  await h.pump();
}

void main() {
  group('ConnectionService — pair flow (first connect)', () {
    test('dial -> hello -> needPin -> pin -> pairOk persists token + meta',
        () async {
      final h = Harness();
      h.now = 111222;
      await h.service.connectTo(kTarget);

      expect(h.dialed, [Uri.parse('ws://192.168.1.7:17777')]);
      expect(h.service.fsmState, ReconnectState.handshaking);
      expect(h.channel.sentMessages.first, isA<HelloMsg>());

      h.channel.feed(ChallengeMsg(nonce: testNonce));
      await h.pump();
      expect(h.service.handshakeStatus, HandshakeStatus.needPin,
          reason: 'unpaired target takes the PIN branch');

      h.service.feedPin('123456');
      await h.pump();
      final pin = h.channel.sentMessages.whereType<PinMsg>().single;
      expect(pin.pin, '123456');

      h.channel.feed(PairOkMsg(token: testToken));
      await h.pump();

      expect(h.service.isAuthed, isTrue);
      expect(h.service.chipStatus, ChipStatus.connected);
      expect(
        h.store.calls,
        containsAllInOrder([
          'saveToken:$kGuid',
          'upsertDevice:$kGuid',
          'setLastDevice:$kGuid',
        ]),
      );
      expect(h.store.secureKv.map['token.$kGuid'], testToken);
      final devices = await h.store.loadDevices();
      expect(devices[kGuid]?.host, '192.168.1.7');
      expect(devices[kGuid]?.lastConnectedAt, 111222);
      expect(await h.store.lastDeviceKey(), kGuid);
    });
  });

  group('ConnectionService — silent reconnect (CONN-03)', () {
    test('stored token takes the auth branch: no PIN, mac only on the wire',
        () async {
      final h = Harness();
      h.store.preloadToken(kGuid, testToken);
      await h.service.connectTo(kTarget);

      h.channel.feed(ChallengeMsg(nonce: testNonce));
      await h.pump();

      expect(h.service.handshakeStatus, isNot(HandshakeStatus.needPin),
          reason: 'paired device must never prompt for a PIN');
      final auth = h.channel.sentMessages.whereType<AuthMsg>().single;
      expect(
        auth.mac,
        authProof(hexDecode(testToken), hexDecode(testNonce)),
        reason: 'challenge-response via authProof, never hand-rolled',
      );

      h.channel.feed(const AuthOkMsg());
      await h.pump();
      expect(h.service.isAuthed, isTrue);

      for (final frame in h.channel.sentText) {
        expect(frame.contains(testToken), isFalse,
            reason: 'the raw token must never cross the wire (T-03-17)');
      }
      expect(h.store.calls, isNot(contains('saveToken:$kGuid')),
          reason: 'silent reconnect does not re-persist the token');
    });
  });

  group('ConnectionService — auth-stop on revocation (D-05)', () {
    test('authFail noPairing: token cleared, NO redial, explanation, closed',
        () async {
      final h = Harness();
      h.store.preloadToken(kGuid, testToken);
      await h.service.connectTo(kTarget);
      h.channel.feed(ChallengeMsg(nonce: testNonce));
      await h.pump();

      h.channel.feed(const AuthFailMsg(reason: 'noPairing'));
      await h.pump();

      expect(h.store.calls, contains('deleteToken:$kGuid'));
      expect(h.store.secureKv.map.containsKey('token.$kGuid'), isFalse);
      expect(h.service.fsmState, ReconnectState.needPairing);
      expect(h.service.pairingExplanation, kRevokedExplanation);
      expect(h.service.lastAuthFailure?.reason, 'noPairing');
      expect(h.dialed, hasLength(1),
          reason: 'auth failures NEVER silently retry (T-03-18)');
      expect(h.scheduled, isEmpty,
          reason: 'no backoff redial may be scheduled after auth-stop');
      expect(h.channel.closed, isTrue);
      expect(h.service.chipStatus, ChipStatus.disconnected);
    });
  });

  group('ConnectionService — transport drop recovery (CONN-04)', () {
    test('drop after authed: backoff scheduled; firing the timer redials',
        () async {
      final h = Harness();
      await connectAndAuth(h);
      expect(h.service.isAuthed, isTrue);

      final before = h.scheduled.length;
      await h.channel.incoming.close(); // transport drop (stream onDone)
      await h.pump();

      expect(h.service.fsmState, ReconnectState.backoff);
      expect(h.service.chipStatus, ChipStatus.reconnecting);
      final backoff = h.scheduled.sublist(before).single;
      expect(backoff.$1, const Duration(seconds: 1),
          reason: 'attempt 1 base 1s, jitter factor pinned to 1.0');

      backoff.$2(); // the driver-owned timer fires
      await h.pump();
      expect(h.dialed, hasLength(2), reason: 'backoff elapsed -> redial');
      expect(h.service.fsmState, ReconnectState.handshaking);
    });

    test('onAppResumed during backoff dials immediately (D-06)', () async {
      final h = Harness();
      await connectAndAuth(h);
      await h.channel.incoming.close();
      await h.pump();
      expect(h.service.fsmState, ReconnectState.backoff);

      h.service.onAppResumed();
      await h.pump();

      expect(h.dialed, hasLength(2),
          reason: 'resume short-circuits the backoff without waiting');
      expect(h.service.fsmState, ReconnectState.handshaking);
    });
  });

  group('ConnectionService — beacon short-circuit (D-06)', () {
    test('a beacon for the target guid redials at the NEW host:port',
        () async {
      final h = Harness();
      final beacons = StreamController<Beacon>();
      h.service.attachBeacons(beacons.stream);

      h.nextDialError = const SocketException('unreachable');
      await h.service.connectTo(kTarget);
      await h.pump();
      expect(h.service.fsmState, ReconnectState.backoff);

      beacons.add(Beacon(
        guid: kGuid,
        name: 'OMKAR-LAPTOP',
        port: 17800,
        // HISTORICAL wire pin: a '1.0' beacon must still be accepted —
        // minor mismatch is fine per SPEC section 2 (Pitfall 10).
        proto: '1.0',
        source: InternetAddress('192.168.1.99'),
      ));
      await h.pump();

      expect(h.dialed, hasLength(2));
      expect(h.dialed.last, Uri.parse('ws://192.168.1.99:17800'),
          reason: 'beacon sighting updates the dial address (PC IP change)');
      await beacons.close();
    });
  });

  group('ConnectionService — private-range dial guard (CONN-05 / D-10)', () {
    test('dial to a public address is refused in code: connect NEVER called',
        () async {
      final h = Harness();
      await h.service.connectTo(const DeviceTarget(
        key: 'k-evil',
        name: 'evil',
        host: '8.8.8.8',
        port: 17777,
      ));

      expect(h.dialed, isEmpty, reason: 'the guard is the real T-03-16 scope');
      expect(h.service.lastDialError, isNotNull);
      expect(h.service.fsmState, ReconnectState.idle,
          reason: 'guard failure is a terminal user-input error, not a blip');
      expect(h.scheduled, isEmpty, reason: 'no backoff for guard refusals');
    });

    test('isPrivateLanAddress truth table (8 cases)', () {
      expect(isPrivateLanAddress(InternetAddress('10.0.0.1')), isTrue);
      expect(isPrivateLanAddress(InternetAddress('172.16.0.1')), isTrue);
      expect(isPrivateLanAddress(InternetAddress('172.31.255.1')), isTrue);
      expect(isPrivateLanAddress(InternetAddress('172.32.0.1')), isFalse);
      expect(isPrivateLanAddress(InternetAddress('192.168.1.7')), isTrue);
      expect(isPrivateLanAddress(InternetAddress('169.254.10.10')), isTrue);
      expect(isPrivateLanAddress(InternetAddress('8.8.8.8')), isFalse);
      expect(isPrivateLanAddress(InternetAddress.loopbackIPv6), isFalse);
    });
  });

  group('ConnectionService — send policy', () {
    test('sendMove before authed puts NOTHING on the sink', () async {
      final h = Harness();
      await h.service.connectTo(kTarget); // handshaking, not authed
      final before = h.channel.sent.length;

      h.service.sendMove(3, 4);

      expect(h.channel.sent.length, before,
          reason: 'volatile frames are dropped, never queued, pre-auth');
    });

    test('sendMove after authed emits a 9-byte binary frame and ticks '
        'probe.onMove', () async {
      final h = Harness();
      await connectAndAuth(h);

      final before = h.channel.sent.length;
      h.service.sendMove(3, 4);
      expect(h.channel.sent.length, before + 1);
      expect(h.channel.sent.last, isA<List<int>>());
      expect((h.channel.sent.last as List<int>).length, 9);

      // probe.onMove is ticked per move: with the default movesPerPing=8 the
      // 8th move emits an interleaved ping onto the same sink.
      for (var i = 0; i < 7; i++) {
        h.service.sendMove(1, 1);
      }
      expect(h.channel.sentMessages.whereType<PingMsg>(), isNotEmpty,
          reason: 'sendMove drives the interleave cadence');
    });

    test('sendScroll before authed puts NOTHING on the sink', () async {
      final h = Harness();
      await h.service.connectTo(kTarget); // handshaking, not authed
      final before = h.channel.sent.length;

      h.service.sendScroll(0, -3);

      expect(h.channel.sent.length, before,
          reason: 'scroll is volatile like move: dropped pre-auth, '
              'never queued (PAD-03)');
    });

    test('sendScroll after authed emits one 9-byte binary frame with '
        'opcode 0x02', () async {
      final h = Harness();
      await connectAndAuth(h);

      final before = h.channel.sent.length;
      h.service.sendScroll(0, -3);
      expect(h.channel.sent.length, before + 1);
      final frame = h.channel.sent.last;
      expect(frame, isA<List<int>>());
      expect((frame as List<int>).length, 9);
      expect(frame.first, 0x02,
          reason: 'scroll frames carry the 0x02 opcode, not move\'s 0x01');
    });

    // 260812-uge REVERSED this test's original assertion. It used to prove
    // that frames sent while reconnecting flush FIFO on re-auth — the shipped
    // behaviour from phase 3 until the v1.0 close, and the reason anything
    // typed during an outage arrived late into whatever window was focused
    // afterwards. The setup is deliberately unchanged so the diff reads as
    // what it is: the same scenario, the opposite outcome.
    test('sendReliable during a reconnect is DROPPED, not replayed on re-auth',
        () async {
      final h = Harness();
      await connectAndAuth(h);
      await h.channel.incoming.close(); // drop -> backoff
      await h.pump();
      expect(h.service.fsmState, ReconnectState.backoff);

      for (var i = 0; i < 12; i++) {
        h.service.sendReliable(ClickMsg(button: 'b$i'));
      }

      // Fire the backoff timer (last scheduled entry) and re-auth.
      h.scheduled.last.$2();
      await h.pump();
      h.channel.feed(ChallengeMsg(nonce: testNonce));
      await h.pump();
      h.channel.feed(const AuthOkMsg());
      await h.pump();
      expect(h.service.isAuthed, isTrue);

      expect(h.channel.sentMessages.whereType<ClickMsg>(), isEmpty,
          reason: 'nothing sent during the outage may reach the PC — this is '
              'the whole point of the change; a queued power+confirm pair '
              'rode this same path');
    });

    test('the handshake window still queues: a frame sent after the socket is '
        'up but before authOk flushes on auth', () async {
      final h = Harness();
      h.store.preloadToken(kGuid, testToken);
      await h.service.connectTo(kTarget);
      h.channel.feed(ChallengeMsg(nonce: testNonce));
      await h.pump();

      // Socket installed, auth still pending — the one window that defers.
      expect(h.service.isAuthed, isFalse);
      h.service.sendReliable(ClickMsg(button: 'handshake'));
      expect(h.channel.sentMessages.whereType<ClickMsg>(), isEmpty,
          reason: 'not authed yet — held, not sent');

      h.channel.feed(const AuthOkMsg());
      await h.pump();

      expect(
        h.channel.sentMessages.whereType<ClickMsg>().map((c) => c.button),
        ['handshake'],
        reason: 'the bounded queue is NOT dead code — it still covers '
            'socket-open to auth-complete',
      );
    });
  });

  group('ConnectionService — apps snapshot + err arms (06-03)', () {
    test('apps.changed parks a value-equal AppsSnapshot and pings changes',
        () async {
      final h = Harness();
      await connectAndAuth(h);

      var pings = 0;
      final sub = h.service.changes.listen((_) => pings++);

      const windows = [
        WindowInfo(id: 7, title: 'Firefox', icon: 'AA==', path: r'C:\ff.exe'),
        WindowInfo(id: 8, title: 'Notepad'),
      ];
      h.channel.feed(const AppsChangedMsg(windows: windows));
      await h.pump();

      final snap = h.service.appsSnapshot;
      expect(snap, isNotNull);
      expect(snap!.windows, hasLength(2));
      expect(snap.windows.first.icon, 'AA==');
      expect(snap.windows.first.path, r'C:\ff.exe');
      expect(pings, greaterThan(0), reason: 'the push pings changes');

      // Value-equality: a second identical push produces an equal snapshot.
      final first = h.service.appsSnapshot;
      h.channel.feed(const AppsChangedMsg(windows: windows));
      await h.pump();
      expect(h.service.appsSnapshot, first,
          reason: 'two identical pushes are value-equal (no spurious rebuild)');

      await sub.cancel();
    });

    test('apps.list reply parks the same AppsSnapshot', () async {
      final h = Harness();
      await connectAndAuth(h);

      h.channel.feed(const AppsListMsg(windows: [
        WindowInfo(id: 1, title: 'Explorer'),
      ]));
      await h.pump();

      expect(h.service.appsSnapshot?.windows.single.title, 'Explorer');
    });

    test('an err frame parks lastError and pings changes', () async {
      final h = Harness();
      await connectAndAuth(h);

      var pings = 0;
      final sub = h.service.changes.listen((_) => pings++);

      h.channel.feed(const ErrMsg(
        code: 'windowGone',
        msg: 'That window is no longer open.',
      ));
      await h.pump();

      expect(h.service.lastError?.code, 'windowGone');
      expect(h.service.lastError?.msg, 'That window is no longer open.');
      expect(pings, greaterThan(0));

      await sub.cancel();
    });
  });

  group('ConnectionService — clip snapshot + fetch-reply arms (06-05)', () {
    test('ClipSnapshot value-equality', () {
      expect(const ClipSnapshot('a'), const ClipSnapshot('a'));
      expect(const ClipSnapshot('a').hashCode, const ClipSnapshot('a').hashCode);
      expect(const ClipSnapshot('a'), isNot(const ClipSnapshot('b')));
    });

    test('clip.changed parks a value-equal ClipSnapshot and pings changes',
        () async {
      final h = Harness();
      await connectAndAuth(h);

      var pings = 0;
      final sub = h.service.changes.listen((_) => pings++);

      h.channel.feed(const ClipChangedMsg(text: 'hello pc'));
      await h.pump();

      final snap = h.service.clipSnapshot;
      expect(snap, isNotNull);
      expect(snap!.text, 'hello pc');
      expect(pings, greaterThan(0), reason: 'the push pings changes');

      // Value-equality: a second identical push produces an equal snapshot
      // (no spurious rebuild).
      final first = h.service.clipSnapshot;
      h.channel.feed(const ClipChangedMsg(text: 'hello pc'));
      await h.pump();
      expect(h.service.clipSnapshot, first,
          reason: 'two identical pushes are value-equal');

      await sub.cancel();
    });

    test('clip.set (the clip.get reply) parks the fetch reply and pings changes',
        () async {
      final h = Harness();
      await connectAndAuth(h);

      var pings = 0;
      final sub = h.service.changes.listen((_) => pings++);

      // The server replies to clip.get with a clip.set frame (router replies
      // Msg::ClipSet{text}); it must land in the DISTINCT fetch-reply slot, not
      // the live clipSnapshot (which follows clip.changed only).
      h.channel.feed(const ClipSetMsg(text: 'from pc clipboard'));
      await h.pump();

      expect(h.service.clipFetchReply, 'from pc clipboard');
      expect(h.service.clipSnapshot, isNull,
          reason: 'a clip.set reply must not populate the live snapshot');
      expect(pings, greaterThan(0));

      await sub.cancel();
    });
  });

  group('ConnectionService — idle-ping liveness (CONN-06)', () {
    test('sustained idle silence declares the connection dead -> backoff',
        () async {
      final h = Harness();
      await connectAndAuth(h);

      // The liveness tick was scheduled at auth.
      var tick = h.scheduled.last;
      expect(tick.$1, const Duration(seconds: 2));
      final deadChannel = h.channel;

      // Drive idle ticks until the wall-clock silence window (missedPongLimit ×
      // idlePingInterval = 6s of unanswered pings, anchored at the first idle
      // ping) trips onDead. Dead-detection is time-based, not count-based, so
      // we loop on state rather than a hardcoded tick count (CR-01).
      for (var i = 0;
          i < 8 && h.service.fsmState == ReconnectState.authed;
          i++) {
        h.now += 2000;
        tick.$2();
        await h.pump();
        if (h.service.fsmState == ReconnectState.authed) {
          tick = h.scheduled.last; // the tick reschedules itself while authed
          expect(tick.$1, const Duration(seconds: 2));
        }
      }

      expect(deadChannel.sentMessages.whereType<PingMsg>(), isNotEmpty,
          reason: 'idle pings flowed on each 2s tick');
      expect(deadChannel.closed, isTrue,
          reason: 'dead connection is closed before the FSM is fed');
      expect(h.service.fsmState, ReconnectState.backoff,
          reason: 'onDead feeds transportFailed -> backoff redial');
      expect(h.service.chipStatus, ChipStatus.reconnecting);
    });

    test('WR-01: a superseded backoff timer does not fire a premature redial',
        () async {
      final h = Harness();
      await connectAndAuth(h);

      // Drop -> backoff: timer1 scheduled for episode 1.
      await h.channel.incoming.close();
      await h.pump();
      expect(h.service.fsmState, ReconnectState.backoff);
      final timer1 = h.scheduled.last;

      // Short-circuit out of backoff with a dial that fails fast -> the service
      // re-enters backoff with a NEW timer (timer2). timer1 is now stale.
      h.nextDialError = Exception('connect refused');
      h.service.retryNow();
      await h.pump();
      expect(h.service.fsmState, ReconnectState.backoff,
          reason: 'the fast-failed short-circuit dial re-enters backoff');
      final dialsAfterRetry = h.dialed.length;
      final timer2 = h.scheduled.last;

      // Firing the STALE timer1 must no-op (generation guard) — NOT redial.
      timer1.$2();
      await h.pump();
      expect(h.dialed.length, dialsAfterRetry,
          reason: 'a superseded backoff timer must not trigger a dial (WR-01)');

      // The CURRENT episode's timer still redials normally.
      timer2.$2();
      await h.pump();
      expect(h.dialed.length, dialsAfterRetry + 1,
          reason: 'the live backoff timer redials');
    });

    test('a pong keeps the connection alive (counter resets)', () async {
      final h = Harness();
      await connectAndAuth(h);

      var tick = h.scheduled.last;
      for (var i = 0; i < 2; i++) {
        h.now += 2000;
        tick.$2();
        await h.pump();
        tick = h.scheduled.last;
      }
      // Answer the outstanding pings; the dead counter must reset.
      h.channel.feed(PongMsg(ts: h.now));
      await h.pump();
      expect(h.service.probe?.pingsAwaited, 0);

      h.now += 2000;
      tick.$2();
      await h.pump();
      expect(h.service.isAuthed, isTrue,
          reason: 'answered pings never accumulate toward the dead limit');
    });
  });

  group('ConnectionService — update seam (12-14, protoVersion 1.8)', () {
    test('UpdateSnapshot value-equality over all three parts', () {
      const a = UpdateSnapshot(
        status: UpdateStatusSnapshot(serverVersion: '1.5.0', extConnected: true),
        progress: UpdateProgressSnapshot(stage: 'downloading', pct: 42),
      );
      const b = UpdateSnapshot(
        status: UpdateStatusSnapshot(serverVersion: '1.5.0', extConnected: true),
        progress: UpdateProgressSnapshot(stage: 'downloading', pct: 42),
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(const UpdateSnapshot(serverTooOld: true)));
      expect(UpdateSnapshot.empty, const UpdateSnapshot());
    });

    test('update.status parks a value-equal snapshot and pings changes',
        () async {
      final h = Harness();
      await connectAndAuth(h);

      var pings = 0;
      final sub = h.service.changes.listen((_) => pings++);

      h.channel.feed(const UpdateStatusMsg(
        serverVersion: '1.4.0',
        extConnected: true,
        extVersion: '1.4.0',
        lastUpdate: LastUpdate(target: '1.4.0', ok: true),
      ));
      await h.pump();

      final status = h.service.updateSnapshot.status;
      expect(status, isNotNull);
      expect(status!.serverVersion, '1.4.0');
      expect(status.extConnected, isTrue);
      expect(status.extVersion, '1.4.0');
      expect(status.lastUpdate?.ok, isTrue);
      expect(pings, greaterThan(0), reason: 'the reply pings changes');

      final first = h.service.updateSnapshot;
      h.channel.feed(const UpdateStatusMsg(
        serverVersion: '1.4.0',
        extConnected: true,
        extVersion: '1.4.0',
        lastUpdate: LastUpdate(target: '1.4.0', ok: true),
      ));
      await h.pump();
      expect(h.service.updateSnapshot, first,
          reason: 'two identical replies are value-equal (no spurious rebuild)');

      await sub.cancel();
    });

    test('update.progress parks the stage/pct/error snapshot', () async {
      final h = Harness();
      await connectAndAuth(h);

      h.channel.feed(const UpdateProgressMsg(
        stage: 'downloading',
        pct: 43,
        version: '1.5.0',
      ));
      await h.pump();
      expect(h.service.updateSnapshot.progress?.stage, 'downloading');
      expect(h.service.updateSnapshot.progress?.pct, 43);

      // The service records what the wire said — the closed D-11 vocabulary is
      // interpreted by the update store, never here.
      h.channel.feed(const UpdateProgressMsg(stage: 'failed', error: 'busy'));
      await h.pump();
      expect(h.service.updateSnapshot.progress?.stage, 'failed');
      expect(h.service.updateSnapshot.progress?.error, 'busy');
    });

    test('sendUpdateCheck rides the reliable path with an empty payload',
        () async {
      final h = Harness();
      await connectAndAuth(h);

      h.service.sendUpdateCheck();
      await h.pump();

      final sent = h.channel.sentMessages.whereType<UpdateCheckMsg>();
      expect(sent, hasLength(1));
      expect(sent.single.toPayload(), isEmpty);
    });

    test('sendUpdateApply carries a version and nothing else (T-12-01)',
        () async {
      final h = Harness();
      await connectAndAuth(h);

      h.service.sendUpdateApply('1.5.0');
      await h.pump();

      final sent = h.channel.sentMessages.whereType<UpdateApplyMsg>();
      expect(sent, hasLength(1));
      expect(sent.single.target, '1.5.0');
      // The one-key shape is the phone-side half of D-14: there is nowhere for
      // a url, an asset name, a file name or a hash to be added.
      expect(sent.single.toPayload().keys, ['target']);
    });

    test('err{unknownType} while a check is outstanding sets serverTooOld',
        () async {
      final h = Harness();
      await connectAndAuth(h);

      h.service.sendUpdateCheck();
      await h.pump();
      h.channel.feed(const ErrMsg(
        code: kUnknownTypeErrCode,
        msg: 'Unknown message type.',
      ));
      await h.pump();

      expect(h.service.updateSnapshot.serverTooOld, isTrue);
      expect(h.service.updateSnapshot.status, isNull);
    });

    test('err{unknownType} with NO outstanding check leaves the flag alone',
        () async {
      final h = Harness();
      await connectAndAuth(h);

      h.channel.feed(const ErrMsg(
        code: kUnknownTypeErrCode,
        msg: 'Unknown message type.',
      ));
      await h.pump();

      expect(h.service.updateSnapshot.serverTooOld, isFalse,
          reason: 'a refusal of some OTHER family is not an update verdict');
      expect(h.service.lastError?.code, kUnknownTypeErrCode);
    });

    test('a server that answers update.status clears the too-old flag',
        () async {
      final h = Harness();
      await connectAndAuth(h);

      h.service.sendUpdateCheck();
      await h.pump();
      h.channel.feed(const ErrMsg(code: kUnknownTypeErrCode, msg: 'nope'));
      await h.pump();
      expect(h.service.updateSnapshot.serverTooOld, isTrue);

      h.service.sendUpdateCheck();
      await h.pump();
      h.channel.feed(
          const UpdateStatusMsg(serverVersion: '1.8.0', extConnected: false));
      await h.pump();

      expect(h.service.updateSnapshot.serverTooOld, isFalse);
      expect(h.service.updateSnapshot.status?.serverVersion, '1.8.0');
    });

    test('the update snapshot is CLEARED when the session drops', () async {
      final h = Harness();
      await connectAndAuth(h);

      h.channel.feed(const UpdateStatusMsg(
        serverVersion: '1.4.0',
        extConnected: true,
        extVersion: '1.4.0',
      ));
      h.channel.feed(const UpdateProgressMsg(stage: 'restarting'));
      await h.pump();
      expect(h.service.updateSnapshot.status, isNotNull);

      // The PC update deliberately drops this socket (D-17).
      await h.channel.incoming.close();
      await h.pump();

      expect(h.service.updateSnapshot, UpdateSnapshot.empty,
          reason: 'a stale serverVersion must not outlive its session');
    });

    test('the reconnect attempt count is readable — and no NEW timer exists',
        () async {
      final h = Harness();
      await connectAndAuth(h);
      expect(h.service.reconnectAttempt, 0);

      final scheduledBefore = h.scheduled.length;
      h.service.sendUpdateApply('1.5.0');
      await h.pump();
      expect(h.scheduled.length, scheduledBefore,
          reason: 'apply schedules NOTHING — D-17 forbids a second reconnect '
              'path; the existing FSM rides the drop out');

      await h.channel.incoming.close();
      await h.pump();
      expect(h.service.reconnectAttempt, 1,
          reason: 'the EXISTING FSM counter is what D-25 reads');
    });
  });
}
