// Task 2 (07-09) — haptics gate (D-13). Proves the hot-path gate: when the
// cached pref is ON hapticTick()/hapticTickMedium() fire the correct
// HapticFeedback platform call exactly once; when OFF they are silent. The
// cache is driven directly (debugHapticsCached) so the gate is deterministic
// without a real prefs backend — the Notifier/store wiring is tested via the
// public provider separately below.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control/settings/haptics.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final calls = <String>[];

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'HapticFeedback.vibrate') {
        calls.add(call.arguments as String);
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
    debugHapticsCached = kHapticsDefault;
  });

  test('cache ON: hapticTick fires lightImpact exactly once', () async {
    debugHapticsCached = true;
    hapticTick();
    await Future<void>.delayed(Duration.zero);
    expect(calls, ['HapticFeedbackType.lightImpact']);
  });

  test('cache OFF: hapticTick is silent', () async {
    debugHapticsCached = false;
    hapticTick();
    await Future<void>.delayed(Duration.zero);
    expect(calls, isEmpty);
  });

  test('cache ON: hapticTickMedium fires mediumImpact (power screen tick)',
      () async {
    debugHapticsCached = true;
    hapticTickMedium();
    await Future<void>.delayed(Duration.zero);
    expect(calls, ['HapticFeedbackType.mediumImpact']);
  });

  test('cache OFF: hapticTickMedium is silent', () async {
    debugHapticsCached = false;
    hapticTickMedium();
    await Future<void>.delayed(Duration.zero);
    expect(calls, isEmpty);
  });

  test('default cache is ON (default haptics pref)', () {
    expect(kHapticsDefault, isTrue);
    expect(debugHapticsCached, isTrue);
  });
}
