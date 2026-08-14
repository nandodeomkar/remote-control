// D5 SPIKE (13-01) — the tracer. Three assertions settle the host shape:
//
//   S1  the MaterialApp.builder subtree is an ANCESTOR of the Navigator, and
//       ModalRoute.of at the builder's context is null.
//   S2  a per-route SummonBackGuard DOES intercept a system back from a route
//       below a MaterialApp.builder shell (SUM-04), and a second back pops.
//   S3  a PopScope placed in the builder ITSELF is a silent no-op — it never
//       registers and the route pops despite it. This is the diagnostic: if
//       someone later "simplifies" the guard up into SummonShell, S3 goes red
//       with a message naming the reason.
//
// S2 is driven through the REAL SummonShell + the REAL SummonBackGuard + the
// REAL SummonShellController, not an inline throwaway closure: the mechanism
// that ships is the mechanism that is proven. Three extra cases ride along
// because they are the same gesture through the same objects and each is a
// must_have edge:
//
//   S2b  nothing raised -> back exits from the root route (T-13-05: the hub
//        must never trap the user on the dashboard).
//   S2c  D-13-02 — a route pushed AFTER the raise pops normally on back, and
//        the surface rides along.
//   S2d  D-13-03 — when the owning route is popped by other means, no live
//        guard owns the raise, canPop is true everywhere, and back leaves the
//        route with the surface still up.
//
// If S2 fails, the host shape changes -> STOP and checkpoint, per CONTEXT.md
// D-13-04. Do not pick a fallback host shape: a per-route shell resurrects the
// exact defect the app-scope shell exists to prevent.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'package:remote_control/net/connection_providers.dart';
import 'package:remote_control/net/connection_service.dart';
import 'package:remote_control/shell/summon_back_guard.dart';
import 'package:remote_control/shell/summon_scope.dart';
import 'package:remote_control/shell/summon_shell.dart';
import 'package:remote_control/store/device_store.dart';

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

/// Recording ConnectionService with a settable `authed` flag — harvested from
/// `test/bubble_scaffold_test.dart:65-81` ahead of Phase 16's deletion of its
/// home (see TEST-MIGRATION.md § Harvest before deletion).
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

/// Pumps the REAL shell at `MaterialApp.builder` with a guarded root route.
Widget _realShellHost({
  required GlobalKey<NavigatorState> nav,
  required Widget rootBody,
}) =>
    ProviderScope(
      overrides: [
        connectionServiceProvider.overrideWith((ref) => _RecordingService()),
      ],
      child: MaterialApp(
        navigatorKey: nav,
        builder: (context, child) => SummonShell(child: child!),
        home: SummonBackGuard(child: rootBody),
      ),
    );

