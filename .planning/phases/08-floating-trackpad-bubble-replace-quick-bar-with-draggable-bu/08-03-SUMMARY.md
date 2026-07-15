---
phase: 08-floating-trackpad-bubble-replace-quick-bar-with-draggable-bu
plan: 03
subsystem: app/widgets
tags: [flutter, riverpod, gesture, animation, drag-snap, bubble]
requires:
  - "bubble_position.dart: Edge enum, BubblePosition model, bubblePositionProvider (08-01)"
provides:
  - "trackpad_bubble.dart: TrackpadBubble draggable minimized-state widget (56dp circle, muted-gate, drag + 200ms easeOut edge-snap), kBubbleSize=56, kBubbleEdgeInset=8"
affects:
  - "08-05 (BubbleScaffold mounts TrackpadBubble in its expand-toggle Stack slot)"
tech-stack:
  added: []
  patterns:
    - "GestureDetector onPanStart/Update/End + AnimationController edge-snap (NOT Draggable/DragTarget)"
    - "Muted-not-red auth gate (mouse_buttons.dart clone): kAccent/kText vs kSurface/kMuted, tappable in both"
    - "Callback-injection leaf widget (service-agnostic, no Navigator/service in widget test)"
    - "Clamp-on-drag + clamp-on-commit off-screen guard (T-08-05)"
key-files:
  created:
    - app/remote_control/lib/widgets/trackpad_bubble.dart
    - app/remote_control/test/trackpad_bubble_test.dart
  modified: []
decisions:
  - "Bubble renders as a full-bleed Stack with the 56dp circle in a Positioned child; drag/tap gestures target the circle, not the Stack — so widget tests must aim gestures at the docked icon, not the widget's geometric center"
  - "yFraction commit uses the release top-left dy / surface height (not the center), matching the store's clamp semantics; rest render maps yFraction*height back to top-left so the drag→commit→render round-trip is stable"
  - "Snap commit fires on AnimationStatus.completed (after the 200ms tween), then _dragOffset is nulled so the widget falls back to the freshly-committed provider rest position with no visual jump"
metrics:
  duration: ~12min
  tasks: 2
  files: 2
  completed: 2026-07-15
---

# Phase 8 Plan 03: TrackpadBubble Draggable Minimized Bubble Summary

A leaf, callback-injected `TrackpadBubble` widget — a 56dp `Icons.touch_app` circle (kAccent when authed, kSurface+kMuted when not, tappable in both) that a `GestureDetector` pan drags anywhere and a 200ms `Curves.easeOut` `AnimationController` snaps to the nearest left/right edge (8px inset), persisting `(edge, yFraction)` to the 08-01 `bubblePositionProvider` with clamp-on-drag and clamp-on-commit off-screen guards.

## What Was Built

- **`lib/widgets/trackpad_bubble.dart`** — `TrackpadBubble` (`ConsumerStatefulWidget` + `SingleTickerProviderStateMixin`) taking `required VoidCallback onTap` and `required bool authed`. Renders a 56dp circle (`kBubbleSize`) in a `Positioned` inside a full-bleed `Stack`: fill `authed ? kAccent : kSurface`, `Icons.touch_app` colored `authed ? kText : kMuted`, `kHairline` border + soft drop shadow — tappable in both states ("muted, not red"). `onTap` = `hapticTick()` then the injected expand callback. A `GestureDetector(onPanStart/Update/End)` tracks a live top-left offset clamped to on-screen bounds (respecting `MediaQuery.paddingOf` top/bottom); `onPanEnd` computes `edge = center.dx > width/2 ? right : left` and `yFraction = (topLeft.dy / height).clamp(0,1)`, runs a 200ms `easeOut` tween to the edge (± `kBubbleEdgeInset` 8px), and on completion commits `BubblePosition(edge, yFraction)` via `bubblePositionProvider.notifier.set(...)`. No `Draggable`/`DragTarget`, no `ConnectionService` import.
- **`test/trackpad_bubble_test.dart`** — 6 widget cases: tap fires `onTap` (authed + not-authed, proving still-tappable), muted-gate render (kAccent/kText vs kSurface/kMuted + `Icons.touch_app` present), and drag-snap (left-half release → `Edge.left`, right-half → `Edge.right`, `yFraction` clamped to [0,1] and ≈ release-Y/height), observed on `bubblePositionProvider` after the snap animation settles. Backed by an in-memory `SharedPreferencesAsync` platform double so the store's real adapter works with no plugin channel.

## How It Works

At rest the widget reads `bubblePositionProvider` and places the circle at `_restTopLeft` — its edge (± 8px inset) at `yFraction * height`, clamped fully on-screen. `onPanStart` seeds the live `_dragOffset` from that rest point; `onPanUpdate` accumulates `d.delta` clamped to `[0, width-56] × [padding.top, height-56-padding.bottom]` so the bubble can never be dragged off-screen (T-08-05). `onPanEnd` snapshots the nearest edge and the clamped `yFraction`, then drives a 200ms `easeOut` tween of the top-left to the docked edge; the `AnimationStatus.completed` listener commits the position and nulls `_dragOffset`, so the widget falls back to the now-committed provider rest position with no jump. Because `yFraction` is clamped on commit here and the 08-01 store additionally clamps/degrades on read, the bubble can never render off-screen.

## Deviations from Plan

None — plan executed exactly as written. Tasks followed the RED → GREEN flow (failing test committed first, implementation second). The Task-2 GREEN step included a test-harness correction (aiming tap/drag gestures at the docked circle icon instead of the full-screen `Stack`'s geometric center, which does not hit-test onto the circle); this is a harness targeting fix, not a weakening of any assertion — all three behaviors (tap-callback, muted-gate, drag-snap nearest-edge + clamped yFraction) remain asserted.

## Verification

- `flutter test test/trackpad_bubble_test.dart` → **6/6 green**.
- `flutter analyze lib/widgets/trackpad_bubble.dart test/trackpad_bubble_test.dart` → **No issues found**.
- All four `must_haves.truths` proven: dual-state 56dp circle still-tappable (tap + muted-gate tests), tap fires haptic + expand callback, drag→nearest-edge snap commit, and clamped `yFraction` (both drag-snap tests + `inInclusiveRange` assertion).
- `key_link` satisfied: `onPanEnd` → `bubblePositionProvider.notifier.set(BubblePosition(edge, yFraction))`, observed committing on the provider in the drag-snap tests.

## TDD Gate Compliance

Gate sequence present in git history:
- `test(08-03)` a07ea9a (RED — widget undefined, analyze fails) → `feat(08-03)` 8b206c6 (GREEN — 6/6 pass).

No REFACTOR commit needed (implementation was clean on first green).

## Known Stubs

None — the widget is fully wired: gestures commit to the real `bubblePositionProvider`, and both visual states render live from `authed`. It has no mount site yet (that is 08-05 `BubbleScaffold` in Wave 3), which is the intended leaf-first sequencing, not a stub.

## Commits

- `a07ea9a` test(08-03): add failing TrackpadBubble tap/muted-gate/drag-snap tests
- `8b206c6` feat(08-03): implement TrackpadBubble draggable minimized-state widget

## Self-Check: PASSED

- FOUND: app/remote_control/lib/widgets/trackpad_bubble.dart
- FOUND: app/remote_control/test/trackpad_bubble_test.dart
- FOUND commits: a07ea9a, 8b206c6
