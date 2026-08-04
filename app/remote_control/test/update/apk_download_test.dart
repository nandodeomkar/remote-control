/// The APK download gate: stream, throttle, chunk-hash, verify — or delete
/// (D-15, D-19, D-23).
///
/// Every test here is OFFLINE and hermetic: the `HttpClient` is a fake from
/// `fake_http.dart` and the destination is an injected temp directory, so
/// nothing touches the network, the platform channel or the real app cache.
///
/// The assertions that matter most are the ABSENCE assertions. "Returns null
/// on failure" is easy to satisfy while leaving a 70 MB partial (or a
/// tampered APK) sitting in the cache; the tests below check the filesystem
/// after every failure path, because that is the property D-23 actually
/// promises and the property a review cannot see.
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control/update/apk_download.dart';
import 'package:remote_control/update/release_feed.dart';

import 'fake_http.dart';

/// An asset that names a plain file and carries [sha256].
ReleaseAsset assetFor(List<int> body, {String? sha256, String? name}) =>
    ReleaseAsset(
      name: name ?? 'RemoteControl-v9.9.9.apk',
      url: 'https://example.invalid/RemoteControl-v9.9.9.apk',
      sizeBytes: body.length,
      sha256: sha256,
    );

/// Deterministic bytes, big enough to arrive in several chunks.
List<int> bodyBytes(int chunks, int chunkSize) =>
    List<int>.generate(chunks * chunkSize, (i) => i % 251);

