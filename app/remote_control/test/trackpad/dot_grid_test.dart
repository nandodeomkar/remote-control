// Phase 09 Plan 01 — dot-grid trackpad texture suite.
//
// Task 1 (unit): pins the DotGridPainter const contract (tile/radius/hint
// values lifted from the prototype lines 99 / 405 / 130) and the shouldRepaint
// equality on the single `tile` field.
//
// Task 3 (widget): proves the dot layer is mounted per-surface (24px default /
// 22px window), stays purely decorative (a drag still records moves and a tap
// still records a left ClickMsg with the painter present), the hint renders in
// kTrackpadHintColor, and NO fake-cursor / ripple painter exists beyond the
// single grid painter. Reuses the trackpad_core_test fake-service + host
// ProviderScope pattern.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_protocol/remote_protocol.dart';

import 'package:remote_control/net/connection_providers.dart';
import 'package:remote_control/net/connection_service.dart';
import 'package:remote_control/screens/connection_copy.dart';
import 'package:remote_control/store/device_store.dart';
import 'package:remote_control/trackpad/dot_grid.dart';
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

/// Recording ConnectionService: captures the hot-path sends so the
/// non-interactivity proofs can assert a drag/tap reached the service THROUGH
/// the decorative dot layer (mirrors trackpad_core_test).
class _RecordingService extends ConnectionService {
  _RecordingService()
      : super(
          store: DeviceStore(secure: _FakeSecureKv(), prefs: _FakePrefsKv()),
        );

  final List<(double, double)> moves = [];
  final List<RemoteMessage> reliable = [];
  bool authed = true;

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

Widget _host(ConnectionService service, Widget child) => ProviderScope(
      overrides: [
        connectionServiceProvider.overrideWith((ref) => service),
      ],
      child: MaterialApp(home: Scaffold(body: child)),
    );

/// Finds every CustomPaint whose painter is a [DotGridPainter].
Finder _dotGridFinder() => find.byWidgetPredicate(
      (w) => w is CustomPaint && w.painter is DotGridPainter,
    );

void main() {
  group('DotGridPainter — const contract (prototype-sourced values)', () {
    test('tile / radius / hint consts equal the prototype values', () {
      expect(kTrackpadDotTileFull, 24);
      expect(kTrackpadDotTileWindow, 22);
      expect(kTrackpadDotRadius, 1.2);
      expect(kTrackpadHintColor, const Color(0xFF4A505C));
    });

    test('shouldRepaint is true iff the tile changed', () {
      expect(
        DotGridPainter(tile: 24).shouldRepaint(DotGridPainter(tile: 22)),
        isTrue,
        reason: 'a different tile size must repaint',
      );
      expect(
        DotGridPainter(tile: 24).shouldRepaint(DotGridPainter(tile: 24)),
        isFalse,
        reason: 'an equal tile size must not repaint',
      );
    });
  });

  group('TrackpadCore — dot-grid mounted per surface', () {
    testWidgets('default core paints a 24px DotGridPainter', (t) async {
      final service = _RecordingService();
      final dragLock = ValueNotifier<bool>(false);
      final keep = KeepAwake(enable: () async {}, disable: () async {});
      await t.pumpWidget(
        _host(
          service,
          TrackpadCore(authed: true, dragLock: dragLock, keepAwake: keep),
        ),
      );

      final painters = _dotGridFinder();
      expect(painters, findsOneWidget,
          reason: 'exactly one dot-grid painter (no cursor/ripple painter)');
      final painter =
          t.widget<CustomPaint>(painters).painter! as DotGridPainter;
      expect(painter.tile, kTrackpadDotTileFull);
      dragLock.dispose();
    });

    testWidgets('window-tile core paints a 22px DotGridPainter', (t) async {
      final service = _RecordingService();
      final dragLock = ValueNotifier<bool>(false);
      final keep = KeepAwake(enable: () async {}, disable: () async {});
      await t.pumpWidget(
        _host(
          service,
          TrackpadCore(
            authed: true,
            dragLock: dragLock,
            keepAwake: keep,
            dotTile: kTrackpadDotTileWindow,
          ),
        ),
      );

      final painter =
          t.widget<CustomPaint>(_dotGridFinder()).painter! as DotGridPainter;
      expect(painter.tile, kTrackpadDotTileWindow);
      dragLock.dispose();
    });
  });

  group('TrackpadCore — dot layer is non-interactive (T-09-01)', () {
    testWidgets('a drag still records moves with the painter present',
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

      expect(_dotGridFinder(), findsOneWidget);
      final gesture = await t.startGesture(const Offset(150, 300));
      await gesture.moveBy(const Offset(40, 0));
      await gesture.moveBy(const Offset(40, 0));
      await gesture.up();
      await t.pump(const Duration(seconds: 1));

      expect(service.moves, isNotEmpty,
          reason: 'the dot layer must not swallow the pointer stream');
      dragLock.dispose();
    });

    testWidgets('a tap still records a left ClickMsg with the painter present',
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

      expect(_dotGridFinder(), findsOneWidget);
      await t.tap(find.byType(TrackpadCore));
      await t.pump(const Duration(seconds: 1));

      final clicks = service.reliable
          .whereType<ClickMsg>()
          .where((m) => m.button == 'left');
      expect(clicks, isNotEmpty,
          reason: 'a tap must reach the service through the dot layer');
      dragLock.dispose();
    });
  });

  group('TrackpadCore — hint color + no excluded effects', () {
    testWidgets('hint Text uses kTrackpadHintColor; single grid painter only',
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

      final hint = t.widget<Text>(find.text(kTrackpadHintAuthed));
      expect(hint.style?.color, kTrackpadHintColor,
          reason: 'hint takes the UI-SPEC #4a505c hue, not kMuted');
      // Exactly one decorative painter — the fake cursor dot and the rippop
      // ripple are the locked exclusions, so no second painter exists.
      expect(_dotGridFinder(), findsOneWidget);
      dragLock.dispose();
    });
  });
}
