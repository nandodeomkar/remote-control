/// Stream the APK to the app cache, hash it in chunks, and refuse to leave it
/// on disk unless it matched its published digest (D-15, D-19, D-23).
///
/// **THIS FILE IS THE SECURITY GATE.** The bytes it writes are about to be
/// handed to Android's `PackageInstaller` and installed with the owner's
/// consent, so the sha256 comparison in [verifyOrDelete] is the ONLY thing
/// standing between a tampered artifact and an installed application
/// (T-12-31). It lives in Dart, not in Kotlin, on purpose: a gate inside
/// platform code is unreachable by the widget test suite, and SC4 asks for
/// "sha256 verified before install" to be a checkable claim rather than a
/// reviewable one. `ApkInstaller.install` is never called until this file has
/// returned `true`.
///
/// **A NULL DIGEST IS A HARD REFUSAL, NEVER A SKIPPED VERIFICATION (D-15).**
/// GitHub only began populating per-asset `digest` on 2025-06-03, so `null` is
/// a real state a real release can be in — and the correct response to "we
/// cannot verify this" is to delete it, not to install it and trust TLS.
///
/// **NEVER TWO COPIES OF 70 MB (T-12-33).** The response is streamed straight
/// into an `IOSink` and the file is hashed by the crypto package's chunked
/// conversion API, fed from `openRead()` (see [sha256OfFile] — the call is
/// spelled exactly once in this file, which is the gate). There is no
/// read-the-whole-file-into-a-list call anywhere here and there must never be
/// one; a phone with a full-ish heap would OOM on the second copy long before
/// the install.
///
/// **EVERY FAILURE PATH DELETES (D-23).** A dropped socket, a non-200, a write
/// error, a full disk and a digest mismatch all end with the partial or bad
/// file removed. A stale file at the destination is also removed BEFORE the
/// download starts, so repeated failures cannot accumulate ~70 MB each in the
/// cache (T-12-34).
///
/// **THE CALLER LEARNS A WORD, NOT AN EXCEPTION (T-12-06).** Outcomes map to
/// the closed vocabulary the UI renders — [DownloadError.network],
/// [DownloadError.disk], [DownloadError.checksum]. Exception text, file paths
/// and URLs go to the log only; the UI copy map never renders a code and must
/// never be handed a string it would be tempted to.
///
/// **NO DIRECTORY-LOOKUP PACKAGE.** The cache directory comes from the
/// existing `remote_control/installer` MethodChannel (`ApkInstaller.cacheDir()`
/// — added by 12-08 for exactly this caller), which keeps this phase's
/// new-dependency surface at exactly one Dart package. The usual plugin for
/// this job is deliberately not named anywhere in this file; a grep for it
/// must return zero hits.
library;

import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import 'apk_installer.dart';
import 'release_feed.dart';

// -- Constants ---------------------------------------------------------------

/// The closed error vocabulary this module reports. There is deliberately no
/// `parse`, no `ratelimit` and no `unknown`: D-11's vocabulary is closed, and
/// a code the UI has no sentence for is a code the user cannot act on.
enum DownloadError {
  /// The bytes never arrived: a dead socket, a timeout, or a non-200 status
  /// (a rate limit is a status, not a socket error — RESEARCH Pitfall 2).
  network,

  /// The bytes arrived but could not be stored: a write error or a full disk.
  disk,

  /// The bytes arrived and could not be trusted: a digest mismatch, or no
  /// published digest at all (D-15).
  checksum,
}

/// TCP/TLS connect budget for the artifact GET.
const Duration kDownloadConnectTimeout = Duration(seconds: 10);

/// Maximum silence BETWEEN chunks. A black-holed socket must not park the
/// download forever with the row frozen at a fixed percentage; this is the
/// explicit bound T-12-33 asks for. It is deliberately not an overall budget:
/// 70 MB over a weak link is slow, not broken.
const Duration kDownloadStallTimeout = Duration(seconds: 60);

/// Progress is emitted at most once per whole percent...
const int kProgressPercentStep = 1;

/// ...or once per this interval, whichever comes first. A 70 MB body arrives
/// in thousands of chunks; an unthrottled callback would rebuild the row
/// thousands of times. This is the same throttle shape the server-side
/// progress uses.
const Duration kProgressMinInterval = Duration(milliseconds: 250);

/// The name a downloaded artifact is stored under when the published asset
/// name is not a plain file name. See [safeFileName].
const String kFallbackApkFileName = 'update.apk';

