---
quick_id: 260731-d45
slug: close-deferred-nopairing-copy-and-group-title-cap
type: quick
autonomous: true
commits: 2
files_modified:
  - app/remote_control/lib/screens/connection_copy.dart
  - app/remote_control/test/pairing_flow_test.dart
  - .planning/todos/pending/2026-07-09-nopairing-reason-overloaded-copy.md
  - .planning/todos/done/2026-07-09-nopairing-reason-overloaded-copy.md
  - extension/background.js
  - .planning/phases/11-browser-bookmarks-view-open-star-current-tab/deferred-items.md
requirements: [CONN-02, BROW-01]
must_haves:
  truths:
    - "A PIN submitted while the PC has NO active pairing window shows copy naming that problem and the next step — no longer the revoked-token line"
    - "A rejected token (badMac) still shows the D-05 revoked line, byte-identical to today"
    - "kRevokedExplanation keeps exactly ONE definition (reconnect_fsm.dart); connection_copy.dart imports it and never re-declares it"
    - "The wire is untouched: no new authFail reason, no fixture change, no remote_protocol change, no server change"
    - "A tab-group title whose emoji straddles MAX_GROUP_TITLE no longer serializes a lone high surrogate, so the tabs.state frame still decodes server-side"
    - "One lone-surrogate implementation exists in extension/background.js, shared by the bookmark cap and the group cap"
    - "MAX_GROUP_TITLE (32), MAX_BM_TITLE (48) and every other cap value are unchanged"
    - "The work lands as exactly TWO commits touching disjoint subsystems"
  artifacts:
    - path: "app/remote_control/lib/screens/connection_copy.dart"
      provides: "kNoPinWindowCopy + a split noPairing/badMac switch arm"
      contains: "kNoPinWindowCopy"
    - path: "app/remote_control/test/pairing_flow_test.dart"
      provides: "Tests pinning that noPairing and badMac now differ and that badMac is still exactly kRevokedExplanation"
      contains: "260731-d45"
    - path: ".planning/todos/done/2026-07-09-nopairing-reason-overloaded-copy.md"
      provides: "The closed todo with a Closed section recording that the stale wire-split sketch was rejected"
      contains: "## Closed"
    - path: "extension/background.js"
      provides: "capTitle(s, max) — the generalised lone-surrogate-safe title cap, used by BOTH the group cap and the bookmark cap"
      contains: "capTitle"
    - path: ".planning/phases/11-browser-bookmarks-view-open-star-current-tab/deferred-items.md"
      provides: "A closed note appended to item 1's row only"
      contains: "260731-d45"
  key_links:
    - from: "pairingErrorCopy case 'noPairing'"
      to: "kNoPinWindowCopy"
      via: "direct return (badMac stays on the imported kRevokedExplanation)"
      pattern: "kNoPinWindowCopy"
    - from: "buildAndSend group mapper"
      to: "capTitle"
      via: "title: capTitle(g.title, MAX_GROUP_TITLE)"
      pattern: "capTitle\\(g\\.title, MAX_GROUP_TITLE\\)"
    - from: "buildBmSnapshot node mapper"
      to: "capTitle"
      via: "title: capTitle(n.title, MAX_BM_TITLE)"
      pattern: "capTitle\\(n\\.title, MAX_BM_TITLE\\)"
---

<objective>
Close two long-standing deferred items that share nothing but a closing date.

1. **`noPairing` copy overload** (pending todo `2026-07-09-nopairing-reason-overloaded-copy.md`, open since the 03-07 E2E). A PIN submitted while the PC has no active pairing window renders "This PC no longer recognizes this phone — pair again" — copy that points the user at re-pairing a revoked token when the truth is "your PC isn't offering a PIN right now." Client-only split of one switch arm.

2. **Group-title lone-surrogate cap** (phase-11 `deferred-items.md` item 1). `extension/background.js` caps group titles with a raw `slice()`, which cuts UTF-16 code units and can emit a bare `\ud83d`. One line, routed through the lone-surrogate-safe helper plan 11-05 already wrote for bookmark titles.

