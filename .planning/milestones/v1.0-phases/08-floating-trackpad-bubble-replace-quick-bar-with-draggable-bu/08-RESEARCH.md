# Phase 8: Floating Trackpad Bubble — Research

**Researched:** 2026-07-15
**Domain:** Flutter widget architecture — behavior-neutral extraction of a hot-path input surface, floating overlay composition, draggable/edge-snap gestures, and dual position persistence
**Confidence:** HIGH (this is an all-in-codebase phase — no new packages, no external services; nearly every claim is grounded in files read this session)

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

Every item below is carried verbatim from `08-CONTEXT.md` (synthesized from the approved design spec `docs/superpowers/specs/2026-07-15-trackpad-bubble-design.md`).

**Expand model (D8-01)**
- Bubble expands into a floating window that pops out of the bubble's position (chosen over a bottom sheet).
- Bubble and window are **never both visible** — expand fades the bubble out as the window scales in (200ms); collapse reverses it.

**Bubble — minimized (D8-02)**
- New file `widgets/trackpad_bubble.dart`. 56dp circle, `kAccent` fill, `Icons.touch_app`.
- **Tap** = haptic tick + expand. **Drag** anywhere; on release animate (200ms ease-out) to nearest left/right edge, 8px inset.
- Position stored as `(edge, yFraction)` in a Riverpod `Notifier` backed by `shared_preferences`. Survives screen switches + restarts. **Default: right edge, 70% down.**
- **Muted rendering** (`kSurface` fill, muted icon) when not authed — same "muted, not red" rule as `MouseButtonsBar`; still tappable.
- **Long-press:** no action in v1.

**Window — expanded (D8-03)**
- New file `trackpad/floating_trackpad_window.dart`. Card: `kSurface` fill, `kHairline` 1px border, 16px radius, drop shadow. **Fixed size ~78% screen width × ~38% screen height.**
- Rows: (1) header bar `⠿` drag handle · inline drag-lock pill (visible only while locked) · `⤢` open full Trackpad · `✕` collapse; (2) gesture surface (`TrackpadCore`) with the same D-05 sensitivity as the full screen; (3) `MouseButtonsBar` reused as-is, muted when not authed.
- **Drag by header bar only.** Gesture-surface touches are always mouse input.
- Window always **clamped fully on-screen.** Anchor derives from the bubble spot on first-ever open; later opens restore last position.
- Position persisted as `(x, y)` fractions, **separate from the bubble position.**

**Trackpad core extraction (D8-04)**
- New file `trackpad/trackpad_core.dart`. Extract from `_TrackpadScreenState`: `GestureClassifier` + `TrackpadDriver` construction, raw pointer routes (`Listener → classifier → driver → service`, **zero setState**), sensitivity cache (`listenManual`, hot path reads a plain double), scroll-direction cache binding, disconnect-hygiene `changes` subscription (→ `driver.reset()`), CR-01 dispose contract.
- Exposed as a `TrackpadCore` widget: gesture surface with injected chrome slots.
- `TrackpadScreen` becomes a **thin composition** of `TrackpadCore` + its existing chrome.
- **Extraction is behavior-neutral: existing `TrackpadScreen` tests must pass unmodified.**

**Scaffold swap (D8-05)**
- New file `widgets/bubble_scaffold.dart` **replaces** `widgets/quick_bar_scaffold.dart`.
- Keeps the **UIPI-banner Stack contract verbatim** (top-anchored, `IgnorePointer`).
- Adds two Stack children: `TrackpadBubble` + `FloatingTrackpadWindow`.
- `showQuickBar` becomes `showBubble` — **false only for the Trackpad screen wrap.**
- **Bubble scope:** tool screens only (Keyboard, Media, Apps, Clipboard, Power, Presenter, Browser). **Not on hub, not on the Trackpad screen.**

**Migration (D8-06)**
- **Quick-bar deleted outright** — no settings toggle. Delete `_TrackpadQuickBar` and the 56px reserved Column slot.

**Lifecycle & hot-path (D8-07)**
- Hot path preserved: window pointer routes identical to the full screen — zero setState.
- Expand/collapse rides a `ValueNotifier` (Pitfall 6 localized-rebuild): the tool body never rebuilds off it.
- Disconnect hygiene per `TrackpadCore` instance (→ `driver.reset()`).
- Dispose contract (CR-01): window collapse or screen pop while drag-locked on a live socket → flush `DragMsg(end, left)` before `driver.dispose()`. **Drag-lock deliberately does NOT survive collapse.**
- keepAwake (D-14): `acquire()` on expand, `release()` on collapse/dispose. Ref-counted, so Presenter's hold survives.

**Navigation & back (D8-08)**
- `⤢`: collapses the window, then pushes the full Trackpad screen wrapped with `showBubble: false`.
- Back button: collapses the window first (one `PopScope` level); a second back leaves the screen.
- Expanded state is per-screen ephemeral — navigating away closes the window; bubble + window positions persist.

### Claude's Discretion
- Exact animation curves/implementation of the scale-out/scale-in (200ms budget fixed).
- Internal structure of the `TrackpadCore` chrome-slot API, as long as the extraction is behavior-neutral and `TrackpadScreen` tests pass unmodified.
- Widget-tree/provider wiring for the two new Riverpod position notifiers.
- Naming of private members and helper methods within the new widgets.

### Deferred Ideas (OUT OF SCOPE)
- Window resize.
- Keyboard inside the window (keyboard stays on its own tile + the full Trackpad screen).
- Bubble on the hub.
- Settings toggle to restore the quick-bar.
- Per-screen collision special-casing (bubble/window covers a control → user drags it clear).
- Bubble long-press hide menu.
</user_constraints>

<phase_requirements>
## Phase Requirements

No new REQ-IDs are mapped to this phase (ROADMAP shows TBD). This phase extends the shipped **PAD-01..05** trackpad surface and the D-10 quick-bar decision. The design spec is the authority. Candidate coverage areas the planner may reference (do not invent formal IDs):

