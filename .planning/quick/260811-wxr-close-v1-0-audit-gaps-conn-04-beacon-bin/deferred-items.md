# Deferred items — quick 260811-wxr

Things this task deliberately did NOT do. Logged, not fixed. Four were named
out of scope by the plan; the fifth is a consequence of the fix this task DID
ship, and is recorded with the hazard that makes it non-trivial so a future
implementer does not rediscover it the hard way.

Nothing from the v1.1 summon-bar design
(`.planning/notes/summon-bar-trackpad-keyboard.md`) appears here — that is
unbuilt scope, not a deferred gap.

## 1. Multicast-lock foreground gating

**What it is:** the beacon listener is now app-scope
(`beaconListenerProvider`), so the Android `WifiManager.MulticastLock` is held
from app start until `ProviderScope` teardown — i.e. until the process ends.
Gating it on foreground (stop on pause, start on resume) via the
`AppLifecycleListener` that already exists at `main.dart:53` would be a real
battery improvement.

**Why it is NOT this task's:** the hold window was judged ACCEPTABLE, on the
evidence, and the plan scoped the fix accordingly:

- `stop()` is reached from exactly one place, and there is no `autoDispose`
  anywhere in `lib/`. Riverpod 3 `NotifierProvider` is keep-alive, so that
  disposal only ever fired at `ProviderScope` teardown. **The lock was ALREADY
  held from the first device-list/Settings visit until the process died** — the
  "screen-visible scoping" the old comments promised was an intent the
  keep-alive provider never delivered. Those comments are now corrected to state
  the real window.
- The delta introduced by this task is therefore only the *pre-first-visit*
  window of a single process lifetime — and that window is precisely the one
  CONN-04 needs a bound socket in. The cost is intrinsic to the requirement.

**Why it is more than the two lines it looks like — read this before starting.**
`BeaconListener.start` / `stop` have **no generation guard**. `stop()` sets
`_running = false` and *then* `await`s `_sub.cancel()`. A `start()` that
interleaves inside that await sees `_running == false`, so it proceeds: it
acquires the lock and binds a fresh socket. The resuming `stop()` then closes
**that** socket and releases the lock — leaving a listener that believes it is
running (`_running == true`) with no socket and no lock. Beacons stop arriving
silently and nothing retries, because from `start()`'s point of view it
succeeded. A pause/resume pair in quick succession is exactly how a user
produces this.

**Where it belongs:** its own task, whose first change is a generation counter
in `BeaconListener` so a stale `stop()` can recognise that it has been
superseded and bail out. New machinery, plus tests that drive the interleave.

## 2. Keymap lockstep hardening

**What it is:** `CLIENT_KEY_CODES`
(`server/server-windows/src/executors/keymap.rs:44-63`) and `kClientKeyCodes`
(`app/remote_control/lib/keyboard/key_rows.dart:45-64`) are the same 57-code
vocabulary in two languages. Re-checked during this task: **57/57, with an empty
set difference in BOTH directions.** They agree today.

**Why it is NOT this task's:** there is no automated cross-language gate the way
the shared `protocol/fixtures/` tree has one. Each side has only its own
coverage test. A one-sided edit — adding a code to the Dart list without adding
it to the Rust one — would fail no build and no test; it would surface as a key
that silently does nothing on the PC, because an unknown `key.code` is dropped
server-side (T-04-02).

**Where it belongs:** a new cross-language test, not a gap closure. The obvious
shape is a shared fixture (a JSON list of the 57 codes) that both suites assert
against, mirroring how the protocol fixtures already work.

## 3. The four phases with no VERIFICATION.md

**What it is:** phases **06, 08, 09 and 12** have no `VERIFICATION.md`. (Checked:
01, 02, 03, 04, 05, 07, 10 and 11 do.)

**Why it is NOT this task's:** outcome evidence exists for all four in other
artifacts — `06-UAT.md` (`status: complete`, SC1 pass), `08-06-SUMMARY.md`,
`09-08-SUMMARY.md`, and for phase 12 the 2026-08-08 hardware observation that
closed SC5 and SC7. The absence is a missing *document*, not a missing outcome.

**Where it belongs:** back-filling verification documents for phases that are
already closed is its own decision — it is worth debating whether a
retroactively written VERIFICATION.md is evidence at all, or just a summary
wearing the wrong filename.

## 4. Nyquist validation coverage

**What it is:** **0 of 12** phases carry `status: validated` (checked across
`.planning/phases/`).

**Why it is NOT this task's:** this task closes audit gaps in code and
bookkeeping. Validation coverage is a different kind of work with its own
command.

**Where it belongs:** `/gsd-validate-phase`.

## 5. Other stale quick-bar mentions in REQUIREMENTS.md — NONE FOUND

Task 2 grepped `.planning/REQUIREMENTS.md` for every surviving mention of the
removed trackpad quick-bar (case-insensitive, covering `quick-bar`, `quick bar`
and `quickbar`). **UI-01's line 76 was the only hit**, and Task 2 rewrote it.
Nothing is deferred under this item — it is recorded so the check is on the
record rather than assumed.

Note this is scoped to `REQUIREMENTS.md` only. Stale quick-bar wording elsewhere
in `.planning/` was not searched and was not in this task's brief; in `lib/`,
every surviving mention is a past-tense comment about the phase-08 removal,
which is correct and should stay.