/// Plain file names only: letters, digits, dot, dash, underscore.
final RegExp kSafeFileNamePattern = RegExp(r'^[A-Za-z0-9._-]+$');

// -- Helpers -----------------------------------------------------------------

/// The name [assetName] may be stored under, or [kFallbackApkFileName].
///
/// The asset name arrives from the network. It is joined to a directory path,
/// so a name containing `..`, `/` or `\` would write outside the app cache —
/// the destination is chosen by this device, never by the feed. Anything that
/// is not a plain file name is replaced outright rather than sanitised
/// piecewise, because a partial escape is the failure mode that gets missed.
String safeFileName(String assetName) {
  if (!kSafeFileNamePattern.hasMatch(assetName) || assetName.startsWith('.')) {
    debugPrint('update: asset name is not a plain file name — using a fallback');
    return kFallbackApkFileName;
  }
  return assetName;
}

/// Best-effort delete. Used on every failure path, so it must never throw and
/// never mask the failure that led here.
Future<void> deleteQuietly(File file) async {
  try {
    if (await file.exists()) await file.delete();
  } catch (e) {
    debugPrint('update: could not remove a partial download: $e');
  }
}

/// The app cache directory from the installer channel, or the system temp
/// directory where that channel does not exist (unit tests, non-Android).
Future<Directory> resolveCacheDir() async {
  try {
    final path = await ApkInstaller().cacheDir();
    if (path != null && path.isNotEmpty) return Directory(path);
  } catch (e) {
    debugPrint('update: cacheDir unavailable, falling back to temp: $e');
  }
  return Directory.systemTemp;
}

// -- Download ----------------------------------------------------------------

/// Stream [asset] to the app cache, reporting throttled progress.
///
/// Returns the file path on success and `null` on EVERY failure, having
/// deleted whatever it had written. [onError] receives the mapped
/// [DownloadError] — it is the only channel by which a failure reason leaves
/// this function, and it carries a word from the closed vocabulary, never a
/// message.
///
/// The file is NOT verified here. [verifyOrDelete] is a separate call so the
/// gate is visible at the call site rather than buried in a success path.
///
/// [client] and [destDir] are injectable so tests never touch the network or
/// the platform channel.
Future<String?> downloadApk(
  ReleaseAsset asset, {
  required void Function(int received, int total) onProgress,
  HttpClient? client,
  Directory? destDir,
  void Function(DownloadError code)? onError,
}) async {
  final http =
      client ?? (HttpClient()..connectionTimeout = kDownloadConnectTimeout);
  final owned = client == null;
  final dir = destDir ?? await resolveCacheDir();
  final file = File('${dir.path}${Platform.pathSeparator}${safeFileName(asset.name)}');

  IOSink? sink;

  Future<String?> fail(DownloadError code, Object reason) async {
    debugPrint('update: apk download failed (${code.name}): $reason');
    if (sink != null) {
      // The sink may already be in an error state; closing it is best-effort
      // and must not replace the real failure.
      try {
        await sink.close();
      } catch (_) {
        // Already broken — the delete below is what matters.
      }
    }
    await deleteQuietly(file);
    onError?.call(code);
    return null;
  }

  try {
    // A stale artifact from a previous failed attempt is removed BEFORE the
    // write, so a repeatedly failing update cannot fill the cache (T-12-34)
    // and a resumed-looking partial can never be mistaken for a full file.
    await deleteQuietly(file);

    final HttpClientResponse response;
    try {
      final request = await http.getUrl(Uri.parse(asset.url));
      request.headers.set(HttpHeaders.userAgentHeader, kUpdateUserAgent);
      response = await request.close();
    } catch (e) {
      return await fail(DownloadError.network, e);
    }

    if (response.statusCode != HttpStatus.ok) {
      // Note the status in the log — a 404 means the release moved, a 403
      // means the signed CDN URL expired (which is why a resolved
      // browser_download_url is never cached; see release_feed.dart).
      try {
        await response.drain<void>();
      } catch (_) {
        // Draining is courtesy; the failure is already decided.
      }
      return await fail(DownloadError.network, 'HTTP ${response.statusCode}');
    }

    // The published size is authoritative for the progress denominator: it is
    // known before the first byte (D-08), so the row can render a percentage
    // from the very first callback instead of after a Content-Length probe.
    final total = asset.sizeBytes > 0
        ? asset.sizeBytes
        : (response.contentLength > 0 ? response.contentLength : 0);

    try {
      sink = file.openWrite();
    } catch (e) {
      return await fail(DownloadError.disk, e);
    }

    var received = 0;
    var reported = -1;
    var reportedPercent = -1;
    final since = Stopwatch()..start();
    var lastReportMs = -kProgressMinInterval.inMilliseconds;

    void report({bool force = false}) {
      if (received <= reported) return;
      final percent = total > 0 ? (received * 100) ~/ total : 0;
      final elapsedMs = since.elapsedMilliseconds;
      final due = percent >= reportedPercent + kProgressPercentStep ||
          elapsedMs - lastReportMs >= kProgressMinInterval.inMilliseconds;
      if (!force && !due) return;
      reported = received;
      reportedPercent = percent;
      lastReportMs = elapsedMs;
      onProgress(received, total);
    }

    try {
      await for (final chunk in response.timeout(kDownloadStallTimeout)) {
        sink.add(chunk);
        received += chunk.length;
        report();
      }
    } catch (e) {
      // A dropped connection or a stall. Anything the sink already swallowed
      // surfaces at close(), inside fail().
      return await fail(DownloadError.network, e);
    }

    try {
      // Flush and close BEFORE hashing: a buffered tail would hash wrong, and
      // a "verified" file that is missing its last chunk is the worst possible
      // outcome of this module.
      await sink.flush();
      await sink.close();
      sink = null;
    } catch (e) {
      // ENOSPC lands here — the writes were accepted into the buffer and the
      // flush is where the disk says no.
      return await fail(DownloadError.disk, e);
    }

    // The terminal callback always lands on the true byte count, so a UI that
    // renders the last event shows a completed bar rather than 99%.
    report(force: true);
    return file.path;
  } finally {
    if (owned) http.close(force: true);
  }
}

