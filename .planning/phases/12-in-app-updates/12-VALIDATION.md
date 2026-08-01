---
phase: 12
slug: in-app-updates
status: draft
nyquist_compliant: false
wave_0_complete: false
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
| D-09 | *(planner)* | `update.*` round-trips byte-identically in Rust and Dart | codec/fixture | `cargo test -p server-core update_fixtures` / `dart test` in remote_protocol | ❌ W0 (`protocol/fixtures/update/`) | ⬜ pending |
| D-13 / SC8 | *(planner)* | A 1.7 server answers `err {code:"unknownType"}` for `update.check` and keeps the session | integration | `cargo test -p server-core unknown_type` | ✅ extend existing §10 path | ⬜ pending |
| D-13 | *(planner)* | `update.check` / `update.apply` are dropped while paused | unit | `cargo test -p server-core pause_drops_update` | ❌ W0 | ⬜ pending |
| D-14 / SC6 | *(planner)* | A forged `update.apply` cannot make the server fetch an arbitrary URL | unit + structural | `cargo test -p server-core forged_apply_is_refused` · `cargo test -p server-core no_locator_fields_in_update_codec` | ❌ W0 | ⬜ pending |
| D-15 | *(planner)* | `downgrade` / `stale` / `busy` refusals, in that order | unit | `cargo test -p server-windows refusal_order` | ❌ W0 | ⬜ pending |
| D-15 | *(planner)* | sha256 mismatch deletes the file and never spawns the installer | unit | `cargo test -p server-windows verify_or_delete` | ❌ W0 | ⬜ pending |
| D-02 | *(planner)* | Feed parse against a checked-in real API response | unit (both) | `cargo test -p server-windows feed_parse` / `flutter test test/update/release_feed_test.dart` | ❌ W0 (shared fixture) | ⬜ pending |
| D-02 | *(planner)* | A `null` digest is a hard `checksum` refusal, never a skipped verification | unit | same fixture family, negative case | ❌ W0 | ⬜ pending |
| Specifics | *(planner)* | Malformed version compares as unknown, never newer; Rust and Dart agree | unit (both, shared fixture) | `cargo test version_compare` / `flutter test test/update/version_test.dart` | ❌ W0 | ⬜ pending |
| D-07 | *(planner)* | 24h cache TTL — a stale cache re-checks, a fresh one does not | unit | `flutter test test/update/update_cache_test.dart` | ❌ W0 | ⬜ pending |
| D-16 | *(planner)* | Helper-script text generated correctly (PID, paths, target substituted) | unit (golden string) | `cargo test -p server-windows helper_script_text` | ❌ W0 | ⬜ pending |
| D-12 | *(planner)* | Marker write → read → report → delete lifecycle; absent marker is normal | unit | `cargo test -p server-windows marker_lifecycle` | ❌ W0 | ⬜ pending |
| D-18 | *(planner)* | `ext.reload` guard fires once per target version per run; no loop when the version does not change | unit | `cargo test -p server-core ext_reload_guard` | ❌ W0 | ⬜ pending |
| D-22 / D-23 | *(planner)* | Row-state matrix renders all states without breaking the screen | widget | `flutter test test/update/updates_screen_test.dart` | ❌ W0 | ⬜ pending |
| D-06 | *(planner)* | Settings badge appears when anything is out of date, and clears | widget | `flutter test test/settings/settings_screen_test.dart` | ✅ extend existing | ⬜ pending |
| D-19 | *(planner)* | `apk_installer.dart` no-ops on `MissingPluginException` | unit | `flutter test test/update/apk_installer_test.dart` | ❌ W0 (mirror the `multicast_lock` test) | ⬜ pending |
| SC1 | *(planner)* | `release.ps1 -DryRun` bumps three files to the same version, exactly one line each | script test | `pwsh tools/release.ps1 -Version 9.9.9 -DryRun` + `git diff --stat` assertion | ❌ W0 | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [ ] `protocol/fixtures/update/` — the `update.*` family, plus `version-compare.json` and a real captured `releases/latest` response (including a `null`-digest negative case). Loaded by BOTH codecs
- [ ] `server/server-windows/tests/` or `#[cfg(test)]` modules under `src/update/` — feed parse, verify-or-delete, refusal order, helper-script text, marker lifecycle
- [ ] `app/remote_control/test/update/` — version compare, feed parse, cache TTL, row states, screen, installer channel
- [ ] Extend the existing Rust + Dart fixture harness registration (the pattern established by 11-03 / 11-07) to include the `update` family on both sides
- [ ] A genuinely side-effect-free `-DryRun` mode in `release.ps1`, so SC1 is testable without publishing

---

## Manual-Only Verifications

| Behavior | Ref | Why Manual | Test Instructions |
|----------|-----|------------|-------------------|
| APK self-update end to end | SC4 | Needs a physical Android device, the "install unknown apps" grant, and a real published release | Publish an rc release; from the phone's Updates screen tap Update app; confirm sha256 verification, the system install dialog, and that the app relaunches on the new version |
| PC self-update end to end | SC5 | Needs a real Windows install, a real signed setup exe, and the process to actually exit and come back | From the phone tap Update PC; confirm the server installs silently, relaunches, the phone reconnects, and the new version is reported. Then force a failure (corrupt the temp file) and confirm `lastUpdate` surfaces it |
| Extension reload after a PC update | SC7 | Needs a running Chrome/Edge with the unpacked extension loaded | Leave the browser OPEN across the PC update; confirm the extension reports the new version without touching `chrome://extensions`. Repeat with the browser closed to isolate file locking |
| Chrome file-lock behavior during install | RESEARCH OQ-1 | Only observable against a real Chrome holding the extension directory | Run the setup exe over an install while Chrome has the extension loaded; observe whether the file replace is blocked and whether Inno aborts the WHOLE install. **Settle this before planning the extension slice** |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 30s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
