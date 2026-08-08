---
quick_id: 260808-waa
slug: record-the-phase-12-sc5-sc7-closure-on-h
description: Record the phase 12 SC5/SC7 closure on hardware
created: 2026-08-08T17:44:45.256Z
mode: quick
area: docs
files:
  - .planning/STATE.md
  - .planning/phases/12-in-app-updates/12-18-SUMMARY.md
  - .planning/todos/pending/2026-08-05-pc-self-update-helper-wedges-before-setup-runs.md
---

# Quick 260808-waa: Record the Phase 12 SC5/SC7 Closure

**Documentation only. No source file is touched.** The code fix landed in quick
`260805-axr`; this task records the on-hardware observation that finally proved it,
and closes the artifacts that were left open pending that proof.

## Why this exists

`12-18-SUMMARY.md` carries `## Self-Check: FAILED` and
`requirements-not-met: [D-16, D-17, D-18, SC5, SC7]`. Those were true when written.
On **2026-08-08** the PC self-update was observed working end to end on the owner's
machine, so five requirements flipped and one pending todo discharged its delivery
constraint. Nothing in `.planning/` reflects that yet.

## The observation being recorded

Sequence, from `%APPDATA%\RemoteControl\logs\server.log.2026-08-08` and
`%TEMP%\rc-setup.log`, verbatim:

```
17:41:36.065972Z  update: helper spawned; exiting to let the installer replace this exe
23:11:37.582      Log opened.  Original Setup EXE: %TEMP%\RemoteControl-Setup-v1.6.3.exe
23:11:37.582      /VERYSILENT /NORESTART /SUPPRESSMSGBOXES /LOG=...
23:11:38.086-096  Successfully installed the file.   (x4)
23:11:38.594      Need to restart Windows? No
17:41:39.041889Z  server-windows listening port=17777
```

(The two clocks are the same instant — `server.log` stamps UTC, Inno stamps local
UTC+05:30.) **Three seconds, spawn to back-up.**

Owner-reported, same run: the **browser extension reloaded itself** with no manual
action, and the **phone reconnected on its own**.

Machine state confirmed after the fact: installed exe `1.6.3`, uninstall registry
`1.6.3`, installed `extension\manifest.json` `1.6.3`, server PID 14644 up since
23:11:38, no `rc-update-*.cmd` and no setup exe left in `%TEMP%`, no marker file left
in `%APPDATA%\RemoteControl`.

## Delivery that made it testable

| Step | Result |
|---|---|
| `v1.6.2` published as a pre-release | commit `6dc6e27`, tag `v1.6.2` — deliberately invisible to `/releases/latest` |
| `v1.6.2` installed **by hand** | `/VERYSILENT /NORESTART /SUPPRESSMSGBOXES`, exit 0; digest matched the mirror asset byte-for-byte |
| `v1.6.3` published as a normal release | commit `f0d1aaa`, tag `v1.6.3`, three digest-bearing assets, anonymous `latest` = `v1.6.3` |
| Update PC tapped | the run recorded above |

## Tasks

### Task 1 — amend `12-18-SUMMARY.md`

- **files:** `.planning/phases/12-in-app-updates/12-18-SUMMARY.md`
- **action:** Add a dated `## Addendum 2026-08-08` block recording the successful
  re-run. Update the Success Criteria Status table rows for SC2, SC5 and SC7. Move
  `D-16, D-17, D-18, SC5, SC7` from `requirements-not-met` to `requirements-completed`
  in the frontmatter and add a `key-decisions` entry explaining the amendment.
  Retitle `## Self-Check: FAILED` to record that its Task 4 line is superseded.
- **constraint:** **Do NOT rewrite the original observations.** The 2026-08-05 record
  of the wedge is the evidence that the defect was real. It stays intact and is marked
  superseded, never edited into agreement with the later run.
- **verify:** the original `Task 4 acceptance criteria — FAILED` line still present;
  a dated addendum sits above it; frontmatter `requirements-not-met` is empty.
- **done:** the file states both what failed on 08-05 and what passed on 08-08, in that
  order, without contradiction.

### Task 2 — close the todo

- **files:** `.planning/todos/pending/2026-08-05-pc-self-update-helper-wedges-before-setup-runs.md`
- **action:** Prepend a dated `RESOLVED` block naming the proving run, then
  `git mv` the file to `.planning/todos/done/`.
- **verify:** `.planning/todos/pending/` is empty; the file exists under `done/`.
- **done:** the todo's *Delivery constraint* section is visibly discharged.

### Task 3 — update `STATE.md`

- **files:** `.planning/STATE.md`
- **action:** Update the frontmatter (`status`, `stopped_at`, `last_updated`,
  `last_activity`); replace the `⚠ 100% counts FILES` warning block with the closure;
  rewrite the Wave 8 result in Current Position; resolve the two `260805-axr` entries
  under Blockers/Concerns; update the Pending Todos section to zero; append the
  `260808-waa` row to the Quick Tasks Completed table.
- **constraint:** Keep the CARRIED-FROM notes for waves 2–7 untouched — later plans
  still read them.
- **verify:** no remaining text in STATE.md claims SC5 is unmet.
- **done:** STATE.md says phase 12 met its goal, and says on what evidence.

## Must-haves

- **truths:**
  - The 2026-08-05 wedge record survives verbatim in `12-18-SUMMARY.md`.
  - No text anywhere in `.planning/` still asserts SC5 or SC7 unmet.
  - The root cause remains recorded as *inferential* — the repair is proven, which half
    was load-bearing is not.
- **artifacts:** `260808-waa-PLAN.md`, `260808-waa-SUMMARY.md`, the three edits above.
- **key_links:** `12-18-SUMMARY.md`, `STATE.md`, `todos/done/2026-08-05-pc-self-update-helper-wedges-before-setup-runs.md`

## Out of scope

- Any source change. `server/`, `app/`, `extension/` are not touched.
- Milestone close / archival. Phase 12 meeting its goal is not the same as the v1.0
  milestone being ready to archive; that is `/gsd-audit-milestone`'s call.
- The Chrome file-lock question (RESEARCH OQ-1). Still unexercised — the 1.6.3 install
  scheduled no `restartreplace`. Recorded as still-open, not closed.
