# Protocol Golden Fixtures

These files are the executable cross-language contract for the Remote Control wire protocol (see `../SPEC.md`, protoVersion `"1.0"`). The Rust codec (`server-core`) and the Dart codec (`app/packages/remote_protocol`) are BOTH tested against these exact files. **No codec may adjust a fixture to match its own output** — a fixture mismatch is a codec bug by definition.

## Layout (D-08)

- One directory per message family: `handshake/`, `text/`, `mouse-binary/`, `beacon/`, `volume/`, `input_blocked/`, `window_info/`, `tabs/`, `bookmarks/`, `update/` (more families may be added by later protocol minors).
- One scenario per JSON file, named `NN-scenario-slug.json` (two-digit ordinal + kebab-case slug).
- `update/` (protoVersion 1.8) is the only family that mixes kinds: files `01-`–`09-` are standard wire fixtures, while `10-`, `11-` and `12-` are **special cases** documented below — they do not follow the wire/expect schema and need their own loaders on both the Rust and Dart sides. The whole directory is validated by `python .planning/phases/12-in-app-updates/check-update-fixtures.py`.

## Standard fixture schema

```json
{
  "name": "scenario-slug",
  "description": "What this scenario proves, with the SPEC section it references.",
  "wire": <see below>,
  "expect": <see below>
}
```

**`wire`** — the raw frame as it appears on the wire:

- For JSON text-frame families (`handshake/`, `text/`): a JSON **object** — the full message envelope `{t, seq?, p?}`, possibly including unknown fields that decoders must ignore (D-05).
- For `mouse-binary/`: a **lowercase hex string** encoding the frame bytes — 18 hex chars for a valid 9-byte frame (negative fixtures may differ, e.g. `05-short-frame` is 16 chars for 8 bytes).

**`expect`** — one of:

- The **canonical decoded envelope** `{t, seq?, p}` containing ONLY spec-defined fields. The contract is: `encode(decode(wire))`, parsed as JSON, must equal `expect` (field order insignificant). Unknown fields present in `wire` never appear in `expect`.
- For binary frames: the decoded form `{op, dx, dy}` where `op` is `"move"` or `"scroll"`.
- For **negative fixtures**: `{"error": true, ...}` — decoding (or, where the description says so, server-side handling, e.g. `handshake/08-hello-version-reject`) must fail/reject. Extra fields like `reason` are informational flags for the integration suite.

## Value discipline

- All hex is **lowercase**, always. No decoder may require case normalization.
- All binary-frame float values are **exactly representable in f32** (e.g. 12.5, -3.25, 100.0, -0.5, -1.5) so `expect.dx`/`expect.dy` compare exactly in both languages — **no epsilon comparison anywhere**.
- `seq` values, where present, are small integers.

## Special case 1: `handshake/05-auth-proof.json`

This fixture does not follow the wire/expect schema. Its shape is:

```json
{
  "name": "auth-proof",
  "description": "...",
  "input":  { "tokenHex": "<64 hex>", "nonceHex": "<64 hex>" },
  "expect": { "macHex": "<64 lowercase hex>" }
}
```

It proves the locked auth construction (SPEC §4): `mac = HMAC-SHA256(key = SHA-256(raw token bytes), message = nonce bytes)`. The `macHex` value was computed by an independent third implementation (.NET `System.Security.Cryptography`), NOT by either codec. Each codec's auth-proof helper must reproduce `macHex` byte-identically from `input`.

## Special case 2: `compute` block in text fixtures

Text fixtures carry an optional extra block:

```json
"compute": { "old": "<previous committed text>", "new": "<new committed text>" }
```

This block is consumed ONLY by the Dart diff-helper test: it must derive exactly `wire.p.bs` / `wire.p.ins` from `old`/`new` using extended-grapheme-cluster counting (SPEC §8). The Rust fixture loader ignores the block (in the D-05 ignore-unknown spirit). It is not part of the wire format.

## Loader contract (D-09 — copies are forbidden)

Both test suites load **these exact files**; per-language fixture copies are forbidden.

- **Rust** (`server/server-core`): resolve from the crate manifest, immune to test cwd — `concat!(env!("CARGO_MANIFEST_DIR"), "/../../protocol/fixtures")`.
- **Dart** (`app/packages/remote_protocol`, cwd = package root when running `dart test`): `../../../protocol/fixtures`. Guard with a directory-existence check that fails the suite with a clear message if the cwd assumption breaks; canonical invocation is `cd app/packages/remote_protocol && dart test`.
