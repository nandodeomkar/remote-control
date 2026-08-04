/// The Dart half of the release-feed parse contract (D-02, D-03, D-15, D-22).
///
/// Pinned to `protocol/fixtures/update/11-releases-latest.json` and
/// `12-releases-latest-null-digest.json` — the SAME two files the Rust parser
/// in `server-windows/src/update/feed.rs` loads (per-language copies are
/// forbidden, D-09). A disagreement between the two parsers is exactly what
/// this file exists to catch: it would show in the field as the phone offering
/// an update the server then refuses.
///
/// A feed body is UNTRUSTED input. Parsing must be TOTAL — no exception may
/// escape `parseRelease`, and no malformed shape may produce a half-built
/// [Release] that a later gate has to re-validate.
///
/// Nothing here touches the network: `fetchLatest` takes an injected client.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control/update/release_feed.dart';

import 'fake_http.dart';

/// Shared fixtures, relative to the package root — `flutter test` runs with
/// cwd = app/remote_control (the version_test.dart / beacon_test.dart idiom).
const String kReleasesFixture =
    '../../protocol/fixtures/update/11-releases-latest.json';
const String kNullDigestFixture =
    '../../protocol/fixtures/update/12-releases-latest-null-digest.json';

/// Guard: the relative fixture path only resolves from the package root. Fail
/// loudly with the canonical invocation — a path typo must never silently pass.
void requireFixture(String path) {
  if (!File(path).existsSync()) {
    fail(
      'Fixture not found at $path (cwd: ${Directory.current.path}). '
      'The canonical invocation is: cd app/remote_control && flutter test',
    );
  }
}

/// The `response` object of a releases fixture, re-encoded as the raw body a
/// real GET would return — so the parser is fed a STRING, exactly as in
/// production, not a pre-decoded map.
String fixtureBody(String path) {
  requireFixture(path);
  final root = jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;
  return jsonEncode(root['response']);
}

/// 64 hex characters, the shape every accepted digest has.
final RegExp k64Hex = RegExp(r'^[0-9a-f]{64}$');

