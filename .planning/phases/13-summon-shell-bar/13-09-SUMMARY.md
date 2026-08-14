---
phase: 13-summon-shell-bar
plan: 09
subsystem: flutter-app-shell
tags: [summon, BAR-03, BAR-04, focus-gate, security, suppressor, D-13-17, CR-2, T-13-01, T-13-16, T-13-02]
status: complete

requires:
  - "13-01: SummonShellController (hiddenImeNode, suppressBar/releaseBar/barVisible), SummonScope"
  - "13-02: SummonBar, SummonIconButton's four-state function, kSummonKeyboardBlockedLabel, the bar's own Overlay layer"
  - "13-03: the single dismiss seam (untouched here, but the shape the Phase-15 escape protects)"
  - "13-07: pushGuarded<T> — the QR suppressor wraps the screen INSIDE that seam, it does not replace it"
provides:
  - "localTextFieldHasFocus(FocusNode?) — BAR-03's corrected predicate, a property of the focused node and not of any screen"
  - "The keyboard icon's focus gate, scoped to one 56x56 slot and proved so by a rebuild counter"
  - "SummonBarSuppressor — the route-scoped, depth-counted bar suppressor, mounted at exactly one site"
  - "The end-of-frame rule for any future route-scoped mutation of app-scope shell state"
  - "test/shell/summon_bar_focus_gate_test.dart (9 cases) and test/shell/summon_bar_scope_test.dart (7 cases)"
affects:
  - "Phase 15 (raised keyboard): the identity escape is already shipped and tested — set controller.hiddenImeNode when HiddenTextInput mounts and the keyboard icon stays live while the keyboard is up. Nothing else to do."
  - "Phase 14 (raised trackpad): the trackpad icon never enters the blocked state and no off-variant glyph exists for it — do not add one."
  - "Any future screen that gains a text field: covered on the day it is written, with no edit to the bar and nothing to remember."
  - "Any future route that wants the bar gone: wrap it in SummonBarSuppressor — but note the source gate asserts exactly two files reference it, so a second site is a deliberate decision that must move the gate."

tech-stack:
  added: []
  patterns:
    - "A cross-cutting gate implemented as a property of the runtime object (the focused node), never as an allowlist of screens — the allowlist is what rots when a screen is added"
    - "The wrong version of a predicate is written into the code comment beside the right one, because the wrong one reads more natural"
    - "Rebuild scope on a hot path is asserted with debugOnRebuildDirtyWidget, not reviewed"
    - "A route-scoped widget mutating app-scope state applies both lifecycle edges in a post-frame callback — initState runs mid-build and dispose runs under finalizeTree's lockState"
    - "An accepted consequence gets a test that states the requirement it serves, so a later reader cannot 'fix' it"

key-files:
  created:
    - "app/remote_control/lib/shell/summon_bar_suppressor.dart"
    - "app/remote_control/test/shell/summon_bar_focus_gate_test.dart"
    - "app/remote_control/test/shell/summon_bar_scope_test.dart"
  modified:
    - "app/remote_control/lib/shell/summon_bar.dart"
    - "app/remote_control/lib/shell/summon_scope.dart"
    - "app/remote_control/lib/screens/pairing_dialog.dart"

key-decisions:
  - "BAR-03's gate is a property of the FOCUSED NODE and names no screen: non-null, not the shell's hidden IME node by reference identity, has a build context, has an exact-type EditableText ancestor (D-13-17)."
  - "The milestone's original predicate is FALSIFIED in the suite rather than merely corrected in prose — restoring it reds the nothing-focused case, because focus reverts to the root scope and that version ships a permanently dead button."
  - "The Phase-15 escape ships now, tested against a REAL EditableText the shell owns, because the trap only appears two phases later and by then the escape looks like dead code."
  - "The focus listener wraps ONE slot, proved by a rebuild counter that asserts the bar and the trackpad icon do NOT rebuild on a focus change."
  - "Both suppressor lifecycle edges apply in a post-frame callback — a route-scoped widget cannot notify a sibling subtree inline from initState (mid-build) or dispose (under lockState). One frame at each boundary, neither observable, asserted frame-by-frame."
  - "SummonShellController ignores suppress/release once disposed, so a deferred release cannot reach a dead notifier during teardown."
  - "The bar over modal routes now carries a test naming the success criterion that requires it, so it reads as a requirement rather than an oversight."

