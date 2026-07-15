// Task 1 (08-02, Wave 0) — TrackpadScreen composition smoke test.
//
// The behavior-neutrality safety net for the D8-04 extraction: this pins the
// chrome the slimmed screen must still render AFTER TrackpadCore is carved out
// of _TrackpadScreenState. It is green against the CURRENT (fat) screen and
// must stay green after Task 3 slims it — that green-through-the-refactor is
// the extraction's behavior-neutral guarantee (RESEARCH Pitfall 7: no
// trackpad_screen_test.dart existed before this plan).
//
// House harness idiom (quick_bar_test.dart): a ProviderScope override gives
// the screen an in-memory fake-KV-backed ConnectionService — no sockets, no
// platform channels. The global keep-awake singleton (which the fat screen
// acquires in initState) routes through a no-op WakelockPlus platform stub so
// the plugin call never throws in the test harness.

// The wakelock platform-interface import is a test-only stub seam; it is a
// transitive (not direct) dependency, hence the file-scoped ignore.
// ignore_for_file: depend_on_referenced_packages

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:wakelock_plus_platform_interface/wakelock_plus_platform_interface.dart';

import 'package:remote_control/net/connection_providers.dart';
import 'package:remote_control/net/connection_service.dart';
import 'package:remote_control/screens/connection_copy.dart';
import 'package:remote_control/store/device_store.dart';
import 'package:remote_control/trackpad/mouse_buttons.dart';
import 'package:remote_control/trackpad/trackpad_screen.dart';

/// No-op wakelock platform so the screen's keep-awake acquire/release never
/// hits an (absent) plugin in the test harness.
class _NoopWakelock extends WakelockPlusPlatformInterface {
  @override
  Future<void> toggle({required bool enable}) async {}

  @override
  Future<bool> get enabled async => false;
}

class _FakeSecureKv implements SecureKv {
  final Map<String, String> backing = {};

  @override
  Future<String?> read(String key) async => backing[key];

  @override
  Future<void> write(String key, String value) async => backing[key] = value;

  @override
  Future<void> delete(String key) async => backing.remove(key);
}

class _FakePrefsKv implements PrefsKv {
  final Map<String, String> backing = {};

  @override
  Future<String?> getString(String key) async => backing[key];

  @override
  Future<void> setString(String key, String value) async {
    backing[key] = value;
  }
}

Widget _host() => ProviderScope(
      overrides: [
        connectionServiceProvider.overrideWith(
          (ref) => ConnectionService(
            store: DeviceStore(secure: _FakeSecureKv(), prefs: _FakePrefsKv()),
          ),
        ),
      ],
      child: const MaterialApp(home: TrackpadScreen()),
    );

void main() {
  setUpAll(() {
    wakelockPlusPlatformInstance = _NoopWakelock();
  });

  testWidgets('renders the surface hint + L/M/R bar + tune + keyboard toggle',
      (t) async {
    await t.pumpWidget(_host());
    await t.pump();

    // The gesture surface hint (not connected in the harness — idle service).
    expect(find.text(kTrackpadHintNotConnected), findsOneWidget);

    // The docked L/M/R mouse-button bar (PAD-02).
    expect(find.byType(MouseButtonsBar), findsOneWidget);
    expect(find.text('L'), findsOneWidget);
    expect(find.text('M'), findsOneWidget);
    expect(find.text('R'), findsOneWidget);

    // The bottom-right cluster: tune affordance (D-05) + keyboard toggle (D-07).
    expect(find.byIcon(Icons.tune), findsOneWidget);
    expect(find.byIcon(Icons.keyboard), findsOneWidget);

    // Dispose the tree so the header chip's throttle timer is cancelled and
    // the keep-awake hold is released before the harness tears down.
    await t.pumpWidget(const SizedBox());
  });
}
