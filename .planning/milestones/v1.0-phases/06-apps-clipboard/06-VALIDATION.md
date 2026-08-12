---
phase: 6
slug: apps-clipboard
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-07-11
---

# Phase 6 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.
> Sourced from 06-RESEARCH.md "Validation Architecture". House style: pure
> IO-free predicates/FSMs factored out of the OS threads + injected seams with
> unit tests; shared golden fixtures for the wire contract.
> Task/Plan/Wave IDs are TBD until the planner runs — this file is created at
> plan-phase step 5.5 (before planning) so the Nyquist map is locked to research.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework (Rust)** | built-in `#[cfg(test)]` + `#[tokio::test]`; core integration suite in `server-core/tests`, pure predicate units in `server-windows` |
| **Framework (Dart)** | `flutter_test` (widget + pure-logic) / `dart test` (remote_protocol fixtures) |
| **Config file** | none — Cargo workspace `server/` + `app/remote_control` + `app/packages/remote_protocol` cover both langs |
| **Quick run command** | `cd server && cargo test -p server-core` / `cd app/remote_control && flutter test test/<area>` |
| **Full suite command** | `cd server && cargo test --workspace` + `cd app/remote_control && flutter test` + `cd app/packages/remote_protocol && dart test` |
| **Estimated runtime** | ~30s (Dart) + ~20s (Rust) |

---

## Sampling Rate

- **After every task commit:** Run the touched side — `cargo test -p <crate>` (server task) or `flutter test test/<area>` (client task).
- **After every plan wave:** Run full `cargo test --workspace` + both Dart suites (`flutter test` app + `dart test` remote_protocol fixtures).
- **Before `/gsd-verify-work`:** Full suites green PLUS the on-device UAT checklist below (real focus/close/launch, live pushes, Android 10+ resume-sync, sensitive-clip skip).
- **Max feedback latency:** ~30 seconds (per-side quick run).

---

## Per-Task Verification Map

*(Requirement-level map from 06-RESEARCH.md; planner assigns final Task/Plan/Wave IDs.)*

| Task ID | Plan | Wave | Requirement | Threat Ref | Secure Behavior | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|------------|-----------------|-----------|-------------------|-------------|--------|
| TBD | TBD | TBD | APPS-01 | — | `apps.list` returns filtered windows; `apps.focus/close` route; `err{windowGone}` when executor returns `false` | integration (MockExecutors extended to return `bool`) | `cargo test -p server-core apps` | ⚠️ extend (router tests assert empty replies today) | ⬜ pending |
| TBD | TBD | TBD | APPS-01 | — | Alt-Tab filter predicate excludes cloaked/tool-window/ownerless (DWMWA_CLOAKED + style bits) | unit (pure predicate over synthetic style bits) | `cargo test -p server-windows apps_filter` | ❌ W0 (factor predicate out of thread loop) | ⬜ pending |
| TBD | TBD | TBD | APPS-01 | — | real focus (AttachThreadInput dance) + close on a live window | manual | on-device UAT (roadmap SC1) | manual | ⬜ pending |
| TBD | TBD | TBD | APPS-02 | — | `WindowInfo` optional `icon`+`path` fields round-trip; server version bumps to `1.2`; legacy (no fields) still decodes | contract fixture (Rust + Dart) | `cargo test -p server-core codec` / `dart test` (remote_protocol) | ❌ W0 (new `window_info/` fixtures) | ⬜ pending |
| TBD | TBD | TBD | APPS-02 | — | UWP window resolves `path=None` → favorites/pin disabled in UI (focus/close still offered) | widget (favorites control disabled when path null) | `flutter test test/apps` | ❌ W0 | ⬜ pending |
| TBD | TBD | TBD | APPS-02 | T-06 launch | `apps.launch{path}` routes; `err{launchFailed}` on bad path; path originates only from a server-enumerated/resolved window (no user-typed paths, D-01) | integration | `cargo test -p server-core apps` | ⚠️ extend | ⬜ pending |
| TBD | TBD | TBD | APPS-03 | T-06 pre-auth-leak | `apps.changed` pushed authed-only, once per real change, no pre-auth leak (clone `vol.changed` push test) | integration (drive watch, assert authed-gate) | `cargo test -p server-core apps_changed_push` | ❌ W0 | ⬜ pending |
| TBD | TBD | TBD | CLIP-01 | T-06 no-log | `clip.set` routes to executor; clipboard text never logged | integration | `cargo test -p server-core clip` | ✅ exists | ✅ green |
| TBD | TBD | TBD | CLIP-02 | T-06 no-log | `clip.get` → `clip.set` reply round-trip | integration | `cargo test -p server-core clip` | ✅ exists | ✅ green |
| TBD | TBD | TBD | CLIP-03 | T-06 echo | echo suppression: server won't re-push a value it just set (content fingerprint) | unit (pure fingerprint logic factored out of clip thread) | `cargo test -p server-windows clip_echo` | ❌ W0 | ⬜ pending |
| TBD | TBD | TBD | CLIP-03 | T-06 sensitive-skip | sensitive/large-clip skip predicate (>16 KiB OR `ExcludeClipboardContentFromMonitorProcessing` present → skip) | unit (pure: flags+len → skip?) | `cargo test -p server-windows clip_gate` | ❌ W0 | ⬜ pending |
| TBD | TBD | TBD | CLIP-03 | T-06 pre-auth-leak | `clip.changed` authed-gated push (clone `vol.changed` push test) | integration | `cargo test -p server-core clip_changed_push` | ❌ W0 | ⬜ pending |
| TBD | TBD | TBD | CLIP-03 | — | phone→PC syncs on app resume, not from background (Android 10+ restriction surfaced) | manual | on-device UAT (roadmap SC4) | manual | ⬜ pending |
| TBD | TBD | TBD | CLIP-04 | — | history persists across restart, collapses consecutive duplicates, tapping an entry pushes it to the **PC** clipboard | widget/unit (clip_store over fake `PrefsKv`) | `flutter test test/clipboard` | ❌ W0 | ⬜ pending |
| TBD | TBD | TBD | (client wiring) | — | Client parks Apps/Clip snapshot + `err` from `_onFrame` (clone `VolChanged` arm) | unit | `flutter test test/connection_service_test.dart` | ⚠️ extend | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky.*

