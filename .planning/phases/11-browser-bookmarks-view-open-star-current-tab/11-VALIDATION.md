---
phase: 11
slug: browser-bookmarks-view-open-star-current-tab
status: planned
nyquist_compliant: true
wave_0_complete: false
created: 2026-07-29
planned: 2026-07-29
---

# Phase 11 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.
> Source: `11-RESEARCH.md` § Validation Architecture. The Per-Task Verification Map below was
> filled by the planner against the 12 plans / 35 tasks in `11-01-PLAN.md` … `11-12-PLAN.md`.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework (Rust)** | `cargo test` (workspace), stock `#[test]` / `#[tokio::test]` |
| **Framework (Dart pkg)** | `package:test` — `app/packages/remote_protocol` |
| **Framework (Flutter app)** | `flutter_test` — `app/remote_control` |
| **Framework (extension JS)** | none — no JS runner in the repo; coverage relocated to the server belt (`ext_relay.rs`), a Rust source guard (`extension_guard.rs`), `node --check` / `node -e` source assertions, and the on-device UAT |
| **Config file** | `server/Cargo.toml` (workspace) · `app/remote_control/pubspec.yaml` · `.github/workflows/ci.yml:13` |
| **Quick run command** | Narrowest for the layer touched — `cd server && cargo test -p server-core <filter>` / `cd app/remote_control && flutter test test/browser/` / `cd app/packages/remote_protocol && dart test` |
| **Full suite command** | `cd server && cargo test --workspace` **and** `cd app/remote_control && flutter test` **and** `cd app/packages/remote_protocol && dart test` |
| **Estimated runtime** | ~90 seconds (all three suites) |

**Note:** `dart test` for `remote_protocol` must run from that package directory — the
canonical-cwd assertion lives at `fixture_test.dart:24-31`.

---

## Sampling Rate

- **After every task commit:** the narrowest command for the layer touched (see Quick run above)
- **After every plan wave:** all three full suites — this phase edits all three trees and the
  fixture contract spans two of them
- **Before `/gsd-verify-work`:** all three suites green + `flutter analyze` clean, then the
  on-device UAT (plan 11-12)