patterns-established:
  - "Node-property gates over screen allowlists: the gate must stay correct for a screen that does not exist yet, and the test suite must not pump today's screens to prove it"
  - "End-of-frame application for route→shell state mutations, with the framework reason (build phase / lockState) written at the call site"
  - "Frame-window assertions: when a deferral is unavoidable, assert the property that actually matters (no chrome over a visible pixel) rather than the frame count"

requirements-completed: [BAR-03, BAR-04]

coverage:
  - id: D1
    description: "The keyboard icon is visibly disabled while a local text field holds focus and enabled otherwise, so a pairing PIN can never be typed into the PC"
    requirement: "BAR-03"
    verification:
      - kind: unit
        ref: "test/shell/summon_bar_focus_gate_test.dart#focusing a text field in the body disables the keyboard icon and leaves the trackpad icon live"
        status: pass
      - kind: unit
        ref: "test/shell/summon_bar_focus_gate_test.dart#unfocusing the field re-enables the keyboard icon"
        status: pass
    human_judgment: false
  - id: D2
    description: "The gate names no screen and stays correct for a future screen that gains a text field — it is a property of the focused node, not an allowlist"
    requirement: "BAR-03"
    verification:
      - kind: command
        ref: "! grep -Ev '^\\s*//' lib/shell/summon_bar.dart lib/shell/summon_icon_button.dart | grep -Eiq 'pairingdialog|devicelistscreen|qrscanscreen|screenname|allowlist'"
        status: pass
      - kind: unit
        ref: "test/shell/summon_bar_focus_gate_test.dart — the suite focuses fields it creates itself and never pumps a real screen"
        status: pass
    human_judgment: false
  - id: D3
    description: "With nothing focused the icon is ENABLED — the milestone's absent-focus predicate would have shipped a permanently disabled button"
    requirement: "BAR-03"
    verification:
      - kind: unit
        ref: "test/shell/summon_bar_focus_gate_test.dart#with NOTHING focused the keyboard icon is enabled"
        status: pass
      - kind: command
        ref: "manual falsification — milestone predicate restored in lib/, that case RED; tree restored"
        status: pass
    human_judgment: false
  - id: D4
    description: "A focus node the shell owns as its hidden IME field does not disable the icon, so Phase 15's raised keyboard stays dismissible"
    requirement: "BAR-03"
    verification:
      - kind: unit
        ref: "test/shell/summon_bar_focus_gate_test.dart#THE PHASE-15 ESCAPE"
        status: pass
      - kind: command
        ref: "manual falsification — identity escape removed, that case RED; tree restored"
        status: pass
    human_judgment: false
  - id: D5
    description: "Disabled is not hidden: the icon keeps its slot, the bar rect and both slot rects are unchanged, and the disable is carried by a glyph rather than a colour"
    requirement: "BAR-03"
    verification:
      - kind: unit
        ref: "test/shell/summon_bar_focus_gate_test.dart#DISABLED IS NOT HIDDEN"
        status: pass
      - kind: unit
        ref: "test/shell/summon_bar_focus_gate_test.dart#CR-2: the disabled state is a GLYPH swap, not a tint change"
        status: pass
    human_judgment: false
  - id: D6
    description: "The blocked-state sentence reaches a screen reader while the icon is disabled, and the disabled slot advertises no tap"
    requirement: "BAR-03"
    verification:
      - kind: unit
        ref: "test/shell/summon_bar_focus_gate_test.dart#the blocked-state sentence is DISCOVERABLE while the icon is disabled"
        status: pass
    human_judgment: false
  - id: D7
    description: "A focus change rebuilds only the keyboard icon's subtree — the bar on the trackpad's hot path is untouched"
    verification:
      - kind: unit
        ref: "test/shell/summon_bar_focus_gate_test.dart#a focus change rebuilds ONLY the keyboard icon subtree"
        status: pass
    human_judgment: false
  - id: D8
    description: "The bar is absent entirely on the QR scan screen — by key, not by opacity or size — and returns with an unchanged rect after that route pops"
    requirement: "BAR-04"
    verification:
      - kind: unit
        ref: "test/shell/summon_bar_scope_test.dart#under suppression the bar is ABSENT"
        status: pass
      - kind: unit
        ref: "test/shell/summon_bar_scope_test.dart#popping the suppressed route restores the bar with its pre-push rect"
        status: pass
    human_judgment: false
  - id: D9
    description: "Suppression is depth-counted, so overlapping route lifetimes compose: nested suppressors restore the bar exactly once, and releasing one while another is mounted restores nothing"
    requirement: "BAR-04"
    verification:
      - kind: unit
        ref: "test/shell/summon_bar_scope_test.dart#two NESTED suppressors, both released, restore the bar exactly once"
        status: pass
      - kind: unit
        ref: "test/shell/summon_bar_scope_test.dart#releasing ONE suppressor while another is still mounted leaves the bar suppressed"
        status: pass
      - kind: command
        ref: "manual falsification — counter replaced by a boolean, the sibling-release case RED; tree restored"
        status: pass
    human_judgment: false
  - id: D10
    description: "The bar is never drawn over a visible pixel of the suppressed screen, across every frame of a full push/pop pair"
    requirement: "BAR-04"
    verification:
      - kind: unit
        ref: "test/shell/summon_bar_scope_test.dart#THE FLICKER PROOF"
        status: pass
      - kind: command
        ref: "manual falsification — suppression delayed 200ms, the flicker proof RED; tree restored"
        status: pass
    human_judgment: false
  - id: D11
    description: "There is exactly one suppression site in the app, and pairing still works end to end through it"
    requirement: "BAR-04"
    verification:
      - kind: command
        ref: "test \"$(grep -rc 'SummonBarSuppressor' lib/ | grep -vc ':0')\" -eq 2"
        status: pass
      - kind: unit
        ref: "test/qr_scan_pairing_test.dart + test/pairing_flow_test.dart — 25 cases, all pass"
        status: pass
    human_judgment: false
  - id: D12
    description: "On hardware: the keyboard icon reads as unmistakably disabled on the pairing sheet and the device list, and the scanner is free of chrome"
    verification: []
    human_judgment: true
    rationale: "The suite proves the glyph swaps, the tint is unchanged either side, the semantics carry the sentence and the bar's key resolves to nothing on a suppressed route. Whether the slashed glyph reads as 'disabled' at a glance on a real phone, and whether the one-frame bar lingering at the very start of the push is genuinely imperceptible, are eyeball observations — both belong on plan 13-10's UAT list."

