---
phase: 12-in-app-updates
plan: 02
subsystem: protocol
tags: [wire-protocol, fixtures, json-schema, semver, github-releases, security]

# Dependency graph
requires:
  - phase: 01-protocol-contract
    provides: the `{t, seq?, p}` envelope, the D-05 ignore-unknown / missing-required strictness rules, the canonical-form rule that `encode_msg` always emits `p`, and the golden-fixture harness both codecs load
  - phase: 11-browser-bookmarks
    provides: the `bm.*` registry rows and `protocol/fixtures/bookmarks/` shapes copied verbatim as the row and fixture format
provides:
  - protoVersion 1.8 wire contract in SPEC.md — registry rows for update.check / update.status / update.apply / update.progress and srv→ext ext.reload
  - the CLOSED stage vocabulary (checking, downloading, verifying, installing, restarting, uptodate, failed) defined in exactly one place
  - the CLOSED error vocabulary (network, checksum, disk, installer, downgrade, stale, busy) defined in exactly one place
  - the D-14 no-locator-authority security rule in SPEC §12, plus its machine-checkable form as a fixture
  - twelve fixtures under protocol/fixtures/update/ — nine wire, three special cases
  - the cross-language version-compare truth table (15 cases)
  - a captured releases/latest shape as the SHARED parse fixture for both feed parsers
  - one command that validates the whole family
affects: [12-04, 12-05, 12-06, 12-07, 12-08, 12-10, 12-13]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Mixed-kind fixture directory: `NN-` ordinals 01-09 are standard wire fixtures, 10-12 are special cases with their own loaders"
    - "A security rule expressed as a structural fixture assertion (04-update-apply.json has exactly one payload key) rather than only as prose"
    - "A standalone Python checker as the plan's own verification command, structured as a list of named check functions so later tasks append rather than rewrite"

key-files:
  created:
    - protocol/fixtures/update/01-update-check-request.json
    - protocol/fixtures/update/02-update-status-full.json
    - protocol/fixtures/update/03-update-status-minimal.json
    - protocol/fixtures/update/04-update-apply.json
    - protocol/fixtures/update/05-update-progress-downloading.json
    - protocol/fixtures/update/06-update-progress-failed-checksum.json
    - protocol/fixtures/update/07-update-progress-uptodate.json
    - protocol/fixtures/update/08-update-apply-missing-target.json
    - protocol/fixtures/update/09-update-status-missing-serverversion.json
    - protocol/fixtures/update/10-version-compare.json
    - protocol/fixtures/update/11-releases-latest.json
    - protocol/fixtures/update/12-releases-latest-null-digest.json
    - .planning/phases/12-in-app-updates/check-update-fixtures.py
  modified:
    - protocol/SPEC.md
    - protocol/fixtures/README.md
    - protocol/schema/messages.schema.json

key-decisions:
  - "SPEC.md line 3 still declares protoVersion 1.7 — the 1.8 family is documented but not yet declared current, because 12-13 flips it atomically with SERVER_PROTO_VERSION"
  - "The README's new special-case sections are numbered 3, 4 and 5, not the plan's 2, 3 and 4 — special cases 1 and 2 already existed (auth-proof, the text `compute` block) and renumbering them would break every inbound reference"
  - "The captured releases/latest response is nested under a `response` key rather than being the file's top level, so the fixture can still carry `name`/`description` like every other file in the tree, and so 12-'s null-digest twin can add `expectRefusal` as a sibling"
  - "`additionalProperties: false` appears on exactly ONE payload in the whole schema — updateApply. The D-05 ignore-unknown leniency is permissive everywhere else; closing this one payload is the schema-level restatement of D-14"
  - "The version-compare table asks 'how does a compare to b' with a four-value answer (newer/older/same/unknown) rather than a boolean isNewer, so `older` and `same` disagreements between the two comparators are caught too, not just the offer/no-offer boundary"
  - "Field names for 11-releases-latest.json were confirmed by a live anonymous fetch of a public repo's releases/latest (jrsoftware/issrc, 2026-08-01) — no auth header, per D-01"

