# Phase 5: Media, Power, Presenter & Browser - Context

**Gathered:** 2026-07-10
**Status:** Ready for planning

<domain>
## Phase Boundary

The everyday control-center extras work end-to-end from the couch: system media
control and accurate absolute volume, safely double-confirmed power actions,
PowerPoint-standard slide driving with an elapsed timer, and browser control via
key macros.

**In scope (ROADMAP Phase 5, mvp mode):**
- Media: play/pause, next, prev system-wide (MED-01); absolute volume slider +
  mute that stays accurate via server volume-state push on connect and external
  change (MED-02)
- Power: lock (PWR-01) and sleep via SetSuspendState (PWR-02) behind
  slide-to-confirm; restart/shutdown behind slide-to-confirm PLUS the
  server-side confirm message (PWR-03)
- Presenter: next/prev, start/end show, blank screen (PRES-01); elapsed timer
  (PRES-02)
- Browser: back/forward, new/close tab, refresh, zoom in/out as key macros on
  the focused browser (BROW-01)
- Interim navigation surface (hub screen) so these tools are reachable before
  the Phase-7 dashboard exists

**Out of scope (other phases):** apps/window management + clipboard (Phase 6),
tray shell, settings window, dashboard tiles polish, autostart, persistent
token storage (Phase 7).
</domain>

<decisions>
## Implementation Decisions

### Control-surface navigation (pre-Phase-7)
- **D-01:** Interim **Remote hub screen**: tapping a connected device row opens
  a slim hub with the trackpad (existing) plus tiles for Media, Power,
  Presenter, Browser. The hub is built as the skeleton the Phase-7 dashboard
  grows into — NOT throwaway UI. Browser controls get their own small screen
  off the hub.
- **D-02:** Existing Phase-3 flow (row tap → trackpad) changes to row tap →
  hub; trackpad is the first/primary tile. Header status/latency chip + banner
  (Phase-3 surface) appears on every connected-capable screen including the new
  hub and tool screens.

### Volume slider + state sync (MED-02)
- **D-03:** Wire amendment (additive, minor proto version bump): new S→C
  message `vol.changed {value: 0-100, muted: bool}` pushed (a) right after
  auth, (b) whenever server-side volume/mute changes externally. Server side
  uses IAudioEndpointVolume state (change callback if practical, else short
  poll — researcher decides mechanism).
- **D-04:** Slider sends **throttled `setvol` while dragging** (~50ms cadence)
  for live audio feedback; incoming `vol.changed` pushes are IGNORED during an
  active drag so the finger always wins; after release the pushed state is
  authoritative again.

### Power confirm UX (PWR-01..03)
- **D-05:** All four power actions sit behind a **slide-to-confirm track**.
  Lock/sleep: completing the slide sends `power` immediately followed by
  `confirm` (single deliberate gesture; two wire messages per SPEC §7).
- **D-06:** Restart/shutdown: completing the slide sends `power` only, then a
  red countdown dialog ("Restart PC? 10s") appears; its confirm button sends
  the `confirm` message. Dialog auto-dismisses when the SPEC 10s window
  expires. Two distinct deliberate gestures — no single-action path (satisfies
  PWR-03 and roadmap SC3).

### Presenter screen (PRES-01/02)
- **D-07:** Full-screen split tap zones: giant Next (right ~2/3) / Prev (left
  ~1/3), bottom bar with Start show / End show / Blank toggle + elapsed timer.
  Haptic tick per slide advance.
- **D-08:** Timer is **manual**: starts on "Start show" tap; tapping the timer
  pauses/resets. Timer is client-local (no wire involvement).
- **D-09:** Keep-awake (wakelock_plus) active while the presenter screen is
  open (per PROJECT stack notes; trackpad already has it).

### Claude's Discretion
Owner delegated area selection and confirmed all recommended options. Exact
styling, tile layout, slider widget, tunable constants (throttle ms, dialog
countdown rendering), media screen composition (transport buttons + slider on
one screen), mute button placement, browser screen button grid, and slice
ordering are Claude/planner discretion within the decisions above. MVP mode:
expect vertical slices during planning.
</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Wire protocol (Phase-1 locked; ONE additive amendment this phase)
- `protocol/SPEC.md` §7 (message table: `media`, `power`, `confirm`, `browser`,
  `present` — all already routed server-side), §2 (version negotiation — the
  `vol.changed` amendment is a minor bump), §6 (err codes: `noPendingAction`
  for stale confirm)
- `protocol/schema/messages.schema.json` — message shapes; `vol.changed` must
  be added here + fixtures
