---
phase: 12-in-app-updates
plan: 17
subsystem: updates
tags: [rust, egui, shell, settings-window, ui-contract, copy-contract, security]

# Dependency graph
requires:
  - phase: 12-in-app-updates (12-12)
    provides: the update thread wired into main.rs — UpdateCmd sender, the shared UpdateProgress watch, the shared busy flag
  - phase: 12-in-app-updates (12-11)
    provides: update_thread's UpdateCmd::Check arm, the STAGE_* vocabulary, RUNNING_VERSION anchoring
  - phase: 12-in-app-updates (12-06)
    provides: UpdateError and its closed seven-code vocabulary
provides:
  - "ShellCtx.update_cmd / update_progress / update_busy — the shell's live handles onto the phone path's update thread"
  - "The UPDATES section in the PC settings window: version line, status line, one action"
  - "Rust update_status() — the pure D-10 stage / D-11 code to sentence-and-colour-role map, and its Tone / UpdateStatus types"
  - "The PC-side copy consts, named so the shared vocabulary is greppable and testable"
affects: [12-18]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "A colour ROLE enum rather than a Color32 in a pure mapping function, so the test asserts the contract instead of re-asserting a hex value"
    - "Wire-code lookup through the existing ALL array rather than string-literal match arms, so a second surface cannot drift from SPEC §7"
    - "Option-returning copy map, where None is the swallow — the one D-11 rule a pure function cannot express by returning a sentence"
    - "request_repaint_after on the publisher's own cadence, so an event-driven egui window follows a background thread's progress without polling"

key-files:
  created: []
  modified:
    - server/server-windows/src/main.rs
    - server/server-windows/src/shell/mod.rs
    - server/server-windows/src/shell/settings.rs

key-decisions:
  - "The shell gets the SAME handles the phone-driven path uses, not a second set. Two command channels would be two places an apply could start from and the busy flag could not serialise them; two progress sources would let the settings window and the phone disagree about what is happening. One machine, one truth."
  - "The three handles live on ShellCtx, not on SettingsWindow::new's parameter list. Every other live handle the window reads — clip_sync, pause_tx, revoke_tx, auth — is a ShellCtx field, and the plan's operative clause is 'in the style the existing live handles use'."
  - "update_status returns a colour ROLE (Tone::Muted / Accent / Red), never a Color32. The test then asserts 'this state is the failure role' rather than re-typing a hex literal that would have to agree with style.rs by eye."
  - "Error codes resolve through UpdateError::ALL rather than through `match` arms on string literals. SPEC §7 owns the vocabulary; a literal here would be a second spelling of it, and the weaker of two spellings is the one that drifts."
  - "update_status returns Option<UpdateStatus>, and the window holds the last one. `busy` means 'change nothing' (D-11 rule 7), which a function that must return a sentence cannot express — so None is the swallow, and the held line is what makes it a no-op."
  - "The available line is `{installed} → {latest}` with NO size clause. UpdateProgress carries no asset size — it is not on the wire — and the plan forbids a second feed fetch to obtain one. A missing size beats an invented one, and the PC asset is 4.9 MB downloading onto the machine itself, which is the case D-08's size promise exists least for."
  - "`restarting` renders `Restarting…`, not the phone's `Restarting on your PC…`. The UI-SPEC's PC copy list deliberately does not carry that sentence over, and 'your PC' reads wrong on the window that IS the PC. It is not a failure sentence, so the D-11 shared-failure-vocabulary rule is untouched — the `installer` sentence keeps its 'Your PC' verbatim, because there it names this machine's installed version and it IS a failure."
  - "The UPDATES section sits LAST, after PAIRED DEVICES. It is the machine's own maintenance affordance, not a daily control — the same placement logic that puts the phone's Updates entry inside the About group rather than at the top of Settings."
  - "The section requests a repaint every 250ms while a stage is live — the update thread's own publication cadence. The window is event-driven and would otherwise sit on `Downloading… 0%` for the whole transfer."

patterns-established:
  - "Named copy consts in a Rust UI file (a divergence from this file's inline-literal style) reserved for copy that is a contract shared with another surface — the naming is what makes the shared vocabulary greppable and assertable"
  - "A copy-parity test that asserts the sentences against their literal contract text, so re-wording either surface fails the build rather than shipping two vocabularies"

requirements-completed: [D-05, D-06, D-08, D-11, D-14, D-15, D-26, SC2, SC5]

# Metrics
duration: 1 session
completed: 2026-08-04
---

# Phase 12 Plan 17: The PC Settings UPDATES Section Summary

**The Windows machine can now check for and install its own update from its own settings window, in its own design system, using the same words and the same underlying thread as the phone — so a broken, unpaired or absent phone no longer leaves the PC with no update path.**

## Performance

