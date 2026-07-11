---
phase: 06-apps-clipboard
plan: 01
subsystem: api
tags: [rust, protocol, serde, tokio-watch, websocket, apps]

# Dependency graph
requires:
  - phase: 05-control-center
    provides: "vol.changed authed-gated push seam (session.rs), VolumeState/ServerDeps watch template, volume golden-fixture family"
  - phase: 01-protocol-contract-server-core
    provides: "WindowInfo/Apps trait, apps.* codec message types, router family arms, golden-fixture harness"
provides:
  - "WindowInfo.icon + WindowInfo.path optional fields (protocol 1.2, base64 PNG icon + resolved exe path)"
  - "Apps::focus/close/launch -> bool trait signature (failed action -> err path)"
  - "Router err{windowGone} (focus/close) + err{launchFailed} (launch) on false"
  - "apps.changed authed-gated S->C push branch in session.rs (no after-auth snapshot)"
  - "ServerDeps.apps watch::Receiver<Vec<WindowInfo>> wired through listener + run_session + main.rs placeholder"
  - "window_info golden-fixture family (01-with-icon-path, 02-legacy) + codec_fixtures_window_info"
affects: [06-02 WinApps executor + apps thread, 06-03 Flutter Apps screen + Dart WindowInfo mirror]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Optional additive protocol field via #[serde(default, skip_serializing_if)] (mirrors Phase-5 1.1 vol amendment)"
    - "bool-returning executor action -> router err{code} surface"
    - "Authed-gated watch::changed() select! branch with NO after-auth snapshot (pull-on-open) for privacy-neutral state"

key-files:
  created:
    - "protocol/fixtures/window_info/01-with-icon-path.json"
    - "protocol/fixtures/window_info/02-legacy.json"
  modified:
    - "server/server-core/src/executors/mod.rs"
    - "server/server-core/src/transport/session.rs"
    - "server/server-core/src/transport/mod.rs"
    - "server/server-core/src/transport/listener.rs"
    - "server/server-core/src/dispatch/router.rs"
    - "server/server-core/src/codec/json.rs"
    - "server/server-core/src/executors/mock.rs"
    - "server/server-core/tests/fixtures.rs"
    - "server/server-core/tests/integration.rs"
    - "server/server-windows/src/executors/stubs.rs"
    - "server/server-windows/src/main.rs"
    - "protocol/fixtures/beacon/01-valid.json"

key-decisions:
  - "apps.changed has NO after-auth snapshot (unlike vol.changed) — client pulls the initial list via apps.list on screen open; the select! branch is the only apps-push site"
  - "err{windowGone|launchFailed} msg strings are operator-facing prose that never embed the HWND id or exe path (T-06-12)"
  - "SERVER_PROTO_VERSION 1.1 -> 1.2 is an additive minor bump; the shared beacon fixture proto was updated in lockstep (single source of truth, D-09)"

patterns-established:
  - "Additive optional protocol field: Option<String> + serde default/skip_serializing_if keeps legacy decode + Eq derive"
  - "bool executor return threaded into router err reply for user-facing toast (APPS-01/SC1)"
  - "Pre-auth pending watch change is delivered as the first post-auth push once the authed-gated branch enables (positive control for the privacy gate)"

requirements-completed: [APPS-01, APPS-02, APPS-03]

# Metrics
duration: 20min
completed: 2026-07-11
---

# Phase 6 Plan 01: Apps Contract Layer Summary

**Protocol 1.2 amendment: WindowInfo gains optional base64 icon + exe path, Apps trait actions return bool so failed focus/close/launch surface err{windowGone|launchFailed}, and an authed-gated apps.changed push seam feeds the live window list to authed sessions only.**

## Performance

- **Duration:** ~20 min
- **Completed:** 2026-07-11
- **Tasks:** 3
- **Files modified:** 12 (2 created, 10 modified)

## Accomplishments
- `WindowInfo` carries optional `icon` (base64 PNG 32x32) + `path` (resolved exe) via `#[serde(default, skip_serializing_if)]`; legacy windows still decode and re-encode without the keys. `SERVER_PROTO_VERSION` bumped 1.1 -> 1.2 (additive minor).
- `Apps::focus/close/launch` now return `bool`; the router emits `err{windowGone}` (focus/close) and `err{launchFailed}` (launch) on `false`, staying silent on success. Error prose never leaks the HWND id or exe path (T-06-12).
- `apps.changed` authed-gated `select!` branch in `session.rs` (identical `== AuthState::Authed` privacy backstop to the volume branch, T-06-01) with a dedicated `apps_changed_frame` helper and NO after-auth snapshot.
- `ServerDeps.apps` watch receiver threaded through `listener` -> `run_session`; `main.rs` holds a placeholder channel until the real Windows apps thread lands in 06-02.
- Golden fixtures `window_info/01-with-icon-path` + `02-legacy` and the `codec_fixtures_window_info` family test; two socket-level integration tests (`apps_no_push_preauth`, `apps_changed_after_auth`).

## Task Commits

Each task was committed atomically:

