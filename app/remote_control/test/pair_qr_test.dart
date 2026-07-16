// 260716-kba Task 1 (TDD RED) — the strict rc://pair QR parser table.
//
// The Windows pair window (server/server-windows/src/shell/pair_window.rs)
// renders a QR whose payload is `rc://pair?host=<ip>&port=<port>&pin=<6
// digits>`. parsePairQr is whitelist-strict (T-QR-01): anything that isn't
// exactly that shape returns null and the scanner treats it as malformed.
// PairQrData is value-equal and must NEVER embed the pin in toString
// (T-QR-02 / T-03-23 secrets discipline).

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control/net/pair_qr.dart';

void main() {
  group('parsePairQr — valid payloads', () {
    test('the canonical pair_window.rs payload parses', () {
      final data = parsePairQr('rc://pair?host=192.168.1.50&port=17777&pin=123456');
      expect(data, isNotNull);
      expect(data!.host, '192.168.1.50');
      expect(data.port, 17777);
      expect(data.pin, '123456');
    });

    test('whitespace-padded input parses (trimmed first)', () {
      final data = parsePairQr('  rc://pair?host=192.168.1.50&port=17777&pin=123456\n');
      expect(
        data,
        const PairQrData(host: '192.168.1.50', port: 17777, pin: '123456'),
      );
    });

    test('extra unknown query params are ignored', () {
      final data = parsePairQr(
        'rc://pair?host=192.168.1.50&port=17777&pin=123456&future=1&x=y',
      );
      expect(
        data,
        const PairQrData(host: '192.168.1.50', port: 17777, pin: '123456'),
      );
    });

    test('an IPv6 literal host parses (InternetAddress.tryParse accepts it)',
        () {
      final data = parsePairQr('rc://pair?host=fe80::1&port=17777&pin=123456');
      expect(
        data,
        const PairQrData(host: 'fe80::1', port: 17777, pin: '123456'),
      );
    });
  });

  group('parsePairQr — malformed payloads return null (T-QR-01 whitelist)',
      () {
    const malformed = <String, String>{
      'wrong scheme (http)':
          'http://pair?host=192.168.1.50&port=17777&pin=123456',
      'plain text': 'hello world',
      'a regular URL': 'https://example.com/some/page?q=1',
      'empty string': '',
      'wrong authority (rc://other)':
          'rc://other?host=192.168.1.50&port=17777&pin=123456',
      'missing host': 'rc://pair?port=17777&pin=123456',
      'missing port': 'rc://pair?host=192.168.1.50&pin=123456',
      'missing pin': 'rc://pair?host=192.168.1.50&port=17777',
      'host not an IP literal (hostname)':
          'rc://pair?host=my-pc&port=17777&pin=123456',
      'port 0': 'rc://pair?host=192.168.1.50&port=0&pin=123456',
      'port out of range (70000)':
          'rc://pair?host=192.168.1.50&port=70000&pin=123456',
      'port non-numeric': 'rc://pair?host=192.168.1.50&port=abc&pin=123456',
      'pin 5 digits': 'rc://pair?host=192.168.1.50&port=17777&pin=12345',
      'pin 7 digits': 'rc://pair?host=192.168.1.50&port=17777&pin=1234567',
      'pin letters': 'rc://pair?host=192.168.1.50&port=17777&pin=abcdef',
      'pin with an inner space':
          'rc://pair?host=192.168.1.50&port=17777&pin=12 456',
    };

    malformed.forEach((label, input) {
      test(label, () {
        expect(parsePairQr(input), isNull);
      });
    });
  });

  group('PairQrData — value semantics + secrets discipline', () {
    test('equal fields mean == and identical hashCode', () {
      const a = PairQrData(host: '192.168.1.50', port: 17777, pin: '123456');
      const b = PairQrData(host: '192.168.1.50', port: 17777, pin: '123456');
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('any differing field breaks equality', () {
      const base = PairQrData(host: '192.168.1.50', port: 17777, pin: '123456');
      expect(
        base,
        isNot(const PairQrData(host: '192.168.1.51', port: 17777, pin: '123456')),
      );
      expect(
        base,
        isNot(const PairQrData(host: '192.168.1.50', port: 17778, pin: '123456')),
      );
      expect(
        base,
        isNot(const PairQrData(host: '192.168.1.50', port: 17777, pin: '654321')),
      );
    });

    test('toString never embeds the pin (T-QR-02 / T-03-23)', () {
      const data = PairQrData(host: '192.168.1.50', port: 17777, pin: '123456');
      expect(data.toString(), isNot(contains('123456')));
    });
  });
}
