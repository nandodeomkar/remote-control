/// Strict parser for the PC pair window's QR payload (260716-kba, CONN-02).
///
/// The Windows server's pairing window
/// (`server/server-windows/src/shell/pair_window.rs`) renders a QR encoding
/// `rc://pair?host={}&port={}&pin={}` — host is the server's LAN IP, port the
/// resolved WebSocket port, pin the live 6-digit pairing PIN (60s expiry,
/// server-side enforced).
///
/// [parsePairQr] is whitelist-strict (T-QR-01): the scheme must be `rc`, the
/// authority `pair`, the host an IP literal ([InternetAddress.tryParse] —
/// consistent with the Connect-by-IP sheet's validation), the port in
/// 1..65535, and the pin exactly 6 digits. ANY deviation returns null and the
/// scanner treats the code as malformed. The scanned host still crosses the
/// existing RFC1918 dial guard in ConnectionService before any socket opens.
///
/// Secrets discipline (T-QR-02 / T-03-23): [PairQrData] deliberately does NOT
/// override toString — the pin must never leak through logs or string
/// interpolation. Never log the raw QR contents either.
library;

import 'dart:io' show InternetAddress;

/// The pin shape the server issues: exactly six ASCII digits.
final RegExp _kPinShape = RegExp(r'^\d{6}$');

/// A parsed `rc://pair` QR payload: where the PIN lives and the PIN itself.
class PairQrData {
  /// The server's LAN IP literal (IPv4 or IPv6).
  final String host;

  /// The server's WebSocket port (1..65535).
  final int port;

  /// The 6-digit pairing PIN. NEVER log or interpolate this (T-QR-02).
  final String pin;

  /// Creates a parsed payload.
  const PairQrData({required this.host, required this.port, required this.pin});

  @override
  bool operator ==(Object other) =>
      other is PairQrData &&
      other.host == host &&
      other.port == port &&
      other.pin == pin;

  @override
  int get hashCode => Object.hash(host, port, pin);

  // NO toString override BY DESIGN: the default `Instance of 'PairQrData'`
  // cannot leak the pin (T-QR-02 / T-03-23).
}

/// Parses [raw] (a scanned QR's text content) as an `rc://pair` payload.
///
/// Returns null for ANYTHING that isn't exactly the pair_window.rs shape —
/// the caller treats null as a malformed code and keeps scanning.
PairQrData? parsePairQr(String raw) {
  final uri = Uri.tryParse(raw.trim());
  if (uri == null) return null;
  // `rc://pair?...` parses with 'rc' as the scheme and 'pair' as the
  // authority host — NOT the path.
  if (uri.scheme != 'rc' || uri.host != 'pair') return null;

  final params = uri.queryParameters;
  final host = params['host'];
  final portText = params['port'];
  final pin = params['pin'];
  if (host == null || portText == null || pin == null) return null;

  // Host must be an IP literal — same rule as the Connect-by-IP sheet.
  if (InternetAddress.tryParse(host) == null) return null;

  final port = int.tryParse(portText);
  if (port == null || port < 1 || port > 65535) return null;

  if (!_kPinShape.hasMatch(pin)) return null;

  return PairQrData(host: host, port: port, pin: pin);
}