1. **Task 1: WindowInfo icon+path fields, protocol 1.2, golden fixtures** - `d15a683` (feat)
2. **Task 2: Apps trait returns bool; router emits err{windowGone|launchFailed}** - `0771a53` (feat)
3. **Task 3: apps.changed authed-gated push seam + ServerDeps wiring** - `e5ac93e` (feat)

## Files Created/Modified
- `server/server-core/src/executors/mod.rs` - WindowInfo icon/path fields; Apps trait bool returns
- `server/server-core/src/transport/session.rs` - SERVER_PROTO_VERSION 1.2; apps.changed branch + apps_changed_frame; apps run_session param
- `server/server-core/src/transport/mod.rs` - ServerDeps.apps watch receiver
- `server/server-core/src/transport/listener.rs` - destructure + thread the apps receiver
- `server/server-core/src/dispatch/router.rs` - err{windowGone|launchFailed} arms; FailingApps false-injection test
- `server/server-core/src/codec/json.rs` - round-trip tests construct WindowInfo with icon/path (set + None)
- `server/server-core/src/executors/mock.rs` - MockApps bool returns + icon/path None
- `server/server-core/tests/fixtures.rs` - codec_fixtures_window_info
- `server/server-core/tests/integration.rs` - apps_tx harness + apps push tests + helpers
- `server/server-windows/src/executors/stubs.rs` - StubApps bool returns
- `server/server-windows/src/main.rs` - placeholder apps watch channel
- `protocol/fixtures/window_info/01-with-icon-path.json` - golden: WindowInfo with icon+path + unknown-field drop
- `protocol/fixtures/window_info/02-legacy.json` - golden: legacy window, no optional keys
- `protocol/fixtures/beacon/01-valid.json` - proto bumped 1.1 -> 1.2 (deviation, see below)

## Decisions Made
- **No after-auth apps snapshot.** Volume sends an unconditional snapshot right after auth; apps does not — the client pulls the initial list via `apps.list` on screen open, so the authed-gated `select!` branch is the sole apps-push site. This keeps the transition lean and matches the RESEARCH Pattern-2 note.
- **Operator-facing err prose.** `err{windowGone|launchFailed}` messages are generic ("that window is no longer available", "could not launch the app") — never the HWND id or exe path (T-06-12), asserted in the router test.
- **Pending pre-auth change as positive control.** In `apps_no_push_preauth`, a window-list change made while unauthed produces silence, then is delivered as the first post-auth push once the authed-gated branch enables — proving the silence was the auth gate, not a dead channel (mirrors `vol_no_push_preauth`).

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] Bumped the shared beacon fixture proto 1.1 -> 1.2**
- **Found during:** Task 2 (running the full `--lib` suite after the version bump)
- **Issue:** `transport::beacon::tests::encode_beacon_matches_valid_fixture_wire` failed: the beacon encoder derives `proto` from `SERVER_PROTO_VERSION` (now "1.2"), but the shared fixture `protocol/fixtures/beacon/01-valid.json` still pinned "1.1".
- **Fix:** Updated both `wire.proto` and `expect.proto` in the fixture to "1.2". Verified the Dart consumer is safe: `net/beacon.dart` treats `proto` as a display/compat hint only (no version gating) and `beacon_test.dart` compares actual vs expected from the same fixture symmetrically, so it stays green. This is the same lockstep the Phase-5 1.0->1.1 bump required.
- **Files modified:** protocol/fixtures/beacon/01-valid.json
- **Verification:** `cargo test -p server-core --lib` -> 92 passed
- **Committed in:** `0771a53` (Task 2 commit)

---

**Total deviations:** 1 auto-fixed (1 blocking)
**Impact on plan:** The fixture bump is a mechanical consequence of the planned SERVER_PROTO_VERSION change (the beacon fixture is the single shared source of truth, D-09). No scope creep.

## Issues Encountered
- None beyond the beacon fixture lockstep documented above. All new + existing tests pass: 92 lib + 6 fixtures + 16 integration.

## Known Stubs
- `server-windows` `main.rs` holds a placeholder apps watch channel (`_apps_tx` default-empty) and `StubApps` returns `true`/empty — intentional per the plan; the real Windows apps thread + `WinApps` executor land in 06-02. This is a documented, plan-mandated interim seam, not a goal-blocking stub.

## Threat Flags
None — no new security surface beyond the plan's threat register. The apps.changed branch carries the `== AuthState::Authed` guard (T-06-01), err prose omits ids/paths (T-06-12), and no new crates were added (T-06-SC: accept).

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- Contract layer complete: 06-02 (WinApps executor + apps thread) can build the real `watch::Sender<Vec<WindowInfo>>` producer against `ServerDeps.apps` and return true OS outcomes from `focus/close/launch`; 06-03 (Flutter Apps screen) can mirror the icon/path fields against the two golden fixtures.
- No blockers. The Phase-6 flagged fiddliness (apps.focus foreground-lock, EnumWindows filtering) is entirely in the 06-02 Win32 body, not this contract slice.

---
*Phase: 06-apps-clipboard*
*Completed: 2026-07-11*

## Self-Check: PASSED

- Created files verified on disk: window_info/01-with-icon-path.json, window_info/02-legacy.json, 06-01-SUMMARY.md
- Task commits verified in git log: d15a683, 0771a53, e5ac93e
