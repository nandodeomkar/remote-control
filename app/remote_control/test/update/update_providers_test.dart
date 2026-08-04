// Task 3 (12-14) — the Updates row-state machine and the Settings badge.
//
// This file is the executable form of the 12-UI-SPEC row state matrix: every
// row of that table is driven here through injected fakes for the feed, the
// cache, the connection service, the downloader, the sha256 gate and the
// installer channel, so the whole surface runs offline with no socket, no
// HTTP and no platform channel.
//
// The eight binding state rules beneath the matrix are each asserted BY NAME
// below, because they are the part of the contract a renderer cannot enforce:
// a state that can be constructed will eventually be shown.

import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_protocol/remote_protocol.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'package:remote_control/net/connection_providers.dart';
import 'package:remote_control/net/connection_service.dart';
import 'package:remote_control/net/reconnect_fsm.dart';
import 'package:remote_control/settings/app_version.dart';
import 'package:remote_control/store/device_store.dart';
import 'package:remote_control/update/apk_download.dart';
import 'package:remote_control/update/apk_installer.dart';
import 'package:remote_control/update/release_feed.dart';
import 'package:remote_control/update/update_cache.dart';
import 'package:remote_control/update/update_providers.dart';

// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------

class FakeWsChannel implements WebSocketChannel {
  final StreamController<dynamic> incoming = StreamController<dynamic>();
  final _RecordingSink _sink = _RecordingSink();

  @override
  Stream<dynamic> get stream => incoming.stream;

  @override
  WebSocketSink get sink => _sink;

  List<RemoteMessage> get sentMessages => _sink.added
      .whereType<String>()
      .map((f) => decodeText(f).msg)
      .toList();

