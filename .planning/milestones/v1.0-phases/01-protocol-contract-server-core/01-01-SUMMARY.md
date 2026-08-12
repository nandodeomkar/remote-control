---
phase: 01-protocol-contract-server-core
plan: 01
subsystem: protocol
tags: [websocket, json-schema, hmac-sha256, fixtures, wire-protocol, grapheme]

# Dependency graph
requires: []
provides:
  - "protocol/SPEC.md — versioned wire contract (protoVersion 1.0): envelope, 27 message types, handshake FSM, locked auth construction, strictness rules, security notes"
  - "protocol/schema/messages.schema.json — documentation-grade JSON Schema (draft 2020-12) with $defs per family"
  - "protocol/schema/mouse-binary.md — 9-byte binary frame layout with byte-offset table"
  - "19 golden fixtures under protocol/fixtures/{handshake,text,mouse-binary}/ — the executable cross-language contract"
  - "protocol/fixtures/README.md — D-08 fixture format doc with auth-proof and compute-block special cases and the shared loader contract"
affects: [01-02, 01-03, 01-04, 01-05, 01-06, 01-08, rust-codec, dart-codec, server-core, remote_protocol]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Golden-fixture contract testing: both codecs load protocol/fixtures/ directly; per-language copies forbidden (D-09)"
    - "Auth construction: HMAC key = SHA-256(raw token); server verifies with stored hash directly"
    - "Diff-ops text: bs counts extended grapheme clusters (UAX #29), delete-at-end + insert"
    - "Negative fixtures use expect {error: true}; canonical expect contains only spec-defined fields (D-05)"

key-files:
  created:
    - protocol/SPEC.md
    - protocol/schema/messages.schema.json
    - protocol/schema/mouse-binary.md
    - protocol/fixtures/README.md
    - protocol/fixtures/handshake/05-auth-proof.json
    - protocol/fixtures/text/04-rapid-backspace.json
    - protocol/fixtures/mouse-binary/01-move-positive.json
  modified: []

key-decisions:
  - "Auth construction locked verbatim: HMAC key = SHA-256(raw token), message = nonce bytes — the only construction verifiable from a stored hash (fixes design spec §4's unimplementable literal text)"
  - "05-auth-proof.json macHex computed by independent .NET crypto (d0f107...3d48), not by either codec — the cross-language byte-identity anchor"
  - "06-nonfinite fixture uses canonical quiet NaN bits 0x7fc00000 (LE 0000c07f) as the plan specified; .NET [float]::NaN is the negative variant 0xffc00000 — plan value kept since both are NaN and the plan gave explicit bits"
  - "pairOk carries raw token plaintext-once during pairing, documented as accepted v1 tradeoff in SPEC §12 (RESEARCH Open Q3)"
  - "PIN rules include discretionary global cap of 20 total failures on top of per-IP lockout (RESEARCH Open Q2)"

patterns-established:
  - "Fixture schema (D-08): {name, description, wire, expect}; wire is JSON object for text frames, lowercase hex string for binary frames"
  - "All fixture floats f32-exact (12.5, -3.25, 100.0, -0.5, -1.5) — no epsilon comparison anywhere"
  - "All hex lowercase everywhere (nonce, token, mac, binary wires)"

requirements-completed: [CONN-07]

# Metrics
duration: 10min
completed: 2026-07-07
---

# Phase 01 Plan 01: Protocol Contract Summary

**Versioned wire-protocol contract (SPEC.md protoVersion 1.0) with locked HMAC-key-equals-SHA-256(token) auth construction, grapheme-counted diff-ops text schema, and 19 golden fixtures including a .NET-computed auth proof**

## Performance

- **Duration:** ~10 min
- **Started:** 2026-07-07T14:26:52Z
- **Completed:** 2026-07-07T14:35:33Z
- **Tasks:** 3
- **Files modified:** 23 created

## Accomplishments

