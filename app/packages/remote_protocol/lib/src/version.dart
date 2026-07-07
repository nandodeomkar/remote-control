/// Protocol version constants (SPEC section 2, D-06).
///
/// `protoVersion` is a `"major.minor"` string carried in `hello`. The server
/// parses only the major component; minor mismatches are accepted.
library;

/// The full protocol version string carried in `hello`.
const String protoVersion = '1.0';

/// Major protocol version — the only component peers compare.
const int protoMajor = 1;

/// Minor protocol version — informational; mismatches are accepted.
const int protoMinor = 0;