patterns-established:
  - "Closed-vocabulary rule: a wire vocabulary is defined once in SPEC §7 and mirrored — never extended — by the schema enums and the fixtures"
  - "Negative fixtures carry an informational `reason` string naming the exact missing field, so a decoder failing for the wrong reason is visible"
  - "Special-case fixtures state in their own description that they need a bespoke loader on both the Rust and Dart sides"

requirements-completed: [D-02, D-03, D-09, D-10, D-11, D-12, D-13, D-14, SC6, SC8]

# Metrics
duration: 30min
completed: 2026-08-01
---

# Phase 12 Plan 02: protoVersion 1.8 Update Contract Summary

**The `update.*` wire contract is now written down once and pinned by twelve shared fixtures — five message shapes, two closed vocabularies, the D-14 no-locator-authority rule as both prose and a structural assertion, and a cross-language version-compare truth table that settles the 1.10.0-vs-1.9.0 trap before either codec is written.**

## Performance

- **Duration:** ~30 min
- **Started:** 2026-08-01T10:40Z
- **Completed:** 2026-08-01T11:10Z
- **Tasks:** 3 of 3
- **Files modified:** 16 (13 created, 3 modified)

## Accomplishments

- **SPEC.md documents the whole 1.8 family without declaring 1.8 current.** Five registry rows, the stage and error vocabularies as closed lists with their non-obvious rules spelled out (`pct` belongs to `downloading` alone; `uptodate` and `failed` are terminal), the `lastUpdate` object with the reason it has to exist at all, the §11 executor-binding divergence, the §10 mixed-version path, the §12 D-14 paragraph, and the §15 `ext.reload` one-shot guard. Line 3 is untouched at `"1.7"` — the scope boundary the plan drew, so the spec never runs five waves ahead of the code.
- **D-14 became machine-checkable.** `04-update-apply.json` has exactly one key inside `wire.p`, the checker asserts it structurally with a failure message that restates the rule, and `messages.schema.json` closes that one payload with `additionalProperties: false`. Prose alone was the weak form; a plan that later "adds a convenient `url` field" now fails a command rather than a review.
- **Both feed parsers get one fixture, not two.** `11-releases-latest.json` pins the `releases/latest` shape — field names confirmed against the live public API, real `dist/` asset sizes (69630935 / 5177240 / 13454) so the phone's size formatter meets real magnitudes — and `12-releases-latest-null-digest.json` turns "a missing digest is a hard refusal" into an `expectRefusal: "checksum"` assertion instead of a code comment.
- **The version-compare disagreement is pre-empted.** Fifteen cases covering the lexical trap in both directions, `v`-stripping, major dominance, and all five unknown cases (two-component, `-rc1` on either side, empty, `latest`, integer overflow). A Rust/Dart disagreement here would have surfaced in the field as a phone offering an update the server then refuses as `stale`.
- **One command validates the family.** `python .planning/phases/12-in-app-updates/check-update-fixtures.py` prints `OK` / exits 0, and is cwd-independent (it resolves the fixture directory from its own `__file__`, the same discipline the Rust loader gets from `CARGO_MANIFEST_DIR`).

## Task Commits

Each task was committed atomically:

1. **Task 1: SPEC.md — the 1.8 message family, vocabularies and security note** — `b349c2e` (docs)
2. **Task 2: The `update.*` wire fixture family** — `5d4a8d2` (test)
3. **Task 3: Non-wire fixtures — version compare, release feed, and the checker's special-case half** — `d0c4dfd` (test)

## Files Created