Purpose: both have a written fix, both were blocked only on scope boundaries that no longer apply, and neither gets cheaper by waiting.
Output: TWO atomic commits. Commit 1 = Flutter client copy + tests + todo move. Commit 2 = extension one-liner + deferred-items note. They must NEVER share a commit — unrelated subsystems, unrelated risk.
</objective>

<critical_finding>
**The brief's blast-radius framing for fix 2 is wrong, and the commit message must not repeat it.**

The brief (inherited from `deferred-items.md` item 1 and the 11-05/11-06 summaries) says the group case is a *latent* robustness fix because `groups` is parsed LENIENTLY server-side while `bm.state` nodes are STRICT. Verified against the current tree, that mitigation does not exist:

- `server/server-core/src/transport/ext.rs:330` runs `serde_json::from_str::<ExtFrame>(text)` on the WHOLE frame first, and `ExtFrame.p` is a `serde_json::Value` (`ext.rs:164-169`) — so every string in the payload, group titles included, is decoded at that point.
- serde_json rejects an unpaired surrogate escape as a hard decode error. The `from_str` fails, `handle_ext_text` returns `None` at `ext.rs:332`, and the frame is dropped.
- The groups leniency at `ext.rs:345-351` (`.and_then(Result::ok).unwrap_or_default()`) operates on an ALREADY-PARSED `Value`. It never runs. Leniency is field-shape leniency, not lexical leniency.
- `ext.rs:353` is the only production site that sets `TabsState.connected = true`. So while a poisoned group title exists, every `tabs.state` frame dies before that line — the phone keeps the last good snapshot, and after any reconnect (`reset_relay_watches`) it shows the "install the extension" hint while the extension is connected and healthy.

Real severity: identical MECHANISM to the bookmark case, differing only in LIKELIHOOD (group titles are short and user-authored, so hitting char 32 with an emoji is rarer than hitting char 48 in a bookmark title). Not "decoration degrades to empty."

Consequences for this plan:
- The fix itself is unchanged — still one line. Do not enlarge it.
- The commit-2 message states the corrected severity (see task 2).
- The correction goes in the APPENDED closed note in `deferred-items.md`, not by editing the original row prose — the scope fence allows item 1's row to gain a note and nothing else.
</critical_finding>

<execution_context>
@$HOME/.claude/gsd-core/workflows/execute-plan.md
@$HOME/.claude/gsd-core/templates/summary.md
</execution_context>

<context>
@.planning/STATE.md
@CLAUDE.md

**Already verified by the planner — do NOT re-derive, do NOT open the server to check:**

- `server/server-core/src/transport/session.rs:626` emits `auth_fail("noPairing", ...)` from the `PinOutcome::NoPairing` branch ONLY (a PIN submitted with no active pairing window).
- `server/server-core/src/transport/session.rs:645` emits `auth_fail("badMac", ...)` from the `Msg::Auth` token-verification path ONLY.
- The server therefore ALREADY distinguishes the two cases. The stale "Fix sketch" in the todo (add a `noPinWindow` wire reason, touch fixtures and `remote_protocol`) is unnecessary and is explicitly rejected by this plan.
- `pairingErrorCopy` has exactly ONE production consumer: `pairing_dialog.dart:169` (`_errorCopy`). When a live `FailedEffect` is present it WINS over `widget.explanation`, so the new string is what the user actually sees on a `noPairing` rejection.
- **UI constraint that bounds the new copy:** `pairing_dialog.dart:262-269` renders the error line in a fixed `SizedBox(height: 24)` with `maxLines: 1` and `TextOverflow.ellipsis`. Anything materially longer than the shipped `kRevokedExplanation` (52 chars) gets ellipsized on a phone-width sheet.
- `capBmTitle` (`extension/background.js:548`) has exactly TWO in-repo references: its declaration and the call at line 591. All other hits are frozen phase-11 SUMMARY prose.
- `extension/background.js:492` is the LAST unguarded title slice in the file — tab titles are not char-capped at all (only the 56 KB frame budget), so there is no third hazard to chase.

