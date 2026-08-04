---
gsd_state_version: 1.0
milestone: v1.0
milestone_name: milestone
status: Executing Phase 12
stopped_at: 12-16-PLAN.md code-complete; its Task 1 human-action checkpoint OUTSTANDING
last_updated: "2026-08-04T15:20:00.000Z"
last_activity: 2026-08-04 -- 12-16 tasks 2+3 done (the ext.reload nudge, its guard, the installer hardening); TASK 1 IS A BLOCKING HUMAN OBSERVATION AND IS NOT DONE -- SC7 is not claimed
progress:
  total_phases: 12
  completed_phases: 11
  total_plans: 108
  completed_plans: 106
  percent: 98
---

# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-07-11)

**Core value:** Phone controls the laptop over WiFi with zero friction: instant cursor response, full keyboard, and the control-center extras — all free.
**Current focus:** Phase 12 — in-app-updates

## Current Position

Phase: 12 (in-app-updates) — EXECUTING
Plan: 16 of 18 (17 SUMMARY files on disk; the plain counter above is a
sequence number, not the completed count)

**CHECKPOINT 2 IS OPEN — 12-16 Task 1, a blocking human observation.** The
owner must run a real setup exe over a live install with Chrome holding the
loaded unpacked extension, and report three facts: (A) the exit code and
whether `%TEMP%\t.log` contains `ErrorReplacingExistingFile`, (B) whether the
server exe was actually replaced, (C) whether the extension's `ext.hello`
reports the NEW version afterwards. The full procedure is in
`12-16-SUMMARY.md`. **SC7 IS NOT CLAIMED** until fact C is reported. No code
is waiting on it — both branches of the installer decision produce the same
flags — only the SC7 claim and one comment's wording.

