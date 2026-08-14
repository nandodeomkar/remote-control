// The shared harness for every `test/shell/` suite (13-02).
//
// WHY THIS FILE EXISTS NOW. Three of the doubles below are HARVESTED from
// suites Phase 16 deletes — `_RecordingService` / `_FakeSecureKv` /
// `_FakePrefsKv` from `test/bubble_scaffold_test.dart:40-81` and the no-op
// wakelock stub from `test/trackpad/trackpad_screen_test.dart:41-47`. Copying
// them into a home that survives is deliberate: TEST-MIGRATION.md's "harvest
// before deletion" step, done while both originals are still readable rather
// than reconstructed afterwards. The D5 spike suite carries its own copies
// because this file did not exist when it was written; it should import from
// here instead.
//
// The computed-expectation helpers mirror the `columnOf` / `floorFor` pair at
// `test/trackpad/trackpad_screen_test.dart:166-176`. They re-derive the
// arithmetic independently of `summon_geometry.dart`, which is the point: an
// expectation that simply called the production function would pass for any
// formula.

// The wakelock platform-interface import is a test-only stub seam; it is a
// transitive (not direct) dependency, hence the file-scoped ignore.
// ignore_for_file: depend_on_referenced_packages

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:wakelock_plus_platform_interface/wakelock_plus_platform_interface.dart';

import 'package:remote_control/net/connection_providers.dart';
import 'package:remote_control/net/connection_service.dart';
import 'package:remote_control/shell/summon_back_guard.dart';
import 'package:remote_control/shell/summon_geometry.dart';
import 'package:remote_control/shell/summon_scope.dart';
import 'package:remote_control/shell/summon_shell.dart';
import 'package:remote_control/store/device_store.dart';

// ── Harvested doubles ────────────────────────────────────────────────────

/// No-op wakelock platform so a screen's keep-awake acquire/release never hits
/// an (absent) plugin in the test harness. Harvested from
/// `trackpad_screen_test.dart:41-47`.
class NoopWakelock extends WakelockPlusPlatformInterface {
  @override
  Future<void> toggle({required bool enable}) async {}

  @override
  Future<bool> get enabled async => false;
}

/// In-memory secure store. Harvested from `bubble_scaffold_test.dart:40-51`.
class FakeSecureKv implements SecureKv {
  /// The backing map, readable by a test that wants to assert on writes.
  final Map<String, String> backing = {};

  @override
  Future<String?> read(String key) async => backing[key];

  @override
  Future<void> write(String key, String value) async => backing[key] = value;

  @override
  Future<void> delete(String key) async => backing.remove(key);
}

/// In-memory prefs store. Harvested from `bubble_scaffold_test.dart:53-63`.
class FakePrefsKv implements PrefsKv {
  /// The backing map, readable and seedable by a test.
  final Map<String, String> backing = {};

  @override
  Future<String?> getString(String key) async => backing[key];

  @override
  Future<void> setString(String key, String value) async {
    backing[key] = value;
  }
}

/// A `ConnectionService` with a settable [authed] flag, so a suite can drive
/// `connectionStatusProvider` between connected and disconnected without a
/// socket. Harvested from `bubble_scaffold_test.dart:65-81`.
class RecordingService extends ConnectionService {
  /// Creates the double over in-memory stores.
  RecordingService()
      : super(
          store: DeviceStore(secure: FakeSecureKv(), prefs: FakePrefsKv()),
        );

  /// Flips both [isAuthed] and [chipStatus].
  bool authed = false;

  @override
  bool get isAuthed => authed;

  @override
  ChipStatus get chipStatus =>
      authed ? ChipStatus.connected : ChipStatus.disconnected;
}

/// Counts every route mutation the `Navigator` performs, so a test can assert
/// that the summon path pushes, pops and replaces **nothing** (SUM-01).
class RecordingNavigatorObserver extends NavigatorObserver {
  /// Pushes seen, including the initial route.
  int pushes = 0;

  /// Pops seen.
  int pops = 0;

  /// Replacements seen.
  int replacements = 0;

  /// Removals seen.
  int removals = 0;

