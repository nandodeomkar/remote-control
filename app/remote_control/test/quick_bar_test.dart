// Task 2 (07-13) — the persistent Trackpad quick-bar (D-10, 07-UI-SPEC §3).
//
// QuickBarScaffold wraps every tool screen: a 56px bottom bar with ONE
// accent Icons.touch_app + "Trackpad" shortcut, present on wrapped tool
// screens and ABSENT when showQuickBar:false (the Trackpad screen itself).
// The scaffold also hosts the UipiBanner (07-11) in both modes without
// intercepting touch on the body.
//
// House pattern: ProviderScope override gives the scaffold an in-memory
// fake-KV-backed ConnectionService (the UipiBanner seam) — no platform
// channels, no sockets.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:remote_control/net/connection_providers.dart';
import 'package:remote_control/net/connection_service.dart';
import 'package:remote_control/store/device_store.dart';
import 'package:remote_control/theme/tokens.dart';
import 'package:remote_control/widgets/quick_bar_scaffold.dart';
import 'package:remote_control/widgets/uipi_banner.dart';

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

Widget _host({required bool showQuickBar, Widget? body}) => ProviderScope(
      overrides: [
        connectionServiceProvider.overrideWith(
          (ref) => ConnectionService(
            store: DeviceStore(secure: _FakeSecureKv(), prefs: _FakePrefsKv()),
          ),
        ),
      ],
      child: MaterialApp(
        home: QuickBarScaffold(
          showQuickBar: showQuickBar,
          body: body ??
              const Scaffold(body: Center(child: Text('tool body'))),
        ),
      ),
    );

void main() {
  testWidgets('the Trackpad quick-bar renders on a wrapped tool screen '
      '(accent icon + label) and hosts the UipiBanner', (t) async {
    await t.pumpWidget(_host(showQuickBar: true));

    // The body renders above the bar.
    expect(find.text('tool body'), findsOneWidget);

    // The reserved accent affordance: Icons.touch_app + "Trackpad", kAccent.
    expect(find.text(kQuickBarLabel), findsOneWidget);
    final icon = t.widget<Icon>(find.byIcon(Icons.touch_app));
    expect(icon.color, kAccent, reason: 'the quick-bar icon is the reserved '
        'accent affordance (07-UI-SPEC §3)');
    final label = t.widget<Text>(find.text(kQuickBarLabel));
    expect(label.style?.color, kAccent);

    // The scaffold composes the UIPI banner host (07-11).
    expect(find.byType(UipiBanner), findsOneWidget);
  });

  testWidgets('showQuickBar:false (the Trackpad screen) hides the shortcut '
      'but keeps the banner host', (t) async {
    await t.pumpWidget(_host(showQuickBar: false));

    expect(find.text('tool body'), findsOneWidget);
    expect(find.text(kQuickBarLabel), findsNothing);
    expect(find.byIcon(Icons.touch_app), findsNothing);
    expect(find.byType(UipiBanner), findsOneWidget);
  });

  testWidgets('the banner overlay never intercepts touch on the body',
      (t) async {
    var taps = 0;
    await t.pumpWidget(
      _host(
        showQuickBar: true,
        body: Scaffold(
          body: Align(
            // Under the top-anchored banner slot — the overlay must let the
            // touch through (UipiBanner is IgnorePointer-wrapped).
            alignment: Alignment.topCenter,
            child: TextButton(
              onPressed: () => taps++,
              child: const Text('tap me'),
            ),
          ),
        ),
      ),
    );

    await t.tap(find.text('tap me'));
    await t.pump();
    expect(taps, 1);
  });
}