- **Duration:** ~1 session
- **Tasks:** 2
- **Files modified:** 3 (0 created, 3 modified)
- **Tests added:** 5

## Accomplishments

- **One machine, one truth.** The settings window commands the same `UpdateCmd` channel, reads the same `UpdateProgress` watch and shares the same busy flag the phone-driven path uses. The two surfaces cannot show different states because there is only one state.
- **The fallback is not the procedure it replaces.** The section performs its own feed check through the existing thread rather than opening a browser — "open a browser and download a file" is precisely the hand-download procedure D-01/D-16 exist to delete.
- **The version line is the package's own version.** `env!("CARGO_PKG_VERSION")`, with a test asserting it is three integers. No hardcoded constant anywhere in the file.
- **The whole copy vocabulary is one pure function.** `update_status` maps every D-10 stage and every one of the seven D-11 codes to a sentence and a colour role. It accepts only a stage and a code, so no path, URL, HTTP status, hash or exception text is *representable*, let alone renderable (T-12-06) — a test feeds hostile strings in as codes and asserts none is reflected into the copy.
- **`busy` is swallowed and `downgrade` degrades, exactly as on the phone.** `busy` returns `None` and the line stays as it was; `downgrade` — impossible through this surface, since the button can only send a version the server itself resolved as strictly newer — renders the generic installer sentence and logs the real code. An unrecognised code from a future server does the same rather than guessing.
- **The button cannot name a target.** `Check for updates` sends `UpdateCmd::Check`; `Update now` sends `UpdateCmd::Apply(v)` where `v` came from the server's own `uptodate` terminal. There is no text field, no path picker and no way for anyone at the window to name a file, a URL or a version (T-12-01) — and the thread re-runs the full refusal ladder on it regardless.
- **Two surfaces cannot produce a concurrent apply.** Both actions disable while the shared busy flag is set, so the local surface never generates a `busy` refusal it would then have to explain (T-12-60).
- **The design systems stayed separate.** No `ProgressBar`, no `#4C8DFF`, no `kAccent`, no `tokens.dart` reference; `style.rs` is byte-unchanged, so `style::icon` gained no member. The section is composed from `section_label` / `field_label` / `mono` / `sg` and the shipped `MUTED` / `ACCENT` / `RED` roles alone.
- **The sibling geometry was matched, not altered.** `add_space(7.0)` went from 2 to 3 — the one new Version field — and the diff to `settings.rs` is 537 insertions and **zero deletions**. Not one shipped line moved.

## Task Commits

1. **Task 1: plumb the update handles into the shell** — `22bbb43` (feat)
2. **Task 2: the UPDATES section** — `4b11d3f` (feat)

## Files Created/Modified

- `server/server-windows/src/main.rs` — three clone lines in the step-3e block (before `update_cmd_tx` moves into `WinUpdate` and `update_rx` into `ServerDeps`) and three fields on the `ShellCtx` literal
- `server/server-windows/src/shell/mod.rs` — `ShellCtx::update_cmd` / `update_progress` / `update_busy` with their D-06 rationale
- `server/server-windows/src/shell/settings.rs` (+537) — the copy consts, `Tone`, `UpdateStatus`, `failure_of`, `update_status`, the two `UiState` fields, `render_updates`, the `UPDATES` call in `render`, and five unit tests

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 2 - Missing Critical] `shell/mod.rs` had to change; the plan's `files_modified` named only two files**

- **Found during:** Task 1
- **Issue:** The plan lists `main.rs` and `settings.rs`. But every live handle the settings window reads — `clip_sync`, `pause_tx`, `revoke_tx`, `auth`, `config` — is a `ShellCtx` field, and `ShellCtx` is declared in `shell/mod.rs`. The alternative (extra parameters on `SettingsWindow::new`) would have required editing `shell/mod.rs` anyway, because `open_settings` is the only call site and it has nothing but `ShellCtx` to source the handles from.
- **Fix:** Added the three fields to `ShellCtx`, which is what the plan's own operative clause — "in the style the existing live handles use" — describes. The `main.rs` diff still touches only the clone lines and the settings-window construction call, as its acceptance criterion requires.
- **Files modified:** `server/server-windows/src/shell/mod.rs`
- **Verification:** `cargo build -p server-windows` exits 0; `grep -c 'UpdateCmd' settings.rs` returns 3.
- **Committed in:** `22bbb43`

**2. [Rule 3 - Blocking] The available line cannot carry `· {size}`**

- **Found during:** Task 2
- **Issue:** The plan's copy list includes `{installed} → {latest} · {size}`. `UpdateProgress` has four fields — `stage`, `pct`, `version`, `error` — and no size; the size is not on the wire, and adding it would mean amending SPEC §7, the JSON schema and both codecs first. The only other source is a second feed fetch, which Task 1 explicitly forbids ("populated from the progress watch's terminal stages, not from a second feed fetch").
- **Fix:** The line renders `{installed} → {latest}`. Recorded in `update_status`'s doc comment so it does not read as an omission.
- **Files modified:** `server/server-windows/src/shell/settings.rs`
- **Verification:** `update_status_maps_every_stage` pins the exact rendered string.
- **Committed in:** `4b11d3f`