| Candidate area | Description | Research support |
|----------------|-------------|------------------|
| Hot-path parity | Window cursor input identical to full screen (PAD-01..04) | `TrackpadCore` is the *same* widget both surfaces mount — parity by construction, verified by extraction (§Architecture Pattern 1) |
| Reuse of PAD primitives | `GestureClassifier`, `TrackpadDriver`, `MoveSender`, `MouseButtonsBar`, accel/tuning unchanged | Confirmed unchanged — extraction only relocates *construction + wiring*, not the primitives |
| CR-01 dispose flush | Drag-end flushed on collapse/pop while locked + authed | Existing `_TrackpadScreenState.dispose` logic moves into `TrackpadCore.dispose` verbatim (§Pitfall 1) |
| D-14 keep-awake | Ref-counted hold, Presenter survives | `keepAwake` already ref-counted; recommend the core owns acquire/release (§Pitfall 4) |
| D-05 sensitivity / D-11 scroll | Same caches feed the window's driver | Both caches move into `TrackpadCore` (§Architecture Pattern 1) |
</phase_requirements>

## Summary

This is a **pure Flutter refactor + new-widget phase with zero new dependencies.** The whole locked stack (Flutter 3.44.5, flutter_riverpod 3.x, shared_preferences, wakelock_plus) is already present and exercised. The work is entirely within `app/remote_control/lib`, built from primitives read this session.

The load-bearing move is a **behavior-neutral extraction** of the trackpad hot path out of `_TrackpadScreenState` into a reusable `TrackpadCore` widget, so the full Trackpad screen and the new floating window mount *the same input engine*. Because both surfaces share one `TrackpadCore`, "cursor latency in the window is indistinguishable from the full screen" is true *by construction* — the pointer routes, the sensitivity/scroll caches, the disconnect `changes` subscription, the CR-01 dispose flush, and the keepAwake hold all live in one place and cannot drift.

The overlay is **Approach A per the spec: per-screen Stack children in `BubbleScaffold`, not `OverlayEntry`.** The existing `QuickBarScaffold` already composes body + UIPI banner as `Stack` children; the bubble and window join that Stack. Expand/collapse rides a `ValueNotifier` so the tool body (a `Positioned.fill` sibling) never rebuilds — the exact localized-rebuild discipline the keyboard panel already uses (Pitfall 6). Draggable bubble edge-snap and header-only window drag use `GestureDetector` (pan) + `AnimationController`, **not** the `Draggable` widget (that is a drag-onto-`DragTarget` tool, wrong semantics here). Two independent Riverpod `Notifier`s persist the bubble `(edge, yFraction)` and window `(x, y)` fractions, cloned line-for-line from the `SensitivityNotifier`/`ScrollDirectionNotifier` house pattern.

**Primary recommendation:** Extract `TrackpadCore` first (Wave 0/1) with a widget test that pins the hot-path routes to a fake classifier/driver seam, *then* build the bubble/window/scaffold on top of the proven core. Migration is **centralized** — only `hub_screen.dart` (the central wrap point) and the scaffold file change; the 7 tool screens are wrapped centrally and need no per-screen edits.

## Architectural Responsibility Map

This is a single-tier Flutter client. "Tier" here means widget/layer ownership within the app.

| Capability | Primary Layer | Secondary Layer | Rationale |
|------------|---------------|-----------------|-----------|
| Raw pointer → classifier → driver → service (hot path) | `TrackpadCore` (new) | `ConnectionService` (send seams) | Single owner of the zero-setState route; both surfaces mount it |
| Sensitivity (D-05) / scroll-dir (D-11) hot-path caches | `TrackpadCore` (new) | `sensitivity.dart` / `scroll_direction.dart` providers | Caches must live with the driver they feed; `listenManual` binds in the core's `initState` |
| Disconnect hygiene (`changes` → `driver.reset()`) | `TrackpadCore` (new) | `ConnectionService.changes` | Per-instance subscription; each mounted core cleans its own gesture state |
| CR-01 dispose flush + `driver.dispose()` | `TrackpadCore` (new) | `ConnectionService.sendReliable` | The owed `DragMsg(end)` is the core's contract; fires on unmount (collapse or pop) |
| keepAwake hold (D-14) | `TrackpadCore` (new) | `keepAwake` singleton (ref-counted) | Core mount = acquire, unmount = release → window expand/collapse gets acquire/release for free |
| Overlay composition (bubble + window + UIPI banner) | `BubbleScaffold` (new) | `UipiBanner` (unchanged) | Owns the `Stack`, the expand/collapse `ValueNotifier`, and the `PopScope` |
| Expand/collapse animation (200ms scale+fade) | `BubbleScaffold` (stateful) | `AnimationController` | Needs a `TickerProvider`; body excluded from the rebuild subtree |
| Bubble drag + edge-snap animation | `TrackpadBubble` (new) | `AnimationController` + bubble-position Notifier | Off the hot path; free-drag then animate to edge on release |
| Header-only window drag + on-screen clamp | `FloatingTrackpadWindow` (new) | window-position Notifier | Header `GestureDetector` is spatially disjoint from the core's `Listener` — no arena conflict |
| Bubble `(edge, yFraction)` persistence | `bubble_position.dart` Notifier (new) | `shared_preferences` (non-secret) | Mirrors `SensitivityNotifier` two-half store pattern |
| Window `(x, y)` persistence | `window_position.dart` Notifier (new) | `shared_preferences` (non-secret) | Independent second Notifier; default = derive-from-bubble sentinel |

## Standard Stack

**No new packages. Everything below is already in `pubspec.yaml` and used in files read this session.**

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| Flutter SDK | 3.44.5 stable (verified via `flutter --version`, revision f94f4fc76b, 2026-07-06) | Widget framework, `Stack`/`GestureDetector`/`AnimationController`/`PopScope`/`ValueNotifier` | Locked stack; all overlay + gesture primitives are first-party [VERIFIED: `flutter --version`] |
| flutter_riverpod | 3.x (`Notifier`/`NotifierProvider` in use in `sensitivity.dart`, `scroll_direction.dart`) | Two new position notifiers | House pattern already established; Riverpod 3 unified `Notifier` [VERIFIED: codebase grep] |
| shared_preferences | present (`SharedPreferencesAsync` used in `sensitivity.dart`) | Non-secret position persistence | Correct store for non-secrets per CLAUDE.md rule [VERIFIED: codebase grep] |
| wakelock_plus | present (wrapped by `keep_awake.dart`) | keepAwake hold on expand | Already ref-counted via `KeepAwake` singleton [VERIFIED: `lib/widgets/keep_awake.dart`] |