**Deliberate non-changes (do not "helpfully" fix these):**
- `reconnect_fsm.dart:333` still treats `noPairing` as revoked (`ClearTokenEffect` + auth-stop). Changing D-05 token semantics is a behaviour change with its own test surface (`reconnect_fsm_test.dart:217-268`) and is out of scope. Leave `reconnect_fsm.dart`, `connection_service.dart` and their tests byte-identical.
- `03-UI-SPEC.md:160` (row "Error — revoked/stale token (`noPairing`/`badMac`)") is a frozen phase record that now describes `badMac` only. Do NOT edit it; the delta is recorded in the closed todo instead.
- No extension version bump. `extension/manifest.json` stays byte-identical.
</context>

<tasks>

<task type="auto">
  <name>Task 1 (COMMIT 1): split the noPairing copy off badMac — client only</name>
  <files>app/remote_control/lib/screens/connection_copy.dart, app/remote_control/test/pairing_flow_test.dart, .planning/todos/pending/2026-07-09-nopairing-reason-overloaded-copy.md</files>

  <read_first>
- `app/remote_control/lib/screens/connection_copy.dart` — whole file (161 lines). Note the two conventions in play: ~20 top-level `k*` copy constants, and inline literals inside the `pairingErrorCopy` switch.
- `app/remote_control/test/pairing_flow_test.dart` lines 50-105 (the `pairingErrorCopy` reason table) and lines 160-195 (the failure-rendering widget group). These are the ONLY two places that assert the current collapsed behaviour.
- `app/remote_control/lib/screens/pairing_dialog.dart` lines 161-178 (`_errorCopy` precedence) and lines 260-275 (the reserved single-line error box).
- `.planning/todos/pending/2026-07-09-nopairing-reason-overloaded-copy.md` — whole file.
- Do NOT open `server/`, `app/packages/remote_protocol/`, or `protocol/fixtures/`. This task has zero wire surface.
  </read_first>

  <action>
**1. `connection_copy.dart` — add the constant.** In the existing `// -- authFail reason mapping (CONN-02) --` section, immediately ABOVE the `String pairingErrorCopy(` declaration, add a new top-level constant named `kNoPinWindowCopy` whose value is exactly `Your PC isn't showing a PIN — start pairing on the PC`. Use a Dart double-quoted string (the value contains an ASCII apostrophe; this matches `kCameraErrorCopy` and `kQrMalformedCopy` in the same file). Use the em dash U+2014, matching every neighbouring string. Wrap as `const String kNoPinWindowCopy =` on one line and the string indented four spaces on the next, matching `kFirewallBlockedCopy`.

Give it a doc comment stating: this is the `noPairing` case — a PIN submitted while the PC has no active pairing window (`PinOutcome::NoPairing`), NOT a revoked token; `kRevokedExplanation` remains the `badMac` case.

Naming rationale (do not substitute another name): `k*Copy` matches the file's five other error-copy constants (`kFirewallBlockedCopy`, `kNonPrivateAddressCopy`, `kQrMalformedCopy`, `kCameraDeniedCopy`, `kCameraErrorCopy`). `NoPinWindow` is a CLIENT symbol name only — it is NOT a wire reason and must never be sent, decoded, or added to any fixture.

Copy rationale (do not shorten or lengthen): 53 characters, exactly one more than the shipped `kRevokedExplanation` (52), so it fits the same reserved `maxLines: 1` error line that copy already fits. It names the problem AND the next step, has no exclamation mark and no jargon, and mirrors the em-dash cadence of `That PIN expired — check your PC for a new one`. "start pairing on the PC" describes the real affordance (the tray / settings "Pair new device" action) without hardcoding a label that could drift.

**2. `connection_copy.dart` — split the switch arm.** In `pairingErrorCopy`, the fallthrough `case 'noPairing':` / `case 'badMac':` currently share one `return kRevokedExplanation;`. Give `case 'noPairing':` its own body returning `kNoPinWindowCopy`, and leave `case 'badMac':` returning `kRevokedExplanation`. Keep the existing comment about the D-05 string having a single definition in `reconnect_fsm.dart`, moved onto the `badMac` arm and reworded so it reads as badMac-only. NEVER re-declare or duplicate the `kRevokedExplanation` literal in this file — the `show kRevokedExplanation` import at line 13 stays exactly as-is. Every other arm (`pinInvalid`, `pinExpired`, `lockedOut`, `versionMismatch`, `default`) stays byte-identical.

