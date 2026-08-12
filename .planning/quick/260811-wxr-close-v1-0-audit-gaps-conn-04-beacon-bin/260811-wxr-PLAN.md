---
quick_id: 260811-wxr
phase: quick-260811-wxr
plan: 01
type: execute
wave: 1
depends_on: []
files_modified:
  - app/remote_control/lib/net/connection_providers.dart
  - app/remote_control/lib/net/beacon_listener.dart
  - app/remote_control/lib/main.dart
  - app/remote_control/lib/store/device_list_store.dart
  - app/remote_control/test/beacon_binding_test.dart
  - app/remote_control/test/widget_test.dart
  - .planning/REQUIREMENTS.md
  - .planning/phases/02-end-to-end-cursor-spike/02-VERIFICATION.md
  - .planning/quick/260811-wxr-close-v1-0-audit-gaps-conn-04-beacon-bin/deferred-items.md
autonomous: true
requirements:
  - CONN-04
  - CONN-06
  - UI-01
  - APPS-01
  - APPS-02
  - APPS-03
user_setup: []

estimate:
  tokens: 80000
  raw_tokens: 40000
  tasks: 3
  confidence: low

must_haves:
  truths:
    - "On a cold start that lands on the hub and never opens Settings or the device list, the app is listening for beacons — so the D-06 short-circuit that rewrites a target's host/port during backoff is reachable, and a router-assigned IP change recovers itself (CONN-04)"
    - "There is exactly ONE BeaconListener instance in the running app. The device list and the ConnectionService consume the SAME instance's stream — proven by a test that emits on the shared instance and observes BOTH consumers react"
    - "The regression test FAILS on the pre-fix tree: it pumps the app shell with the device list stubbed out, so nothing screen-scoped can attach beacons on its behalf"
    - "The multicast-lock hold window is stated as a fact in the code, not as an aspiration: the comments that claim screen-visible scoping are corrected to describe what the keep-alive provider actually delivers"
    - "flutter analyze is clean and flutter test reports 865 passed / 0 failed (baseline 863 + 2 new)"
    - "REQUIREMENTS.md describes what ships TODAY: CONN-06 checked and traced Complete, APPS-01/02/03 traced Complete, and UI-01 naming the floating bubble rather than a quick-bar that no longer exists"
    - "02-VERIFICATION.md carries a SUPERSEDED banner pointing at 02-04-GATE-RESULT.md, with its body left intact as the honest record of what was true when written"
    - "v1.0-MILESTONE-AUDIT.md is byte-unchanged — the audit is a point-in-time record, and closure is recorded in this task's SUMMARY and in STATE.md instead"
  artifacts:
    - path: "app/remote_control/lib/net/connection_providers.dart"
      provides: "the app-scope beaconListenerProvider (single instance, owns teardown) plus the bindBeacons(ref) app-start binding that attaches the stream to the ConnectionService"
      contains: "beaconListenerProvider"
    - path: "app/remote_control/test/beacon_binding_test.dart"
      provides: "the CONN-04 regression proof: beacons attached with no screen mounted, and one shared listener feeding both consumers"
      contains: "beaconListenerProvider"
    - path: ".planning/quick/260811-wxr-close-v1-0-audit-gaps-conn-04-beacon-bin/deferred-items.md"
      provides: "the four explicitly out-of-scope items plus the multicast foreground-gating deferral, with the race that makes it non-trivial written down"
      contains: "keymap lockstep"
  key_links:
    - "main.dart initState -> bindBeacons(ref) -> connectionServiceProvider.attachBeacons(beaconListenerProvider.stream): the single wire that makes CONN-04's IP-change half reachable without a screen"
    - "beaconListenerProvider -> DeviceListNotifier.build(): the device list consumes the shared instance instead of constructing its own, so no second socket and no second MulticastLock client exist"
---

<objective>
Close the gaps the v1.0 milestone audit found on 2026-08-11: one real code fix
(CONN-04's IP-change half is screen-scoped and unreachable on a cold start that
never leaves the hub), plus the stale bookkeeping that audit catalogued.

Purpose: v1.1 builds directly on phases 8 and 10. Ship the correctness fix and
make the written record describe what actually ships before the milestone is
archived.

