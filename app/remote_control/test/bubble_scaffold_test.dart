// Task 1 (08-05, Wave 3) — BubbleScaffold safety net (RED until Task 2 creates
// the widget). Supersedes test/quick_bar_test.dart (08-06 deletes it). Pins
// the D8-01/D8-05/D8-07/D8-08 must_haves:
//
//  1. presence — showBubble:true renders the TrackpadBubble over the body and
//     the UipiBanner host is present.
//  2. absence — showBubble:false renders NEITHER TrackpadBubble NOR
//     FloatingTrackpadWindow, but the UipiBanner slot still rides (the
//     Trackpad-screen wrap).
//  3. expand toggle (never both visible, D8-01) — tapping the bubble replaces
//     it with a FloatingTrackpadWindow (bubble gone); tapping the window's ✕
//     collapses back to the bubble (window gone).
//  4. body-hit-testable — a tappable widget in the body OUTSIDE the window's
//     card rect still receives a tap while the window is open (the body is a
//     Positioned.fill SIBLING of the expand-gated subtree, never rebuilt off
//     it — Pitfall 3/6).
//  5. back-intercept (D8-08) — a system back while expanded collapses the
//     window (PopScope) instead of popping the route; a second back pops.
//
// House pattern: ProviderScope override gives the scaffold a recording
// ConnectionService (mirrors floating_trackpad_window_test.dart's
// _RecordingService) + an in-memory SharedPreferencesAsync double backing the
// bubble/window position providers TrackpadBubble/FloatingTrackpadWindow read.

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'package:remote_control/net/connection_providers.dart';
import 'package:remote_control/net/connection_service.dart';
import 'package:remote_control/store/device_store.dart';
import 'package:remote_control/trackpad/floating_trackpad_window.dart';
import 'package:remote_control/widgets/bubble_scaffold.dart';
import 'package:remote_control/widgets/trackpad_bubble.dart';
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

/// Recording ConnectionService with a settable [authed] flag (mirrors
/// floating_trackpad_window_test.dart's `_RecordingService`).
class _RecordingService extends ConnectionService {
  _RecordingService()
      : super(
          store: DeviceStore(secure: _FakeSecureKv(), prefs: _FakePrefsKv()),
        );

  bool authed = false;

  @override
  bool get isAuthed => authed;

  @override
  ChipStatus get chipStatus =>
      authed ? ChipStatus.connected : ChipStatus.disconnected;
}

Widget _host({
  required bool showBubble,
  ConnectionService? service,
  Widget? body,
}) =>
    ProviderScope(
      overrides: [
        connectionServiceProvider.overrideWith(
          (ref) => service ?? _RecordingService(),
        ),
      ],
      child: MaterialApp(
        home: BubbleScaffold(
          showBubble: showBubble,
          body: body ?? const Scaffold(body: Center(child: Text('tool body'))),
        ),
      ),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // TrackpadBubble / FloatingTrackpadWindow load their position via
    // SharedPreferencesAsync; back it with the in-memory async fake so no
    // plugin channel is hit.
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
  });

  testWidgets(
      'showBubble:true renders the TrackpadBubble over the body and hosts '
      'the UipiBanner', (t) async {
    await t.pumpWidget(_host(showBubble: true));

    expect(find.text('tool body'), findsOneWidget);
    expect(find.byType(TrackpadBubble), findsOneWidget);
    expect(find.byType(UipiBanner), findsOneWidget);
  });

  testWidgets(
      'showBubble:false hides the bubble/window but keeps the banner host '
      '(the Trackpad-screen wrap)', (t) async {
    await t.pumpWidget(_host(showBubble: false));

    expect(find.text('tool body'), findsOneWidget);
    expect(find.byType(TrackpadBubble), findsNothing);
    expect(find.byType(FloatingTrackpadWindow), findsNothing);
    expect(find.byType(UipiBanner), findsOneWidget);
  });

  testWidgets(
      'tapping the bubble expands to the FloatingTrackpadWindow (never both '
      'visible, D8-01); the window ✕ collapses back to the bubble', (t) async {
    await t.pumpWidget(_host(showBubble: true));

    expect(find.byType(TrackpadBubble), findsOneWidget);
    expect(find.byType(FloatingTrackpadWindow), findsNothing);

    await t.tap(find.byIcon(Symbols.touch_app_rounded));
    await t.pumpAndSettle();

    expect(find.byType(TrackpadBubble), findsNothing,
        reason: 'the bubble and window are never both visible (D8-01)');
    expect(find.byType(FloatingTrackpadWindow), findsOneWidget);

    await t.tap(find.byIcon(Symbols.close_rounded));
    await t.pumpAndSettle();

    expect(find.byType(FloatingTrackpadWindow), findsNothing);
    expect(find.byType(TrackpadBubble), findsOneWidget);
  });

  testWidgets(
      'the tool body outside the window rect stays hit-testable while the '
      'window is open (Positioned.fill sibling, Pitfall 3/6)', (t) async {
    var bodyTaps = 0;
    await t.pumpWidget(
      _host(
        showBubble: true,
        body: Scaffold(
          body: Align(
            // Top-left corner — well outside the centered ~78%w x 38%h card.
            alignment: Alignment.topLeft,
            child: TextButton(
              onPressed: () => bodyTaps++,
              child: const Text('body tap target'),
            ),
          ),
        ),
      ),
    );

    await t.tap(find.byIcon(Symbols.touch_app_rounded));
    await t.pumpAndSettle();
    expect(find.byType(FloatingTrackpadWindow), findsOneWidget);

    await t.tap(find.text('body tap target'));
    await t.pump();

    expect(bodyTaps, 1,
        reason: 'the body is a Positioned.fill sibling that never rebuilds '
            'off expand and stays hit-testable around the open window');
  });

  testWidgets(
      'a system back while expanded collapses the window first (PopScope, '
      'D8-08); a second back pops the route', (t) async {
    final navKey = GlobalKey<NavigatorState>();

    await t.pumpWidget(
      ProviderScope(
        overrides: [
          connectionServiceProvider.overrideWith(
            (ref) => _RecordingService(),
          ),
        ],
        child: MaterialApp(
          navigatorKey: navKey,
          home: const Scaffold(body: Center(child: Text('root'))),
        ),
      ),
    );

    navKey.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => const BubbleScaffold(
          body: Scaffold(body: Center(child: Text('tool body'))),
        ),
      ),
    );
    await t.pumpAndSettle();

    await t.tap(find.byIcon(Symbols.touch_app_rounded));
    await t.pumpAndSettle();
    expect(find.byType(FloatingTrackpadWindow), findsOneWidget);

    // Simulate a system (Android hardware/gesture) back button.
    await t.binding.handlePopRoute();
    await t.pumpAndSettle();

    expect(find.byType(FloatingTrackpadWindow), findsNothing,
        reason: 'the first back collapses the window, not the route');
    expect(find.byType(TrackpadBubble), findsOneWidget);
    expect(find.text('tool body'), findsOneWidget,
        reason: 'the first back must NOT pop the route');

    // A second back now pops the route back to root.
    await t.binding.handlePopRoute();
    await t.pumpAndSettle();

    expect(find.text('root'), findsOneWidget);
    expect(find.text('tool body'), findsNothing);
  });
}