- **Max feedback latency:** 30 seconds (quick run), 90 seconds (full suite)

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Decision | Threat Ref | Secure Behavior | Test Type | Automated Command | File Exists | Status |
|---------|------|------|----------|------------|-----------------|-----------|-------------------|-------------|--------|
| 11-01-01 | 01 | 1 | D-06/D-07/D-11/D-14 | T-11-03, T-11-08, T-11-04, T-11-07, T-11-09 | SPEC declares no `url` on BmEl; escalated ext-leg residual; caps fixed | source assertion + suite | `cd server && cargo test --workspace` | ✅ | ⬜ pending |
| 11-01-02 | 01 | 1 | — (version machinery) | — | Version literal single-sourced (D-09 precedent) | suite | `cd server && cargo test --workspace` | ✅ | ⬜ pending |
| 11-01-03 | 01 | 1 | D-06/D-07/D-08/D-11 | T-11-03 | Every fixture grep-asserted URL-free | fixture (inert until registered) | `node --input-type=module -e "…fixture structure check…"` | ❌ created here | ⬜ pending |
| 11-02-01 | 02 | 2 | D-07/D-11 | T-11-03, T-11-04 | `BmNode` has no url/icon; trait has no recursive delete | source assertion + suite | `cd server && cargo test --workspace` | ✅ | ⬜ pending |
| 11-02-02 | 02 | 2 | D-06/D-08 | T-11-07, T-11-10, T-11-02 | 500-node belt before watch send; opaque `nodeId` never interpreted | build + suite | `cd server && cargo build --workspace && cargo test --workspace` | ✅ | ⬜ pending |
| 11-02-03 | 02 | 2 | D-06 (Pitfall 2) | T-11-07, T-11-10 | Both-watch reset; `nodeId` string / `tabId` int frame keys | integration (socket) | `cd server && cargo test -p server-core --test ext_relay` | ❌ extended here | ⬜ pending |
| 11-03-01 | 03 | 3 | D-03/D-13/D-14 | T-11-09, T-11-10, T-11-02 | Four commands executor-bound; no new err codes | build + unit | `cd server && cargo build --workspace && cargo test -p server-core` | ✅ | ⬜ pending |
| 11-03-02 | 03 | 3 | D-06/D-11 | T-11-03 | Rust↔fixture parity, negatives throw | fixture | `cd server && cargo test -p server-core --test fixtures` | ❌ registered here | ⬜ pending |
| 11-03-03 | 03 | 3 | D-03/D-13/D-14 | T-11-09, T-11-10 | `bm.list` answered while paused; commands dropped; id types unswapped | unit | `cd server && cargo test -p server-core dispatch::router` | ❌ extended here | ⬜ pending |
| 11-04-01 | 04 | 4 | D-03/D-06 | T-11-01, T-11-02, T-11-12, T-11-07 | `== AuthState::Authed` guard; no after-auth snapshot; no logging | build + suite | `cd server && cargo build --workspace && cargo test --workspace` | ✅ | ⬜ pending |
| 11-04-02 | 04 | 4 | D-03 | T-11-01 | Pre-auth silence proven; test verified to go RED without the guard | integration | `cd server && cargo test -p server-core --test integration bm_changed_authed_gate` | ❌ created here | ⬜ pending |
| 11-05-01 | 05 | 2 | D-06 (Pitfall 1) | T-11-07, T-11-12 | Byte-accurate frame measurement in BOTH loops; permission scoped | source assertion | `node --check extension/background.js && node -e "…manifest check…"` | ❌ created here | ⬜ pending |
| 11-05-02 | 05 | 2 | D-11 | T-11-11, T-11-01 | Import-storm guard; `bmUrlSet = null` means omit, never `false` | source assertion | `node --check extension/background.js && node -e "…listener check…"` | ❌ created here | ⬜ pending |
| 11-05-03 | 05 | 2 | D-06/D-07/D-08 | T-11-03, T-11-02, T-11-07, T-11-04 | No url/icon on a node; counts-only log; BFS honours D-08; no `removeTree` | source assertion | `node --check extension/background.js && node -e "…snapshot check…"` | ❌ created here | ⬜ pending |
| 11-06-01 | 06 | 3 | D-11 | T-11-01, T-11-03, T-11-06 | Tri-state `bookmarked`; exact-URL, zero normalization | source assertion | `node --check extension/background.js && node -e "…bookmarked check…"` | ❌ created here | ⬜ pending |
| 11-06-02 | 06 | 3 | D-09/D-10/D-11/D-13/D-14 | T-11-10, T-11-04, T-11-05, T-11-06, T-11-02 | Fail-closed `bm.open`; `folderType` resolver; per-node catch on unstar | source assertion | `node --check extension/background.js && node -e "…commands check…"` | ❌ created here | ⬜ pending |
| 11-06-03 | 06 | 3 | D-10/D-14 | T-11-04, T-11-03 | `removeTree` banned, hardcoded bar id banned, no url on a bm element | guard (Rust, comment-stripped) | `cd server && cargo test -p server-core --test extension_guard` | ❌ created here | ⬜ pending |
| 11-07-01 | 07 | 2 | D-06/D-11 | T-11-03, T-11-01 | `BmNode` mirror has no url; tri-state preserved in ==/hashCode | analyze + suite | `cd app/packages/remote_protocol && dart analyze && dart test` | ✅ | ⬜ pending |
| 11-07-02 | 07 | 2 | D-11 | T-11-10, T-11-07 | `nodeId` String / `tabId` int enforced at decode | analyze + suite | `cd app/packages/remote_protocol && dart analyze && dart test` | ✅ | ⬜ pending |
| 11-07-03 | 07 | 2 | D-06/D-11 | T-11-03 | Dart↔Rust byte-identity over the SAME golden files | fixture | `cd app/packages/remote_protocol && dart test -N "bookmarks fixtures"` | ❌ registered here | ⬜ pending |
| 11-08-01 | 08 | 3 | D-06 | T-11-02 | No payload logging in either parking arm | analyze + widget suite | `cd app/remote_control && flutter analyze && flutter test test/browser/` | ✅ | ⬜ pending |
| 11-08-02 | 08 | 3 | D-04/D-05/D-08/D-14 | T-11-04, T-11-13 | Single-node remove only; deletable-child gate; titles never used as identity | unit (store) | `cd app/remote_control && flutter test test/browser/bookmarks_store_test.dart` | ❌ created here | ⬜ pending |
| 11-08-03 | 08 | 3 | D-11/D-12 | T-11-01, T-11-06 | Overlay clears on snapshot identity only; store opens no UI | unit (store) | `cd app/remote_control && flutter test test/browser/tabs_store_test.dart` | ❌ extended here | ⬜ pending |
| 11-09-01 | 09 | 4 | D-13 | T-11-06 | One confirm helper; `kError` confined to the confirm button | analyze + guards | `cd app/remote_control && flutter analyze && flutter test test/browser/ test/theme_tokens_guard_test.dart test/icons_guard_test.dart` | ✅ | ⬜ pending |
| 11-09-02 | 09 | 4 | D-05/D-06/D-07/D-13/D-14 | T-11-13, T-11-04, T-11-09, T-11-01 | Delete affordance gated; no swipe; gated is muted not red | analyze + guards | `cd app/remote_control && flutter analyze && flutter test test/theme_tokens_guard_test.dart test/icons_guard_test.dart` | ✅ | ⬜ pending |
| 11-09-03 | 09 | 4 | D-13/D-14 | T-11-04, T-11-06 | Non-empty folder and locked node offer NO long-press; Cancel sends nothing | widget | `cd app/remote_control && flutter test test/browser/bookmarks_section_test.dart` | ❌ created here | ⬜ pending |
| 11-10-01 | 10 | 5 | — (persistence) | T-11-14 | Corrupt prefs read degrades to Tabs; non-secret store | analyze + widget suite | `cd app/remote_control && flutter analyze && flutter test test/browser/` | ✅ | ⬜ pending |
| 11-10-02 | 10 | 5 | D-01/D-02/D-03/D-04 | T-11-09, T-11-12, T-11-13 | Gated commands inert; `bm.list` only when displayed | analyze + guards | `cd app/remote_control && flutter analyze && flutter test test/browser/ test/theme_tokens_guard_test.dart test/icons_guard_test.dart` | ✅ | ⬜ pending |
| 11-10-03 | 10 | 5 | D-01/D-02/D-03/D-04 | T-11-12 | Same-rect proof; prime-once proof; position preserved | widget | `cd app/remote_control && flutter test test/browser/browser_screen_test.dart` | ✅ extended here | ⬜ pending |
| 11-11-01 | 11 | 6 | D-09/D-11 | T-11-01, T-11-09 | UNKNOWN renders no slot; gated muted not red; semantics kept | analyze + guards | `cd app/remote_control && flutter analyze && flutter test test/browser/ test/theme_tokens_guard_test.dart test/icons_guard_test.dart` | ✅ | ⬜ pending |
| 11-11-02 | 11 | 6 | D-11/D-12 | T-11-06 | Unstar unreachable without the confirm; no toasts | analyze + widget suite | `cd app/remote_control && flutter analyze && flutter test test/browser/` | ✅ | ⬜ pending |
| 11-11-03 | 11 | 6 | D-09/D-11/D-12 | T-11-15, T-11-06, T-11-01, T-11-09 | Zero `TabsActivateMsg` on a star tap (arena isolation, A6) | widget | `cd app/remote_control && flutter test test/browser/browser_screen_test.dart` | ✅ extended here | ⬜ pending |
| 11-12-01 | 12 | 7 | — (phase gate) | — | All three suites + analyzer green before any device run | full suite | `cd server && cargo test --workspace && cd ../app/packages/remote_protocol && dart test && cd ../../remote_control && flutter analyze && flutter test` | ✅ | ⬜ pending |
| 11-12-02 | 12 | 7 | D-04/D-08/D-10/D-11/D-12/D-14 | T-11-07, T-11-04, T-11-01 | Real-collection frame size; real Chrome delete rejection path | **human-check (UAT-1…UAT-11)** | manual — recorded in `11-UAT.md` | ❌ created here | ⬜ pending |
| 11-12-03 | 12 | 7 | — (docs) | T-11-02, T-11-12 | Smoke check prints counts and sizes only; permission justified | source assertion | `node -e "…README + UAT-1 recorded check…"` | ✅ | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