Output: an app-scope beacon binding with a regression test that fails without
it; a corrected REQUIREMENTS.md; a SUPERSEDED banner on the stale phase-02
verification; and a deferred-items.md recording what was deliberately not done.
</objective>

<execution_context>
@$HOME/.claude/gsd-core/workflows/execute-plan.md
@$HOME/.claude/gsd-core/templates/summary.md
</execution_context>

<context>
@.planning/v1.0-MILESTONE-AUDIT.md
@app/remote_control/lib/net/connection_providers.dart
@app/remote_control/lib/net/beacon_listener.dart
@app/remote_control/lib/store/device_list_store.dart
@app/remote_control/lib/main.dart
@app/remote_control/test/widget_test.dart

## Findings already established — do not re-derive

**The defect.** `ConnectionService.attachBeacons`
(`lib/net/connection_service.dart:766`) has exactly one caller:
`lib/store/device_list_store.dart:272`, inside `DeviceListNotifier.build()`.
That notifier builds only when `deviceListProvider` is watched — the device-list
screen (`:164`) and Settings (`:211`). `hub_screen.dart` watches neither.
`connection_providers.dart` constructs the service with no beacon stream. So a
cold start that lands on the hub dials the stored host (`main.dart:73-92`) and
the D-06 short-circuit (`reconnect_fsm.dart:281-295`, which only acts in
`ReconnectState.backoff`) can never fire.

**THE DECISION — MOVE, not make-idempotent.** Two `BeaconListener` instances is
not a style question, it is a defect, and this was checked in code rather than
assumed:

- `MainActivity.kt:29-30` creates ONE native `WifiManager.MulticastLock` and
  calls `setReferenceCounted(false)`. Two Dart `MulticastLock` clients therefore
  share one un-refcounted native lock: whichever listener stops FIRST drops the
  lock for the one still running.
- `attachBeacons` cancels and replaces its subscription, so a second call is
  last-write-wins — the losing listener keeps a live socket and its own lock
  client for nothing.

So: ONE instance, constructed by an app-scope provider, consumed by both the
service and the device list. `device_list_store.dart` stops constructing one,
stops calling `attachBeacons`, and stops calling `stop()`.

**THE MULTICAST-LOCK VERDICT — app-scope holding is ACCEPTABLE. Stated
explicitly, as required.** The reasoning, from the code:

- `BeaconListener.start()` acquires the lock, `stop()` releases it. `stop()` is
  reached from exactly one place today: `DeviceListNotifier`'s `ref.onDispose`.
- There is no `autoDispose` anywhere in `lib/` (verified by grep), and Riverpod 3
  `NotifierProvider` is keep-alive, so that `onDispose` fires only at
  `ProviderScope` teardown — process end.
- **Therefore the lock is ALREADY held from the first device-list/Settings visit
  until the process dies.** The "screen-visible scoping" the comments in
  `device_list_store.dart:10-12` / `:236-240` and `beacon_listener.dart:6-8`
  describe is an intent the keep-alive provider does not deliver.
- After the fix the window becomes app-start-to-process-end. **The delta is only
  the pre-first-visit window of a single process lifetime** — and that window is
  precisely the one CONN-04 requires a bound socket in. The cost is intrinsic to
  the requirement, not incidental.

Not acceptable would have obliged a different lifecycle; it is acceptable, so the
fix stands as scoped. Foreground-gating (stop on pause / start on resume via the
`AppLifecycleListener` that already exists in `main.dart:53`) is DEFERRED, not
built — see Task 3 for the interleave hazard that makes it more than two lines.

**Baseline:** `flutter test` 863 passed, `flutter analyze` clean, run from
`app/remote_control/`.
</context>

<tasks>

