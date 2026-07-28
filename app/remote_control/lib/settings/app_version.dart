/// The running build's version, read from the INSTALLED package (260729-42w).
///
/// WHY A PROVIDER, not a direct `PackageInfo.fromPlatform()` call at the use
/// site:
///
///   1. It is the seam that keeps the widget suite off the platform channel.
///      `flutter_test` has no plugin registrant, so a direct call throws
///      `MissingPluginException`; a test overrides this provider instead and
///      never touches `package_info_plus` at all.
///   2. It makes the failure path expressible. `AsyncValue.error` is something
///      the Settings row can render around (see `kVersionUnavailable`), where
///      a thrown exception mid-build would take the screen down.
///
/// WHY NOT A DART CONSTANT: a `const kAppVersion = '1.3.0'` is exactly the bug
/// this fixes. pubspec said `1.0.0+1` through four shipped releases precisely
/// because nothing forced the two to agree. The package manifest is the only
/// copy that cannot drift from what was installed.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// Formats the two halves of the package version for display.
///
/// Both matter for support: [version] (Android's `versionName`) is what people
/// quote, while [buildNumber] (`versionCode`) is what actually orders
/// upgrades — and the two disagreed for the whole v1.0-v1.3.0-rc1 run.
String formatAppVersion({required String version, required String buildNumber}) =>
    '$version ($buildNumber)';

/// The installed package's version, e.g. `1.3.0 (4)`.
///
/// Override in tests: `appVersionProvider.overrideWith((ref) async => '9.9.9 (99)')`.
///
/// `retry` returns null to opt OUT of Riverpod 3's automatic
/// retry-with-backoff. The package manifest does not change while the process
/// is alive, so a failure here is permanent — retrying would spin a backoff
/// timer forever behind a row that reads [kVersionUnavailable] either way, and
/// it would keep the state oscillating out of `AsyncError` back into
/// `AsyncLoading`.
final appVersionProvider = FutureProvider<String>(
  (ref) async {
    final info = await PackageInfo.fromPlatform();
    return formatAppVersion(
      version: info.version,
      buildNumber: info.buildNumber,
    );
  },
  retry: (_, _) => null,
);
