---
quick_id: 260811-wxr
phase: quick-260811-wxr
plan: 01
subsystem: app-client-networking
tags: [conn-04, beacon, discovery, riverpod, multicast-lock, audit-closure]
status: complete

requires:
  - "ConnectionService.attachBeacons (03-07)"
  - "ReconnectFsm.beaconSighted D-06 short-circuit (03-07)"
provides:
  - "beaconListenerProvider — the single app-scope BeaconListener"
  - "bindBeacons(ref) — app-start attachment of the beacon stream to the ConnectionService"
affects:
  - "DeviceListNotifier no longer constructs or stops a BeaconListener"
  - "Any future host of the app shell must override beaconListenerProvider in tests"

tech-stack:
  added: []
  patterns:
    - "app-start binding via a bindX(WidgetRef) free function, shaped like bindHapticsCache"
    - "app-scope Provider as sole owner of construction AND teardown for a native-resource holder"

key-files:
  created:
    - app/remote_control/test/beacon_binding_test.dart
    - .planning/quick/260811-wxr-close-v1-0-audit-gaps-conn-04-beacon-bin/deferred-items.md
  modified:
    - app/remote_control/lib/net/connection_providers.dart
    - app/remote_control/lib/main.dart
    - app/remote_control/lib/store/device_list_store.dart
    - app/remote_control/lib/net/beacon_listener.dart
    - app/remote_control/test/widget_test.dart
    - .planning/REQUIREMENTS.md
    - .planning/phases/02-end-to-end-cursor-spike/02-VERIFICATION.md

decisions:
  - "MOVE the listener to app scope rather than make attachBeacons idempotent — two BeaconListeners share one un-refcounted native MulticastLock, so the first stop() drops it for the other"
  - "App-scope multicast-lock holding is ACCEPTABLE: the lock was already held process-lifetime from the first Settings visit, so the delta is only the pre-first-visit window — which is exactly the window CONN-04 requires"
  - "Foreground gating DEFERRED, not built: start/stop have no generation guard, so an interleaved pair silently strands the listener"
  - "02-VERIFICATION.md marked SUPERSEDED with its body and frontmatter status preserved, rather than rewritten"
  - "v1.0-MILESTONE-AUDIT.md left byte-unchanged; closure recorded here and in STATE.md"

metrics:
  duration: ~35 min
  completed: 2026-08-12
  tasks: 3
  commits: 3

actuals:
  tokens: 21000
  tasks: 3
  commits: 3
---

# Quick 260811-wxr: Close v1.0 Audit Gaps (CONN-04 Beacon Binding) Summary

CONN-04's IP-change recovery was unreachable on a cold start that stayed on the
hub; it is now bound at app start by one shared `BeaconListener`, pinned by two
tests that were observed failing first.

## What Shipped

**The code fix (Task 1, commit `ab51477`).** `ConnectionService.attachBeacons`
had exactly one caller — `DeviceListNotifier.build()` — which runs only when a
screen watches `deviceListProvider` (the device list and Settings). `HubScreen`
watches neither. So a cold start that landed on the dashboard dialled the stored
host with **no beacon stream attached**, and the D-06 short-circuit
(`ReconnectFsm.beaconSighted`, which acts only in `ReconnectState.backoff`) could
never fire. A PC that changed IP stayed unreachable until the user happened to
open Settings.

Now: a new app-scope `beaconListenerProvider` constructs THE one listener and
owns its teardown, and a new `bindBeacons(ref)` — shaped exactly like
`bindHapticsCache` — hands its stream to the service from `main.dart`'s
`initState`, before the launch kick and before any screen exists.
`DeviceListNotifier` watches that provider instead of constructing its own
listener; it keeps only its own subscription, and no longer attaches to the
service or stops the listener.

**The bookkeeping (Task 2, commit `776e290`).** CONN-06 checked and traced
Complete; APPS-01/02/03 traced Complete (the UAT they waited on ran and passed);
UI-01 rewritten to name the floating trackpad bubble instead of the quick-bar
phase 08 deleted. `02-VERIFICATION.md` given a SUPERSEDED banner pointing at
`02-04-GATE-RESULT.md`.

**The deferrals (Task 3, commit `620b2a8`).** Five items, in `deferred-items.md`.

## The Observed RED

Both new tests were run and observed failing before the fix. Two rounds, because
the first red is only a compile error and a compile error proves nothing about
behavior:

**RED round 1 — pre-fix tree, no `lib/` edit at all.** The test file names a
provider that does not exist:

```
test/beacon_binding_test.dart:128:11: Error: Undefined name 'beaconListenerProvider'.
          beaconListenerProvider.overrideWithValue(beacons),
          ^^^^^^^^^^^^^^^^^^^^^^
test/beacon_binding_test.dart:164:11: Error: Undefined name 'beaconListenerProvider'.
00:00 +0 -1: Some tests failed.
```

