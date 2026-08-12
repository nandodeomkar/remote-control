# Project Retrospective

*A living document updated after each milestone. Lessons feed forward into future planning.*

## Milestone: v1.0 — MVP

**Shipped:** 2026-08-12
**Phases:** 12 | **Plans:** 108 | **Tasks:** 244 | **Commits:** 673 | **Span:** 2026-07-07 → 2026-08-12

### What Was Built

- A phone-as-mouse-and-keyboard remote for Windows: trackpad with the full feel checklist, a four-pad keyboard, media/power/presenter/browser control, app switching, bidirectional clipboard, and browser tab + bookmark control through a Chrome extension relay.
- A Rust tray server (`server-core` OS-agnostic + `server-windows`) behind a versioned, fixture-locked wire protocol that both languages decode identically.
- Self-updating distribution: one `tools/release.ps1` run bumps three versions, builds three artifacts and publishes them with digests to a public mirror; all three components then update themselves.

### What Worked

- **Retiring the make-or-break risk in phase 2, while the code was still small.** The cursor-latency spike measured p50 6ms / p95 10ms and locked the transport. Ten later phases were built on a settled answer instead of an open question.
- **Fixture-locked cross-language contracts.** Both codecs pinned to the same golden files — including a .NET-computed auth proof as an outside anchor — meant no wire-format bug ever reached hardware. This was the single highest-leverage decision of the milestone.
- **Pure IO-free FSMs for the hard logic** (reconnect policy, gesture classification, sticky modifiers, slide-to-confirm). Each was fully unit-testable with no sockets, timers or widgets, and each one held up.
- **On-device UAT as a blocking gate, not a formality.** Every phase that shipped user-facing behaviour ended on real hardware. It caught what suites could not: a half-open TCP connection leaving Shift welded down, and a UAT-8 gesture failure that only appeared under a real finger.

### What Was Inefficient

- **The 100% that wasn't.** For eight weeks the progress counter read 100% while `12-18-SUMMARY.md` carried `## Self-Check: FAILED`. Plan-and-summary counting measures files, not outcomes, and nothing in the workflow noticed the contradiction.
- **Verification coverage drifted late.** Phases 1-5 and 10-11 produced `VERIFICATION.md`; 06, 08, 09 and 12 did not. The habit decayed silently under delivery pressure and only surfaced at the milestone audit.
- **Documentation status vocabulary drifted from what the tools read.** The close gate reported 19 open items; 15 were missing or non-terminal frontmatter fields on work that was long finished. That is an hour spent proving nothing was wrong.
- **One requirement was reported complete for a month while half-unreachable.** CONN-04's IP-change recovery existed but was bound to a screen-scoped provider, so a cold start landing on the dashboard never armed it. Traceability said Complete because the code existed — nobody asked from where it was reachable.

### Patterns Established

- **Own a contract once, in one object, so both surfaces inherit fixes by construction.** `KeyboardInputController` (D-95) replaced two verbatim copies of the stuck-key model; every later fix landed on both keyboard surfaces for free — and will land on a third.
- **Record what a later plan must not rediscover.** Every SUMMARY carries a "carried from" list of traps, wrong turns and deliberate omissions. This repeatedly saved re-deriving the same conclusion.
- **Deliberate omissions get a comment at the point of omission.** After a plan's own grep-count gate tripped on tokens written in its comments — twice — the convention became: say at the omission why the token is absent.
- **Observe RED before GREEN, and say so in the summary.** A regression test that was never seen failing is a test of nothing.

### Key Lessons

1. **A SUMMARY on disk is not an outcome — and a pessimistic artifact is not a failure.** Both directions cost real time this milestone: a FAILED self-check under a 100% counter, and phase 02's stale `gaps_found` that had been superseded by a passing gate the whole time.
2. **The seam you inject around is the code no test executes.** `spawn_helper` was the one function in the update path with no coverage, precisely because `begin_apply_with` took the spawn as an injected closure. That is where the blocking defect lived. When you inject a boundary for testability, write down that the boundary itself is now untested.
3. **"Delivered" must include "reachable".** CONN-04 taught this: ask what has to have happened for this code to run at all, not just whether it exists.
4. **A fix that ships through the path it fixes needs a hand-installed intermediate.** The broken updater could not deliver its own repair; `1.6.2` had to be installed by hand before `1.6.3` could prove the fix. Predicted in advance, and the prediction held exactly.
5. **Bookkeeping decays silently and surfaces all at once, at the gate.** Cheaper to keep terminal statuses accurate as you go than to reconstruct fourteen of them under a close deadline.

### Cost Observations

- Execution ran on wave-based parallel plans, with a review stop after each wave rather than auto-chaining — that pacing caught deviations while they were still cheap.
- Worktree isolation was the default for parallel execution; its recurring costs were stale-HEAD spawns and orphaned worktrees hiding prior progress, not merge conflicts.
- The highest-cost single event of the milestone was the update defect: two published releases, a four-minute wedge on the owner's machine, and a full quick-task cycle to repair — traceable to one untested function behind a test seam.

## Cross-Milestone Trends

Only one milestone so far; trends begin at v1.1.

| Metric | v1.0 |
|--------|------|
| Phases | 12 |
| Plans | 108 |
| Tasks | 244 |
| Commits | 673 |
| Span | 37 days |
| Phases with passing VERIFICATION.md | 7 of 12 |
| Closeout type | override_closeout |
| Deferred at close | 10 |