<task type="tracer" tdd="true">
  <name>Task 1: One app-scope beacon listener, wired before any screen exists</name>
  <files>app/remote_control/lib/net/connection_providers.dart, app/remote_control/lib/main.dart, app/remote_control/lib/store/device_list_store.dart, app/remote_control/lib/net/beacon_listener.dart, app/remote_control/test/beacon_binding_test.dart, app/remote_control/test/widget_test.dart</files>
  <behavior>
    Write `test/beacon_binding_test.dart` FIRST; both tests must be red on the
    current tree before any lib/ edit.

    - Test 1 — "beacons attach with no screen mounted": build a `ProviderScope`
      overriding `beaconListenerProvider` with a fake, `deviceStoreProvider` and
      `connectionServiceProvider` with the inert fakes `widget_test.dart` already
      defines, and `deviceListProvider` with an empty stub. Pump
      `RemoteControlApp`. Assert the fake was `start()`ed AND that something
      subscribed to its stream. Nothing screen-scoped can have done either — the
      device list is stubbed to a notifier with no side effects. RED today.
    - Test 2 — "one shared listener feeds both consumers": same container WITHOUT
      the `deviceListProvider` stub, so the real `DeviceListNotifier` builds.
      Emit one `Beacon` on the fake and assert the device list published a row
      for it. That is the no-second-socket proof: a notifier that built its own
      listener would never see this beacon. RED today.

    The fake is `class _FakeBeaconListener implements BeaconListener` — from
    another library only the three public members (`stream`, `start`, `stop`)
    are required, so no `noSuchMethod` and no `dart:io` faking is needed. Back it
    with a broadcast `StreamController<Beacon>` whose `onListen` records that a
    subscriber arrived, plus a `started` flag and an `emit(Beacon)` helper.
    `Beacon` has a public const constructor (`lib/net/beacon.dart:28`).

    Do NOT write a test that mounts the device-list screen — it would pass on the
    pre-fix tree and prove nothing.
  </behavior>
  <action>
Read all six files before editing. Then, once both tests are red:

1. `lib/net/connection_providers.dart` — add `beaconListenerProvider`, a
   `Provider<BeaconListener>` returning ONE instance with
   `ref.onDispose(() => unawaited(listener.stop()))`. The provider is a pure
   factory: it constructs and registers teardown, and starts nothing. Then add
   `void bindBeacons(WidgetRef ref)`, shaped exactly like
   `bindHapticsCache(ref)` in `lib/settings/haptics.dart:110`: read the listener
   and the service, hand the listener's stream to the service, and start the
   listener with the same swallow-and-continue error handling
   `device_list_store.dart:274-277` uses today (a bind failure is retryable OEM
   noise and must never crash the launch path). Document on the provider that it
   is the single owner of construction and teardown, that `start()` is
   idempotent by contract and may be called by any consumer that needs beacons
   flowing, and that a second instance is forbidden because the native multicast
   lock is not reference counted.

2. `lib/main.dart` — call `bindBeacons(ref);` in `initState`, immediately after
   `bindHapticsCache(ref);` and before the `AppLifecycleListener`. Extend the
   library doc comment: discovery beacons are now bound at app start, so the
   D-06 short-circuit is reachable on a cold start that never leaves the hub.
   This is the whole CONN-04 fix — one binding, no new machinery.

3. `lib/store/device_list_store.dart` — `DeviceListNotifier.build()` obtains the
   listener from `ref.watch(beaconListenerProvider)` instead of constructing one.
   Keep its own stream subscription (the device list still merges beacons) and
   keep the idempotent `start()` so the screen works under entry points that
   never ran the app-start binding. Remove the service-attachment line at `:272`
   and its comment — that responsibility moved to `connection_providers.dart`.
   Remove the `stop()` from `ref.onDispose` and drop the now-unused `_listener`
   field; the provider owns teardown. Keep cancelling its OWN subscription on
   dispose. Losing the rebuild-retries-the-bind property is immaterial: with no
   `autoDispose` in `lib/`, that rebuild never happens.

4. Comment truth pass, in `device_list_store.dart` (the library doc at `:10-12`,
   the class doc at `:236-240`) and `beacon_listener.dart` (the library doc at
   `:6-8`). Each currently promises the lock is scoped to a visible screen.
   Replace those clauses with what is true: the lock is held from app start
   until `ProviderScope` teardown, because the beacon listener is app-scope and
   nothing in `lib/` is `autoDispose`; a bound socket in exactly that window is
   what CONN-04's IP-change recovery requires. Do not delete the Pitfall 8
   reference — the rule (never hold it with no listener running) still holds and
   is still satisfied; only the scoping claim was wrong.

