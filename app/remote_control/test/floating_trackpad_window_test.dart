// Task 1 (08-04, Wave 2) — FloatingTrackpadWindow safety net (RED until Task 2
// creates the widget). Pins the five load-bearing D8-03 contracts of the
// expanded-state floating trackpad card:
//
//  1. header-drag moves + clamps — dragging the ⠿ header handle shifts the
//     card's Positioned offset, and dragging far past a screen edge commits
//     windowPositionProvider fractions that stay within [0,1] (fully
//     on-screen, T-08-06 / SC3).
//  2. surface-is-mouse — a pan that starts on the TrackpadCore gesture surface
//     does NOT move the window (the header GestureDetector and the core
//     Listener are spatially-disjoint SIBLINGS — RESEARCH Pitfall 2).
//  3. header buttons — tapping ⤢ fires the injected onExpandFull, tapping ✕
//     fires onCollapse.
//  4. drag-lock pill — the inline header pill is hidden by default and shown
//     when the injected drag-lock listenable is true (the seam the TrackpadCore
//     drives via onDragLockChanged).
//  5. no-overflow — at a short 360×640 surface the card's three rows (header +
//     surface + MouseButtonsBar) fit with no RenderFlex overflow (the A2
//     short-device guard).
//
// The service seam is a recording ConnectionService subclass (TrackpadCore
// reads connectionServiceProvider on mount); the keep-awake seam is an injected
// spy so the test never touches the wakelock platform channel.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_protocol/remote_protocol.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'package:remote_control/net/connection_providers.dart';
import 'package:remote_control/net/connection_service.dart';
import 'package:remote_control/store/device_store.dart';
import 'package:remote_control/trackpad/floating_trackpad_window.dart';
import 'package:remote_control/trackpad/trackpad_core.dart';
import 'package:remote_control/widgets/keep_awake.dart';

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

/// Recording ConnectionService: satisfies the TrackpadCore hot-path read with a
/// settable [isAuthed]; captures nothing the window tests assert on directly.
class _RecordingService extends ConnectionService {
  _RecordingService()
      : super(
          store: DeviceStore(secure: _FakeSecureKv(), prefs: _FakePrefsKv()),
        );

  final List<(double, double)> moves = [];
  final List<RemoteMessage> reliable = [];
  bool authed = false;

  @override
  bool get isAuthed => authed;

  @override
  ChipStatus get chipStatus =>
      authed ? ChipStatus.connected : ChipStatus.disconnected;

  @override
  void sendMove(double dx, double dy) => moves.add((dx, dy));

  @override
  void sendReliable(RemoteMessage msg) => reliable.add(msg);
}

const Key _cardKey = Key('floating-trackpad-card');
const Key _pillKey = Key('window-drag-lock-pill');

KeepAwake _spyKeep() => KeepAwake(enable: () async {}, disable: () async {});

Widget _host(ConnectionService service, Widget window) => ProviderScope(
      overrides: [
        connectionServiceProvider.overrideWith((ref) => service),
      ],
      child: MaterialApp(home: Scaffold(body: Stack(children: [window]))),
    );