**Sampling continuity check:** 35 tasks, exactly one (`11-12-02`) without an `<automated>` command,
and it is bracketed by automated tasks on both sides. No three consecutive tasks lack automated
verification.

**Layer assignments carried from research (preserved by the plan set):**

| Decision | Behavior | Layer & why | Owning task |
|---|---|---|---|
| Wire | Rust↔Dart `bm.*` codec parity | **Shared golden fixtures** — only layer that proves byte-identity across two languages; per-language copies forbidden (SPEC §14) | 11-01-03, 11-03-02, 11-07-03 |
| Wire | `TabEl.bookmarked` tri-state (true/false/absent) | Fixtures, in the **existing** `tabs` family — no new harness fn needed | 11-01-03 |
| Wire | Missing required `BmEl` field is a hard decode error | Fixture (negative) — harnesses branch on `expect.error` | 11-01-03, 11-03-02, 11-07-03 |
| D-06 | `bm.state` → bookmarks watch; server belt truncates >500; malformed `nodes` ignored | **`ext_relay.rs`** — SPEC §15 has no codec harness, so these socket tests *are* the ext-leg contract | 11-02-03 |
| Pitfall 2 | Ext disconnect resets **BOTH** watches | `ext_relay.rs` — only layer where real socket death is observable | 11-02-03 |
| Wire | `ExtCmd::BmOpen/BmStar/BmUnstar/BmRemove` forward correct frames + payload keys | `ext_relay.rs` — catches a `nodeId`/`tabId` swap | 11-02-03 |
| §11 | Four commands dropped while paused; `bm.list` **answered**; `bm.changed` from a client ignored | **`router.rs` in-module tests** | 11-03-03 |
| Push | `bm.changed` authed-gated (silence pre-auth, single push after auth) | **`integration.rs`** — T-06-01 privacy backstop | 11-04-02 |
| Version | `SERVER_PROTO_VERSION == "1.6"` reaches beacon + `versionMismatch` | `integration.rs:650` (assertion exists; beacon fixture value updated) | 11-01-02 |
| D-11 | Star renders filled/outline/absent; tap does not activate the tab; inert when `!enabled`; unstar confirm-gated | **`browser_screen_test.dart`** — "the star never misreports" is only observable as a rendered glyph | 11-11-03 |
| D-12 | Optimistic flip then reconcile on the next authoritative snapshot | **`tabs_store_test.dart`** — pure store test, deterministic | 11-08-03 (store) + 11-11-03 (widget) |
| D-14 | Folder with `count > 0` offers no delete; `count == 0` does | `bookmarks_section_test.dart` — the affordance gate is a rendering rule | 11-09-03 |
| D-01/D-02 | Segment swaps list region; macro grid at the **same rect** | `browser_screen_test.dart` — `tester.getRect()` before/after | 11-10-03 |
| D-03 | `bm.list` NOT sent on open; sent on first Bookmarks display; NOT re-sent | `browser_screen_test.dart` | 11-10-03 |
| D-04 | Opening a bookmark leaves segment + folder position unchanged | `browser_screen_test.dart` + `bookmarks_store_test.dart` | 11-08-02, 11-10-03 |
| D-05 | Drill-down + back stack; deleted current folder self-heals to root | **`bookmarks_store_test.dart`** — pure navigation logic | 11-08-02 |
| Regression | No new locked palette literal; no classic `Icons.*` | Existing global guards ✅ | 11-09-01/02, 11-10-02, 11-11-01 |
| Regression | `removeTree` appears nowhere in `extension/` | **New Rust source guard** `extension_guard.rs`, comment-stripped | 11-06-03 |
| Regression | 7-action macro vocabulary + existing tab-section behavior untouched | `browser_screen_test.dart` — 24 existing tests stay green ✅ | 11-10-03, 11-11-03 |