---

## Wave 0 Requirements

- [ ] `server-windows` unit tests — Alt-Tab filter predicate, clip sensitive/large gate, clip echo fingerprint (factor pure functions out of the thread loops, exactly as `pct_from_scalar` was factored from the Phase-5 audio thread)
- [ ] `server-core` push tests — `apps.changed` / `clip.changed` (clone the `vol.changed` authed-gate + no-pre-auth-leak cases)
- [ ] New golden fixtures — `WindowInfo` with `icon`+`path` and legacy without (both Rust + Dart decode); extend server-version assertion to `1.2`
- [ ] Extend router tests — `focus/close/launch` now return `bool` → assert `err{windowGone|launchFailed}` on false; `MockExecutors` return true
- [ ] Extend `connection_service_test.dart` — Apps/Clip snapshot + `err` arms
- [ ] `flutter test` — `apps_store` (favorites, UWP non-pinnable) and `clip_store` (history dedupe/persist/reuse) over fake `PrefsKv`
- [ ] Framework install: none — existing infrastructure covers everything

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Real window focus + close | APPS-01 | Input injection / foreground-lock behavior is not CI-testable | On-device: tap a window row → it comes to foreground reliably; close → window closes, or a toast shows if it was already gone |
| Live window-list refresh | APPS-03 | Requires real windows opening/closing | Open/close apps on the PC → the phone list updates within one poll tick via `apps.changed` |
| Pinned-favorite launch | APPS-02 | Requires real `ShellExecuteW` against a resolved exe path | Long-press a running classic app → pin → close it → tap the favorite → it relaunches; confirm a UWP window shows as non-pinnable |
| Phone→PC clipboard resume-sync | CLIP-03 | Android 10+ blocks background clipboard reads; needs real lifecycle | Copy on phone while app backgrounded → nothing syncs; resume app → the copy reaches the PC; PC→phone stays live |
| Sensitive-clip skip | CLIP-03 | Requires a real password manager setting the exclusion format | With auto-sync ON, copy from KeePassXC / Credential Manager → confirm the secret does NOT sync to the phone |
| No sync loops (echo suppression) | CLIP-03 | Round-trip timing across two real devices | With auto-sync ON both directions, copy once → value appears on the other device and does NOT bounce back |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 30s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending (planner to map final task IDs, then flip `nyquist_compliant`)
