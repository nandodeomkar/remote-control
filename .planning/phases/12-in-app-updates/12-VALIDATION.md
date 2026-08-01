---
phase: 12
slug: in-app-updates
status: approved
nyquist_compliant: true
wave_0_complete: false  # test scaffolds are planned into 12-02/12-04/12-06/12-07 (wave 1-2); flipped by the executor
created: 2026-08-01
---

# Phase 12 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.
> Derived from `12-RESEARCH.md` § Validation Architecture. Task IDs are filled
> in by the planner; the Ref column is the stable key until then.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | `cargo test` (Rust workspace at `server/`) + `flutter_test` (app) + `dart test` (pure `remote_protocol` package) |
| **Config file** | `server/Cargo.toml`; `app/remote_control/pubspec.yaml`; `app/packages/remote_protocol/pubspec.yaml` |
| **Quick run command** | Rust: `cargo test -p server-windows update` (from `server/`) · Dart: `flutter test test/update/` (from `app/remote_control`) |
| **Full suite command** | `cargo test --workspace` (from `server/`) + `flutter test` (from `app/remote_control`) + `dart test` (from `app/packages/remote_protocol`) |
| **Estimated runtime** | ~90 seconds for all three full suites |
| **Shared fixtures** | `protocol/fixtures/` — loaded by BOTH codecs. Per-language copies are forbidden (SPEC §14) |

No framework installation is needed — every runner already exists in the tree.

---

## Sampling Rate

- **After every task commit:** the touched side's quick command — `cargo test -p <crate> update` or `flutter test test/update/`
- **After every plan wave:** all three full suites (the fixture contract spans all three)
- **Before `/gsd-verify-work`:** all three full suites green, plus the on-device UAT plan
- **Max feedback latency:** ~30 seconds (quick command)

---

## Per-Task Verification Map

| Ref | Task ID | Behavior | Test Type | Automated Command | File Exists | Status |
|-----|---------|----------|-----------|-------------------|-------------|--------|
| D-09 | 12-04 T1/T3 · 12-05 T1/T2 | `update.*` round-trips byte-identically in Rust and Dart | codec/fixture | `cargo test -p server-core update_fixtures` / `dart test` in remote_protocol | ❌ W0 (`protocol/fixtures/update/`) | ⬜ pending |
| D-13 / SC8 | 12-13 T3 · 12-05 T2 | A 1.7 server answers `err {code:"unknownType"}` for `update.check` and keeps the session | integration | `cargo test -p server-core unknown_type` | ✅ extend existing §10 path | ⬜ pending |
| D-13 | 12-13 T1 | `update.check` / `update.apply` are dropped while paused | unit | `cargo test -p server-core pause_drops_update` | ❌ W0 | ⬜ pending |
| D-14 / SC6 | 12-13 T3 · 12-04 T3 · 12-11 T1 | A forged `update.apply` cannot make the server fetch an arbitrary URL | unit + structural | `cargo test -p server-core forged_apply_is_refused` · `cargo test -p server-core no_locator_fields_in_update_codec` | ❌ W0 | ⬜ pending |
| D-15 | 12-11 T1 | `downgrade` / `stale` / `busy` refusals, in that order | unit | `cargo test -p server-windows refusal_order` | ❌ W0 | ⬜ pending |
| D-15 | 12-06 T3 | sha256 mismatch deletes the file and never spawns the installer | unit | `cargo test -p server-windows verify_or_delete` | ❌ W0 | ⬜ pending |
| D-02 | 12-06 T2 · 12-10 T1 | Feed parse against a checked-in real API response | unit (both) | `cargo test -p server-windows feed_parse` / `flutter test test/update/release_feed_test.dart` | ❌ W0 (shared fixture) | ⬜ pending |
| D-02 | 12-06 T2 · 12-10 T1 | A `null` digest is a hard `checksum` refusal, never a skipped verification | unit | same fixture family, negative case | ❌ W0 | ⬜ pending |
| Specifics | 12-04 T3 · 12-07 T1 | Malformed version compares as unknown, never newer; Rust and Dart agree | unit (both, shared fixture) | `cargo test version_compare` / `flutter test test/update/version_test.dart` | ❌ W0 | ⬜ pending |
| D-07 | 12-07 T2 | 24h cache TTL — a stale cache re-checks, a fresh one does not | unit | `flutter test test/update/update_cache_test.dart` | ❌ W0 | ⬜ pending |
| D-16 | 12-09 T2 | Helper-script text generated correctly (PID, paths, target substituted) | unit (golden string) | `cargo test -p server-windows helper_script_text` | ❌ W0 | ⬜ pending |
| D-12 | 12-09 T1 · 12-11 T3 · 12-13 T3 | Marker write → read → report → delete lifecycle; absent marker is normal | unit | `cargo test -p server-windows marker_lifecycle` | ❌ W0 | ⬜ pending |
| D-18 | 12-16 T2 | `ext.reload` guard fires once per target version per run; no loop when the version does not change | unit | `cargo test -p server-core ext_reload_guard` | ❌ W0 | ⬜ pending |
| D-22 / D-23 | 12-15 T3 | Row-state matrix renders all states without breaking the screen | widget | `flutter test test/update/updates_screen_test.dart` | ❌ W0 | ⬜ pending |
| D-06 | 12-15 T3 · 12-17 T2 | Settings badge appears when anything is out of date, and clears | widget | `flutter test test/settings/settings_screen_test.dart` | ✅ extend existing | ⬜ pending |
| D-19 | 12-08 T1 | `apk_installer.dart` no-ops on `MissingPluginException` | unit | `flutter test test/update/apk_installer_test.dart` | ❌ W0 (mirror the `multicast_lock` test) | ⬜ pending |
| SC1 | 12-01 T2 | `release.ps1 -DryRun` bumps three files to the same version, exactly one line each | script test | `pwsh tools/release.ps1 -Version 9.9.9 -DryRun` + `git diff --stat` assertion | ❌ W0 | ⬜ pending |
| SC1 / D-04 | 12-18 T1 | Two releases published from the FINISHED tree, so `releases/latest` is strictly ahead of both installed clients | script + live API | `python` probe asserting `releases/latest` is `v1.6.1` and `releases/tags/v1.6.0` is complete, both with three `sha256:` digests | — needs the mirror, which 12-03 creates | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [x] `protocol/fixtures/update/` — the `update.*` family, plus `version-compare.json` and a real captured `releases/latest` response (including a `null`-digest negative case). Loaded by BOTH codecs
- [x] `server/server-windows/tests/` or `#[cfg(test)]` modules under `src/update/` — feed parse, verify-or-delete, refusal order, helper-script text, marker lifecycle
- [x] `app/remote_control/test/update/` — version compare, feed parse, cache TTL, row states, screen, installer channel
- [x] Extend the existing Rust + Dart fixture harness registration (the pattern established by 11-03 / 11-07) to include the `update` family on both sides
- [x] A genuinely side-effect-free `-DryRun` mode in `release.ps1`, so SC1 is testable without publishing

