# Phase 8: Floating Trackpad Bubble - Pattern Map

**Mapped:** 2026-07-15
**Files analyzed:** 11 (7 create, 3 modify, 2 delete)
**Analogs found:** 11 / 11 (every new/modified file has an in-repo analog — this is a pure refactor+compose phase)

All paths below are relative to `app/remote_control/`. Line numbers reference files read 2026-07-15.

## File Classification

| New/Modified File | Role | Data Flow | Closest Analog | Match Quality |
|-------------------|------|-----------|----------------|---------------|
| CREATE `lib/trackpad/trackpad_core.dart` | widget (hot-path engine) | event-driven (pointer→classifier→driver→service) | `lib/trackpad/trackpad_screen.dart` `_TrackpadScreenState` L58–198 | exact (extraction source) |
| CREATE `lib/widgets/trackpad_bubble.dart` | widget (component) | event-driven (drag/tap gesture) | `lib/trackpad/mouse_buttons.dart` (muted-gate + callback), `_TrackpadQuickBar` in `quick_bar_scaffold.dart` L115–157 (icon/affordance) | role-match |
| CREATE `lib/trackpad/floating_trackpad_window.dart` | widget (component) | event-driven + request-response (buttons) | `trackpad_screen.dart` chrome (L248–435), `mouse_buttons.dart` | role-match |
| CREATE `lib/widgets/bubble_scaffold.dart` | widget (scaffold/provider host) | request-response (composition + PopScope) | `lib/widgets/quick_bar_scaffold.dart` (entire file) | exact (direct replacement) |
| CREATE `lib/settings/bubble_position.dart` | store + provider | CRUD (persist round-trip) | `lib/settings/sensitivity.dart` (two-half store+Notifier) | exact (clone pattern) |
| CREATE `lib/settings/window_position.dart` | store + provider | CRUD (persist round-trip) | `lib/settings/scroll_direction.dart` / `sensitivity.dart` | exact (clone pattern) |
| MODIFY `lib/trackpad/trackpad_screen.dart` | widget (screen) | composition | itself (slim to `TrackpadCore` + chrome) | self |
| MODIFY `lib/hub/hub_screen.dart` | widget (screen) | navigation wrap | itself L51/L266–281 (`QuickBarScaffold`→`BubbleScaffold`) | self |
| MODIFY `lib/keyboard/keyboard_screen.dart` | widget (screen) | doc-comment only | itself (update stale `QuickBarScaffold` mention) | self |
| DELETE `lib/widgets/quick_bar_scaffold.dart` | — | — | superseded by `bubble_scaffold.dart` | — |
| DELETE `test/quick_bar_test.dart` | test | — | superseded by `test/bubble_scaffold_test.dart` | — |

## Pattern Assignments

### `lib/trackpad/trackpad_core.dart` (widget, event-driven) — NEW

**Analog:** `lib/trackpad/trackpad_screen.dart` `_TrackpadScreenState`
**read_first:** `lib/trackpad/trackpad_screen.dart` L58–198, `lib/trackpad/trackpad_driver.dart` (dispose sends nothing), `lib/widgets/keep_awake.dart`, `lib/settings/scroll_direction.dart` (bindScrollDirectionCache)

**Move map (verbatim relocation from `_TrackpadScreenState` → `_TrackpadCoreState`):**

