# Floating Trackpad Bubble — Design Spec

**Date:** 2026-07-15
**Status:** Approved (brainstorm session, visual companion mockups in `.superpowers/brainstorm/1409-1784118629/`)
**Replaces:** the persistent Trackpad quick-bar (`QuickBarScaffold`, D-10 / 07-13)

## Summary

Replace the 56px bottom quick-bar on every tool screen with a floating bubble that
expands into a draggable floating trackpad window. The user can mouse the laptop
cursor while staying on any tool screen (Media, Apps, Browser, …) instead of
navigating away to the full Trackpad screen. The full Trackpad screen and its hub
tile are unchanged.

## Decisions (from brainstorm)

| Question | Decision |
|---|---|
| Expand behavior | Floating window popping out of the bubble (revised from bottom sheet after mockup review) |
| Window contents | Gesture surface + L/R mouse buttons + expand-to-full shortcut |
| Bubble drag | Draggable, snaps to nearest left/right edge, position persisted |
| Bubble scope | Tool screens only (Keyboard, Media, Apps, Clipboard, Power, Presenter, Browser). Not on hub, not on Trackpad screen |
| Window drag | Draggable by header bar only, fixed size (~78% w × ~38% h), clamped on-screen, position persisted |
| Migration | Quick-bar deleted outright — no settings toggle |
| Implementation | Approach A: per-screen scaffold overlay, trackpad core extracted for reuse |

## Components

### New files

- **`widgets/bubble_scaffold.dart`** — replaces `widgets/quick_bar_scaffold.dart`.
  Keeps the UIPI-banner Stack contract verbatim (top-anchored, IgnorePointer).
  Adds two Stack children: `TrackpadBubble` (minimized state) and
  `FloatingTrackpadWindow` (expanded state). The `showQuickBar` param becomes
  `showBubble` — false only for the Trackpad screen wrap (no shortcut to the
  screen you are on; the UIPI banner still rides).

- **`trackpad/trackpad_core.dart`** — extraction of what today lives inside
  `_TrackpadScreenState`: `GestureClassifier` + `TrackpadDriver` construction,
  raw pointer routes (`Listener → classifier → driver → service`, zero setState),
  sensitivity cache (`listenManual`, hot path reads a plain double),
  scroll-direction cache binding, disconnect-hygiene `changes` subscription
  (transition into `disconnected` → `driver.reset()`), and the CR-01 dispose
  contract (flush `DragMsg(end, left)` if drag-locked on a live socket before
  `driver.dispose()`). Exposed as a `TrackpadCore` widget: gesture surface with
  injected chrome slots. `TrackpadScreen` becomes a thin composition of
  `TrackpadCore` + its existing chrome (drag-lock pill, tune, keyboard panel,
  `MouseButtonsBar`). The extraction is behavior-neutral: existing
  `TrackpadScreen` tests must pass unmodified.

- **`trackpad/floating_trackpad_window.dart`** — the expanded state. A card:
  `kSurface` fill, `kHairline` 1px border, 16px radius, drop shadow. Fixed size
  ~78% screen width × ~38% screen height. Rows top-to-bottom:
  1. Header bar: `⠿` drag handle region · inline drag-lock pill (visible only
     while locked) · `⤢` open full Trackpad screen · `✕` collapse to bubble.
  2. Gesture surface (`TrackpadCore`): move, tap = left click, two-finger tap =
     right click, two-finger scroll with momentum, long-press drag + drag-lock.
     Same D-05 sensitivity setting as the full screen.
  3. `MouseButtonsBar` (reused as-is), gated muted when not authed.

- **`widgets/trackpad_bubble.dart`** — the minimized state. 56dp circle,
  `kAccent` fill, `Icons.touch_app` (the reserved accent affordance carries
  over from the quick-bar). Tap = haptic tick + expand. Drag anywhere; on
  release animates (200ms ease-out) to nearest left/right edge with an 8px
  inset. Muted rendering (kSurface fill, muted icon) when not authed — same
  "muted, not red" rule as `MouseButtonsBar`; still tappable.

### Deleted