### Supporting (reused unchanged — do NOT modify)
| Symbol | File | Purpose |
|--------|------|---------|
| `GestureClassifier` | `trackpad/gesture_classifier.dart` | Pure FSM; construction moves to `TrackpadCore`, class unchanged |
| `TrackpadDriver` | `trackpad/trackpad_driver.dart` | Intent executor; construction+wiring moves to `TrackpadCore`, class unchanged |
| `MouseButtonsBar` | `trackpad/mouse_buttons.dart` | Reused as-is in the window (muted when not authed) |
| `MoveSender`, `accel.dart`, `tuning.dart` | `trackpad/` | Reused unchanged |
| `UipiBanner` | `widgets/uipi_banner.dart` | Stack contract preserved verbatim in `BubbleScaffold` |
| `keepAwake` | `widgets/keep_awake.dart` | Ref-counted hold; `acquire`/`release` API confirmed present |
| `kAccent`/`kSurface`/`kHairline`/`kText`/`kMuted`/`kBg` | `theme/tokens.dart` | Design tokens for bubble + window chrome |
| `SensitivityNotifier` / `ScrollDirectionNotifier` | `settings/` | **Copy-the-pattern templates** for the two new position notifiers |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| Stack children in `BubbleScaffold` (Approach A) | `Overlay` / `OverlayEntry` | OverlayEntry detaches from the widget subtree, complicating per-screen-ephemeral lifecycle, `PopScope` interception, and the ValueNotifier localized-rebuild. Spec locks Approach A. **Use Stack children.** |
| `GestureDetector` pan + `AnimationController` | `Draggable`/`DragTarget` widget | `Draggable` models drag-*onto-a-target* with a feedback widget — wrong semantics for free-move-then-snap. **Use GestureDetector.** |
| Bubble drives position via `ValueNotifier<Offset>` | `setState` during drag | `setState` is acceptable here (bubble is off the hot path), but a local `ValueNotifier` keeps the rebuild scoped. Discretion. |

**Installation:** none — no `pub add` required. Confirm with `flutter pub get` after edits only.

## Package Legitimacy Audit

**Not applicable — this phase installs no external packages.** All symbols come from the already-locked, already-installed stack (Flutter first-party, flutter_riverpod, shared_preferences, wakelock_plus). No `pub add`, no new transitive dependencies. No SLOP/SUS surface.

**Packages removed due to [SLOP] verdict:** none
**Packages flagged as suspicious [SUS]:** none

## Architecture Patterns

### System Architecture Diagram

```
                         BubbleScaffold  (StatefulWidget, replaces QuickBarScaffold)
                         owns: expand ValueNotifier<bool>  +  AnimationController  +  PopScope
  ┌───────────────────────────────────────────────────────────────────────────────┐
  │ Stack                                                                           │
  │  ├─ Positioned.fill(child: body)  ◄── tool screen; NEVER rebuilds off expand    │
  │  │        (Media / Apps / Power / Keyboard / Clipboard / Presenter / Browser)   │
  │  │                                                                              │
  │  ├─ Positioned(top): SafeArea → UipiBanner.forService(service)  [UNCHANGED]     │
  │  │        (IgnorePointer-wrapped — never steals a body touch)                   │
  │  │                                                                              │
  │  └─ ValueListenableBuilder<bool>(expand) ──► renders EITHER:                    │
  │         ├─ collapsed → TrackpadBubble  (Positioned at bubble (edge,yFraction))  │
  │         │      tap ─────────────────────────────► expand.value = true           │
  │         │      pan+release ──► animate to nearest edge ──► bubblePosNotifier     │
  │         │                                                                        │
  │         └─ expanded → FloatingTrackpadWindow (Positioned at window (x,y))        │
  │                header:  ⠿drag(GestureDetector→clamp→windowPosNotifier)          │
  │                         · drag-lock pill (ValueListenable from core)            │
  │                         · ⤢ (collapse → push TrackpadScreen showBubble:false)   │
  │                         · ✕ (expand.value = false)                              │
  │                surface: TrackpadCore  ─┐                                        │
  │                buttons: MouseButtonsBar │                                        │
  └─────────────────────────────────────────┼──────────────────────────────────────┘
                                             │
        TrackpadCore  (the extracted hot-path engine — mounted here AND on full screen)
        ┌────────────────────────────────────▼─────────────────────────────────────┐
        │ Listener(onPointerDown/Move/Up/Cancel, HitTestBehavior.opaque)  ZERO setState │
        │   → GestureClassifier (pure FSM)  → TrackpadDriver → ConnectionService sends  │
        │ caches:  _sensitivity (listenManual)   scrollReversedCached (bindScroll…)      │
        │ subs:    changes → on transition INTO disconnected → driver.reset()            │
        │ hold:    keepAwake.acquire() @initState / release() @dispose  (ref-counted)    │
        │ dispose: if dragLocked && authed → sendReliable(DragMsg end,left); driver.dispose│
        │ exposes: ValueListenable<bool> dragLocked  +  chrome slots (discretion)         │
        └───────────────────────────────────────────────────────────────────────────────┘
```

