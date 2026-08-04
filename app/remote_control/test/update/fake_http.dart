/// Offline `dart:io` HTTP fakes shared by `release_feed_test.dart` and
/// `apk_download_test.dart`.
///
/// These exist so NO test in this phase ever opens a socket: both modules take
/// an injectable `HttpClient`, and this file is what gets injected. Each fake
/// implements only the members its module actually calls and forwards the rest
/// to `noSuchMethod`, which is the standard way to stand in for a large SDK
/// interface without a mocking package (this project adds no dev dependency
/// for it, the same reasoning that kept `crypto` the phase's only new package).
///
/// A member reached that is NOT implemented throws `NoSuchMethodError` rather
/// than silently returning null — a test that starts exercising new HTTP
/// surface fails loudly instead of passing on a stub.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Records the headers a request set, so a test can assert what was — and was
/// NOT — sent (D-01: no `Authorization`, ever).
class FakeHttpHeaders implements HttpHeaders {
  final Map<String, String> values = <String, String>{};

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    values[name.toLowerCase()] = '$value';
  }

  @override
  void add(String name, Object value, {bool preserveHeaderCase = false}) {
    values[name.toLowerCase()] = '$value';
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

/// A response with a fixed status and a caller-supplied byte stream.
class FakeHttpClientResponse extends Stream<List<int>>
    implements HttpClientResponse {
  FakeHttpClientResponse(this.statusCode, Stream<List<int>> body)
      : _body = body;

  /// Convenience: a 200 carrying a UTF-8 string in one chunk.
  factory FakeHttpClientResponse.text(int status, String body) =>
      FakeHttpClientResponse(status, Stream<List<int>>.value(utf8.encode(body)));

  /// Convenience: a 200 carrying the given chunks in order.
  factory FakeHttpClientResponse.chunks(List<List<int>> chunks) =>
      FakeHttpClientResponse(200, Stream<List<int>>.fromIterable(chunks));

  /// Convenience: chunks, then an error mid-stream (a dropped connection).
  factory FakeHttpClientResponse.chunksThenError(
    List<List<int>> chunks,
    Object error,
  ) {
    Stream<List<int>> gen() async* {
      for (final chunk in chunks) {
        yield chunk;
      }
      throw error;
    }

    return FakeHttpClientResponse(200, gen());
  }

  final Stream<List<int>> _body;

  @override
  final int statusCode;

  @override
  int get contentLength => -1;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) =>
      _body.listen(
        onData,
        onError: onError,
        onDone: onDone,
        cancelOnError: cancelOnError,
      );

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

/// A request that yields a caller-supplied response (or throws) on `close()`.
class FakeHttpClientRequest implements HttpClientRequest {
  FakeHttpClientRequest(this._respond);

  final FutureOr<HttpClientResponse> Function() _respond;

  final FakeHttpHeaders _headers = FakeHttpHeaders();

  @override
  HttpHeaders get headers => _headers;

  @override
  Future<HttpClientResponse> close() async => _respond();

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

/// The injectable client. Records every URL it was asked for.
class FakeHttpClient implements HttpClient {
  FakeHttpClient(this._open);

  /// Always throws [error] from `getUrl` — a dead network.
  factory FakeHttpClient.throwing(Object error) =>
      FakeHttpClient((_) => throw error);

  /// Always answers with [response].
  factory FakeHttpClient.responding(HttpClientResponse Function() response) =>
      FakeHttpClient((_) => FakeHttpClientRequest(response));

  final FakeHttpClientRequest Function(Uri url) _open;

  /// Every URL passed to `getUrl`, in order.
  final List<Uri> requested = <Uri>[];

  /// The last request handed out, for header assertions.
  FakeHttpClientRequest? lastRequest;

  bool closed = false;

  @override
  Duration? connectionTimeout;

  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    requested.add(url);
    final request = _open(url);
    lastRequest = request;
    return request;
  }

  @override
  void close({bool force = false}) {
    closed = true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}