**3. `pairing_flow_test.dart` — replace one unit test with two.** In the `group('pairingErrorCopy — the UI-SPEC reason table (CONN-02)')` group, delete the single test currently named `'noPairing and badMac both map to the D-05 revoked explanation (single definition from reconnect_fsm.dart)'` and put two tests in its place, at the same position:

- `'badMac maps to the D-05 revoked explanation (single definition from reconnect_fsm.dart)'` — asserts `pairingErrorCopy('badMac')` equals `kRevokedExplanation`, and asserts `kRevokedExplanation` is exactly `This PC no longer recognizes this phone — pair again` (the existing verbatim guard, preserved).
- `'noPairing gets its own no-PIN-window copy, distinct from badMac (260731-d45)'` — asserts, in this order: `pairingErrorCopy('noPairing')` is `isNot(pairingErrorCopy('badMac'))`; `pairingErrorCopy('noPairing')` equals `kNoPinWindowCopy`; `pairingErrorCopy('noPairing')` is `isNot(kRevokedExplanation)`; `kNoPinWindowCopy` is exactly `Your PC isn't showing a PIN — start pairing on the PC`; and `kNoPinWindowCopy.length` is `lessThanOrEqualTo(kRevokedExplanation.length + 4)` with a `reason:` naming the reserved single-line error box (`maxLines: 1` + ellipsis) that bounds it.

**4. `pairing_flow_test.dart` — update the widget test body (not its name).** In `testWidgets('raw reason enums never reach a rendered widget')`, keep the `for (final reason in ['badMac', 'noPairing'])` loop and the raw-enum negative assertion over `_renderedTexts` exactly as they are. Replace only the unconditional `expect(find.text(kRevokedExplanation), findsOneWidget);` with a per-reason expectation: bind a local `expected` to `kRevokedExplanation` when `reason` is `'badMac'` and to `kNoPinWindowCopy` otherwise, then assert `find.text(expected)` finds one widget. Do not restructure the loop, do not change `_sheet`, do not touch any other test in the file.

**5. Move the todo.** Run `git mv .planning/todos/pending/2026-07-09-nopairing-reason-overloaded-copy.md .planning/todos/done/2026-07-09-nopairing-reason-overloaded-copy.md`, then append a `## Closed — quick 260731-d45 (2026-07-31)` section at the end of the moved file, matching the house convention already used by `.planning/todos/done/2026-07-09-server-one-pairing-per-run.md`. It must record, in prose: (a) the "Fix sketch" above was STALE and was deliberately NOT followed — no `noPinWindow` wire reason, no server change, no fixture change, no `remote_protocol` change; (b) why it was unnecessary — `session.rs:626` emits `noPairing` only from `PinOutcome::NoPairing` and `session.rs:645` emits `badMac` only from the `Msg::Auth` path, so the server already distinguished them and the collapse was purely the client's `pairingErrorCopy` switch; (c) what shipped — `kNoPinWindowCopy` on the `noPairing` arm, `kRevokedExplanation` retained on `badMac`; (d) the deliberate non-change — `reconnect_fsm.authRejected` still treats `noPairing` as revoked (`ClearTokenEffect` + auth-stop), which is arguably wrong for a PIN-window problem but is a D-05 behaviour change out of this task's scope, and it does not affect what the user reads because a live `FailedEffect` outranks `widget.explanation` in `_errorCopy`; (e) that `03-UI-SPEC.md:160` is a frozen phase record now describing `badMac` only and was intentionally left unedited.

**6. Commit.** Stage exactly these paths and commit with subject `fix(quick-260731-d45): give noPairing its own copy, distinct from badMac`. The body must state that this is client-only with zero wire change, that the server already distinguished the two reasons, and that the stale wire-split sketch in the todo was rejected. Do NOT stage `extension/` or `deferred-items.md` — they belong to commit 2.
  </action>

  <verify>
    <automated>cd app/remote_control &amp;&amp; flutter analyze &amp;&amp; flutter test</automated>
  </verify>

  <acceptance_criteria>