5. `test/widget_test.dart` — the existing shell smoke test now reaches
   `bindBeacons`, which would attempt a real UDP bind. Add a
   `beaconListenerProvider` override using the same fake, and extend the header
   comment (which already lists the inert seams) to name it. Change nothing else
   about that test.

Run the two new tests red-to-green, then the full suite.
  </action>
  <verify>
    <automated>cd app/remote_control &amp;&amp; flutter test test/beacon_binding_test.dart</automated>
    <automated>cd app/remote_control &amp;&amp; flutter test</automated>
    <automated>cd app/remote_control &amp;&amp; flutter analyze</automated>
  </verify>
  <done>
    Both new tests were observed RED before the lib/ edits and GREEN after (state
    the red output in the SUMMARY — an unobserved red is not a regression test).
    `flutter test` reports 865 passed / 0 failed. `flutter analyze` reports no
    issues. One commit, code only.
  </done>
</task>

<task type="auto">
  <name>Task 2: Make the written requirements describe what ships today</name>
  <files>.planning/REQUIREMENTS.md, .planning/phases/02-end-to-end-cursor-spike/02-VERIFICATION.md</files>
  <action>
Documentation only — every feature below is already delivered and was verified
against the live codebase by the audit's integration check. Commit separately
from Task 1.

In `.planning/REQUIREMENTS.md`:

- Line 15, CONN-06: flip the unchecked box to checked. Delivered by
  `lib/hud/latency_probe.dart` feeding `lib/widgets/connection_header.dart:44`,
  mounted on 10 screens.
- Line 120, the CONN-06 traceability row: `Pending` becomes `Complete`.
- Lines 136-138, APPS-01 / APPS-02 / APPS-03: replace each "Code complete (…);
  on-device UAT 06-07" status with `Complete`. Preserve each row's parenthetical
  detail if it reads naturally alongside `Complete`; the UAT it was waiting on
  ran and passed (`.planning/phases/06-apps-clipboard/06-UAT.md` carries
  `status: complete`, SC1 pass).
- Line 76, UI-01: the requirement text names a trackpad quick-bar that no longer
  exists — phase 08 decision D8-06 deleted it and the floating bubble replaced
  it; every surviving mention in `lib/` is a past-tense comment about the
  removal. Rewrite the text to: **Dashboard home with tool tiles plus a
  persistent floating trackpad bubble on every tool screen.** Keep the `[x]` and
  keep the `**UI-01**:` prefix formatting of its neighbours. Word it for what
  ships TODAY: the v1.1 summon-bar design
  (`.planning/notes/summon-bar-trackpad-keyboard.md`) is NOT BUILT and must not
  appear in a requirement. Leave the UI-01 traceability row at line 151 alone —
  it already reads Complete.
- Before finishing, grep `.planning/REQUIREMENTS.md` for any OTHER surviving
  mention of the removed quick-bar. Change only UI-01's line; if any other line
  carries the same stale claim, leave it and record it in `deferred-items.md`
  (Task 3) — it is outside this task's brief.

In `.planning/phases/02-end-to-end-cursor-spike/02-VERIFICATION.md`:

Add a SUPERSEDED banner at the TOP of the body, immediately after the closing
frontmatter delimiter and before the `# Phase 02 Verification` heading, in the
blockquote style this project already uses for resolved records — copy the shape
of the RESOLVED banner at the top of
`.planning/todos/done/2026-08-05-pc-self-update-helper-wedges-before-setup-runs.md`
(a `> ##` heading line, then blockquoted prose). The banner must say: this
verification was written before plan 02-03 built the client half it reports as
missing (the handshake FSM, the trackpad screen, the latency HUD); 02-04 then ran
the hard gate and it PASSED at p50 6ms / p95 10ms on real WiFi, recorded in
`02-04-GATE-RESULT.md` and in the ROADMAP's Phase 2 line; the verification was
never re-run. Point the reader at `02-04-GATE-RESULT.md` for the outcome.

Do NOT rewrite the body — it is the honest record of what was true on
2026-07-08, and this project keeps such history and marks it rather than deleting
it. Leave the frontmatter `status: gaps_found` value ALONE, and say so in the
banner: the frontmatter is preserved deliberately so the file still reads as the
artifact it was, and the banner is the correction.

