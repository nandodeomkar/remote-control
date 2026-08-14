// Task 2 (13-05, Wave 3) — the RECORDED predictive-back baseline (SUM-04,
// D-13-01, SC3, T-13-05, T-13-11).
//
// THIS FILE TURNS NOTHING ON. Predictive back is MEASURED in this phase, not
// enabled (D-13-01). Its whole job is to record what the framework does today
// and go red if this phase moves it.
//
// TWO INDEPENDENT LAYERS, and only one of them is in play:
//
//  * SYSTEM predictive back (the back-to-home / cross-activity peek) is ON.
//    `targetSdk` resolves to 36 through Flutter 3.44 and the manifest never
//    declares `android:enableOnBackInvokedCallback`, so Android's default
//    applies. Flutter modulates it ahead of each gesture through
//    `SystemNavigator.setFrameworkHandlesBack` — that call is what the three
//    widget cases below capture.
//  * IN-APP route predictive peek (peeking at the previous route) is OFF and
//    ALWAYS HAS BEEN: `buildAppTheme()` declares no `pageTransitionsTheme`.
//    It cannot regress because it has never existed. Enabling it properly is a
//    DEFERRED IDEA, not work this phase absorbs (T-13-11).
//
// So SC3's "predictive back still animates" can only be measuring layer 1:
// back-to-home from the hub with nothing raised. That is case 1.
//
// THE MECHANISM (widgets/navigator.dart:3743-3753 → widgets/app.dart:1442-1455):
// the Navigator publishes a NavigationNotification carrying
// `navigatorCanPop || routeBlocksPop`; WidgetsApp forwards it to the engine as
// `setFrameworkHandlesBack`. The truth table has exactly one new row:
//
//   | situation                          | claim | system peek           |
//   |------------------------------------|-------|-----------------------|
//   | hub, nothing raised (MUST NOT MOVE)| false | back-to-home peek     |
//   | hub, surface raised & owned  (NEW) | true  | suppressed — correct  |
//   | any pushed route                   | true  | unchanged from today  |
//
// TWO SETUP STEPS THAT ARE NOT OPTIONAL, both confirmed by hand:
//
//  1. The target platform must be Android. `SystemNavigator.setFrameworkHandlesBack`
//     returns early on every other target (services/system_navigator.dart:31-43),
//     so the channel is never touched and every captured list is EMPTY.
//     `flutter test` already forces `TargetPlatform.android` through the
//     FLUTTER_TEST environment check (foundation/_platform_io.dart), so the
//     override below is a PIN rather than a fix — it keeps this suite honest if
//     that implicit default ever changes, and forcing a non-Android target was
//     verified to empty the list.
//  2. The app lifecycle must be resumed BEFORE the first pump, not after.
//     `_defaultOnNavigationNotification` returns without touching the channel
//     while `_appLifecycleState` is null (widgets/app.dart:1443-1447), and
//     `WidgetsApp.initState` latches that state once from
//     `WidgetsBinding.instance.lifecycleState`. In a widget test that value
//     starts NULL, and driving it to resumed AFTER pumping re-dispatches
//     nothing — the startup notification is already gone, and the baseline
//     capture stays empty forever. Driving it first is what makes case 1
//     observable at all.
//
// Each case therefore asserts `isNotEmpty` FIRST, with a reason naming the
// setup step. Without that guard, dropping either step fails with an opaque
// "Bad state: No element" instead of naming the cause.
//
// ONLY HARDWARE CAN SHOW the rest: whether the OS actually renders the
// back-to-home peek from the hub with nothing raised, and whether the raised
// surface renders correctly DURING that peek while the system compositor is
// scaling the app window. Both are UAT observations; neither is asserted here.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:remote_control/shell/summon_geometry.dart';
import 'package:remote_control/shell/summon_scope.dart';

import 'summon_test_harness.dart';

/// Setup step 1, expressed as a variant rather than as a `setUp` assignment.
///
/// `debugDefaultTargetPlatformOverride` is a foundation debug variable, and
/// `flutter_test` verifies it is unset at the END OF THE TEST BODY — before
/// any `tearDown` runs (`binding.dart:1973` calls `_verifyInvariants` on the
/// body, `foundation/debug.dart:45`). A `setUp`/`tearDown` pair therefore
/// fails every case with "the value of a foundation debug variable was
/// changed by the test". The variant sets and restores it INSIDE the body's
/// scope (`widget_tester.dart:306-313`), which is the framework's own answer.
final TargetPlatformVariant kAndroidOnly =
    TargetPlatformVariant.only(TargetPlatform.android);

