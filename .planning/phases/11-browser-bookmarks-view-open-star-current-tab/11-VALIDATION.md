---
phase: 11
slug: browser-bookmarks-view-open-star-current-tab
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-07-29
---

# Phase 11 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.
> Source: `11-RESEARCH.md` § Validation Architecture. The planner fills the
> Per-Task Verification Map once plan/task IDs exist.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework (Rust)** | `cargo test` (workspace), stock `#[test]` / `#[tokio::test]` |
| **Framework (Dart pkg)** | `package:test` — `app/packages/remote_protocol` |
| **Framework (Flutter app)** | `flutter_test` — `app/remote_control` |
| **Config file** | `server/Cargo.toml` (workspace) · `app/remote_control/pubspec.yaml` · `.github/workflows/ci.yml:13` |
| **Quick run command** | Narrowest for the layer touched — `cd server && cargo test -p server-core <filter>` / `cd app/remote_control && flutter test test/browser/` / `cd app/packages/remote_protocol && dart test` |
| **Full suite command** | `cd server && cargo test --workspace` **and** `cd app/remote_control && flutter test` **and** `cd app/packages/remote_protocol && dart test` |
| **Estimated runtime** | ~90 seconds (all three suites) |

**Note:** `dart test` for `remote_protocol` must run from that package directory — the
canonical-cwd assertion lives at `fixture_test.dart:24-31`. There is **no JS test runner**
in this repo, so `extension/background.js` has no unit layer; its coverage is relocated to
the server belt (`ext_relay.rs`) plus a console-paste smoke check in `extension/README.md`.

---

## Sampling Rate

- **After every task commit:** the narrowest command for the layer touched (see Quick run above)
- **After every plan wave:** all three full suites — this phase edits all three trees and the
  fixture contract spans two of them
- **Before `/gsd-verify-work`:** all three suites green + `flutter analyze` clean, then the
  on-device UAT below
- **Max feedback latency:** 30 seconds (quick run), 90 seconds (full suite)

---

## Per-Task Verification Map

*Planner fills this from the research's Requirements → Test Map once task IDs exist.*

| Task ID | Plan | Wave | Decision | Threat Ref | Secure Behavior | Test Type | Automated Command | File Exists | Status |
|---------|------|------|----------|------------|-----------------|-----------|-------------------|-------------|--------|
| 11-01-01 | 01 | 1 | Wire | — | — | fixture | `cargo test -p server-core codec_fixtures_bookmarks` | ❌ W0 | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

**Layer assignments carried from research (planner must preserve these):**