Do NOT edit `.planning/v1.0-MILESTONE-AUDIT.md`. It is the point-in-time record
of 2026-08-11 and its findings stay as written; closure is recorded in this
task's SUMMARY and in STATE.md.
  </action>
  <verify>
    <automated>grep -n "CONN-06" .planning/REQUIREMENTS.md</automated>
    <automated>grep -n "floating trackpad bubble" .planning/REQUIREMENTS.md</automated>
    <automated>grep -c "Complete" .planning/REQUIREMENTS.md</automated>
    <automated>grep -n "SUPERSEDED" .planning/phases/02-end-to-end-cursor-spike/02-VERIFICATION.md</automated>
    <automated>git diff --stat .planning/v1.0-MILESTONE-AUDIT.md</automated>
  </verify>
  <done>
    CONN-06 reads checked in the list and Complete in the traceability table;
    APPS-01/02/03 all read Complete; UI-01 names the floating trackpad bubble and
    no longer promises a quick-bar. `02-VERIFICATION.md` opens with a SUPERSEDED
    banner naming `02-04-GATE-RESULT.md`, its body and its frontmatter status
    untouched. `git diff --stat` on the audit file is empty. One commit, docs
    only.
  </done>
</task>

<task type="auto">
  <name>Task 3: Record what was deliberately not fixed</name>
  <files>.planning/quick/260811-wxr-close-v1-0-audit-gaps-conn-04-beacon-bin/deferred-items.md</files>
  <action>
Create `deferred-items.md` in this quick task's directory, following the format
of `.planning/quick/260809-ipc-unify-the-trackpad-docked-keyboard-panel/deferred-items.md`
(title line, a short preamble stating these are logged and not fixed, then one
numbered section per item with what it is, why it is not this task's, and where
it belongs). Record five items:

1. **Multicast-lock foreground gating.** The listener is now app-scope, so the
   lock is held from app start until `ProviderScope` teardown. Task 1's verdict
   is that this is acceptable (it is a strict superset of today's already
   process-lifetime hold by only the pre-first-visit window, and CONN-04 needs a
   bound socket in exactly that window). Gating it on foreground via the
   `AppLifecycleListener` already present at `main.dart:53` would be a real
   improvement and looks like two lines — it is not. `BeaconListener.start` /
   `stop` have no generation guard: `stop()` sets `_running = false` and then
   AWAITS `_sub.cancel()`, so a `start()` that interleaves acquires the lock and
   binds a fresh socket, and the resuming `stop()` then closes THAT socket and
   releases the lock, leaving a listener that believes it is running and is not.
   Doing this safely needs a generation counter in `BeaconListener`. New
   machinery, its own task.
2. **Keymap lockstep hardening.** `CLIENT_KEY_CODES`
   (`server/server-windows/src/executors/keymap.rs:44-63`) and `kClientKeyCodes`
   (`app/remote_control/lib/keyboard/key_rows.dart:45-64`) are 57/57 with an
   empty set difference in both directions today, but there is no automated
   cross-language gate the way the fixture tree has one. A one-sided edit would
   fail no build and surface as a dead key. That is a new test, not a gap
   closure.
3. **The four phases with no VERIFICATION.md** — 06, 08, 09, 12. Outcome evidence
   exists for all four in other artifacts (`06-UAT.md`, `08-06-SUMMARY.md`,
   `09-08-SUMMARY.md`, and the 2026-08-08 hardware observation). Back-filling
   verification documents for closed phases is its own decision.
4. **Nyquist coverage.** 0 of 12 phases carry `status: validated`. That is a
   `/gsd-validate-phase` job, not this one.
5. Any additional stale quick-bar mention Task 2 found in `REQUIREMENTS.md`
   outside UI-01's line. If Task 2 found none, say so in one line rather than
   dropping the item.

