# Phase 8: Floating Trackpad Bubble — Context

**Gathered:** 2026-07-15
**Status:** Ready for planning
**Source:** Design Spec Express Path (docs/superpowers/specs/2026-07-15-trackpad-bubble-design.md — approved)

<domain>
## Phase Boundary

Replace the persistent 56px bottom **Trackpad quick-bar** (`QuickBarScaffold`, decision
D-10 / phase 07-13) on every tool screen with a **floating bubble** that expands into a
**draggable floating trackpad window**. The user mouses the laptop cursor while staying on
any tool screen (Media, Apps, Browser, Keyboard, Clipboard, Power, Presenter) instead of
navigating to the full Trackpad screen.

**In scope:** minimized draggable bubble, expanded floating trackpad window, extraction of
the trackpad hot-path core for reuse, deletion of the quick-bar, position persistence, and
the full test + UAT surface.

**Explicitly unchanged:** the full Trackpad screen, its hub tile, the UIPI banner contract,
and all reused trackpad primitives (`GestureClassifier`, `TrackpadDriver`, `MouseButtonsBar`,
`MoveSender`, accel/tuning, `keepAwake`).
</domain>

<decisions>
## Implementation Decisions

Every item below is a **locked decision** carried from the approved brainstorm spec.

### Expand model (D8-01)
- The bubble expands into a **floating window that pops out of the bubble's position** (chosen
  over a bottom sheet after mockup review).
- Bubble and window are **never both visible** — expand fades the bubble out as the window
  scales in (200ms); collapse reverses it. Window scales out of / back into the bubble spot.

### Bubble — minimized state (D8-02)
- New file `widgets/trackpad_bubble.dart`. 56dp circle, `kAccent` fill, `Icons.touch_app`
  (the reserved accent affordance carried over from the quick-bar).
- **Tap** = haptic tick + expand.
- **Drag** anywhere; on release animates (200ms ease-out) to the **nearest left/right edge**
  with an 8px inset.
- Position stored as `(edge, yFraction)` in a Riverpod `Notifier` backed by
  `shared_preferences`. Survives screen switches and app restarts. **Default: right edge, 70% down.**
- **Muted rendering** (`kSurface` fill, muted icon) when not authed — same "muted, not red"
  rule as `MouseButtonsBar`; still tappable.
- **Long-press:** no action in v1 (no hide menu).

### Window — expanded state (D8-03)
- New file `trackpad/floating_trackpad_window.dart`. Card: `kSurface` fill, `kHairline` 1px
  border, 16px radius, drop shadow. **Fixed size ~78% screen width × ~38% screen height.**
- Rows top-to-bottom:
  1. **Header bar:** `⠿` drag-handle region · inline drag-lock pill (visible only while
     locked) · `⤢` open full Trackpad screen · `✕` collapse to bubble.
  2. **Gesture surface** (`TrackpadCore`): move, tap = left click, two-finger tap = right
     click, two-finger scroll with momentum, long-press drag + drag-lock. Same **D-05
     sensitivity** as the full screen.
  3. **`MouseButtonsBar`** reused as-is, gated muted when not authed.
- **Drag by header bar only.** Gesture-surface touches are always mouse input — no ambiguity
  between moving the window and moving the cursor.
- Window always **clamped fully on-screen.** Anchor derives from the bubble spot on the
  first-ever open; later opens restore the last window position.
- Position persisted as `(x, y)` fractions, **separate from the bubble position.**

### Trackpad core extraction (D8-04)
- New file `trackpad/trackpad_core.dart`. Extract from `_TrackpadScreenState`:
  `GestureClassifier` + `TrackpadDriver` construction, raw pointer routes
  (`Listener → classifier → driver → service`, **zero setState**), sensitivity cache
  (`listenManual`, hot path reads a plain double), scroll-direction cache binding,
  disconnect-hygiene `changes` subscription (transition into `disconnected` → `driver.reset()`),
  and the CR-01 dispose contract.
- Exposed as a `TrackpadCore` widget: gesture surface with injected chrome slots.
- `TrackpadScreen` becomes a **thin composition** of `TrackpadCore` + its existing chrome
  (drag-lock pill, tune, keyboard panel, `MouseButtonsBar`).
- **Extraction is behavior-neutral: existing `TrackpadScreen` tests must pass unmodified.**

### Scaffold swap (D8-05)
- New file `widgets/bubble_scaffold.dart` **replaces** `widgets/quick_bar_scaffold.dart`.
- Keeps the **UIPI-banner Stack contract verbatim** (top-anchored, `IgnorePointer`).
- Adds two Stack children: `TrackpadBubble` (minimized) and `FloatingTrackpadWindow` (expanded).
- The `showQuickBar` param becomes `showBubble` — **false only for the Trackpad screen wrap**
  (no shortcut to the screen you are on; the UIPI banner still rides).
- **Bubble scope:** tool screens only — Keyboard, Media, Apps, Clipboard, Power, Presenter,
  Browser. **Not on hub, not on the Trackpad screen.**

### Migration (D8-06)
- **Quick-bar deleted outright** — no settings toggle to restore it. Delete `_TrackpadQuickBar`
  and the 56px reserved Column slot; tool screens get the full height back.

