// Task 1 (08-02, Wave 0) — TrackpadCore extraction safety net (RED until
// Task 2 creates the widget). Pins the three load-bearing contracts the
// D8-04 hot-path extraction must preserve:
//
//  1. The pointer route is wired end-to-end: pointer events on a mounted
//     TrackpadCore (built with the REAL classifier + driver) flow
//     classifier -> driver -> ConnectionService — a drag records moves and a
//     tap records a left ClickMsg on the reliable channel.
//  2. CR-01 4-quadrant dispose flush: unmounting the core sends
//     DragMsg(end, left) via sendReliable ONLY when the driver is drag-locked
//     AND the service is authed; nothing in the other three quadrants (no
//     stuck mouse button behind a collapsed surface — SC5, T-08-03).
//  3. keepAwake is acquired on mount and released on dispose (the core is the
//     SOLE owner — RESEARCH Pitfall 4), proven via an injected spy KeepAwake.
//
// The service seam is a recording ConnectionService subclass with a settable
// isAuthed so the flush guard is driven deterministically; the driver seam is
// injected in the 4-quadrant test so drag-lock is set by hand.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_protocol/remote_protocol.dart';

import 'package:remote_control/net/connection_providers.dart';
import 'package:remote_control/net/connection_service.dart';
import 'package:remote_control/store/device_store.dart';
import 'package:remote_control/trackpad/gesture_classifier.dart';
import 'package:remote_control/trackpad/trackpad_core.dart';
import 'package:remote_control/trackpad/trackpad_driver.dart';
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

/// Recording ConnectionService: captures the hot-path sends and the CR-01
/// dispose flush, with a settable [isAuthed] so the flush guard is driven
/// deterministically (the real gating lives in the base class we bypass here).
class _RecordingService extends ConnectionService {
  _RecordingService()
      : super(
          store: DeviceStore(secure: _FakeSecureKv(), prefs: _FakePrefsKv()),
        );

  final List<(double, double)> moves = [];
  final List<(double, double)> scrolls = [];
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
  void sendScroll(double dx, double dy) => scrolls.add((dx, dy));

  @override
  void sendReliable(RemoteMessage msg) => reliable.add(msg);
}

Widget _host(ConnectionService service, Widget child) => ProviderScope(
      overrides: [
        connectionServiceProvider.overrideWith((ref) => service),
      ],
      child: MaterialApp(home: Scaffold(body: child)),
    );

/// A silent-schedule driver: no real Timers, so unmount leaves nothing pending.
TrackpadDriver _inertDriver() => TrackpadDriver(
      onSendMove: (_, _) {},
      onSendScroll: (_, _) {},
      onSendZoom: (_, _) {},
      onSendReliable: (_) {},
      onHaptic: () {},
      onDragLockChanged: (_) {},
      onLongPressElapsed: () {},
      sensitivity: () => 1.0,
      schedule: (_, _) {},
    );

void main() {
  group('TrackpadCore — pointer route (classifier -> driver -> service)', () {
    testWidgets('a single-finger drag records moves on the service', (t) async {
      final service = _RecordingService();
      final dragLock = ValueNotifier<bool>(false);
      final keep = KeepAwake(enable: () async {}, disable: () async {});
      await t.pumpWidget(
        _host(
          service,
          TrackpadCore(authed: true, dragLock: dragLock, keepAwake: keep),
        ),
      );

      final gesture = await t.startGesture(const Offset(150, 300));
      await gesture.moveBy(const Offset(40, 0));
      await gesture.moveBy(const Offset(40, 0));
      await gesture.up();
      // Flush the armed (then disarmed) long-press one-shot Timer.
      await t.pump(const Duration(seconds: 1));

      expect(service.moves, isNotEmpty,
          reason: 'pointer moves must reach the service via the driver');
      dragLock.dispose();
    });

    testWidgets('a tap records a left ClickMsg on the reliable channel',
        (t) async {
      final service = _RecordingService();
      final dragLock = ValueNotifier<bool>(false);
      final keep = KeepAwake(enable: () async {}, disable: () async {});
      await t.pumpWidget(
        _host(
          service,
          TrackpadCore(authed: true, dragLock: dragLock, keepAwake: keep),
        ),
      );

      await t.tap(find.byType(TrackpadCore));
      await t.pump(const Duration(seconds: 1)); // flush the armed long-press

      final clicks = service.reliable
          .whereType<ClickMsg>()
          .where((m) => m.button == 'left');
      expect(clicks, isNotEmpty,
          reason: 'a tap must send a left click on the reliable channel');
      dragLock.dispose();
    });
  });

  group('TrackpadCore — CR-01 dispose flush (4-quadrant, T-08-03)', () {
    Future<List<RemoteMessage>> runQuadrant(
      WidgetTester t, {
      required bool locked,
      required bool authed,
    }) async {
      final service = _RecordingService()..authed = authed;
      final driver = _inertDriver();
      if (locked) driver.handle(const [DragStartIntent()]);
      final dragLock = ValueNotifier<bool>(false);
      final keep = KeepAwake(enable: () async {}, disable: () async {});
      await t.pumpWidget(
        _host(
          service,
          TrackpadCore(
            authed: authed,
            dragLock: dragLock,
            keepAwake: keep,
            driver: driver,
          ),
        ),
      );
      // Unmount -> TrackpadCore.dispose runs the CR-01 flush guard.
      await t.pumpWidget(const SizedBox());
      dragLock.dispose();
      return service.reliable;
    }

    testWidgets('locked + authed -> flushes DragMsg(end, left)', (t) async {
      final reliable = await runQuadrant(t, locked: true, authed: true);
      final ends = reliable
          .whereType<DragMsg>()
          .where((m) => m.action == 'end' && m.button == 'left');
      expect(ends, hasLength(1));
    });

    testWidgets('locked + NOT authed -> sends nothing', (t) async {
      final reliable = await runQuadrant(t, locked: true, authed: false);
      expect(reliable, isEmpty);
    });

    testWidgets('NOT locked + authed -> sends nothing', (t) async {
      final reliable = await runQuadrant(t, locked: false, authed: true);
      expect(reliable, isEmpty);
    });

    testWidgets('NOT locked + NOT authed -> sends nothing', (t) async {
      final reliable = await runQuadrant(t, locked: false, authed: false);
      expect(reliable, isEmpty);
    });
  });

  group('TrackpadCore — keepAwake ownership (Pitfall 4)', () {
    testWidgets('acquires on mount and releases on dispose', (t) async {
      final service = _RecordingService();
      final dragLock = ValueNotifier<bool>(false);
      final keep = KeepAwake(enable: () async {}, disable: () async {});

      await t.pumpWidget(
        _host(
          service,
          TrackpadCore(authed: false, dragLock: dragLock, keepAwake: keep),
        ),
      );
      expect(keep.activeCount, 1, reason: 'mount acquires the keep-awake hold');

      await t.pumpWidget(const SizedBox());
      expect(keep.activeCount, 0, reason: 'dispose releases the hold');
      dragLock.dispose();
    });
  });
}