  /// One number to compare before and after a raise.
  int get mutations => pushes + pops + replacements + removals;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) => pushes++;

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) => pops++;

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      removals++;

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) =>
      replacements++;
}

// ── Driven metrics ───────────────────────────────────────────────────────

/// Drives the raw view metrics. devicePixelRatio 1 keeps FakeViewPadding
/// values 1:1 with logical pixels. When an IME inset is present, `padding`
/// bottom is 0 while `viewPadding` keeps the nav-bar value — that is how
/// the platform reports it, and the difference is the whole point.
void driveView(
  WidgetTester t, {
  required Size size,
  required double top,
  required double bottom,
  double ime = 0,
}) {
  t.view.devicePixelRatio = 1.0;
  t.view.physicalSize = size;
  t.view.viewPadding = FakeViewPadding(top: top, bottom: bottom);
  t.view.padding = FakeViewPadding(top: top, bottom: ime > 0 ? 0 : bottom);
  t.view.viewInsets = FakeViewPadding(bottom: ime);
  addTearDown(t.view.reset);
}

/// The bar's offset above the window's bottom edge, re-derived from the driven
/// metrics. The IME draws over the nav bar, so this is the larger of the two.
double barBottomOffsetOf({required double bottom, double ime = 0}) =>
    ime > bottom ? ime : bottom;

/// The space a raised surface may occupy, re-derived from the driven metrics.
double availableOf({
  required Size size,
  required double top,
  required double bottom,
  double ime = 0,
}) =>
    size.height -
    top -
    barBottomOffsetOf(bottom: bottom, ime: ime) -
    kSummonBarHeight;

/// The surface height for [kind], re-derived: the design choice, clamped by
/// what exists.
double summonSurfaceHeightFor(SummonSurfaceKind kind, double available) {
  final chosen = kind == SummonSurfaceKind.trackpad
      ? kSummonTrackpadHeight
      : kSummonKeyboardHeight;
  return available < chosen ? available : chosen;
}

// ── The host ─────────────────────────────────────────────────────────────

/// The text the default guarded body renders, so a suite can grab a
/// `BuildContext` from inside the root route.
const String kHarnessRootText = 'root body';

/// Installs the platform doubles every shell suite needs. Call from `setUp`.
void installSummonTestPlatforms() {
  SharedPreferencesAsyncPlatform.instance =
      InMemorySharedPreferencesAsync.empty();
  wakelockPlusPlatformInstance = NoopWakelock();
}

/// The REAL shell at `MaterialApp.builder` over a guarded root route — the
/// production wiring from `main.dart`, not a stand-in.
Widget summonHost({
  required GlobalKey<NavigatorState> nav,
  required ConnectionService service,
  Widget? body,
  List<NavigatorObserver> observers = const <NavigatorObserver>[],
}) =>
    ProviderScope(
      overrides: [
        connectionServiceProvider.overrideWith((ref) => service),
      ],
      child: MaterialApp(
        navigatorKey: nav,
        navigatorObservers: observers,
        builder: (context, child) => SummonShell(child: child!),
        home: SummonBackGuard(
          child: body ??
              const Scaffold(body: Center(child: Text(kHarnessRootText))),
        ),
      ),
    );

/// Pumps [summonHost] and settles the initial route transition.
///
/// `pumpAndSettle` here is NAVIGATION settling, never a timing assertion — the
/// ban in `test/shell/` is on using it before a geometry or motion assertion,
/// where a 200ms summon and a 900ms summon would be indistinguishable.
Future<RecordingService> pumpShell(
  WidgetTester t, {
  required GlobalKey<NavigatorState> nav,
  RecordingService? service,
  Widget? body,
  List<NavigatorObserver> observers = const <NavigatorObserver>[],
}) async {
  final resolved = service ?? RecordingService();
  await t.pumpWidget(
    summonHost(nav: nav, service: resolved, body: body, observers: observers),
  );
  await t.pumpAndSettle();
  return resolved;
}

/// Grabs a `BuildContext` from inside a route's subtree, so a test can call
/// `SummonScope.of` the way production code would.
BuildContext contextOf(WidgetTester t, String text) => t.element(find.text(text));