- `protocol/SPEC.md` (195 lines) locks every wire decision research flagged as expensive to change: the auth construction ("HMAC key = SHA-256(raw token)" written verbatim), the extended-grapheme-cluster `bs` unit with the 10000 cap, D-05/D-06/D-07 strictness rules, the full 27-type message registry, PIN rules (60s / 5 attempts / 5-min per-IP lockout / global cap 20), pause semantics with CONN-07 release-on-session-end, and 64 KB transport limits
- `05-auth-proof.json` carries token bytes 0x00..0x1f, nonce bytes 0xa0..0xbf, and macHex `d0f10703352913066fcbf70360201fe0dfb691d66a74b2132968ad5659113d48` computed by an independent third implementation (.NET `SHA256`/`HMACSHA256`), giving Rust (Plan 04) and Dart (Plan 08) a byte-identity anchor neither codec produced
- Full D-09 coverage: challenge/auth/authOk/authFail handshake, D-05 ignore-unknown proof pair, version-reject and missing-required negative fixtures, IME-revision / emoji / rapid-backspace text fixtures with compute blocks, and binary move/scroll fixtures with negative deltas plus three strictness negatives (bad opcode, short frame, NaN)
- Every binary fixture's LE f32 bytes computed via `[System.BitConverter]` and verified to decode back exactly (12.5/100.0, -3.25/-0.5, 0.0/-1.5) — no hand-derived bytes

## Task Commits

Each task was committed atomically:

1. **Task 1: Write protocol/SPEC.md and schema locking all wire decisions** - `21f2f10` (feat)
2. **Task 2: Create handshake fixtures with independently computed auth proof** - `a9b0fcd` (feat)
3. **Task 3: Create text and mouse-binary fixtures plus fixtures README** - `bfe0c32` (feat)

## Files Created/Modified

- `protocol/SPEC.md` - Versioned prose contract: envelope, versioning, handshake FSM, auth construction, PIN rules, gating, family registry, diff-ops semantics, binary frames, unknown-type handling, pause/cleanup, security notes, transport limits
- `protocol/schema/messages.schema.json` - JSON Schema draft 2020-12, one `$defs` entry per family payload (documentation-grade)
- `protocol/schema/mouse-binary.md` - 9-byte frame byte-offset table with strict decode rules
- `protocol/fixtures/handshake/01..09-*.json` - hello (ignore-unknown proof), challenge, authOk, authFail, auth-proof (special format), pin (zero-padded string), pairOk, version-reject (negative), missing-mac (negative)
- `protocol/fixtures/text/01..04-*.json` - simple insert, IME revision (bs 1), emoji (multi-codepoint grapheme), rapid backspace (bs 4 grapheme-count lock) — each with a `compute {old, new}` block
- `protocol/fixtures/mouse-binary/01..06-*.json` - f32-exact move positive/negative, scroll, bad-opcode / short-frame / non-finite negatives
- `protocol/fixtures/README.md` - D-08 format, both special cases, loader contract (CARGO_MANIFEST_DIR path for Rust, ../../../protocol/fixtures for Dart, copies forbidden)

## Decisions Made

- **NaN bit pattern:** the plan specified canonical quiet NaN `0x7fc00000` (LE hex `0000c07f`) for `06-nonfinite.json`; .NET's `[float]::NaN` constant is the negative-sign variant (`0000c0ff`). Kept the plan's explicit bits — both are NaN and codecs must reject any non-finite value regardless of sign bit.
- **`08-hello-version-reject.json` expect** includes `"reason": "versionMismatch"` as an informational flag for the integration suite (codecs decode the message fine; the SERVER rejects it), per the plan's D-06 note.
- All other choices followed the plan exactly as written.

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered

- Inline `powershell -Command` verification failed because Git Bash expanded `$` variables before PowerShell saw them; moved all verification into `.ps1` scripts in the session scratchpad and ran them with `-File`. No repo impact.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

- `protocol/` is a complete, self-consistent contract: Plans 01-02..01-06 (Rust workspace + codec + auth + dispatch) and 01-08 (Dart codec) can implement directly against SPEC.md and the fixtures without renegotiating any wire decision
- The auth-proof anchor and the grapheme-count lock (rapid-backspace bs=4) are in place before either codec exists, per RESEARCH Pitfall 1/4 guidance
- No blockers introduced; Dart SDK installation (Plan 01-07 checkpoint) remains the known gate for Dart-side plans

---
*Phase: 01-protocol-contract-server-core*
*Completed: 2026-07-07*

## Self-Check: PASSED

All 23 created files verified on disk (spot-checked 7 key artifacts); all 3 task commits (21f2f10, a9b0fcd, bfe0c32) present in git log.
