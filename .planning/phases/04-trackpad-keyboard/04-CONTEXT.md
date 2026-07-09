# Phase 4: Trackpad & Keyboard - Context

**Gathered:** 2026-07-09
**Status:** Ready for planning

<domain>
## Phase Boundary

Make the phone a genuinely usable daily mouse and keyboard — trackpad gesture
feel and typing/key fidelity that match a real laptop, not a toy.

**In scope (ROADMAP Phase 4, mvp mode):**
- Trackpad: one-finger move with velocity acceleration + server sub-pixel
  accumulation (PAD-01), tap = left / two-finger tap = right / on-screen L/M/R
  buttons (PAD-02), two-finger scroll with momentum + instant touch-stop
  (PAD-03), long-press drag with drag-lock for screen-edge drags (PAD-04)
- Keyboard: IME-correct typing incl. autocomplete revisions/emoji/backspace via
  diff-ops (KEY-01), F1–F12 + numpad + nav-cluster key rows (KEY-02), sticky
  modifiers Ctrl/Alt/Shift/Win with visible held state + combos (KEY-03),
  server-side autorepeat on hold (KEY-04)

**Out of scope (other phases):** dashboard home + persistent quick-bar (UI-01,
Phase 7), media/power/presenter/browser controls (Phase 5), gyro/air-mouse
(FEAT-01 backlog), UDP mouse channel (TRAN-01 backlog — NOT triggered, Phase-2
gate passed on ws://).
</domain>

<decisions>
## Implementation Decisions

### Pointer injection model (PAD-01)
- **D-01:** Switch the server from RELATIVE to ABSOLUTE injection (enigo
  `Coordinate::Abs` via GetCursorPos + accumulated delta → normalized absolute
  SendInput). This bypasses Windows pointer ballistics so slow/small drags are
  no longer suppressed by "Enhance pointer precision" (the OS default), giving
  true 1:1 tracking regardless of that setting. Confirmed problem from the
  Phase-2 gate run (02-04-GATE-RESULT.md).
- **D-02:** KEEP the existing server sub-pixel accumulator — it was never at
  fault (it correctly carries fractions); only the downstream OS ballistics
  curve lost the motion. Absolute injection consumes the accumulated position.
- **D-03:** Multi-monitor / virtual-desktop normalization is a known edge case
  (absolute coords normalize to the VIRTUAL desktop, not the primary monitor) —
  researcher must specify the normalization math and a verification for a
  multi-display setup before implementation.

### Trackpad feel & gesture classification (PAD-01..04)
- **D-04:** Gesture classification is CLIENT-side, off the raw `Listener`
  pointer stream (the Phase-3 hot path already delegates `onPointerMove` →
  `service.sendMove`). One classifier distinguishes: single-finger move,
  tap (→ `click left`), two-finger tap (→ `click right`), two-finger scroll
  (→ `0x02` scroll frames), and long-press-then-move drag with drag-lock.
- **D-05:** Benchmark is the Remote Mouse app the owner uses today — Phase 4
  must feel at least as good. Ship sensible defaults (velocity acceleration
  curve; ~250ms long-press to enter drag-lock; scroll momentum that halts
  instantly on a new touch contact) and expose a **sensitivity** setting
  (shared_preferences, non-secret) so the owner can tune.
- **D-06:** Exact curve shape and thresholds (tap-vs-move pixel/time tolerance,
  two-finger-tap window, momentum decay, acceleration coefficients) are treated
  as ON-DEVICE TUNING during execution — they cannot be decided abstractly.
  Plans should land tunable constants in one place and include a device
  feel-check as an execution checkpoint, not hardcode magic numbers as final.

### Keyboard surface layout (KEY-01, KEY-02)
- **D-07:** Keyboard is an EXPANDABLE PANEL over the trackpad, not a separate
  screen — the trackpad stays the home surface and the keyboard is one toggle
  away. (The dashboard/quick-bar is Phase 7; Phase 4 keeps the full-bleed
  trackpad from Phase 3 as home.)
- **D-08:** Typing uses a hidden/offscreen system `TextField` to capture the
  device IME (autocomplete, emoji, backspace); the client computes diff-ops
  (`bs`/`ins`, extended-grapheme-cluster counting per SPEC §8) and sends `text`
  messages. Do NOT reinvent an on-screen keyboard — ride the system IME.
- **D-09:** Special keys are toggleable ROWS in the panel (switchable groups:
  F1–F12, numpad, nav-cluster Home/End/PgUp/PgDn/Del/Esc/Tab + arrows), sending
  `key` messages. Default visible row = nav-cluster.

### Sticky modifiers & autorepeat (KEY-03, KEY-04)
- **D-10:** Tapping a modifier (Ctrl/Alt/Shift/Win) shows a VISIBLE held state
  (highlighted); the next non-modifier key sends the combo (`key` with `mods`)
  and then modifiers auto-reset. Multiple modifiers chord (Ctrl+Alt+Del,
  Win+D). LONG-PRESS a modifier = lock it held for repeated combos until tapped
  off.
- **D-11:** Autorepeat (KEY-04) is server-side key-down/hold, driven by `key`
  `action: down`/`up` from a held on-screen key — never client tap-spam.
- **D-12:** All modifier/held state resets on disconnect (client-side), layered
  on top of the already-shipped CONN-07 server-side release-all so no phantom
  input survives a mid-combo drop.

### Claude's Discretion
Owner delegated the area selection ("no preference") and confirmed all four
locked decisions above. Exact constants, widget structure, and slice ordering
are Claude/planner discretion within these decisions. MVP mode: expect SPIDR
slicing during planning (trackpad slice(s) before keyboard slice(s)).

### Folded Todos
- **Absolute pointer injection so slow drags survive Windows pointer
  acceleration** (`.planning/todos/pending/2026-07-08-absolute-pointer-injection-for-slow-drag-fidelity.md`,
  score 0.9) — folded into D-01/D-02/D-03. This is the natural home the todo
  itself named. Remove from pending when the plan lands it.
</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Wire protocol (LOCKED Phase 1 — no changes this phase)
- `protocol/SPEC.md` §7 (message table: `click`, `key`, `text`, `drag`), §8
  (diff-ops text semantics — extended-grapheme-cluster counting), §10 (binary
  mouse frames) — the input message contract is already locked; Phase 4
  implements executors + client producers against it, it does NOT change the wire
- `protocol/schema/messages.schema.json` — `click`, `key`, `text` shapes
- `protocol/schema/mouse-binary.md` — `0x01` move / `0x02` scroll 9-byte frames
- `protocol/fixtures/text/*` — diff-op fixtures (emoji, rapid backspace) the
  client diff computation must reproduce byte-for-byte
- `protocol/fixtures/mouse-binary/*` — move/scroll frame fixtures

### Prior-phase artifacts to honor
- `.planning/phases/02-end-to-end-cursor-spike/02-04-GATE-RESULT.md` — the
  pointer-acceleration finding that motivates D-01 (absolute injection)
- `server/server-windows/src/input_thread.rs` — current RELATIVE move injection
  + sub-pixel accumulator (the file D-01/D-02 modify)
- `app/remote_control/lib/trackpad/trackpad_screen.dart` — Phase-3 slimmed
  consumer (hot-path `sendMove`); the gesture classifier grows here
- `app/remote_control/lib/trackpad/move_sender.dart` — 9-byte binary frame sink
- `app/remote_control/lib/net/connection_service.dart` — `sendMove` (volatile)
  and `sendReliable` (queued) — clicks/keys/text go through `sendReliable`
- `.planning/REQUIREMENTS.md` — PAD-01..04, KEY-01..04 acceptance wording

### Todo folded
- `.planning/todos/pending/2026-07-08-absolute-pointer-injection-for-slow-drag-fidelity.md`
</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `ConnectionService.sendMove` (volatile, gated) + `sendReliable` (bounded FIFO
  queue, flushes on auth): the two send paths Phase 4 producers use — binary
  move/scroll on the volatile path, `click`/`key`/`text` on the reliable path.
- `MoveSender`: existing 9-byte binary frame builder; scroll (`0x02`) frames fit
  the same sink.
- Phase-1 server executors: mock executors + dispatch gates already route
  `click`/`key`/`text`; Phase 4 supplies the REAL Windows executors (enigo
  `SendInput`, layout-independent Unicode `text()`), mirroring how Phase 2
  built the real move executor.
- `HapticFeedback` (flutter/services) — tick on clicks/keys (per PROJECT stack).
- shared_preferences — the sensitivity setting + row-visibility state (non-secret).

### Established Patterns
- Hot move path is a boolean gate + fire-and-forget; it never rebuilds UI and
  never pings `changes` (Phase-2/3 invariant) — the gesture classifier must
  keep clicks/scroll/drag off that rebuild path too.
- Pure IO-free classifiers/FSMs with injected seams + unit tests (handshake_fsm,
  reconnect_fsm house style) — the gesture classifier and diff-op computer
  should follow it (test-seamed, deterministic).
- Enigo injection failures on the input thread are dropped, never panic (Phase 2).

### Integration Points
- `input_thread.rs`: relative → absolute injection (D-01); add real click/scroll
  executors alongside move.
- Real `key` / `text` executors (new, server-windows) behind the Phase-1
  executor traits so server-core stays zero-Windows-deps.
- `trackpad_screen.dart`: gesture classifier + on-screen L/M/R buttons +
  keyboard-panel toggle mount here.
</code_context>

<specifics>
## Specific Ideas

- Benchmark target: the **Remote Mouse** app the owner currently uses — Phase 4
  must match or beat its trackpad feel and typing fidelity (this is the whole
  reason for the project per PROJECT.md).
- Typing must survive the hard cases already fixtured: multi-codepoint emoji
  (👋🏽 = one grapheme), rapid backspace across graphemes, IME autocomplete
  revisions — the diff-op computation is grapheme-cluster-exact, not UTF-16/byte.
</specifics>

<deferred>
## Deferred Ideas

- Gyro/air-mouse mode (FEAT-01) — backlog, its own future capability.
- UDP mouse-delta channel (TRAN-01) — NOT triggered; the Phase-2 gate passed on
  ws:// (p50 6ms). Only revisit if real-use jitter appears.

### Reviewed Todos (not folded)
- **Server one-pairing-per-run** (`.planning/todos/pending/2026-07-09-server-one-pairing-per-run.md`)
  — matched on the "server" keyword but is a pairing-lifecycle gap that closes
  with Phase-7 token persistence, not a trackpad/keyboard concern. Deferred.
- **Overloaded `noPairing` reason copy** (`.planning/todos/pending/2026-07-09-nopairing-reason-overloaded-copy.md`)
  — pairing/protocol copy, not input. Deferred to a server-protocol follow-up /
  Phase 7.
</deferred>

---

*Phase: 4-Trackpad & Keyboard*
*Context gathered: 2026-07-09*
