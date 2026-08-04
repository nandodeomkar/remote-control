/// The running build's version, read from the INSTALLED package (260729-42w).
///
/// TWO shapes, ONE lookup. The Settings About row wants the display string
/// `1.4.0 (8)`; the Updates screen wants the bare `1.4.0`, because
/// `SemVer.tryParse` rejects anything with a build number bolted on and an
/// unparseable installed version resolves to "Version unknown" rather than to
/// an update offer (D-26). Both come from the SAME [PackageInfo] future
/// ([packageInfoProvider]) so they can never disagree, and neither is ever
/// derived by picking the other one apart.
///
/// WHY A PROVIDER, not a direct platform lookup at the use site (a grep for
/// the lookup call must find exactly ONE occurrence in this file, which is why
/// this sentence does not spell it):
///
///   1. It is the seam that keeps the widget suite off the platform channel.
///      `flutter_test` has no plugin registrant, so a direct call throws
///      `MissingPluginException`; a test overrides this provider instead and
///      never touches `package_info_plus` at all.
///   2. It makes the failure path expressible. `AsyncValue.error` is something
///      the Settings row can render around (see `kVersionUnavailable`), where
///      a thrown exception mid-build would take the screen down.
///
/// WHY NOT A HAND-MAINTAINED DART LITERAL: a source-level version constant is
/// exactly the bug this fixes. pubspec claimed the same version through four
/// shipped releases precisely because nothing forced the two to agree. The
/// package manifest is the only copy that cannot drift from what was
/// installed — which is also why this whole phase exists, so do not introduce
/// one here or anywhere downstream.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// The two halves of the package version, as one value-equal pair.
///
/// Exists so there is exactly ONE [PackageInfo] resolution behind both the
/// display string and the bare version: a second future could resolve to a
/// different answer under an override, and "the app disagrees with itself
/// about which version it is" is the failure mode this file was written to
/// end.
class PackageVersion {
  /// Android's `versionName` — the bare `X.Y.Z` people quote, and the only
  /// form the update comparator accepts.
  final String version;

  /// Android's `versionCode` — what actually orders upgrades.
  final String buildNumber;

  /// Creates a version pair.
  const PackageVersion({required this.version, required this.buildNumber});

  @override
  bool operator ==(Object other) =>
      other is PackageVersion &&
      other.version == version &&
      other.buildNumber == buildNumber;

  @override
  int get hashCode => Object.hash(version, buildNumber);

  @override
  String toString() => 'PackageVersion($version, build $buildNumber)';
}

/// Formats the two halves of the package version for display.
///
/// Both matter for support: [version] (Android's `versionName`) is what people
/// quote, while [buildNumber] (`versionCode`) is what actually orders
/// upgrades — and the two disagreed for the whole v1.0-v1.3.0-rc1 run.
String formatAppVersion({required String version, required String buildNumber}) =>
    '$version ($buildNumber)';

/// The ONE `PackageInfo` lookup, and the override seam tests should reach for.
///
/// Overriding this in a test fixes BOTH [appBareVersionProvider] and
/// [appVersionProvider] at once, which is the point: they are two renderings
/// of one fact, and a test that could set them apart would be testing a state
/// the app cannot be in.
///
/// `retry` returns null to opt OUT of Riverpod 3's automatic
/// retry-with-backoff. The package manifest does not change while the process
/// is alive, so a failure here is permanent — retrying would spin a backoff
/// timer forever behind a row that reads `kVersionUnavailable` either way, and
/// it would keep the state oscillating out of `AsyncError` back into
/// `AsyncLoading`.
final packageInfoProvider = FutureProvider<PackageVersion>(
  (ref) async {
    final info = await PackageInfo.fromPlatform();
    return PackageVersion(
      version: info.version,
      buildNumber: info.buildNumber,
    );
  },
  retry: (_, _) => null,
);

/// The installed version WITHOUT the build number, e.g. `1.4.0`.
///
/// This is what the Updates screen compares against the release feed. It is
/// the `version` field of the same [PackageInfo] the display string uses —
/// never the display string with its tail chopped off, because a parser that
/// un-formats a formatted string is one copy change away from silently
/// producing a version nobody shipped.
final appBareVersionProvider = FutureProvider<String>(
  (ref) async => (await ref.watch(packageInfoProvider.future)).version,
  retry: (_, _) => null,
);

/// The installed package's version for display, e.g. `1.3.0 (4)`.
///
/// Override in tests: `appVersionProvider.overrideWith((ref) async => '9.9.9 (99)')`
/// for the About row alone, or [packageInfoProvider] to fix both renderings.
final appVersionProvider = FutureProvider<String>(
  (ref) async {
    final info = await ref.watch(packageInfoProvider.future);
    return formatAppVersion(
      version: info.version,
      buildNumber: info.buildNumber,
    );
  },
  retry: (_, _) => null,
);