/// The reason string reused by every case's non-empty guard.
const String kSetupReason =
    'the capture is empty, so one of the two mandatory setup steps is gone: '
    'the Android platform override, or the resumed lifecycle driven BEFORE '
    'the first pump. Without them the framework never reaches the channel and '
    'this case would measure nothing at all.';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// Every `setFrameworkHandlesBack` value the framework pushed, in order.
  final handled = <bool>[];

  setUp(() {
    handled.clear();
    installSummonTestPlatforms();
    // The house channel-mocking idiom, `test/haptics_gate_test.dart:19-30`.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'SystemNavigator.setFrameworkHandlesBack') {
        handled.add(call.arguments as bool);
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  testWidgets(
      '1 — BASELINE: on the hub with nothing raised the framework does NOT '
      'claim back, so the system back-to-home peek is preserved (SC3)',
      (t) async {
    // Setup step 2 — BEFORE the pump. See the header.
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);

    final nav = GlobalKey<NavigatorState>();
    await pumpShell(t, nav: nav);

    expect(handled, isNotEmpty, reason: kSetupReason);
    expect(
      handled.last,
      isFalse,
      reason: 'this is the ONLY predictive-back animation the app has today — '
          'back-to-home from the root route — and it is what SC3 measures. '
          'Mounting the summon shell must not disturb it',
    );
    expect(
      handled,
      everyElement(isFalse),
      reason: 'nothing during startup ever claims back either; the shell adds '
          'no transient claim on the way up',
    );
  }, variant: kAndroidOnly);

  testWidgets(
      '2 — RAISED: with an owned surface up on the hub the framework DOES '
      'claim back — the one new row in the truth table', (t) async {
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);

    final nav = GlobalKey<NavigatorState>();
    await pumpShell(t, nav: nav);
    final controller = SummonScope.of(contextOf(t, kHarnessRootText));

    controller.raise(SummonSurfaceKind.trackpad);
    await t.pump();
    await t.pump(kSummonRaiseDuration);

    expect(handled, isNotEmpty, reason: kSetupReason);
    expect(
      handled.last,
      isTrue,
      reason: 'the owning route reports canPop:false, so popDisposition is '
          'doNotPop and the Navigator publishes canHandlePop:true. The system '
          'peek is suppressed while a surface is up, which is INTENDED: back '
          'must dismiss the surface, not exit the app (SUM-04)',
    );
  }, variant: kAndroidOnly);

  testWidgets(
      '3 — RESTORED: lowering puts the claim back to false, so the baseline '
      'returns', (t) async {
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);

    final nav = GlobalKey<NavigatorState>();
    await pumpShell(t, nav: nav);
    final controller = SummonScope.of(contextOf(t, kHarnessRootText));

    controller.raise(SummonSurfaceKind.trackpad);
    await t.pump();
    await t.pump(kSummonRaiseDuration);
    expect(handled.last, isTrue, reason: 'precondition for this case');

    controller.lower();
    await t.pump();
    await t.pump(kSummonLowerDuration);

    expect(handled, isNotEmpty, reason: kSetupReason);
    expect(
      handled.last,
      isFalse,
      reason: 'THE REGRESSION THIS CASE EXISTS TO CATCH. A guard written as a '
          'constant non-poppable would leave this claim true forever, and '
          'Android would never play the back-to-home peek again — a silent '
          'loss with nothing visibly broken (T-13-05)',
    );
    expect(
      handled.where((claim) => claim).length,
      1,
      reason: 'exactly one claim, raised and released — the shell does not '
          'flap the engine flag across a raise/lower cycle',
    );
  }, variant: kAndroidOnly);

  test(
      '4 — the phase enables nothing: no back-invoked-callback attribute and '
      'no page-transitions builder (D-13-01, T-13-11)', () {
    final manifest =
        File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
    expect(
      manifest.contains('enableOnBackInvokedCallback'),
      isFalse,
      reason: 'D-13-01: predictive back is MEASURED, not enabled. The manifest '
          'must stay untouched by this phase — declaring the attribute either '
          'way changes the baseline the three cases above just recorded, and '
          'the false form would switch the system peek OFF entirely',
    );

    final offenders = <String>[];
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final lines = entity.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final trimmed = lines[i].trim();
        if (trimmed.startsWith('//')) continue;
        if (lines[i].contains('pageTransitionsTheme') ||
            lines[i].contains('PredictiveBackPageTransitionsBuilder')) {
          offenders.add('${entity.path.replaceAll(r'\', '/')}:${i + 1}');
        }
      }
    }
    expect(
      offenders,
      isEmpty,
      reason: 'in-app route predictive peek has NEVER existed in this app, so '
          'it cannot regress and it is not this phase\'s to add. Enabling it '
          'properly is a deferred idea with its own evidence; absorbing it '
          'here would be scope creep into the one place SC3 is measured',
    );
  });
}