---

## Manual-Only Verifications

Every row below names the plan and task that OWNS it. All of them run against the real
`v1.6.0` / `v1.6.1` releases that `12-18` Task 1 publishes from the finished tree — they
are unreachable before that, because until a release postdates the implementation every
client resolves latest as at-or-below installed and reports "up to date" (D-21, D-26).

| Behavior | Ref | Owning plan | Why Manual | Test Instructions |
|----------|-----|-------------|------------|-------------------|
| Both clients brought onto the feature-complete build | SC2, SC3 | **12-18 T2** | Installing a setup exe on the owner's desktop and sideloading an APK onto a physical phone, then reading two GUIs | Install the `v1.6.0` assets (from the `v1.6.0` tag, not `latest`); confirm both surfaces report `1.6.0`, all three Updates rows name `1.6.1` as latest, the App row shows a download size before downloading, and both badge placements are lit. This is the documented one-time manual upgrade, not a defect |
| APK self-update end to end | SC4 | **12-18 T3** | Needs a physical Android device, the "install unknown apps" grant, and a real published release | From the phone's Updates screen tap Update app against the real `v1.6.1` release; confirm the missing-grant explainer, a declined system dialog that does NOT retry, sha256 verification, the system install dialog, and that the app relaunches on the new version. **Not an rc:** `releases/latest` excludes pre-releases and the client parser rejects `X.Y.Z-rcN` as unknown, so a pre-release is never offered (D-20, D-26) — the target must be a stable tag |
| PC self-update end to end | SC5 | **12-18 T4** (steps 1-3, 6) | Needs a real Windows install, a real signed setup exe, and the process to actually exit and come back | From the phone tap Update PC; confirm the server installs silently, relaunches, the phone reconnects on its EXISTING FSM (D-17) and the new version is reported on both surfaces, and that the marker is reported once and deleted. Then stand in for a non-zero installer exit by hand-writing the `ok:false` marker and confirm `lastUpdate` surfaces it once, in one of the seven fixed sentences, and clears (D-12, D-24) |
| Extension reload after a PC update | SC7 | **12-18 T4** (step 4) | Needs a running Chrome/Edge with the unpacked extension loaded | Leave the browser OPEN across the PC update; confirm the extension reports the new version without touching `chrome://extensions`, OR degrades to the documented restart-your-browser copy. Both are a pass; record which one happened rather than inferring it from the code. Repeat with the browser closed to isolate file locking |
| Chrome file-lock behavior during install | RESEARCH OQ-1 | **12-16 T1** (pre-hardening) · **12-18 T4** step 5 (post-hardening) | Only observable against a real Chrome holding the extension directory | 12-16 T1: run the setup exe over an install while Chrome has the extension loaded; observe whether the file replace is blocked and whether Inno aborts the WHOLE install. **Settle this before 12-16 T3 chooses the `.iss` change.** 12-18 T4 step 5: repeat after the `restartreplace` hardening and state plainly whether the outcome changed and whether the extension directory was replaced immediately or scheduled for next boot |

---

## Validation Sign-Off

- [x] All tasks have `<automated>` verify or Wave 0 dependencies — the exceptions are
      12-16 Task 1 (the Chrome file-lock observation) and 12-18 Tasks 2, 3 and 4 (the
      on-hardware end-to-end verifications). Each carries an explicit
      `<automated>MISSING</automated>` marker with a stated reason and each is listed
      under Manual-Only Verifications above
- [x] Every Manual-Only Verification names an owning plan and task, and an artifact to
      run against: `12-18` Task 1 publishes `v1.6.0` and `v1.6.1` from the finished tree
- [x] Sampling continuity: no 3 consecutive tasks without automated verify
- [x] Wave 0 covers all MISSING references (fixtures in 12-02; Rust test modules in 12-06/12-09/12-11;
      Dart test dir in 12-07/12-08/12-10; harness registration in 12-04/12-05; `-DryRun` in 12-01)
- [x] No watch-mode flags
- [x] Feedback latency < 30s
- [x] `nyquist_compliant: true` set in frontmatter

**Approval:** approved (planner, 2026-08-01) — task IDs filled from the 18-plan breakdown.
Revised 2026-08-01 after plan-check: the Manual-Only Verifications now name owning plans,
and `12-18` was added to publish the release they run against (BLOCKER 1).