Anything from the v1.1 summon-bar design stays out entirely — it is unbuilt
scope and does not belong in a deferred list for this task.
  </action>
  <verify>
    <automated>test -f .planning/quick/260811-wxr-close-v1-0-audit-gaps-conn-04-beacon-bin/deferred-items.md &amp;&amp; grep -c "^## " .planning/quick/260811-wxr-close-v1-0-audit-gaps-conn-04-beacon-bin/deferred-items.md</automated>
    <automated>grep -n "keymap lockstep\|Keymap lockstep" .planning/quick/260811-wxr-close-v1-0-audit-gaps-conn-04-beacon-bin/deferred-items.md</automated>
  </verify>
  <done>
    `deferred-items.md` exists with five numbered sections, each naming what it
    is, why it is out of scope, and where it belongs. The foreground-gating entry
    records the start/stop interleave hazard concretely enough that a future
    implementer does not rediscover it. One commit.
  </done>
</task>

</tasks>

<threat_model>
## Trust Boundaries

| Boundary | Description |
|----------|-------------|
| LAN → app (UDP 17778) | Unauthenticated broadcast datagrams from any host on the network reach `BeaconListener`. This change makes that socket bound for longer (app start rather than first Settings visit), so the boundary is now open in a window where it previously was not. |

## STRIDE Threat Register

| Threat ID | Category | Component | Severity | Disposition | Mitigation Plan |
|-----------|----------|-----------|----------|-------------|-----------------|
| T-wxr-01 | Spoofing | `reconnect_fsm.beaconSighted` — a forged beacon claiming the current target's guid could redirect a dial | medium | mitigate | Already mitigated and NOT weakened here: `beaconSighted` ignores any guid that is not the current target (T-03-06), acts only in `ReconnectState.backoff`, and a redirected dial still lands in challenge-response — a spoof redirects an ATTEMPT, never an authenticated session. `_dial` additionally refuses any host that is not RFC1918/link-local. Task 1 changes when the listener runs, not what it accepts. |
| T-wxr-02 | Denial of Service | `BeaconListener._onEvent` — malformed datagrams on a now-longer-lived socket | low | accept | `Beacon.tryParse` is a strict total parse returning null on anything unexpected, socket errors are swallowed, and nothing is allocated per rejected datagram. Longer exposure, unchanged blast radius. |
| T-wxr-03 | Information disclosure | Beacon debug printing | low | accept | `kDebugMode` only, decoded fields only, never raw datagram bytes. Unchanged by this task. |

No package-manager installs in this task, so no `T-wxr-SC` supply-chain entry:
`pubspec.yaml` is not modified and no dependency is added.
</threat_model>

<verification>
- `cd app/remote_control && flutter test` → 865 passed, 0 failed (baseline 863).
- `cd app/remote_control && flutter analyze` → no issues.
- The two tests in `test/beacon_binding_test.dart` were observed RED on the
  pre-fix tree, with the red output quoted in the SUMMARY.
- `git diff --stat .planning/v1.0-MILESTONE-AUDIT.md` is empty.
- Three commits, in order: code, requirements/verification docs, deferred items.
</verification>

<success_criteria>
- SC1: A cold start that never opens Settings or the device list is listening for
  beacons, so CONN-04's IP-change recovery is reachable — proven by a test that
  fails without the fix and does not mount any screen that could attach beacons
  on the app's behalf.
- SC2: Exactly one `BeaconListener` exists at runtime, shared by the device list
  and the ConnectionService — proven by a test that emits on the shared instance
  and observes the device list react.
- SC3: The multicast-lock hold window is stated as fact in the code comments, and
  the verdict that app-scope holding is acceptable is recorded with its reasoning
  in the SUMMARY.
- SC4: `flutter test` 865 / 0 and `flutter analyze` clean.
- SC5: REQUIREMENTS.md describes shipped behavior for CONN-06, APPS-01/02/03 and
  UI-01, with no promise of an unbuilt summon-bar.
- SC6: `02-VERIFICATION.md` is marked superseded without its body being rewritten,
  and `v1.0-MILESTONE-AUDIT.md` is byte-unchanged.
</success_criteria>

<output>
Create `.planning/quick/260811-wxr-close-v1-0-audit-gaps-conn-04-beacon-bin/260811-wxr-SUMMARY.md` when done.

The SUMMARY must record: the observed RED output of both new tests before the
fix; the multicast-lock lifecycle finding and the acceptable-verdict reasoning;
and the audit-closure statement (which of the audit's gaps this task closed and
which it deliberately did not), since the audit file itself stays unedited.
</output>
</content>
</invoke>