- `protocol/fixtures/` — existing fixture layout; the amendment needs new
  golden fixtures (Rust + Dart codecs stay byte-identical)

### Server side
- `server/server-core/src/dispatch/router.rs` — `media`/`power`+`confirm`
  double-confirm gate (10s window, `pending_power`) ALREADY implemented against
  executor traits; Phase 5 supplies real executors, router unchanged
- `server/server-windows/src/executors/stubs.rs` — StubMedia/StubPower to be
  replaced with real Windows impls (enigo media keys + IAudioEndpointVolume;
  LockWorkStation/SetSuspendState/ExitWindowsEx)
- `server/server-windows/src/executors/keymap.rs` — browser/present macro codes
  ALREADY mapped (04-02, `Key::Unicode`); browser/present may already work
  end-to-end server-side — verify before writing new code
- `server/server-windows/src/input_thread.rs` — input-thread pattern real
  executors follow (send-and-forget, failures dropped, never panic)

### Client side
- `app/remote_control/lib/net/connection_service.dart` — `sendReliable` (all
  Phase-5 C→S commands), `changes` stream (where `vol.changed` push lands)
- `app/remote_control/lib/screens/device_list_screen.dart` — row tap currently
  navigates to trackpad; D-02 reroutes to the hub
- `app/remote_control/lib/hud/` — header status/latency chip pattern (D-02:
  reuse on hub + tool screens)
- `app/remote_control/lib/trackpad/trackpad_screen.dart` — wakelock pattern,
  haptics pattern
- `.planning/REQUIREMENTS.md` — MED-01/02, PWR-01..03, PRES-01/02, BROW-01
  acceptance wording

### Stack notes
- `CLAUDE.md` (project) — enigo media keys built in (`Key::MediaPlayPause`
  etc.); `windows` crate for IAudioEndpointVolume + LockWorkStation;
  wakelock_plus for presenter
</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- Router + double-confirm gate: `power`→`confirm` 10s window with
  `err{noPendingAction}` already enforced server-core-side with tests — client
  only needs the UX (D-05/D-06).
- Executor traits (`Media`, `Power`) + recording MockExecutors: real Windows
  executors slot in behind existing traits; server-core stays
  zero-Windows-deps.
- Browser/present key macros already executing via keymap.rs since 04-02.
- `sendReliable` bounded FIFO: correct path for all Phase-5 commands.
- Header chip/banner + `Timer.periodic(kHudReadThrottle)` HUD pattern for the
  hub and tool screens.
- wakelock_plus + HapticFeedback wiring precedent on trackpad screens.

### Established Patterns
- Pure IO-free FSM + injected seams for anything stateful (slide-to-confirm
  track state, presenter timer) — house style, deterministic tests.
- Additive protocol change = schema + golden fixtures + both codecs + version
  note in SPEC §2 (Phase-1 discipline; contract-tested cross-language).
- Server executor calls are send-and-forget on the input thread; never panic.
- Value-equal status snapshots so Riverpod notifiers suppress no-op rebuilds —
  volume state should follow the same pattern.

### Integration Points
- `stubs.rs` → real `media.rs` / `power.rs` executors (server-windows).
- Volume-state producer (server-windows) → new S→C push through the existing
  session write path.
- `device_list_screen.dart` row tap → new hub route; hub → tool screens.
- `connection_service.dart` `changes`/message router → volume state store
  (Riverpod provider) for the slider.
</code_context>

<specifics>
## Specific Ideas

- Hub is explicitly the Phase-7 dashboard skeleton — build tile layout with
  that growth in mind (8 tiles eventually; 5 now: Trackpad, Media, Power,
  Presenter, Browser).
- Sleep must actually suspend (SetSuspendState with hibernate=false), not
  hibernate — roadmap SC2 calls this out.
- Volume slider accuracy against PC-side changes is the MED-02 acceptance
  test: change volume on the PC, slider follows.
</specifics>

<deferred>
## Deferred Ideas

- None new from this discussion.

### Reviewed Todos (not folded)
- **Server one-pairing-per-run**
  (`.planning/todos/pending/2026-07-09-server-one-pairing-per-run.md`) —
  pairing lifecycle, closes with Phase-7 persistent token storage. Same
  verdict as Phase-4 review. Deferred.
- **Overloaded `noPairing` reason copy**
  (`.planning/todos/pending/2026-07-09-nopairing-reason-overloaded-copy.md`) —
  server-protocol/pairing copy, not control-center scope. Deferred to Phase 7 /
  protocol follow-up.
</deferred>

---

*Phase: 5-Media, Power, Presenter & Browser*
*Context gathered: 2026-07-10*