| Concern | Source lines | Action |
|---------|--------------|--------|
| `_service = ref.read(connectionServiceProvider)` | L96 | MOVE |
| sensitivity cache `ref.listenManual(sensitivityProvider…)` → `_sensitivity` | L101–105, field L91 | MOVE |
| `bindScrollDirectionCache(ref)` | L111 | MOVE |
| `_classifier = GestureClassifier(...)` | L113–115 | MOVE |
| `_driver = TrackpadDriver(...)` (all seams, incl. `onDragLockChanged`, `onLongPressElapsed`) | L116–128 | MOVE |
| `_changesSub`/`_lastChip` disconnect hygiene → `driver.reset()` | L143–151, fields L85–86 | MOVE |
| `keepAwake.acquire()` / `release()` | L156 / L173 | MOVE (core is SOLE owner — Pitfall 4) |
| `_onPointerDown/Move/Up/Cancel` handlers | L180–198 | MOVE |
| `Listener` + `Positioned.fill` gesture surface | L268–286 | MOVE |
| CR-01 dispose flush + `_driver.dispose()` | L160–169 | MOVE (fires on collapse AND pop) |
| `_dragLockPill` `ValueNotifier<bool>` | L71 | MOVE + EXPOSE as `ValueListenable<bool> get dragLocked` |
| keyboard panel, tune sheet, `_imeProducer`, `_onMouseButton`, header chip, pill *placement* | L76–82, L200–246, L319–429 | STAY in `TrackpadScreen` |

**Hot-path routes (move verbatim — the ZERO-setState invariant):** `trackpad_screen.dart` L180–198 + L268–286:
```dart
Listener(
  onPointerDown: (e) => _driver.handle(
      _classifier.onPointerDown(e.pointer, e.position.dx, e.position.dy)),
  onPointerMove: (e) => _driver.handle(
      _classifier.onPointerMove(e.pointer, e.position.dx, e.position.dy)),
  onPointerUp:   (e) => _driver.handle(_classifier.onPointerUp(e.pointer)),
  onPointerCancel:(e)=> _driver.handle(_classifier.onPointerCancel(e.pointer)),
  behavior: HitTestBehavior.opaque,
  child: /* injected surface hint */,
)
```

**CR-01 dispose flush (move verbatim, `trackpad_screen.dart` L160–169) — Pitfall 1:**
```dart
@override
void dispose() {
  _changesSub?.cancel();
  if (_driver.dragLocked && _service.isAuthed) {
    _service.sendReliable(const DragMsg(action: 'end', button: 'left'));
  }
  _driver.dispose();
  _dragLockPill.dispose();
  keepAwake.release();
  super.dispose();
}
```