---

## Wave 0 Requirements

No separate Wave-0 plan is needed: **no test framework has to be installed** (all three runners
already exist), and every missing test artefact is created inside the plan that owns the behaviour
it proves. Each item below names its owning task.

- [ ] `protocol/fixtures/bookmarks/` — 9 fixture files → **11-01-03**
- [ ] `protocol/fixtures/tabs/09-tabs-changed-bookmarked.json` — tri-state `bookmarked` → **11-01-03**
- [ ] `server/server-core/tests/fixtures.rs` — `codec_fixtures_bookmarks()` registration → **11-03-02**
- [ ] `app/packages/remote_protocol/test/fixture_test.dart` — `group('bookmarks fixtures')` → **11-07-03**
- [ ] `server/server-core/tests/ext_relay.rs` — 6 new `bm` scenarios + both-watch reset → **11-02-03**
- [ ] `server/server-core/src/dispatch/router.rs` — extended paused-drop / read-exemption / direction tests → **11-03-03**
- [ ] `server/server-core/tests/integration.rs` — authed-gate `bm.changed` scenario → **11-04-02**
- [ ] `app/remote_control/test/browser/bookmarks_store_test.dart` — **NEW** → **11-08-02**
- [ ] `app/remote_control/test/browser/tabs_store_test.dart` — D-12 overlay tests → **11-08-03**
- [ ] `app/remote_control/test/browser/bookmarks_section_test.dart` — **NEW** → **11-09-03**
- [ ] `app/remote_control/test/browser/browser_screen_test.dart` — segment / D-02 rect / D-03 prime / star tests → **11-10-03**, **11-11-03**
- [ ] `server/server-core/tests/extension_guard.rs` — **NEW** `removeTree` / hardcoded-id / no-url / permission guards → **11-06-03**
- [ ] `extension/README.md` — bookmark-snapshot console smoke check → **11-12-03** (deliberately after UAT-1, so the wording matches observed behaviour)
- [x] **Framework install: none needed** — all three runners already exist

