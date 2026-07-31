---
phase: quick-260731-d45
plan: 01
status: complete
subsystem: pairing-copy + extension-wire-caps
tags: [copy, authFail, pairing, extension, unicode, deferred-cleanup, no-wire-change]
requires: [phase-03, phase-11]
provides:
  - "kNoPinWindowCopy — the noPairing arm of pairingErrorCopy, split off badMac (client only, zero wire change)"
  - "capTitle(s, max) — one lone-surrogate-safe title cap shared by the group cap and the bookmark cap"
  - "A closed todo recording that the stale noPinWindow wire-split sketch was rejected, and why"
  - "A closed note on phase-11 deferred item 1 that also CORRECTS its lenient-parse severity claim"
affects:
  - app/remote_control pairing sheet copy only — no FSM, no transport, no store change
  - extension/background.js title capping only — no cap value, no manifest, no version bump
tech-stack:
  added: []
  patterns:
    - "Client-side reason-to-copy split when the server already distinguishes the reasons on the wire — check the emitter before adding a wire reason"
    - "One parameterised capTitle(s, max) over per-consumer helpers: the property that matters is a SINGLE lone-surrogate implementation, and a name like capBmTitle lies the moment it serves a group title"
    - "Corrections to frozen or deferred records go in an APPENDED note, never by editing the original prose"
key-files:
  created:
    - .planning/todos/done/2026-07-09-nopairing-reason-overloaded-copy.md
  modified:
    - app/remote_control/lib/screens/connection_copy.dart
    - app/remote_control/test/pairing_flow_test.dart
    - extension/background.js
    - .planning/phases/11-browser-bookmarks-view-open-star-current-tab/deferred-items.md
  deleted:
    - .planning/todos/pending/2026-07-09-nopairing-reason-overloaded-copy.md
decisions:
  - "The todo's Fix sketch (add a noPinWindow wire reason, touch session.rs, protocol/fixtures and remote_protocol) was STALE and was rejected — the server already emits noPairing only from PinOutcome::NoPairing (session.rs:626) and badMac only from the Msg::Auth path (session.rs:645), so the collapse was purely the client's fallthrough switch arm"
  - "deferred-items.md item 1's severity claim was WRONG: the groups leniency at ext.rs:345-351 runs on an already-parsed Value, downstream of the whole-frame from_str at ext.rs:330 that a lone surrogate already failed — same mechanism and severity as the bookmark case, differing only in likelihood"
  - "capBmTitle(s) became capTitle(s, max) rather than a default parameter or a second helper — a defaulted capBmTitle keeps a name that lies when it caps a group title, and a second helper is a second lone-surrogate implementation"
  - "reconnect_fsm.authRejected still clears the token on noPairing — deliberate non-change, still open (see Still Open below)"
  - "03-UI-SPEC.md:160 left unedited — frozen phase record; the delta lives in the closed todo instead"
  - "No extension version bump and no manifest.json edit — behaviour-preserving robustness fix on a path the shipped extension already exercises"
metrics:
  duration: ~25min
  tasks: 2
  commits: 2
  files: 5
  completed: 2026-07-31
---

# Quick Task 260731-d45 — Close two deferred items: noPairing copy + group-title surrogate cap

Split the overloaded `noPairing` authFail copy off `badMac` client-side with zero wire change, and routed the extension's group-title cap through the same lone-surrogate-safe helper as the bookmark cap — two long-open deferred items, two atomic commits, disjoint subsystems.

## What shipped

**Commit 1 — `0cd5104` `fix(quick-260731-d45): give noPairing its own copy, distinct from badMac`**

- `connection_copy.dart`: new top-level `const String kNoPinWindowCopy = "Your PC isn't showing a PIN — start pairing on the PC"` (53 chars, U+2014 em dash, ASCII apostrophe). `pairingErrorCopy`'s fallthrough `case 'noPairing': case 'badMac':` became two independent arms — `noPairing` returns `kNoPinWindowCopy`, `badMac` keeps `kRevokedExplanation`. Every other arm byte-identical.
- `pairing_flow_test.dart`: the collapsed test `'noPairing and badMac both map to the D-05 revoked explanation'` became two — a `badMac` test preserving the verbatim D-05 guard, and `'noPairing gets its own no-PIN-window copy, distinct from badMac (260731-d45)'` pinning distinctness, the exact new literal, and a length bound (at most `kRevokedExplanation.length + 4`) justified by the sheet's reserved one-line error box. The widget test `'raw reason enums never reach a rendered widget'` kept its name and loop; only its unconditional `expect(find.text(kRevokedExplanation), ...)` became a per-reason `expected`.
- Todo moved from `pending/` to `done/` with a `## Closed — quick 260731-d45 (2026-07-31)` section.