List<List<int>> chunked(List<int> bytes, int chunkSize) {
  final out = <List<int>>[];
  for (var i = 0; i < bytes.length; i += chunkSize) {
    out.add(bytes.sublist(i, (i + chunkSize).clamp(0, bytes.length)));
  }
  return out;
}

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('rc-apk-download-test');
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  File destFor(String name) => File('${temp.path}${Platform.pathSeparator}$name');

  group('downloadApk streams to the cache', () {
    test('a successful download reports non-decreasing progress ending at the '
        'total and returns a path', () async {
      final bytes = bodyBytes(40, 4096);
      final asset = assetFor(bytes);
      final client = FakeHttpClient.responding(
        () => FakeHttpClientResponse.chunks(chunked(bytes, 4096)),
      );

      final events = <List<int>>[];
      final path = await downloadApk(
        asset,
        client: client,
        destDir: temp,
        onProgress: (received, total) => events.add([received, total]),
      );

      expect(path, isNotNull);
      expect(File(path!).existsSync(), isTrue);
      expect(await File(path).length(), bytes.length);
      expect(path, startsWith(temp.path), reason: 'never outside the given dir');

      expect(events, isNotEmpty);
      for (final e in events) {
        expect(e[1], bytes.length, reason: 'the denominator is the published size');
      }
      for (var i = 1; i < events.length; i++) {
        expect(events[i][0], greaterThan(events[i - 1][0]),
            reason: 'progress never goes backwards');
      }
      // The terminal callback lands on the true byte count, so a UI rendering
      // the last event shows a completed bar rather than 99%.
      expect(events.last[0], bytes.length);
    });

    test('progress is throttled — far fewer callbacks than chunks', () async {
      // 400 chunks of 1 KiB. Unthrottled that is 400 row rebuilds; the 1%
      // rule caps it near 100 (plus the terminal emit).
      final bytes = bodyBytes(400, 1024);
      final asset = assetFor(bytes);
      final client = FakeHttpClient.responding(
        () => FakeHttpClientResponse.chunks(chunked(bytes, 1024)),
      );

      var calls = 0;
      final path = await downloadApk(
        asset,
        client: client,
        destDir: temp,
        onProgress: (_, _) => calls++,
      );

      expect(path, isNotNull);
      expect(calls, lessThan(200), reason: 'a 70 MB body must not flood the UI');
      expect(calls, greaterThan(1));
    });

    test('an asset name that is not a plain file name cannot escape the '
        'destination directory', () async {
      final bytes = bodyBytes(1, 32);
      final asset = assetFor(bytes, name: '../../../../evil.apk');
      final client = FakeHttpClient.responding(
        () => FakeHttpClientResponse.chunks(chunked(bytes, 32)),
      );

      final path = await downloadApk(
        asset,
        client: client,
        destDir: temp,
        onProgress: (_, _) {},
      );

      expect(path, isNotNull);
      expect(path, startsWith(temp.path));
      expect(path, endsWith(kFallbackApkFileName));
    });
  });

  group('downloadApk deletes on every failure path (D-23)', () {
    test('a mid-stream error deletes the partial file and returns null',
        () async {
      final bytes = bodyBytes(20, 4096);
      final asset = assetFor(bytes);
      final client = FakeHttpClient.responding(
        () => FakeHttpClientResponse.chunksThenError(
          chunked(bytes, 4096).take(5).toList(),
          const SocketException('connection reset by peer'),
        ),
      );

      DownloadError? code;
      final path = await downloadApk(
        asset,
        client: client,
        destDir: temp,
        onProgress: (_, _) {},
        onError: (c) => code = c,
      );

      expect(path, isNull);
      expect(code, DownloadError.network);
      // THE assertion: no partial survives an interrupted download.
      expect(destFor(asset.name).existsSync(), isFalse);
      expect(temp.listSync(), isEmpty);
    });

    test('a dead socket returns null with no file created', () async {
      final asset = assetFor(bodyBytes(1, 16));
      final client =
          FakeHttpClient.throwing(const SocketException('network unreachable'));

      DownloadError? code;
      final path = await downloadApk(
        asset,
        client: client,
        destDir: temp,
        onProgress: (_, _) {},
        onError: (c) => code = c,
      );

      expect(path, isNull);
      expect(code, DownloadError.network);
      expect(temp.listSync(), isEmpty);
    });

    test('a non-200 status is a network failure, and a stale file from a '
        'previous attempt is removed anyway', () async {
      final asset = assetFor(bodyBytes(1, 16));
      // A leftover from an earlier failed attempt — it must not survive, and
      // it must never be mistaken for a completed download (T-12-34).
      final stale = destFor(asset.name);
      await stale.writeAsString('stale partial');

      final client = FakeHttpClient.responding(
        () => FakeHttpClientResponse.text(404, 'gone'),
      );

      DownloadError? code;
      final path = await downloadApk(
        asset,
        client: client,
        destDir: temp,
        onProgress: (_, _) {},
        onError: (c) => code = c,
      );

      expect(path, isNull);
      expect(code, DownloadError.network);
      expect(stale.existsSync(), isFalse);
    });

    test('a destination that cannot be written is a disk failure', () async {
      final bytes = bodyBytes(1, 16);
      final asset = assetFor(bytes);
      final client = FakeHttpClient.responding(
        () => FakeHttpClientResponse.chunks(chunked(bytes, 16)),
      );
      // A directory that does not exist stands in for "the write failed" —
      // the same branch a full disk takes.
      final missing = Directory('${temp.path}${Platform.pathSeparator}nope');

      DownloadError? code;
      final path = await downloadApk(
        asset,
        client: client,
        destDir: missing,
        onProgress: (_, _) {},
        onError: (c) => code = c,
      );

      expect(path, isNull);
      expect(code, DownloadError.disk);
      expect(missing.existsSync(), isFalse);
    });
  });

  group('sha256OfFile hashes in chunks', () {
    test('matches a precomputed digest for known bytes', () async {
      final file = destFor('known.bin');
      await file.writeAsString('remote control');
      final expected = sha256.convert(utf8.encode('remote control')).toString();

      expect(await sha256OfFile(file), expected);
      expect(expected, matches(RegExp(r'^[0-9a-f]{64}$')));
    });

    test('agrees with a one-shot digest over a multi-chunk file', () async {
      final bytes = bodyBytes(64, 8192); // 512 KiB, many openRead chunks
      final file = destFor('big.bin');
      await file.writeAsBytes(bytes);

      expect(await sha256OfFile(file), sha256.convert(bytes).toString());
    });
  });

  group('verifyOrDelete is the gate before install', () {
    late File file;
    late String digest;

    setUp(() async {
      final bytes = bodyBytes(4, 1024);
      file = destFor('RemoteControl-v9.9.9.apk');
      await file.writeAsBytes(bytes);
      digest = sha256.convert(bytes).toString();
    });

    test('a correct digest returns true and LEAVES the file', () async {
      expect(await verifyOrDelete(file, digest), isTrue);
      expect(file.existsSync(), isTrue);
    });

    test('an uppercase expectation still matches (case-insensitive)', () async {
      expect(await verifyOrDelete(file, digest.toUpperCase()), isTrue);
      expect(file.existsSync(), isTrue);
    });

    test('a wrong digest returns false AND removes the file', () async {
      expect(await verifyOrDelete(file, '0' * 64), isFalse);
      expect(file.existsSync(), isFalse,
          reason: 'a file that failed its checksum must never survive');
    });

    test('a NULL expected digest returns false AND removes the file (D-15)',
        () async {
      // The whole point: an absent digest is a refusal, never a skipped
      // verification. This is the exact state a pre-2025-06-03 asset is in.
      expect(await verifyOrDelete(file, null), isFalse);
      expect(file.existsSync(), isFalse);
    });

    test('an EMPTY expected digest returns false AND removes the file',
        () async {
      expect(await verifyOrDelete(file, '   '), isFalse);
      expect(file.existsSync(), isFalse);
    });

    test('a missing file is a refusal, not a crash', () async {
      final absent = destFor('not-there.apk');
      expect(await verifyOrDelete(absent, digest), isFalse);
      expect(absent.existsSync(), isFalse);
    });
  });

  group('download then verify, end to end and offline', () {
    test('a tampered body downloads but never survives verification',
        () async {
      final published = bodyBytes(8, 1024);
      final tampered = bodyBytes(8, 1024)..[100] = 0xFF;
      final asset = assetFor(
        published,
        sha256: sha256.convert(published).toString(),
      );
      final client = FakeHttpClient.responding(
        () => FakeHttpClientResponse.chunks(chunked(tampered, 1024)),
      );

      final path = await downloadApk(
        asset,
        client: client,
        destDir: temp,
        onProgress: (_, _) {},
      );
      expect(path, isNotNull, reason: 'the bytes arrived; only trust is missing');

      expect(await verifyOrDelete(File(path!), asset.sha256), isFalse);
      expect(File(path).existsSync(), isFalse);
      expect(temp.listSync(), isEmpty);
    });

    test('the honest body verifies and is left for the installer', () async {
      final bytes = bodyBytes(8, 1024);
      final asset = assetFor(bytes, sha256: sha256.convert(bytes).toString());
      final client = FakeHttpClient.responding(
        () => FakeHttpClientResponse.chunks(chunked(bytes, 1024)),
      );

      final path = await downloadApk(
        asset,
        client: client,
        destDir: temp,
        onProgress: (_, _) {},
      );
      expect(await verifyOrDelete(File(path!), asset.sha256), isTrue);
      expect(File(path).existsSync(), isTrue);
    });
  });
}