### Recommended Project Structure
```
app/remote_control/lib/
├── trackpad/
│   ├── trackpad_core.dart            # NEW — extracted hot-path engine (D8-04)
│   ├── floating_trackpad_window.dart # NEW — expanded card (D8-03)
│   ├── trackpad_screen.dart          # SLIMMED — thin composition of TrackpadCore + chrome
│   ├── gesture_classifier.dart       # unchanged
│   ├── trackpad_driver.dart          # unchanged
│   ├── mouse_buttons.dart            # unchanged (reused in window)
│   ├── move_sender.dart / accel.dart / tuning.dart  # unchanged
├── widgets/
│   ├── bubble_scaffold.dart          # NEW — replaces quick_bar_scaffold.dart (D8-05)
│   ├── trackpad_bubble.dart          # NEW — minimized draggable bubble (D8-02)
│   ├── quick_bar_scaffold.dart       # DELETED (D8-06)
│   ├── uipi_banner.dart / keep_awake.dart  # unchanged
├── settings/                          # or trackpad/ — planner discretion
│   ├── bubble_position.dart          # NEW — (edge,yFraction) store+Notifier
│   └── window_position.dart          # NEW — (x,y) fraction store+Notifier
```

### Pattern 1: Behavior-neutral extraction of `TrackpadCore`

**What:** Relocate the hot-path machinery from `_TrackpadScreenState` (read this session, `trackpad_screen.dart` L58–198) into a new `TrackpadCore` widget, leaving `TrackpadScreen` a thin composition.

**Exact move/stay map** (grounded in the current file):

| Concern | Current location | Destination |
|---------|------------------|-------------|
| `_service = ref.read(connectionServiceProvider)` | initState L96 | **MOVE** to core |
| `ref.listenManual(sensitivityProvider…)` → `_sensitivity` cache | L101–105 | **MOVE** to core |
| `bindScrollDirectionCache(ref)` | L111 | **MOVE** to core |
| `_classifier = GestureClassifier(...)` | L113–115 | **MOVE** to core |
| `_driver = TrackpadDriver(...)` (all seams incl. `onDragLockChanged`) | L116–128 | **MOVE** to core |
| `_changesSub` + `_lastChip` disconnect hygiene → `driver.reset()` | L143–151 | **MOVE** to core |
| `keepAwake.acquire()` / `release()` | L156 / L173 | **MOVE** to core *(see Pitfall 4)* |
| `_onPointerDown/Move/Up/Cancel` + the `Listener` (`Positioned.fill`) | L180–198, L268–286 | **MOVE** to core |
| CR-01 dispose flush (`if _driver.dragLocked && _service.isAuthed → DragMsg(end)`) + `_driver.dispose()` | L160–169 | **MOVE** to core |
| `_dragLockPill` `ValueNotifier<bool>` | L71 | **MOVE** to core; **EXPOSE** as `ValueListenable<bool> dragLocked` for chrome |
| `_imeProducer`, `_imeFocusNode`, `_panelExpanded`, keyboard panel, tune sheet, `_onMouseButton`, header chip/banner, drag-lock **pill widget placement** | scattered | **STAY** in `TrackpadScreen` (window does NOT get keyboard/tune — Deferred) |

**Chrome-slot API (discretion):** expose `TrackpadCore` as a widget taking the gesture surface hint text + an optional `overlayBuilder`/child slots and exposing `ValueListenable<bool> get dragLocked`. The full screen supplies its top-center pill, tune cluster, keyboard toggle; the window supplies its inline header pill. Both read the *same* `dragLocked` listenable.

**When to use:** always — this is the phase's foundation. Land it + its test before any bubble/window UI.

```dart
// Source: pattern derived from trackpad_screen.dart (read 2026-07-15) — the
// four handlers move verbatim; the invariant is ZERO setState on this route.
Listener(
  onPointerDown: (e) => _driver.handle(
      _classifier.onPointerDown(e.pointer, e.position.dx, e.position.dy)),
  onPointerMove: (e) => _driver.handle(
      _classifier.onPointerMove(e.pointer, e.position.dx, e.position.dy)),
  onPointerUp:   (e) => _driver.handle(_classifier.onPointerUp(e.pointer)),
  onPointerCancel:(e)=> _driver.handle(_classifier.onPointerCancel(e.pointer)),
  behavior: HitTestBehavior.opaque,
  child: /* surface */,
)
```

### Pattern 2: Overlay via Stack children + localized-rebuild expand (Approach A)