metrics:
  duration: ~25min
  completed: 2026-08-14
  tasks: 2
  commits: 2
  files: 6

actuals:
  tokens: 12100
  tasks: 2
  commits: 2

duration: ~25min
completed: 2026-08-14
---

# Phase 13 Plan 09: The Focus Gate and the QR Suppressor Summary

**A pairing PIN can no longer be routed to the PC: the keyboard icon disables itself for exactly as long as any local text field holds focus, by a predicate that is a property of the focused node and names no screen — and the bar disappears entirely on the QR scanner, depth-counted so it never blinks at a route boundary.**

## Performance

- **Duration:** ~25 min
- **Completed:** 2026-08-14
- **Tasks:** 2
- **Files created:** 3, modified: 3

## Task Commits

1. **Task 1: The corrected focus predicate, and the escape that keeps Phase 15 dismissible** — `99f640f` (feat)
2. **Task 2: Depth-counted bar suppression on the QR scanner** — `9a0c318` (feat)

## Accomplishments

- **BAR-03 shipped as a node property, not a screen list.** `localTextFieldHasFocus` asks four questions of the focused node and nothing about which screen is showing. The pairing sheet's PIN field, both device-list fields and any field a future screen grows are covered identically, with no edit here and nothing to remember. A source gate fails the build if either bar file ever names a screen.
- **The milestone's predicate is falsified, not just corrected.** `primaryFocus == null` is essentially never true — focus reverts to the root scope and `WidgetsApp` autofocuses a scope around the `Navigator` — so that version ships a permanently dead button. Restoring it in `lib/` reds the nothing-focused case, by hand, recorded below.
- **Phase 15's escape is already in the tree, with a test.** A focus node the shell declares as its hidden IME field does not disable the icon, asserted against a genuine `EditableText`. Without it, raising the keyboard two phases from now would disable the one affordance that dismisses it.
- **The rebuild scope is asserted, not reviewed.** A focus change rebuilds the keyboard slot and nothing else — the bar and the trackpad icon are proved untouched with `debugOnRebuildDirtyWidget`. The bar sits on the trackpad's hot path on every screen, so this is a latency contract.
- **BAR-04 shipped depth-counted, at exactly one mount site**, asserted absent by key rather than by opacity or size, with the nesting and sibling-release cases both pinned and the boolean version proved red.