/// The card's own Positioned (the single Positioned that is an ancestor of the
/// card key) — the window places itself via left/top.
Positioned _cardPositioned(WidgetTester t) => t.widget<Positioned>(
      find
          .ancestor(
            of: find.byKey(_cardKey),
            matching: find.byType(Positioned),
          )
          .first,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // TrackpadCore's window-position sibling loads via SharedPreferencesAsync;
    // back it with the in-memory async fake so no plugin channel is hit.
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
  });

  group('FloatingTrackpadWindow — header drag moves + clamps (SC3, T-08-06)',
      () {
    testWidgets('dragging the header handle shifts the card offset', (t) async {
      final service = _RecordingService();
      await t.pumpWidget(
        _host(
          service,
          FloatingTrackpadWindow(
            authed: true,
            onExpandFull: () {},
            onCollapse: () {},
            onMouseButton: (_) {},
            keepAwake: _spyKeep(),
          ),
        ),
      );

      final before = _cardPositioned(t);
      await t.drag(find.byIcon(Icons.drag_indicator), const Offset(30, 40));
      await t.pump();
      final after = _cardPositioned(t);

      expect(after.left, greaterThan(before.left!),
          reason: 'a header-handle pan must move the window right');
      expect(after.top, greaterThan(before.top!),
          reason: 'a header-handle pan must move the window down');
    });

    testWidgets('dragging far past an edge commits fractions within [0,1]',
        (t) async {
      final service = _RecordingService();
      await t.pumpWidget(
        _host(
          service,
          FloatingTrackpadWindow(
            authed: true,
            onExpandFull: () {},
            onCollapse: () {},
            onMouseButton: (_) {},
            keepAwake: _spyKeep(),
          ),
        ),
      );

      // Drag the header handle far beyond the bottom-right corner.
      await t.drag(find.byIcon(Icons.drag_indicator), const Offset(4000, 4000));
      await t.pump();

      final container = ProviderScope.containerOf(
        t.element(find.byType(FloatingTrackpadWindow)),
      );
      final pos = container.read(windowPositionProvider);

      expect(pos.isSet, isTrue,
          reason: 'a header drag persists a real (moved) position');
      expect(pos.xFraction, inInclusiveRange(0.0, 1.0),
          reason: 'the committed x fraction must keep the card on-screen');
      expect(pos.yFraction, inInclusiveRange(0.0, 1.0),
          reason: 'the committed y fraction must keep the card on-screen');
    });
  });

  group('FloatingTrackpadWindow — surface touches are mouse input (Pitfall 2)',
      () {
    testWidgets('a pan on the gesture surface does NOT move the window',
        (t) async {
      final service = _RecordingService()..authed = true;
      await t.pumpWidget(
        _host(
          service,
          FloatingTrackpadWindow(
            authed: true,
            onExpandFull: () {},
            onCollapse: () {},
            onMouseButton: (_) {},
            keepAwake: _spyKeep(),
          ),
        ),
      );

      final before = _cardPositioned(t);
      // A drag that STARTS on the TrackpadCore surface — pure mouse input.
      await t.drag(find.byType(TrackpadCore), const Offset(60, 60));
      // Flush the armed (then disarmed) long-press one-shot Timer.
      await t.pump(const Duration(seconds: 1));
      final after = _cardPositioned(t);

      expect(after.left, before.left,
          reason: 'a surface pan is mouse movement, never a window move');
      expect(after.top, before.top,
          reason: 'a surface pan is mouse movement, never a window move');
    });
  });

  group('FloatingTrackpadWindow — header buttons fire injected callbacks', () {
    testWidgets('⤢ fires onExpandFull and ✕ fires onCollapse', (t) async {
      final service = _RecordingService();
      var expanded = 0;
      var collapsed = 0;
      await t.pumpWidget(
        _host(
          service,
          FloatingTrackpadWindow(
            authed: true,
            onExpandFull: () => expanded++,
            onCollapse: () => collapsed++,
            onMouseButton: (_) {},
            keepAwake: _spyKeep(),
          ),
        ),
      );

      await t.tap(find.byIcon(Icons.open_in_full));
      await t.pump();
      expect(expanded, 1);
      expect(collapsed, 0);

      await t.tap(find.byIcon(Icons.close));
      await t.pump();
      expect(collapsed, 1);
      expect(expanded, 1);
    });
  });

  group('FloatingTrackpadWindow — inline drag-lock pill tracks the listenable',
      () {
    testWidgets('pill is hidden by default and shown when drag-lock is true',
        (t) async {
      final service = _RecordingService();
      final dragLock = ValueNotifier<bool>(false);
      addTearDown(dragLock.dispose);

      await t.pumpWidget(
        _host(
          service,
          FloatingTrackpadWindow(
            authed: true,
            onExpandFull: () {},
            onCollapse: () {},
            onMouseButton: (_) {},
            keepAwake: _spyKeep(),
            dragLock: dragLock,
          ),
        ),
      );

      expect(find.byKey(_pillKey), findsNothing,
          reason: 'the header pill is hidden while drag-lock is off');

      dragLock.value = true;
      await t.pump();

      expect(find.byKey(_pillKey), findsOneWidget,
          reason: 'the header pill appears while drag-lock is engaged');
    });
  });

  group('FloatingTrackpadWindow — A2 short-device no-overflow guard', () {
    testWidgets('the three rows fit a 360×640 surface with no overflow',
        (t) async {
      final service = _RecordingService();
      await t.pumpWidget(
        _host(
          service,
          MediaQuery(
            data: const MediaQueryData(size: Size(360, 640)),
            child: FloatingTrackpadWindow(
              authed: true,
              onExpandFull: () {},
              onCollapse: () {},
              onMouseButton: (_) {},
              keepAwake: _spyKeep(),
            ),
          ),
        ),
      );

      expect(t.takeException(), isNull,
          reason: 'the card must not overflow on a short device (A2)');
    });
  });
}