/// Grabs a BuildContext from inside the given route's subtree so the test can
/// call SummonScope.of / raise the way production code would.
BuildContext _contextOf(WidgetTester t, String text) =>
    t.element(find.text(text));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // The shell's UipiBanner slot reaches the real ConnectionService; nothing
    // in this suite touches SharedPreferences directly, but the in-memory async
    // fake keeps any incidental read off the plugin channel.
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
  });

  testWidgets('S1: MaterialApp.builder sits ABOVE the Navigator', (t) async {
    final shellKey = GlobalKey();
    await t.pumpWidget(
      MaterialApp(
        builder: (context, child) => KeyedSubtree(key: shellKey, child: child!),
        home: const Scaffold(body: Text('root')),
      ),
    );

    expect(
      find.descendant(
        of: find.byKey(shellKey),
        matching: find.byType(Navigator),
      ),
      findsOneWidget,
      reason: 'MaterialApp.builder is handed `routing` (FocusScope > Navigator) '
          'as its child — widgets/app.dart:1690-1731',
    );
    expect(
      ModalRoute.of(shellKey.currentContext!),
      isNull,
      reason: 'there is no route above the Navigator — pop_scope.dart:196',
    );
  });

  testWidgets(
      'S2: a per-route SummonBackGuard intercepts back from a route BELOW the '
      'real SummonShell; a second back pops', (t) async {
    final nav = GlobalKey<NavigatorState>();
    await t.pumpWidget(
      _realShellHost(
        nav: nav,
        rootBody: const Scaffold(body: Center(child: Text('root'))),
      ),
    );
    await t.pumpAndSettle();

    unawaited(
      nav.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => const SummonBackGuard(
            child: Scaffold(body: Center(child: Text('tool'))),
          ),
        ),
      ),
    );
    // Navigation only — NOT a timing assertion (the pumpAndSettle ban is
    // scoped to MOT-01's motion budgets).
    await t.pumpAndSettle();
    expect(find.text('tool'), findsOneWidget);

    // Raise the way production will: through the shell's controller, from a
    // context inside the pushed route, so the id stack records THAT route.
    final controller = SummonScope.of(_contextOf(t, 'tool'));
    controller.raise(SummonSurfaceKind.trackpad);
    await t.pump();
    expect(controller.raised.value, isNotNull);
    expect(
      SummonScope.ownsRaisedSurface(_contextOf(t, 'tool')),
      isTrue,
      reason: 'the pushed route raised it, so the pushed route owns it',
    );

    await t.binding.handlePopRoute(); // the system back
    await t.pumpAndSettle();

    expect(
      controller.raised.value,
      isNull,
      reason: 'the guard intercepted and lowered the surface',
    );
    expect(
      find.text('tool'),
      findsOneWidget,
      reason: 'the first back must NOT pop the route (SUM-04)',
    );

    await t.binding.handlePopRoute(); // a second back pops
    await t.pumpAndSettle();

    expect(find.text('root'), findsOneWidget);
    expect(find.text('tool'), findsNothing);
  });

  testWidgets(
      'S2b: with nothing raised, back exits from the root route — the hub never '
      'traps the user (T-13-05)', (t) async {
    final nav = GlobalKey<NavigatorState>();
    await t.pumpWidget(
      _realShellHost(
        nav: nav,
        rootBody: const Scaffold(body: Center(child: Text('root'))),
      ),
    );
    await t.pumpAndSettle();

    final controller = SummonScope.of(_contextOf(t, 'root'));
    expect(controller.raised.value, isNull);

    // handlePopRoute returns false when nothing in the framework handled the
    // back — which is exactly "the platform should exit the app".
    final handled = await t.binding.handlePopRoute();
    await t.pumpAndSettle();

    expect(
      handled,
      isFalse,
      reason: 'no owned surface means canPop is true on every guard, so the '
          'framework declines the back and Android exits the app. A static '
          'canPop of false here would freeze the phone on the dashboard.',
    );
    expect(find.text('root'), findsOneWidget);
  });

  testWidgets(
      'S2c: a route pushed AFTER the raise pops normally and the surface rides '
      'along (D-13-02)', (t) async {
    final nav = GlobalKey<NavigatorState>();
    await t.pumpWidget(
      _realShellHost(
        nav: nav,
        rootBody: const Scaffold(body: Center(child: Text('root'))),
      ),
    );
    await t.pumpAndSettle();

    // Raise from the ROOT route — root owns it.
    final controller = SummonScope.of(_contextOf(t, 'root'));
    controller.raise(SummonSurfaceKind.trackpad);
    await t.pump();

    unawaited(
      nav.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => const SummonBackGuard(
            child: Scaffold(body: Center(child: Text('tool'))),
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    expect(find.text('tool'), findsOneWidget);
    expect(
      SummonScope.ownsRaisedSurface(_contextOf(t, 'tool')),
      isFalse,
      reason: 'the pushed route did not raise it, so it must not intercept',
    );

    await t.binding.handlePopRoute();
    await t.pumpAndSettle();

    expect(
      find.text('tool'),
      findsNothing,
      reason: 'back on a route pushed after the raise pops that route normally',
    );
    expect(
      controller.raised.value,
      isNotNull,
      reason: 'the surface rides along — it is not lowered by that back',
    );
  });

  testWidgets(
      'S2d: when the owning route is popped by other means the surface is '
      'orphaned and back stops intercepting anywhere (D-13-03)', (t) async {
    final nav = GlobalKey<NavigatorState>();
    await t.pumpWidget(
      _realShellHost(
        nav: nav,
        rootBody: const Scaffold(body: Center(child: Text('root'))),
      ),
    );
    await t.pumpAndSettle();

    unawaited(
      nav.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => const SummonBackGuard(
            child: Scaffold(body: Center(child: Text('tool'))),
          ),
        ),
      ),
    );
    await t.pumpAndSettle();

    final controller = SummonScope.of(_contextOf(t, 'tool'));
    controller.raise(SummonSurfaceKind.trackpad);
    await t.pump();

    // The AppBar-arrow path: the owning route is popped WITHOUT a back gesture.
    nav.currentState!.pop();
    await t.pumpAndSettle();
    expect(find.text('root'), findsOneWidget);
    expect(
      controller.raised.value,
      isNotNull,
      reason: 'an orphaned surface stays raised — no transfer machinery',
    );
    expect(
      SummonScope.ownsRaisedSurface(_contextOf(t, 'root')),
      isFalse,
      reason: 'the owner id has left the stack; no live route owns the raise',
    );

    final handled = await t.binding.handlePopRoute();
    await t.pumpAndSettle();

    expect(
      handled,
      isFalse,
      reason: 'canPop is true everywhere, so back exits the app with the '
          'surface still raised — D-13-03, the accepted trade',
    );
    expect(controller.raised.value, isNotNull);
  });

  testWidgets('S3: a PopScope in the builder itself is a SILENT no-op',
      (t) async {
    var invoked = 0;
    final nav = GlobalKey<NavigatorState>();
    await t.pumpWidget(
      MaterialApp(
        navigatorKey: nav,
        builder: (context, child) => PopScope(
          canPop: false,
          onPopInvokedWithResult: (didPop, result) => invoked++,
          child: child!,
        ),
        home: const Scaffold(body: Text('root')),
      ),
    );
    unawaited(
      nav.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('tool')),
        ),
      ),
    );
    await t.pumpAndSettle();

    await t.binding.handlePopRoute();
    await t.pumpAndSettle();

    expect(
      invoked,
      0,
      reason: 'no ModalRoute above the Navigator to register with',
    );
    expect(
      find.text('root'),
      findsOneWidget,
      reason: 'the route popped despite a false canPop — the shell-level '
          'PopScope never registered (pop_scope.dart:196-201)',
    );
  });
}