| File | Purpose |
|------|---------|
| `protocol/fixtures/update/01-update-check-request.json` | Empty-payload request; the canonical-form rule (`p` always emitted as `{}`) |
| `protocol/fixtures/update/02-update-status-full.json` | All four fields incl. the nested `lastUpdate`; carries an unknown key that must be dropped (D-05) |
| `protocol/fixtures/update/03-update-status-minimal.json` | Extension-never-connected + no-marker case; both optionals absent, not null |
| `protocol/fixtures/update/04-update-apply.json` | The D-14 structural contract — one key, `target` |
| `protocol/fixtures/update/05-update-progress-downloading.json` | The only stage that carries `pct` |
| `protocol/fixtures/update/06-update-progress-failed-checksum.json` | Terminal failure; `error` present, `pct` absent |
| `protocol/fixtures/update/07-update-progress-uptodate.json` | Terminal success-with-nothing-to-do; stage and nothing else |
| `protocol/fixtures/update/08-update-apply-missing-target.json` | NEGATIVE — missing required `target` is a hard decode error |
| `protocol/fixtures/update/09-update-status-missing-serverversion.json` | NEGATIVE — missing required `serverVersion` is a hard decode error |
| `protocol/fixtures/update/10-version-compare.json` | SPECIAL — 15-case cross-language truth table |
| `protocol/fixtures/update/11-releases-latest.json` | SPECIAL — captured feed shape, shared by both parsers |
| `protocol/fixtures/update/12-releases-latest-null-digest.json` | SPECIAL/NEGATIVE — null digest ⇒ hard `checksum` refusal |
| `.planning/phases/12-in-app-updates/check-update-fixtures.py` | 8 named checks over the family; `OK`/0 or first failure/1 |

## Files Modified

| File | Change |
|------|--------|
| `protocol/SPEC.md` | §2 the 1.8 additive-minor line; §7 five registry rows + three vocabulary subsections; §10 the mixed-version worked example; §11 executor binding + the read divergence; §12 the D-14 rule, the mirror-repo residual and the no-manifest rationale; §15 the `ext.reload` row and its one-shot guard |
| `protocol/fixtures/README.md` | Layout list brought current (all ten families) with the `update/` mixed-kind note; special cases 3, 4 and 5 documented |
| `protocol/schema/messages.schema.json` | Three dispatch hooks; `$defs` for `semver`, `updateStage`, `updateError`, `updateLastUpdate`, `updateCheck`, `updateStatus`, `updateApply`, `updateProgress` |

## Key Implementation Notes

**Nothing was registered with either codec harness, deliberately.** `server-core/tests/fixtures.rs` registration belongs to 12-04 and `remote_protocol/test/fixture_test.dart` to 12-05; a registration with no decoder would fail the build. The fixture directory is inert until those two plans pick it up, which is exactly why this plan is Wave 1.

**The stale advertised client protoVersion was NOT touched.** `app/packages/remote_protocol/lib/src/version.dart` still declares `'1.1'` (harmless — SPEC §2 compares only the major). 12-RESEARCH flags it as a known-stale item and explicitly says not to fix it as a side effect; "a 1.8 phone" in SC8 means *the phone knows the `update.*` types*, not *the phone advertises `"1.8"`*.

**No dependency was installed.** This plan is artifacts only — no Rust, no Dart, no package manager ran. The phase's two new dependencies (`ureq`, `crypto`) are audited in 12-RESEARCH.md and are introduced by 12-06 and 12-10.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 — Blocking] README special-case numbering collided with existing sections**

- **Found during:** Task 3
- **Issue:** The plan says to document the three new fixtures as "special cases 2, 3 and 4". `protocol/fixtures/README.md` already contains *Special case 1: `handshake/05-auth-proof.json`* and *Special case 2: `compute` block in text fixtures*. Following the plan literally would have produced two "Special case 2" headings in one file.
- **Fix:** Numbered the new sections 3, 4 and 5. The plan's acceptance criterion is "a special-case entry naming `10-version-compare.json`", which does not depend on the ordinal, and the existing sections keep their numbers so any inbound reference stays valid.
- **Files modified:** `protocol/fixtures/README.md`
- **Commit:** `d0c4dfd`

**2. [Rule 3 — Blocking] Task 2's `grep -c '1[012]-' check-update-fixtures.py == 0` criterion was unsatisfiable as first written**

- **Found during:** Task 2 verification
- **Issue:** The script's docstring showed its own invocation, `python .planning/phases/12-in-app-updates/check-update-fixtures.py` — and that path contains `12-`, so the criterion's regex matched the usage line, not a fixture reference. The criterion's intent is clearly "no reference to fixture files 10-, 11- or 12- yet".
- **Fix:** Removed the self-path from the docstring (replaced with a statement that the script resolves the fixture directory from its own location and may be run from any cwd) and removed the forward-looking sentence naming files 10-/11-/12-. `grep -c` then returned 0 with the intent intact.
- **Files modified:** `.planning/phases/12-in-app-updates/check-update-fixtures.py`
- **Commit:** `5d4a8d2`