**What:** `BubbleScaffold` becomes a `ConsumerStatefulWidget` (from today's stateless `ConsumerWidget`) with `SingleTickerProviderStateMixin`. Body + UIPI banner stay as they are; the bubble/window are added Stack children gated by a `ValueListenableBuilder<bool>` so the tool body never rebuilds on expand/collapse.

**Why the body stays hit-testable around the window:** in a `Stack`, the body (`Positioned.fill`) sits *below* the window. The window occupies ~78%×38% at its position; everywhere it is *not*, taps fall through to the body. No `IgnorePointer` needed on the body; the window itself is opaque only over its own rect. This is the same reason the current UIPI banner (IgnorePointer-wrapped) never steals body touches.

```dart
// Source: quick_bar_scaffold.dart Stack (read 2026-07-15) — extended.
Stack(children: [
  Positioned.fill(child: body),                       // never rebuilds off expand
  Positioned(top:0,left:0,right:0,
    child: SafeArea(bottom:false, child: UipiBanner.forService(service))), // UNCHANGED
  ValueListenableBuilder<bool>(                        // ONLY this subtree rebuilds
    valueListenable: _expanded,
    builder: (_, expanded, __) => expanded
        ? FloatingTrackpadWindow(/* … */)
        : TrackpadBubble(onTap: () => _expanded.value = true, /* … */),
  ),
])
```

### Pattern 3: Draggable bubble with edge-snap

**What:** `GestureDetector(onPanStart/onPanUpdate/onPanEnd)` tracks a live offset; on release an `AnimationController` (200ms, `Curves.easeOut`) tweens to the nearest left/right edge with an 8px inset, then commits `(edge, yFraction)` to the bubble Notifier. Clamp the drag to on-screen bounds using `MediaQuery.sizeOf(context)`.

**When to use:** the bubble only. Nearest edge = `dx < screenWidth/2 ? left : right`. yFraction persisted from the release Y clamped to `[0,1]` (respect safe-area top/bottom).

### Pattern 4: Header-only window drag with on-screen clamp

**What:** a `GestureDetector` wrapping *only* the header `⠿` region calls `onPanUpdate` to move the window offset, clamped so the full card stays on-screen; `onPanEnd` persists `(x, y)` fractions. The gesture surface (`TrackpadCore`'s `Listener`) is a **separate sibling** in the window's Column — a touch on the surface hits the opaque `Listener`, a touch on the header hits the header `GestureDetector`. They never contend because they occupy disjoint rects. This is exactly why the spec can promise "gesture-surface touches are always mouse input."

### Pattern 5: Dual position persistence (two independent Notifiers)

**What:** clone the `SensitivityNotifier`/`ScrollDirectionNotifier` two-half pattern (read this session) twice:

- `BubblePositionStore` + `BubblePositionNotifier` → model `(edge: enum{left,right}, yFraction: double)`. Default `(right, 0.70)`. Clamp yFraction `[0,1]`; degrade corrupt/missing read to default.
- `WindowPositionStore` + `WindowPositionNotifier` → model `(xFraction, yFraction)`. Default = **sentinel "unset"** so `FloatingTrackpadWindow` knows to anchor from the bubble spot on first-ever open; after any move it stores the real fractions.

Serialize each as a small JSON string (mirrors `device_store.dart`'s `devices` JSON) or two keys each; discretion. Reuse `SharedPreferencesAsync` (non-secret — never secure storage).

```dart
// Source: sensitivity.dart / scroll_direction.dart house pattern (read 2026-07-15).
class BubblePositionNotifier extends Notifier<BubblePosition> {
  @override
  BubblePosition build() {
    unawaited(_load(ref.watch(bubblePositionStoreProvider)));
    return const BubblePosition(edge: Edge.right, yFraction: 0.70); // sync seed
  }
  Future<void> _load(BubblePositionStore s) async => state = await s.load();
  void set(BubblePosition p) { state = p; unawaited(ref.read(bubblePositionStoreProvider).save(p)); }
}
```

### Anti-Patterns to Avoid
- **`OverlayEntry` for the window** — detaches from the subtree, fights `PopScope` + per-screen-ephemeral lifecycle. Spec locks Stack children.
- **`Draggable`/`DragTarget`** — drag-onto-target semantics; wrong for free-move + snap.
- **Any `setState` on the gesture route** — breaks the PAD-01 hot-path invariant. The core routes are classifier→driver→service only.
- **Rebuilding the tool body off the expand notifier** — put the body OUTSIDE the `ValueListenableBuilder` (Pitfall 6).
- **Two keepAwake acquires for one logical hold** — if the core owns keepAwake, do NOT also acquire in `BubbleScaffold`/window (would double-count; harmless with ref-count but muddies intent). One owner: the core.
- **Persisting positions in `flutter_secure_storage`** — non-secret; use shared_preferences (CLAUDE.md rule).
- **Editing the 7 tool screens for migration** — they are wrapped centrally in `hub_screen._open`; only the scaffold + hub change.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Keep-awake ref counting across window/presenter | A new counter | `keepAwake` singleton (`KeepAwake`, ref-counted) | Already solves Pitfall 8; `acquire`/`release` verified in `keep_awake.dart` |
| Non-secret pref store + Riverpod Notifier | New store scaffolding | Clone `SensitivityStore`/`SensitivityNotifier` | Established two-half pattern with clamped/degrading reads |
| Back-button intercept | `WillPopScope` (deprecated) | `PopScope` (see State of the Art) | 3.44 first-party; deprecation trap below |
| Drag-lock indicator state | New bool plumbing | Reuse the driver's `onDragLockChanged` → `ValueNotifier` already wired | Exposed from `TrackpadCore` as `ValueListenable<bool>` |
| Edge-snap / expand animation | Manual `Timer` frame loop | `AnimationController` + `Tween`/`Curves.easeOut` | First-party, vsync-driven, cancelable |

**Key insight:** this phase is 90% *relocation and composition of already-correct code*. The risk is not "what to build" but "moving the hot path without changing its behavior." Every seam the driver/classifier need is already injectable and already tested.

## Runtime State Inventory

> Included because this phase deletes a widget and adds a refactor/extraction. There is no string-rename or data-key migration.

| Category | Items Found | Action Required |
|----------|-------------|------------------|
| Stored data | **None keyed by a renamed string.** The quick-bar persisted nothing. Two NEW shared_preferences keys are *added* (bubble + window position) — greenfield keys, no migration. | Choose two new stable pref key strings; document them |
| Live service config | None — no external service holds any state for this feature. | None |
| OS-registered state | None — no OS registrations touch the quick-bar or bubble. | None |
| Secrets/env vars | None — positions are non-secret; auth token untouched. | None |
| Build artifacts | Deleting `quick_bar_scaffold.dart` + `quick_bar_test.dart` removes symbols (`QuickBarScaffold`, `kQuickBarLabel`, `kQuickBarHeight`). Any import of these breaks the build. | Grep confirms importers: `hub_screen.dart` (real import) + `keyboard_screen.dart` (doc-comment reference only). Update the import in `hub_screen.dart`; adjust the keyboard doc comment |

**Verified importers of the deleted symbols:** `lib/hub/hub_screen.dart` (line 51 import + `_open` wrap), `lib/keyboard/keyboard_screen.dart` (doc comment mention only), and `test/quick_bar_test.dart` (superseded). No other `QuickBarScaffold`/`showQuickBar` references exist in `lib/` [VERIFIED: Grep this session].

## Common Pitfalls

### Pitfall 1: Breaking the CR-01 dispose flush during extraction
**What goes wrong:** the owed `DragMsg(end, left)` is dropped when the window collapses (or the screen pops) while drag-locked on a live socket → the PC's left button stays held behind a bubble.
**Why it happens:** `_driver.dispose()` deliberately sends nothing (read `trackpad_driver.dart` L169–173); the flush lives in `_TrackpadScreenState.dispose` (L160–169). If the extraction forgets to carry the *exact* `if (_driver.dragLocked && _service.isAuthed) sendReliable(DragMsg end)` guard into `TrackpadCore.dispose`, the contract silently breaks.
**How to avoid:** move the guard verbatim into `TrackpadCore.dispose`, *before* `_driver.dispose()`. This now fires on **both** window collapse and screen pop (the core unmounts in both) — which is precisely D8-07's "drag-lock does NOT survive collapse."
**Warning signs:** the 4-quadrant dispose test (drag-locked×authed) fails; PC cursor stuck dragging after `✕`.

### Pitfall 2: Header drag vs. gesture-surface arena contention
**What goes wrong:** dragging the window also moves the cursor, or a surface touch drags the window.
**Why it happens:** placing the header `GestureDetector` as an *ancestor* of the surface, or making the surface non-opaque, lets pan gestures bubble.
**How to avoid:** header `GestureDetector` and the core `Listener` are **sibling** subtrees in the window Column, spatially disjoint. Keep `HitTestBehavior.opaque` on the core `Listener`. Only the header region is draggable.
**Warning signs:** cursor jumps while repositioning the window.

### Pitfall 3: Tool body rebuilding on expand/collapse (hot-path leak)
**What goes wrong:** expanding the window rebuilds the whole tool screen, causing jank / dropped input.
**Why it happens:** putting `body` *inside* the `ValueListenableBuilder(expanded)` subtree.
**How to avoid:** body is a `Positioned.fill` sibling ABOVE the builder in the Stack; only the bubble/window subtree rides the notifier — the exact discipline `_TrackpadScreenState` uses for `_panelExpanded` (L414, keyboard panel) and `_dragLockPill` (L324).
**Warning signs:** a `build()` on the tool screen fires on every expand; profiler shows body rebuild.

### Pitfall 4: keepAwake double-count or drop across Presenter
**What goes wrong:** opening the window on the Presenter screen, then collapsing, drops Presenter's keep-awake; or the hold leaks after collapse.
**Why it happens:** `keepAwake` is a shared ref-count (read `keep_awake.dart`). If the core acquires on mount and releases on unmount, Presenter (which holds its own `acquire` in `presenter_screen.dart` L82) stays at count≥1 through the window's 1→2→1 excursion. Correct. But if *both* the core AND the scaffold acquire, the count is off (harmless underflow-guarded, but wrong intent).
**How to avoid:** **single owner — the core.** Core `initState` = `acquire()`, `dispose` = `release()`. Window expand mounts the core (acquire); collapse unmounts it (release). This makes D8-07's "acquire on expand / release on collapse" automatic and keeps the full Trackpad screen behavior-neutral (it still nets one acquire via its single core).
**Warning signs:** `keep_awake_test`-style count assertions fail; screen dims mid-present after a window excursion.

### Pitfall 5: `showBubble:false` on the wrong screens
**What goes wrong:** a bubble appears on the hub or on the full Trackpad screen; or is missing from a tool screen.
**Why it happens:** the flag rename `showQuickBar → showBubble` must keep the *exact* current wiring: hub wraps every tile via `QuickBarScaffold` centrally, Trackpad tile passes `false`, hub itself is NOT wrapped.
**How to avoid:** the hub screen (`hub_screen.dart`) is never wrapped — verified: `HubScreen.build` returns a bare `Scaffold`, and `_open` wraps *destinations* only. Keep it that way. `HubTileSpec.showQuickBar` → `showBubble`; only the Trackpad tile stays `false`.
**Warning signs:** `BubbleScaffold` presence/absence widget test fails; bubble on hub.

### Pitfall 6: `PopScope` deprecation trap (see State of the Art)
**What goes wrong:** using `onPopInvoked` (deprecated) or `WillPopScope` (removed path) → analyzer warnings or wrong pop semantics.
**How to avoid:** use `PopScope(canPop: !expanded, onPopInvokedWithResult: (didPop, result) { if (!didPop) collapse(); })`. Set `canPop` from the expand notifier so the *first* back collapses (intercept) and the *second* back pops the route.
**Warning signs:** back button leaves the screen while the window is open, or double-back needed everywhere.

### Pitfall 7: "Existing TrackpadScreen tests must pass unmodified" — but there is no widget test for it
**What goes wrong:** the constraint is read as "a safety net exists," but `test/` has **no `trackpad_screen_test.dart`** — only unit tests for the *primitives* (`trackpad_driver_test`, `gesture_classifier_test`, `accel_test`, `mouse_buttons_test`).
**Why it matters:** those primitive tests pass trivially after extraction (the classes don't change), so "pass unmodified" is satisfied *but proves nothing about the extraction's behavior-neutrality*. There is no automated guard that `TrackpadScreen` still wires the hot path correctly.
**How to avoid:** **Wave 0 must add** a `TrackpadCore` widget test (pointer events → fake classifier/driver seam; dispose flush; keepAwake count) AND a thin `TrackpadScreen` composition smoke test. Treat this as a gap to fill, not an existing net.
**Warning signs:** confidently shipping the extraction with green tests that never exercised the screen.

## Code Examples

### PopScope back-intercept (collapse-first)
```dart
// Source: Flutter 3.44 PopScope API (onPopInvokedWithResult; see State of the Art).
return PopScope(
  canPop: !_expanded.value,                 // drive from the expand notifier
  onPopInvokedWithResult: (didPop, result) {
    if (!didPop) _expanded.value = false;   // first back collapses the window
  },
  child: /* the Stack */,
);
```

### Nearest-edge snap on release
```dart
// Source: pattern for D8-02 edge-snap (GestureDetector + AnimationController).
void _onPanEnd(DragEndDetails _) {
  final size = MediaQuery.sizeOf(context);
  final toRight = _dragOffset.dx + kBubbleSize / 2 > size.width / 2;
  final edge = toRight ? Edge.right : Edge.left;
  final yFraction = (_dragOffset.dy / size.height).clamp(0.0, 1.0);
  _snapController.forward(from: 0); // 200ms Curves.easeOut to (edge, 8px inset)
  ref.read(bubblePositionProvider.notifier).set(
      BubblePosition(edge: edge, yFraction: yFraction));
}
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| `WillPopScope` | `PopScope` | Flutter 3.12+ (WillPopScope removed) | Use `PopScope` for the back-intercept [CITED: Flutter migration guide] |
| `PopScope(onPopInvoked:)` | `PopScope(onPopInvokedWithResult:)` | `onPopInvoked` deprecated ~3.22 | Use `onPopInvokedWithResult` on 3.44.5 [ASSUMED — planner should confirm the exact callback name against the pinned SDK; both compile, deprecated one warns] |
| Riverpod 2 `StateNotifier`/`AutoDispose`/`Family` | Riverpod 3 unified `Notifier` | Riverpod 3 (locked stack) | New position notifiers use `Notifier` (matches `sensitivity.dart`) [VERIFIED: codebase] |
| `thread_rng()`-era snippets | n/a (no rand here) | — | Not applicable to this phase |

**Deprecated/outdated:**
- `QuickBarScaffold` / `_TrackpadQuickBar` / `kQuickBarLabel` / `kQuickBarHeight` — deleted this phase (D8-06).

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | Flutter 3.44.5 `PopScope` uses `onPopInvokedWithResult` (not `onPopInvoked`) | State of the Art / Code Examples | LOW — both compile; the deprecated name only warns. Planner adds a task to use the non-deprecated callback and let the analyzer confirm |
| A2 | Window size ~78%w × ~38%h fits its three rows (header + surface + `MouseButtonsBar` 64px) on typical phones without overflow | D8-03 | MEDIUM — on very short screens 38% may crowd the 64px button bar; verify with a layout test + on-device UAT; clamp/scroll-safe if needed |
| A3 | Making `keepAwake` the core's sole responsibility keeps the full Trackpad screen behavior-neutral (still nets exactly one acquire) | Pitfall 4 | LOW — the full screen mounts exactly one core; net hold identical to today |
| A4 | Deriving the window anchor from the bubble spot on first open, via a "unset" sentinel in the window store, is acceptable UX | Pattern 5 | LOW — matches spec D8-03 verbatim |

## Open Questions

1. **Where do the two position notifiers live — `settings/` or `trackpad/`?**
   - What we know: `sensitivity.dart`/`scroll_direction.dart` live in `settings/`; positions are trackpad-specific UI state.
   - What's unclear: whether the house prefers colocating with the feature (`trackpad/`) or the settings store folder.
   - Recommendation: `settings/` for consistency with the existing store pattern; either is fine (Claude's Discretion covers provider wiring).

2. **Exact window height safety on short devices (A2).**
   - What we know: fixed ~38% height + a 64px `MouseButtonsBar` + header.
   - What's unclear: minimum device height where rows crowd.
   - Recommendation: add a widget test asserting no overflow at a small test surface (e.g. 360×640) and flag on-device UAT.

## Environment Availability

> This phase has **no external dependencies** beyond the already-installed Flutter toolchain. Skipping detailed probing.

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| Flutter SDK | entire phase | ✓ | 3.44.5 stable | — |
| Dart SDK | entire phase | ✓ | ^3.12.2 (pubspec) | — |
| flutter_riverpod / shared_preferences / wakelock_plus | notifiers, persistence, keepAwake | ✓ | already in pubspec | — |

**Missing dependencies with no fallback:** none.
**Missing dependencies with fallback:** none.

## Validation Architecture

> Nyquist validation is enabled (`workflow.nyquist_validation: true`). This section drives VALIDATION.md.

### Test Framework
| Property | Value |
|----------|-------|
| Framework | `flutter_test` (bundled with Flutter 3.44.5) |
| Config file | none — standard `test/` tree; run via `flutter test` |
| Quick run command | `flutter test test/trackpad/ test/bubble_scaffold_test.dart test/trackpad_bubble_test.dart` (scoped) |
| Full suite command | `flutter test` (from `app/remote_control/`) |

### Phase Requirements → Test Map
| Area | Behavior | Test Type | Automated Command | File Exists? |
|------|----------|-----------|-------------------|-------------|
| Extraction net | Pointer events on `TrackpadCore` reach a fake classifier/driver seam; zero setState | widget | `flutter test test/trackpad/trackpad_core_test.dart` | ❌ Wave 0 |
| CR-01 flush | `DragMsg(end)` sent ONLY when drag-locked AND authed (4-quadrant) on core dispose | unit/widget | `flutter test test/trackpad/trackpad_core_test.dart` | ❌ Wave 0 |
| keepAwake | Core mount acquires / dispose releases; Presenter hold survives a window excursion | unit/widget | `flutter test test/keep_awake_test.dart` (extend) | ⚠️ extend existing |
| Composition | `TrackpadScreen` still renders surface + drag-lock pill + tune + keyboard toggle after slimming | widget | `flutter test test/trackpad/trackpad_screen_test.dart` | ❌ Wave 0 |
| Bubble drag/snap | Drag → snaps to nearest edge; position notifier updated; 8px inset | widget | `flutter test test/trackpad_bubble_test.dart` | ❌ Wave 0 |
| Bubble tap/haptic | Tap fires expand callback + haptic tick | widget | `flutter test test/trackpad_bubble_test.dart` | ❌ Wave 0 |
| Bubble muted | `kSurface` fill + muted icon when not authed; still tappable | widget | `flutter test test/trackpad_bubble_test.dart` | ❌ Wave 0 |
| Window header drag | Header pan moves + clamps window; surface touches do NOT move it | widget | `flutter test test/floating_trackpad_window_test.dart` | ❌ Wave 0 |
| Window header buttons | `⤢`/`✕` fire callbacks; drag-lock pill appears via listenable | widget | `flutter test test/floating_trackpad_window_test.dart` | ❌ Wave 0 |
| Scaffold presence | Bubble present on tool screens, absent with `showBubble:false`; UIPI slot unchanged; body around the open window stays hit-testable | widget | `flutter test test/bubble_scaffold_test.dart` | ❌ Wave 0 (supersedes `quick_bar_test.dart`) |
| Bubble persistence | `(edge, yFraction)` round-trip + default `(right, 0.70)` + corrupt-read degrade | unit | `flutter test test/bubble_position_test.dart` | ❌ Wave 0 |
| Window persistence | `(x, y)` round-trip + unset-sentinel default + corrupt-read degrade | unit | `flutter test test/window_position_test.dart` | ❌ Wave 0 |
| Migration | `QuickBarScaffold` symbols gone; hub compiles against `BubbleScaffold` | build | `flutter analyze && flutter test` | ✅ (compile-time) |

### Sampling Rate
- **Per task commit:** the scoped quick run for the file(s) touched.
- **Per wave merge:** `flutter test` (full suite) + `flutter analyze`.
- **Phase gate:** full suite + analyzer green before `/gsd-verify-work`.

### Wave 0 Gaps
- [ ] `test/trackpad/trackpad_core_test.dart` — extraction net: pointer→seam, zero-setState, CR-01 4-quadrant, keepAwake count. **(Primary safety net — Pitfall 7.)**
- [ ] `test/trackpad/trackpad_screen_test.dart` — thin-composition smoke test (currently NONE exists).
- [ ] `test/trackpad_bubble_test.dart` — drag/snap/tap/haptic/muted.
- [ ] `test/floating_trackpad_window_test.dart` — header drag/clamp, buttons, pill, surface-is-mouse.
- [ ] `test/bubble_scaffold_test.dart` — presence/absence, UIPI slot, body hit-testable (supersedes `test/quick_bar_test.dart`; delete that file).
- [ ] `test/bubble_position_test.dart`, `test/window_position_test.dart` — persistence round-trips (mirror `scroll_direction_test.dart` / `device_store_test.dart`).
- [ ] Extend `test/keep_awake_test.dart` for the window-excursion / Presenter-survival scenario.
- Framework install: none — `flutter_test` already present.

### UAT items (device-only, cannot be automated)
- Cursor latency from the window indistinguishable from the full screen (parity is structural, but confirm on-device).
- Drag bubble + window on every tool screen; positions restore after app restart.
- Power screen + window overlap: drag window clear, confirm the double-confirm power flow is unobstructed.
- Reconnect and disconnect while the window is open (muted state, `driver.reset` on drop, no stuck drag).
- Presenter + window: keep-awake never drops during a window open/close excursion.

## Security Domain

> `security_enforcement: true`, ASVS level 1. This is a client-only UI phase with **no new network surface, no new secrets, no new auth path.**

### Applicable ASVS Categories
| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V2 Authentication | no | No auth change; bubble/window read the existing `authed` status only |
| V3 Session Management | no | No session change |
| V4 Access Control | no | LAN-only binding + token auth unchanged |
| V5 Input Validation | yes (light) | Persisted position fractions are clamped on read (`[0,1]`, edge enum) and degrade to default on corrupt/missing — same discipline as `SensitivityStore` |
| V6 Cryptography | no | Positions are non-secret; stored in shared_preferences by rule, never secure storage / never near the auth token |
| V7 Error Handling | yes (light) | A failed prefs read/write costs persistence, never responsiveness (house pattern) |

### Known Threat Patterns for this stack
| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| Corrupt/out-of-range stored fraction → off-screen or invisible bubble | Tampering / DoS-of-UX | Clamp on read + default fallback (mirror `SensitivityStore.load`); window always clamped fully on-screen |
| Stuck held mouse button behind a collapsed window | (server-side input integrity) | CR-01 dispose flush + CONN-07 `release_all` — preserved verbatim in `TrackpadCore` (Pitfall 1) |
| Secret leakage into non-secret store | Information disclosure | N/A here — no secret touched; positions are non-secret by construction |

**Net:** no new attack surface. The only security-relevant discipline is clamping/degrading the two new non-secret prefs, already the established house pattern.

## Sources

### Primary (HIGH confidence — read this session)
- `lib/trackpad/trackpad_screen.dart` — hot-path routes, sensitivity/scroll caches, disconnect sub, CR-01 dispose, keepAwake, pill/panel notifiers (the extraction source of truth).
- `lib/trackpad/trackpad_driver.dart` — `dragLocked`, `reset()`, `dispose()` (sends nothing) semantics.
- `lib/widgets/quick_bar_scaffold.dart` — Stack contract, UIPI banner placement, `_openTrackpad` push, `showQuickBar` flag.
- `lib/widgets/keep_awake.dart` — ref-counted `acquire`/`release` (D-14, Pitfall 8).
- `lib/hub/hub_screen.dart` — central wrap point, `HubTileSpec.showQuickBar`, Trackpad tile `false`, hub itself unwrapped.
- `lib/settings/sensitivity.dart`, `lib/settings/scroll_direction.dart` — the two-half store+Notifier persistence pattern to clone.
- `lib/trackpad/mouse_buttons.dart`, `lib/theme/tokens.dart` — reused chrome + tokens.
- `lib/presenter/presenter_screen.dart` — Presenter's own keepAwake hold (ref-count survival requirement).
- `test/quick_bar_test.dart`, `test/scroll_direction_test.dart`, `test/trackpad/trackpad_driver_test.dart`, `test/device_store_test.dart` — callback-injection / fake-KV / harness test idioms to mirror.
- `flutter --version` → 3.44.5 stable, revision f94f4fc76b; `pubspec.yaml` sdk `^3.12.2` [VERIFIED].
- Grep for `QuickBarScaffold|showQuickBar`, `keepAwake.`, `PopScope|Overlay|Draggable` — confirmed importers and the absence of any existing overlay/draggable/PopScope pattern in `lib/`.

### Secondary (MEDIUM confidence)
- Flutter `PopScope`/`WillPopScope` migration (training knowledge cross-checked against installed 3.44.5) — the `onPopInvokedWithResult` callback name flagged as A1 for planner confirmation.

### Tertiary (LOW confidence)
- Window ~38% height fit on short devices (A2) — needs a layout test + on-device UAT.

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH — no new packages; every symbol read in-repo this session.
- Architecture (extraction + overlay + persistence): HIGH — grounded in exact current code and the established house patterns.
- Pitfalls: HIGH — each traces to a specific line/contract read this session.
- PopScope callback name: MEDIUM — flagged A1.
- Window layout fit on small screens: MEDIUM — flagged A2.

**Research date:** 2026-07-15
**Valid until:** 2026-08-14 (stable — internal Flutter refactor, no fast-moving external deps)