// -- Hash and verify ---------------------------------------------------------

/// Collects the single [Digest] a chunked sha256 conversion emits.
///
/// Hand-written instead of `AccumulatorSink` from `package:convert`: that
/// package is only a transitive dependency here, and depending on a package
/// that is not declared is both a lint failure and a thing that silently
/// breaks when the transitive graph shifts. Four lines is cheaper than a
/// second declared dependency in a phase whose budget is one.
class DigestSink implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}

/// Lowercase hex sha256 of [file], hashed in chunks.
///
/// Never reads the file into a single list — see the library doc comment. The
/// caller is a ~70 MB APK on a phone.
Future<String> sha256OfFile(File file) async {
  final output = DigestSink();
  final input = sha256.startChunkedConversion(output);
  await for (final chunk in file.openRead()) {
    input.add(chunk);
  }
  input.close();
  final digest = output.value;
  if (digest == null) {
    // Unreachable: close() always emits. Stated rather than assumed, because
    // a silently empty digest would compare unequal and merely look like a
    // mismatch instead of a bug.
    throw StateError('sha256 conversion produced no digest');
  }
  return digest.toString();
}

/// The gate: `true` only if [file] hashes to [expectedHex]. Otherwise the file
/// is DELETED and `false` is returned.
///
/// This runs after the sink is flushed and closed, and BEFORE the path is ever
/// handed to `ApkInstaller.install`. Nothing else in the app may call
/// `install` on a file this function has not approved.
///
/// A null or empty [expectedHex] is a HARD failure (D-15). The temptation it
/// refuses is real — the download succeeded, the bytes are probably fine, and
/// skipping the comparison would "work". It is refused because the digest is
/// the only integrity check that exists, and an absent one means the check was
/// never possible, not that it passed.
///
/// The comparison is case-insensitive on both sides: [stripDigest] already
/// lowercases what the feed published, and this trims and lowercases again so
/// a hand-supplied expectation cannot fail on spelling alone.
Future<bool> verifyOrDelete(File file, String? expectedHex) async {
  final expected = expectedHex?.trim().toLowerCase();
  if (expected == null || expected.isEmpty) {
    debugPrint('update: no published sha256 for this asset — refusing (D-15)');
    await deleteQuietly(file);
    return false;
  }

  final String actual;
  try {
    actual = await sha256OfFile(file);
  } catch (e) {
    debugPrint('update: could not hash the downloaded file: $e');
    await deleteQuietly(file);
    return false;
  }

  if (actual != expected) {
    debugPrint('update: sha256 mismatch — deleting the downloaded file');
    await deleteQuietly(file);
    return false;
  }
  return true;
}