**Chrome-slot API (Claude's Discretion):** `TrackpadCore` takes the surface hint text + optional overlay/child slots; exposes `ValueListenable<bool> get dragLocked`. Full screen supplies its top-center pill/tune/keyboard cluster; window supplies its inline header pill — both read the same `dragLocked` listenable.

---

### `lib/trackpad/trackpad_screen.dart` (widget, composition) — MODIFY (slim)

**Analog:** self. Becomes a thin composition: mount `TrackpadCore` inside the existing `Scaffold`/`Column`, feed the retained chrome (drag-lock pill L319–335 reading `core.dragLocked`, bottom-right tune/keyboard cluster L342–401, `MouseButtonsBar` L408, keyboard panel L414–429, header chip L291–313). Sensitivity sheet `_openSensitivitySheet` L210–246 STAYS. **Constraint: extraction is behavior-neutral — existing primitive tests pass unmodified; add a composition smoke test (Wave 0, none exists today).**

---

### `lib/widgets/trackpad_bubble.dart` (widget, event-driven) — NEW

**Analog:** `mouse_buttons.dart` (muted-gate + injected callback), `_TrackpadQuickBar` `quick_bar_scaffold.dart` L115–157 (accent affordance)

**Muted-not-red gate (from `mouse_buttons.dart` L119–121):** when `!authed` render `kSurface` fill + muted icon; when authed `kAccent` fill + `kText`/white icon. Still tappable in both states.
```dart
// authed → kAccent fill, Icons.touch_app; not authed → kSurface fill, kMuted icon
final fill = authed ? kAccent : kSurface;
final iconColor = authed ? kText : kMuted;
```

**Callback-injection (from `mouse_buttons.dart` L26–37, `MouseButtonsBar` shape):** `TrackpadBubble({required VoidCallback onTap, required bool authed, ...})` — service-agnostic, so the widget test needs no service fake. `onTap` = `hapticTick()` + expand (haptic wired by caller or inside; mirror `_onMouseButton` L201–204 which calls `hapticTick()`).

**Icon/token:** `Icons.touch_app` (carried from `_TrackpadQuickBar` L139), 56dp circle, `kAccent`. Tokens from `theme/tokens.dart`: `kAccent` L34, `kSurface` L23, `kMuted` L31, `kHairline` L25.

**Drag + edge-snap (Research Pattern 3):** `GestureDetector(onPanStart/Update/End)` tracks a live `ValueNotifier<Offset>`/local offset; `onPanEnd` computes nearest edge (`dx + size/2 > screenW/2 ? right : left`), `yFraction = (dy/screenH).clamp(0,1)`, runs a 200ms `Curves.easeOut` `AnimationController` to the edge+8px inset, then commits to the bubble notifier. Use `MediaQuery.sizeOf(context)`. **Do NOT use `Draggable`/`DragTarget`** (wrong semantics).

---

### `lib/trackpad/floating_trackpad_window.dart` (widget, event-driven) — NEW

**Analog:** `trackpad_screen.dart` chrome + `mouse_buttons.dart`
**read_first:** `trackpad_screen.dart` L248–435 (Column layout, pill, MouseButtonsBar dock), `mouse_buttons.dart`, `theme/tokens.dart`

**Card chrome (D8-03):** `kSurface` fill, `Border.all(color: kHairline)` 1px, 16px radius, drop shadow — same idiom as the `_DragLockPill` container `trackpad_screen.dart` L444–450 and `_HubTile` `hub_screen.dart` L216–221. Fixed ~78%w × ~38%h from `MediaQuery.sizeOf`.

**Column rows:**
1. Header bar: `⠿` drag-handle `GestureDetector` (Pattern 4 — sibling, NOT ancestor of the surface) · inline drag-lock pill via `ValueListenableBuilder<bool>(core.dragLocked)` (reuse `_DragLockPill` idiom L324–333) · `⤢` open full screen · `✕` collapse. Buttons via injected callbacks.
2. Gesture surface: `TrackpadCore` (same engine — cursor parity by construction).
3. `MouseButtonsBar(onPress:, enabled: authed)` reused as-is (`mouse_buttons.dart` L25–37), muted when not authed.

**Header-drag vs surface (Pitfall 2):** header `GestureDetector` and core `Listener` are spatially-disjoint SIBLINGS in the Column; keep `HitTestBehavior.opaque` on the core Listener. `onPanUpdate` moves the window offset clamped fully on-screen; `onPanEnd` persists `(x,y)` fractions to the window notifier.

---

### `lib/widgets/bubble_scaffold.dart` (scaffold) — NEW (replaces quick_bar_scaffold.dart)

**Analog:** `lib/widgets/quick_bar_scaffold.dart` (entire file)
**read_first:** `quick_bar_scaffold.dart` L44–110, `hub_screen.dart` L266–281

**Verbatim-preserved UIPI Stack contract (`quick_bar_scaffold.dart` L81–104):**
```dart
Material(
  color: kBg,
  child: Stack(children: [
    Positioned.fill(child: body),                    // NEVER rebuilds off expand
    Positioned(top:0,left:0,right:0,
      child: SafeArea(bottom:false,
        child: UipiBanner.forService(service))),     // UNCHANGED, IgnorePointer inside
    // NEW: bubble/window subtree — the ONLY thing that rebuilds on expand
    ValueListenableBuilder<bool>(
      valueListenable: _expanded,
      builder: (_, expanded, __) => expanded
          ? FloatingTrackpadWindow(/* … */)
          : TrackpadBubble(onTap: () => _expanded.value = true, /* … */),
    ),
  ]),
)
```

**Changes from analog:**
- `ConsumerWidget` → `ConsumerStatefulWidget` + `SingleTickerProviderStateMixin` (needs `ValueNotifier<bool> _expanded`, `AnimationController`, `PopScope`).
- Rename param `showQuickBar` → `showBubble` (default `true`); `false` only for the Trackpad-screen wrap.
- Delete `_TrackpadQuickBar` (L115–157) and the 56px `Column` slot (`if (showQuickBar) …` L105–106) — tool screens reclaim full height (D8-06).
- Keep `service = ref.watch(connectionServiceProvider)` L79.
- Keep `_openTrackpad` push idiom (L62–74) for `⤢`, but wrap destination `showBubble: false`.

**PopScope back-intercept (Research Code Example, Pitfall 6):**
```dart
PopScope(
  canPop: !_expanded.value,
  onPopInvokedWithResult: (didPop, result) {
    if (!didPop) _expanded.value = false; // first back collapses
  },
  child: /* the Material/Stack */,
);
```
**A1 flag:** confirm `onPopInvokedWithResult` (not deprecated `onPopInvoked`) against pinned SDK 3.44.5 — let the analyzer confirm.

---

### `lib/settings/bubble_position.dart` (store + provider) — NEW

**Analog:** `lib/settings/sensitivity.dart` (entire two-half pattern)
**read_first:** `sensitivity.dart` L38–103, `device_store.dart` L30 + L1–15 (JSON schema idiom if composite)

**Clone shape:**
- `const String kBubblePositionPrefsKey = 'bubble.position';`
- Model `BubblePosition(Edge edge, double yFraction)`; `enum Edge { left, right }`. Default `(right, 0.70)`.
- `BubblePositionStore({SharedPreferencesAsync? prefs})` with injectable adapter (`sensitivity.dart` L43–44). `load()` try/catch degrading to default, `yFraction.clamp(0.0,1.0)`, invalid edge → default (mirror `SensitivityStore.load` L50–58). Serialize as a small JSON string via `dart:convert` (mirror `device_store` `devices` JSON) OR two keys — discretion.
- `bubblePositionStoreProvider = Provider(...)` (L69–71).
- `BubblePositionNotifier extends Notifier<BubblePosition>`: `build()` seeds default sync + `unawaited(_load(ref.watch(store)))`; `set(BubblePosition)` writes state + `unawaited(store.save(...))` fire-and-forget (L76–97).
- `bubblePositionProvider = NotifierProvider<BubblePositionNotifier, BubblePosition>(...)` (L101–103).

---

### `lib/settings/window_position.dart` (store + provider) — NEW

**Analog:** `lib/settings/scroll_direction.dart` / `sensitivity.dart`

**Clone shape:** identical two-half pattern. `const String kWindowPositionPrefsKey = 'window.position';` Model `(double xFraction, double yFraction)`. **Default = "unset" sentinel** (e.g. nullable model or a `bool isSet`) so `FloatingTrackpadWindow` anchors from the bubble spot on first-ever open; after any move it stores real fractions. `load()` degrades corrupt/missing → unset; clamp fractions `[0,1]`.

## Shared Patterns

### Muted-not-red auth gate
**Source:** `lib/trackpad/mouse_buttons.dart` L119–121 (`enabled` → `kAccent`/`kMuted` swap, still-visible)
**Apply to:** `trackpad_bubble.dart` (bubble fill/icon), `floating_trackpad_window.dart` (its `MouseButtonsBar enabled: authed`)
```dart
final borderColor = active ? kAccent : kHairline;
final labelColor = active ? kAccent : kMuted; // "muted, not red" — non-destructive
```

### Localized-rebuild via ValueNotifier + ValueListenableBuilder (Pitfall 3/6)
**Source:** `trackpad_screen.dart` L71 (`_dragLockPill`), L76 (`_panelExpanded`), builders L324/L348/L414
**Apply to:** `bubble_scaffold.dart` `_expanded` (body stays OUTSIDE the builder), window drag-lock pill
```dart
ValueListenableBuilder<bool>(valueListenable: _x,
  builder: (context, v, _) => /* ONLY this subtree rebuilds */);
```

### keepAwake ref-counted hold (D-14, Pitfall 4)
**Source:** `lib/widgets/keep_awake.dart` L48–64 (`acquire`/`release`, ref-counted singleton `keepAwake` L71)
**Apply to:** `trackpad_core.dart` ONLY — `acquire()` in `initState`, `release()` in `dispose`. Do NOT also acquire in scaffold/window (single owner; Presenter's own hold `presenter_screen.dart` survives the 1→2→1 excursion).

### Two-half store+Notifier persistence (non-secret prefs)
**Source:** `lib/settings/sensitivity.dart` (store L38–66 + notifier L76–97) and `scroll_direction.dart`
**Apply to:** both new position notifiers. Injectable `SharedPreferencesAsync`, clamped/degrading `load()`, sync-seed `build()`, fire-and-forget `set()`. Non-secret → shared_preferences, NEVER secure storage (CLAUDE.md rule).

### Callback-injection widget (service-agnostic, testable)
**Source:** `mouse_buttons.dart` L26–37, `hub_screen.dart` `HubTileGrid.onOpen` L141–154
**Apply to:** `trackpad_bubble.dart` (`onTap`), `floating_trackpad_window.dart` (`onExpandFull`/`onCollapse`/`onMouseButton`) — so widget tests never touch Navigator or a live service.

### Central navigation wrap (migration, Pitfall 5)
**Source:** `hub_screen.dart` `_open` L270–281 + `HubTileSpec.showQuickBar` L68/L87
**Apply to:** `hub_screen.dart` MODIFY — swap import L51 `quick_bar_scaffold.dart`→`bubble_scaffold.dart`, `QuickBarScaffold`→`BubbleScaffold`, `spec.showQuickBar`→`spec.showBubble` (rename field L68/L87). Hub itself stays UNWRAPPED (bare `Scaffold` L303) — Trackpad tile alone keeps `false`. The 7 tool screens need NO per-screen edits.

## Test Patterns

**Harness idiom (`test/quick_bar_test.dart`):** `ProviderScope(overrides: [connectionServiceProvider.overrideWith(...)])` with `_FakeSecureKv`/`_FakePrefsKv` in-memory maps (L24–47) + `MaterialApp(home: …)`; assert `find.byIcon`/`find.text`/color; tap-through test proving overlay `IgnorePointer` (L96–119). **Mirror into:** `test/bubble_scaffold_test.dart` (presence with `showBubble`, absence with `showBubble:false`, UIPI slot unchanged, body hit-testable around the window). DELETE `test/quick_bar_test.dart`.

**Fake-KV / debug-cache round-trip idiom (`test/scroll_direction_test.dart`):** `debugScrollReversedCached` seam L28–34, injected-getter driver harness `buildDriver` L37–50, `tearDown` reset L17. **Mirror into:** `test/bubble_position_test.dart` / `test/window_position_test.dart` (`(edge,yFraction)`/`(x,y)` round-trip, default, corrupt-read degrade — inject `SharedPreferencesAsync` fake via store constructor).

**Wave 0 new tests (none exist as safety net — Pitfall 7):**
- `test/trackpad/trackpad_core_test.dart` — pointer→fake classifier/driver seam, zero-setState, CR-01 4-quadrant (dragLocked×authed), keepAwake count.
- `test/trackpad/trackpad_screen_test.dart` — thin-composition smoke.
- `test/trackpad_bubble_test.dart` — drag/snap/tap/haptic/muted.
- `test/floating_trackpad_window_test.dart` — header drag/clamp, buttons, pill, surface-is-mouse.
- `test/bubble_scaffold_test.dart` — supersedes quick_bar_test.
- `test/bubble_position_test.dart`, `test/window_position_test.dart`.
- Extend `test/keep_awake_test.dart` — window-excursion / Presenter-survival.

## No Analog Found

None — every file has a strong in-repo analog. This phase is 90% relocation + composition of already-correct code.

## Metadata

**Analog search scope:** `app/remote_control/lib/{trackpad,widgets,settings,hub,theme,store}/`, `app/remote_control/test/`
**Files scanned:** 9 source + 2 test (all read in full this session)
**Pattern extraction date:** 2026-07-15