| Decision | Behavior | Layer & why |
|---|---|---|
| Wire | Rust↔Dart `bm.*` codec parity | **Shared golden fixtures** — only layer that proves byte-identity across two languages; per-language copies forbidden (SPEC §14) |
| Wire | `TabEl.bookmarked` tri-state (true/false/absent) | Fixtures, in the **existing** `tabs` family — no new harness fn needed |
| Wire | Missing required `BmEl` field is a hard decode error | Fixture (negative) — harnesses branch on `expect.error` (`fixtures.rs:118-128`, `fixture_test.dart:128-135`) |
| D-06 | `bm.state` → bookmarks watch; server belt truncates >500 nodes; malformed `nodes` degrades without discarding the frame | **`ext_relay.rs`** — SPEC §15 has no codec harness, so these socket tests *are* the ext-leg contract |
| Pitfall 2 | Ext disconnect resets **BOTH** watches | `ext_relay.rs` — only layer where real socket death is observable |
| Wire | `ExtCmd::BmOpen/BmStar/BmUnstar/BmRemove` forward correct frames + payload keys | `ext_relay.rs` — catches a `nodeId`/`tabId` swap |
| §11 | `bm.open/star/unstar/remove` dropped while paused; `bm.list` **answered** while paused; `bm.changed` from a client silently ignored | **`router.rs` in-module tests** |
| Push | `bm.changed` authed-gated (silence pre-auth, single push after auth) | **`integration.rs`** — T-06-01 privacy backstop |
| Version | `SERVER_PROTO_VERSION == "1.6"` reaches beacon + `versionMismatch` | `integration.rs:650` (assertion exists; beacon fixture value must be updated) |
| D-11 | Star renders filled/outline/absent for true/false/null; tap does not activate the tab; inert when `!enabled`; unstar is confirm-gated | **`browser_screen_test.dart`** — "the star never misreports" is only observable as a rendered glyph |
| D-12 | Optimistic flip then reconcile on **any** incoming snapshot | **`tabs_store_test.dart`** — pure store test, deterministic (no timers, no widgets) |
| D-14 | Folder with `count > 0` offers no delete; `count == 0` does | `browser_screen_test.dart` — the affordance gate is a rendering rule (Chrome's `kFolderNotEmptyError` is the unreachable runtime backstop) |
| D-01/D-02 | Segment swaps list region; macro grid at the **same rect** across both segments | `browser_screen_test.dart` — `tester.getRect()` before/after is the literal reading of D-02 |
| D-03 | `bm.list` NOT sent on open; sent on first Bookmarks switch; NOT re-sent on second | `browser_screen_test.dart` — fake service already records every `sendReliable` (`:100`) |
| D-04 | Opening a bookmark leaves segment + folder position unchanged | `browser_screen_test.dart` |
| D-05 | Drill-down + back stack over a flat node list; deleted current folder self-heals to root | **`bookmarks_store_test.dart`** — pure navigation logic |
| Regression | No new locked palette literal; no classic `Icons.*` | Existing global guards (`theme_tokens_guard_test.dart`, `icons_guard_test.dart`) ✅ |
| Regression | `removeTree` appears nowhere in `extension/` | **New grep gate** — cheapest enforcement of "subtree wipe structurally impossible" (D-14) |
| Regression | 7-action macro vocabulary + existing tab-section behavior untouched | `browser_screen_test.dart:195-570` — 24 existing tests stay green ✅ |

---

## Wave 0 Requirements

- [ ] `protocol/fixtures/bookmarks/` — 8 fixture files (shapes in RESEARCH § Wire Contract)
- [ ] `protocol/fixtures/tabs/09-tabs-changed-bookmarked.json` — tri-state `bookmarked`
- [ ] `server/server-core/tests/fixtures.rs` — `codec_fixtures_bookmarks()` registration (after `:184`)
- [ ] `app/packages/remote_protocol/test/fixture_test.dart` — `group('bookmarks fixtures')` registration (after `:202`)
- [ ] `server/server-core/tests/ext_relay.rs` — 5 new `bm` scenarios + both-watch reset assertion
- [ ] `server/server-core/src/dispatch/router.rs` — extend paused-drop and read-exemption tests
- [ ] `server/server-core/tests/integration.rs` — authed-gate `bm.changed` scenario
- [ ] `app/remote_control/test/browser/bookmarks_store_test.dart` — **NEW** (drill-down, back stack, self-heal)
- [ ] `app/remote_control/test/browser/tabs_store_test.dart` — extend with D-12 optimistic-overlay tests
- [ ] `app/remote_control/test/browser/browser_screen_test.dart` — extend with segment / D-02 rect / star / delete-gate tests
- [ ] A `removeTree` grep gate (shell/CI step or a Rust `#[test]` reading the file)
- [ ] `extension/README.md` — console-paste smoke check for the bookmark snapshot (following the `:44-65` shape)
- [ ] **Framework install: none needed** — all three runners already exist

---

## Manual-Only Verifications

Full 11-step on-device UAT in `11-RESEARCH.md` § Validation Architecture. Manual-only because
each needs a real Chrome, a real bookmark collection, or a real socket death.

| Behavior | Decision | Why Manual | Test Instructions |
|----------|----------|------------|-------------------|
| Permission reload outcome | Deployment risk A1 | Chrome's unpacked-extension re-approval behavior is not settleable from docs | **UAT-1** — edit `manifest.json` in the loaded folder, hit reload on `chrome://extensions`, observe the row. Either outcome passes; an **unrecorded** outcome fails. Result decides README wording. |
| All Chrome roots reachable; drill-down survives a push | D-08, D-05 | Needs a real bookmark tree | **UAT-2** |
| Real-collection frame stays under 56 KB; session survives | D-06, Pitfall 1 | Needs a real collection + SW console | **UAT-3** — read node count + byte size in the SW console; confirm no `[tab-bridge] disconnected` follows |
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

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 90s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