- `flutter analyze` is clean — no new warnings, no unused constant.
- `flutter test` reports **609** passing, up exactly 1 from the 608 baseline (one unit test became two; the widget test count is unchanged). Any other number means an unintended edit — stop and reconcile before committing.
- `pairingErrorCopy('noPairing')` and `pairingErrorCopy('badMac')` return different strings; `pairingErrorCopy('badMac')` is `kRevokedExplanation` exactly.
- `grep -c "kRevokedExplanation" app/remote_control/lib/screens/connection_copy.dart` is 2 (the `show` import and the single `badMac` return) — the literal is never duplicated into this file.
- `git diff --stat` before committing lists exactly three paths: `connection_copy.dart`, `pairing_flow_test.dart`, and the todo rename. `git status` shows the todo as a rename (`R`) into `.planning/todos/done/`, and `.planning/todos/pending/` is now empty.
- `git diff --stat -- server/ app/packages/remote_protocol/ protocol/ extension/` produces NO output.
- Exactly one commit was created by this task.
  </acceptance_criteria>

  <done>`noPairing` renders its own no-PIN-window line, `badMac` still renders the D-05 revoked line, the wire is untouched, the suite is green at 609, and the todo has moved to `done/` with a Closed section — all in ONE commit.</done>
</task>

<task type="auto">
  <name>Task 2 (COMMIT 2): route the group-title cap through the lone-surrogate-safe helper</name>
  <files>extension/background.js, .planning/phases/11-browser-bookmarks-view-open-star-current-tab/deferred-items.md</files>

  <read_first>