**RED round 2 — provider added, but nothing binds it.** I then added ONLY
`beaconListenerProvider` (a pure factory: constructs and registers teardown,
starts nothing) with no `bindBeacons`, no `main.dart` call and no
`device_list_store` change, so the failure would be behavioral rather than a
missing symbol. Both tests failed on their assertions:

```
00:00 +0: beacons attach with no screen mounted
The following TestFailure was thrown running a test:
Expected: true
  Actual: <false>
the app-start binding must start the listener on a cold start that never
leaves the hub (CONN-04)
  ...test/beacon_binding_test.dart line 138

00:01 +0 -1: one shared listener feeds both consumers
Expected: an object with length of <1>
  Actual: []
   Which: has length of <0>
a device list that built its OWN BeaconListener would never see a beacon
emitted on the app-scope instance
  ...test/beacon_binding_test.dart line 190

00:01 +0 -2: Some tests failed.
```

That second round is the real regression proof: the app shell was mounted, the
device list was stubbed inert, and nothing started or subscribed to the
listener. Green after the fix: `00:01 +2: All tests passed!`

Neither test mounts the device-list screen. One that did would pass on the
pre-fix tree and prove nothing.

## The Multicast-Lock Finding, and Why App-Scope Is Acceptable

This was the load-bearing question — whether moving the listener to app scope
trades a correctness fix for a battery regression. It does not, and the reasoning
is worth keeping because the code comments used to claim the opposite.

**Two instances would have been a defect, not a style point.** `MainActivity.kt`
creates ONE native `WifiManager.MulticastLock` and calls
`setReferenceCounted(false)`. Two Dart `MulticastLock` clients therefore share
one un-refcounted native lock: **whichever listener stops first drops the lock
for the one still running.** And `attachBeacons` cancels and replaces its
subscription, so a second call is last-write-wins — the losing listener would
keep a live socket and its own lock client for nothing. Hence MOVE, not
make-idempotent.

**The hold window was already process-lifetime.** `stop()` was reached from
exactly one place: `DeviceListNotifier`'s `ref.onDispose`. There is no
`autoDispose` anywhere in `lib/`, and Riverpod 3 `NotifierProvider` is
keep-alive, so that disposal only ever fired at `ProviderScope` teardown — process
end. **The lock was therefore already held from the first device-list/Settings
visit until the process died.** The "screen-visible scoping" the comments in
`device_list_store.dart` and `beacon_listener.dart` described was an intent the
keep-alive provider never delivered.

**So the delta is only the pre-first-visit window** of a single process lifetime
— and that window is precisely the one CONN-04 requires a bound socket in. The
cost is intrinsic to the requirement, not incidental to the fix. Verdict:
**acceptable**, and the comments now state the real window as fact instead of
promising a scoping that never existed. The Pitfall 8 rule (never hold the lock
with no listener running) still holds and is still satisfied; only the scoping
claim was wrong.

## Audit Closure

`v1.0-MILESTONE-AUDIT.md` is **byte-unchanged** (`git diff --stat` against the
task base `d9162d2` is empty) — it is the point-in-time record of 2026-08-11.
Closure is recorded here instead.

**Closed by this task:**

| Audit gap | How |
|-----------|-----|
| CONN-04 partial — IP-change half screen-scoped and unreachable | Fixed in code, pinned by two regression tests (`ab51477`) |
| CONN-06 unchecked / traced Pending | Checked and traced Complete (`776e290`) |
| APPS-01/02/03 traced "Code complete; on-device UAT 06-07" | Traced Complete — the UAT ran and passed (`776e290`) |
| UI-01 promising a deleted trackpad quick-bar | Rewritten to the floating bubble that actually ships (`776e290`) |
| `02-VERIFICATION.md` stale at `gaps_found` / BLOCKED | SUPERSEDED banner pointing at `02-04-GATE-RESULT.md` (`776e290`) |

**Deliberately NOT closed** (all in `deferred-items.md`): multicast-lock
foreground gating (needs a generation counter first — see below), keymap
cross-language lockstep hardening, the four phases with no `VERIFICATION.md`
(06, 08, 09, 12), and Nyquist validation coverage (0 of 12 phases `validated`).

## Deviations from Plan

**1. [Rule 1 — Bug in my own test] Removed an unobservable teardown assertion**

- **Found during:** Task 1, first green run.
- **Issue:** I had added an assertion beyond the plan's brief — that unmounting
  the app fires the provider's `ref.onDispose` and thus `stop()`. It failed.
  The cause is not a bug in `lib/`: `overrideWithValue` replaces the provider
  **body outright**, so the real `ref.onDispose` registration never runs under
  any override. The assertion was testing the override mechanism, not the app.
