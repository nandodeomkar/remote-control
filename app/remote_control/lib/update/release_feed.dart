/// The phone's own half of the release-feed contract (D-02, D-03).
///
/// The phone fetches `releases/latest` ITSELF and resolves the APK itself,
/// because the phone is the tier that EXECUTES the APK. That is the same rule
/// as D-14, not an exception to it: the tier that runs a file is the tier that
/// names it. This module never names a file for the PC and never accepts one
/// from it — `update.apply` carries a version string and nothing else.
///
/// **THE API IS THE MANIFEST (D-03).** There is deliberately no separate
/// manifest file to keep in sync: the releases response already carries the
/// tag, the asset names, the sizes and a per-asset sha256. A second source of
/// truth could drift from the assets it describes. Every other field the API
/// returns is ignored.
///
/// **NO CREDENTIAL HEADER, EVER (D-01).** The mirror repo is public precisely
/// so the client can read it anonymously; sending a token would reintroduce
/// the credential problem the mirror exists to avoid, and a credential on a
/// redirected request leaks to whatever the redirect target is. The cost is
/// GitHub's anonymous 60-requests/hour/IP limit, which a once-a-day check does
/// not come close to. The standard HTTP credential header is deliberately not
/// even NAMED anywhere in this file, so a case-insensitive grep for it must
/// return zero hits — that makes the rule a gate rather than a comment. The
/// executable half of the assertion lives in `release_feed_test.dart`, which
/// reads back every header the request set and requires that key to be absent.
///
/// **NEVER CACHE A RESOLVED `browser_download_url`.** That URL redirects to a
/// time-limited signed CDN URL; a stored one is a link that works today and
/// 404s tomorrow. Re-resolve the release immediately before each download —
/// `fetchLatest` is cheap and the whole point of D-03 is that the feed is the
/// live answer.
///
/// **EVERY FAILURE IS ONE FAILURE (D-22).** A dead network, an HTTP 403 from
/// the rate limiter (RESEARCH Pitfall 2 — a rate limit is a status code, not a
/// socket error) and a body that will not parse all collapse to `null` here,
/// which the UI renders as the single "couldn't check" state. The three are
/// logged DIFFERENTLY so a 403 is diagnosable, but no exception text, URL or
/// status code is ever handed to the caller.
///
/// The authority for the parse is
/// `protocol/fixtures/update/11-releases-latest.json` — the SAME file the Rust
/// parser in `server-windows/src/update/feed.rs` loads. [stripDigest] and
/// [parseRelease] are written to agree with `strip_digest` / `parse_release`
/// case for case; a disagreement would show in the field as the phone offering
/// an update the server then refuses.
///
/// SDK primitives over wrappers: `dart:io HttpClient`, never the pub `http`
/// package — the same call the beacon made when it chose `RawDatagramSocket`
/// over the stale `udp` package. (The wrapper's package: URI is not spelled
/// here either; a grep for it under `lib/update/` must return zero hits.)
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

// -- Constants ---------------------------------------------------------------

/// The public mirror's `releases/latest` endpoint (D-02).
///
/// Spelled exactly once in the Dart tree, the way `RELEASES_API` is spelled
/// exactly once in the Rust tree. It is a compile-time constant: it is never
/// read from config, never read from the wire, and never influenced by
/// anything the PC says.
const String kReleasesApi =
    'https://api.github.com/repos/nandodeomkar/remote-control-releases/releases/latest';

/// Android APK: `RemoteControl-v1.5.0.apk`.
const String kApkAssetPrefix = 'RemoteControl-v';

/// Windows setup exe: `RemoteControl-Setup-v1.5.0.exe`.
const String kSetupAssetPrefix = 'RemoteControl-Setup-v';

/// Browser extension zip: `RemoteControl-Extension-v1.5.0.zip`.
const String kExtensionAssetPrefix = 'RemoteControl-Extension-v';

/// GitHub requires a User-Agent on API requests; the same string the server's
/// `feed_agent()` sends.
const String kUpdateUserAgent = 'RemoteControl-Updater';

/// TCP/TLS connect budget. A connect slower than this is a broken network.
const Duration kFeedConnectTimeout = Duration(seconds: 5);

/// Overall budget for the feed GET. Ten seconds is generous for a small JSON
/// body — the server's `feed_agent()` uses the same number for the same
/// reason.
const Duration kFeedTimeout = Duration(seconds: 10);

