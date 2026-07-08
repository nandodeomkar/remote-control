/// Discovery beacon model + strict total-parse decoder (protocol/BEACON.md).
///
/// The beacon is UNTRUSTED network input: [Beacon.tryParse] is total — any
/// failure returns null (silent drop) and no error ever escapes to the
/// listener (T-03-12). Validation follows the BEACON.md all-or-nothing
/// order: size cap BEFORE parse, JSON object, v == 1, app discriminator,
/// typed field checks; unknown fields are ignored (forward-compat rule 6).
library;

import 'dart:convert';
import 'dart:io';

/// UDP port the server broadcasts beacons to — must match
/// DEFAULT_BEACON_PORT in server-core beacon.rs (RC_BEACON_PORT override
/// is server-side only; the port travels IN the beacon for ws, not UDP).
const int kBeaconPort = 17778;

/// Hard datagram size cap applied BEFORE any parsing (BEACON.md rule 1;
/// flood/tamper mitigation — a real beacon is ~130 bytes).
const int kMaxBeaconBytes = 512;

/// One validated discovery beacon.
///
/// `v` and `app` are validation gates, not decoded state (fixtures README):
/// they never appear here. [host] is derived from the datagram [source] —
/// the beacon's claimed fields can never redirect where the client dials.
class Beacon {
  const Beacon({
    required this.guid,
    required this.name,
    required this.port,
    required this.proto,
    required this.source,
  });

  /// Machine GUID — identifies the PC across IP changes (≤64 chars).
  final String guid;

  /// Human-readable PC name (COMPUTERNAME, ≤64 chars).
  final String name;

  /// WebSocket port to connect to (1..65535) — travels in the beacon so
  /// ws-port changes need no client update.
  final int port;

  /// Wire-protocol version string (SPEC §2), display/compat hint only.
  final String proto;

  /// Where the datagram ACTUALLY came from.
  final InternetAddress source;

  /// The address the client dials — always the datagram source address,
  /// never a payload field (a spoofed payload cannot point elsewhere).
  String get host => source.address;

  /// Strict, total parse of one datagram. Returns null on ANY failure —
  /// silent drop, no exception ever escapes (the caller is a socket
  /// listener; see trackpad _onFrame for the same posture).
  static Beacon? tryParse(List<int> data, InternetAddress source) {
    // Rule 1: size cap before touching the bytes.
    if (data.length > kMaxBeaconBytes) return null;
    try {
      // Rule 2: UTF-8 JSON, single object.
      final decoded = jsonDecode(utf8.decode(data));
      if (decoded is! Map<String, dynamic>) return null;

      // Rule 3: beacon format version — unknown versions are dropped,
      // never best-effort parsed.
      final v = decoded['v'];
      if (v is! int || v != 1) return null;

      // Rule 4: application discriminator.
      if (decoded['app'] != 'remote-control') return null;

      // Rule 5: typed field checks.
      final name = decoded['name'];
      if (name is! String || name.length > 64) return null;
      final guid = decoded['guid'];
      if (guid is! String || guid.isEmpty || guid.length > 64) return null;
      final port = decoded['port'];
      if (port is! int || port < 1 || port > 65535) return null;
      final proto = decoded['proto'];
      if (proto is! String) return null;

      // Rule 6: unknown fields ignored — nothing else is read.
      return Beacon(
        guid: guid,
        name: name,
        port: port,
        proto: proto,
        source: source,
      );
    } catch (_) {
      // Total parse: bad UTF-8, bad JSON, anything unexpected — drop.
      return null;
    }
  }
}