Next: WAVE 8 — `12-18` (the version bumps and the full UAT). It is
`autonomous: false` and needs a physical Android phone on the LAN with the
install-unknown-apps grant DECLINED once. 12-16's Task 1 folds naturally into
that same session: same machine, same installer run, same browser.

  Waves: W1 `12-01,12-02` (release.ps1 + protoVersion 1.8 contract) — DONE · W2
  `12-04,12-05,12-06,12-07,12-08` — DONE 2026-08-01 · W3 `12-03,12-09` — DONE
  2026-08-04 · W4 `12-10,12-11` — DONE 2026-08-04 · W5 `12-12,12-14` — DONE
  2026-08-04 · W6 `12-13,12-15,12-17` — DONE 2026-08-04 · W7 `12-16` CODE-DONE
  / Task 1 checkpoint OPEN · W8 `12-18` PENDING.

  WAVE 7 (12-16) RESULT — **THE EXTENSION RELOADS ITSELF, EXACTLY ONCE.**
  `ExtCmd::Reload` + `reload_frame()` + the pure `should_nudge()` land in
  `ext.rs`; `run_ext` gained a `server_version` parameter (from
  `server-windows`, never server-core's own library version) and a
  never-reset `reload_attempted_for` guard. `background.js` gained
  `case "ext.reload": chrome.runtime.reload()`, pinned by a new
  `extension_guard.rs` test whose mutation check was performed (arm removed ⇒
  red, restored ⇒ green). `RemoteControl.iss`'s extension `[Files]` entry now
  schedules a Chrome-locked file for next-boot replacement instead of raising
  an Abort that would take the whole install down under `/SUPPRESSMSGBOXES`.
  7 new tests; ext_relay 25 passed (was 19), workspace 312 passed / 0 failed /
  2 ignored. Commits `1f147e1`, `23027e6`.

  CARRIED FROM 12-16 — things a later plan must not rediscover:

  - **NEVER reset the reload guard.** Not on session end, not in
    `reset_relay_watches`, not on a newest-wins replacement. The reload
    CAUSES the reconnect that produces the second hello, so anything that
    clears the guard reopens the loop it exists to close (T-12-56).

  - **The guard is keyed on the SERVER's version**, not the extension's — the
    question is "have I already asked for this target".

  - **`ext_relay.rs`'s `HARNESS_SERVER_VERSION` is `"1.0.0"`**, chosen to
    match the `extVersion` the pre-1.8 scenarios already send so they stay in
    the no-nudge case. Drift tests use `spawn_relay_with_version`.

  - **Three comments in this change deliberately avoid spelling tokens the
    plan greps for a fixed count of** (`CARGO_PKG_VERSION` in ext.rs must be
    0; `restartreplace` in the .iss must be 1; `deleteafterinstall` must be
    0). Each says so at the point of omission. This is the SECOND time this
    class of self-tripping gate has bitten — assume it will again.

  - **`server-core/src/executors/mod.rs` was in 12-16's `files_modified` and
    needed no change.** `ExtInfo` already landed there in 12-12.

  WAVE 6 (12-17) RESULT — **THE PC CAN UPDATE ITSELF FROM ITS OWN
  WINDOW.** `ShellCtx` gained `update_cmd` / `update_progress` /
  `update_busy` — the SAME `UpdateCmd` sender, `UpdateProgress` watch and busy
  flag the phone-driven path uses, cloned in `main.rs` before they move into
  `WinUpdate` and `ServerDeps`. `settings.rs` gained an `UPDATES` section
  composed exactly like its `GENERAL` / `PAIRED DEVICES` siblings: the
  `env!("CARGO_PKG_VERSION")` version line, a status line, and one action that
  is `Check for updates` until the server resolves something newer and then
  `Update now`. `update_status()` is the pure D-10-stage / D-11-code map,
  returning a sentence plus a colour ROLE. 5 new tests; server-windows 115
  passed (was 110), workspace 305 passed / 0 failed / 2 ignored, `cargo build`
  clean with zero warnings. The `settings.rs` diff is 537 insertions and ZERO
  deletions — no shipped line moved. Commits `22bbb43`, `4b11d3f`.

  CARRIED FROM 12-17 — things a later plan must not rediscover:

  - **The PC surface quotes the seven sentences from `shell/settings.rs`'s
    `UPDATE_*` consts.** `update_copy_matches_the_phone_vocabulary` asserts
    them byte-for-byte. Re-wording either surface fails that test on
    purpose — it is the alarm, not a flake.

  - **`UpdateProgress` carries NO asset size**, so the PC available line is
    `{installed} → {latest}` with no `· {size}` clause. Adding one means
    amending SPEC §7, the schema and both codecs first. Do not "restore" it
    with a second feed fetch.

  - **`restarting` renders `Restarting…` on the PC**, not the phone's
    `Restarting on your PC…` — the window IS the PC. The `installer` failure
    keeps its "Your PC" verbatim, because there it names this machine's
    installed version and it IS a failure sentence.

  - **`cargo fmt` is unavailable on this toolchain** (`1.97.0-x86_64-pc-
    windows-msvc` has no rustfmt component). Match formatting by hand; no CI
    step or plan criterion invokes it.

  - **A long `git commit -m @'...'@` here-string breaks PowerShell arg
    parsing when the message contains double quotes.** Use `git commit -F
    <file>`.

  WAVE 6 (12-15) RESULT — **THE UPDATES SCREEN RENDERS THE WHOLE MATRIX.**
  `lib/update/updates_screen.dart` carries the copy contract as four pure
  functions plus `UpdatesScreen`, `UpdateRow`, `CheckFooter`,
  `InstallPermissionSheet` and `UpdateBadgeDot`; `settings_screen.dart` gained
  `UpdatesNavRow` as the FIRST child of the existing About group with the
  shipped `Version` row unmoved, and `hub_screen.dart` gained a `Positioned`
  dot overlay on the existing gear (its size, colour and icon untouched, so the
  app bar cannot reflow). 49 new screen tests + 6 Settings tests: all 15
  `UpdateRowKind` values and all 17 matrix rows asserted for exact subtitle and
  exact trailing slot, three rows always, row height identical across
  available/downloading/failed, exactly one `Retry` and it lives in the footer,
  no `kError`/`SnackBar`/`Dialog` in any state, the row body inert, and the D-19
  sheet on all three exits. `flutter test` 832 passed (was 777), `flutter
  analyze` clean. Commits `f6c4bdc`, `eef00dd`, `f2bea22`, `f1f70a6`.

  CARRIED FROM 12-15 — things a later plan must not rediscover:

  - **`pumpAndSettle` cannot be used on any screen carrying
    `ConnectionHeaderChip`.** Its 500ms `Timer.periodic` calls `setState`, so a
    frame is always scheduled and settling never terminates. Use explicit
    `pump(Duration)` and unmount at the end of each test so the ticker is
    cancelled before the pending-timer check.

  - **The Extension row's trailing slot is empty in EVERY state, spinner
    included.** The UI-SPEC matrix lists `checking` as "applies to: all" with a
    busy spinner, but its trailing-slot table says Empty is used "always on the
    Extension row". The second rule governs and `UpdateRow.neverActs`
    implements it. Do not "fix" the missing spinner.

  - **The seven fixed failure sentences live in
    `lib/update/updates_screen.dart` as `kFail*` / `kSubtitle*` consts.**
    `12-17`'s PC settings section must quote these, not re-write them (D-11).

  - **The row body has NO recognizer by design** (T-12-51). The trailing
    `TextButton`'s own internal `InkWell` is the row's only one — a test that
    asserts "no InkWell in the row" is wrong; scope it to the title/subtitle.

  - **`quietLaunchCheck()` is still uncalled.** The screen calls
    `ensureChecked()` on mount, which is a different trigger. Wiring the launch
    path is `12-18`'s scope.

  WAVE 6 (12-13) RESULT — **THE UPDATE FAMILY IS ON THE WIRE AND
  protoVersion IS 1.8.** `router.rs`'s 12-02 placeholder is gone: `update.check`
  calls `exec.update.info()` once and replies exactly one `update.status`,
  `update.apply` passes `&p.target` and nothing else and replies nothing, and
  both joined `is_executor_bound`. `session.rs` gained the authed-gated
  `update.changed()` push arm with the empty-stage sentinel filtered.
  `SERVER_PROTO_VERSION`, `SPEC.md` line 3 + its §2 sentence, and BOTH pins in
  `protocol/fixtures/beacon/01-valid.json` moved to `1.8` in one commit. Rust
  workspace 300 passed / 0 failed / 2 ignored (was 293), `cargo build
  --workspace` exit 0, zero warnings. Commits `a4deabd`, `73ce5f1`, `6cb9599`.

  CARRIED FROM 12-13 — things a later plan must not rediscover:

  - **`SERVER_PROTO_VERSION` is `"1.8"` now.** Any new fixture or test
    asserting "the current server version" uses 1.8. The handshake still
    compares only the MAJOR component, so `integration.rs`'s
    `hello_challenge` deliberately still pins `"1.0"` — that is the SPEC §2
    minor-mismatch test, not a stale value.

  - **`protocol/schema/mouse-binary.md`'s title still says `protoVersion
    1.7`** and that is CORRECT — it names the version the `0x03` zoom opcode
    was introduced in, not the current one. Do not "fix" it.

  - **The plan's acceptance criteria named `codec_fixtures_beacon`, which
    does not exist.** `tests/fixtures.rs` has no beacon family. The real
    gates are the unit test `encode_beacon_matches_valid_fixture_wire`
    (`src/transport/beacon.rs:136`) and the Dart
    `app/remote_control/test/beacon_test.dart`. Both were run green.

  - **`is_executor_bound`'s doc comment is now the authoritative statement of
    the SPEC §11 read exemption AND its one counter-example.** `update.check`
    is a read that is deliberately NOT exempt (D-13). Do not move it into the
    exemption list on the grounds that it is a read.

  - **`Harness.update_exec: Arc<MockUpdate>` exists** in `integration.rs`.
    Any later socket test that needs to seed `info()` or read `applies()`
    uses it — do not construct a second `MockUpdate` and override
    `Executors` again.

  - **`update/mod.rs`'s `#![allow(dead_code)]` is STILL there.** 12-13 added
    no caller for `UpdateCmd::Check`, `marker::write_pending`,
    `download::download_to` or `feed::APK_ASSET_PREFIX`. Removal point is
    still 12-17; re-probe rather than assume.

  - Tooling note: a `cat >> file <<'EOF'` heredoc append of a large Rust test
    block fails in this shell with `unexpected EOF while looking for matching
    '`. Write the block to the scratchpad with the Write tool and `cat >>` it.

  WAVE 5 (12-12) RESULT — **THE UPDATE PATH IS WIRED.** `Executors.update` and
  `ServerDeps.update` exist and every harness constructs them; `run_ext` gained
  a THIRD relay watch that captures `ext.hello`'s `extVersion` (D-09/D-18); and
  `main.rs` spawns the update thread as step 3e beside 3a-3c. Rust workspace
  293 passed / 0 failed / 2 ignored (was 290), `cargo build -p server-windows`
  exit 0, zero warnings. Commits `36d7670`, `af5c9e6`, `f742915`.

  CARRIED FROM 12-12 — things a later plan must not rediscover:

  - **`router.rs`'s `UpdateCheck`/`UpdateApply => Vec::new()` placeholder is
    STILL there.** 12-12 deliberately added no router arm and no session arm;
    both are 12-13's. `Executors.update` now exists, so 12-13 is unblocked.
    Both variants must also join `is_executor_bound`'s `matches!` list, and
    the doc comment at `router.rs:344` must be AMENDED (D-13 makes
    `update.check` executor-bound, unlike every other `*.list` read).

  - **The session push arm must SKIP the empty-stage sentinel.**
    `UpdateProgress::default()` carries an empty `stage`, which the D-10
    vocabulary cannot express and which is never legal on the wire.

  - **`ExtInfo` is deliberately NOT a `ServerDeps` field** — it drives no
    session push arm. Its only consumer is `WinUpdate`, which takes its own
    `watch::Receiver` clone in `main.rs`. Do not "fix" this by adding it.

  - **`listener.rs` binds `update: _update`** by name rather than adding a
    `..` rest pattern. That exhaustive destructure is load-bearing: it is what
    turns a `ServerDeps` change into a compile error at the one place 12-13
    must edit. 12-13 threads it into `run_session` exactly as `bookmarks` is.

  - **`integration.rs`'s `Harness._update_tx` must stay a STRUCT FIELD.** A
    local would drop at `start_server`'s exit and silently disable the branch
    under test (the `bm_tx` precedent). 12-13 just drops the `_` prefix.

  - **`update/mod.rs`'s `#![allow(dead_code)]` was NOT removed in 12-12**,
    despite 12-11's note saying it would be. Probed: four items still have no
    caller — `UpdateCmd::Check` (12-17's), `marker::write_pending`,
    `download::download_to`, `feed::APK_ASSET_PREFIX`. Removal point moved to
    **12-17**; re-probe rather than assume.

  - **`grep -c 'ExtCmd::Reload'` is still 0** — the reload command, the D-18
    version comparison and the once-per-target-version guard are all 12-16's,
    behind its Chrome file-locking observation checkpoint. The `extVersion`
    input it needs is now live in the watch.

  - Tooling note: an in-place Python rewrite of a source file converts the
    whole file to CRLF on this repo (Python text-mode default). Use `sed -i`
    or `newline=''` for source mutation experiments, or `diff` against a `cp`
    backup will report every line changed.

  WAVE 3 RESULT — **v1.5.0 IS PUBLISHED AND D-21 IS SATISFIED.** The mirror
  `nandodeomkar/remote-control-releases` returns 200 anonymously with
  `tag_name` `v1.5.0`, `draft` False, `prerelease` False, exactly three assets
  (`RemoteControl-v1.5.0.apk`, `RemoteControl-Setup-v1.5.0.exe`,
  `RemoteControl-Extension-v1.5.0.zip`), each `state: uploaded` and each
  carrying a `sha256:` digest equal to what the build machine printed. Every
  client-side plan from here on has a real feed to check against. Built from
  `2cd05f5`; the script's bump commit is `b6d405d`; the three version files now
  agree at `1.5.0` / `1.5.0+9` / `1.5.0`.

  CARRIED FROM WAVE 3 — things 12-18 must not rediscover:

  - **The mirror was created BARE** (a `default_branch` but zero branches), so
    `gh release create` failed with `HTTP 422 Repository is empty` AFTER the
    bump was committed, the tag was pushed and all three artifacts were built.
    Fixed by seeding `main` with a README (`53f310a`). That failure mode is
    permanently gone for this mirror, but **`tools/release.ps1` has no
    empty-mirror preflight** — its probe only checks `/repos/<mirror>` is 200,
    which a bare repo satisfies. Possible follow-up: a sixth preflight on
    `size`/`default_branch`.

  - **`release.ps1` is NOT idempotent after a publish-stage failure.** Once the
    tag is pushed a re-run refuses at the tag check. The script prints the exact
    `gh release create` line to finish by hand — use it. Do NOT delete the tag
    and re-run (that rebuilds three artifacts for nothing).

  - **v1.5.0 carries 12-09's `update/marker.rs` and `apply.rs`** because 12-09
    landed first in the same wave. They compile in but are wired to nothing, so
    they are inert. Accepted deviation from the plan objective, recorded in
    12-03-SUMMARY.md.

  - `v1.5.0` is the floor for every later version comparison. 12-18's `1.6.0`
    and `1.6.1` must both be strictly greater or the script's argument refusal
    throws — even under `-DryRun`.

  WAVE 2 RESULT (merged to master, post-merge gates green): Rust workspace 246
  passed / 0 failed / 2 ignored (was 207); `remote_protocol` 22/22;
  `remote_control` 679/679; `cargo build --workspace` and `flutter build apk
  --debug` both exit 0. Both language halves of the `update.*` wire contract now
  exist and are pinned to the SAME nine shared fixtures, and both version
  comparators are pinned to the same 15-case truth table
  (`protocol/fixtures/update/10-version-compare.json`).

  CARRIED FROM WAVE 2 — things a later plan must not rediscover:

  - `router.rs` holds a DOCUMENTED PLACEHOLDER: `UpdateCheck`/`UpdateApply` =>
    `Vec::new()`. It is deliberately NOT `err{unknownType}` — a false
    `unknownType` is what the phone caches as "server too old to update itself"
    per SPEC §10. 12-12 must replace this when `Executors.update` exists.
    `UpdateStatus`/`UpdateProgress` joined the permanent S→C-only ignore chain
    and are FINAL (12-13 asks for exactly that).

  - sha2 0.11 has NO `std` feature, so `Sha256` is NOT an `io::copy` sink — the
    RESEARCH.md example does not compile. `download.rs` uses a 64 KiB chunked
    read loop instead. Do not "simplify" it back into a build error.

  - `is_valid_target` (server-windows `update/download.rs`) is public precisely
    so 12-09 does not invent a second version regex. Reuse it.

  - 12-08's outcome seam is a reverse `MethodCall` on the SAME channel, not an
    `EventChannel`. 12-10/12-14/12-15 consume `ApkInstaller().outcomes` as a
    `Stream<InstallEvent>`.

  - Asset sizes are deliberately NOT cached by `update_cache.dart`. A plan
    needing `{size}` offline must add a third `update.` key, not assume one.

  - `LastUpdate.toPayload()` (Dart) is inconsistent with `toJson()` on the three
    older nested value classes in the same file. Plan-specified; rename
    deliberately if ever, not incidentally.

  - Dart `specialCaseFixtures` is keyed by family; the Rust
    `SPECIAL_CASE_FIXTURES` is keyed by `(family, filename)` and is the stricter
    of the two. Align the Dart side if a `text/10-*.json` ever appears.

  THREE BLOCKING HUMAN CHECKPOINTS, all `autonomous: false`:

  1. **12-03 T1 (wave 3)** — the owner must create the PUBLIC mirror repo
     `nandodeomkar/remote-control-releases`. It 404s today. The agent is
     forbidden from proceeding past this task; nothing downstream has a real
     release to check against until it exists.

  2. **12-16 T1 (wave 7)** — observe on the real machine whether Chrome blocks
     Inno's `{app}\extension` overwrite and whether `chrome.runtime.reload()`
     picks up a new manifest version. This observation is settled BEFORE 12-16
     T3 chooses the `.iss` change, and SC7 may not be claimed until it is made.

  3. **12-18 T2/T3/T4 (wave 8)** — on-hardware UAT. 12-18 exists because the
     phase is otherwise undemonstrable: it publishes `v1.6.0` from the finished
     tree AND `v1.6.1` as the strictly-newer tap target, hand-installs both
     clients onto 1.6.0 (the accepted one-time manual-install cost), then runs
     the APK self-update (incl. revoked-grant and declined-dialog paths) and the
     PC self-update with the browser open. Acceptance criteria demand verbatim
     recorded observations and explicitly forbid inference.

  Plan-checker PASSED on iteration 2 (iteration 1 found 3 blockers, all fixed in
  `032de24`). The material catch was that the original 17-plan set published its
  only release BEFORE the feature existed, so `latest == installed` forever and
  SC4/SC5/SC7 could never be exercised — that is what 12-18 fixes.

  Note on a pre-release: an `X.Y.Z-rcN` tag can NEVER be the update target.
  `releases/latest` excludes pre-releases and the client parser rejects the
  suffix as unknown (D-20/D-26), so 12-18 uses a real `v1.6.1`, not an rc.

  ONE ACCEPTED GAP (checker warning, non-blocking): D-24's helper-side branch —
  on a non-zero installer exit the helper relaunches the still-installed OLD exe
  and leaves the marker at `ok:false` — is proven only by 12-09's golden-string
  test on the script TEXT, plus a hand-written marker in 12-18 T4 step 6 that
  exercises the phone-facing half. The helper's own relaunch-old-exe behavior is
  never run. Cheap remedy if wanted: point the helper at a stub installer that
  exits 1.

Phase 11 (browser-bookmarks-view-open-star-current-tab) — COMPLETE and VERIFIED
2026-07-31, 13/13 plans. History below.

  11-11 is DONE: every tab row whose bookmark state is KNOWN now carries a 48x48
  trailing star — Symbols.star_rounded with the FILL axis as the whole state
  signal (fill 1 + kAccent live, fill 0 + kMuted, never the destructive red),
  right padding dropping 12→4 only when a slot renders. bookmarked == null
  (UNKNOWN) renders NO slot and NO semantics node, so the row and its a11y tree
  stay byte-identical to pre-phase. _onStarTab is asymmetric by design: adding
  sends bm.star + haptic on the tap instant; removing opens confirmDestructive
  FIRST and only flips + sends on the Remove press (cancel/barrier send nothing).
  RESEARCH Pitfall 8 / A6 is now settled by OBSERVATION — a star tap records
  exactly one BmStarMsg and zero TabsActivateMsg. Carry-forward for 11-12: an
  icon-only button whose onTap can be null needs Semantics(container: true,
  enabled: ...) or the disabled state has NO a11y node at all (found by test,
  fixed in b513149 — the shipped bookmarks back button is unaffected only
  because its onTap is never null). Also logged as deferred item 2: a
  press-and-HOLD >100ms on the star additionally fires the row's onTapDown
  (Flutter calls handleTapDown on deadline expiry, not only on winning the
  arena) — benign tab switch, out of scope because the row's tap-down activate
  is locked. 7 new tests; flutter suite 601 green, analyze clean, cargo 202
  green, dart protocol 13 green.
  11-10 is DONE: the Browser screen is now a fixed BrowserSegmentBar header
  (hand-rolled, no enabled parameter — navigation is never gated), ONE swapped
  Expanded scroll region, and a PINNED macro-grid footer with a 1px kHairline
  top edge, so D-02's identical rect holds by construction (tester.getRect
  equality proven across a segment switch AND a 21-row folder drill-in).
  browser_segment.dart persists the choice under a NEW browser.segment prefs key
  (corrupt/unknown/throwing reads degrade to tabs); the D-03 prime fires from
  build off the segment ABOUT TO RENDER, guarded by _bmPrimed — so a segment
  restored from prefs primes on the same path as a tap, and screen open still
  records zero BmListMsg. PopScope walks the folder stack before leaving the
  route. _SectionHeader deleted; kBrowserActions + the whole tab section
  byte-untouched. 9 new screen tests; flutter suite 594 green, analyze clean.
  Carry-forward for 11-11: _TabRow is untouched, so the star insert lands
  against the shipped chrome (the 12px→4px right-padding drop is 11-11's edit);
  use state.bookmarkedFor(tab), NOT tab.bookmarked; import the unstar copy from
  bookmark_confirm.dart; and any new screen-level test must pump through
  _pumpScreen, which owns the browserSegmentStoreProvider override (a raw
  ProviderScope throws on the shared_preferences platform).
  11-09 is DONE: InstallHintCard is now a
  shared public widget both segments render (no fork), confirmDestructive + ten
  named copy consts serve all three destructive confirms, and BookmarksSection
  ships the full region — folder bar (live while gated), folder/link rows on the
  _TabRow chrome, honest truncation copy, and the D-14 affordance gate
  (onLongPress null on a non-empty folder, a locked node and every root) behind
  the D-13 confirm.
  11-04 is DONE: ServerDeps.bookmarks is threaded from
  run_ext through the accept loop into every session, the bm.changed push arm is
  authed-gated (guard-removal mutation proven RED) with no after-auth snapshot, and
  bm_changed_frame always emits truncated and never logs. Server-side bookmarks relay
  is complete; cargo 202 green, build warning-free.
  Waves 1-3 complete: 11-01, 11-02, 11-03, 11-05, 11-06, 11-07, 11-08.
  Phase 10 VERIFIED 2026-07-17 (10-VERIFICATION.md, passed, 12/12 must-haves).
  Phase 10 shipped: four full-screen swipeable keyboard pads (Type/Arrows/Numpad/Fn)
  with persistent modifier chips + tab bar, keyboard.pad persistence, sacred FSM
  lifted to screen owner (donor keyboard_panel.dart byte-untouched), Shortcuts hub
  tile (25 chords, position 3), keymap vocabulary +18 codes both sides, no protocol
  bump. Suites: 539 flutter green, 38 cargo green, analyzer clean. Distributed as
  GitHub prerelease v1.3.0-rc1 (fresh APK + server exe), field-approved by owner.
  09-07 confirmed the Settings screen against 09-UI-SPEC with zero source delta
  and strengthened settings_screen_test.dart (meta copy, scroll-segment accent,
  accent-chip fill/text). Phase 08 closed with the
  on-device UAT gate PASS (Xiaomi 25080RABDI, fresh release APK): all six
  human-checks — latency parity vs full Trackpad screen, dual position
  persistence across restart, Power-screen slide-to-confirm unobstructed,
  WiFi-drop muted state + drag reset + UIPI banner, CR-01 drag flush on
  collapse/leave, Presenter keepAwake hold. Quick-bar deleted outright
  (283 lines); grep gate 0 refs, analyzer clean, full suite 399 green.
  Phase 05 CLOSED 2026-07-11: 7/7 plans, verification 5/5 code layer, UAT 6/6 on-device (media, absolute volume+PC follow, lock/sleep-suspend, restart/shutdown two-gesture, PowerPoint presenter, browser macros incl. fixed zoom-in), security threats_open 0 (19/19). Google Slides web-start = documented known limitation (out of SC4 scope).
  Phase 03 E2E on Xiaomi 25080RABDI + Windows 11: all five success criteria passed
  (discovery ≤4s, PIN pairing + error copy, silent reconnect, WiFi-drop recovery,
  manual IP, live latency header with no hot-path hitching). See 03-VERIFICATION.md.
  Carried Phase-4 item: Windows "Enhance pointer precision" suppresses slow relative
  deltas — workaround is disabling it; absolute-injection fix (enigo Coordinate::Abs)
  is a pending todo (Phase 4 candidate).
  See: 03-VERIFICATION.md, 03-07-SUMMARY.md
Last activity: 2026-08-04 -- Phase 12 execution started
  (B1-B6), so Failure B is closed and phase 11's blocking item is resolved. All 13
  plans now have SUMMARY files. B2 proved the originally-unreachable gesture: a
  long-press on an EMPTY folder surfaced `Delete this folder?` WITHOUT navigating
  into it, and Delete removed it. B3 proved a link's delete no longer force-opens
  the bookmark. Both deletions were cross-checked against the profile's Bookmarks
  file (0 UAT8 remnants anywhere), not just the phone's rendering. B1 behaved as
  the amended checklist predicted: no dialog, drill-in ON RELEASE, which is
  correct. B4 haptic judged NOT laggy, so the pre-authorised
  hapticTick()-into-_flash() remedy is NOT needed. B6 confirmed the tab-row scope
  fence held. Fixture note: the setup snippet ran TWICE and produced duplicate
  same-titled rows; caught by verifying the profile before B1, which would
  otherwise have made B2 unreadable. NEW deferred item 4: the 100ms press flash is
  imperceptible on LINK rows -- verified NOT caused by 11-13 (the flash fires from
  onTapDown before and after, and on a quick tap both callbacks land in the same
  frame either way), pre-existing and surfaced only because B4 asked the owner to
  look closely at press feedback. The FOLDER flash became newly visible, an
  improvement. NEXT: phase 11 has no incomplete plans -- run phase verification
  (gsd-verifier -> 11-VERIFICATION.md) before closing the phase. Deferred items 2
  and 3 remain OUT of scope by owner decision.
  PREVIOUS -- 11-12 CLOSED and 11-13 tasks 1-3 LANDED.
  11-12 task 3 wrote extension/README.md from the observed A1 outcome (`333c820`),
  SUMMARY `715280c`. Plan 11-13 then fixed Failure B:
  `a5cd678` splits `_BmRowState._fire()` into `_flash()` (onTapDown, visual only)
  and `_activate()` (onTap, the side effect), so a long press now resolves with
  nothing having run; kBmDeleteHint gains the folder case. `adb8413` adds 7
  regression tests at TWO layers -- the section layer was structurally incapable
  of reproducing the defect because `onEnterFolder` is a recorder there, so a
  drill-in swaps nothing and the row survives; only the real BookmarksNotifier at
  the screen layer replaces the list. RED-PROOF OBSERVED: with the wiring reverted
  to pre-fix, EXACTLY 4 of the 7 new tests fail (both long-press-empty-folder and
  both long-press-link, at both layers); the other 3 pass either way by design and
  pin semantics, not the defect. Source restored byte-identical after. `7723602`
  amends 11-UI-SPEC.md, which was the ROOT CAUSE -- it specified tap-down drill-in
  AND long-press delete on the same folder row, and 11-09 implemented that
  faithfully. Now carries the rule "a row whose tap action REPLACES or REMOVES the
  row must fire on onTap, never on onTapDown", plus the plan-checker's corollary:
  a NON-deletable row has no LongPressGestureRecognizer at all, so its tap
  recognizer is unopposed and fires on release however long the hold -- holding a
  non-empty folder DOES drill in, and that is correct (the D-14 gate withholds the
  DELETE, never the navigation). Do NOT "fix" it with a dummy onLongPress,
  onTapCancel, or hold timer. Gates: flutter 608 green (was 601, +7), analyze
  clean; no Rust/protocol/extension file touched so cargo 202 and dart 13 cannot
  have regressed. NEXT: 11-13 task 4 is a BLOCKING human checkpoint -- the owner
  must re-run UAT-8 on device (checks B1-B6) and record it in 11-UAT.md before the
  phase can close. Note deferred items 2 and 3 remain OUT of scope by owner
  decision, and the browser profile is still dirty from the first UAT run
  (`Search by name` id 587, empty `UAT8 test folder` id 588).
  PREVIOUS -- 11-12 task 2 (on-device UAT) RUN AND RECORDED. All eleven
  rows carry an observation: 10 PASS, 1 FAIL. Full detail in 11-UAT.md.
  **PHASE IS NOT CLEAR TO CLOSE** -- UAT-8 is a real functional gap (Failure B):
  `_BmRow` (bookmarks_section.dart:315-319) puts onTapDown activate and onLongPress
  on the SAME InkWell, and Flutter fires handleTapDown at the ~100ms press deadline
  while long-press waits ~500ms. On a FOLDER the tap-down navigation swaps the list
  before long-press can resolve, so D-14's empty-folder delete is unreachable by any
  gesture (proven with count==0, where onLongPress IS wired). On a LINK the delete
  does work but the bookmark is force-opened first. Tab rows and the link case are
  unaffected because their tap-down action does not destroy the row -- so the defect
  is scoped to rows whose tap-down replaces the row. Same root cause as deferred
  item 2 but a materially worse consequence; must NOT be folded into it. Widget
  tests missed it because they invoke onLongPress directly and never model the
  arena race -- a fix should add a real timed-press test.
  A1 IS ANSWERED and task 3 (extension README) is now unblocked: on **Comet
  150.0.7871.115** a permission-widening reload of an UNPACKED extension is granted
  **silently** -- no prompt, no disable, granted_permissions gained `bookmarks`
  with disable_reasons []. Two caveats task 3 must honour: this is Comet, not
  Chrome, and it is the unpacked/reload-arrow path only, NOT Web Store update
  behaviour. Method note: the sheet's own four-step procedure was INSUFFICIENT --
  a downgrade+reload clears active_permissions but NOT granted_permissions, so the
  pre-state needs a full Remove + Load-unpacked or the measurement is a false pass.
  Other findings: A3 measured 500 nodes / 37,845 B / getTree 4.57ms, and
  **truncation is LIVE on the owner's real collection** (538 API-visible nodes vs
  the 500-node cap, ~38 dropped every snapshot) -- MAX_BM_NODES, not
  MAX_FRAME_BYTES, is the binding constraint (bytes would not bite until ~758
  nodes). D-10 got a genuine field win: this profile numbers its roots
  bookmark_bar=1, other=371, synced=372, and the folderType lookup still filed the
  star correctly where a hardcoded id would have been at risk. Comet's getTree()
  never returns the synced root at all, which is why Mobile bookmarks is absent
  from the phone (correct, not a D-08 violation). New deferred item 3: truncation
  copy is accurate but unintuitive. Anomaly A: one unreproduced partial unstar --
  watch item; bm.unstar's silent per-node .catch() would hide a real intermittent
  failure. Profile left dirty by the run (owner to delete in the bookmark manager):
  `Search by name` id 587 in Bookmarks bar, empty `UAT8 test folder` id 588 in
  Other bookmarks.

Progress: [██████████] 100% (11 of 11 phases complete; 90 of 90 plans)

## Performance Metrics

**Velocity:**

- Total plans completed: 48
- Average duration: -
- Total execution time: 0.0 hours

**By Phase:**

| Phase | Plans | Total | Avg/Plan |
|-------|-------|-------|----------|
| 01 | 8 | - | - |
| 05 | 7 | - | - |
| 06 | 7 | - | - |
| 07 | 13 | - | - |

**Recent Trend:**

- Last 5 plans: -
- Trend: -

*Updated after each plan completion*
| Phase 01 P01 | 10min | 3 tasks | 23 files |
| Phase 01 P02 | 10min | 2 tasks | 24 files |
| Phase 01 P03 | 6min | 2 tasks | 2 files |
| Phase 01 P04 | 13min | 2 tasks | 4 files |
| Phase 01 P05 | 12min | 2 tasks | 3 files |
| Phase 01 P06 | 13min | 2 tasks | 4 files |
| Phase 01 P07 | 16min | 2 tasks | 0 files |
| Phase 01 P08 | 18min | 3 tasks | 13 files |
| Phase 02 P01 | 45min | 3 tasks | 8 files |
| Phase 02 P02 | 28min | 3 tasks | 31 files |
| Phase 02 P03 | 11min | 3 tasks | 10 files |
| Phase 02 P04 | manual | 1 task | 1 file |
| Phase 03 P02 | 8min | 2 tasks | 4 files |
| Phase 03 P03 | 8min | 2 tasks | 4 files |
| Phase 03 P01 | 15min | 3 tasks | 17 files |
| Phase 03 P04 | 11min + checkpoint | 3 tasks | 8 files |
| Phase 03 P05 | ~25min (2 sessions) | 2 tasks | 5 files |
| Phase 03 P06 | 17min | 3 tasks | 6 files |
| Phase 04 P01 | 10min | 2 tasks | 3 files |
| Phase 04 P03 | 16min | 3 tasks | 7 files |
| Phase 04 P02 | 6min | 2 tasks | 4 files |
| Phase 04 P04 | 25min (2 sessions) | 3 tasks | 6 files |
| Phase 04 P05 | 18min | 3 tasks | 6 files |
| Phase 04 P06 | 13min | 3 tasks | 8 files |
| Phase 04 P09 | 3min | 2 tasks | 2 files |
| Phase 04 P10 | 11min | 2 tasks | 2 files |
| Phase 05 P01 | 7min | 3 tasks | 14 files |
| Phase 05 P02 | 8min | 3 tasks | 5 files |
| Phase 05 P03 | 9min | 2 tasks | 6 files |
| Phase 05 P04 | 12min | 2 tasks | 4 files |
| Phase 05 P05 | 12min | 3 tasks | 8 files |
| Phase 05 P06 | ~7min | 2 tasks | 5 files |
| Phase 05 P07 | ~20min | 2 tasks | 5 files |
| Phase 06 P01 | ~20min | 3 tasks | 12 files |
| Phase 06 P02 | 25min | 3 tasks | 7 files |
| Phase 06 P03 | ~30min | 3 tasks | 8 files |
| Phase 06 P04 | ~30min | 3 tasks | 11 files |
| Phase 06 P05 | ~30min | 3 tasks | 6 files |
| Phase 07 P01 | 4min | 2 tasks | 1 files |
| Phase 07 P02 | 15min | 2 tasks | 6 files |
| Phase 07 P03 | 8min | 3 tasks | 5 files |
| Phase 07 P09 | 12min | 3 tasks | 5 files |
| Phase 07 P04 | 5min | 2 tasks | 1 files |
| Phase 07 P05 | 12min | 3 tasks | 6 files |
| Phase 07 P10 | ~30min | 2 tasks | 18 files |
| Phase 07 P11 | ~20min | 2 tasks | 3 files |
| Phase 07 P06 | ~50min | 3 tasks | 6 files |
| Phase 07 P12 | 25min | 2 tasks | 8 files |
| Phase 07 P07 | ~15min | 2 tasks | 6 files |
| Phase 07 P13 | ~20min | 2 tasks | 8 files |
| Phase 07 P08 | ~55min | 2 tasks | 7 files |
| Phase 08 P01 | 9min | 2 tasks | 4 files |
| Phase 08 P02 | 22min | 3 tasks | 5 files |
| Phase 08 P03 | ~12min | 2 tasks | 2 files |
| Phase 08 P04 | ~10min | 2 tasks | 2 files |
| Phase 08 P05 | 12min | 2 tasks | 2 files |
| Phase 08 P06 | ~15min + UAT | 2 tasks | 5 files |
| Phase 09 P01 | 6min | 3 tasks | 5 files |
| Phase 09 P02 | 2min | 2 tasks | 2 files |
| Phase 09 P03 | 8min | 2 tasks | 3 files |
| Phase 09 P04 | 12min | 2 tasks | 2 files |
| Phase 09 P05 | 4min | 2 tasks | 0 files |
| Phase 09 P06 | 5min | 2 tasks | 0 files |
| Phase 09 P09 | 18min | 3 tasks | 32 files |
| Phase 10 P01 | 7min | 2 tasks | 3 files |
| Phase 10 P02 | 14min | 3 tasks | 5 files |
| Phase 10 P04 | ~14min | 2 tasks | 4 files |
| Phase 10 P05 | ~17min | 2 tasks | 2 files |
| Phase 11 P01 | 22min | 3 tasks | 17 files |
| Phase 11 P02 | 23min | 3 tasks | 5 files |
| Phase 11 P05 | 7min | 3 tasks | 2 files |
| Phase 11 P07 | 5min | 3 tasks | 2 files |
| Phase 11 P03 | 7min | 3 tasks | 3 files |
| Phase 11 P06 | 6min | 3 tasks | 2 files |
| Phase 11 P08 | 18min | 3 tasks | 5 files |
| Phase 11 P04 | 14min | 2 tasks | 5 files |
| Phase 11 P09 | 8min | 3 tasks | 5 files |
| Phase 11 P10 | 12min | 3 tasks | 3 files |
| Phase 11 P11 | 35min | 3 tasks | 2 files |
| Phase 12 P01 | 35min | 3 tasks | 2 files |
| Phase 12 P02 | 30min | 3 tasks | 16 files |
| Phase 12 P09 | 25min | 3 tasks | 3 files |
| Phase 12 P03 | 45min | 3 tasks | 5 files |
| Phase 12 P10 | 42min | 2 tasks | 7 files |
| Phase 12 P11 | 32min | 3 tasks | 4 files |
| Phase 12 P12 | 18min | 3 tasks | 9 files |
| Phase 12 P14 | 35min | 3 tasks | 5 files |

## Accumulated Context

### Roadmap Evolution

- Phase 8 added: Floating trackpad bubble — replace quick-bar with draggable bubble + floating trackpad window (spec: docs/superpowers/specs/2026-07-15-trackpad-bubble-design.md)
- Phase 10 added: Keyboard rethink + Shortcuts tile — full-screen swipeable keyboard pads (Type w/ system IME + slim extras row, Arrows, Numpad, Fn) with persistent modifier chips + bottom tabs replacing the bottom-docked panel/switcher; new Shortcuts hub tile of one-tap Windows shortcut buttons (show desktop, snip/screenshots, task manager, explorer, settings, snap, refresh, tabs, find, zoom, edit ops) via existing key tap+mods path; keymap.rs CLIENT_KEY_CODES + Dart mirror extended (letters, PrintScreen, etc). Excluded by user: Alt+Tab (Apps remote exists), Win+L lock, Ctrl+Alt+Del (uninjectable)
- Phase 9 added: UI refinement to design prototype — visual pass across all screens to match the Claude Design handoff (spec: docs/superpowers/specs/2026-07-16-ui-refinement-prototype/Prototype.dc.html). User-decided: dot-grid trackpad texture only — NO fake cursor dot, NO tap ripple. Palette untouched (7 D-12 tokens already byte-identical to prototype).
- Phase 12 added: In-App Updates — a "check for updates" surface that self-updates all three components (Flutter app, Windows server, browser extension), driven from the phone. Design spec approved 2026-08-01: `docs/superpowers/specs/2026-08-01-in-app-updates-design.md` (commit 3e0135f) — read it before planning; its Decisions table IS the acceptance surface. LOCKED decisions: (a) a second, PUBLIC repo `nandodeomkar/remote-control-releases` holds the 3 release assets so no auth token ships inside any artifact — the private repo keeps source and `.planning/`; (b) the phone is the control surface for all three, PC settings keeps a fallback check; (c) one unified `X.Y.Z` across `server-windows/Cargo.toml`, `pubspec.yaml`, and `extension/manifest.json`, with NO update manifest file — the public releases API already returns tag, asset names, and per-asset sha256 `digest`; (d) protoVersion 1.7 → 1.8 adds `update.check` / `update.status` / `update.apply` / `update.progress` plus srv→ext `ext.reload`; (e) the server resolves asset URL + hash itself from a compiled-in constant and NEVER accepts one from the wire (a wire-supplied URL is RCE on the PC — this is not negotiable for convenience); (f) PC apply = silent Inno install + detached relaunch helper + an `update-result.json` marker read at startup, because the process that would report a failed install has already exited; (g) the extension rides the installer (it is already bundled at `{app}\extension`) and reloads in place via `chrome.runtime.reload()`, guarded to one attempt per target version per process run. Entry-scan notes for planning, NOT locked: new deps look like `ureq` 3.3 server-side (blocking + rustls, off the tokio runtime like the other worker threads) and `crypto` app-side (Dart has no built-in sha256); the Android install channel should mirror the hand-written `platform/multicast_lock.dart` MethodChannel pattern rather than take a plugin. Sequencing constraint: `tools/release.ps1` and the mirror repo come FIRST — nothing client-side is testable end-to-end until a real release exists to check against. Owner action outstanding: the public mirror repo does not exist yet and must be created by the owner. Known one-time cost: every already-installed client predates this, so the first upgrade onto it is still a manual install for both users.
- Phase 11 added: Browser bookmarks — view the PC browser's bookmarks on the Browser tile, open one in a new tab, and star/unstar the current tab. Extends the existing Tab Bridge extension leg (SPEC §15) with a `bookmarks` permission and a new `bm.*` phone-facing family (proto minor bump 1.6 — 1.0–1.5 clients stay accepted). Entry-scan notes for planning, NOT locked decisions: (a) the §7 "no `url` ever crosses the phone-facing wire" invariant is preserved by keeping URL resolution extension-side — the phone sends `bm.open {id}` and the extension does `bookmarks.get(id)` → `tabs.create({url})`; (b) a full flattened `bm.state` push snapshot mirrors `tabs.state`, avoiding request-correlation machinery on the push-only ext leg, but needs node/title caps against the 56 KB frame budget; (c) the bookmarks-bar parent for new bookmarks must be resolved via `getTree()`, not the hardcoded id `"1"`; (d) a per-TabEl `bookmarked` flag would drive the star state; (e) tab rows already spend tap-down (activate), long-press and swipe (close), so a star needs a trailing button, not another row gesture. Open scope questions for discuss-phase: whether `bm.remove` (destructive, no undo) is in v1 at all, and Tabs/Bookmarks segmented control vs a separate screen.

### Decisions

Decisions are logged in PROJECT.md Key Decisions table.
Recent decisions affecting current work:

- [Roadmap]: Research phases 1+2 merged into Phase 1 (protocol contract + server core — both pure foundation); control-center split into Phase 5 (thin key-macro executors) and Phase 6 (fiddly push-driven Apps/Clipboard)
- [Roadmap]: Phase 2 is a hard gate — <30ms cursor budget on real WiFi must pass before Phase 3, else transport decision (UDP channel) is revisited
- [Roadmap]: Two spec amendments from research are wire-format decisions settled in Phase 1: challenge-response auth (HMAC-SHA256 of server nonce) and diff-ops text messages (IME-safe)
- [Roadmap]: REQUIREMENTS.md said "36 total" but contains 38 REQ-IDs; coverage corrected to 38/38
- [Phase ?]: Auth construction locked: HMAC key = SHA-256(raw token), message = nonce bytes — verifiable from stored hash; fixes design spec §4 unimplementable literal text
- [Phase ?]: 05-auth-proof.json macHex computed by independent .NET crypto — cross-language byte-identity anchor for Rust and Dart codecs
- [Phase ?]: Nonfinite binary fixture uses canonical quiet NaN bits 0x7fc00000 per plan (not .NET's negative-NaN variant)
- [Phase 01]: Enum-valued wire fields (button/action/reason) are plain Strings in codec payload structs: codec stays value-lenient (version-2 hello must decode), semantic validation lives in the router
- [Phase 01]: Canonical-form serde attributes (skip_serializing_if on every Option field) locked in Wave 2 so Plan 03 encode round-trip needs no struct changes
- [Phase 01]: Every todo!() body names its implementing plan (01-03..01-06) so red-test panics identify the responsible wave
- [Phase 01]: encode_msg always emits p (as {} for empty payloads): fixture expect envelopes carry p unconditionally, overriding the plan's omit-empty-p wording
- [Phase 01]: MissingField is reserved for payload-level required fields; envelope-level serde failures map to BadJson
- [Phase 01]: rand 0.10 renamed RngCore → Rng at crate root; hmac 0.13 requires explicit KeyInit import for new_from_slice (RESEARCH snippets predate these majors)
- [Phase 01]: pending_power uses tokio::time::Instant so start_paused tests drive the 10s confirm window; mismatched confirm clears the pending action (single-shot take)
- [Phase 01]: Router drops semantic-invalid values silently (bad button/action/mods, setvol > 100): SPEC defines no err code for bad enum values and inventing one creates a probing surface
- [Phase 01]: Post-auth JSON decode errors reply err{internal} and keep the connection; SPEC err table defines no decode-failure code, pre-auth decode errors stay silent per SPEC section 6
- [Phase 01]: Unparseable protoVersion major treated as versionMismatch (err + close) per D-06 reject-by-default; session FSM owns hello/pin/auth and ignores post-auth handshake replays
- [Phase 01]: Zero-Windows-deps verified against Linux target tree: windows-sys on the host tree is tokio/mio/socket2 platform plumbing only
- [Phase 02]: Default WebSocket port 17777 with RC_PORT env override (spec names no numeric default; settings UI is Phase 7)
- [Phase 02]: DEV_PIN dev shortcut not implemented — AuthManager has no fixed-PIN API and the console-printed real PIN serves the owner's test loop (T-02-EP surface never created)
- [Phase 02]: enigo::set_dpi_awareness() helper (re-exported at crate root in 0.6.1) used for DPI awareness; windows-crate fallback not needed
- [Phase 02]: Enigo injection failures on the input thread are dropped (send-and-forget hot path), never panic
- [Phase 02]: A2 resolved: ConnectionTask.fromSocket is public in Dart 3.12.2 — RESEARCH TCP_NODELAY construction used verbatim, no fallback idiom
- [Phase 02]: connectNoDelay awaits channel.ready so WebSocket connect failures surface at the call site, not only on the stream
- [Phase 02]: MoveSender.sink typed StreamSink<dynamic> so IOWebSocketChannel.sink plugs in directly; tests substitute a recording fake
- [Phase 02]: Client handshake is a pure IO-free FSM (HandshakeFsm) mirroring session.rs exactly (hello -> always challenge -> pin|auth branch on in-memory token); a thin HandshakeDriver does all channel IO — transitions proven without a socket
- [Phase 02]: Reconnect/auth path reuses authProof(hexDecode token, hexDecode nonce) verbatim — no client-side crypto invented; asserted byte-equal in the FSM test
- [Phase 02]: Latency measured round-trip-UNDER-move-load (ping every K moves OR ~250ms), not idle RTT — the faithful proxy for ack-less move frames (D-06); nearest-rank percentile (rank = ceil(p/100*N), clamped)
- [Phase 02]: Single channel-stream listener decodes each frame once and routes handshake -> driver, pong -> probe (no double-subscribe); hot move path never rebuilds the HUD (timer-polled on a throttle)
- [Phase 02]: ws:// LAN needs AndroidManifest INTERNET permission + usesCleartextTraffic=true; scoped network-security-config deferred to Phase 3
- [Phase 02]: Hard gate judged PASS with the pointer-accel workaround (Windows "Enhance pointer precision" disabled): the suppressed slow deltas are OS-injection fidelity downstream of the correct sub-pixel accumulator, not transport/latency — absolute-injection fix (enigo Coordinate::Abs) deferred to a pending todo (Phase 4 candidate)
- [Phase 03-02]: Backoff cap is 10s (design spec §8) over D-06 discretionary ~30s; delay = base(1/2/4/8/10s) x (0.8 + 0.4*random()) rounded to ms, injectable random for deterministic tests
- [Phase 03-02]: authRejected for ANY reason lands in needPairing with AuthStopEffect + CloseEffect and never a retry; ClearTokenEffect + revoked explanation only for noPairing/badMac
- [Phase 03-02]: beaconSighted short-circuit also resets the attempt counter — consistent D-06 fresh-start semantics with appResumed/retryNowPressed
- [Phase 03-03]: loadDevices returns Map keyed by deviceKey; DeviceMeta.toJson excludes the key so the prefs devices JSON byte-matches RESEARCH Pattern 7
- [Phase 03-03]: SharedPrefsKv wraps SharedPreferencesAsync (2.5.x current API), thin adapter so DeviceStore never sees the API choice
- [Phase 03-03]: Every SecureKv read/delete is Pitfall-5-wrapped (deleteToken swallows PlatformException like reads); writes stay raw so pairing save failures surface
- [Phase 03-01]: SERVER_PROTO_VERSION widened to pub(crate) and referenced by encode_beacon — proto literal never duplicated
- [Phase 03-01]: MachineGuid registry-read failure degrades to stable "name-<device_name>" id with a warn — identity failure never crashes the server
- [Phase 03-01]: if-addrs in server-core (cross-platform, preserves zero-Windows-deps); winreg + tauri-winrt-notification isolated in server-windows; toast attributed to "Windows PowerShell" is the accepted v1 quirk (AUMID lands with Phase-7 tray)
- [Phase 03-04]: Beacon.host is always the datagram source address — payload fields can never redirect where the client dials (T-03-13 spoof containment)
- [Phase 03-04]: BeaconListener pairs MulticastLock with the socket lifecycle: acquire before bind, release on stop AND bind failure (retryable); broadcast stream survives stop/start
- [Phase 03-04]: MulticastLock MethodChannel no-ops on MissingPluginException — OEM insurance, not a requirement; tests and non-Android hosts need no fakes
- [Phase 03-04]: network_security_config.xml keeps base-config cleartext (Android XML has no CIDR scoping); real LAN-only enforcement is the ConnectionService RFC1918 guard in 03-05 (D-10 split documented in-file)
- [Phase 03-05]: Liveness is a generation-guarded tick chain on the injected schedule seam (no Timer.periodic) — probe stays timer-free, tests deterministic; probe.reset() keeps the RTT window so the header shows last-known latency through teardown
- [Phase 03-05]: Guard refusal (non-RFC1918 dial) is a terminal user-input error -> idle with lastDialError; transportFailed is reserved for real transport blips (backoff would hammer a public host)
- [Phase 03-05]: Reliable queue survives transport blips (teardown drops only volatile gating); AuthStopEffect is the sole queue-clearing path — a revoked target re-pairs before anything flushes
- [Phase 03-05]: ConnectionStatus snapshot is value-equal (== / hashCode) so the Riverpod Notifier suppresses no-op rebuilds on changes pings; D-10 enforcement split now COMPLETE (XML + code guard both shipped)
- [Phase 03-06]: DeviceListEntry equality excludes lastSeenMillis: anti-churn falls out of listEquals — unchanged beacons publish nothing, rows never blink per packet
- [Phase 03-06]: Pairing sheet rebuilds via StreamBuilder over service.changes — needPin/failure transitions never alter the value-equal ConnectionStatus snapshot, so a provider watch alone would miss them
- [Phase 03-06]: Post-authFail retry is one tap: the sheet stores the PIN as pending, fires a fresh connectTo, and auto-feeds it when the new handshake reaches needPin
- [Phase 03-06]: Firewall-blocked copy requires BOTH a failed manual dial AND a currently-live beacon row at that host; otherwise the generic transport copy with ip:port renders
- [Phase 03-07]: Header chip + banner poll their own Timer.periodic(kHudReadThrottle 500ms) — decoupled from the hot move path (Pitfall 9); the single latency/status surface for every connected-capable screen
- [Phase 03-07]: attachBeacons wired into DeviceListNotifier so the D-06 beacon short-circuit is live end-to-end (03-05's attachBeacons had no caller otherwise); trackpad hint strings centralized in connection_copy.dart
- [Phase 03-07]: D-01 launch kick runs post-first-frame in DeviceListScreen initState — silent reconnect to lastDeviceKey, NO nav on success (user stays on the list); explicit row-tap is the only path that navigates to the trackpad
- [Phase 04-03]: ScrollIntent carries delta/2 per move event (per-event average of the two pointers' deltas); fling velocity = in-window sample sum / (lift - oldest sample ts) so a pause naturally cancels the fling
- [Phase 04-03]: Drag-lock edges: onLongPressFire while locked is a no-op, onPointerCancel keeps the lock (only reset() or tap-to-drop clears), second finger during a drag is ignored
- [Phase 04-03]: Pre-slop pointer travel (<=kTapSlopPx) emits nothing — tap candidate preserved, <=10px startup motion intentionally dropped (standard trackpad behavior)
- [Phase 04-02]: Open Q3 resolved: terse key.code vocabulary locked in keymap.rs CLIENT_KEY_CODES (Esc/Tab/Home/End/PgUp/PgDn/Del, Up/Down/Left/Right, F1..F12, Num0..Num9 + NumEnter + NumDot, ControlLeft/AltLeft/ShiftLeft/WinLeft) — 04-06 kClientKeyCodes must mirror byte-for-byte
- [Phase 04-02]: Router Phase-1 browser/present macro codes (BrowserBack/BrowserForward/T/W/B/Plus/Minus) mapped in map_key via Key::Unicode so already-routed actions execute instead of silently no-opping
- [Phase 04-02]: KeyTap with an unknown code drops the WHOLE command — modifiers never pressed around a key that will not fire; Cmd dropped Copy (heap-owning variants, mpsc send moves)
- [Phase 04-04]: Long-press verdicts round-trip through the classifier (onLongPressElapsed -> onLongPressFire -> driver.handle) so drag-start vs stale-fire logic stays in the pure FSM
- [Phase 04-04]: D-05 sensitivity bridged to the hot path via ref.listenManual(fireImmediately) updating a cached double — never a per-event provider lookup; store clamps read+write and degrades to default on platform read failure
- [Phase 04-04]: Tune sheet is a Consumer-scoped modal route outside the Listener subtree — tuning never rebuilds the trackpad surface or header chip
- [Phase ?]: 04-05: IME-revision diff follows fixture 02 / computeDiff semantics (bs:1, ins:'e ') — plan's bs:3 expectation was a typo; computeDiff stays the only diff engine
- [Phase ?]: 04-05: hidden IME field rides a ZWSP sentinel (8 x U+200B) so boundary backspaces keep emitting bs frames; HiddenTextInput mounted OUTSIDE the panel's AnimatedSize so toggling never detaches the input connection
- [Phase 04-06]: LOCKED modifier = physical hold via keymap.rs hold codes (KeyMsg down/up) excluded from modsForTap (Pitfall 7 double-apply avoidance); ARMED rides the mods array of the next non-modifier tap only, then auto-resets
- [Phase 04-06]: D-12: ModifierFsm.disconnected() resets with ZERO effects and the panel forgets its held key cap — CONN-07 release_all already freed real keys; a queued stale up must never flush into a NEW session
- [Phase 04-06]: keyboard.rowGroup store rides the PrefsKv seam (device_store pattern) instead of raw SharedPreferencesAsync — its constructor throws StateError in tests without a platform instance
- [Phase 04]: 04-09: Phase-04-03 scroll decision refined: ScrollIntent carries delta/n over LIVE tracked pointers (n=2 both fingers down — byte-identical averaging; n=1 after a lift = full rate, WR-04 closed); no new tuning constant, classifier stays pure FSM
- [Phase 04-10]: Liveness deadline via sleep_until(last_inbound + LIVENESS_TIMEOUT 10s) select! branch in run_session — expiry breaks 'read onto the EXISTING CONN-07 cleanup; last_inbound refreshes on ANY inbound frame (Text/Binary/WS control), never on pause toggles
- [Phase 04-10]: Half-open socket tests keep the client alive and silent (drop/close emits FIN/RST on loopback); paused clock for the deadline wait, tokio::time::resume() before real-IO session-end assertions (auto-advance races kernel FIN)
- [Phase 05-01]: VolChangedPayload uses u64 value + bool muted with NO Option — serde missing-field is the hard decode error fixture 03 demands
- [Phase 05-01]: clientProtoVersion in handshake_fsm.dart references the remote_protocol protoVersion constant so minor bumps cannot leave a stale lib literal; remaining '1.0' test literals are commented historical wire pins (Pitfall 10)
- [Phase ?]: 05-02: Browser grid rows derive from kBrowserActions with a data-driven pairing rule (refresh full-width) — the 7-action list stays the single source of truth vs router.rs
- [Phase ?]: 05-02: kHubTiles ordered registry IS the hub render order (Trackpad first, full-width primary); later plans insert HubTileSpec entries with zero grid changes
- [Phase ?]: 05-02: Hub tiles + browser keys fire callbacks on tap-down via the MouseButtonsBar house pattern — widget tests never touch the Navigator or a service fake
- [Phase 05-04]: PresenterTimer is a pure clock-injected FSM (stopped/running/paused) over nowMillis — elapsed excludes paused gaps (accumulated + live span while running); startShow resets from ANY state; no timers/IO/Flutter in the FSM (D-08, Pitfall 13)
- [Phase 05-04]: The presenter mm:ss ticker is a widget-local 1s Timer.periodic created LAZILY on first Start show (no rebuild loop before a show) and cancelled in dispose; the timer text tap/long-press stays interactive even when disconnected because the elapsed clock is strictly client-local (D-08)
- [Phase 05-04]: PresenterScreen gates only the present-sending controls (zones, Start/End/Blank) on auth (muted, never red); Blank is optimistic local state (no wire readback) rendered with the armed-chip outline; WakelockPlus scoped initState->dispose (D-09); Presenter tile inserted between Trackpad and Browser in kHubTiles
- [Phase 05-05]: First COM usage in the repo — dedicated audio thread owns the apartment (CoInitializeEx MTA), re-acquires MMDeviceEnumerator→default endpoint→IAudioEndpointVolume FRESH every 250ms pass so default-device switches survive with zero notification plumbing (Pitfall 6); every HRESULT `.ok()?`-drops, never unwraps
- [Phase 05-05]: IMMDevice::Activate is feature-gated on Win32_System_Com_StructuredStorage + Win32_System_Variant (PROPVARIANT param) beyond the 7 RESEARCH-listed windows features — cargo surfaced both (A3)
- [Phase 05-05]: enable_shutdown_privilege() checks GetLastError() != ERROR_NOT_ALL_ASSIGNED so a silent partial grant is failure (Pitfall 1); every WinPower method thread::spawns (SetSuspendState may block until resume — never a tokio worker, Pitfall 4); sleep=SetSuspendState(false)=SUSPEND not hibernate (SC2); shutdown=EWX_POWEROFF|EWX_FORCEIFHUNG + non-zero planned dwReason (never the unconditional force flag — data loss)
- [Phase 05-05]: WinMedia holds only two senders (input_tx media taps MED-01, audio_tx volume MED-02) — send-and-forget, no COM on the caller (Pitfall 5); pct_from_scalar rounds+clamps for a lossless 0..=100 round trip (Pitfall 7); StubMedia/StubPower gone, only StubApps/StubClipboard remain for Phase 6
- [Phase 05-06]: ConfirmTrackFsm is a pure per-track slide-to-confirm FSM (idle→dragging(progress)→completed) — sealed effects (SendPower/SendConfirm/OpenCountdown/SpringBack) carry only the action string, no Flutter/IO/timers/wire types; 0.9 completion threshold, spring-back below (T-05-13)
- [Phase 05-06]: The single-action-path gate (T-05-12/PWR-03) is structural: SendPower is always effect[0], a single `if (isDestructive)` picks the second effect, so the FSM can never emit SendConfirm for restart/shutdown — unit-proven; PowerMsg is sent from exactly one screen site, ConfirmMsg from exactly two (lock/sleep effect + dialog button)
- [Phase 05-06]: D-05 lock/sleep completion sends power+confirm same-tick (FIFO held by the reliable queue); D-06 restart/shutdown open the app's ONE modal — a red countdown dialog with a dialog-local 1s ticker seeded from kPowerConfirmWindowSeconds=10 (server CONFIRM_WINDOW mirror); auto-dismiss at 0 / Cancel / barrier send nothing, late confirm's err{noPendingAction} silently ignored, post-confirm disconnect is banner-only (RESEARCH Pattern 5)
- [Phase 05-06]: Power hub tile (Icons.power_settings_new) inserted between Trackpad and Presenter → order Trackpad, Power, Presenter, Browser; the bare-grid hub test surface was enlarged to 800x1400 for the 4th tile (production HubScreen scrolls the grid)
- [Phase 05-07]: VolumeSliderPolicy is a pure clock-injected D-04 finger-wins policy — leading-edge kSetvolThrottleMs=50 throttle, dragStart resets throttle bookkeeping so each fresh drag's first update sends, dragEnd flushes final iff it differs from last sent ([10,30] no-dup / [10,30,45] throttled-tail both unit-proven), unauthed drops-never-queues (Pitfall 12); injected seams are public fields per presenter_timer convention
- [Phase 05-07]: VolChangedMsg parks a value-equal VolumeSnapshot on ConnectionService (branch after PongMsg, before driver routing, no payload logged) → changes ping → VolumeNotifier (cloned from ConnectionStatusNotifier); Media screen renders slider + mute from the pushed snapshot only (mute has NO optimistic flip, follows next push); Media hub tile (Icons.music_note) inserted ahead of Power → FINAL 5-tile order Trackpad, Media, Power, Presenter, Browser (D-01 complete)
- [Phase 06-01]: WindowInfo.icon/path are additive Option<String> with serde default + skip_serializing_if (mirrors the Phase-5 1.1 vol amendment) → legacy windows still decode and re-encode without the keys, Eq derive preserved; SERVER_PROTO_VERSION 1.1→1.2 (additive minor, 1.0/1.1 clients accepted) and the shared beacon fixture proto bumped in lockstep (D-09 single source of truth)
- [Phase 06-01]: apps.changed has NO after-auth snapshot (unlike vol.changed) — the client pulls the initial list via apps.list on screen open, so the authed-gated select! branch is the SOLE apps-push site; the == AuthState::Authed guard is the T-06-01 privacy backstop (clone of the volume branch)
- [Phase 06-01]: Apps::focus/close/launch return bool → router emits err{windowGone} (focus/close) / err{launchFailed} (launch) on false, silent on true; err msg strings are operator-facing prose that NEVER embed the HWND id or exe path (T-06-12), asserted in the FailingApps router test
- [Phase 06-01]: A pending pre-auth apps watch change is delivered as the FIRST post-auth push once the authed-gated branch enables (after the D-03 vol snapshot) — used as the positive control in apps_no_push_preauth proving the pre-auth silence was the auth gate, not a dead channel
- [Phase ?]: [Phase 06-02]: Apps enumeration runs on a dedicated OS thread (audio_thread clone) — EnumWindows Z-order + 5-point Alt-Tab filter (visible/titled/tool-app/owner-root/DWM-uncloaked); pure is_alt_tab_window predicate unit-tested without OS calls; list capped 50 + push_if_changed anti-flood (APPS-03)
- [Phase ?]: [Phase 06-02]: Icon pipeline SHGetFileInfoW(by exe path, owned->DestroyIcon) with WM_GETICON/class-icon fallback(borrowed->kept) -> GetDIBits 32bpp BGRA -> RGBA -> png -> hand-rolled base64, cached by exe path; encodes the bitmap's ACTUAL dims (GetObjectW) since GetDIBits cannot rescale
- [Phase ?]: [Phase 06-02]: WinApps validates focus/close ids against the current snapshot BEFORE sending (stale id -> false -> err{windowGone}); the apps thread's own IsWindow is the second-line same-tick-recycle guard (T-06-13 accept); UWP/ApplicationFrameHost/WindowsApps paths -> path=None (non-pinnable, focus/close still work)
- [Phase 06-03]: Dart WindowInfo mirrors protocol 1.2 (optional icon/path via _opt tolerant parse + skip-none toJson + value ==); ConnectionService parks a value-equal AppsSnapshot from apps.changed AND the apps.list reply, plus _lastError from err — the err arm is parked but NOT returned early so err{versionMismatch} still reaches handshake_fsm's terminal-fail path
- [Phase 06-03]: AppsSnapshot/AppsViewState equality is hand-rolled element-wise — no package:collection dependency added (not a direct dep; T-06-SC no-new-packages held); FavoritesStore.load returns a GROWABLE list (never const []) so pin/unpin mutate in place (bug caught by the RED suite)
- [Phase 06-03]: FavoritesStore (PrefsKv key apps.favorites, non-secret D-02) pins ONLY a running window's server-resolved WindowInfo.path (T-06-04, no manual-path field), rejects UWP path==null (Flag 1), dedupes by path, corruption-tolerant; Apps screen surfaces err toasts off the raw service.changes stream (identity-tracked) because the value-equal view never rebuilds on an err park
- [Phase 06-03]: Apps hub tile (Icons.apps) inserted after Media, before Power -> order Trackpad, Media, Apps, Power, Presenter, Browser (06-UI-SPEC placement)
- [Phase 06-04]: clip.changed has NO after-auth snapshot AND no unconditional snapshot analog (volume drains one even at default) — the PC clipboard is never dumped implicitly; a freshly-authed phone gets nothing until a real external change, pulling current value via clip.get (Pitfall 8 / T-06-05). Tested by leaving the watch at default and asserting silence (contrast with the drained vol snapshot)
- [Phase 06-04]: ClipCmd::Set NEVER pushes to the watch — the clip thread writes arboard + records the set fingerprint, and the next poll's read-back is echo-suppressed when its sha2 fingerprint matches (Pitfall 5, D-05). Consequence (plan-mandated): WinClipboard::get() returns the last EXTERNAL mirrored value, not the just-set value (harmless — the phone already holds what it set)
- [Phase 06-04]: Sensitive-clip skip is fail-open — a 0 exclude_id (RegisterClipboardFormatW failure) or a source app that sets no ExcludeClipboardContentFromMonitorProcessing format is treated non-sensitive (RESEARCH A3 residual risk); >16 KiB skip uses String::len() UTF-8 bytes with > 16384 (exactly 16 KiB allowed). No CoInitializeEx on the clip thread (arboard needs no COM, unlike the audio thread)
- [Phase 06-04]: StubClipboard removed + stubs.rs deleted — all five server_core executor traits (MouseKeys/Media/Power/Apps/Clipboard) now have real Windows backends
- [Phase 06]: [Phase 06-05]: clipFetchReply stays a String? getter but is identity-tracked by ClipNotifier — each clip.set reply decodes to a fresh String, so an unrelated changes ping (identical reference) is never consumed as a Fetch reply; no seq/counter added
- [Phase 06]: [Phase 06-05]: HistoryStore.record does move-to-head dedupe (remove existing equal, prepend, cap 5) — the only design satisfying BOTH consecutive dedupe AND reuse-moves-to-head (D-06); clipTextTooLarge caps on UTF-8 BYTES not code units (T-06-16b); Clipboard hub tile after Apps -> Trackpad, Media, Apps, Clipboard, Power, Presenter, Browser
- [Phase 07-02]: input.blocked (proto 1.3, SRV-05/D-07) added to BOTH codecs as an additive S→C push cloning the vol.changed precedent (InputBlockedPayload{reason} + Msg::InputBlocked / InputBlockedMsg + decodeText arm); reason is a fixed vocabulary ("elevated"), never window title/exe/PII. SERVER_PROTO_VERSION deliberately NOT bumped here (still 1.2) — the version bump + authed-gated session push land in 07-05 which owns session.rs. input.blocked routed to the router S→C-only no-op group (client sending it is ignored silently). A NEW fixture family needs a matching test fn in BOTH hard-coded harnesses (Rust codec_fixtures_input_blocked + Dart input_blocked group) — neither globs dirs; the shared golden fixture proves byte-identical decode.
- [Phase ?]: [Phase 07-01]: AuthManager grown to Vec<PairedDevice{hash,name,paired_at}> with from_paired/revoke/complete_pairing_named/verify_auth_hash/paired_records + a watch::Sender<u64> change-signal; existing complete_pairing/is_paired/verify_auth signatures preserved (complete_pairing delegates to complete_pairing_named phone, verify_auth to verify_auth_hash().is_some()) so server-windows still builds; hash-only invariant unit-enforced
- [Phase ?]: [Phase 07-03]: firewall::inbound_allowed keeps read-only INetFwRules enumeration (not just FirewallEnabled+DefaultInboundAction) — Windows default inbound action IS Block on standard profiles so getters-only would false-positive BlockedNoRule everywhere; port-only rule match is the single-host heuristic (A3), Unknown fails quiet (caller must not warn)
- [Phase ?]: [Phase 07-03]: windows 0.62 — VARIANT cfg-gated on all(Win32_System_Com, Win32_System_Ole), IEnumVARIANT lives in Win32::System::Ole not ::Com; autostart/firewall/notify_firewall_warning are unwired primitives (scoped allow(dead_code)) consumed by 07-06/07-08
- [Phase ?]: 07-09: haptics hot-path cache uses ref.listenManual(fireImmediately) not ref.listen (Riverpod 3)
- [Phase ?]: 07-09: keep-awake shipped as ref-counted KeepAwake + shared singleton to pre-empt the Pitfall-8 quick-bar leak (D-14)
- [Phase ?]: [Phase 07-04]: RID constants defined as plain crate-local u32 consts (not windows::Win32::System::SystemServices) so is_blocking_il stays a zero-OS-dependency pure predicate; values (0x2000/0x3000) match the real Win32 constants
- [Phase ?]: [Phase 07-04]: foreground_blocked() degrades BOTH the foreground and our own RID reads to SECURITY_MANDATORY_MEDIUM_RID on failure (fail-quiet), never manufacturing a spurious block from an uncertain read
- [Phase ?]: 07-05: revoke select! arm is a sibling (not authed-gated) — the if let Some(h) = authed_hash guard inside filters; input.blocked mirrors apps/clip (no after-auth snapshot); handle_text grew a third return element (newly-authed hash) captured at the existing D-03 was_authed transition guard
- [Phase 07-10]: grep-guard test (test/theme_tokens_guard_test.dart) scans the WHOLE lib/ tree, not just the plan's named 12 screens, per the plan's own acceptance criteria (`grep -rn "0xFF16181D" lib` must return ONLY tokens.dart); migrated 5 additional palette offenders under Rule 2 (key_rows.dart, modifier_chip.dart, pairing_dialog.dart, mouse_buttons.dart, dev/beacon_smoke_main.dart)
- [Phase 07-10]: connection_header.dart keeps two local Color consts (_reconnectingColor #E8A33D amber, _chipFill translucent #CC0E0F12) uninverted — neither is one of the seven D-12 locked tokens, so the guard test intentionally does not forbid them
- [Phase 07-10]: bindHapticsCache(ref) installed once in main.dart's RemoteControlApp.initState (before the D-01 launch kick and D-06 resume listener) so the haptics hot-path cache is primed before the very first tap; all ~19 HapticFeedback call sites now route through hapticTick()/hapticTickMedium(); Trackpad and Presenter route keep-awake through the shared keepAwake ref-counted singleton instead of raw WakelockPlus calls
- [Phase 07-11]: InputBlockedSnapshot equality includes the timestamp (not just reason) so a repeated elevated-window block still notifies the banner as a fresh event
- [Phase 07-11]: UipiBanner mount-time seed guard: a snapshot already parked before mount is not shown, only a strictly newer transition opens the banner
- [Phase 07-06]: tray-icon 0.24 confirmed (vendored source read) to auto-handle TaskbarCreated re-registration internally -- no manual rebuild() needed — verified against platform_impl/windows/mod.rs's tray_proc S_U_TASKBAR_RESTART handler rather than trusting the RESEARCH [ASSUMED] tag
- [Phase 07-06]: rustc toolchain pinned to 1.97.0 via server/rust-toolchain.toml — egui/ecolor/emath/epaint 0.35 require rustc >= 1.92; the prior default 1.89 toolchain hard-failed the build (Rule 3 blocking fix)
- [Phase 07-06]: UIPI foreground probe (maybe_check_uipi) adds a 250ms time throttle on top of the plan's transition debounce — foreground_blocked() walks two OpenProcess/OpenProcessToken chains, too costly to run unthrottled on every Move event without risking the locked <30ms cursor-latency budget (PAD-05)
- [Phase 07-12]: trackpad_screen.dart wiring for scroll_direction added under Rule 2 (not in plan file list) so the D-11 pref has real effect, not just an isolated driver seam
- [Phase 07-12]: TrackpadDriver scrollReversed seam is optional (defaults Natural) so every pre-existing driver test call site compiles unchanged; scroll_direction.dart's hot-path cache lives module-level (haptics-style), not screen-local
- [Phase 07-07]: Config::default() keeps clipboard_sync ON (manual Default impl): a derived false default would silently regress Phase-6 always-on clipboard sync on fresh installs; port field uses a lenient toml::Value codec so a hand-edited garbage port drops field-local instead of failing the whole document and wiping the paired list
- [Phase 07-07]: RC_PORT env override is never baked into config.toml (save subscription re-serializes cfg.port, the loaded value); invalid RC_PORT now warns + falls through via config::resolve_port instead of aborting startup (T-07-27 fail-safe)
- [Phase 07-07]: clip-sync gate is an Arc<AtomicBool> checked on the clip thread's poll tick only — clip.set (explicit phone action) keeps working with sync off; beacon guid fallback stays COMPUTERNAME-based while display name follows cfg.device_name (rename must not change discovery identity)
- [Phase 07]: 07-08: egui-on-winit via EguiGlow + glutin 0.32/glutin-winit 0.5 — eframe cannot share the tray loop (Pitfall 4)
- [Phase 07]: 07-08: SharedSettings live handle — settings edits and pairing/revoke config saves share one source of truth (no clobbering)
- [Phase 07]: 07-08: device-name change also restart-to-apply (beacon identity binds once at startup, same as port — Open Q3)
- [Phase ?]: [Phase 08-01]: bubble/window positions each serialize as a single JSON string, degrade corrupt/unknown reads to their default (bubble right/70%, window unset sentinel), and clamp fractions to [0,1] on read+write (T-08-01 off-screen guard); window uses a bool isSet sentinel via .at/.unset const ctors, independent of the bubble key (SC4)
- [Phase ?]: [Phase 08-02]: TrackpadCore extracted as the shared zero-setState hot-path engine; the full screen and the 08-04 window mount the SAME core so cursor parity holds by construction
- [Phase ?]: [Phase 08-02]: drag-lock surfaced via a parent-owned ValueNotifier injected into TrackpadCore and re-exposed as ValueListenable<bool> dragLocked (D8-04 injected-notifier discretion); TrackpadScreen keeps its _service read for chrome only
- [Phase 08]: 08-03: TrackpadBubble is a full-bleed Stack with the 56dp circle in a Positioned child; drag/tap gestures target the circle (not the widget center) and commit yFraction from the release top-left dy (matching the store clamp), snapping to the nearest edge via a 200ms easeOut controller that commits on completion
- [Phase 08]: 08-04: FloatingTrackpadWindow is a self-positioning single Positioned card — header-only drag (⠿ handle GestureDetector, a disjoint SIBLING of the TrackpadCore Listener) clamps offset to [0, screen−card] and commits clamped [0,1] fractions to windowPositionProvider; surface touches stay pure mouse input (Pitfall 2, T-08-06/SC3)
- [Phase 08]: 08-04: the window owns its drag-lock ValueNotifier (fed to TrackpadCore, read by the inline header pill) unless a test injects one; keepAwake is a forwarded-only seam since TrackpadCore is the sole hold owner (Pitfall 4); first-open anchors from initialTopLeft (bubble spot) else screen-center
- [Phase ?]: [Phase 08]: 08-05: PopScope wraps a ValueListenableBuilder<bool> (not the reverse) so canPop stays reactive to _expanded while the Material/Stack subtree is passed as the builder's cached child, preserving the body-never-rebuilds-off-expand invariant
- [Phase ?]: [Phase 08]: 08-05: FloatingTrackpadWindow is rendered UNWRAPPED (no ScaleTransition/Opacity) in the expanded branch since it returns a bare Positioned that must be a direct Stack child (Transform/Opacity break the Positioned<->Stack ParentData contract when interposed) -- the 200ms AnimationController instead drives only the bubble's FadeTransition
- [Phase 08]: 08-06: central wrapper migration — renaming HubTileSpec.showQuickBar->showBubble and swapping the _open wrap in hub_screen.dart alone migrated all 7 tool screens (D8-05); quick-bar deleted outright with no restore toggle (D8-06)
- [Phase 08]: 08-06: `flutter install` reuses the last-built APK without rebuilding — on-device UAT of any migration REQUIRES an explicit `flutter build apk --release` first (burned: stale 07-15 APK installed with a fresh install timestamp, phone showed the old quick-bar)
- [Phase ?]: [Phase 09-01]: dot-grid is a leaf CustomPaint (no child, no hitTest) mounted UNDER the Listener as Stack child[0], hint in IgnorePointer above — decoration cannot swallow input; drag still moves, tap still left-clicks (T-09-01 proven)
- [Phase ?]: [Phase 09-01]: MouseButtonsBar per-button minHeight = height-16 (64->48 byte-identical, 56->40 window, no overflow); kTrackpadHintColor #4A505C a local non-token const so the D-12 seven-literal guard stays untripped
- [Phase 09]: 09-02: Status chip+banner and Hub confirmed As-is vs 09-UI-SPEC; parity pinned by tests, zero source/palette change — Confirm-pass plan: every named spec value already matched source, so deltas closed were test-coverage gaps only
- [Phase ?]: 09-03: Keyboard hint copy added (#4a505c local const _kKeyboardHintColor, not a token); switcher/caps/chips confirmed at-spec — source unchanged, deltas closed were test-coverage only
- [Phase ?]: 09-04: Media + Browser screens already matched 09-UI-SPEC; closed as pure test-pinning (transport 64/48/48, tabular readout, full-width Refresh, accent press-flash)
- [Phase 10-01]: key.code vocabulary extended by 18 codes (letters A C D E F I R S V X Y Z, main-row 0, PrintScreen, promoted T W Plus Minus) with NO SERVER_PROTO_VERSION bump — the accepted vocabulary grows, message shape unchanged, unknown codes still drop silently (T-04-02). keymap.rs CLIENT_KEY_CODES is the single source of truth; Dart kClientKeyCodes mirrors byte-for-byte, both coverage gates green
- [Phase 10-01]: Key::PrintScr confirmed the enigo 0.6.1 VK_SNAPSHOT variant by reading vendored src (keycodes.rs:525 variant / :1010 -> VK_SNAPSHOT); letters ride Key::Unicode(lowercase) reusing the T/W/B precedent so Ctrl/Win chords resolve via VkKeyScanW. T/W/Plus/Minus promoted OUT of ROUTER_MACRO_CODES (now BrowserBack/BrowserForward/B) keeping the two lists disjoint; B stays router-only (present_macro blank). Plus->'=' Pitfall-11 fix preserved, Equal never introduced
- [Phase 10-02]: kShortcutCatalog is the single ordered source of truth (4 sections / 25 buttons, kBrowserActions/kHubTiles pattern) driving BOTH the render and the vocabulary coverage test; every ShortcutSpec.code cross-checked against kClientKeyCodes (drift fails the build, T-10-03), excluded combos (Alt+Tab/Win+L/Ctrl+Alt+Del) asserted absent. Buttons fire ONE KeyMsg(action:'tap', mods) on the reliable path via the media _TransportButton press-DOWN + 100ms accent-flash + muted-not-red pattern — no new network surface, no protocol change (T-10-02 accept). All 26 Symbols.*_rounded glyphs verified present in material_symbols_icons 4.2951.0 (zero substitutions). Shortcuts HubTileSpec (bolt_rounded) at kHubTiles index 2 → 9-tile grid, HubTileGrid odd-tail chunker renders the 9th half-width tile with zero grid change
- [Phase ?]: [Phase 09-09]: Full Material Symbols Rounded migration — all client glyphs are Symbols.<name>_rounded (material_symbols_icons 4.2951.0), axes pinned once via buildAppTheme IconThemeData (opsz 24/wght 400/FILL 0/GRAD 0); classic Icons.* banned in lib/ by icons_guard_test. Owner overrode 09-UI-SPEC line-28 skew acceptance. Release APK grew only +61.7 KB (Symbols font tree-shaken 99.4%).
- [Phase 10]: Type-row cap relaxation is the padding seam, not minWidth — Under an Expanded cell BoxConstraints.enforce already clamps KeyCap's 48px minWidth floor to the parent's tight width, so the predicted 'fight' cannot occur and minWidth is inert there. The real squeeze at ~40dp is the 12px horizontal padding (16px left for a 25px 'Esc'), so the Type row passes 4px. minWidth still ships: UI-SPEC names the relaxation and it does bind under the docked panel's loose Wrap constraints.
- [Phase 10]: KeyCap's 48px HEIGHT floor stays hard-coded; only width is parameterized — UI-SPEC relaxes width only ('Height stays >=48dp'). The height floor is what actually keeps a cap tappable, so it must not be call-site relaxable.
- [Phase 10]: kKeyboardHint moved (not copied) to key_pads.dart — A duplicate const would break the house one-named-const rule and, blocking, would leave 10-05 unable to import both key_pads.dart and keyboard_screen.dart (kKeyboardTitle) without an ambiguous-name collision.
- [Phase 10]: KeyboardTabBar reports selection only — no haptic, no page animation, no enabled param — The screen owner (10-05) runs hapticTick() + the 200ms PageView animate on onSelect, so swipe-settle can reuse the selection path without double-firing a haptic (UI-SPEC: no extra haptic on settle). Tabs are navigation and must work offline, so no gated variant exists.
- [Phase ?]: [Phase 11-01]: protoVersion 1.6 locked in SPEC.md — six bm.* rows, flat BmEl {id,parentId,title,folder?,count?,locked?,truncated?} with NO url and NO icon, root 0 virtual (D-08), nodeId (string) vs tabId (integer) named apart because Chrome bookmark ids are strings and a value-lenient codec would let a swap fail silently at the extension
- [Phase 11-01]: TabEl.bookmarked is TRI-STATE — reuses the icon/groupId serde+Dart shape but absence means UNKNOWN not false (the extension could not read the tree), so the phone renders NO star rather than an empty one (D-11 forbids misreporting). Shipped in BOTH codecs in 11-01 (Rule 3) because tabs/09-tabs-changed-bookmarked.json goes live immediately in the already-registered tabs harness — 11-02 task 1 step 5 and 11-07 task 1 step 3 are now no-ops
- [Phase 11-01]: SPEC section 15 accepted-residual ESCALATED — the ext leg now carries bookmark create+delete, the first ext-leg capability with a persistent non-self-healing effect (a closed tab is recoverable from history, a deleted bookmark is not and the phone has no undo); still accepted because the blast radius is bounded by never calling removeTree (D-14). Caps fixed at 500 nodes / 48-char titles / 56 KB measured in UTF-8 BYTES not UTF-16 code units
- [Phase 11-02]: Executors.bookmarks landed in the same commit as BookmarksRelay (not the plan's task 1): adding the field alone breaks server-windows' struct literal, so field + sole production implementor ship together and no intermediate commit is red
- [Phase 11-02]: ExtCmd drops Copy (String-carrying bm variants); the four bm frames are built from a LOCAL serde_json::json! envelope, not the phone-facing codec — run_ext already parses this leg with a local tolerant ExtFrame, so egress stays local and run_ext takes no dependency on the bm codec landing in 11-03
- [Phase 11-02]: reset_relay_watches is the ONE session-death cleanup point called at all three sites (Pitfall 2), mutation-verified: deleting the bm_tx reset fails ext_disconnect_resets_both_watches and only that test. bm.state takes the STRICT posture (parse failure keeps the last good tree) unlike the lenient groups array; nodeId/tabId asserted by TYPE (is_string/is_i64) because a swap decodes fine and fails silently at the extension
- [Phase ?]: [Phase 11-05]: Every frame budget in extension/background.js now measures UTF-8 BYTES via bytesOf (TextEncoder) — frame.length appears zero times. The shipped tabs icon-strip loop carried the same latent bug since 260716-oi2 and was fixed in place with its body, bound and exit condition byte-identical; a 900-node CJK+emoji tree the old measurement would have shipped at ~170 KB (session kill) now lands at 57172 bytes
- [Phase 11]: [Phase 11-05]: buildBmSnapshot walks BFS from tree[0].children (root 0 never emitted) because a DFS truncation can spend the whole budget inside the first root's first deep subtree, leaving Other/Mobile bookmarks unreachable — a direct D-08 violation. Truncation flags are applied INSIDE the serialize closure the drop loop re-runs, so the bytes measured are the bytes sent (the flags themselves cost ~18 B/node)
- [Phase 11]: [Phase 11-05]: capBmTitle trims a trailing lone high surrogate after the 48-char slice (Rule 2) — JSON.stringify of an emoji split by the cap emits a bare lone-surrogate escape, serde_json rejects it as a hard decode error, and 11-02 made bm.state ingest STRICT, so one such title would silently cost the phone its whole bookmark tree. The shipped 32-char group-title cap has the same hazard on the leniently-parsed groups array: logged in deferred-items.md, not fixed
- [Phase 11]: [Phase 11-05]: An unreadable bookmark tree sends NO bm.state frame (bmUrlSet=null), never an empty one — an empty snapshot tells the phone 'you have no bookmarks', while no frame leaves BookmarksState connected:false and the phone on the honest install hint. buildAndSendAll is the single debounce target and on-open push: one settling gap, one getTree walk, two frames, bookmarks first so the tab snapshot reads a fresh URL set
- [Phase 11-07]: Dart codec mirrors the bm.* family: BmNode/_bmList with String nodeId vs integer tabId enforced by _req<String>/_req<int>, so a type swap is a FormatException in BOTH languages instead of a silent extension-side failure (T-11-10). Six Bm*Msg classes + six decodeText arms; no package:collection, no url and no icon on BmNode
- [Phase 11-07]: group('bookmarks fixtures') hard-registered in the Dart harness and PROVEN real by a corrupt-to-RED-then-revert experiment (Pitfall 7) — a fixture family neither harness globs yields zero coverage and zero failures silently (the 07-02 input.blocked lesson). _bmList shipped with its consumers in task 2 because a caller-less private Dart helper is an unused_element warning that fails the analyze gate
- [Phase 11-03]: bm.list read arm ALWAYS emits truncated (Some(state.truncated)) mirroring the 1.5 always-emit-groups posture — older clients drop the unknown key per D-05, and a 1.6 client never disambiguates absent-because-old from absent-because-false
- [Phase 11-03]: Fixture-family registration proven, not assumed: corrupting 03-bm-open.json's expect turned codec_fixtures_bookmarks RED, then reverted (fixtures byte-clean). The pause gate was mutation-verified the same way — deleting the is_executor_bound bm entry failed exactly paused_drops_every_executor_bound_family_silently
- [Phase ?]: [Phase 11-06]: TabEl.bookmarked is a strict tri-state — one guarded assignment (bmUrlSet !== null && tab.url) emitting explicit true/false, key absent from EVERY tab when the tree was unreadable; raw exact URL equality with ZERO normalization because widening 'matches' widens bm.unstar's delete-every-match blast radius, not for fidelity
- [Phase ?]: [Phase 11-06]: bookmarksBarId() resolves via folderType === 'bookmarks-bar' (D-10), roots[0] then null fallback, and bm.star creates NOTHING on null rather than an unparented bookmark. server-core/tests/extension_guard.rs (comment-stripped, mutation-proven RED) makes removeTree, a hardcoded parentId '1', a url on a snapshot element, and a missing bookmarks permission each fail cargo test --workspace — CI-visible with zero new tooling since the repo has no JS runner
- [Phase 11]: 11-08: the D-12 optimistic star overlay reconciles on snapshot IDENTITY, not value equality — ConnectionService parks a brand-new TabsSnapshot per push, so identical() is the exact definition of 'new authoritative data'; value equality would keep a flip alive across a disagreeing snapshot, and clearing on every changes ping would defeat the optimism (volume/apps/clipboard ping too)
- [Phase 11]: 11-08: bookmark folder navigation lives on the notifier, never on the wire — D-06 gives drill-down no wire representation; keeping _currentFolderId and _backStack on BookmarksNotifier is what makes a pushed snapshot unable to move the user (D-04), and a vanished folder self-heals to the virtual root '0' silently
- [Phase ?]: [Phase 11-04]: ServerDeps.bookmarks push arm is authed-gated (bookmarks_alive && ctx.auth_state == AuthState::Authed) and is the ONLY bookmarks push site — mutation-proven by deleting the guard, watching the pre-auth silence assertion go RED, then restoring session.rs byte-identical
- [Phase ?]: [Phase 11-04]: the no-after-auth-snapshot assertion (T-11-12/D-03) needs a connection authed BEFORE the watch ever advances — on the pre-auth-silence connection the pending watch delivery is byte-indistinguishable from a snapshot, so the test opens authed_client() first and asserts silence there
- [Phase ?]: [Phase 11-04]: Harness.bm_tx stays a struct field despite a one-commit dead-code warning — a local _bm_tx in start_server() would drop at function exit, flip bookmarks_alive false and silently disable the branch under test
- [Phase 11-09]: Trailing bookmark lines (folder truncation + long-press hint) render only when connected — a delete hint under the install-hint card would advertise an affordance no visible row has
- [Phase 11-09]: D-14 is enforced as an AFFORDANCE gate, not a refusal: onLongPress is null (no visual tell, nothing to discover) unless BookmarksViewState.isDeletable — 11-08's shared predicate, deliberately not re-derived in the row
- [Phase 11-09]: confirmDestructive returns result == true so a barrier dismissal collapses into the cancel branch; kError appears in exactly one place in the phase (the confirm button fill)
- [Phase ?]: [Phase 11-10]: D-02 pixel-pinning is achieved by LAYOUT — the macro grid moved out of the swapped scroll region into a Column footer, so identical rects hold by construction and tester.getRect equality only witnesses it
- [Phase ?]: [Phase 11-10]: the D-03 bm.list prime fires from build off the segment about to render (guarded by _bmPrimed), not from onSelect — a segment restored from prefs is displayed with no tap, and an onSelect-only prime would never fire for that user
- [Phase ?]: [Phase 11-10]: bookmarksStateProvider is watched on BOTH segments so PopScope.canPop sees the folder depth in the frame the back gesture arrives; system back and the folder-bar button share one callback (haptic included)
- [Phase ?]: [Phase 11-11]: the tab-row star is tri-state — UNKNOWN (bookmarked == null) renders NO slot and NO semantics node, so an unreadable bookmark state can never be misreported as not-bookmarked
- [Phase ?]: [Phase 11-11]: an icon-only button whose onTap can be null needs Semantics(container: true, enabled: ...) — otherwise the disabled state has no a11y node at all and a screen reader hears nothing instead of a disabled button
- [Phase ?]: [Phase 11-11]: nested-recognizer isolation is asserted by observation (zero TabsActivateMsg on a star tap), never inferred from TapGestureRecognizer deadlines — and the deadline caveat that survives is press-and-hold, logged as deferred item 2
- [Phase 12]: release.ps1 probes /repos/<mirror> AND /releases/latest -- a lone latest 404 also means 'no releases yet', which would block the first-ever publish
- [Phase 12]: dry-run degrades environment-state refusals (dirty tree, unreachable mirror) to warnings; argument refusals (bad format, version at or below published latest) still throw
- [Phase 12]: the version bump is committed as chore(release): vX.Y.Z before tagging, so the tag names the source the artifacts were built from
- [Phase 12]: SPEC.md documents the protoVersion 1.8 update.* family but line 3 still declares 1.7 — 12-13 flips the version declaration atomically with SERVER_PROTO_VERSION so the spec never runs ahead of the code
- [Phase 12]: additionalProperties:false appears on exactly one payload in messages.schema.json (updateApply) — the schema-level restatement of D-14; D-05 ignore-unknown leniency stays permissive everywhere else
- [Phase 12]: protocol/fixtures/update/ mixes kinds: 01-09 are standard wire fixtures, 10-12 are special cases needing their own Rust and Dart loaders; README numbers them special cases 3/4/5 because 1 and 2 predate the phase
- [Phase 12]: 12-09: update.log truncates at 64 KiB on server startup (RESEARCH Open Question 4 resolved to truncate, not accept-unbounded) because the cmd helper cannot join tracing-appender rotation
- [Phase 12]: 12-09: the marker file is validated on read as untrusted input - a malformed target is discarded and an out-of-vocabulary error collapses to installer, because its contents travel to the phone via update.status
- [Phase 12]: 12-03: v1.5.0 is live on the public mirror -- three digest-bearing assets, anonymous 200, produced by tools/release.ps1. D-21 satisfied: every client-side plan now has a real release to check against.
- [Phase 12]: 12-03: the mirror repo was created bare, so gh release create returned 422 'Repository is empty' AFTER the tag was already pushed. Recovery seeded main with a README (53f310a), then ran the script's own printed gh line. release.ps1 has NO empty-mirror preflight and is non-idempotent once the tag is pushed -- 12-18 must not delete-and-rerun on a failed publish.
- [Phase 12]: 12-11: the update refusal ladder is three pure functions with zero I/O; a forged URL-shaped target refuses as stale with no network activity, and the ORDER is asserted by a test — SC6/T-12-01; is_valid_target is re-exported from download.rs and ordering uses server_core::version::compare_versions so there is only one version regex and one comparator
- [Phase 12]: 12-11: the update thread exits via the crate's existing std::process::exit path after a 750 ms flush grace, not a plumbed graceful shutdown — the detached helper is already counting down its bounded 30-poll wait; the grace window lets the session loop flush the restarting stage before the socket drops (D-17)
- [Phase 12]: 12-11: UpdateCmd::Check terminates on uptodate in BOTH outcomes, carrying the resolved version only when it is strictly newer — D-10 is a closed vocabulary with no available stage; version-present is therefore the available signal for 12-17, and inventing a stage would mean amending SPEC 7, the schema and both codecs first
- [Phase ?]: 12-12: ExtInfo is NOT a ServerDeps field — those fields exist to drive session push arms and ExtInfo drives none; WinUpdate takes its own Receiver clone in main.rs
- [Phase ?]: 12-12: the update.progress watch Sender is an Arc shared by the update thread AND WinUpdate, so a busy/downgrade/stale refusal reaches the phone without queueing behind an in-flight 5 MB download
- [Phase ?]: 12-14: UpdateRowState is one value-equal class over an exhaustive UpdateRowKind enum, not 15 sealed subclasses - the enum IS the UI-SPEC matrix, one operator== covers every variant, and 'actionable' being part of the value makes D-18 assertable
- [Phase ?]: 12-14: pcDidNotReturn (D-25) reads the EXISTING reconnect FSM attempt counter (>=5) instead of starting a timer, honouring D-17's ban on a second reconnect path

### Pending Todos

**0 pending** — `.planning/todos/pending/` is empty. (The previous "2 pending" line was stale: it
still listed an item that had already moved to `todos/done/`.)

- ~~Absolute pointer injection~~ — DONE in 04-01 (raw SendInput ABSOLUTE|VIRTUALDESK; in todos/done/)
- ~~Server supports ONE pairing per process run~~ — DONE; closed by Phase 7's persistent token
  storage exactly as predicted (in todos/done/). STATE listed it as pending until 2026-07-31.

- ~~`noPairing` reason is overloaded~~ — DONE 2026-07-31, quick task 260731-d45 (in todos/done/).
  **The todo's own fix sketch turned out to be stale and was NOT followed.** It proposed a new wire
  reason `noPinWindow` plus server, fixture and protocol changes; in fact the server already
  distinguishes the two cases (`session.rs:626` emits `noPairing` only from `PinOutcome::NoPairing`,
  `:645` emits `badMac` only from the token path). The collapse was purely the client's fallthrough
  arm, so the fix was Dart-copy-only with ZERO wire change: new `kNoPinWindowCopy` in
  `connection_copy.dart`, `badMac` left on `kRevokedExplanation`.
  **Still open, deliberately:** `reconnect_fsm.dart:333` continues to treat `noPairing` as revoked
  and fire `ClearTokenEffect` — arguably wrong for a PIN-window problem, but a D-05 behaviour change
  with its own test surface, and invisible to the user because a live `FailedEffect` outranks
  `explanation` in `_errorCopy`.

### Blockers/Concerns

- [quick 260731-euq — SHIP-TOGETHER]: protoVersion is now **1.7** (binary opcode `0x03`, zoom). The next release MUST ship the server exe alongside the APK. An old server does NOT break — `UnknownOpcode` is dropped and counted per SPEC §9 rule 4, the handshake compares only the major component, so the session stays up and move/scroll/click keep working — but **pinch silently does nothing** until the server is updated. Same rule as the phase-10 keymap growth, same reason.
- [quick 260731-euq — KNOWN EDGE, accepted]: a keyboard-panel sticky Ctrl held at the instant of a pinch is dropped by the zoom arm's `Direction::Release` without updating `dispatch/held.rs` bookkeeping. Self-corrects on the next modifier interaction; consulting held state from the input thread was out of scope.
- [quick 260731-euq — STALE, unfixed]: `app/packages/remote_protocol/lib/src/version.dart` still declares `protoVersion = '1.1'` (stale since phase 1), aliased into `clientProtoVersion` at `handshake_fsm.dart:23`, so the phone advertises `"1.1"` in `hello` while the server is at `"1.7"`. Harmless (major-only comparison) but wrong. Left unfixed deliberately — changing what the client advertises is a handshake-path behaviour change with its own test surface.

- [Phase 3 — RESOLVED 2026-07-08]: Android UDP broadcast reception CONFIRMED on the owner's Xiaomi 25080RABDI (Android 16 / HyperOS) at the 03-04 early on-device checkpoint — beacons listed within seconds, continuous 2s-interval reception, no MulticastLock failure, no OEM filtering. Cleartext ws:// also proven under the new network_security_config. See 03-04-SUMMARY.md.
- [Phase 6]: apps.focus foreground-lock workarounds and EnumWindows filtering flagged as highest-fiddliness area — research recommends a phase-level spike during planning
- [Phase 2 — RESOLVED 2026-07-08]: Hard transport gate PASSED on-device (p50 = 6ms, p95 = 10ms on real WiFi, all four PAD-05 criteria). TCP_NODELAY empirical verification also resolved — sub-6ms p50 under continuous load with no traffic-pattern-dependent hitching. UDP-channel reconsideration NOT triggered. See 02-04-GATE-RESULT.md.
- [Phase 05 — KNOWN LIMITATION]: The presenter "start show" macro sends F5, which starts the slideshow in the PowerPoint desktop app (the locked SC4 target — works) but reloads the page in a web browser. Google Slides' present shortcut is Ctrl+F5, so starting a show from web Google Slides is out of scope for v1. This is a known limitation, not a bug — PowerPoint desktop is the supported presenter surface. (from quick task 260711-huz)

### Quick Tasks Completed

| # | Description | Date | Commit | Directory |
|---|-------------|------|--------|-----------|
| 260708-ejx | Fix WR-01 — pairing window re-pair loop | 2026-07-08 | 54cfcff | [260708-ejx-fix-wr-01-pairing-window-re-pair-loop](./quick/260708-ejx-fix-wr-01-pairing-window-re-pair-loop/) |
| 260711-huz | Fix browser zoom-in keymap (Plus → '=') + doc Google Slides presenter limitation | 2026-07-11 | b27f617 | [260711-huz-fix-browser-zoom-in-keymap-plus-document](./quick/260711-huz-fix-browser-zoom-in-keymap-plus-document/) |
| 260716-kba | Add QR pairing scanner to Flutter app | 2026-07-16 | c294a8b | [260716-kba-add-qr-pairing-scanner-to-flutter-app](./quick/260716-kba-add-qr-pairing-scanner-to-flutter-app/) |
| 260716-lp5 | Distribution prep: appId rename, release signing scaffold, DISTRIBUTION.md | 2026-07-16 | a6eaf8a | [260716-lp5-distribution-prep-appid-rename-release-s](./quick/260716-lp5-distribution-prep-appid-rename-release-s/) |
| 260716-n9e | README rework: user-facing install guide | 2026-07-16 | 840ed84 | [260716-n9e-readme-rework-user-facing-install-sectio](./quick/260716-n9e-readme-rework-user-facing-install-sectio/) |
| 260716-ns1 | App branding: pointer logo, exe icon, Android launcher icons | 2026-07-16 | 1279415 | [260716-ns1-app-branding-pointer-logo-exe-icon-embed](./quick/260716-ns1-app-branding-pointer-logo-exe-icon-embed/) |
| 260716-oi2 | Browser tab list + switching via Chrome extension (Tab Bridge, protocol 1.4) | 2026-07-16 | 44629e4 | [260716-oi2-browser-tab-list-and-switching-via-chrom](./quick/260716-oi2-browser-tab-list-and-switching-via-chrom/) |
| 260716-sme | Tab-group visibility — view-only group headers in the phone tab list (protocol 1.5) | 2026-07-16 | a08d992 | [260716-sme-add-tab-group-visibility-to-browser-tabs](./quick/260716-sme-add-tab-group-visibility-to-browser-tabs/) |
| 260729-38z | Windows installer for the tray server (Inno Setup, shortcuts, autostart migration, single-instance guard) | 2026-07-29 | 9b10180 | [260729-38z-windows-installer-for-tray-server](./quick/260729-38z-windows-installer-for-tray-server/) |
| 260729-42w | App version identity (1.3.0+4) + Settings About row | 2026-07-29 | cf7005c | [260729-42w-app-version-identity-and-about-row](./quick/260729-42w-app-version-identity-and-about-row/) |
| 260729-4rg | No console window on launch + rolling file logging | 2026-07-29 | 564a744 | [260729-4rg-hide-console-window-and-add-file-logging](./quick/260729-4rg-hide-console-window-and-add-file-logging/) |
| 260729-58x | Tab-group visual hierarchy — grouped runs contained in a tinted `_GroupBlock` | 2026-07-29 | 088c53b | [260729-58x-fix-tab-group-visual-hierarchy-on-the-br](./quick/260729-58x-fix-tab-group-visual-hierarchy-on-the-br/) |
| 260730-bm0 | Ship v1.4.0-rc1 prerelease with phase 11 bookmarks artifacts (server 1.4.0, app 1.4.0+7, extension 1.2.0) | 2026-07-30 | 2fca0cb | [260730-bm0-ship-v1-4-0-rc1-prerelease-with-phase-11](./quick/260730-bm0-ship-v1-4-0-rc1-prerelease-with-phase-11/) |
| 260731-d45 | Close 2 deferred items: `noPairing` gets its own copy (client-only, zero wire change); group titles trimmed of lone surrogates via a shared `capTitle(s, max)` | 2026-07-31 | 0cd5104, 081df65 | [260731-d45-close-deferred-nopairing-copy-and-group-title-cap](./quick/260731-d45-close-deferred-nopairing-copy-and-group-title-cap/) |
| 260731-euq | Pinch-to-zoom: binary opcode `0x03` executed as a Ctrl-held wheel tick, spread-vs-translation gesture arbitration locked per episode (protoVersion 1.7) | 2026-07-31 | d2900af, 3a7b0c8 | [260731-euq-add-pinch-zoom-to-trackpad-binary-opcode](./quick/260731-euq-add-pinch-zoom-to-trackpad-binary-opcode/) |
| 260801-r8x | Stage `server/Cargo.lock` in the release commit — Codex P1 on PR #1: cargo rewrites the lockfile during the installer build, so leaving it out made the tag name a stale tree (`cargo build --locked` fails) and left dirt that tripped the next run's preflight | 2026-08-01 | 8b875b1 | [260801-r8x-stage-server-cargo-lock-in-the-release-c](./quick/260801-r8x-stage-server-cargo-lock-in-the-release-c/) |

## Deferred Items

Items acknowledged and carried forward from previous milestone close:

| Category | Item | Status | Deferred At |
|----------|------|--------|-------------|
| *(none)* | | | |

## Session Continuity

Last session: 2026-08-04T14:28:51.973Z
Stopped at: Completed 12-11-PLAN.md
Resume file: None
