/// Protocol version constants (SPEC section 2, D-06).
///
/// `protoVersion` is a `"major.minor"` string carried in `hello`. The server
/// parses only the major component; minor mismatches are accepted.
library;

/// The full protocol version string carried in `hello`.
///
/// 1.1 (D-03): adds the S→C `vol.changed {value, muted}` push — a minor
/// bump; `"1.0"` peers remain fully interoperable (SPEC section 2).
const String protoVersion = '1.1';

/// Major protocol version — the only component peers compare.
const int protoMajor = 1;

/// Minor protocol version — informational; mismatches are accepted.
const int protoMinor = 1;
