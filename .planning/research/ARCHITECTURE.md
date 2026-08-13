# Architecture Research — v1.1 The Summon Bar

**Domain:** Flutter (Android) client of a LAN remote-control app; client-side-only milestone
**Researched:** 2026-08-12
**Confidence:** HIGH for everything cited to `file.dart:line` (read directly from the working tree at `master` @ `7c9ecf8`). MEDIUM for the two Flutter framework behaviours cited to api.flutter.dev. LOW/flagged where noted.

> Scope note: this is a **codebase-grounded** architecture answer, not a generic Flutter pattern survey. Every structural claim below carries a real file/line. Everything the design note asserts that I could **not** verify is called out in §8.

---

## 0. Executive answer, in one screen

| # | Question | Answer |
|---|---|---|
| 1 | Where does the bar mount? | **New `SummonShell` at `MaterialApp.builder`** (`main.dart:112-118`), above the Navigator. `BubbleScaffold` is **replaced**, not extended — but a ~20-line remnant of it survives as a per-route back guard, because `PopScope` cannot work above the Navigator. |
| 2 | Keyboard's third mount point | The **shell** owns `KeyboardInputController`, `FocusNode`, `ImeDiffProducer` and `HiddenTextInput`; the overlay only renders the deck. Controller lifetime = shell lifetime (app-scope). `controller.dismissed()` must fire on the dismiss edge (`keyboard_input_controller.dart:143`). The `WidgetsBindingObserver`/`didChangeMetrics` machinery must **not** be ported. |
| 3 | Restore-where-it-was | **Keyboard host State must stay MOUNTED** (deck chrome unmounts, State survives) — as the docked panel already does. **Trackpad must be REBUILT** (unmount on dismiss) — it has no visual state and holds the keep-awake lock. |
| 4 | Inset arithmetic | `available = S − viewPadding.top − max(viewPadding.bottom, viewInsets.bottom) − kSummonBarHeight`, read from the **ancestor** MediaQuery (unstripped at `builder`), **plus** a mandatory `MediaQuery.removePadding(removeBottom: true)` around the overlay because `KeyboardTabBar` carries its own `SafeArea` (`key_pads.dart:351`). Full derivation + 5 worked devices in §4. |
| 5 | Hidden IME input | A `Positioned(width:1, height:1)` child of the **shell's** Stack — outside the Navigator, outside the bar, outside the animating chrome. It then survives dismiss, re-summon **and route pushes**. |
| 6 | What retires | 3 named symbols + **2 the note misses** (`bubble_position.dart` / `bubblePositionProvider`, and `UipiBanner`'s only production mount). 6 test files. `showBubble` becomes `SummonSurface? owns` on the screen, not on the tile. |
| 7 | Build order | Shell+bar (empty overlay) → trackpad surface → keyboard third mount → retire bubble → tiles last + flag re-read → chip-row fix. First demo = the bar on every screen with a correctly-sized empty panel. |

---

## 1. Where the bar mounts

### 1.1 How screens are composed and routed today

There is **no shell**. The composition is:

```
ProviderScope                                   main.dart:36
└── MaterialApp(home: HubScreen)                main.dart:112-118   ← no `builder:`
    └── Navigator (implicit)
        ├── HubScreen ─ Scaffold ─ SafeArea     hub_screen.dart:319, 367
        └── (pushed) MaterialPageRoute
            └── BubbleScaffold                  hub_screen.dart:284-292
                └── Material > Stack            bubble_scaffold.dart:166-168
                    ├── Positioned.fill(body)   bubble_scaffold.dart:171   ← the tool Scaffold
                    ├── Positioned(top) UipiBanner  bubble_scaffold.dart:176-183
                    └── bubble | window         bubble_scaffold.dart:186-213
```

Facts that matter:

- **Every navigation is a plain `MaterialPageRoute`.** Six call sites: `hub_screen.dart:284`, `hub_screen.dart:298`, `bubble_scaffold.dart:117`, `settings_screen.dart:218`, `settings_screen.dart:659`, `device_list_screen.dart:93`, `pairing_dialog.dart:360`. No `go_router`, no `onGenerateRoute`, no central route table.
- **`BubbleScaffold` is the only central wrapper, and it covers only the 9 tile routes** (`hub_screen.dart:286`). The hub itself, Settings, DeviceList, Updates, QrScan are **not** wrapped.
- **Every screen owns its own `Scaffold`** (16 of them: `apps_screen.dart:126`, `browser_screen.dart:557`, `clipboard_screen.dart:160`, `hub_screen.dart:319`, `keyboard_screen.dart:245`, `media_screen.dart:85`, `power_screen.dart:172`, `presenter_screen.dart:193`, `device_list_screen.dart:169`, `qr_scan_screen.dart:104`, `settings_screen.dart:139`, `shortcuts_screen.dart:426`, `trackpad_screen.dart:147`, `updates_screen.dart:519`).
- **Every screen wraps its body in `SafeArea`** — verified for all 14 user-facing screens (`apps_screen.dart:145`, `browser_screen.dart:581`, `clipboard_screen.dart:179`, `hub_screen.dart:367`, `keyboard_screen.dart:267`, `media_screen.dart:104`, `power_screen.dart:191`, `presenter_screen.dart:212`, `device_list_screen.dart:182`, `qr_scan_screen.dart:117`, `settings_screen.dart:145`, `shortcuts_screen.dart:445`, `trackpad_screen.dart:152`, `updates_screen.dart:531`). **This is load-bearing for the design below** — it is what lets one shell reserve the bar's 56px for every screen without editing a single screen.

### 1.2 The insertion point: `MaterialApp.builder`

**Modify `main.dart:112-118`** to add a `builder:` that mounts a new `SummonShell` above the Navigator.

```dart
// main.dart — the ONLY edit needed to reach every screen
return MaterialApp(
  title: 'Remote Control',
  debugShowCheckedModeBanner: false,
  theme: buildAppTheme(),
  builder: (context, child) => SummonShell(child: child!),   // NEW
  home: const HubScreen(),
);
```

`MaterialApp.builder` inserts widgets **above the Navigator but below** `Theme`, `MediaQuery`, `Directionality`, `Localizations`, `DefaultTextStyle` — all of which are therefore ancestors and available from the builder's `BuildContext`. Omitting `child` deletes the Navigator entirely. *(api.flutter.dev/MaterialApp.builder; seam-classified LOW because it came through `webfetch`, but the source is the official API doc and the ordering is directly observable in a test — verify with one `find.byType` assertion in the first plan.)*

Why this and not the alternatives:

| Candidate | Verdict |
|---|---|
| **`MaterialApp.builder` shell** | **CHOSEN.** One mount reaches literally every route including the hub (`main.dart:117`) and Settings' subtree. Gives exactly one `KeyboardInputController`, one hidden IME field, one overlay — see §2.4 for why "exactly one" is a correctness requirement, not a tidiness preference. The bar does **not** animate on route pushes, which is what "permanent" should feel like. |
| Extend `BubbleScaffold` in place | **REJECTED.** It is per-route (`hub_screen.dart:286`) and only wraps the 9 tile routes. Per-route means N controllers, N hidden inputs, and a stuck-modifier path across navigation (§2.4). It also cannot reach the hub without wrapping `home:` too. |
| Per-screen composition | **REJECTED.** 14 edits, 14 chances to drift, and the "restore where it was" contract dies at every route boundary. |
| `OverlayEntry` | **REJECTED**, and the codebase already rejected it once for the same reason: `bubble_scaffold.dart:6-9` — "Stack children, NOT `OverlayEntry`, which would fight `PopScope` + the per-screen-ephemeral lifecycle". |

### 1.3 `BubbleScaffold`: extend, replace, or sit beside?

**Replace — but salvage two of its three jobs, and split them.**

`BubbleScaffold` does three things (`bubble_scaffold.dart`):

| Job | Line | Fate |
|---|---|---|
| Hosts the bubble/window subtree | 186-213 | **Deleted** with the bubble. |
| Hosts the `UipiBanner` slot | 176-183 | **Moves to the shell** — and this is a finding the design note misses. `UipiBanner.forService` has exactly **one** production mount site in the whole app (`bubble_scaffold.dart:181`; the only other hits are tests). Deleting `BubbleScaffold` without rehoming it silently deletes the SRV-05 "can't control this window — it's running as administrator" advisory from the product. Rehoming it to the shell also **gains** it on the hub and Settings, which never had it. |
| `PopScope` back-intercept | 159-165 | **Cannot move to the shell.** `PopScope` registers with the *enclosing* `ModalRoute` via `ModalRoute.registerPopEntry`; above the Navigator there is no route to register with (api.flutter.dev/PopScope, seam-classified LOW/`webfetch` — but the class doc is explicit and this is cheap to prove with one widget test). |

So the recommended shape is **one app-scope shell + one thin per-route guard**:

- `lib/shell/summon_shell.dart` — **NEW.** The bar, the overlay, the hidden IME field, the controller, the banner slot, the inset arithmetic.
- `lib/shell/summon_back_guard.dart` — **NEW, ~20 lines.** Stateless; a `PopScope` reading the shell's `raised` `ValueNotifier`; `canPop: !raised`, `onPopInvokedWithResult` → dismiss. Wrapped around each route body at the *existing* central push site (`hub_screen.dart:286`, where `BubbleScaffold` sits today) plus `home:` (`main.dart:117`).
- `lib/widgets/bubble_scaffold.dart` — **DELETED.**

> **Plan constraint (back gesture):** do not assume a shell-level `WidgetsBindingObserver.didPopRoute` override will win — `WidgetsApp`'s own observer is registered first and `handlePopRoute` returns on the first observer that handles it. The route-level guard is the mechanism that is known to work with a `MaterialApp` (non-`.router`) app. **Flagged MEDIUM** — worth one spike test in plan 1.

### 1.4 Which screens get the bar

PROJECT.md says "every screen, the hub included" (`.planning/PROJECT.md:29`). With an app-scope shell that is what you get by default, including Settings, Updates, DeviceList, QrScan. Two deliberate carve-outs to decide in requirements (both flagged, neither blocking):

- **`QrScanScreen`** (`qr_scan_screen.dart:104`) — full-screen camera capture, a pure modal errand. A summon bar over a viewfinder is noise. Recommend suppressing.
- **`DeviceListScreen` / `PairingDialog`** — the only screens in the app with **local** `TextField`s (`device_list_screen.dart:491`, `device_list_screen.dart:509`, `pairing_dialog.dart:242`). Here the *phone* is the input target, which is the exact case the "overlay not resize" rationale says does not exist (`.planning/notes/summon-bar-trackpad-keyboard.md:37-42`). The arithmetic in §4 handles this correctly with no special-casing (the bar floats above the local IME and the field-bearing screen resizes above the bar) — so this is a taste call, not a bug. Recommend keeping the bar, because suppression logic is more risk than the noise it removes.

---

## 2. The keyboard's third mount point

### 2.1 What exists after `260809-ipc`

```
KeyboardInputController         keyboard_input_controller.dart:49   ← the shared stuck-key owner
   ├── constructed in initState / disposed in dispose by:
   │     _KeyboardScreenState   keyboard_screen.dart:125, 170       (full-screen, route)
   │     _KeyboardPanelState    keyboard_panel.dart:172, 261        (docked, child of TrackpadScreen)
   └── seams: send, changes, isDisconnected, onChanged              keyboard_input_controller.dart:85-97
```

The controller is a **plain object with injected seams** and is deliberately *not* a mixin or a lifted holder — `keyboard_input_controller.dart:12-19`: *"Ownership IS lifecycle."*

### 2.2 What a third mount point needs from the controller

Exactly four things, all already public:

| Need | API | Notes |
|---|---|---|
| Construct with seams | `KeyboardInputController({send, changes, isDisconnected, onChanged})` `:85` | `send` → `service.sendReliable`; `changes` → `service.changes`; `isDisconnected` → `() => service.chipStatus == ChipStatus.disconnected` (the exact closures at `trackpad_screen.dart:307-310`). |
| Drive the chips/caps | `stateOf`, `hasArmedMods`, `chipTap`, `chipLongPress`, `keyDown`, `keyUp`, `keyTapWithMods` `:191-234` | Identical wiring to `keyboard_panel.dart:311-374`. |
| Feed the hidden field | `imeResetTick` (`ValueNotifier<int>`) `:77` | Passed as `HiddenTextInput.resetSignal`. |
| **Release on dismiss** | `dismissed()` `:143` | Shares `_flushHolds()` with `dispose()` so a dismiss-then-teardown emits each owed `up` exactly once (`:139`). |

### 2.3 What the controller assumes about its host

1. **`onChanged` is a `setState` hook** (`:25`, called from `_onDisconnected`, `chipTap`, `chipLongPress`, `keyTapWithMods`, `dismissed`). The host must be a `State` that can rebuild the chip row. Both existing hosts guard it with `if (mounted)` (`keyboard_panel.dart:177`, `keyboard_screen.dart:130`).
2. **`dispose()` runs after the caps have already unmounted.** `keyboard_input_controller.dart:161-163`: Flutter unmounts children before parents, so `KeyCap.dispose` has already released held caps and `keyUp`'s `remove()` guard (`:224`) makes the pair idempotent. **Any new host must keep the caps as descendants of the host State** or this idempotence breaks.
3. **`changes` is subscribed for the object's whole life** (`:92`). Two live controllers = two live subscriptions = two independent FSMs. Harmless *individually*; see §2.4 for why it is not harmless in aggregate.
4. **`send` must stay valid for the object's whole life.** `keyboard_panel.dart:169-171` documents the trap: the host rebuilds with *fresh closures* each build, so the controller is given **forwarding closures** (`(msg) => widget.send(msg)`), never the raw field. A shell-owned controller reading a cached `ConnectionService` (`hub_screen.dart:275` house pattern) sidesteps this entirely.

### 2.4 What breaks if the host is an overlay — and the fix

| Hazard | Why | Required design |
|---|---|---|
| **IME connection torn down on every summon** | If the host State unmounts on dismiss, `HiddenTextInput` unmounts with it. `hidden_text_input.dart:8-13` is explicit: never `Offstage`/`Visibility(maintainState:false)` — the Android input connection detaches. | The **host State must survive dismiss**; only the chrome unmounts. And the hidden field goes further up still — §5. |
| **Locked modifier welded down on the PC** | The State surviving is exactly what created deferred item #2. Collapsing unmounts caps (they self-release) but the FSM lock persists. | Call `controller.dismissed()` on the dismiss edge — the literal shape of `keyboard_panel.dart:244-249`. **Already solved** in the controller; the third mount point must not forget to call it. |
| **N controllers across navigation** | A **per-route** shell would leave the hub's controller alive (route still mounted below) while a new route's controller shows unlocked chips. Lock Shift on the hub, tap a tile → Shift stays physically held on the PC with no chip anywhere to release it. This is the 260812-tsw bug, resurrected at a scope no test covers. | **App-scope shell ⇒ exactly one controller for the process.** This is the single strongest architectural argument for `MaterialApp.builder` over a per-route wrapper. |
| **Pad restore hop on every summon** | `PageController(initialPage: _currentPage)` is constructed **once**, in `initState` (`keyboard_panel.dart:164`). When the deck unmounts on dismiss and remounts on summon, the `PageView` attaches a *new* `ScrollPosition`; whether it lands on `_currentPage` depends on `PageStorage`/`keepScrollOffset` restoring the offset, not on any explicit code. Today this path is exercised rarely (collapse/expand of the docked panel) and **no test covers "page to Numpad → collapse → expand"** — the closest tests seed prefs and go through `_pendingRestore` (`keyboard_panel_test.dart:723-779`). Under a summon model this path runs dozens of times per session. | **Make it explicit.** On the summon edge, `WidgetsBinding.instance.addPostFrameCallback((_) => _pageController.jumpToPage(_currentPage))` (or rebuild the controller seeded to `_currentPage`). Pin it with a new test: *page to Numpad → dismiss → summon → `find.byType(NumpadPad)` findsOneWidget on the FIRST frame*. This is the concrete answer to OQ-A1 sub-question 2 (`.planning/research/questions.md:41-43`). |
| **`didChangeMetrics` double-rebuild** | `keyboard_panel.dart:157` + `:196-199` add a `WidgetsBindingObserver` purely because the panel's stripped MediaQuery is value-equal across an IME animation and never notifies. At the shell the MediaQuery is **not** stripped, so `MediaQuery.viewInsetsOf(context)` already rebuilds every IME frame. | **Do not port the observer.** Porting it gives two rebuilds per IME frame on the hottest surface in the app. |
| **`_pendingRestore` complexity** | `keyboard_panel.dart:146` exists because the panel mounts collapsed and the async prefs load lands with no `PageView` to jump. Same shape at the shell (mounts dismissed). | **Keep it.** It is still needed for the cold-start restore. It is only the *within-session* restore that must come from in-memory `_currentPage`. |

### 2.5 Recommended ownership split (the plan-level constraint)

```
SummonShell (State, app-scope)                  ← owns, for the process lifetime:
  ├── ConnectionService        (ref.read once, house pattern — hub_screen.dart:275)
  ├── FocusNode _imeFocusNode  (mirrors trackpad_screen.dart:69)
  ├── ImeDiffProducer          (mirrors trackpad_screen.dart:81)
  ├── KeyboardInputController  (constructed here, disposed here)   ← MOVED UP vs D-95's "the surface constructs it"
  ├── ValueNotifier<SummonSurface?> _raised
  └── Stack
      ├── Positioned.fill  → MediaQuery(padding+bar) → child (the Navigator)
      ├── Positioned(top)  → SafeArea(bottom:false) → UipiBanner.forService   [rehomed]
      ├── Positioned(1x1)  → HiddenTextInput(producer, focusNode, resetSignal: controller.imeResetTick)
      ├── Positioned(bottom: barTop, ...) → the raised surface (mounted only while raised)
      └── Positioned(bottom: barBottomOffset, height: 56) → SummonBar
```

This is a **deliberate, documented amendment to D-95**: the controller is still constructed and disposed by exactly one `State`, and ownership is still lifecycle — the lifecycle just moved up a level, because the dismiss/re-summon cycle means the *surface* is no longer the thing whose lifetime matches the model's. Record it as such so a future reader does not "restore" the surface-owns-controller rule.

**Reuse, don't clone, the deck.** `keyboard_panel.dart:332-375` (`_deck()`) and `keyboard_screen.dart:276-317` are already near-identical `PageView`s over the same four pads. The third mount point must **not** be a third copy. Extract a `KeyboardDeck` widget (pads + chip row + tab bar, taking a `KeyboardInputController` and a height) that all three surfaces mount. `key_pads.dart:361-365` already says exactly this about `KeyCap`: *"Reuse it; do not clone its press logic."*

---

## 3. State ownership for "restore where it was"

### 3.1 Inventory of the state today

| State | Where it lives | Provider? | Persisted? |
|---|---|---|---|
| Which pad the docked panel shows | `_KeyboardPanelState._currentPage` (`keyboard_panel.dart:130`) | seeded from `panelPadProvider` (`key_rows.dart:351`) | `keyboard.panelPad` (`key_rows.dart:208`) |
| Which pad the full screen shows | `_KeyboardScreenState._currentPage` (`keyboard_screen.dart:95`) | seeded from `keyboardPadProvider` (`key_rows.dart:314`) | `keyboard.pad` (`key_rows.dart:194`) |
| Modifier FSM + held-key set | `KeyboardInputController._fsm`, `._heldCodes` (`:62`, `:70`) | **no** | **no** |
| IME buffer / diff baseline | `_HiddenTextInputState._controller` + `ImeDiffProducer` (`hidden_text_input.dart:50`) | **no** | **no** |
| Trackpad gesture FSM + driver | `TrackpadCoreState._classifier`, `._driver` (`trackpad_core.dart:117-119`) | **no** | **no** |
| Drag-lock | parent-owned `ValueNotifier<bool>` (`trackpad_screen.dart:61`, `trackpad_core.dart:71`) | **no** | **no** |
| Keep-awake hold | ref-counted process singleton `keepAwake` (`keep_awake.dart:71`), acquired at `trackpad_core.dart:194`, released at `:209` | **no** | n/a |
| Sensitivity / scroll direction | `sensitivityProvider`, `scrollReversedCached` (`trackpad_core.dart:145-154`) | **yes**, cached via `listenManual(fireImmediately: true)` | yes |
| Panel expanded flag | `ValueNotifier<bool> _panelExpanded` (`trackpad_screen.dart:66`) | **no** | **no** |
| Bubble / window position | `bubblePositionProvider`, `windowPositionProvider` | yes | yes — **both retire** |

### 3.2 Verdict per piece — MOUNTED vs REBUILT

**Definitive, and they differ. This is the core state-flow change of the milestone.**

| Piece | Must stay MOUNTED? | Why |
|---|---|---|
| `HiddenTextInput` + its `FocusNode` | **YES — and above everything else** | `hidden_text_input.dart:8-13`. Rebuilding = new input connection = the IME re-negotiates on every summon. Landmine #3. |
| `KeyboardInputController` (FSM, held set, `imeResetTick`) | **YES** (as an object; not a widget) | Not persistable — `ModifierFsm` state is a live physical contract with the PC. Rebuilding it would forget that Shift is physically held. Lives at shell scope. |
| Keyboard deck / caps / chip row | **NO — must UNMOUNT** | `keyboard_screen.dart:24-28`: *"leaving a pad DISPOSES its caps, and a cap disposed mid-hold releases its key… Nothing here may retain an off-screen pad's State."* Keeping the deck mounted while dismissed would reintroduce the stuck-key door. |
| Which pad is showing | **REBUILT from in-memory `_currentPage`** (not from the provider) | The provider is async-loading (`key_rows.dart:294-299`) — reading it on each summon is what would cause the visible hop. In-memory State in the shell survives dismiss; the provider is for **cold start only**. |
| `TrackpadCore` | **NO — must UNMOUNT** | See §3.3. |
| Drag-lock notifier | Owned by the shell; **value resets** because `TrackpadCore.dispose` flushes `DragMsg(end,left)` on a live socket (`trackpad_core.dart:205-207`). Correct: dismissing must not leave a mouse button held. |
| Sensitivity / scroll direction | **REBUILT, free.** `listenManual(fireImmediately: true)` re-seeds on mount (`trackpad_core.dart:145-149`). |

### 3.3 The cost of keeping the trackpad mounted — measured against the code

The question posed was whether a mounted-but-hidden trackpad "keeps sending or keeps a wakelock". Reading the code:

- **It does NOT keep sending.** The hot path is purely event-driven: four `Listener` callbacks → classifier → driver → service, with zero timers at rest (`trackpad_core.dart:216-234`, `:240-245`). `TrackpadDriver`'s momentum/long-press timers only exist during a gesture. A hidden surface receives no pointers, so it emits nothing.
- **It DOES keep the wakelock, permanently.** `_keep.acquire()` in `initState` (`trackpad_core.dart:194`) and `_keep.release()` in `dispose` (`:209`) are the only transitions, and `KeepAwake` is a process-wide ref-count (`keep_awake.dart:48-64`). A `TrackpadCore` kept mounted behind a dismissed overlay holds the count at ≥1 **for the entire app session, on every screen**. The screen never dims. That is a battery regression the size of the whole app.
- **It stays hit-testable.** `HitTestBehavior.opaque` (`trackpad_core.dart:245`). A hidden-but-mounted core inside a zero-height box is safe, but a mounted core behind a translucent dismissed chrome is a live cursor surface swallowing taps meant for the screen beneath.

**Therefore: unmount `TrackpadCore` on dismiss.** Cost of rebuilding: a fresh `GestureClassifier` + `TrackpadDriver` (two plain object allocations, `trackpad_core.dart:156-176`), one `listenManual` seed, one `changes` subscription, one keep-awake acquire. No I/O, no async, no prefs read. **There is nothing visible to restore** — the surface renders a `CustomPaint` dot grid and a hint `Text` (`trackpad_core.dart:251-265`). "Restores where it was, no visible jump" is satisfied trivially for the trackpad and is a real engineering problem only for the keyboard.

### 3.4 One new provider

The summon keyboard needs its own landing-pad key. `KeyboardPadStore` is already parameterised by key (`key_rows.dart:246-250`), so this is ~12 lines:

```dart
const String kSummonPadPrefsKey = 'keyboard.summonPad';   // key_rows.dart, beside :194 and :208
final summonPadStoreProvider = Provider<KeyboardPadStore>(
  (ref) => KeyboardPadStore(key: kSummonPadPrefsKey));    // migrateRetiredPanelKey: false
final summonPadProvider = NotifierProvider<SummonPadNotifier, KeyboardPad>(...);
```

Rationale for a **third** key rather than sharing `keyboard.pad`: D-94's argument (`key_rows.dart:199-207`) is that two surfaces sharing a key "continually yank each other's landing pad" when their usage profiles differ. The summon surface's profile (fast Type/Arrows bursts alongside another remote) differs from the full screen's (Numpad/Fn work). Same reasoning, third instance. *One model, three mount-point keys.*

---

## 4. The inset arithmetic — derived, not copied

> This is landmine #2 (`.planning/notes/summon-bar-trackpad-keyboard.md:122-126`). The instruction was "re-derive; do not copy." Below is the derivation from first principles for the new context, plus the two places where the old formula is actively **wrong** here.

### 4.1 Why the panel's formula exists (the thing not to copy)

`keyboard_panel.dart:378-408`. The docked panel reads **raw view metrics**:

```dart
final view = MediaQueryData.fromView(View.of(context));
final columnHeight = view.size.height
    - view.viewPadding.top
    - math.max(view.viewPadding.bottom, view.viewInsets.bottom);
```

It must, because in *its* tree the ancestor MediaQuery has been stripped twice:

1. `Scaffold(resizeToAvoidBottomInset: true)` (`trackpad_screen.dart:150`) → `removeViewInsets(removeBottom: true)` → **`viewInsets.bottom == 0` in the body**;
2. `SafeArea` (`trackpad_screen.dart:152`) → `MediaQuery.removePadding` → **`padding.top == padding.bottom == 0`**;
3. neither touches `size`, so `size.height` is still the **full window** — so the naive `size − padding − viewInsets` reads the whole window and the clamp binds against a column that does not exist. The discriminator tests prove it: `trackpad_screen_test.dart:257-274` ("the naive read yields 80 and fails") and `:276-307` ("the naive read yields 176 and fails").

It also needs `WidgetsBindingObserver.didChangeMetrics` (`keyboard_panel.dart:157`, `:196-199`) because the *stripped* `MediaQueryData` is value-equal across an IME animation and never notifies.

### 4.2 The third inset context, characterised

At `MaterialApp.builder` the shell sits **above the Navigator and below MediaQuery** (api.flutter.dev/MaterialApp.builder). Consequences, and they invert every premise above:

| Property | Docked panel | **Summon shell** |
|---|---|---|
| `viewInsets.bottom` | stripped to 0 by Scaffold | **real IME height** |
| `padding.top/bottom` | stripped to 0 by SafeArea | **real safe insets** |
| Rebuild on metric change | never (value-equal) → needs `didChangeMetrics` | **automatic** — `MediaQuery.viewInsetsOf(context)` registers an `InheritedModel` dependency and the data is *not* value-equal across the IME animation |
| Descendant `SafeArea`s already consumed the bottom inset? | **yes** (ancestor SafeArea) → `KeyboardTabBar`'s own `SafeArea` contributes 0 | **NO** — see §4.4, this is the trap |

**So: read the ancestor MediaQuery, and delete the observer.** Copying `MediaQueryData.fromView` here would work numerically but is wrong architecturally: it opts out of the rebuild mechanism you now get for free, and any future ancestor that *does* legitimately adjust the MediaQuery (a debug banner, a text-scale clamp) would be ignored.

### 4.3 The derivation

Define, all read at the shell's `BuildContext`:

```
S     = MediaQuery.sizeOf(context).height                 // full window, logical px
Ptop  = MediaQuery.viewPaddingOf(context).top             // status bar — IME-INDEPENDENT
Pbot  = MediaQuery.viewPaddingOf(context).bottom          // gesture nav — IME-INDEPENDENT
Ibot  = MediaQuery.viewInsetsOf(context).bottom           // system IME, 0 when down
```

**Use `viewPaddingOf`, not `paddingOf`.** `padding.bottom` collapses to 0 while the IME is up (the engine subtracts the inset); `viewPadding` does not. The panel's comment states the same rule (`keyboard_panel.dart:399-403`) and it survives the move.

**Step 1 — where the bar's bottom edge sits.**
The bar must stay reachable while the system IME is up, or "dismiss costs ONE gesture" is false on the Type pad. So it floats above whichever of the two bottom obstructions is taller:

```
barBottomOffset = max(Pbot, Ibot)
```

`max()` is exact and never double-counts because **both are measured from the window's bottom edge** — the IME is drawn *over* the nav bar, it is not stacked on top of it. (Same justification as `keyboard_panel.dart:400-403`, and it is the one piece of the old arithmetic that transfers verbatim.)

**Step 2 — what the bar costs.**

```
kSummonBarHeight = 56                 // NEW const; content only, excl. the safe inset
barBlock = kSummonBarHeight + barBottomOffset
```

56 matches the house bottom-bar vocabulary: `_kTabBarHeight = 56` (`key_pads.dart:113`) and the window's `MouseButtonsBar(height: 56)` (`floating_trackpad_window.dart:232`). The note's "~56-ish px" (`summon-bar-trackpad-keyboard.md:69`) lands on the same number.

**Step 3 — the overlay's available height.**

```
available = S − Ptop − barBlock
          = S − Ptop − max(Pbot, Ibot) − kSummonBarHeight
```

**Identity worth writing into the plan:** `available == columnHeight(docked panel) − kSummonBarHeight`. Same three terms, one extra subtraction. But it is *derived from a different source* (ancestor MediaQuery, not `View.of`), so the two formulas must **not** be factored into one helper — they would then share a source that is correct for only one of them.

**Step 4 — reserving the bar for everything beneath.**
The Navigator subtree must not paint under the bar. Because **all 14 screens wrap their body in `SafeArea`** (§1.1), one MediaQuery injection reserves it everywhere with zero per-screen edits:

```dart
MediaQuery(
  data: mq.copyWith(
    padding:     mq.padding.copyWith(bottom: mq.padding.bottom + kSummonBarHeight),
    viewPadding: mq.viewPadding.copyWith(bottom: mq.viewPadding.bottom + kSummonBarHeight),
  ),
  child: child!,   // the Navigator
)
```

**Leave `viewInsets` untouched.** That is what keeps the two local-`TextField` screens (`device_list_screen.dart:491`, `pairing_dialog.dart:242`) working: their `Scaffold(resizeToAvoidBottomInset: true)` still shrinks by the real IME, *and* `padding.bottom` (which the engine has already collapsed to 0 under a raised IME) still yields `0 + 56`. Net: content ends at `IME_top − 56`, which is exactly the bar's top edge. **The arithmetic is consistent in both IME states with no conditional logic** — verify this with a widget test on the pairing dialog rather than trusting the prose.

**Step 5 — strip the bottom padding for the overlay subtree. Mandatory.**

```dart
MediaQuery.removePadding(context: context, removeBottom: true, child: overlay)
```

`KeyboardTabBar` wraps itself in `SafeArea(top: false)` (`key_pads.dart:351`), and `_kTabBarHeight = 56` is documented as *"excluding the bottom SafeArea inset"* (`key_pads.dart:112`). In the docked panel that inner `SafeArea` contributes **0**, because the trackpad screen's ancestor `SafeArea` (`trackpad_screen.dart:152`) already removed the padding — the panel's own test asserts this reasoning (`keyboard_panel_test.dart:86-90`: *"which is exactly why the panel reads the RAW view for its column height, and why KeyboardTabBar's inner SafeArea contributes 0"*). **In the shell nothing has stripped it**, so without `removePadding` the tab bar silently grows by `Pbot` (24–48px of dead space at the bottom of a floating panel), and `kPanelChromeHeight = 121` (`key_pads.dart:161`) stops being true. This is the single most likely way to get the inset arithmetic subtly wrong.

**Step 6 — the pad-height clamp.**

```
kSummonMaxHeightFraction = 0.75      // NEW — design choice, see below
kSummonMinPadHeight      = 96        // reuse kPanelMinPadHeight's value (key_pads.dart:215)
kOverlayChromeHeight     = kPanelChromeHeight = 121   // valid ONLY given Step 5

summonPadHeight(pad, available) =
    min( kPanelPadHeights[pad],
         max( kSummonMinPadHeight,
              available * kSummonMaxHeightFraction − kOverlayChromeHeight ) )
```

Same *shape* as `panelPadHeight` (`key_pads.dart:244-251`) — floor applied to the ceiling, never to the pad's own request — but a **different fraction and a different justification**:

- The panel's `0.55` exists to keep the trackpad beneath it **live and usable** — a hard functional contract (`key_pads.dart:208-211`, `keyboard_panel.dart:5-8`).
- The overlay has **no live surface beneath it**; nothing beneath is an input target (`summon-bar-trackpad-keyboard.md:37-42`). The only reason to cap it below 100% is *legibility*: an overlay that fills the screen has become a screen, which is the thing this design exists to stop being. `0.75` leaves a visible strip of the host screen at every size. **This is a design choice, not a derived number — say so in the plan and let the owner move it on hardware.**
- **The `kPanelColumnOverhead = 122` constant (`key_pads.dart:179`) must NOT be reused.** Its extra `+1` is the hidden IME sliver that sits inside the docked panel's Column (`keyboard_panel.dart:416`, `key_pads.dart:164-178`). In the shell the hidden field is a `Positioned` sibling of the overlay (§5) and costs the overlay **zero** layout. Reusing 122 would be a 1px lie in the other direction — and `key_pads.dart:170-178` is emphatic that this pixel is the difference between the guarantee holding and not.

### 4.4 Worked values (dpr = 1)

| # | Device / state | S | Ptop | Pbot | Ibot | `available` | ceiling | pad | viewport | overlay total | host strip left |
|---|---|---|---|---|---|---|---|---|---|---|---|
| A | 411×891, nav 48, IME down | 891 | 24 | 48 | 0 | **763** | 451.25 | numpad (312) | **312** | 433 | 330 |
| B | 360×640, nav 24, IME down | 640 | 24 | 24 | 0 | **536** | 281.0 | numpad (312) | **281** (clamped) | 402 | 134 |
| C | 411×891, IME up 290, Type | 891 | 24 | 24 | 290 | **521** | 269.75 | type (80) | **80** | 201 | 320 |
| D | 360×640, IME up 290, Type | 640 | 24 | 24 | 290 | **270** | 81.5 → floor **96** | type (80) | **80** | 201 | 13 |
| E | 360×640, IME mid-fall 150, just paged Type→Numpad | 640 | 24 | 24 | 150 | **410** | 186.5 | numpad (312) | **186.5** → retargets to 281 | 307.5 → 402 | 102 → 134 |

Checks:

- **B (clamp binds):** 281 viewport − 32 pad padding − 24 row gaps = 225 over 4 numpad rows = **56.25/row ≥ KeyCap's 48px floor**, so caps flex instead of overflowing — the mechanism at `key_pads.dart:229-233`.
- **D (floor binds on the ceiling):** the documented exception at `key_pads.dart:220-228`, now with a different consequence: only 13px of host screen remains. Acceptable because the IME is only ever up on the Type pad (`keyboard_panel.dart:271-281`), which asks for just 80px.
- **E is the case the old code could not see.** Mid-IME-animation the metrics change every frame; the panel needed `didChangeMetrics` to notice. The shell notices via its MediaQuery dependency, `AnimatedSize` re-targets, and no frame overflows. **This is the concrete payoff of reading the ancestor MediaQuery instead of the raw view.**
- **Sanity vs the thing being deleted:** `FloatingTrackpadWindow` was `0.38 × screen height` (`floating_trackpad_window.dart:52`) = 338 on device A, of which 48 header + 56 buttons = **234 of actual pad**. The trackpad overlay proposed below gives 363 on the same device — strictly better than the affordance it replaces.

### 4.5 The trackpad overlay's height

```
kSummonTrackpadFraction = 0.55      // design choice
kSummonTrackpadMinBlock = 220       // absolute floor
kSummonMouseBarHeight   = 56        // matches floating_trackpad_window.dart:232

block   = clamp(available * 0.55, kSummonTrackpadMinBlock, available)
surface = block − kSummonMouseBarHeight
```

- A: block 419.65 → surface **363.65**
- B: block 294.8 → surface **238.8**

No header row (the retiring window's 48px `⠿`/`⤢`/`✕` header, `floating_trackpad_window.dart:55`, `:240-286`, exists only to serve dragging and the two nav buttons — both die with the window). Dismiss is the bar icon; "open full" is the Trackpad tile, which survives at the end of `kHubTiles`.

---

## 5. The hidden IME input

### 5.1 How it is mounted today

Two mounts, both following the same rule:

- Docked panel: `keyboard_panel.dart:413-420` — the **first child of the panel's outer `Column`**, i.e. a sibling of, and *outside*, the `AnimatedSize` chrome (`:425-458`). The comment: *"ALWAYS mounted (both states, every pad): a 1x1 invisible sliver outside the animating chrome, so neither toggling nor paging ever detaches the IME connection."*
- Full screen: `keyboard_screen.dart:319-325` — a `Column` child **outside the `PageView`**.

The widget itself refuses to be hidden the wrong way: `hidden_text_input.dart:110-115` — 1×1 `SizedBox` + `Opacity(0)` + `IgnorePointer` + `ExcludeSemantics`, and *"NEVER Offstage/Visibility(maintainState:false) — they detach the Android input connection."* The existing guarantee is pinned by `keyboard_panel_test.dart:130-152` (identical `State` object across the toggle).

### 5.2 Where it must live in the new tree — exactly

**A direct `Positioned` child of the shell's `Stack`, mounted unconditionally, sibling of both the bar and the overlay, outside the Navigator.**

```dart
// summon_shell.dart — build()
Stack(children: [
  Positioned.fill(child: MediaQuery(data: /* +bar padding */, child: child!)),   // the Navigator
  const Positioned(left: 0, bottom: 0, width: 1, height: 1,                      // ← HERE
      child: HiddenTextInput(...)),
  ...bar, overlay, banner
])
```

Constraints a planner must not relax:

1. **Unconditional.** Never inside an `if (raised)`, never a child of the overlay, never a child of an `AnimatedSize`/`AnimatedPositioned`/`SlideTransition`. If it is inside the animating chrome, Android tears down the input connection on every summon — landmine #3.
2. **Outside the Navigator** (a sibling of `child!`, not inside it). This is *stronger* than what exists today and it is free: a route push/pop can no longer detach the connection either. Today the docked panel's field dies with the trackpad screen; the shell's does not.
3. **Zero layout footprint.** As a `Positioned` with explicit `width: 1, height: 1` it contributes nothing to the overlay's height — which is why `kPanelColumnOverhead`'s `+1` (`key_pads.dart:164-180`) must be dropped from the new arithmetic (§4.3 Step 6).
4. **Its `FocusNode`, `ImeDiffProducer` and `resetSignal` all live at shell scope.** `resetSignal` is `controller.imeResetTick` (`keyboard_input_controller.dart:77`), disposed by `controller.dispose()` (`:119`). With both at shell scope the signal identity never changes; `hidden_text_input.dart:64-72` handles identity changes anyway, and `ChangeNotifier.removeListener` after dispose is safe, so this is belt-and-braces.
5. **A `Material` + `Directionality` ancestor is required.** `MaterialApp.builder` supplies `Directionality`/`Theme`/`Localizations`; the shell should still wrap its `Stack` in `Material(color: kBg, …)` — the same thing `BubbleScaffold` does today (`bubble_scaffold.dart:166`).
6. **Regression test to carry forward:** clone `keyboard_panel_test.dart:130-152` at shell scope, and add the stronger case — *summon → dismiss → **push a route** → summon: the `HiddenTextInput` `State` is identical throughout.*

---

## 6. What retires, and every reference to it

### 6.1 The three named symbols — complete reference lists

**`TrackpadBubble`** — `lib/widgets/trackpad_bubble.dart` (whole file)

| File:line | Reference |
|---|---|
| `lib/widgets/bubble_scaffold.dart:46` | import |
| `lib/widgets/bubble_scaffold.dart:15, 129, 210` | doc + `_bubbleAnchor` mirror comment + the collapsed-state render |
| `test/trackpad_bubble_test.dart` (whole file, 4 tests) | **delete** |
| `test/bubble_scaffold_test.dart:5-11, 23, 36, 119, 129, 139, 145, 153, 226` | **delete/rewrite** |

**`FloatingTrackpadWindow`** — `lib/trackpad/floating_trackpad_window.dart` (whole file)

| File:line | Reference |
|---|---|
| `lib/widgets/bubble_scaffold.dart:16, 44, 130, 191, 197` | doc, import, anchor comment, expanded-state render |
| `lib/settings/window_position.dart:13` | doc reference |
| `test/floating_trackpad_window_test.dart` (whole file, 5 groups) | **delete** |
| `test/bubble_scaffold_test.dart:8, 23, 35, 130, 140, 147, 152, 178, 218, 224` | **delete/rewrite** |

**`windowPositionProvider`** + `WindowPosition` + `WindowPositionStore` + `WindowPositionNotifier` + `kWindowPositionPrefsKey` — `lib/settings/window_position.dart` (whole file)

| File:line | Reference |
|---|---|
| `lib/trackpad/floating_trackpad_window.dart:41, 121, 148, 160, 171, 182` | import + `_resolve`/pan handlers/build |
| `test/window_position_test.dart` (whole file, 3 groups) | **delete** |
| `test/floating_trackpad_window_test.dart:7, 36, 176` | **delete** |
| Orphaned pref key `window.position` in installed apps | harmless; no migration needed (the store degrades to the unset sentinel, `window_position.dart:92-103`). Optional one-line cleanup. |

### 6.2 Two more things that die — the design note does not list either

**`bubblePositionProvider` and all of `lib/settings/bubble_position.dart`.** Its only consumers are `TrackpadBubble` (`trackpad_bubble.dart:96, 118, 132, 161, 173`) and `BubbleScaffold._bubbleAnchor` (`bubble_scaffold.dart:131-140, 150`). With both gone the file, the provider, the `Edge` enum, the `bubble.position` pref key and `test/bubble_position_test.dart` (5 groups) are all dead. **Add it to the deletion list explicitly** — otherwise it survives as a store nothing reads and a test suite that passes forever while proving nothing.

**`UipiBanner` loses its only production mount.** Detailed in §1.3. `bubble_scaffold.dart:181` is the sole `UipiBanner.forService` call site in `lib/`. **This must be rehomed to the shell in the same plan that deletes `BubbleScaffold`, or the SRV-05 advisory disappears silently** — no test will catch it, because `test/uipi_banner_test.dart` builds the widget directly.

### 6.3 The full test-migration table

| Test file | Fate |
|---|---|
| `test/trackpad_bubble_test.dart` | **Delete** |
| `test/floating_trackpad_window_test.dart` | **Delete** — but harvest the `_RecordingService` + `KeepAwake` spy idiom (`:22-24`) for the new shell tests |
| `test/window_position_test.dart` | **Delete** |
| `test/bubble_position_test.dart` | **Delete** |
| `test/bubble_scaffold_test.dart` | **Rewrite as `summon_shell_test.dart`.** Contracts 1/2/3 (`:5-11`) are bubble-specific and die. Contract 4 — *"a tappable widget in the body OUTSIDE the raised surface still receives a tap"* (`:11-16`, `:155-185`) — is the **most valuable test in the milestone** and must survive verbatim in spirit: it is what proves "overlay, not screen". Contract 5, back-intercept (`:187-227`), survives against the new `SummonBackGuard`. |
| `test/hub_tiles_test.dart` | **Update.** `kExpectedOrder` (`:15-25`) and the index assertions (`:49-52`) hard-code Trackpad at 0 and Keyboard at 1. New order: Shortcuts, Media, Apps, Clipboard, Power, Presenter, Browser, **Trackpad, Keyboard**. Row/tail geometry assertions (`:96-118`) still hold at 9 tiles — the tail tile becomes Keyboard. |
| `test/hub/hub_screen_test.dart:22-34` | **Update.** Asserts *"D-02: the trackpad is the full-width primary tile — always first in the registry"*. That comment is already stale (the primary row died in 07-13); now the assertion itself inverts. |
| `test/hub_offline_test.dart` | Likely unaffected (asserts `onTap: null` + gear reachability). Re-run. |
| `test/widget_test.dart` | **Update.** The only test that pumps `RemoteControlApp` (`main.dart`), so it is the only existing test that will see the shell. Add: the bar renders on the hub. |
| `test/keyboard/keyboard_panel_test.dart` | **Keep unchanged** if the deck is extracted without changing `KeyboardPanel`'s public shape. Its 20 tests are the third mount point's safety net by proxy. If `_deck()` is extracted, re-run to prove behaviour-neutrality. |
| `test/keyboard/keyboard_screen_test.dart`, `keyboard_input_controller_test.dart`, `key_pads_test.dart`, `modifier_chip_test.dart` | Unaffected by the mount point; `modifier_chip_test.dart` is touched by the chip-row fix. |
| `test/trackpad/trackpad_screen_test.dart:295-304` | **Must be rewritten by the chip-row fix** — see §6.5. |
| **New:** `test/shell/summon_shell_test.dart` | bar presence on hub + a tool screen; body hit-testable while raised; hidden-input `State` identity across summon/dismiss/route-push; the §4.4 inset table as a driven-viewport table test (mirroring `trackpad_screen_test.dart:225-307`'s style). |

### 6.4 What `showBubble: false` should BECOME

**Current meaning** (`hub_screen.dart:69-73`, `:91-93`; `bubble_scaffold.dart:59-61`, `:119-121`): a property of the **`HubTileSpec`** — "the route this tile creates must not show a shortcut to the screen it is". Set in two places: the Trackpad tile (`hub_screen.dart:92`) and the `⤢` push from the floating window (`bubble_scaffold.dart:120`).

**Why a mechanical port fails, three ways:**

1. **The second call site dies.** `bubble_scaffold.dart:114-126` (`_openFullTrackpad`) is deleted with the window. So the flag would have exactly one setter left — a `bool` field on a public class, set once. That is a constant, not a parameter.
2. **It is attached to the wrong object.** It lives on `HubTileSpec` — the *tile that creates the route*. But the summon bar is app-scope and knows nothing about which tile produced the current route. And the Keyboard screen is now reachable by other means too. The property being described is *"what surface am I already looking at"*, which is a property of the **screen**, not of the tile.
3. **It hid a whole affordance.** With one affordance (the bubble) that was fine. With a two-icon bar, hiding an icon changes the bar's shape from screen to screen — which contradicts "permanent bottom bar". The bar must be geometrically identical everywhere.

**Recommended replacement:**

```dart
enum SummonSurface { trackpad, keyboard }

/// The surface this screen IS. The bar renders the matching icon in a
/// selected-and-inert state ("you are here") instead of hiding it, so the
/// bar's geometry is identical on every screen.
final activeSurfaceProvider = NotifierProvider<ActiveSurfaceNotifier, SummonSurface?>(...);
```

- `TrackpadScreen` (`trackpad_screen.dart:75`) and `KeyboardScreen` (`keyboard_screen.dart:108`) declare themselves in `initState` and clear in `dispose`.
- **Use a depth-counted / last-writer-wins stack, not a nullable set/clear.** On push, the new route's `initState` runs while the old route is still mounted; on pop, `dispose` runs after the transition. A naive set/clear will produce a stale or prematurely-cleared value at both boundaries. Pin it with a push-then-pop widget test.
- `HubTileSpec.showBubble` is **deleted** (`hub_screen.dart:69-73`, `:80`, `:92`); `_open` (`hub_screen.dart:282-293`) collapses to a plain push wrapped in `SummonBackGuard`.

**The intent survives verbatim** — *never a shortcut to the screen you are on* — while the mechanism moves from "hide an affordance, decided by the tile" to "mark the icon inert, decided by the screen". That is the deliberate re-read landmine #5 asks for.

### 6.5 Landmine #4 — the chip-row overflow test

The overflow is `ModifierChip`'s inner `Row` (`modifier_chip.dart:76-92`): a 16/w600 label measuring ~81.3dp inside a 74dp cell at 360dp width. The chip row geometry is shared verbatim between `keyboard_screen.dart:213-233` and `keyboard_panel.dart:306-326`, and the summon overlay will make it **three** surfaces.

The tripwire is **not** in `modifier_chip_test.dart` (the design note's implied location); it is at **`test/trackpad/trackpad_screen_test.dart:291-304`**:

```dart
expect(overflows, greaterThan(0),
    reason: 'if this ever reaches zero, the chip row was fixed — delete '
        'this drain and restore a plain takeException-is-null assertion');
```

**Plan constraint:** the chip-row fix and this test's replacement must be the **same commit**, or the suite goes red for the right reason and looks like a regression.

---

## 7. Suggested build order

Dependencies found, then the order that respects them.

```
P1 shell + bar (empty overlay, inset arithmetic, banner rehomed)
   ├─► P2 trackpad surface into the overlay
   │      └─► P4 retire the bubble (needs a working replacement first)
   │             └─► P5 hub tiles last + showBubble re-read
   └─► P3 keyboard third mount point (deck extraction, controller at shell scope)
          └─► P6 chip-row 360dp fix + retire the drain test   (also depends on P3:
                 the fix must land on all THREE surfaces at once)
```

| # | Plan | New | Modified | Deleted | Demo |
|---|---|---|---|---|---|
| **P1** | **Shell + bar, empty overlay** | `shell/summon_shell.dart`, `shell/summon_bar.dart`, `shell/summon_back_guard.dart`, `test/shell/summon_shell_test.dart` | `main.dart:112-118` (add `builder:`), `hub_screen.dart:282-293` (guard wrapper), `widget_test.dart` | — | **The bar is on the hub and all 9 tool screens; nothing beneath is clipped or reflowed; tapping an icon raises a correctly-sized empty panel that animates in 200ms; back dismisses it.** |
| **P2** | Trackpad surface | — | `summon_shell.dart` | — | Cursor moves from the raised overlay on any screen; dismissing releases drag-lock and the wakelock. |
| **P3** | Keyboard third mount | `keyboard/keyboard_deck.dart` (extracted), `summonPadProvider` in `key_rows.dart` | `keyboard_panel.dart` (use the extracted deck), `keyboard_screen.dart` (same), `summon_shell.dart` | — | Type on any screen; lock Shift, dismiss → PC releases it; page to Numpad, dismiss, re-summon → lands on Numpad with **no hop**. |
| **P4** | Retire the bubble | — | `hub_screen.dart` | `widgets/trackpad_bubble.dart`, `widgets/bubble_scaffold.dart`, `trackpad/floating_trackpad_window.dart`, `settings/window_position.dart`, `settings/bubble_position.dart` + 4 test files | Suite green with 5 source files and ~4 test files gone. |
| **P5** | Tiles last + flag re-read | `SummonSurface`, `activeSurfaceProvider` | `hub_screen.dart:59-144`, `trackpad_screen.dart`, `keyboard_screen.dart`, `hub_tiles_test.dart`, `hub/hub_screen_test.dart` | `HubTileSpec.showBubble` | Trackpad + Keyboard are the last two tiles; on those screens the matching bar icon reads inert. |
| **P6** | Chip row at 360dp | — | `modifier_chip.dart:76-92`, `trackpad_screen_test.dart:291-304`, `modifier_chip_test.dart` | the drain assertion | No overflow at 360dp on all three keyboard surfaces. |

**Why P1 first and why the empty overlay is the right first demo:** the inset arithmetic (§4) is the highest-risk, highest-value unknown, it is entirely independent of what the overlay contains, and getting it wrong is invisible until a real device with gesture nav and a raised IME. An empty panel with a derived height, driven through the five viewports in §4.4, retires that risk before a single line of surface code exists.

**Why the trackpad before the keyboard:** it exercises the whole overlay lifecycle (mount, dismiss, unmount, keep-awake, drag-flush) with no IME involved, so a failure there is unambiguous. Doing the keyboard first would entangle overlay-lifecycle bugs with IME-connection bugs.

**Why the bubble cannot be deleted before P2:** deleting it first leaves the owner with no fast trackpad access on tool screens for the duration of the milestone. Keeping both briefly is the safe order and costs nothing but a temporary double affordance.

---

## 8. Things the design note asserts that I could NOT verify — flagged

| Note claim | Status |
|---|---|
| Landmine #1: *"A LOCKED modifier survives a dismiss… Has its own todo."* (`notes:116-121`) | **ALREADY FIXED — the note has drifted.** Quick `260812-tsw` shipped `KeyboardInputController.dismissed()` (`keyboard_input_controller.dart:143-146`), the call site (`keyboard_panel.dart:244-249`) and two tests (`keyboard_panel_test.dart:561-610`). The todo is in `.planning/todos/done/2026-08-11-locked-modifier-survives-a-panel-dismiss.md`. **It is not zero work for v1.1**, though: the third mount point must *call* `dismissed()` on its dismiss edge, and `260809-ipc/deferred-items.md#2` is now stale. |
| Landmine #4: *"pinned by a test that drains the overflow"* — location implied to be a keyboard suite (`notes:130-134`) | **Correct behaviour, wrong file.** It is `test/trackpad/trackpad_screen_test.dart:291-304`. `modifier_chip_test.dart` contains no overflow handling. |
| Scope list names `bubble_scaffold_test.dart`, `floating_trackpad_window_test.dart`, `hub_tiles_test.dart` and "the keyboard suites" (`notes:141-144`) | **Under-counts by 4 files.** Also affected: `trackpad_bubble_test.dart`, `window_position_test.dart`, `bubble_position_test.dart`, `hub/hub_screen_test.dart`, plus `widget_test.dart` and `hub_offline_test.dart` to re-run. |
| Retirement list of 3 symbols (`notes:24-27`) | **Under-counts by 2.** `bubble_position.dart`/`bubblePositionProvider` becomes dead, and `UipiBanner` loses its only production mount (§6.2). |
| *"The bar rides the hub too — ASSUMED"* (`notes:32-35`) | The assumption is **cheap and safe** under an app-scope shell: the hub gets the bar for free, and there is no code reason to exclude it. Not contradicted by anything in the tree. |
| *"~4-6 plans"* (`notes:141`) | **6 plans** as scoped in §7, with P1 carrying most of the risk. Consistent. |
| Back-gesture dismissal mechanism | **NOT verified in code.** `PopScope` needs a `ModalRoute` and the shell sits above the Navigator; the per-route `SummonBackGuard` is the proposed answer but has not been proven here. **MEDIUM confidence — spike it in P1.** |
| `PageController` page restore across dismiss/re-summon | **NOT verified.** No test covers "page → collapse → expand" for the docked panel; whether `PageStorage` restores the offset is implementation-dependent. **Treat as a real risk, not a theoretical one** (§2.4). |

---

## 9. Anti-patterns specific to this integration

**AP-1 — "Simplify" the shell's height read into `MediaQueryData.fromView(View.of(context))`.**
It would produce the same number today and opt out of the automatic rebuild the ancestor MediaQuery provides, re-introducing the need for `didChangeMetrics` and breaking the mid-IME-animation case (§4.4 row E). The panel's raw-view read is a **workaround for a stripped tree**, not a house style.

**AP-2 — Factor the panel's `columnHeight` and the shell's `available` into one helper.**
They differ by `kSummonBarHeight` and would tempt exactly that. They read from **different sources** for different reasons. Sharing the helper means sharing the source, which is correct for only one caller.

**AP-3 — Reuse `kPanelColumnOverhead` (122) for the overlay.**
Its `+1` is the docked panel's in-Column IME sliver. The shell's hidden field is a `Positioned` sibling and costs the overlay nothing (§5.3).

**AP-4 — Keep `TrackpadCore` mounted while dismissed "so it restores instantly".**
It restores instantly anyway (nothing visual to restore) and holding it mounted pins the process-wide wakelock for the entire session (§3.3).

**AP-5 — Turn the overlay into a resize/inset contract.**
`notes:56-59` and `PROJECT.md:111` both pre-emptively reject this. Nothing on the phone is the input target; there is no field to keep visible. The only screens where that rationale *would* apply (`device_list_screen`, `pairing_dialog`) are handled correctly by the arithmetic in §4 with no reflow of anything else.

**AP-6 — A third copy of the keyboard deck.**
`260809-ipc` existed to delete the second copy. `key_pads.dart:361-365` and `keyboard_panel.dart:20-27` both say it outright. Extract `KeyboardDeck`; do not paste.

---

## Sources

- Working tree `C:/Users/omkar/Projects/Remote Control/app/remote_control/` at `master` @ `7c9ecf8` — every `file.dart:line` citation above, read directly — **HIGH**
- `.planning/notes/summon-bar-trackpad-keyboard.md` (2026-08-11) — the design and its five landmines — **HIGH** (with the four drifts flagged in §8)
- `.planning/quick/260809-ipc-.../deferred-items.md` — chip-row overflow provenance and the tripwire's stated location — **HIGH**
- `.planning/todos/done/2026-08-11-locked-modifier-survives-a-panel-dismiss.md` — proof landmine #1 shipped — **HIGH**
- `.planning/research/questions.md` OQ-A1 — the unquantified speed contract; §2.4 answers sub-question 2 structurally — **HIGH**
- [api.flutter.dev — MaterialApp.builder](https://api.flutter.dev/flutter/material/MaterialApp/builder.html) — builder sits above the Navigator, below Theme/MediaQuery/Directionality/Localizations — seam-classified **LOW** (provider `webfetch`); official doc, cheap to prove in a widget test
- [api.flutter.dev — PopScope](https://api.flutter.dev/flutter/widgets/PopScope-class.html) — registers with the enclosing `ModalRoute` via `registerPopEntry`; will not intercept above the Navigator — seam-classified **LOW** (provider `webfetch`); drives the `SummonBackGuard` recommendation, flagged for a P1 spike

---
*Architecture research for: v1.1 The Summon Bar (client-side Flutter only)*
*Researched: 2026-08-12*
