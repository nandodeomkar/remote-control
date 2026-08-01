/// Version comparison for the update surface (D-26) — PURE, no I/O.
///
/// This file answers exactly one question for the UI: *is the candidate
/// strictly newer than what is installed?* Nothing here reads a file, a
/// preference, a socket or a clock; every function is total and deterministic,
/// which is what makes it pinnable to a shared truth table.
///
/// **UNKNOWN IS NEVER NEWER.** A version string that does not parse as an
/// `X.Y.Z` triple of non-negative integers compares as UNKNOWN, and an UNKNOWN
/// must never produce an update offer. That rule is the whole security value of
/// this file (T-12-18): a crafted or corrupted tag such as `latest`,
/// `9.9.9-evil` or a 21-digit major cannot manufacture an offer, because
/// [isNewer] returns `false` the moment either side fails to parse.
///
/// **INTEGER TUPLE COMPARE, NEVER LEXICAL AND NEVER FLOAT.** `1.10.0` is newer
/// than `1.9.0`. As strings `"1.10.0" < "1.9.0"`; as floats `1.10 < 1.9`. Only
/// an explicit (major, minor, patch) integer comparison gets it right, and that
/// row is the first case in the shared fixture for exactly this reason.
///
/// The authority for this file's behaviour is
/// `protocol/fixtures/update/10-version-compare.json` — the SAME file the Rust
/// comparator in `server-core` loads. The implementation is written to satisfy
/// the fixture, not the other way round. The two sides disagreeing about what
/// "newer" means would show in the field as the phone offering an update the
/// server then refuses as `stale`.
library;

/// The ONLY accepted input form: an optional leading `v`, then exactly three
/// non-negative integer components.
///
/// A leading `v` is stripped because git tags are published as `vX.Y.Z` while
/// package versions are bare. Anything else — two components, four components,
/// a pre-release suffix, a build-metadata suffix, whitespace-only, a word — is
/// rejected outright rather than coerced.
final RegExp kSemVerPattern = RegExp(r'^v?(\d+)\.(\d+)\.(\d+)$');

/// A parsed `X.Y.Z` version, ordered by (major, minor, patch) as integers.
///
/// Immutable and `const`-constructible. There is deliberately no pre-release,
/// no build-metadata and no wildcard component: the update surface only ever
/// compares released triples, and anything richer would be a shape the shared
/// fixture cannot express.
class SemVer implements Comparable<SemVer> {
  /// Major component — dominates minor and patch entirely.
  final int major;

  /// Minor component — dominates patch.
  final int minor;

  /// Patch component.
  final int patch;

  /// Creates a version from its three already-validated components.
  const SemVer(this.major, this.minor, this.patch);

  /// Parses [s] as `X.Y.Z` or `vX.Y.Z` after trimming, returning `null` for
  /// anything else — the UNKNOWN answer.
  ///
  /// Returns `null` for `1.4` (two components are never coerced to `1.4.0`),
  /// for `1.4.0-rc1` (see the pre-release note below), for the empty string,
  /// for `latest`, and for any component that does not fit a Dart `int`.
  ///
  /// **Overflow is UNKNOWN, not saturation.** `999999999999999999999.0.0`
  /// matches the digit pattern but exceeds a 64-bit `int`; it is parsed with
  /// [int.tryParse] and yields `null` rather than throwing or clamping to a
  /// huge value that would compare as newer.
  ///
  /// **PRE-RELEASE CONSEQUENCE (deliberate, not accidental).** `X.Y.Z-rcN`
  /// returns `null`, so a pre-release is NEVER offered to a client. This is
  /// consistent with "update channels other than latest-stable" being out of
  /// scope for the phase, and GitHub's `releases/latest` already excludes
  /// pre-releases — making this client-side rejection a second belt rather
  /// than the primary mechanism. A `-PreRelease` publish is for the owner's
  /// own manual testing and is invisible to clients by design.
  static SemVer? tryParse(String s) {
    final match = kSemVerPattern.firstMatch(s.trim());
    if (match == null) return null;
    final major = int.tryParse(match[1]!);
    final minor = int.tryParse(match[2]!);
    final patch = int.tryParse(match[3]!);
    if (major == null || minor == null || patch == null) return null;
    return SemVer(major, minor, patch);
  }

  /// Orders by major, then minor, then patch — as integers, always.
  ///
  /// `SemVer.tryParse('1.10.0')!.compareTo(SemVer.tryParse('1.9.0')!)` is
  /// positive. A lexical or float comparison gets that backwards.
  @override
  int compareTo(SemVer other) {
    if (major != other.major) return major.compareTo(other.major);
    if (minor != other.minor) return minor.compareTo(other.minor);
    return patch.compareTo(other.patch);
  }

  @override
  bool operator ==(Object other) =>
      other is SemVer &&
      other.major == major &&
      other.minor == minor &&
      other.patch == patch;

  @override
  int get hashCode => Object.hash(major, minor, patch);

  /// The canonical `X.Y.Z` form — no leading `v`, no zero padding.
  @override
  String toString() => '$major.$minor.$patch';
}

/// The ONLY question the UI asks: is [candidate] strictly newer than
/// [installed]?
///
/// **Null-in means false: UNKNOWN is never newer.** If either side fails to
/// parse this returns `false`, so a malformed tag on either end of the
/// comparison can never trigger an update offer (D-26). Equality returns
/// `false` too — a version at or below the installed one is never offered.
bool isNewer({required String candidate, required String installed}) {
  final parsedCandidate = SemVer.tryParse(candidate);
  final parsedInstalled = SemVer.tryParse(installed);
  if (parsedCandidate == null || parsedInstalled == null) return false;
  return parsedCandidate.compareTo(parsedInstalled) > 0;
}

/// The canonical `X.Y.Z` form of [s] with any leading `v` stripped, or `null`
/// when [s] does not parse.
///
/// Used by the row copy, which renders the installed and latest versions
/// verbatim apart from that stripped `v` — never reformatted, never
/// zero-padded (UI-SPEC Copywriting Contract).
String? normalize(String s) => SemVer.tryParse(s)?.toString();