---

## Manual-Only Verifications

Full 11-step on-device UAT is owned by **plan 11-12, task 2** and recorded in `11-UAT.md`.
Manual-only because each needs a real Chrome, a real bookmark collection, or a real socket death.

| Behavior | Decision | Why Manual | Test Instructions |
|----------|----------|------------|-------------------|
| Permission reload outcome | Deployment risk A1 | Chrome's unpacked-extension re-approval behavior is not settleable from docs | **UAT-1** — edit `manifest.json` in the loaded folder, hit reload on `chrome://extensions`, observe the row. Either outcome passes; an **unrecorded** outcome fails. Result decides README wording (11-12-03). |
| All Chrome roots reachable; drill-down survives a push | D-08, D-05 | Needs a real bookmark tree | **UAT-2** |
| Real-collection frame stays under 56 KB; session survives; `getTree()` timing | D-06, Pitfall 1, A3 | Needs a real collection + SW console | **UAT-3** — record node count, byte size and `console.time` timing; confirm no `[tab-bridge] disconnected` follows |
| Three opens in a row keep segment + folder | D-04 | End-to-end | **UAT-4** |
| Star lands in the **bookmarks bar**, not Other bookmarks | D-10 | Verified in Chrome's own bookmark manager | **UAT-5** |
| Unstar removes **every** matching-URL entry, confirm-gated | D-11 | Needs a URL bookmarked in two places | **UAT-6** |
| Optimistic flip survives the next push | D-12 | Timing-sensitive on a real link | **UAT-7** |
| Non-empty folder offers no delete; empty one does | D-14 | Real Chrome enforcement path | **UAT-8** |
| Browser close flips **both** segments to the install hint | Pitfall 2 | Real socket death | **UAT-9** |
| Paused input: `bm.list` still loads, open does nothing | SPEC §11 | Needs the tray pause | **UAT-10** |
| Tab activate / long-press close / swipe close / all 7 macros unchanged | Regression | On-device feel | **UAT-11** |

---

## Validation Sign-Off

- [x] All tasks have `<automated>` verify or a documented human-check (35 tasks; 1 human-check)
- [x] Sampling continuity: no 3 consecutive tasks without automated verify
- [x] Wave 0 covers all MISSING references (each assigned to an owning task)
- [x] No watch-mode flags
- [x] Feedback latency < 90s
- [x] `nyquist_compliant: true` set in frontmatter

**Approval:** planner-signed 2026-07-29 (execution status tracked in the map above)
