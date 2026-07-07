# remote_protocol

Pure Dart wire-protocol codecs for Remote Control (protoVersion `1.0`).
No Flutter dependency (D-03) — the Phase 2 Flutter app imports this package
via a path dependency.

Owns:

- the 9-byte binary mouse-frame codec (`[opcode u8][dx f32 LE][dy f32 LE]`),
- JSON message codecs for every family in `protocol/SPEC.md` section 7,
- `protoVersion` constants,
- the `authProof` helper (HMAC-SHA256, key = SHA-256(raw token), message = nonce),
- grapheme-correct diff-ops (`computeDiff`) for `text` messages (D-04).

## Testing

The test suite loads the SAME golden fixtures as the Rust suite —
`protocol/fixtures/` at the repo root; per-language fixture copies are
forbidden (D-09). Because the fixtures are resolved by relative path, the
canonical invocation MUST run from the package root:

```sh
cd app/packages/remote_protocol && dart test
```

Analyzer gate:

```sh
dart analyze --fatal-infos
```
