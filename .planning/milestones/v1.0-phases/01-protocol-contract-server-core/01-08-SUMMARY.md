---
phase: 01-protocol-contract-server-core
plan: 08
subsystem: protocol-dart
tags: [dart, codec, golden-fixtures, hmac, grapheme, ci, tdd-green]

# Dependency graph
requires:
  - phase: 01-protocol-contract-server-core
    plan: 01
    provides: "protocol/SPEC.md wire contract + 19 golden fixtures (shared cross-language contract, D-09)"
  - phase: 01-protocol-contract-server-core
    plan: 07
    provides: "Dart SDK 3.12.2 via Flutter 3.44.5 at C:\\dev\\flutter (dart.bat absolute path)"
provides:
  - "Pure Dart remote_protocol package (D-03): binary mouse codec, JSON codecs for all families, protoVersion constants, authProof helper, grapheme-correct diff-ops (D-04)"
  - "GREEN Dart fixture tests against the SAME protocol/fixtures as Rust — phase success criterion 1 complete on both sides"
  - "authProof reproduces the .NET-computed macHex byte-identically — three-way cross-language anchor closed (.NET / Rust / Dart)"
  - "Dormant CI workflow (.github/workflows/ci.yml, D-02) + repo README documenting the local test gate (D-01)"
affects: [phase-02, phase-03]

# Tech tracking
tech-stack:
  added:
    - "Dart package deps: crypto (HMAC-SHA256/SHA-256), characters (grapheme clusters), collection; dev: test, lints"
  patterns:
    - "Dart binary codec via ByteData + Endian.little; decode order mirrors Rust exactly (length 9 → LE f32 parse → finite check → opcode dispatch)"
    - "Two-step envelope parse in Dart: envelope map, then fromPayload factories with explicit containsKey checks — FormatException names the missing key (D-05)"
    - "Fixture loading from package root via ../../../protocol/fixtures with existsSync guard naming the canonical invocation directory (Pitfall 8)"

key-files:
  created:
    - app/packages/remote_protocol/pubspec.yaml
    - app/packages/remote_protocol/lib/remote_protocol.dart
    - app/packages/remote_protocol/lib/src/binary_codec.dart
    - app/packages/remote_protocol/lib/src/json_codec.dart
    - app/packages/remote_protocol/lib/src/auth_proof.dart
    - app/packages/remote_protocol/lib/src/diff_ops.dart
    - app/packages/remote_protocol/lib/src/hex.dart
    - app/packages/remote_protocol/lib/src/version.dart
    - app/packages/remote_protocol/test/fixture_test.dart
    - app/packages/remote_protocol/test/auth_proof_test.dart
    - app/packages/remote_protocol/test/diff_ops_test.dart
    - .github/workflows/ci.yml
    - README.md
  modified: []

key-decisions:
  - "Unknown message type decodes to UnknownMsg, never an error (D-07) — mirrors Rust Msg::Unknown"
  - "encodeMessage always emits p (empty map for empty payloads), omits null seq — mirrors the Rust canonical-envelope decision"
  - "diff-ops walk grapheme clusters via package:characters, not UTF-16 code units (D-04) — emoji backspace counts 1"

patterns-established:
  - "Dart half of every future protocol change: add fixture first, both codecs must go green against it unchanged"

requirements-completed: [CONN-07]

# Metrics
duration: 18min
completed: 2026-07-07
---

# Phase 01 Plan 08: Dart Protocol Package Summary

**Pure Dart remote_protocol package proven against the same golden fixtures as Rust — binary codec, JSON codecs, .NET-anchored authProof, grapheme-correct diff-ops — plus the dormant CI workflow and repo README**

## Performance

- **Duration:** ~18 min (Tasks 1-2 by executor, Task 3 + closeout by orchestrator after executor hit provider usage limit)
- **Completed:** 2026-07-07
- **Tasks:** 3
- **Files created:** 13 (11 package files + ci.yml + README.md)

## Accomplishments