- `_TrackpadQuickBar` and the 56px reserved Column slot. Tool screens get the
  full height back.

### Reused unchanged

`GestureClassifier`, `TrackpadDriver`, `MouseButtonsBar`, `MoveSender`,
accel/tuning, `UipiBanner`, `keepAwake`.

## Interaction

**Bubble (minimized):**
- Position stored as `(edge, yFraction)` in a Riverpod `Notifier` backed by
  shared_preferences — survives screen switches and app restarts. Default:
  right edge, 70% down.
- Long-press: no action in v1 (no hide menu).

**Window (expanded):**
- Expand: window scales out of the bubble's position (200ms); bubble fades out
  simultaneously — bubble and window are never both visible. Anchor derives
  from the bubble spot on first-ever open; later opens restore the last window
  position. Always clamped fully on-screen.
- Drag: header bar only. Gesture-surface touches are always mouse input — no
  ambiguity between moving the window and moving the cursor. Position persisted
  as `(x, y)` fractions, separate from the bubble position.
- Collapse: window shrinks back into the bubble at the bubble's position.
- `⤢`: collapses the window, then pushes the full Trackpad screen wrapped with
  `showBubble: false` (existing pattern).
- Back button: collapses the window first (one `PopScope` level); a second back
  leaves the screen.
- Expanded state is per-screen ephemeral — navigating away closes the window;
  bubble and window positions persist.
- The tool screen stays visible and tappable everywhere around the window.

**Out of scope (v1):** window resize, keyboard in the window (keyboard stays on
its own tile + the full Trackpad screen), bubble on hub, settings toggle to
restore the quick-bar, per-screen collision special-casing (bubble covers a
control → user drags it; window covers one → user drags the window).

## Lifecycle & error handling

- **Hot path preserved:** the window's pointer routes are identical to the full
  screen — zero setState, per-event intent list is the only allocation.
  Expand/collapse rides a `ValueNotifier` (same localized-rebuild discipline as
  the keyboard panel, Pitfall 6): the tool screen body never rebuilds off it.
- **Disconnect hygiene:** per `TrackpadCore` instance — transition into
  `disconnected` → `driver.reset()`. Server side is CONN-07 `release_all`.
- **Dispose contract (CR-01):** window collapse or screen pop while drag-locked
  on a live socket → flush `DragMsg(end, left)` before `driver.dispose()`.
  Drag-lock deliberately does NOT survive collapse — no invisible held mouse
  button behind a bubble.
- **keepAwake (D-14):** `acquire()` on expand, `release()` on collapse/dispose.
  Ref-counted, so Presenter's own hold is never dropped.
- **UIPI banner:** unchanged — top overlay in `BubbleScaffold` on every tool
  screen, including while the window is open.
- **Offline:** hub disables tool tiles when disconnected, so the bubble's muted
  state only shows mid-session (reconnecting, or dropped while on a tool screen).

## Testing

**Widget tests** (existing callback-injection style, no Navigator):
- `TrackpadBubble`: drag → snaps to nearest edge; position notifier updated;
  tap fires callback + haptic; muted when not authed.
- `FloatingTrackpadWindow`: header-drag moves and clamps the window; header
  buttons fire callbacks; pointer events on the surface reach a fake
  classifier/driver seam; drag-lock pill appears via notifier.
- `BubbleScaffold`: bubble present on tool screens, absent with
  `showBubble: false`; UIPI banner slot unchanged; tool content around the open
  window stays hit-testable.
- `TrackpadCore` extraction: existing `TrackpadScreen` tests pass unmodified.

**Unit tests:**
- Bubble `(edge, yFraction)` and window `(x, y)` persistence round-trips.
- Dispose flush sends `DragMsg(end)` only when drag-locked AND authed
  (4-quadrant test, mirrors CR-01 tests).

**UAT items:**
- Cursor latency from the window indistinguishable from the full screen.
- Drag bubble and window on every tool screen; positions restore after restart.
- Power screen + window overlap: drag window clear, confirm flow unobstructed.
- Reconnect and disconnect while the window is open.