### Deliberate scope additions (Rule 2 — missing critical detail)

- **`semver` pattern `$def` in the schema.** The plan asked for the four payloads and the two vocabularies. Leaving `target`, `serverVersion`, `extVersion` and `version` as bare `{"type": "string"}` would have documented nothing about the format the D-26 comparator must reject, so a shared `^[0-9]+\.[0-9]+\.[0-9]+$` `$def` carries the "no leading `v`, no `-rcN`" rule where the fields are.
- **`additionalProperties: false` on `updateApply` only.** Not requested; it is the schema-level restatement of D-14, and its comment says explicitly why the D-05 leniency is suspended for that one payload.
- **Two extra version-compare rows beyond the plan's minimum** (`2.0.0` vs `1.99.99` for major dominance, and both directions of the overflow case), because an asymmetric comparator passes a one-directional table.

## Threat Flags

None. This plan added no endpoint, no auth path, no file access and no schema at a trust boundary — it documents and constrains surface that 12-04 through 12-13 will implement. The three `mitigate` dispositions in the plan's threat register (T-12-01 `update.apply` payload shape, T-12-06 the error vocabulary, T-12-07 the release-feed digest) are all discharged as intended: the first as a fixture the checker asserts structurally plus SPEC §12, the second as a closed list in SPEC §7 mirrored by a schema enum, the third as `expectRefusal: "checksum"` in `12-releases-latest-null-digest.json`.

## Known Stubs

None. Every artifact this plan produces is complete for its purpose. The `update/` fixture directory is intentionally not yet loaded by either codec harness — that is a wave-ordering fact recorded in the plan's own action text (12-04 registers Rust, 12-05 registers Dart), not an unfinished stub.

## Verification

| Check | Result |
|-------|--------|
| `python .planning/phases/12-in-app-updates/check-update-fixtures.py` | `OK`, exit 0 (8 checks) |
| `cd server && cargo test --workspace` | 207 passed, 0 failed, 2 ignored |
| `grep -n 'protoVersion:' protocol/SPEC.md` | still `"1.7"` on line 3 |
| `grep -c 'update\.apply' protocol/SPEC.md` | 8 (≥3 required) |
| `grep -c 'ext\.reload' protocol/SPEC.md` | 4, with hits in both the §7 and §15 regions |
| All 7 stage literals + all 7 error literals present in SPEC.md | yes |
| `protocol/schema/messages.schema.json` parses as JSON | yes |
| `11-releases-latest.json` size values | 69630935 / 5177240 / 13454 |
| Post-commit deletion check on all three commits | no deletions |

## For Future Phases

- **12-04 (Rust codec) and 12-05 (Dart codec)** register `update/0[1-9]-*.json` with their existing wire harnesses. The negative fixtures carry a `reason` string naming the exact missing field — assert the decode fails, and ideally that it fails for that field.
- **12-06 (server feed parser) and 12-07 (phone comparator)** each need a bespoke loader for `10-`, `11-` and `12-`; they are NOT wire fixtures. Read `response.assets` (nested under `response`, not top level). `12-`'s `expectRefusal` is the assertion to write.
- **12-06 and 12-10 asset-name constants** must be `RemoteControl-vX.Y.Z.apk`, `RemoteControl-Setup-vX.Y.Z.exe`, `RemoteControl-Extension-vX.Y.Z.zip` — the names in `11-releases-latest.json` match what 12-01 locked into `tools/release.ps1`.
- **12-13** flips `protocol/SPEC.md` line 3, the §2 "Current version" sentence, `SERVER_PROTO_VERSION` and `protocol/fixtures/beacon/01-valid.json` to `1.8` atomically. This plan deliberately left all four alone.
- **Do not renumber the README special cases.** 1 and 2 predate this phase.
- **The checker's `CHECKS` list is the extension point** — append a named function returning `None` or a failure string; do not rewrite the existing eight.

## Self-Check: PASSED

All 13 created files verified present on disk; all three task commits (`b349c2e`, `5d4a8d2`, `d0c4dfd`) verified present in git history.