**3. [Rule 2 - Missing Critical] `restarting` had no PC sentence**

- **Found during:** Task 2
- **Issue:** The UI-SPEC's PC copy list enumerates the sentences that carry over and `restarting` is not among them — but the stage is reachable (the thread publishes it ~750 ms before the process exits), so the mapping must return something.
- **Fix:** `Restarting…`. The phone's `Restarting on your PC…` is written from the phone's vantage point and reads wrong on the window that is that PC. It is not a failure sentence, so D-11's shared-failure-vocabulary rule is untouched — and the `installer` failure keeps its "Your PC" verbatim, because there it names this machine's installed version.
- **Files modified:** `server/server-windows/src/shell/settings.rs`
- **Verification:** asserted by name in `update_status_maps_every_stage`, with the reason in the assertion message.
- **Committed in:** `4b11d3f`

**4. [Rule 3 - Blocking] The status line needed a repaint request**

- **Found during:** Task 2
- **Issue:** The window is event-driven (`ControlFlow::Wait` plus egui's repaint queue). Nothing in it observes the progress watch, so a download would leave the line frozen at `Downloading… 0%` until the user happened to move the mouse over the window.
- **Fix:** `ui.ctx().request_repaint_after(250ms)` while the stage is one of the five live ones — the update thread's own `PROGRESS_MIN_INTERVAL`, so the window asks for exactly as many frames as there are publications. It rides the existing `UserEvent::Repaint` → `ControlFlow::WaitUntil` path; no new timer, no polling, and no repaint at all once the stage is terminal.
- **Files modified:** `server/server-windows/src/shell/settings.rs`
- **Verification:** the matcher lists exactly the five live stages; terminal stages fall through.
- **Committed in:** `4b11d3f`

**5. [Rule 3 - Blocking] A pure map cannot express "change nothing"**

- **Found during:** Task 2
- **Issue:** D-11 rule 7 says `busy` is swallowed — the line is left exactly as it was. A function returning `UpdateStatus` has no way to say that.
- **Fix:** `update_status` returns `Option<UpdateStatus>`; `None` is the swallow, and `UiState::update_status` holds the last rendered line so `None` is genuinely a no-op. An unknown future stage returns `None` too, for the same reason: leave the line alone rather than blanking it.
- **Files modified:** `server/server-windows/src/shell/settings.rs`
- **Verification:** `update_status_maps_every_error_code` asserts `busy` maps to `None` and every other code to a sentence.
- **Committed in:** `4b11d3f`

**6. [Rule 1 - Bug] The import rewrite dropped `use crate::{autostart, config};`**

- **Found during:** Task 2
- **Issue:** Six `E0433 cannot find module` errors — replacing the import block lost a line that was already there.
- **Fix:** Restored it. The final `settings.rs` diff is pure insertion with zero deletions, which is the stronger form of the plan's "the sibling geometry was matched and not altered" criterion.
- **Verification:** `git diff --stat` reports 537 insertions and no deletions; `cargo test -p server-windows` exits 0.
- **Committed in:** `4b11d3f`

---

**Total deviations:** 6 auto-fixed (3 blocking, 2 missing-critical, 1 bug). No architectural change, no new dependency, no scope creep. Deviations 2 and 3 are both cases where the plan's copy list named a sentence the wire cannot supply or the vantage point makes wrong; both are recorded in source so a later reader does not "fix" them back.

## Decisions Made

See `key-decisions` in the frontmatter. The four a later plan should not re-litigate:

- **One set of handles, shared.** Do not give the settings window its own channel, its own watch or its own busy flag. The single-source property is the whole reason the two surfaces agree.
- **`Tone`, not `Color32`, out of the pure function.** The colour role is the contract; the hex belongs to `style.rs` alone.
- **Codes resolve through `UpdateError::ALL`.** Do not add `match "network" =>` arms here — SPEC §7 owns the vocabulary and this file must not spell it a second time.
- **No size on the PC available line, and no second feed fetch to get one.** The wire carries no size; inventing one to satisfy a copy template would be worse than omitting it.

## Issues Encountered

- **`watch::Receiver::borrow()` off the tokio runtime.** The shell thread is a plain `std::thread` running winit, not a tokio worker. `borrow()` is synchronous and needs no runtime — and `shell/mod.rs` already does exactly this with `ctx.conn_count.borrow()` at `StartCause::Init`, so the precedent was in the file.
- **`cargo fmt --check` is unavailable.** The `1.97.0-x86_64-pc-windows-msvc` toolchain has no `rustfmt` component installed, so formatting was matched by hand against the surrounding code rather than verified by tool. Not a project gate — no CI step or plan criterion invokes it.
- **A here-string commit message with embedded double quotes broke PowerShell arg parsing.** Used `git commit -F <file>` instead; noted only so the next executor reaches for `-F` first on a long message.

## Verification Results

| Gate | Result |
|------|--------|
| `cargo build -p server-windows` | **exit 0, zero warnings** |
| `cargo test -p server-windows` | **115 passed** (was 110), 0 failed, 2 ignored |
| `cargo test --workspace` | **305 passed** (was 300), 0 failed, 2 ignored |
| `grep -c '"UPDATES"' settings.rs` | 1 (exactly one) |
| `grep -c 'CARGO_PKG_VERSION' settings.rs` | 2 (>= 1); no hardcoded version literal in production code |
| `grep -c 'UpdateCmd' settings.rs` | 3 (>= 1) |
| `grep -c 'add_space(7.0)' settings.rs` | 3 (was 2, +1 for the new Version field) |
| `grep -ci 'ProgressBar\|4C8DFF\|kAccent\|tokens.dart' settings.rs` | 0 |
| `style::icon` members | 21, unchanged — `style.rs` is byte-identical |
| `git diff --stat settings.rs` | 537 insertions, **0 deletions** — no shipped line moved |
| `main.rs` diff | only the three clone lines and the `ShellCtx` literal |
| Stages covered by a unit test | 7 / 7, plus the empty sentinel and an unknown future stage |
| D-11 codes covered by a unit test | 7 / 7, plus an unrecognised code and a code-less `failed` |

### The five new tests

| Test | What it pins |
|------|--------------|
| `update_status_maps_every_stage` | every D-10 stage → its exact sentence and colour role, including the empty sentinel, a pct-less `downloading`, and both `uptodate` outcomes |
| `update_status_maps_every_error_code` | all seven D-11 codes: five sentences, `downgrade` → the generic installer sentence, `busy` → `None`; plus an unknown code and a code-less `failed` |
| `update_status_cannot_render_a_detail` | a URL, a Windows path, an HTTP status and a 64-char hex digest fed in as codes — none is reflected into user-facing copy (T-12-06) |
| `update_version_line_is_the_package_version` | the version line is `env!("CARGO_PKG_VERSION")` and parses as three integers (D-05, SC2) |
| `update_copy_matches_the_phone_vocabulary` | the shared sentences byte-for-byte, plus U+2026 for the ellipsis and U+2192 for the arrow |

## Known Stubs

None. The section is fully wired to the real update thread.

SC5 (the PC updating itself end to end from this window) is observable only by running a real installer against a real release, which is `12-18`'s UAT scope. Everything below that — the command reaching the thread, the refusal ladder, the published stage sequence — is already covered by `update_thread.rs`'s own suite from 12-11.

## Threat Flags

None beyond the plan's register. Every mitigation it assigns is implemented:

- **T-12-01** — the apply target is the version the server resolved; there is no text field, no path picker and no locator-shaped parameter. `run_apply` re-runs the whole refusal ladder from this trigger as from the phone's.
- **T-12-06** — `update_status` accepts a stage and a code and nothing else; a test proves hostile strings cannot reach the copy.
- **T-12-60** — both actions disable on the shared busy flag, and the executor's compare-and-swap refuses a second apply regardless.
- **T-12-61** — a grep asserts no phone token, no `kAccent`, no `#4C8DFF` and no `tokens.dart` reference; `style.rs` is untouched.
- **T-12-59** — accepted as planned: anyone at this desktop could already run an installer by hand, and this button removes the SmartScreen-prone manual download instead of adding capability.

## User Setup Required

None.

## Next Phase Readiness

**Wave 6 is complete.** Wave 7 is `12-16` (the `ext.reload` version-drift arm), which depends on `12-13` and is unblocked. Wave 8 is `12-18` (the version bumps and the full UAT), which depends on `12-15`, `12-16` and `12-17` — two of its three are now done.

For `12-16` and `12-18`:

- `12-16` and `12-18` are both `autonomous: false`. `12-18` additionally needs a physical Android phone on the same LAN, with the install-unknown-apps grant *declined once* so the D-19 refusal path is observed.
- The PC surface now quotes the seven sentences from `shell/settings.rs`'s `UPDATE_*` consts. If `12-18` re-words anything on the phone, `update_copy_matches_the_phone_vocabulary` fails — which is the intended alarm, not a flake.
- `quietLaunchCheck()` on the phone is still uncalled; wiring the launch path remains `12-18`'s scope.

## Self-Check: PASSED

All three files exist on disk with the described contents, and both task commits (`22bbb43`, `4b11d3f`) are present in `git log`.