## Files Created/Modified

- `lib/shell/summon_bar.dart` — `localTextFieldHasFocus` plus a `ListenableBuilder` over the focus manager wrapping **only** the keyboard slot. The whole correction, including why the wrong predicate reads more natural, is written into the doc comment above the function.
- `lib/shell/summon_bar_suppressor.dart` (new) — the route-scoped, depth-counted suppressor. Its doc states why it is counted, why both edges are deferred to end-of-frame, that there is one mount site, and that the bar over modal routes is required rather than tolerated.
- `lib/shell/summon_scope.dart` — the controller ignores suppress/release once disposed (see deviation 2).
- `lib/screens/pairing_dialog.dart` — the QR push now hands `pushGuarded` a suppressor-wrapped screen. The guard stays outermost; the nesting rule is stated at the site.
- `test/shell/summon_bar_focus_gate_test.dart` (new) — 9 cases.
- `test/shell/summon_bar_scope_test.dart` (new) — 7 cases.

`summon_icon_button.dart` and `summon_shell.dart` were listed in the plan's `files_modified` but needed **no change**: 13-02 already shipped the four-state function with the `keyboard_off_rounded` swap and the ancestor `Tooltip`, and the shell already consumed `barVisible` through a `ValueListenableBuilder`. Plan 13-02's "wired as a value rather than omitted so 13-09 changes one expression" held exactly — the blocked input went from a `const false` to a call.

## Every mutation run red by hand

A test nobody has seen fail is a test nobody knows works. Four mutations were applied to `lib/`, run, and reverted; `git diff` over `lib/` is empty afterwards and the committed tree is byte-identical.

| Mutation | Result |
|---|---|
| `localTextFieldHasFocus` → the milestone's `primaryFocus != null` | **RED** at *"with NOTHING focused the keyboard icon is enabled"* (plus two more). This is the case the plan named, and it fails first. |
| `identical(node, shellImeNode)` escape deleted | **RED** at *"THE PHASE-15 ESCAPE"*, and **only** there — the escape is load-bearing and nothing else depends on it. |
| Depth counter replaced by a boolean (`releaseBar` sets visible unconditionally) | **RED** at *"releasing ONE suppressor while another is still mounted"*, and only there. The nesting case survives a boolean; the sibling case is the one that does not. |
| Suppression applied 200ms late instead of at end-of-frame | **RED** at *"THE FLICKER PROOF"* (plus three more). The frame-window assertion is not vacuous. |

## Decisions Made

See `key-decisions` in the frontmatter. The two worth reading in full are the node-property gate (why an allowlist was never on the table) and the end-of-frame rule (below).

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] A route-scoped widget cannot mutate app-scope shell state inline at either lifecycle edge**

