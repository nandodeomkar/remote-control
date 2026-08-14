# Phase 13 — deferred items

Out-of-scope discoveries found while executing this phase. Logged, **not fixed**
(the executor's scope boundary: only issues directly caused by the current
task's changes are auto-fixed).

---

## D1 — `BrowserMacroGrid` overflows horizontally by 12px at 360dp width

**Found:** 13-08 Task 1, writing the two browser reach cases at 360x640.

**Symptom:** `A RenderFlex overflowed by 12 pixels on the right.` — one macro
key's `Row` (`lib/browser/browser_screen.dart:377`), laid out in a 158dp cell.

**It is pre-existing and it is not the bar.** Verified by hand against a bare
`MaterialApp(home: BrowserScreen())` at the same 360x640 viewport with **no
shell mounted at all**: identical overflow, identical 12px, exactly one
reported exception. The summon reservation is vertical only and changes no
horizontal constraint, so it cannot have caused this.

**It was very likely never real.** Widget tests render in the test font, where
every glyph is a full em — the same measurement trap `13-UI-SPEC` already flags
for Phase 18's chip row (its 7.3px may not exist with the shipped face). The
existing browser suite never exercised it because
`browser_screen_test.dart::_pumpScreen` drives 800x1600.

**Why not fixed here:** BAR-05 is reserved through one injection with **zero
per-screen edits**, and 13-08's verify asserts `git diff --name-only -- lib/`
is empty for exactly that reason. Editing `browser_screen.dart` to silence this
would destroy the property the plan is testing.

**How 13-08 handles it:** `drainPreExistingHorizontalOverflow` in
`test/shell/summon_shell_test.dart` drains it and **asserts what it swallows** —
the message must say `on the right`. A vertical overflow, which is the failure
the reach cases exist to catch, does not match and fails the test.

**Suggested owner:** whoever next touches the browser macro row, or Phase 18
if it takes the same measurement pass over the chip row. Confirm on hardware
at 360dp before spending anything on it.