### Lifecycle & hot-path contracts (D8-07)
- **Hot path preserved:** window pointer routes are identical to the full screen — zero
  setState, per-event intent list is the only allocation.
- **Expand/collapse rides a `ValueNotifier`** (same localized-rebuild discipline as the
  keyboard panel, Pitfall 6): the tool screen body never rebuilds off it.
- **Disconnect hygiene** per `TrackpadCore` instance — transition into `disconnected` →
  `driver.reset()` (server side is CONN-07 `release_all`).
- **Dispose contract (CR-01):** window collapse or screen pop while drag-locked on a live
  socket → flush `DragMsg(end, left)` before `driver.dispose()`. **Drag-lock deliberately does
  NOT survive collapse** — no invisible held mouse button behind a bubble.
- **keepAwake (D-14):** `acquire()` on expand, `release()` on collapse/dispose. Ref-counted,
  so Presenter's own hold is never dropped.

### Navigation & back handling (D8-08)
- `⤢`: collapses the window, then pushes the full Trackpad screen wrapped with
  `showBubble: false` (existing pattern).
- **Back button:** collapses the window first (one `PopScope` level); a second back leaves the
  screen.
- **Expanded state is per-screen ephemeral** — navigating away closes the window; bubble and
  window positions persist. The tool screen stays visible and tappable everywhere around the
  window.

### Claude's Discretion
- Exact animation curves/implementation of the scale-out/scale-in (200ms budget is fixed).
- Internal structure of the `TrackpadCore` chrome-slot API, as long as the extraction is
  behavior-neutral and `TrackpadScreen` tests pass unmodified.
- Widget-tree/provider wiring for the two new Riverpod position notifiers.
- Naming of private members and helper methods within the new widgets.
</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Design source of truth
- `docs/superpowers/specs/2026-07-15-trackpad-bubble-design.md` — approved design spec; the
  authority for every decision above.

### Files replaced / deleted
- `app/remote_control/lib/widgets/quick_bar_scaffold.dart` — `QuickBarScaffold` +
  `_TrackpadQuickBar`; replaced by `bubble_scaffold.dart`, then deleted.
- `app/remote_control/test/quick_bar_test.dart` — quick-bar widget tests; superseded by
  bubble/scaffold tests.

### Trackpad core to extract from
- `app/remote_control/lib/trackpad/trackpad_screen.dart` — `_TrackpadScreenState`; source of
  the hot-path routes, sensitivity cache, disconnect hygiene, and CR-01 dispose contract.
- `app/remote_control/lib/trackpad/gesture_classifier.dart` — `GestureClassifier` (reused unchanged).
- `app/remote_control/lib/trackpad/trackpad_driver.dart` — `TrackpadDriver` (reused unchanged).
- `app/remote_control/lib/trackpad/move_sender.dart` — `MoveSender` (reused unchanged).
- `app/remote_control/lib/trackpad/mouse_buttons.dart` — `MouseButtonsBar` (reused as-is).
- `app/remote_control/lib/trackpad/accel.dart`, `app/remote_control/lib/trackpad/tuning.dart` —
  accel/tuning (reused unchanged).

### Shared chrome & lifecycle
- `app/remote_control/lib/widgets/uipi_banner.dart` — `UipiBanner`; Stack contract preserved verbatim.
- `app/remote_control/lib/widgets/keep_awake.dart` — `keepAwake` ref-counted hold (D-14).
- `app/remote_control/lib/theme/tokens.dart` — `kAccent`, `kSurface`, `kHairline` design tokens.

### Consumers to migrate (tool screens wrapped by the scaffold)
- `app/remote_control/lib/keyboard/keyboard_screen.dart`, `media/media_screen.dart`,
  `apps/apps_screen.dart`, `clipboard/clipboard_screen.dart`, `power/power_screen.dart`,
  `presenter/presenter_screen.dart`, `browser/browser_screen.dart` — receive the bubble.
- `app/remote_control/lib/hub/hub_screen.dart` — must NOT get the bubble (verify current wrap).

### Existing test patterns to mirror
- `app/remote_control/test/trackpad/*` — callback-injection widget/unit style, no Navigator.
- `app/remote_control/test/uipi_banner_test.dart`, `test/keep_awake_test.dart`.
</canonical_refs>

<specifics>
## Specific Ideas

- Default bubble position: **right edge, 70% down.**
- Window size: **~78% width × ~38% height**, fixed.
- Animations: **200ms** ease-out for edge snap; **200ms** scale for expand/collapse.
- Bubble icon: `Icons.touch_app` on `kAccent`.
- Two independent persisted positions: bubble `(edge, yFraction)`, window `(x, y)` fractions.
- Muted (not red) state when unauthed, mirroring `MouseButtonsBar`.
</specifics>

<deferred>
## Deferred Ideas (Out of scope — v1)

- Window resize.
- Keyboard inside the window (keyboard stays on its own tile + the full Trackpad screen).
- Bubble on the hub.
- Settings toggle to restore the quick-bar.
- Per-screen collision special-casing (bubble/window covers a control → user drags it clear).
- Bubble long-press hide menu.
</deferred>

---

*Phase: 08-floating-trackpad-bubble-replace-quick-bar-with-draggable-bu*
*Context gathered: 2026-07-15 via Design Spec Express Path*