void main() {
  group('parseRelease against the shared fixture', () {
    test('reads the version and all three assets with exact sizes/digests', () {
      final release = parseRelease(fixtureBody(kReleasesFixture));
      expect(release, isNotNull);
      // The leading `v` is stripped: the tag is `v1.5.0`, the version is not.
      expect(release!.version, '1.5.0');
      expect(release.assets, hasLength(3));

      final apk = assetWithPrefix(release, kApkAssetPrefix);
      final setup = assetWithPrefix(release, kSetupAssetPrefix);
      final ext = assetWithPrefix(release, kExtensionAssetPrefix);
      expect(apk, isNotNull);
      expect(setup, isNotNull);
      expect(ext, isNotNull);

      expect(apk!.name, 'RemoteControl-v1.5.0.apk');
      expect(setup!.name, 'RemoteControl-Setup-v1.5.0.exe');
      expect(ext!.name, 'RemoteControl-Extension-v1.5.0.zip');

      // D-08: the size is known BEFORE any download, so the row can render it.
      // These are the real observed artifact magnitudes, not round numbers.
      expect(apk.sizeBytes, 69630935);
      expect(setup.sizeBytes, 5177240);
      expect(ext.sizeBytes, 13454);

      for (final asset in [apk, setup, ext]) {
        expect(asset.sha256, isNotNull, reason: '${asset.name} lost its digest');
        expect(asset.sha256, matches(k64Hex),
            reason: '${asset.name} digest is not 64 lowercase hex');
        expect(asset.url, startsWith('https://'));
      }

      // The APK prefix must not swallow the setup exe or the extension zip.
      expect(apk.name, isNot(setup.name));
      expect(apk.name, isNot(ext.name));
    });

    test('a null digest parses to null, never to an empty string or a throw',
        () {
      final release = parseRelease(fixtureBody(kNullDigestFixture));
      expect(release, isNotNull);
      final setup = assetWithPrefix(release!, kSetupAssetPrefix);
      expect(setup, isNotNull);
      // D-15: the ABSENCE is preserved as null so the download gate can refuse
      // it. It is never coerced to '' and never treated as "verified".
      expect(setup!.sha256, isNull);
      // The other two assets still carry usable digests — the refusal is
      // per-asset, not per-release.
      expect(assetWithPrefix(release, kApkAssetPrefix)!.sha256, isNotNull);
      expect(assetWithPrefix(release, kExtensionAssetPrefix)!.sha256, isNotNull);
    });

    test('asset order is not assumed (the live feed returns them sorted)', () {
      // The live mirror returns Extension, Setup, APK (alphabetical) while the
      // fixture lists APK first. Resolution is by name, never by index.
      const body = '''
{"tag_name":"v9.9.9","assets":[
 {"name":"RemoteControl-Extension-v9.9.9.zip","browser_download_url":"https://x/e","size":1,"digest":null},
 {"name":"RemoteControl-Setup-v9.9.9.exe","browser_download_url":"https://x/s","size":2,"digest":null},
 {"name":"RemoteControl-v9.9.9.apk","browser_download_url":"https://x/a","size":3,"digest":null}]}''';
      final release = parseRelease(body)!;
      expect(assetWithPrefix(release, kApkAssetPrefix)!.sizeBytes, 3);
      expect(assetWithPrefix(release, kSetupAssetPrefix)!.sizeBytes, 2);
      expect(assetWithPrefix(release, kExtensionAssetPrefix)!.sizeBytes, 1);
    });
  });

  group('parseRelease is total on malformed input', () {
    test('returns null, never throws, for every malformed shape', () {
      // Malformed JSON.
      expect(parseRelease('not json at all'), isNull);
      expect(parseRelease(''), isNull);
      // Valid JSON, wrong root type.
      expect(parseRelease('[]'), isNull);
      expect(parseRelease('"latest"'), isNull);
      // Missing tag_name.
      expect(parseRelease('{"assets":[]}'), isNull);
      // tag_name of the wrong type.
      expect(parseRelease('{"tag_name":7,"assets":[]}'), isNull);
      // assets of the wrong shape.
      expect(parseRelease('{"tag_name":"v1.0.0","assets":{}}'), isNull);
      expect(parseRelease('{"tag_name":"v1.0.0","assets":["a"]}'), isNull);
      // An asset missing browser_download_url / size / name.
      expect(
        parseRelease('{"tag_name":"v1.0.0","assets":[{"name":"a","size":1}]}'),
        isNull,
      );
      expect(
        parseRelease(
          '{"tag_name":"v1.0.0","assets":[{"name":"a","browser_download_url":"u","size":"1"}]}',
        ),
        isNull,
      );
      // A digest of the wrong type (not a string, not null).
      expect(
        parseRelease(
          '{"tag_name":"v1.0.0","assets":[{"name":"a","browser_download_url":"u","size":1,"digest":7}]}',
        ),
        isNull,
      );
    });

    test('an omitted digest field is the same as an explicit null', () {
      const body =
          '{"tag_name":"v1.0.0","assets":[{"name":"RemoteControl-v1.0.0.apk","browser_download_url":"https://x/a","size":1}]}';
      final release = parseRelease(body);
      expect(release, isNotNull);
      expect(assetWithPrefix(release!, kApkAssetPrefix)!.sha256, isNull);
    });

    test('a tag with no leading v is carried verbatim', () {
      final release = parseRelease('{"tag_name":"1.5.0","assets":[]}');
      expect(release!.version, '1.5.0');
    });
  });

  group('stripDigest is deliberately strict', () {
    const hex = '3333cf18753033586c895652cd3cff6cd25c00b2e713a241a01a388c26e3f730';

    test('accepts sha256: plus exactly 64 hex', () {
      expect(stripDigest('sha256:$hex'), hex);
    });

    test('lowercases uppercase hex rather than rejecting it (Rust parity)', () {
      // The Rust `strip_digest` ends in `to_ascii_lowercase()`; a digest is a
      // value, not a spelling, and the two parsers must agree on it.
      expect(stripDigest('sha256:${hex.toUpperCase()}'), hex);
    });

    test('rejects a wrong algorithm, including an uppercase prefix', () {
      expect(stripDigest('sha1:$hex'), isNull);
      expect(stripDigest('md5:$hex'), isNull);
      // Rust's strip_prefix("sha256:") is case-sensitive, so this one is too.
      expect(stripDigest('SHA256:$hex'), isNull);
      expect(stripDigest(hex), isNull, reason: 'a bare hex string is not a digest');
    });

    test('rejects a wrong length and non-hex characters', () {
      expect(stripDigest('sha256:${hex.substring(1)}'), isNull);
      expect(stripDigest('sha256:${hex}0'), isNull);
      expect(stripDigest('sha256:'), isNull);
      expect(stripDigest('sha256:${'z' * 64}'), isNull);
      expect(stripDigest('sha256:$hex '), isNull, reason: 'anchored, no trailing junk');
    });

    test('null in, null out', () {
      expect(stripDigest(null), isNull);
    });
  });

  group('assetWithPrefix demands exactly one match', () {
    test('returns null for zero matches and for more than one', () {
      const two = '''
{"tag_name":"v1.0.0","assets":[
 {"name":"RemoteControl-v1.0.0.apk","browser_download_url":"https://x/a","size":1},
 {"name":"RemoteControl-v1.0.0-hotfix.apk","browser_download_url":"https://x/b","size":2}]}''';
      expect(assetWithPrefix(parseRelease(two)!, kApkAssetPrefix), isNull);
      expect(
        assetWithPrefix(parseRelease(two)!, kSetupAssetPrefix),
        isNull,
        reason: 'zero matches is also null',
      );
    });
  });

  group('fetchLatest collapses every failure to one silent null (D-22)', () {
    test('a dead network returns null and does not throw', () async {
      final client =
          FakeHttpClient.throwing(const SocketException('network is unreachable'));
      expect(await fetchLatest(client: client), isNull);
    });

    test('an HTTP 403 rate limit returns null and does not throw', () async {
      // RESEARCH Pitfall 2: a rate limit is a STATUS, not a socket error.
      final client = FakeHttpClient.responding(
        () => FakeHttpClientResponse.text(403, '{"message":"rate limit"}'),
      );
      expect(await fetchLatest(client: client), isNull);
    });

    test('a 200 with a malformed body returns null', () async {
      final client = FakeHttpClient.responding(
        () => FakeHttpClientResponse.text(200, 'not json'),
      );
      expect(await fetchLatest(client: client), isNull);
    });

    test('a 200 with the fixture body parses, hits kReleasesApi, and sends '
        'a User-Agent but NO Authorization (D-01)', () async {
      final body = fixtureBody(kReleasesFixture);
      final client = FakeHttpClient.responding(
        () => FakeHttpClientResponse.text(200, body),
      );
      final release = await fetchLatest(client: client);
      expect(release, isNotNull);
      expect(release!.version, '1.5.0');

      expect(client.requested.single.toString(), kReleasesApi);
      final headers = client.lastRequest!.headers as FakeHttpHeaders;
      expect(headers.values['user-agent'], isNotEmpty);
      expect(
        headers.values.keys,
        isNot(contains('authorization')),
        reason: 'a credential on the public mirror is D-01 violated',
      );
      // An injected client is the caller's to close.
      expect(client.closed, isFalse);
    });
  });
}