/// The `Accept` GitHub documents for its REST API. Not a credential.
const String kGitHubAccept = 'application/vnd.github+json';

// -- Types -------------------------------------------------------------------

/// One published artifact, reduced to the four values that matter.
///
/// Value-equal so provider state comparisons (and widget rebuild suppression)
/// behave: two fetches of an unchanged release compare equal.
class ReleaseAsset {
  const ReleaseAsset({
    required this.name,
    required this.url,
    required this.sizeBytes,
    required this.sha256,
  });

  /// The published file name, e.g. `RemoteControl-v1.5.0.apk`.
  final String name;

  /// `browser_download_url`. **Time-limited once resolved** — see the library
  /// doc comment; never persist it.
  final String url;

  /// `size` in bytes, available BEFORE a download starts so the row can render
  /// `{size}` (D-08).
  final int sizeBytes;

  /// The digest with the `sha256:` prefix already stripped and lowercased.
  ///
  /// `null` means the API returned null, omitted the field, or returned
  /// something that is not a sha256 digest. Null is a HARD REFUSAL upstream
  /// (D-15) — it is never permission to skip verification.
  final String? sha256;

  @override
  bool operator ==(Object other) =>
      other is ReleaseAsset &&
      other.name == name &&
      other.url == url &&
      other.sizeBytes == sizeBytes &&
      other.sha256 == sha256;

  @override
  int get hashCode => Object.hash(name, url, sizeBytes, sha256);

  @override
  String toString() => 'ReleaseAsset($name, $sizeBytes B, sha256: $sha256)';
}

/// The one release the feed calls "latest".
class Release {
  const Release({required this.version, required this.assets});

  /// The tag with any leading `v` already stripped: `1.5.0`, not `v1.5.0`.
  ///
  /// Carried VERBATIM apart from that `v`. It is deliberately not run through
  /// `normalize()` here: deciding whether a version is usable is
  /// `version.dart`'s job (UNKNOWN IS NEVER NEWER), and rejecting the whole
  /// release at parse time would turn a version question into a feed error.
  final String version;

  /// Every asset the release published, in the order the API returned them.
  ///
  /// **Order is not a contract.** The live feed returns them alphabetically
  /// (Extension, Setup, APK) while the fixture lists them APK-first; resolve
  /// by name with [assetWithPrefix], never by index.
  final List<ReleaseAsset> assets;

  @override
  bool operator ==(Object other) =>
      other is Release &&
      other.version == version &&
      listEquals(other.assets, assets);

  @override
  int get hashCode => Object.hash(version, Object.hashAll(assets));

  @override
  String toString() => 'Release($version, ${assets.length} assets)';
}

// -- Pure parsing ------------------------------------------------------------

/// `sha256:` + exactly 64 hex characters. Anchored, so trailing junk fails.
final RegExp kSha256DigestPattern = RegExp(r'^sha256:([0-9a-fA-F]{64})$');

/// `Some('sha256:<64 hex>')` -> the 64 lowercase hex characters; everything
/// else -> `null`.
///
/// Deliberately strict, and deliberately identical to the Rust `strip_digest`:
/// `null` for a null digest, for a different algorithm prefix (`sha1:`,
/// `md5:` — a weaker hash is not a hash we accept), for a wrong length, for
/// non-hex characters, and for an uppercase `SHA256:` prefix (the Rust side's
/// `strip_prefix("sha256:")` is case-sensitive, so this one is too). Every one
/// of those becomes a hard refusal upstream, so a permissive parser here would
/// be a silently disabled integrity check.
///
/// Uppercase HEX is accepted and lowercased rather than rejected — again
/// matching Rust's `to_ascii_lowercase`. The digest is a value, not a
/// spelling, and the two parsers must agree on it.
String? stripDigest(String? raw) {
  if (raw == null) return null;
  final match = kSha256DigestPattern.firstMatch(raw);
  if (match == null) return null;
  return match[1]!.toLowerCase();
}