- **Fix:** removed the assertion (and the now-dead `stopped` flag on the fake),
  leaving a comment at the site explaining why teardown is not assertable here —
  a test that re-registered `onDispose` inside the override would prove only the
  override. Teardown ownership is still real in production, where the provider
  body runs.
- **Files modified:** `app/remote_control/test/beacon_binding_test.dart`
- **Commit:** `ab51477` (removed before the commit)

**2. [Rule 3 — Method, not scope] An extra RED round beyond the plan**

The plan asked for the tests to be red on the pre-fix tree. Literally satisfied
by round 1 (a compile error), but a compile error is a weak regression proof, so
I added the intermediate provider-only step to get a behavioral red before
writing the binding. Strictly a superset of what was asked; no scope change.

**3. Plan step 3's "keep the idempotent `start()`" — kept, with a corrected
rationale in the comment.** The plan justified it as "so the screen works under
entry points that never ran the app-start binding". True, and kept. The comment
now says so explicitly rather than leaving the second `start()` looking
redundant.

Nothing else deviated. No architectural changes, no package installs, no
dependency edits (`pubspec.yaml` untouched, as the threat model required).

## Verification

| Gate | Result |
|------|--------|
| `flutter test test/beacon_binding_test.dart` | **2 passed** (both observed RED first) |
| `flutter test` | **865 passed / 0 failed** (baseline 863 + 2) |
| `flutter analyze` | **No issues found!** |
| `git diff --stat .planning/v1.0-MILESTONE-AUDIT.md` | **empty** |
| Commit count/order | 3: code → docs → deferred items |

The predicted 865 landed exactly. Note the suite reports `widget_test.dart: app
shell homes on the dashboard` on many lines — that is one test emitting repeated
progress lines, not duplicates; the final count is authoritative.

## Success Criteria

| SC | Status | Evidence |
|----|--------|----------|
| SC1 — cold start listens for beacons, proven by a test that fails without the fix and mounts no screen that could attach them | MET | Test 1; RED round 2 output above; device list stubbed inert |
| SC2 — exactly one `BeaconListener`, shared by both consumers | MET | Test 2 emits on the app-scope instance and the device list publishes the row |
| SC3 — hold window stated as fact in comments; verdict recorded with reasoning | MET | `beacon_listener.dart` + `device_list_store.dart` comments; section above |
| SC4 — 865/0 and analyze clean | MET | Both re-run after the final commit |
| SC5 — REQUIREMENTS.md describes shipped behavior, no unbuilt summon-bar | MET | CONN-06, APPS-01/02/03, UI-01; zero unchecked v1 boxes, zero Pending rows |
| SC6 — `02-VERIFICATION.md` superseded without a body rewrite; audit byte-unchanged | MET | Banner at line 12; frontmatter `gaps_found` preserved; audit diff empty |

## Known Stubs

None. No hardcoded empty values, placeholder text, TODO/FIXME markers, or
unwired components were introduced. No tests were skipped and every `<verify>`
in the plan was run.

## Threat Flags

None. Task 1 changes **when** the beacon socket is bound, not **what** it
accepts. The plan's register anticipated this: `beaconSighted` still ignores any
guid that is not the current target, still acts only in `ReconnectState.backoff`,
and a redirected dial still lands in challenge-response — a spoofed beacon can
redirect an attempt, never an authenticated session. `Beacon.tryParse` remains a
strict total parse. No new endpoint, auth path, file access or schema change.

## Follow-Ups

The one item a future task should not have to rediscover, from
`deferred-items.md` §1: **foreground-gating the multicast lock needs a generation
counter in `BeaconListener` first.** `stop()` sets `_running = false` and *then*
awaits `_sub.cancel()`; a `start()` interleaving inside that await sees
`_running == false`, acquires the lock and binds a fresh socket, and the
resuming `stop()` closes **that** socket and releases the lock — leaving a
listener that believes it is running with no socket and no lock, silently, with
nothing to retry. A pause/resume pair in quick succession is exactly how a user
produces it.

## Self-Check: PASSED

Created files verified present on disk:

- `FOUND: app/remote_control/test/beacon_binding_test.dart`
- `FOUND: .planning/quick/260811-wxr-close-v1-0-audit-gaps-conn-04-beacon-bin/deferred-items.md`

Commits verified in `git log`:

- `FOUND: ab51477` — fix(quick-260811-wxr-01): bind beacons at app start, one listener (CONN-04)
- `FOUND: 776e290` — docs(quick-260811-wxr-02): requirements describe what ships today
- `FOUND: 620b2a8` — docs(quick-260811-wxr-03): record what was deliberately not fixed