**Commit 2 — `081df65` `fix(quick-260731-d45): trim lone surrogates from capped group titles`**

- `extension/background.js`: `capBmTitle(s)` became `capTitle(s, max)`, relocated from the bookmarks section up to sit immediately after `bytesOf` (the file's established home for shared cap and measurement helpers), with a rewritten doc comment covering both consumers honestly. The group mapper's `title: (g.title || "").slice(0, MAX_GROUP_TITLE)` became `title: capTitle(g.title, MAX_GROUP_TITLE)` — the only behavioural change. `buildBmSnapshot`'s call became `capTitle(n.title, MAX_BM_TITLE)` (pure rename).
- `deferred-items.md`: item 1's row gained a closed note that also corrects its severity reasoning. Exactly one line changed; items 2, 3 and 4 byte-identical.

## Findings

### 1. The todo's "Fix sketch" was stale — no wire change was needed

The 2026-07-09 todo proposed adding a distinct wire reason (`noPinWindow`) in `session.rs`, plus fixture and `remote_protocol` updates. **Verified against the current tree, none of that was necessary.** The server already distinguishes the two situations:

- `server/server-core/src/transport/session.rs:626` emits `authFail{noPairing}` from the `PinOutcome::NoPairing` branch **only** — a PIN submitted with no active pairing window.
- `session.rs:645` emits `authFail{badMac}` from the `Msg::Auth` token-verification path **only**.

The collapse was entirely client-side, at `connection_copy.dart`'s fallthrough switch arm. Splitting that arm is the whole fix. `server/`, `protocol/fixtures/` and `app/packages/remote_protocol/` are untouched — mechanically confirmed by an empty `git diff --stat HEAD~2..HEAD -- server/ app/packages/remote_protocol/ protocol/ extension/manifest.json`.

### 2. Deferred item 1's blast-radius claim was wrong — this was never a "latent robustness fix"

`deferred-items.md` item 1 (and the 11-05/11-06 framing it inherited) justified deferral partly on the group path being lower-risk than the bookmark path because "`groups` is parsed LENIENTLY server-side whereas `bm.state` nodes are strict." **That mitigation does not exist.**

- `ext.rs:330` runs `serde_json::from_str::<ExtFrame>(text)` over the **whole frame text** first, and `ExtFrame.p` is a `serde_json::Value` — so every string in the payload, group titles included, is decoded at that point.
- serde_json rejects an unpaired surrogate escape as a hard decode error. `from_str` fails, `handle_ext_text` returns `None` at `ext.rs:332`, and the frame is dropped.
- The groups tolerance at `ext.rs:345-351` (`.and_then(Result::ok).unwrap_or_default()`) operates on an **already-parsed** `Value` and never runs. It is field-SHAPE leniency, not lexical leniency.
- `ext.rs:353` is the only production site that sets `TabsState.connected = true`. So while a poisoned group title existed, every `tabs.state` frame died before that line: the phone kept the last good snapshot and, after any reconnect (`reset_relay_watches`), showed the "install the extension" hint while the extension was connected and healthy.

Real severity: **identical mechanism and severity to the bookmark case, differing only in likelihood** (a 32-char group title is less likely than a 48-char bookmark title to carry an emoji straddling exactly the cap). The fix itself was unchanged — one line — but the commit message and the appended deferred-items note state the corrected severity rather than repeating the old framing.

### 3. The capBmTitle rename leaves stale references in frozen phase-11 summaries

`11-05-SUMMARY.md` and `11-06-SUMMARY.md` name `capBmTitle` in historical prose (including an old `grep -c "MAX_BM_TITLE"` observation). Frozen phase records are not edited, so those references are now stale by name. Accepted and recorded here rather than chased. In live code `grep -c capBmTitle extension/background.js` is 0 and `grep -c capTitle` is 3 (declaration plus both call sites).

## Still open (deliberate non-change)

`reconnect_fsm.dart:333` — `authRejected` still treats `noPairing` as revoked: it emits `ClearTokenEffect` and stops auth retries. For a PIN-window problem the stored token is not necessarily bad, so this is arguably wrong, but changing it is a **D-05 token-semantics behaviour change** with its own test surface (`reconnect_fsm_test.dart:217-268`) and was explicitly out of scope. `reconnect_fsm.dart`, `connection_service.dart` and their tests are byte-identical.

It does **not** affect what the user reads: in `pairing_dialog.dart`'s `_errorCopy`, a live `FailedEffect` outranks `widget.explanation`, so a `noPairing` rejection renders `kNoPinWindowCopy` regardless of what the FSM did to the token. Worth its own task if the token-clearing behaviour is ever revisited.

Also intentionally untouched: `03-UI-SPEC.md:160` (frozen record, now describing `badMac` only) and `extension/manifest.json` (no version bump).

## Verification

| Gate | Result |
|------|--------|
| `flutter analyze` | No issues found |
| `flutter test` | **609** passing (baseline 608, +1 from the split copy test) |
| `node --check extension/background.js` | exit 0 |
| `capTitle` behavioural assertion | OK — caps at 32, trims the straddling surrogate, null-safe |
| `cargo test --workspace` and `dart test` | Not run — `git diff --stat HEAD~2..HEAD -- server/ app/packages/remote_protocol/` is empty, so 202 and 13 are unchanged by construction |
| Scope fence: `server/`, `remote_protocol/`, `protocol/`, `manifest.json` | No output over `HEAD~2..HEAD` |
| `deferred-items.md` numstat | `1 1` — one line changed; items 2-4 byte-identical; 6 table lines intact |
| `git diff --name-status HEAD~2..HEAD` | Exactly the 6 expected entries, nothing else |
| Commit isolation | `git show --stat` on each: neither commit contains the other subsystem's files |
| `.planning/todos/pending/` | Empty |

## Deviations from Plan

**1. [Rule 3 - Plan self-conflict] `grep -c "kRevokedExplanation" connection_copy.dart` is 3, not the 2 the acceptance criterion states**

- **Found during:** Task 1 verification.
- **Issue:** The task's `<action>` step 1 explicitly requires the new constant's doc comment to state that `kRevokedExplanation` remains the `badMac` case. Following it necessarily produces a third occurrence of the symbol name, which contradicts the same task's acceptance criterion of exactly 2.
- **Resolution:** Followed the `<action>`. The criterion's own stated rationale — "the literal is never duplicated into this file" — holds exactly: `grep -c "no longer recognizes" connection_copy.dart` is **0**, and the three `kRevokedExplanation` hits are the `show` import (line 13), the plan-mandated doc-comment reference (line 133) and the single `badMac` return (line 160). No literal duplication; `kRevokedExplanation` still has exactly one definition, in `reconnect_fsm.dart`.
- **Files modified:** none beyond the planned edit.

**2. [Naming] Summary written as `SUMMARY.md`, not `260731-d45-SUMMARY.md`**

- The plan's `<output>` block names `260731-d45-SUMMARY.md` (the sibling quick-task convention), while the execution brief specifies `SUMMARY.md`. Wrote `SUMMARY.md`, matching this directory's own unprefixed `PLAN.md`.

**3. [Cosmetic] The todo move recorded as delete plus add rather than `R`**

- `git mv` was used as instructed, but the appended Closed section pushed the similarity index below git's rename threshold, so `git diff --name-status` reports `A` plus `D`. The plan's verification step 7 explicitly permits either form.

No other deviations. No auth gates. No package installs — `pubspec.yaml`, `pubspec.lock`, `Cargo.toml`, `Cargo.lock` and `extension/manifest.json` are all untouched, so no Package Legitimacy Audit applies.

## Known Stubs

None.

## Self-Check: PASSED

- `.planning/todos/done/2026-07-09-nopairing-reason-overloaded-copy.md` — FOUND, contains `## Closed`
- `app/remote_control/lib/screens/connection_copy.dart` — FOUND, contains `kNoPinWindowCopy`
- `app/remote_control/test/pairing_flow_test.dart` — FOUND, contains `260731-d45`
- `extension/background.js` — FOUND, contains `capTitle`
- `.planning/phases/11-browser-bookmarks-view-open-star-current-tab/deferred-items.md` — FOUND, contains `260731-d45`
- Commit `0cd5104` — FOUND
- Commit `081df65` — FOUND