- **Found during:** Task 2, on the first run of the scope suite — 5 of 7 cases red.
- **Issue:** The plan (and 13-RESEARCH §9) specify `initState: suppressBar()` / `dispose: releaseBar()`. Both throw. `initState` for a pushed route runs while the framework is building, and the bar's layer — the `ValueListenableBuilder` on `barVisible` — is a **sibling** subtree, not an ancestor: *"setState() or markNeedsBuild() called during build ... The widget which was currently being built when the offending call was made was: SummonGuardScope."* `dispose` is no better: element unmount happens inside `BuildOwner.finalizeTree`, which runs `lockState` (`framework.dart:3344`), so a notification there throws *"called when widget tree was locked"*. The research prescribed the shape without executing it.
- **Fix:** both edges apply through `_atEndOfFrame`, which posts a frame callback when the scheduler is in `persistentCallbacks` and mutates immediately otherwise. The cost is one frame at each boundary and **neither is observable**: on push the extra frame is the frame in which the incoming route's transition value is still 0 (translated entirely off the viewport), and on pop the route is disposed only after its transition has finished, so the bar returns *late*, never early — the correct direction for the one boundary where being early would put chrome back over live credential capture.
- **Assertion, not assumption:** the flicker proof was rewritten to pin what actually matters — *the bar is never drawn over a visible pixel of the suppressed screen* — by walking the frames and asserting the two rects never overlap, then that the bar is gone for every frame from the moment the route is on screen. Proved to have teeth by the 200ms-late mutation above.
- **Files modified:** `lib/shell/summon_bar_suppressor.dart`.
- **Committed in:** `9a0c318`

**2. [Rule 2 - Missing critical] A deferred release could outlive the shell and throw during teardown**

- **Found during:** Task 2, reasoning through deviation 1's fix.
- **Issue:** Once the release is deferred, a post-frame callback can fire after `SummonShellController.dispose()` has already disposed `barVisible` — an app or test tearing down with a suppressed route still mounted. `ValueNotifier` throws when used after disposal, so the failure mode is a crash on the way out, in a path with no user-visible cause.
- **Fix:** `SummonShellController` records `_disposed` and both `suppressBar` and `releaseBar` return early once set. Mutating a dead controller is a no-op, not a crash. `lib/shell/summon_scope.dart` was not in the plan's `files_modified`; the four-line guard is recorded here rather than absorbed, because it changes a 13-01 contract (mutators are now total, and safe after disposal).
- **Files modified:** `lib/shell/summon_scope.dart`.
- **Committed in:** `9a0c318`

**3. [Rule 1 - Bug in the first test] The blocked label is not reachable from the icon's render-object ancestry**

- **Found during:** Task 1. `tester.getSemantics(find.byKey(kSummonKeyboardIconKey))` returned the **root** node, so the first form of the discoverability case failed while the label was in fact perfectly discoverable.
- **Issue:** `Tooltip` publishes its message through an `OverlayPortal`, so the semantics node carrying it is **not** in the icon's render-object ancestry — `getSemantics` walks past it to the root and reports nothing. A weaker test (`find.byTooltip` alone) would have passed and proved only that a widget exists.
- **Fix:** the case walks the semantics tree from the root and asserts a node carries the sentence, that its box is the slot's 56x56, that it advertises **no tap action**, and — as the control — that the live trackpad slot beside it **does**. That last assertion is what stops the absence being a harness artefact.
- **Files modified:** `test/shell/summon_bar_focus_gate_test.dart` only. No production change.
- **Committed in:** `99f640f`

---