/// Parse a `releases/latest` body into a [Release]. PURE — no I/O, total.
///
/// Returns `null` for anything malformed rather than throwing: a body that
/// will not read is, from the user's side, the same event as a feed that could
/// not be reached, and the error vocabulary has no `parse` code (D-11 is
/// closed). Mirrors the Rust `parse_release`, which maps a serde failure to
/// `UpdateError::Network` for exactly that reason.
Release? parseRelease(String body) {
  try {
    final decoded = jsonDecode(body);
    if (decoded is! Map<String, dynamic>) return null;

    final tag = decoded['tag_name'];
    if (tag is! String || tag.isEmpty) return null;

    final rawAssets = decoded['assets'];
    if (rawAssets is! List) return null;

    final assets = <ReleaseAsset>[];
    for (final raw in rawAssets) {
      if (raw is! Map) return null;
      final name = raw['name'];
      final url = raw['browser_download_url'];
      final size = raw['size'];
      if (name is! String || url is! String || size is! int) return null;
      final digest = raw['digest'];
      if (digest != null && digest is! String) return null;
      assets.add(
        ReleaseAsset(
          name: name,
          url: url,
          sizeBytes: size,
          sha256: stripDigest(digest as String?),
        ),
      );
    }

    return Release(
      version: tag.startsWith('v') ? tag.substring(1) : tag,
      assets: assets,
    );
  } catch (e) {
    // jsonDecode throws FormatException on a malformed body; nothing else in
    // here should throw, but the contract is total either way.
    debugPrint('update: releases feed body did not parse: $e');
    return null;
  }
}

/// The single asset whose name starts with [prefix], or `null` for zero or
/// more than one match.
///
/// The three prefixes are disjoint by construction — `RemoteControl-Setup-v`
/// and `RemoteControl-Extension-v` both diverge from `RemoteControl-v` at the
/// character after `RemoteControl-`, so the APK prefix cannot swallow the
/// other two. This function relies on that: it demands exactly one match, and
/// a release that published two matching assets is malformed, not ambiguous.
///
/// A digest is NOT checked here. The digest refusal (D-15) belongs at the gate
/// that would have used it — `verifyOrDelete` in `apk_download.dart`.
ReleaseAsset? assetWithPrefix(Release release, String prefix) {
  ReleaseAsset? found;
  for (final asset in release.assets) {
    if (!asset.name.startsWith(prefix)) continue;
    if (found != null) {
      debugPrint('update: release ${release.version} has >1 asset for $prefix');
      return null;
    }
    found = asset;
  }
  if (found == null) {
    debugPrint('update: release ${release.version} has no asset for $prefix');
  }
  return found;
}

// -- Network -----------------------------------------------------------------

/// GET the feed and parse it, or `null` on ANY failure.
///
/// Inject [client] in tests so nothing here ever touches the network. When no
/// client is injected one is created, given a connect timeout, and closed in
/// `finally` — an unclosed `HttpClient` keeps its idle sockets and the
/// process' Dart VM alive.
///
/// Never throws. A status failure logs the NUMBER (so a 403 rate limit is
/// diagnosable) and a transport failure logs the exception; both return the
/// same `null`, because the UI has exactly one word for them (D-22).
Future<Release?> fetchLatest({HttpClient? client}) async {
  final http = client ?? (HttpClient()..connectionTimeout = kFeedConnectTimeout);
  final owned = client == null;
  try {
    final request = await http.getUrl(Uri.parse(kReleasesApi)).timeout(kFeedTimeout);
    request.headers.set(HttpHeaders.userAgentHeader, kUpdateUserAgent);
    request.headers.set(HttpHeaders.acceptHeader, kGitHubAccept);
    // NOTE: exactly two headers are set, and neither carries a credential
    // (D-01). If a third ever appears here, the grep gate above fails — on
    // purpose.
    final response = await request.close().timeout(kFeedTimeout);

    if (response.statusCode != HttpStatus.ok) {
      // Pitfall 2: a rate limit is an HTTP 403, not a socket error. Log the
      // number; the user still only ever sees "couldn't check".
      debugPrint('update: releases feed returned HTTP ${response.statusCode}');
      await response.drain<void>();
      return null;
    }

    final body =
        await response.transform(utf8.decoder).join().timeout(kFeedTimeout);
    return parseRelease(body);
  } catch (e) {
    // SocketException, HandshakeException, TimeoutException, HttpException —
    // one transport failure, distinguishable in the log from the status branch
    // above and indistinguishable to the caller.
    debugPrint('update: releases feed transport failure: $e');
    return null;
  } finally {
    if (owned) http.close(force: true);
  }
}