  void feed(RemoteMessage msg) => incoming.add(encodeMessage(msg));

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _RecordingSink implements WebSocketSink {
  final List<Object?> added = <Object?>[];

  @override
  void add(dynamic data) => added.add(data);

  @override
  Future<dynamic> close([int? closeCode, String? closeReason]) async {}

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

/// The `PackageInstaller` channel, faked. Never touches the platform.
class FakeInstaller extends ApkInstaller {
  final StreamController<InstallEvent> _out =
      StreamController<InstallEvent>.broadcast();
  final List<String> installed = <String>[];

  /// Whether the "install unknown apps" grant is held (D-19).
  bool grant = true;

  @override
  Stream<InstallEvent> get outcomes => _out.stream;

  @override
  Future<bool> canInstall() async => grant;

  @override
  Future<void> install(String apkPath) async => installed.add(apkPath);

  void push(InstallEvent event) => _out.add(event);
}

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

const String kGuid = 'guid-0af7';

const DeviceTarget kTarget = DeviceTarget(
  key: kGuid,
  name: 'OMKAR-LAPTOP',
  host: '192.168.1.7',
  port: 17777,
);

/// The three real assets, at their real magnitudes (66 MB / 4.9 MB / 13 KB).
Release releaseAt(String version) => Release(
      version: version,
      assets: [
        ReleaseAsset(
          name: 'RemoteControl-v$version.apk',
          url: 'https://example.invalid/a.apk',
          sizeBytes: 69630935,
          sha256: 'a' * 64,
        ),
        ReleaseAsset(
          name: 'RemoteControl-Setup-v$version.exe',
          url: 'https://example.invalid/s.exe',
          sizeBytes: 5177240,
          sha256: 'b' * 64,
        ),
        ReleaseAsset(
          name: 'RemoteControl-Extension-v$version.zip',
          url: 'https://example.invalid/e.zip',
          sizeBytes: 13312,
          sha256: 'c' * 64,
        ),
      ],
    );

/// A real [ConnectionService] over fake seams — no socket, no timers except
/// the ones the test fires by hand.
class Wire {
  final MemSecureKv secure = MemSecureKv();
  final MemPrefsKv prefs = MemPrefsKv();
  final List<FakeWsChannel> channels = <FakeWsChannel>[];
  final List<void Function()> scheduled = <void Function()>[];
  late final ConnectionService service;

  Wire() {
    service = ConnectionService(
      store: DeviceStore(secure: secure, prefs: prefs),
      connect: (uri) async {
        final ch = FakeWsChannel();
        channels.add(ch);
        return ch;
      },
      schedule: (delay, fn) => scheduled.add(fn),
      nowMillis: () => 0,
      random: () => 0.5,
    );
  }

  FakeWsChannel get channel => channels.last;

  Future<void> pump() async {
    for (var i = 0; i < 8; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  Future<void> connectAndAuth() async {
    secure.map['token.$kGuid'] = 'ab' * 32;
    await service.connectTo(kTarget);
    channel.feed(ChallengeMsg(nonce: 'cd' * 32));
    await pump();
    channel.feed(const AuthOkMsg());
    await pump();
  }

  /// Drops the socket [times] times, firing the backoff timer between drops so
  /// the FSM's own attempt counter climbs — the counter D-25 reads.
  Future<void> dropAndRedial(int times) async {
    for (var i = 0; i < times; i++) {
      await channel.incoming.close();
      await pump();
      if (scheduled.isNotEmpty) {
        final fire = scheduled.removeLast();
        scheduled.clear();
        fire();
        await pump();
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Container
// ---------------------------------------------------------------------------

MemPrefsKv cachePrefs({int? atMillis, String? version}) {
  final p = MemPrefsKv();
  if (atMillis != null) p.map[kUpdateLastCheckAtPrefsKey] = '$atMillis';
  if (version != null) p.map[kUpdateLastSeenVersionPrefsKey] = version;
  return p;
}

ProviderContainer host({
  required Wire wire,
  Future<Release?> Function()? fetch,
  String installedVersion = '1.4.0',
  bool installedThrows = false,
  MemPrefsKv? prefs,
  FakeInstaller? installer,
  ApkDownloader? downloader,
  ApkVerifier? verifier,
  DateTime? now,
}) {
  final container = ProviderContainer(overrides: [
    connectionServiceProvider.overrideWithValue(wire.service),
    appBareVersionProvider.overrideWith((ref) async {
      if (installedThrows) throw Exception('no plugin registrant');
      return installedVersion;
    }),
    updateCacheStoreProvider
        .overrideWithValue(UpdateCacheStore(prefs: prefs ?? MemPrefsKv())),
    releaseFetcherProvider
        .overrideWithValue(fetch ?? () async => null),
    apkInstallerProvider.overrideWithValue(installer ?? FakeInstaller()),
    if (downloader != null) apkDownloaderProvider.overrideWithValue(downloader),
    if (verifier != null) apkVerifierProvider.overrideWithValue(verifier),
    updateClockProvider
        .overrideWithValue(() => now ?? DateTime.utc(2026, 8, 4, 12)),
  ]);
  addTearDown(container.dispose);
  return container;
}

/// Reads the state after letting the async cache load and the async version
/// lookup land.
Future<UpdatesViewState> settle(ProviderContainer c, Wire wire) async {
  c.read(updatesStateProvider);
  await wire.pump();
  return c.read(updatesStateProvider);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // -------------------------------------------------------------------------
  group('UpdateRowState — value equality', () {
    test('the same inputs produce an equal, identically-hashing state', () {
      const a = UpdateRowState.available(
          installed: '1.4.0', latest: '1.5.0', sizeBytes: 69630935);
      const b = UpdateRowState.available(
          installed: '1.4.0', latest: '1.5.0', sizeBytes: 69630935);
      expect(a, b);
      expect(a.hashCode, b.hashCode);

      expect(const UpdateRowState.downloading(43),
          const UpdateRowState.downloading(43));
      expect(const UpdateRowState.downloading(43),
          isNot(const UpdateRowState.downloading(44)));
      expect(const UpdateRowState.failed(UpdateFailure.network),
          isNot(const UpdateRowState.failed(UpdateFailure.disk)));
      expect(const UpdateRowState.checking(),
          isNot(const UpdateRowState.verifying()));
    });

    test('the Extension available variant is NOT equal to the actionable one',
        () {
      const ext = UpdateRowState.availableNoAction(
          installed: '1.4.0', latest: '1.5.0');
      const app = UpdateRowState.available(
          installed: '1.4.0', latest: '1.5.0', sizeBytes: 1);
      expect(ext, isNot(app));
      expect(ext.actionable, isFalse);
      expect(app.actionable, isTrue);
    });

    test('UpdatesViewState is value-equal across all five fields', () {
      const one = UpdatesViewState(
        app: UpdateRowState.upToDate('1.4.0'),
        pc: UpdateRowState.serverDisconnected(),
        extension: UpdateRowState.serverDisconnected(),
        footer: CheckFooterState.neverChecked(),
        badge: false,
      );
      const two = UpdatesViewState(
        app: UpdateRowState.upToDate('1.4.0'),
        pc: UpdateRowState.serverDisconnected(),
        extension: UpdateRowState.serverDisconnected(),
        footer: CheckFooterState.neverChecked(),
        badge: false,
      );
      expect(one, two);
      expect(one.hashCode, two.hashCode);
      expect(one, isNot(const UpdatesViewState.initial()));
    });
  });

  // -------------------------------------------------------------------------
  group('the row-state matrix — every state is reachable', () {
    test('checking: all three rows while a tapped check is in flight',
        () async {
      final wire = Wire();
      await wire.connectAndAuth();
      final gate = Completer<Release?>();
      final c = host(wire: wire, fetch: () => gate.future);
      await settle(c, wire);

      unawaited(c.read(updatesStateProvider.notifier).check());
      await wire.pump();

      final s = c.read(updatesStateProvider);
      expect(s.app.kind, UpdateRowKind.checking);
      expect(s.pc.kind, UpdateRowKind.checking);
      expect(s.extension.kind, UpdateRowKind.checking);
      expect(s.footer.kind, CheckFooterKind.checking);

      gate.complete(null);
      await wire.pump();
    });

    test('upToDate / available / availableNoAction across the three rows',
        () async {
      final wire = Wire();
      await wire.connectAndAuth();
      final c = host(
        wire: wire,
        installedVersion: '1.5.0', // the phone is already current
        fetch: () async => releaseAt('1.5.0'),
      );
      await settle(c, wire);

      await c.read(updatesStateProvider.notifier).check();
      // The PC is behind; the extension is behind but the PC is too, so the
      // extension is simply waiting on the PC update.
      wire.channel.feed(const UpdateStatusMsg(
        serverVersion: '1.4.0',
        extConnected: true,
        extVersion: '1.4.0',
      ));
      await wire.pump();

      final s = c.read(updatesStateProvider);
      expect(s.app, const UpdateRowState.upToDate('1.5.0'));
      expect(
        s.pc,
        const UpdateRowState.available(
          installed: '1.4.0',
          latest: '1.5.0',
          sizeBytes: 5177240,
        ),
        reason: 'the PC row carries the setup exe size (D-08)',
      );
      expect(
        s.extension,
        const UpdateRowState.availableNoAction(
            installed: '1.4.0', latest: '1.5.0'),
      );
      expect(s.extension.actionable, isFalse);
      expect(s.extension.sizeBytes, isNull,
          reason: 'the extension has no download of its own');
    });

    test('available (app): the APK size reaches the row before any download',
        () async {
      final wire = Wire();
      final c = host(wire: wire, fetch: () async => releaseAt('1.5.0'));
      await settle(c, wire);

      await c.read(updatesStateProvider.notifier).check();
      await wire.pump();

      expect(
        c.read(updatesStateProvider).app,
        const UpdateRowState.available(
          installed: '1.4.0',
          latest: '1.5.0',
          sizeBytes: 69630935,
        ),
      );
    });

    test('downloading / verifying / installing on the PC row, from the wire',
        () async {
      final wire = Wire();
      await wire.connectAndAuth();
      final c = host(wire: wire, fetch: () async => releaseAt('1.5.0'));
      await settle(c, wire);

      wire.channel.feed(const UpdateProgressMsg(
          stage: kStageDownloading, pct: 43, version: '1.5.0'));
      await wire.pump();
      expect(c.read(updatesStateProvider).pc,
          const UpdateRowState.downloading(43));

      wire.channel.feed(const UpdateProgressMsg(stage: kStageVerifying));
      await wire.pump();
      expect(c.read(updatesStateProvider).pc, const UpdateRowState.verifying());

      wire.channel.feed(const UpdateProgressMsg(stage: kStageInstalling));
      await wire.pump();
      expect(c.read(updatesStateProvider).pc, const UpdateRowState.installing());

      wire.channel.feed(const UpdateProgressMsg(stage: kStageRestarting));
      await wire.pump();
      expect(c.read(updatesStateProvider).pc, const UpdateRowState.restarting());
    });

    test('failed(code): each of the five renderable D-11 codes', () async {
      final wire = Wire();
      await wire.connectAndAuth();
      final c = host(wire: wire, fetch: () async => releaseAt('1.5.0'));
      await settle(c, wire);

      const cases = {
        kErrNetwork: UpdateFailure.network,
        kErrChecksum: UpdateFailure.checksum,
        kErrDisk: UpdateFailure.disk,
        kErrInstaller: UpdateFailure.installer,
        kErrStale: UpdateFailure.stale,
      };
      for (final entry in cases.entries) {
        wire.channel.feed(
            UpdateProgressMsg(stage: kStageFailed, error: entry.key));
        await wire.pump();
        expect(c.read(updatesStateProvider).pc,
            UpdateRowState.failed(entry.value));
        expect(c.read(updatesStateProvider).pc.actionable, isTrue,
            reason: 'a row-scoped failure offers Retry');
      }
    });

    test('couldNotCheck: ONE feed failure puts all three rows there, and the '
        'single retry lives in the footer (D-22)', () async {
      final wire = Wire();
      await wire.connectAndAuth();
      final c = host(wire: wire, fetch: () async => null);
      await settle(c, wire);

      await c.read(updatesStateProvider.notifier).check();
      await wire.pump();

      final s = c.read(updatesStateProvider);
      expect(s.app.kind, UpdateRowKind.couldNotCheck);
      expect(s.pc.kind, UpdateRowKind.couldNotCheck);
      expect(s.extension.kind, UpdateRowKind.couldNotCheck);
      expect(s.footer.kind, CheckFooterKind.failed);
      expect(
        [s.app.actionable, s.pc.actionable, s.extension.actionable],
        everyElement(isFalse),
        reason: 'three Retry buttons for one failure would be three '
            'affordances for one act',
      );
    });

    test('serverDisconnected: PC and Extension are gated, the App row is NOT',
        () async {
      final wire = Wire(); // never authed
      final c = host(wire: wire, fetch: () async => releaseAt('1.5.0'));
      await settle(c, wire);

      await c.read(updatesStateProvider.notifier).check();
      await wire.pump();

      final s = c.read(updatesStateProvider);
      expect(s.pc, const UpdateRowState.serverDisconnected());
      expect(s.extension, const UpdateRowState.serverDisconnected());
      expect(s.app.kind, UpdateRowKind.available,
          reason: 'the App row works with no PC in the room — its version '
              'comes from the package and its feed from the internet');
      expect(s.app.actionable, isTrue);
    });

    test('serverTooOld blanks BOTH PC-side rows with the same state', () async {
      final wire = Wire();
      await wire.connectAndAuth();
      final c = host(wire: wire, fetch: () async => releaseAt('1.5.0'));
      await settle(c, wire);

      wire.service.sendUpdateCheck();
      await wire.pump();
      wire.channel
          .feed(const ErrMsg(code: kUnknownTypeErrCode, msg: 'unknown type'));
      await wire.pump();

      final s = c.read(updatesStateProvider);
      expect(s.pc, const UpdateRowState.serverTooOld());
      expect(s.extension, const UpdateRowState.serverTooOld(),
          reason: 'a 1.7 server cannot report extVersion through a family it '
              'does not know — the cause reads once, not twice');
    });

    test('pcDidNotReturn after an apply the PC never came back from (D-25)',
        () async {
      final wire = Wire();
      await wire.connectAndAuth();
      final c = host(wire: wire, fetch: () async => releaseAt('1.5.0'));
      await settle(c, wire);

      c.read(updatesStateProvider.notifier).updatePc('1.5.0');
      await wire.pump();

      // One drop: the socket has gone, but the FSM is still trying.
      await wire.dropAndRedial(1);
      expect(c.read(updatesStateProvider).pc,
          const UpdateRowState.restarting(),
          reason: 'the reconnect banner is the only reconnect surface (D-17)');

      await wire.dropAndRedial(kPcReturnAttempts);
      expect(c.read(updatesStateProvider).pc,
          const UpdateRowState.pcDidNotReturn());
      expect(c.read(updatesStateProvider).pc.actionable, isTrue);
    });

    test('extensionNeverConnected when the server reports no extVersion',
        () async {
      final wire = Wire();
      await wire.connectAndAuth();
      final c = host(wire: wire, fetch: () async => releaseAt('1.5.0'));
      await settle(c, wire);

      wire.channel.feed(const UpdateStatusMsg(
          serverVersion: '1.5.0', extConnected: false));
      await wire.pump();

      expect(c.read(updatesStateProvider).extension,
          const UpdateRowState.extensionNeverConnected());
    });

    test('extensionNeedsBrowserRestart when the PC is current and the '
        'extension is not (D-18)', () async {
      final wire = Wire();
      await wire.connectAndAuth();
      final c = host(wire: wire, fetch: () async => releaseAt('1.5.0'));
      await settle(c, wire);

      await c.read(updatesStateProvider.notifier).check();
      wire.channel.feed(const UpdateStatusMsg(
        serverVersion: '1.5.0', // the installer already ran
        extConnected: true,
        extVersion: '1.4.0', // ...but the reload did not take
      ));
      await wire.pump();

      expect(c.read(updatesStateProvider).extension,
          const UpdateRowState.extensionNeedsBrowserRestart());
      expect(c.read(updatesStateProvider).extension.actionable, isFalse);
    });

    test('unknownVersion for an unparseable installed version', () async {
      final wire = Wire();
      final c = host(
        wire: wire,
        installedVersion: 'not-a-version',
        fetch: () async => releaseAt('1.5.0'),
      );
      await settle(c, wire);

      await c.read(updatesStateProvider.notifier).check();
      await wire.pump();

      expect(c.read(updatesStateProvider).app,
          const UpdateRowState.unknownVersion());
    });

    test('unknownVersion when the package lookup itself failed', () async {
      final wire = Wire();
      final c = host(
        wire: wire,
        installedThrows: true,
        fetch: () async => releaseAt('1.5.0'),
      );
      await settle(c, wire);

      await c.read(updatesStateProvider.notifier).check();
      await wire.pump();

      expect(c.read(updatesStateProvider).app.kind,
          UpdateRowKind.unknownVersion);
    });
  });

  // -------------------------------------------------------------------------
  group('binding rule 1 — available is never manufactured (D-26, T-12-18)', () {
    test('a version EQUAL to installed is upToDate, never available', () async {
      final wire = Wire();
      final c = host(wire: wire, fetch: () async => releaseAt('1.4.0'));
      await settle(c, wire);

      await c.read(updatesStateProvider.notifier).check();
      await wire.pump();

      expect(c.read(updatesStateProvider).app,
          const UpdateRowState.upToDate('1.4.0'));
    });

    test('a version BELOW installed is upToDate, never available', () async {
      final wire = Wire();
      final c = host(
          wire: wire,
          installedVersion: '1.6.0',
          fetch: () async => releaseAt('1.5.0'));
      await settle(c, wire);

      await c.read(updatesStateProvider.notifier).check();
      await wire.pump();

      expect(c.read(updatesStateProvider).app,
          const UpdateRowState.upToDate('1.6.0'));
    });

    test('a crafted tag resolves to unknownVersion, never to an Update button',
        () async {
      for (final tag in ['9.9.9-evil', 'latest', '1.5', '']) {
        final wire = Wire();
        final c = host(wire: wire, fetch: () async => releaseAt(tag));
        await settle(c, wire);

        await c.read(updatesStateProvider.notifier).check();
        await wire.pump();

        final app = c.read(updatesStateProvider).app;
        expect(app.kind, UpdateRowKind.unknownVersion, reason: 'tag: $tag');
        expect(app.actionable, isFalse, reason: 'tag: $tag');
      }
    });

    test('a release with no matching asset cannot be offered', () async {
      final wire = Wire();
      final c = host(
        wire: wire,
        fetch: () async => const Release(version: '1.5.0', assets: []),
      );
      await settle(c, wire);

      await c.read(updatesStateProvider.notifier).check();
      await wire.pump();

      expect(c.read(updatesStateProvider).app,
          const UpdateRowState.unknownVersion());
    });
  });

  // -------------------------------------------------------------------------
  group('binding rule 7 — busy is swallowed (D-11)', () {
    test('busy arriving as an update.progress error produces NO state change',
        () async {
      final wire = Wire();
      await wire.connectAndAuth();
      final c = host(wire: wire, fetch: () async => releaseAt('1.5.0'));
      await settle(c, wire);

      wire.channel.feed(const UpdateProgressMsg(
          stage: kStageDownloading, pct: 61, version: '1.5.0'));
      await wire.pump();
      final before = c.read(updatesStateProvider);
      expect(before.pc, const UpdateRowState.downloading(61));

      wire.channel
          .feed(const UpdateProgressMsg(stage: kStageFailed, error: kErrBusy));
      await wire.pump();

      expect(c.read(updatesStateProvider), before,
          reason: 'busy means the row already shows what is happening — '
              'surfacing it would blame the user for a race');
      expect(c.read(updatesStateProvider).pc,
          const UpdateRowState.downloading(61));
    });

    test('mapWireError returns null for busy and never yields a busy failure',
        () {
      expect(mapWireError(kErrBusy), isNull);
      expect(UpdateFailure.values.map((f) => f.name), isNot(contains('busy')));
    });
  });

  // -------------------------------------------------------------------------
  group('binding rule 8 — downgrade degrades to failed(installer)', () {
    test('a downgrade push renders as the generic installer failure', () async {
      final wire = Wire();
      await wire.connectAndAuth();
      final c = host(wire: wire, fetch: () async => releaseAt('1.5.0'));
      await settle(c, wire);

      wire.channel.feed(
          const UpdateProgressMsg(stage: kStageFailed, error: kErrDowngrade));
      await wire.pump();

      expect(c.read(updatesStateProvider).pc,
          const UpdateRowState.failed(UpdateFailure.installer));
    });

    test('mapWireError maps downgrade to installer, and downgrade is not '
        'representable as a failure', () {
      expect(mapWireError(kErrDowngrade), UpdateFailure.installer);
      expect(
          UpdateFailure.values.map((f) => f.name), isNot(contains('downgrade')));
    });

    test('lastUpdate{ok:false} from the startup marker renders too (D-12)',
        () async {
      final wire = Wire();
      await wire.connectAndAuth();
      final c = host(wire: wire, fetch: () async => releaseAt('1.5.0'));
      await settle(c, wire);

      wire.channel.feed(const UpdateStatusMsg(
        serverVersion: '1.4.0',
        extConnected: false,
        lastUpdate:
            LastUpdate(target: '1.5.0', ok: false, error: kErrInstaller),
      ));
      await wire.pump();

      expect(c.read(updatesStateProvider).pc,
          const UpdateRowState.failed(UpdateFailure.installer));
    });
  });

  // -------------------------------------------------------------------------
  group('binding rule 2 — the Extension row never has an enabled action', () {
    test('no extension state is ever actionable', () async {
      final wire = Wire();
      await wire.connectAndAuth();
      final c = host(wire: wire, fetch: () async => releaseAt('1.5.0'));
      await settle(c, wire);
      await c.read(updatesStateProvider.notifier).check();

      final pushes = <UpdateStatusMsg>[
        const UpdateStatusMsg(serverVersion: '1.5.0', extConnected: false),
        const UpdateStatusMsg(
            serverVersion: '1.5.0', extConnected: true, extVersion: '1.4.0'),
        const UpdateStatusMsg(
            serverVersion: '1.4.0', extConnected: true, extVersion: '1.4.0'),
        const UpdateStatusMsg(
            serverVersion: '1.5.0', extConnected: true, extVersion: '1.5.0'),
        const UpdateStatusMsg(
            serverVersion: '1.5.0', extConnected: true, extVersion: 'junk'),
      ];
      for (final push in pushes) {
        wire.channel.feed(push);
        await wire.pump();
        expect(c.read(updatesStateProvider).extension.actionable, isFalse,
            reason: 'after $push');
      }
    });
  });

  // -------------------------------------------------------------------------
  group('binding rules 3/4 — the APK path (D-19)', () {
    test('a missing install grant opens the sheet and downloads NOTHING',
        () async {
      final wire = Wire();
      final installer = FakeInstaller()..grant = false;
      var downloads = 0;
      final c = host(
        wire: wire,
        fetch: () async => releaseAt('1.5.0'),
        installer: installer,
        downloader: (asset, {required onProgress, onError}) async {
          downloads++;
          return null;
        },
      );
      await settle(c, wire);
      await c.read(updatesStateProvider.notifier).check();
      await wire.pump();

      final result = await c.read(updatesStateProvider.notifier).updateApp();
      await wire.pump();

      expect(result, UpdateAppResult.needsInstallGrant);
      expect(downloads, 0, reason: '70 MB is not spent on a hunch');
      expect(c.read(updatesStateProvider).app.kind, UpdateRowKind.available,
          reason: 'the row stays on available while the sheet is up');
    });

    test('downloading -> verifying -> installing, then a decline returns the '
        'row to available', () async {
      final wire = Wire();
      final installer = FakeInstaller();
      final downloadGate = Completer<void>();
      final verifyGate = Completer<void>();
      final c = host(
        wire: wire,
        fetch: () async => releaseAt('1.5.0'),
        installer: installer,
        downloader: (asset, {required onProgress, onError}) async {
          onProgress(50, 100);
          await downloadGate.future;
          return '/cache/RemoteControl-v1.5.0.apk';
        },
        verifier: (file, expectedHex) async {
          await verifyGate.future;
          return true;
        },
      );
      await settle(c, wire);
      await c.read(updatesStateProvider.notifier).check();
      await wire.pump();

      unawaited(c.read(updatesStateProvider.notifier).updateApp());
      await wire.pump();
      expect(c.read(updatesStateProvider).app,
          const UpdateRowState.downloading(50));

      downloadGate.complete();
      await wire.pump();
      expect(c.read(updatesStateProvider).app, const UpdateRowState.verifying());

      verifyGate.complete();
      await wire.pump();
      expect(c.read(updatesStateProvider).app, const UpdateRowState.installing());
      expect(installer.installed, ['/cache/RemoteControl-v1.5.0.apk']);

      // D-19: the user said no. That is not a failure.
      installer.push(const InstallEvent(InstallOutcome.declined));
      await wire.pump();
      expect(c.read(updatesStateProvider).app.kind, UpdateRowKind.available);
      expect(c.read(updatesStateProvider).app.actionable, isTrue);
    });

    test('a failed download maps the closed DownloadError vocabulary',
        () async {
      for (final entry in {
        DownloadError.network: UpdateFailure.network,
        DownloadError.disk: UpdateFailure.disk,
        DownloadError.checksum: UpdateFailure.checksum,
      }.entries) {
        final wire = Wire();
        final c = host(
          wire: wire,
          fetch: () async => releaseAt('1.5.0'),
          downloader: (asset, {required onProgress, onError}) async {
            onError?.call(entry.key);
            return null;
          },
        );
        await settle(c, wire);
        await c.read(updatesStateProvider.notifier).check();
        await wire.pump();

        await c.read(updatesStateProvider.notifier).updateApp();
        await wire.pump();

        expect(c.read(updatesStateProvider).app,
            UpdateRowState.failed(entry.value),
            reason: '${entry.key}');
      }
    });

    test('a digest that does not verify fails as checksum — nothing installs',
        () async {
      final wire = Wire();
      final installer = FakeInstaller();
      final c = host(
        wire: wire,
        fetch: () async => releaseAt('1.5.0'),
        installer: installer,
        downloader: (asset, {required onProgress, onError}) async =>
            '/cache/x.apk',
        verifier: (file, expectedHex) async => false,
      );
      await settle(c, wire);
      await c.read(updatesStateProvider.notifier).check();
      await wire.pump();

      await c.read(updatesStateProvider.notifier).updateApp();
      await wire.pump();

      expect(c.read(updatesStateProvider).app,
          const UpdateRowState.failed(UpdateFailure.checksum));
      expect(installer.installed, isEmpty);
    });

    test('a platform install failure is the installer failure', () async {
      final wire = Wire();
      final installer = FakeInstaller();
      final c = host(
        wire: wire,
        fetch: () async => releaseAt('1.5.0'),
        installer: installer,
        downloader: (asset, {required onProgress, onError}) async =>
            '/cache/x.apk',
        verifier: (file, expectedHex) async => true,
      );
      await settle(c, wire);
      await c.read(updatesStateProvider.notifier).check();
      await wire.pump();
      await c.read(updatesStateProvider.notifier).updateApp();
      await wire.pump();

      installer.push(const InstallEvent(InstallOutcome.failure, status: 5));
      await wire.pump();

      expect(c.read(updatesStateProvider).app,
          const UpdateRowState.failed(UpdateFailure.installer));
    });
  });

  // -------------------------------------------------------------------------
  group('binding rule 5 — PC success is confirmed by reconnection (D-17)', () {
    test('updatePc sends update.apply with a version and nothing else',
        () async {
      final wire = Wire();
      await wire.connectAndAuth();
      final c = host(wire: wire, fetch: () async => releaseAt('1.5.0'));
      await settle(c, wire);

      c.read(updatesStateProvider.notifier).updatePc('1.5.0');
      await wire.pump();

      final applies = wire.channel.sentMessages.whereType<UpdateApplyMsg>();
      expect(applies, hasLength(1));
      expect(applies.single.toPayload(), {'target': '1.5.0'});
    });

    test('reconnecting re-checks — and the row lands on upToDate', () async {
      final wire = Wire();
      await wire.connectAndAuth();
      final c = host(
          wire: wire,
          installedVersion: '1.5.0',
          fetch: () async => releaseAt('1.5.0'));
      await settle(c, wire);
      await c.read(updatesStateProvider.notifier).check();

      c.read(updatesStateProvider.notifier).updatePc('1.5.0');
      wire.channel.feed(const UpdateProgressMsg(stage: kStageRestarting));
      await wire.pump();
      expect(c.read(updatesStateProvider).pc, const UpdateRowState.restarting());

      // The socket drops (that IS the update), then the FSM redials and auths.
      await wire.dropAndRedial(1);
      wire.channel.feed(ChallengeMsg(nonce: 'ef' * 32));
      await wire.pump();
      wire.channel.feed(const AuthOkMsg());
      await wire.pump();

      expect(wire.channel.sentMessages.whereType<UpdateCheckMsg>(), isNotEmpty,
          reason: 'the re-check on reconnect is what confirms the new version');

      wire.channel.feed(const UpdateStatusMsg(
          serverVersion: '1.5.0', extConnected: false));
      await wire.pump();

      expect(c.read(updatesStateProvider).pc,
          const UpdateRowState.upToDate('1.5.0'));
    });
  });

  // -------------------------------------------------------------------------
  group('the check cadence (D-07)', () {
    test('the quiet launch check produces NO footer checking state and leaves '
        'the previous cached result intact on failure', () async {
      final wire = Wire();
      final prefs = cachePrefs(
        atMillis: DateTime.utc(2026, 8, 1).millisecondsSinceEpoch,
        version: '1.5.0',
      );
      final footers = <CheckFooterKind>[];
      final c = host(
        wire: wire,
        prefs: prefs,
        fetch: () async => null, // the background check fails
        now: DateTime.utc(2026, 8, 4, 12),
      );
      c.listen(updatesStateProvider, (_, next) => footers.add(next.footer.kind),
          fireImmediately: true);
      await settle(c, wire);

      await c.read(updatesStateProvider.notifier).quietLaunchCheck();
      await wire.pump();

      expect(footers, isNot(contains(CheckFooterKind.checking)),
          reason: 'a background check that animates the screen is an '
              'interruption');
      expect(c.read(updatesStateProvider).footer.kind, CheckFooterKind.ok,
          reason: 'a failed background check is silent');
      // Compared as an INSTANT: the cache round-trips epoch millis, so it
      // hands back a local-zone DateTime for the same moment.
      expect(
          c.read(updatesStateProvider).footer.lastCheckedAt
              ?.millisecondsSinceEpoch,
          DateTime.utc(2026, 8, 1).millisecondsSinceEpoch);
      expect(c.read(updateCacheStateProvider).lastSeenVersion, '1.5.0',
          reason: 'the last-good entry is untouched by a failure');
      expect(prefs.map[kUpdateLastCheckAtPrefsKey],
          '${DateTime.utc(2026, 8, 1).millisecondsSinceEpoch}');
    });

    test('the quiet launch check does not fetch inside the 24h window',
        () async {
      final wire = Wire();
      var fetches = 0;
      final c = host(
        wire: wire,
        prefs: cachePrefs(
          atMillis: DateTime.utc(2026, 8, 4, 6).millisecondsSinceEpoch,
          version: '1.5.0',
        ),
        fetch: () async {
          fetches++;
          return releaseAt('1.5.0');
        },
        now: DateTime.utc(2026, 8, 4, 12),
      );
      await settle(c, wire);

      await c.read(updatesStateProvider.notifier).quietLaunchCheck();
      expect(fetches, 0);
    });

    test('a successful check records the cache and moves the footer to ok',
        () async {
      final wire = Wire();
      final prefs = cachePrefs();
      final c = host(
        wire: wire,
        prefs: prefs,
        fetch: () async => releaseAt('1.5.0'),
        now: DateTime.utc(2026, 8, 4, 12),
      );
      await settle(c, wire);
      expect(c.read(updatesStateProvider).footer.kind,
          CheckFooterKind.neverChecked);

      await c.read(updatesStateProvider.notifier).check();
      await wire.pump();

      expect(c.read(updatesStateProvider).footer.kind, CheckFooterKind.ok);
      expect(
          c.read(updatesStateProvider).footer.lastCheckedAt
              ?.millisecondsSinceEpoch,
          DateTime.utc(2026, 8, 4, 12).millisecondsSinceEpoch);
      expect(prefs.map[kUpdateLastSeenVersionPrefsKey], '1.5.0');
    });

    test('ensureChecked checks once, and not again once a result is held',
        () async {
      final wire = Wire();
      var fetches = 0;
      final c = host(wire: wire, fetch: () async {
        fetches++;
        return releaseAt('1.5.0');
      });
      await settle(c, wire);

      c.read(updatesStateProvider.notifier).ensureChecked();
      await wire.pump();
      c.read(updatesStateProvider.notifier).ensureChecked();
      await wire.pump();

      expect(fetches, 1,
          reason: 'a second check per screen open would spend the 60/hour '
              'anonymous budget invisibly');
    });
  });

  // -------------------------------------------------------------------------
  group('the badge truth rule (D-06)', () {
    test('lit for a KNOWN component strictly behind a cached latest', () async {
      final wire = Wire();
      final c = host(
        wire: wire,
        installedVersion: '1.4.0',
        prefs: cachePrefs(atMillis: 1, version: '1.5.0'),
      );
      await settle(c, wire);

      expect(c.read(updateBadgeProvider), isTrue);
      expect(c.read(updatesStateProvider).badge, isTrue,
          reason: 'the screen and the Settings dot read one source');
    });

    test('dark for an ABSENT cache', () async {
      final wire = Wire();
      final c = host(wire: wire, installedVersion: '1.4.0');
      await settle(c, wire);

      expect(c.read(updateBadgeProvider), isFalse);
    });

    test('dark on unknownVersion — an unparseable version is never behind',
        () async {
      final wire = Wire();
      final c = host(
        wire: wire,
        installedVersion: 'not-a-version',
        prefs: cachePrefs(atMillis: 1, version: '1.5.0'),
      );
      await settle(c, wire);

      expect(c.read(updateBadgeProvider), isFalse);
      expect(c.read(updatesStateProvider).app.kind,
          UpdateRowKind.unknownVersion);
    });

    test('dark on an unparseable cached tag', () async {
      final wire = Wire();
      final c = host(
        wire: wire,
        installedVersion: '1.4.0',
        prefs: cachePrefs(atMillis: 1, version: '9.9.9-evil'),
      );
      await settle(c, wire);

      expect(c.read(updateBadgeProvider), isFalse);
    });

    test('dark on couldNotCheck — a failed check never lights it', () async {
      final wire = Wire();
      final c = host(
          wire: wire, installedVersion: '1.4.0', fetch: () async => null);
      await settle(c, wire);

      await c.read(updatesStateProvider.notifier).check();
      await wire.pump();

      expect(c.read(updatesStateProvider).app.kind,
          UpdateRowKind.couldNotCheck);
      expect(c.read(updateBadgeProvider), isFalse);
      expect(c.read(updatesStateProvider).badge, isFalse);
    });

    test('dark on serverDisconnected — an unknown PC cannot light it',
        () async {
      final wire = Wire(); // no socket at all
      final c = host(
        wire: wire,
        installedVersion: '1.5.0', // the phone itself is current
        prefs: cachePrefs(atMillis: 1, version: '1.5.0'),
      );
      await settle(c, wire);

      expect(c.read(updatesStateProvider).pc,
          const UpdateRowState.serverDisconnected());
      expect(c.read(updateBadgeProvider), isFalse);
    });

    test('dark on serverTooOld — the same, through the 1.7 refusal', () async {
      final wire = Wire();
      await wire.connectAndAuth();
      final c = host(
        wire: wire,
        installedVersion: '1.5.0',
        prefs: cachePrefs(atMillis: 1, version: '1.5.0'),
      );
      await settle(c, wire);

      wire.service.sendUpdateCheck();
      await wire.pump();
      wire.channel.feed(const ErrMsg(code: kUnknownTypeErrCode, msg: 'no'));
      await wire.pump();

      expect(c.read(updatesStateProvider).pc,
          const UpdateRowState.serverTooOld());
      expect(c.read(updateBadgeProvider), isFalse);
    });

    test('a KNOWN PC behind the cached latest lights it, and it clears the '
        'moment that PC reaches upToDate', () async {
      final wire = Wire();
      await wire.connectAndAuth();
      final c = host(
        wire: wire,
        installedVersion: '1.5.0',
        prefs: cachePrefs(atMillis: 1, version: '1.5.0'),
      );
      await settle(c, wire);
      expect(c.read(updateBadgeProvider), isFalse);

      wire.channel.feed(const UpdateStatusMsg(
          serverVersion: '1.4.0', extConnected: false));
      await wire.pump();
      expect(c.read(updateBadgeProvider), isTrue);

      wire.channel.feed(const UpdateStatusMsg(
          serverVersion: '1.5.0', extConnected: false));
      await wire.pump();
      expect(c.read(updateBadgeProvider), isFalse,
          reason: 'no dismiss gesture and no seen flag — the dot clears when '
              'the condition does');
    });

    test('a KNOWN extension behind the cached latest lights it too', () async {
      final wire = Wire();
      await wire.connectAndAuth();
      final c = host(
        wire: wire,
        installedVersion: '1.5.0',
        prefs: cachePrefs(atMillis: 1, version: '1.5.0'),
      );
      await settle(c, wire);

      wire.channel.feed(const UpdateStatusMsg(
        serverVersion: '1.5.0',
        extConnected: true,
        extVersion: '1.4.0',
      ));
      await wire.pump();

      expect(c.read(updateBadgeProvider), isTrue);
    });

    test('a cache older than the TTL still lights it — a version comparison '
        'does not expire', () async {
      final wire = Wire();
      final c = host(
        wire: wire,
        installedVersion: '1.4.0',
        prefs: cachePrefs(
          atMillis: DateTime.utc(2026, 1, 1).millisecondsSinceEpoch,
          version: '1.5.0',
        ),
        now: DateTime.utc(2026, 8, 4, 12),
      );
      await settle(c, wire);

      expect(c.read(updateBadgeProvider), isTrue,
          reason: 'update_cache.dart: a failed check leaves the last-good '
              'entry and the badge keeps its last known answer');
    });

    test('badgeLit is a pure function of the three inputs', () {
      expect(
          badgeLit(cachedLatest: null, appInstalled: '1.4.0', status: null),
          isFalse);
      expect(
          badgeLit(cachedLatest: '1.5.0', appInstalled: null, status: null),
          isFalse);
      expect(
          badgeLit(cachedLatest: '1.5.0', appInstalled: '1.4.0', status: null),
          isTrue);
      expect(
        badgeLit(
          cachedLatest: '1.5.0',
          appInstalled: '1.5.0',
          status: const UpdateStatusSnapshot(
              serverVersion: 'junk', extConnected: false),
        ),
        isFalse,
        reason: 'UNKNOWN IS NEVER BEHIND',
      );
    });
  });

  // -------------------------------------------------------------------------
  group('no persisted installing flag (T-12-50)', () {
    test('an install in flight writes nothing to the cache prefs', () async {
      final wire = Wire();
      final prefs = cachePrefs();
      final c = host(
        wire: wire,
        prefs: prefs,
        fetch: () async => releaseAt('1.5.0'),
        downloader: (asset, {required onProgress, onError}) async =>
            '/cache/x.apk',
        verifier: (file, expectedHex) async => true,
        now: DateTime.utc(2026, 8, 4, 12),
      );
      await settle(c, wire);
      await c.read(updatesStateProvider.notifier).check();
      await wire.pump();

      await c.read(updatesStateProvider.notifier).updateApp();
      await wire.pump();
      expect(c.read(updatesStateProvider).app, const UpdateRowState.installing());

      // Only the two D-07 cache keys exist; there is no install marker for a
      // fresh launch to read as stuck.
      expect(prefs.map.keys.toSet(), {
        kUpdateLastCheckAtPrefsKey,
        kUpdateLastSeenVersionPrefsKey,
      });
    });
  });

  // -------------------------------------------------------------------------
  group('the file itself', () {
    test('carries no legacy StateNotifier and starts no timer', () {
      final source =
          File('lib/update/update_providers.dart').readAsStringSync();
      expect(source.contains('StateNotifier'), isFalse,
          reason: 'Riverpod 3 unified Notifier only');
      expect(RegExp(r'\bTimer\s*[(.]').hasMatch(source), isFalse,
          reason: 'D-17: the existing reconnect FSM is the only reconnect '
              'mechanism — this phase starts no timer of its own');
    });
  });
}