**Total deviations:** 3 auto-fixed (1 blocking framework constraint, 1 missing teardown guard, 1 bug in a test's first form).
**Impact on plan:** No requirement was weakened and no assertion was dropped. Deviation 1 is the one that generalises: **a route-scoped widget mutating app-scope shell state must apply both edges at end-of-frame.** Phase 14 and Phase 15 will both be tempted to write the inline version, and it fails loudly at push time rather than quietly.

## Verification Results

| Check | Result |
|---|---|
| `flutter test test/shell/summon_bar_focus_gate_test.dart` | **9 cases**, all passed (plan asked for ≥7) |
| `flutter test test/shell/summon_bar_scope_test.dart` | **7 cases**, all passed (plan asked for ≥6) |
| `flutter test test/qr_scan_pairing_test.dart test/pairing_flow_test.dart` | 25 tests, all passed — pairing unaffected |
| `flutter test test/theme_tokens_guard_test.dart test/icons_guard_test.dart` | 2 cases, both passed |
| `flutter test` (full suite) | **991 passed** (975 before this plan + 16) |
| `flutter analyze --no-fatal-infos` | No issues found |
| `! grep -Ev '^\s*//' lib/shell/summon_bar.dart lib/shell/summon_icon_button.dart \| grep -Eiq 'pairingdialog\|devicelistscreen\|qrscanscreen\|screenname\|allowlist'` | succeeds — the gate names no screen |
| `test "$(grep -rc 'SummonBarSuppressor' lib/ \| grep -vc ':0')" -eq 2` | succeeds — its own file and the single mount site |
| `git diff` over `lib/` after all four falsification mutations | empty |

## Success Criteria

- [x] The keyboard icon is visibly disabled, by glyph and not by colour alone, while a local text field holds focus, and enabled otherwise — the tint is asserted **identical** either side of the disable, so a tint-only implementation would fail
- [x] The gate names no screen and stays correct for a future screen that gains a text field — enforced by a source scan, and the suite deliberately never pumps a real screen
- [x] The blocked-state sentence is reachable by both long-press and a screen reader while the icon is disabled
- [x] The bar is absent entirely on the QR scan screen and returns with an unchanged rect afterwards

## Requirements Completed

- **BAR-03** — the phase's one genuine security control: a locally-typed pairing PIN cannot reach the PC, gated on the focused node and not on the screen
- **BAR-04** — the bar is gone on the QR scanner and present everywhere else, with no flicker at either lifecycle boundary

## Threat Mitigations

| Threat ID | Disposition | Status |
|---|---|---|
| T-13-01 (Information Disclosure — the focus gate) | mitigate | **Mitigated.** The gate is a property of the focused node with all four clauses, pinned by 9 cases including the nothing-focused case that fails against the wrong predicate. Both the wrong predicate and the missing identity escape were run red by hand. |
| T-13-16 (Information Disclosure — the disable being invisible where it matters) | mitigate | **Mitigated.** The disable is a glyph swap; the tint is asserted unchanged either side, so a future tint-only "simplification" reds. The sentence's reachability is asserted through the semantics tree, with the live slot's tap action as the control. |
| T-13-02 (Tampering/DoS — a raised surface over the QR scanner) | mitigate | **Mitigated.** Depth-counted route-scoped suppression at the single push site, asserted absent by key. The frame-window case additionally proves the bar is never drawn over a visible pixel of the scanner, at either boundary. |
| T-13-03 (the bar over the power confirm dialog) | accept | **Accepted, and now documented by a test** that names the success criterion requiring it — so a later reader cannot mistake it for an oversight. Stays on plan 13-10's UAT eyeball list. |
| T-13-SC (package-manager installs) | accept | No installs; `pubspec.yaml` unchanged. |

## Threat Flags

None. This plan adds no network endpoint, no auth path, no file access and no schema change. It **removes** a disclosure path rather than creating one.

## Known Stubs

None. The predicate is real and exercised against real `EditableText`s; the suppressor is real and mounted at the one production site.

## Notes for Next Phase

- **Phase 15 has one line to write:** set `controller.hiddenImeNode` when `HiddenTextInput` mounts (and clear it on dispose). The escape and its test already exist. If the keyboard icon ever greys out the instant the keyboard is raised, that assignment is missing — do **not** "fix" it by loosening the predicate.
- **The end-of-frame rule is the reusable finding.** Any Phase 14/15 widget that mutates shell state from a route's lifecycle edge hits the same two framework constraints. Copy `_atEndOfFrame`; do not re-derive it from a red test.
- **A second suppression site is a decision, not an edit.** The `-eq 2` source gate reds on a third file. If a future screen genuinely needs the bar gone, move the gate deliberately and say why — and never for a modal route, which SC4 forbids.
- **Two items for plan 13-10's UAT list:** the slashed glyph reading as "disabled" at a glance on hardware, and the power confirm dialog with the bar over it.

## Self-Check: PASSED

All three created files exist on disk; all three modified files exist. Both commits (`99f640f`, `9a0c318`) are present in git history. Neither commit deletes a tracked file (`git diff --diff-filter=D` over the pair is empty).

---
*Phase: 13-summon-shell-bar*
*Completed: 2026-08-14*
