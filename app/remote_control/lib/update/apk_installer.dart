/// MethodChannel client for Android's `PackageInstaller` session (D-19).
///
/// Hand-written, cloning `lib/platform/multicast_lock.dart` exactly — same
/// `remote_control/` channel prefix, same `invokeMethod` inside a `try`, same
/// `MissingPluginException` no-op so widget tests and non-Android hosts never
/// touch the platform. The channel name is spelled exactly once in this file
/// (see [ApkInstaller._channel]); its methods are `canInstall` /
/// `openInstallPermission` / `cacheDir` / `install`, all handled in
/// MainActivity.kt.
///
/// **Why a session and not an intent.** `ACTION_INSTALL_PACKAGE` is deprecated
/// and gives no outcome callback at all. D-19 requires "a declined system
/// dialog returns the row to available", which is only knowable through the
/// session API's status broadcast (RESEARCH §Rejected Alternatives).
///
/// **Why SUCCESS is not an observable outcome.** Replacing the APK terminates
/// this app's process, so `STATUS_SUCCESS` is delivered to a process being torn
/// down — or to the *new* app, which has no in-flight state (RESEARCH Pitfall
/// 7). The outcomes a caller can observe are therefore exactly
/// [InstallOutcome.pendingUserAction], [InstallOutcome.declined] and
/// [InstallOutcome.failure]. Success is confirmed by the app simply relaunching
/// at a new `package_info_plus` version, exactly the way the PC update is
/// confirmed by reconnecting (D-17). Never persist an "installing" flag: a
/// fresh launch would read it as stuck, and there is no event that could ever
/// clear it.
///
/// **Why verification is NOT here.** The sha256 gate runs in Dart, in
/// `apk_download.dart` (12-10), BEFORE [ApkInstaller.install] is called. The
/// platform side never verifies and never fetches — a security gate inside
/// platform code is unreachable by widget tests, so keeping it in testable Dart
/// is deliberate (T-12-23). This channel does only what only it can do.
///
/// **Why the outcome seam is a reverse `MethodCall` and not an `EventChannel`.**
/// One channel name means one Kotlin registration and one thing to keep in
/// sync; an `EventChannel` would need a second name plus stream-handler
/// lifecycle on the Kotlin side for a stream that emits at most once per
/// install. The platform calls back on this same channel with method `outcome`.
library;

import 'dart:async';

import 'package:flutter/services.dart';

/// The terminal states an APK install can report to Dart.
///
/// `success` is deliberately absent — see the library doc comment: the install
/// kills this process, so STATUS_SUCCESS is never observed here.
enum InstallOutcome {
  /// The system has asked for the user's confirmation; its own dialog is up.
  pendingUserAction,

  /// The user declined the system dialog (`STATUS_FAILURE_ABORTED`).
  /// D-19: the row returns to "update available". No retry, no nagging.
  declined,

  /// Any other non-success status, carrying the numeric code.
  failure,
}

/// One install outcome as delivered from the platform.
class InstallEvent {
  const InstallEvent(this.outcome, {this.status});

  final InstallOutcome outcome;

  /// The raw `PackageInstaller.EXTRA_STATUS` value, present on
  /// [InstallOutcome.failure]. `STATUS_FAILURE_CONFLICT` (5) is what a
  /// signature mismatch or a lower versionCode produces (RESEARCH Pitfall 8).
  final int? status;

  @override
  String toString() => 'InstallEvent(${outcome.name}, status: $status)';
}

class ApkInstaller {
  static const MethodChannel _channel = MethodChannel('remote_control/installer');

  static final StreamController<InstallEvent> _outcomes =
      StreamController<InstallEvent>.broadcast();

  static bool _handlerRegistered = false;

  ApkInstaller() {
    _ensureHandler();
  }

  /// Outcomes pushed up from `InstallResultReceiver`. Broadcast, so more than
  /// one listener (the row and a log sink) can observe the same install.
  Stream<InstallEvent> get outcomes {
    _ensureHandler();
    return _outcomes.stream;
  }

  static void _ensureHandler() {
    if (_handlerRegistered) return;
    _handlerRegistered = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'outcome') return null;
      final args = (call.arguments as Map?) ?? const {};
      final name = args['outcome'] as String?;
      final status = args['status'] as int?;
      final outcome = switch (name) {
        'pendingUserAction' => InstallOutcome.pendingUserAction,
        'declined' => InstallOutcome.declined,
        'failure' => InstallOutcome.failure,
        // An unknown name from a future platform revision is a failure, not a
        // crash: the caller can always render "couldn't install".
        _ => InstallOutcome.failure,
      };
      _outcomes.add(InstallEvent(outcome, status: status));
      return null;
    });
  }

  /// Whether the per-app "install unknown apps" grant is held.
  ///
  /// Returns `true` where the platform handler does not exist (unit tests,
  /// non-Android hosts) on [MissingPluginException], so the explainer sheet
  /// never opens spuriously off-device. The Kotlin side likewise returns `true`
  /// below API 26, where the per-app grant did not exist (RESEARCH Pitfall 5).
  Future<bool> canInstall() async {
    try {
      return await _channel.invokeMethod<bool>('canInstall') ?? true;
    } on MissingPluginException {
      // No handler registered (test / non-Android): behave as if granted.
      return true;
    }
  }

  /// Open the system's "install unknown apps" settings screen for this package.
  ///
  /// Silent no-op where the platform handler does not exist. The app does NOT
  /// poll for the grant afterwards (UI-SPEC Component 3): the user comes back
  /// and taps Update again.
  Future<void> openInstallPermission() async {
    try {
      await _channel.invokeMethod<void>('openInstallPermission');
    } on MissingPluginException {
      // No handler registered (test / non-Android): no settings screen to open.
    }
  }

  /// The Android app cache directory, or `null` off-platform.
  ///
  /// This method exists so `apk_download.dart` (12-10) has somewhere to stream
  /// ~70 MB WITHOUT adding a `path_provider` dependency — it keeps this phase's
  /// new-dependency surface at exactly one Dart package (`crypto`), the same
  /// reasoning that chose `RawDatagramSocket` over a wrapper package for the
  /// beacon. Returns `null` on [MissingPluginException]; the caller falls back
  /// to `Directory.systemTemp` in tests.
  Future<String?> cacheDir() async {
    try {
      return await _channel.invokeMethod<String>('cacheDir');
    } on MissingPluginException {
      // No handler registered (test / non-Android): caller uses systemTemp.
      return null;
    }
  }

  /// Hand an already-downloaded, already-**verified** file to the platform.
  ///
  /// Verification happens in Dart BEFORE this call (see the library doc
  /// comment); the platform side never verifies. Silent no-op where the
  /// platform handler does not exist. Outcomes arrive on [outcomes], never as
  /// a return value — `commit()` does not block on the user.
  Future<void> install(String apkPath) async {
    _ensureHandler();
    try {
      await _channel.invokeMethod<void>('install', {'path': apkPath});
    } on MissingPluginException {
      // No handler registered (test / non-Android): nothing to install.
    }
  }
}