- `extension/background.js` lines 20-45 (the wire-cap constants block and `bytesOf`, the file's shared-helper anchor), lines 478-500 (the group mapper holding the unguarded slice at line 492), and lines 538-600 (`capBmTitle` and its call site in `buildBmSnapshot`).
- `.planning/phases/11-browser-bookmarks-view-open-star-current-tab/deferred-items.md` — read line 7 (item 1) only. Lines 8, 9 and 10 (items 2, 3, 4) are fenced OUT of scope and must end byte-identical.
- Do NOT open or modify `server/`. The `ext.rs` decode behaviour that sets the severity is already summarised in this plan's `<critical_finding>`; treat it as given.
  </read_first>

  <action>
**1. Generalise the helper.** Rename `capBmTitle(s)` to `capTitle(s, max)` — one parameterised implementation, the cap length passed in rather than `MAX_BM_TITLE` hardcoded. The body is otherwise unchanged: slice `(s || "")` to `max`, then drop the last code unit when its char code is in `0xD800..0xDBFF`. Update the single existing call site at line 591 to `capTitle(n.title, MAX_BM_TITLE)`.

Decision rationale, recorded here so it is not relitigated at execution time: a defaulted `capBmTitle(s, max = MAX_BM_TITLE)` keeps a name that lies the moment it serves a group title, and a second helper is exactly the "second approach" this task forbids. One `capTitle(s, max)` keeps a SINGLE lone-surrogate implementation, which is the property that matters — the failure mode is silent and identical on both paths.

**2. Relocate it to the shared-helper area.** Move the function so it sits immediately after `bytesOf` (which ends at line 37) and before the `GROUP_ID_NONE` const. Hoisting means the call at line 492 would resolve either way, but the tabs section would otherwise call a function declared 50 lines below it inside the bookmarks section — `bytesOf` is already the file's established home for shared caps/measurement helpers.

Rewrite its doc comment while moving it, to cover BOTH consumers honestly: `slice()` cuts UTF-16 code units, so an emoji straddling the cap is split in half and `JSON.stringify` emits a bare `\ud83d`; serde_json rejects an unpaired surrogate escape as a hard decode error, and on BOTH paths the server parses the whole frame envelope before any per-field tolerance runs — so one such title costs the entire `bm.state` tree on the bookmarks path and the entire `tabs.state` snapshot (including the extension-connected signal) on the tabs path. Do not repeat the old comment's claim that the groups path is protected by lenient parsing; see `<critical_finding>`.

**3. The one-line fix.** At the group mapper (line 492), replace `title: (g.title || "").slice(0, MAX_GROUP_TITLE),` with `title: capTitle(g.title, MAX_GROUP_TITLE),`. The `|| ""` guard is preserved inside `capTitle`, so the call needs no extra guard. This is the only behavioural change in the file.

**4. Change nothing else in the extension.** `MAX_GROUP_TITLE` stays 32, `MAX_BM_TITLE` stays 48, `MAX_TABS`, `MAX_GROUPS`, `MAX_BM_NODES`, `MAX_ICON_B64` and `MAX_FRAME_BYTES` all stay at their current values. No `manifest.json` edit, no version bump, no new logging (the privacy rule at the top of the file forbids logging titles — do not add a diagnostic that prints one).

**5. Append a closed note to item 1's row in `deferred-items.md`.** Append to the END of item 1's existing "Why deferred" cell, on the SAME line (a markdown table row is one line). The note must: mark the item closed by quick task 260731-d45; state that the group cap now routes through the shared `capTitle(s, max)` helper with `MAX_GROUP_TITLE` unchanged at 32; and CORRECT the record — the row's "parsed LENIENTLY server-side" reasoning does not hold, because `ext.rs:330` decodes the whole `ExtFrame` (with `p` as a `serde_json::Value`) before the groups tolerance at `ext.rs:345-351` can run, so a poisoned title killed the entire `tabs.state` frame including the `connected: true` signal at `ext.rs:353`; the real difference from the bookmark case was likelihood, not leniency. Any literal `|` in the appended text MUST be escaped as `\|` or the table breaks — prefer wording with no pipes at all. Do not reflow, re-wrap, or otherwise touch the rest of item 1's row, and do not touch rows 2, 3 or 4.

**6. Commit.** Stage exactly `extension/background.js` and `deferred-items.md` and commit with subject `fix(quick-260731-d45): trim lone surrogates from capped group titles`. The body must state the blast radius as corrected in `<critical_finding>` — same mechanism as the bookmark cap, and NOT mitigated by the groups leniency, because that leniency runs after the whole-frame decode that a lone surrogate already failed; the practical difference from the bookmark case is likelihood, not severity. Do not restate the old "latent robustness fix" framing.
  </action>

  <verify>
    <automated>node --check extension/background.js &amp;&amp; node -e "const fs=require('fs');const src=fs.readFileSync('extension/background.js','utf8');const m=src.match(/function capTitle[\s\S]*?\n}/);if(!m)throw new Error('capTitle not found');const f=eval('('+m[0]+')');const t='a'.repeat(31)+String.fromCodePoint(128512);if(t.slice(0,32).length!==32)throw new Error('premise broken');if(f(t,32).length!==31)throw new Error('lone surrogate NOT trimmed');if(f('x'.repeat(40),32).length!==32)throw new Error('cap not applied');if(f(undefined,32)!=='')throw new Error('null-title guard lost');console.log('capTitle OK: caps at 32, trims the straddling surrogate, null-safe')"</automated>
  </verify>

  <acceptance_criteria>
- `node --check extension/background.js` exits 0, and the `capTitle` assertion above prints its OK line.
- `grep -c "capBmTitle" extension/background.js` is 0; `grep -c "capTitle" extension/background.js` is at least 3 (declaration plus both call sites).
- `grep -n "slice(0, MAX_GROUP_TITLE)" extension/background.js` returns nothing — the raw slice is gone.
- `grep -n "MAX_GROUP_TITLE = 32" extension/background.js` and `grep -n "MAX_BM_TITLE = 48" extension/background.js` both still match — no cap value moved.
- `git diff --numstat -- .planning/phases/11-browser-bookmarks-view-open-star-current-tab/deferred-items.md` reports exactly `1	1` (one line changed). Any other number means a fenced row was touched — revert and redo.
- The deferred-items table still renders: the file has exactly 6 lines beginning with `|` (header, separator, 4 item rows).
- `git diff --stat -- server/ app/packages/remote_protocol/ app/remote_control/ extension/manifest.json` produces NO output.
- Exactly one commit was created by this task, and it is the SECOND commit.
  </acceptance_criteria>

  <done>Group titles are capped through the same lone-surrogate-safe helper as bookmark titles, every cap value is unchanged, item 1 of the phase-11 deferred list carries a closed note that also corrects its severity claim, and items 2-4 are byte-identical — all in ONE commit.</done>
</task>

</tasks>

<threat_model>
## Trust Boundaries

| Boundary | Description |
|----------|-------------|
| PC server → phone | `authFail` reasons are server-chosen strings the phone maps to copy; a hostile or spoofed server picks which line the user reads |
| PC browser extension → PC server | Group and bookmark titles are user/site-influenced strings that must survive JSON round-trip into serde_json |

## STRIDE Threat Register

| Threat ID | Category | Component | Disposition | Mitigation Plan |
|-----------|----------|-----------|-------------|-----------------|
| T-d45-01 | Information Disclosure | `pairingErrorCopy` | mitigate | `kNoPinWindowCopy` is a fixed literal naming no host, port, PIN, token or enum. The whitelist switch and its `default` retry line are unchanged, so T-03-24 (raw enum never reaches the user) still holds — pinned by the untouched `'raw reason enums never reach a rendered widget'` test, which now covers both reasons against their distinct expected strings |
| T-d45-02 | Spoofing | server-chosen `authFail` reason | accept | A hostile server could send `noPairing` to steer the user toward re-pairing. Unchanged from today: the FSM's auth-stop and `ClearTokenEffect` semantics are byte-identical, and the new copy directs the user to an OUT-OF-BAND action on their own PC (start pairing there), which is no weaker than the previous "pair again" |
| T-d45-03 | Denial of Service | `extension/background.js` group title cap | mitigate | The fix. A crafted or merely emoji-decorated group title straddling char 32 previously emitted an unpaired surrogate escape that failed the whole-frame `serde_json::from_str` at `ext.rs:330`, silently killing every `tabs.state` frame and the `connected: true` signal with it. `capTitle` trims the trailing high surrogate so the frame decodes |
| T-d45-04 | Tampering | `deferred-items.md` fenced rows | mitigate | Items 2-4 are owner-fenced. Enforced mechanically by the `git diff --numstat` = `1 1` acceptance criterion, not by careful reading |
| T-d45-SC | Tampering | supply chain | mitigate | ZERO package installs. `pubspec.yaml`, `pubspec.lock`, `Cargo.toml`, `Cargo.lock` and `extension/manifest.json` are not in `files_modified`; a diff touching any of them is a task failure. No Package Legitimacy Audit is required because no npm/pub/cargo install occurs |
</threat_model>

<verification>
Run after BOTH commits exist. `HEAD~2..HEAD` is exactly this task's two commits — if that range is not exactly these two, stop.

1. `cd app/remote_control && flutter analyze` — clean.
2. `cd app/remote_control && flutter test` — **609** passing (baseline 608, +1 from splitting the copy test).
3. `cd server && cargo test --workspace` — **202** passing, unchanged.
4. `cd app/packages/remote_protocol && dart test` — **13** passing, unchanged.
5. `node --check extension/background.js` — exits 0; the task-2 `capTitle` assertion prints its OK line.
6. Scope fence: `git diff --stat HEAD~2..HEAD -- server/ app/packages/remote_protocol/` produces NO output. Same for `protocol/` and `extension/manifest.json`.
7. `git diff --name-status HEAD~2..HEAD` lists exactly: `app/remote_control/lib/screens/connection_copy.dart`, `app/remote_control/test/pairing_flow_test.dart`, the todo rename `pending/2026-07-09-nopairing-reason-overloaded-copy.md` → `done/...` (as `R`, or as one delete + one add), `extension/background.js`, and `.planning/phases/11-browser-bookmarks-view-open-star-current-tab/deferred-items.md`. Nothing else.
8. `git diff --numstat HEAD~2..HEAD -- .planning/phases/11-browser-bookmarks-view-open-star-current-tab/deferred-items.md` reports `1	1`.
9. `git log --oneline -2` shows the two subjects in order: the group-title commit on top, the `noPairing` copy commit beneath it. Neither commit contains files from the other subsystem — confirm with `git show --stat HEAD` and `git show --stat HEAD~1`.
10. `ls .planning/todos/pending/` is empty.
</verification>

<success_criteria>
- A PIN submitted with no active pairing window shows `Your PC isn't showing a PIN — start pairing on the PC`; a rejected token still shows `This PC no longer recognizes this phone — pair again`.
- `kRevokedExplanation` still has exactly one definition, in `reconnect_fsm.dart`, imported by `connection_copy.dart`.
- Zero wire change: server, `protocol/fixtures/` and `app/packages/remote_protocol/` are untouched, and their suites stay at 202 and 13.
- The `noPairing` todo is in `.planning/todos/done/` with a Closed section recording that the stale wire-split sketch was rejected and why.
- A group title whose emoji straddles char 32 no longer produces a lone surrogate; one `capTitle(s, max)` serves both title caps; every cap value is unchanged.
- Item 1 of the phase-11 deferred list carries a closed note that also corrects its lenient-parse severity claim; items 2, 3 and 4 are byte-identical.
- Exactly TWO commits, one per subsystem, neither contaminated by the other.
</success_criteria>

<artifacts_produced>
New and changed symbols, by commit.

**Commit 1 — `app/remote_control/lib/screens/connection_copy.dart`**
- `kNoPinWindowCopy` — new top-level `const String`, value `Your PC isn't showing a PIN — start pairing on the PC` (53 chars, U+2014 em dash, ASCII apostrophe, double-quoted). The `noPairing` arm of `pairingErrorCopy` returns it. A CLIENT symbol only — never a wire reason.
- `pairingErrorCopy` — unchanged signature; the fallthrough `case 'noPairing': case 'badMac':` becomes two independent arms.

**Commit 1 — `app/remote_control/test/pairing_flow_test.dart`**
- `'badMac maps to the D-05 revoked explanation (single definition from reconnect_fsm.dart)'` — new test (replaces the collapsed one).
- `'noPairing gets its own no-PIN-window copy, distinct from badMac (260731-d45)'` — new test.
- `'raw reason enums never reach a rendered widget'` — existing test, name unchanged, body now expects the per-reason string.

**Commit 1 — `.planning/todos/done/2026-07-09-nopairing-reason-overloaded-copy.md`**
- `## Closed — quick 260731-d45 (2026-07-31)` — new section on the moved file.

**Commit 2 — `extension/background.js`**
- `capTitle(s, max)` — the generalised lone-surrogate-safe cap, relocated to sit after `bytesOf`. Replaces `capBmTitle(s)`, which no longer exists.
- Call sites: `capTitle(g.title, MAX_GROUP_TITLE)` in the group mapper (the fix) and `capTitle(n.title, MAX_BM_TITLE)` in `buildBmSnapshot` (the rename).
- Known stale references, accepted and NOT chased: phase-11 `11-05-SUMMARY.md` and `11-06-SUMMARY.md` name `capBmTitle` in frozen historical prose (including an old `grep -c "MAX_BM_TITLE"` observation). Frozen phase records are not edited; the rename is recorded in this quick task's SUMMARY instead.

**Commit 2 — `deferred-items.md`**
- No new symbols. Item 1's row gains a closed note that also corrects its severity reasoning.
</artifacts_produced>

<output>
Create `.planning/quick/260731-d45-close-deferred-nopairing-copy-and-group-title-cap/260731-d45-SUMMARY.md` when done.

The SUMMARY must record: the rejected stale fix sketch (no wire change was needed); the corrected blast radius for the group-title cap and the fact that `deferred-items.md` item 1's original leniency reasoning was wrong; the `capBmTitle` → `capTitle` rename and its stale references in frozen phase-11 summaries; and the deliberate non-change to `reconnect_fsm.authRejected`'s `noPairing`-clears-the-token behaviour, which remains open.
</output>