- `remote_protocol` is a pure Dart package (no Flutter dependency, D-03) with deps limited to crypto/characters/collection — usable by any future Dart client
- Binary codec decodes/encodes the 9-byte mouse frame with the exact Rust rule order: length-exactly-9 first, LE f32 parse, finite check before opcode dispatch — all 6 mouse-binary fixtures pass
- JSON codec covers every SPEC family via two-step envelope parse; missing payload keys surface as `FormatException` naming the key (matches Rust `MissingField`); unknown `t` decodes to `UnknownMsg` (D-07); `encodeMessage` always emits `p` and omits null `seq` — handshake and text fixtures pass
- `authProof` (HMAC-SHA256, key = SHA-256(raw token), message = nonce) reproduces `05-auth-proof.json`'s .NET-computed macHex byte-identically — the cross-language anchor now holds in all three implementations
- diff-ops count grapheme clusters via `package:characters` (D-04): emoji/IME cases pass, backspace over 👍 counts 1, both fixture compute blocks pass
- `dart test`: 8/8 green; `dart analyze --fatal-infos`: no issues
- Dormant CI workflow (D-02): rust job (ubuntu-latest, `server` workspace) + dart job (`app/packages/remote_protocol`), per RESEARCH Code Example 5; repo README documents the two-command local gate (D-01) and the package-root invocation rule

## Task Commits

1. **Task 1: Scaffold package + red fixture tests** - `3f10bff` (test) — all 8 tests red via UnimplementedError
2. **Task 2: Implement codecs/auth/diff-ops to green** - `7a16670` (feat)
3. **Task 3: Dormant CI workflow + repo README** - `8196c62` (docs)

## Files Created/Modified

- `app/packages/remote_protocol/` — full package: pubspec (SDK `^3.5.0`), barrel export, 6 src modules, 3 test files
- `.github/workflows/ci.yml` — dormant two-job workflow, activates on future push
- `README.md` — monorepo layout, local test gate, fixtures-as-contract note

## Decisions Made

- Dart codec mirrors every locked Rust codec decision (always-emit-p, lenient unknown types, string-typed enum fields, binary rule order) — no new wire decisions introduced
- Fixture path resolution uses `../../../protocol/fixtures` relative to package root with an `existsSync` guard that names the required invocation directory — fails loud with guidance instead of mysterious file-not-found

## Deviations from Plan

### Process deviation

**Executor terminated by provider usage limit after Task 2**
- Tasks 1-2 committed by the executor agent; the session died before Task 3
- Orchestrator completed Task 3 (ci.yml + README per RESEARCH Code Example 5) and this closeout inline
- All Task 3 acceptance criteria verified: both jobs with correct working directories, both gate commands in README, no criterion references remote CI having run

## TDD Gate Compliance

Tasks 1-2 followed red/green: `3f10bff` (all 8 tests red, zero load errors) → `7a16670` (all green). Task 3 is doc-only (exempt).

## Verification Results

- `dart test` (from package root): 8 passed, 0 failed — includes all three fixture families + authProof anchor + diff-ops
- `dart analyze --fatal-infos`: no issues
- `powershell` acceptance greps: `cargo test --workspace` and `dart test` present in ci.yml; both gate commands present in README.md
- Rust side unchanged: `cargo test --workspace` remains 98/98 green

## Known Stubs

None.

## Issues Encountered

- Provider usage limit killed the executor between Task 2 and Task 3; orchestrator finished inline (see Deviations). No code impact.

## User Setup Required

None.

## Next Phase Readiness

- Phase success criterion 1 fully closed: golden fixtures decode identically in Rust AND Dart
- Phase 2 (trackpad + latency gate) can import `remote_protocol` directly for its 9-byte frames and handshake messages
- The CI workflow activates automatically if the repo is ever pushed — no action needed

---
*Phase: 01-protocol-contract-server-core*
*Completed: 2026-07-07*

## Self-Check: PASSED

All 13 created files verified on disk; all three task commits (3f10bff, 7a16670, 8196c62) in git log; `dart test` 8/8 green and `dart analyze` clean re-verified at closeout.
