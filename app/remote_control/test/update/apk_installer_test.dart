// Task 1 (12-08) — the `remote_control/installer` MethodChannel contract
// (D-19). Two halves:
//
//   * with NO handler registered (a widget test, or any non-Android host) every
//     method is a silent no-op with a safe default — canInstall() is true so
//     the explainer sheet never opens spuriously, cacheDir() is null so the
//     download path falls back to systemTemp, and install() /
//     openInstallPermission() complete without throwing;
//   * with a mocked handler, each method invokes the expected platform method
//     name with the expected arguments, and a reverse `outcome` call from the
//     platform reaches the caller's seam.
//
// Success is NOT among the outcomes: replacing the APK kills this process
// (RESEARCH Pitfall 7), so there is nothing to assert about it.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control/update/apk_installer.dart';

const _channel = MethodChannel('remote_control/installer');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(_channel, null);
  });

  /// Push a platform -> framework `outcome` call, as InstallResultReceiver does.
  Future<void> pushOutcome(String outcome, {int? status}) async {
    await messenger.handlePlatformMessage(
      _channel.name,
      const StandardMethodCodec().encodeMethodCall(
        MethodCall('outcome', <String, Object?>{
          'outcome': outcome,
          'status': status,
        }),
      ),
      (_) {},
    );
  }

  group('no handler registered (widget test / non-Android host)', () {
    test('canInstall() is true, so the explainer sheet never opens', () async {
      expect(await ApkInstaller().canInstall(), isTrue);
    });

    test('cacheDir() is null, so the caller falls back to systemTemp', () async {
      expect(await ApkInstaller().cacheDir(), isNull);
    });

    test('install() completes without throwing', () async {
      await expectLater(ApkInstaller().install('/tmp/x.apk'), completes);
    });

    test('openInstallPermission() completes without throwing', () async {
      await expectLater(ApkInstaller().openInstallPermission(), completes);
    });
  });

  group('mocked platform handler', () {
    late List<MethodCall> calls;

    setUp(() {
      calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(_channel, (call) async {
        calls.add(call);
        return switch (call.method) {
          'canInstall' => false,
          'cacheDir' => '/data/user/0/dev.omkar.remotecontrol/cache',
          _ => null,
        };
      });
    });

    test('canInstall() forwards the platform answer verbatim', () async {
      expect(await ApkInstaller().canInstall(), isFalse);
      expect(calls.single.method, 'canInstall');
    });

    test('cacheDir() returns the platform path', () async {
      expect(
        await ApkInstaller().cacheDir(),
        '/data/user/0/dev.omkar.remotecontrol/cache',
      );
      expect(calls.single.method, 'cacheDir');
    });

    test('openInstallPermission() invokes the settings method', () async {
      await ApkInstaller().openInstallPermission();
      expect(calls.single.method, 'openInstallPermission');
    });

    test('install() passes the apk path under "path"', () async {
      await ApkInstaller().install('/cache/RemoteControl-v1.5.0.apk');
      expect(calls.single.method, 'install');
      expect(
        (calls.single.arguments as Map)['path'],
        '/cache/RemoteControl-v1.5.0.apk',
      );
    });
  });

  group('outcome seam', () {
    test('a declined system dialog reaches the caller', () async {
      final installer = ApkInstaller();
      final seen = installer.outcomes.first;
      await pushOutcome('declined');
      expect((await seen).outcome, InstallOutcome.declined);
    });

    test('pendingUserAction reaches the caller', () async {
      final installer = ApkInstaller();
      final seen = installer.outcomes.first;
      await pushOutcome('pendingUserAction');
      expect((await seen).outcome, InstallOutcome.pendingUserAction);
    });

    test('failure carries the numeric status (5 = CONFLICT)', () async {
      final installer = ApkInstaller();
      final seen = installer.outcomes.first;
      await pushOutcome('failure', status: 5);
      final event = await seen;
      expect(event.outcome, InstallOutcome.failure);
      expect(event.status, 5);
    });

    test('success is not an outcome the enum can express', () {
      expect(
        InstallOutcome.values.map((o) => o.name),
        isNot(contains('success')),
      );
    });
  });
}
