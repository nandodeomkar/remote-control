# Phase 13: Summon Shell & Bar - Pattern Map

**Mapped:** 2026-08-14
**Files analyzed:** 14 (7 new, 4 modified, 3 new test suites + N existing suites touched)
**Analogs found:** 12 / 14

All paths below are relative to `app/remote_control/` unless stated otherwise.

## File Classification

| New/Modified File | Role | Data Flow | Closest Analog | Match Quality |
|-------------------|------|-----------|----------------|---------------|
| `lib/shell/summon_shell.dart` (new) | host widget / provider | event-driven (animation + focus + connection) | `lib/widgets/bubble_scaffold.dart` | exact (same Stack + reactive-`PopScope` + banner-slot shape, one scope up) |
| `lib/shell/summon_geometry.dart` (new) | utility (pure arithmetic + consts) | transform | `lib/keyboard/key_pads.dart:127-240` (`kPanelColumnOverhead`, `panelPadHeight`) | role-match (**shape only — values must NOT be reused**, D-13-15) |
| `lib/shell/summon_bar.dart` (new) | component (chrome) | request-response (tap → shell) | `lib/keyboard/key_pads.dart:332-402` `KeyboardTabBar` | exact (56dp bottom icon bar, hairline top, accent-vs-muted tint) |
| `lib/shell/summon_icon_button.dart` (new) | component (interactive control) | request-response | `lib/hub/hub_screen.dart:215-257` `_HubTile` | exact (offline = muted + `onTap: null`, layout never shifts) |
| `lib/shell/summon_surface.dart` (new) | component (chrome) | event-driven (animated) | `lib/trackpad/floating_trackpad_window.dart` (card) + `key_pads.dart` panel hairline | role-match |
| `lib/shell/summon_handle.dart` (new) | component (inert chrome) | none | `lib/trackpad/floating_trackpad_window.dart:240-257` `_header()` | role-match (glyph + sibling-gesture rule; **no** recognizer in 13) |
| `lib/shell/summon_back_guard.dart` (new) | middleware (route-scoped) | event-driven (back gesture) | `lib/widgets/bubble_scaffold.dart:157-165` `PopScope` | exact |
| `lib/shell/summon_scope.dart` (new) | provider (`InheritedWidget`) | pub-sub (non-subscribing read) | **none in tree** — no `InheritedWidget` exists in `lib/` | no analog |
| `lib/main.dart` (mod) | config / app shell | — | itself (`main.dart:110-119`) | exact |
| `lib/browser/browser_screen.dart` (mod) | screen | event-driven (back) | itself (`:576-580`) | exact |
| `lib/screens/pairing_dialog.dart` (mod) | screen (push site + suppressor) | request-response | `pairing_dialog.dart:359-361` | exact |
| `test/shell/summon_geometry_test.dart` (new) | test (driven viewport) | transform | `test/trackpad/trackpad_screen_test.dart:119-240` | exact |
| `test/shell/summon_shell_test.dart` (new) | test (widget) | event-driven | `test/bubble_scaffold_test.dart` | exact |
| `test/push_sites_guard_test.dart` (new, D-13-16) | test (source scan) | file-I/O | `test/icons_guard_test.dart` | exact |

---

## Pattern Assignments

### `lib/shell/summon_shell.dart` (host widget, event-driven)

**Analog:** `lib/widgets/bubble_scaffold.dart` — read it whole; it is the same widget one scope higher.

**Imports pattern** (`bubble_scaffold.dart:32-47`) — note `library;` after the leading doc comment, relative imports, `../theme/tokens.dart`:

```dart
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:remote_protocol/remote_protocol.dart';

import '../net/connection_providers.dart';
import '../net/connection_service.dart';
import '../theme/tokens.dart';
```

**Consumer + controller lifecycle** (`bubble_scaffold.dart:74-109`) — copy verbatim, renaming to `_raise`/`_swap`:

```dart
class _BubbleScaffoldState extends ConsumerState<BubbleScaffold>
    with SingleTickerProviderStateMixin {
  final ValueNotifier<bool> _expanded = ValueNotifier<bool>(false);
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: kBubbleExpandDuration);
  }

  @override
  void dispose() {
    _expanded.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _expand()   { _expanded.value = true;  unawaited(_controller.forward()); }
  void _collapse() { _expanded.value = false; unawaited(_controller.reverse()); }
}
```
> Two controllers in Phase 13 (`_raise`, `_swap`) ⇒ use `TickerProviderStateMixin`, **not** `SingleTickerProviderStateMixin`. Keep the `unawaited(...)` house idiom on both `forward()`/`reverse()`.

**Value-equal provider reads, with the reason comment** (`bubble_scaffold.dart:143-150`) — this is D-13-13's mandated source:

```dart
// App-lifetime singleton — watching a plain Provider never rebuilds.
final service = ref.watch(connectionServiceProvider);
// Transition-only snapshot (value-equal): rebuilds on lifecycle changes,
// never on the trackpad move path (Phase-2 invariant).
final status = ref.watch(connectionStatusProvider);
final authed = status.chip == ChipStatus.connected;
```
`ConnectionStatus` is value-equal by `operator ==` at `lib/net/connection_providers.dart:85-106` — that is why this never rebuilds on the hot path. **Never** `service.changes`.

**Core pattern — reactive `canPop` + Stack, body built exactly once** (`bubble_scaffold.dart:152-183`). This is the shape 13-RESEARCH §7.4 says to reuse verbatim; only the children change:

```dart
return ValueListenableBuilder<bool>(
  valueListenable: _expanded,
  builder: (context, expanded, child) => PopScope(
    canPop: !expanded,
    onPopInvokedWithResult: (didPop, result) {
      if (!didPop) _collapse();
    },
    child: child!,
  ),
  child: Material(
    color: kBg,
    child: Stack(
      children: [
        Positioned.fill(child: widget.body),
        Positioned(
          top: 0, left: 0, right: 0,
          child: SafeArea(
            bottom: false,
            child: UipiBanner.forService(service),
          ),
        ),
        // ...the only subtree that rebuilds on the notifier
      ],
    ),
  ),
);
```
Shell differences the planner must state explicitly: (a) the `PopScope` moves **out** of the shell into `SummonBackGuard` (there is no route above the builder — 13-RESEARCH §2), so the outer `ValueListenableBuilder` at the shell wraps `SummonScope` instead; (b) `Positioned.fill(child: widget.body)` becomes `Positioned.fill(child: MediaQuery(data: bumped, child: child!))`; (c) the bar is the **last** `Stack` child.

**UIPI banner slot** — reuse `bubble_scaffold.dart:175-183` byte-for-byte (`Positioned(top/left/right:0)` → `SafeArea(bottom: false)` → `UipiBanner.forService(service)`). `bubble_scaffold.dart:181` is the sole production mount in `lib/`; Phase 16 relocates it here.

**Positioned-child trap already documented in the analog** (`bubble_scaffold.dart:191-196`): a `Positioned` returned by a child must be a *direct* descendant of the `Stack` — no intervening `Transform`/`Opacity`. Phase 13 inverts this correctly (the shell owns the `Positioned`, `Transform.translate` is *inside* it), but carry the comment style.

---

### `lib/shell/summon_geometry.dart` (utility, transform)

**Analog:** `lib/keyboard/key_pads.dart:127-240` — **structural analog only.** D-13-15 and 13-RESEARCH § Anti-Patterns forbid reusing `kPanelMaxHeightFraction` (0.55), `kPanelColumnOverhead` (122), `kPanelPadHeights` or `panelPadHeight`.

**What to copy: the honesty-comment convention that separates derived numbers from chosen ones** (`key_pads.dart:134-142`, verbatim style):

```dart
// HONESTY ABOUT THE NUMBERS: the padding / gap / row consts above are REAL —
// they are what the pads actually lay out with. The 64px numpad row and the
// 76px arrows inverted-T cell below are CHOSEN TARGETS, not constants read
// back from the pads...
```
D-13-09/D-13-14 require exactly this treatment for `kSummonTrackpadHeight = 280` and `kSummonKeyboardHeight = 432` — name them **design choices, not arithmetic**, in the doc comment.

**Const-composition style** (`key_pads.dart:144-180`): every hairline/row/chrome number is a named `const double` and composites are `const` expressions built from them (`kPanelChromeHeight = _kPanelHairline + _kPanelChipRowHeight + _kTabBarHeight`). Mirror this for `surfaceContentHeight` = height − `kSummonHairline` − `kSummonHandleBandHeight`.

**Public-vs-private const rule, observed across the file:** consts a test or another file asserts against are public (`kPanelChromeHeight`, `kPanelColumnOverhead`, `kPanelMinPadHeight`); layout-internal ones are `_`-prefixed. All six UI-SPEC constants are asserted by tests ⇒ all public.

**`viewPaddingOf`-not-`paddingOf` precedent** lives at `lib/keyboard/keyboard_panel.dart:399-403` — the one piece of the old arithmetic that transfers verbatim.

---

### `lib/shell/summon_bar.dart` (component, request-response)

**Analog:** `lib/keyboard/key_pads.dart:332-402` `KeyboardTabBar` — the in-tree 56dp bottom icon bar.

**Core pattern** (`key_pads.dart:348-401`):

```dart
return ColoredBox(
  color: kBg,
  child: SafeArea(
    top: false,
    child: SizedBox(
      height: _kTabBarHeight,
      child: Row(
        children: [
          for (final pad in KeyboardPad.values)
            Expanded(
              child: InkWell(
                onTap: () => onSelect(pad),
                child: Container(
                  decoration: BoxDecoration(
                    border: Border(
                      top: BorderSide(
                        color: pad == current ? kAccent : kHairline,
                        width: pad == current ? _kTabUnderlineWidth : _kTabHairlineWidth,
                      ),
                    ),
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(kKeyboardTabIcons[pad], size: _kTabIconSize,
                           color: pad == current ? kAccent : kMuted),
                      ...
```

**What carries over:** `kBg` fill, `SizedBox(height: 56)`, 1px `kHairline` top `Border` on a decorated box, 24px glyph, `kAccent`-vs-`kMuted` tint switch, `InkWell` as the entire press feedback (no scale, no haptic).

**What must deliberately differ** (per 13-UI-SPEC): no `Expanded`/no `SafeArea` inside (the shell's `Positioned(bottom: barBottomOffset)` owns the inset); `Row(mainAxisAlignment: MainAxisAlignment.center)` with two fixed 56×56 slots and a `SizedBox(width: 32)`; the top border is `kHairline` full-width and **never** becomes the 2px accent underline (that treatment stays `KeyboardTabBar`'s).

**Stateless + callback-in constructor style** (`key_pads.dart:332-345`): a `StatelessWidget` taking `current` + `void Function(...) onSelect`, with dartdoc on every field. Copy this shape — the bar must not itself be a `ConsumerWidget` unless it reads `connectionStatusProvider` directly; keep the rebuild scope minimal (P9).

---

### `lib/shell/summon_icon_button.dart` (component, request-response)

**Analog:** `lib/hub/hub_screen.dart:215-257` `_HubTile` — the canonical offline-mutes-but-stays-live control.

**Core pattern** (`hub_screen.dart:227-256`):

```dart
return Material(
  color: kSurface,
  shape: RoundedRectangleBorder(...),
  child: InkWell(
    onTap: enabled ? () => onOpen(spec) : null,   // null ⇒ no ripple, for free
    borderRadius: BorderRadius.circular(16),
    child: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(spec.icon, size: 32, color: kMuted),
          ...
          Text(spec.label, style: TextStyle(..., color: enabled ? kText : kMuted)),
```

**Copy exactly:** `onTap: enabled ? ... : null` as the *entire* disable mechanism (UI-SPEC rule 4: "no ripple on a disabled icon — `onTap: null` removes it for free"), and the `enabled ? kText : kMuted` ternary, which is the tree precedent CR-1 leans on. **Layout is identical across states** — the tile's fill, border and box never change with `enabled`; the summon icon's 56×56 slot must likewise be `Rect`-identical across all four states including the CR-2 glyph swap.

**Its doc comment states the invariant** (`hub_screen.dart:211-214`) — *"Disabled (D-08 offline): `onTap` null (no ripple), label muted, same fill/border so the layout is stable."* Write the equivalent sentence for the four-state function.

**Tooltip-as-semantics precedent** (`hub_screen.dart:347-354`):

```dart
IconButton(
  tooltip: badge ? kSettingsWithUpdateTooltip : kSettingsTitle,
  onPressed: _openSettings,
  icon: const Icon(Symbols.settings_rounded, size: 24, color: kText),
),
```
Named copy consts, tooltip carries the state for a screen reader. **Deviation required by 13-UI-SPEC:** in state 2 the `Tooltip` must be an **ancestor** of the `InkWell`, not `IconButton.tooltip` on a disabled button.

**Icon consts to reuse verbatim:** `Symbols.touch_app_rounded` (`hub_screen.dart:89`), `Symbols.keyboard_rounded` (`hub_screen.dart:97`). Labels `'Trackpad'` / `'Keyboard'` at `hub_screen.dart:88, :96`.

---

### `lib/shell/summon_handle.dart` (component, inert chrome)

**Analog:** `lib/trackpad/floating_trackpad_window.dart:240-257` `_header()`.

```dart
// The ⠿ drag handle — its OWN GestureDetector (a SIBLING of the core
// Listener below, never an ancestor). A pan here moves + clamps the
// window; a touch on the surface never reaches this detector.
GestureDetector(
  behavior: HitTestBehavior.opaque,
  onPanStart: _onPanStart,
  ...
  child: const Padding(
    padding: EdgeInsets.symmetric(horizontal: 12),
    child: Icon(Symbols.drag_indicator_rounded, size: 20, color: kMuted),
  ),
),
```

**Carry over:** `kMuted` glyph, and — as a doc comment only — the sibling-not-ancestor rule for Phase 14.
**Do NOT carry over:** the `GestureDetector` itself (D-13-07: no recognizer at all in Phase 13), the glyph (`drag_handle_rounded`, not `drag_indicator_rounded`), the size (24, not 20), or the 16px-radius + shadow card treatment of the window (13-UI-SPEC Geometry rule 4 explicitly retires it).

**Test-facing key convention** from the same file (`floating_trackpad_window.dart:58, :61`):

```dart
const Key kWindowDragLockPillKey = Key('window-drag-lock-pill');
const Key kWindowCardKey = Key('floating-trackpad-card');
```
Public `const Key k…Key = Key('kebab-case')` declared beside the widget. The timing/geometry tests need `kSummonSurfaceKey`, `kSummonBarKey`, `kSummonTrackpadIconKey`, `kSummonKeyboardIconKey` in exactly this form.

---

### `lib/shell/summon_back_guard.dart` (middleware, event-driven)

**Analog:** `lib/widgets/bubble_scaffold.dart:159-165` and `lib/browser/browser_screen.dart:576-580`.

```dart
// bubble_scaffold.dart:159-163
PopScope(
  canPop: !expanded,
  onPopInvokedWithResult: (didPop, result) {
    if (!didPop) _collapse();
  },
  child: child!,
)

// browser_screen.dart:576-580 — identical shape, the guard that must learn the predicate
body: PopScope(
  canPop: !inFolder,
  onPopInvokedWithResult: (didPop, result) {
    if (!didPop) _onBookmarksBack();
  },
  child: SafeArea(...),
),
```
Both call sites already open with the `didPop` early-out — keep it. The guard's only allowed `canPop` is `!shell.ownsRaisedSurface(_id)` (13-RESEARCH §4); browser's callback gains `if (SummonScope.ownsRaisedSurface(context)) return;` before `_onBookmarksBack()` (D-13-18, predicate-based, never order-based).

**Push-site pattern to wrap** (`hub_screen.dart:282-293` — the central seam, the same "one place" move `pushGuarded` should make):

```dart
void _open(HubTileSpec spec) {
  unawaited(
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => BubbleScaffold(
          showBubble: spec.showBubble,
          body: spec.builder(context),
        ),
      ),
    ),
  );
}
```
Other sites to convert, all the same shape: `hub_screen.dart:298-300`, `settings_screen.dart:219, :660`, `device_list_screen.dart:94`, `bubble_scaffold.dart:117-124`, and `pairing_dialog.dart:359-361` (which returns a value — `push<PairQrData>` — so `pushGuarded<T>` must be generic and preserve the return type):

```dart
scanQr: () => Navigator.of(sheetContext).push<PairQrData>(
  MaterialPageRoute(builder: (_) => const QrScanScreen()),
),
```

---

### `lib/shell/summon_scope.dart` (InheritedWidget provider)

**No analog — `lib/` contains zero `InheritedWidget` subclasses** (grep: no hits for `InheritedWidget` or `getInheritedWidgetOfExactType`). Use 13-RESEARCH §3's code and the framework doc directly. Two house conventions still apply: a `library;` doc comment naming the contract, and a `static bool ownsRaisedSurface(BuildContext)` helper that internally uses the **non-subscribing** `context.getInheritedWidgetOfExactType<SummonScope>()`.

---

### `lib/main.dart` (config — the single insertion point)

**Analog:** itself, `main.dart:110-118`:

```dart
@override
Widget build(BuildContext context) {
  return MaterialApp(
    title: 'Remote Control',
    debugShowCheckedModeBanner: false,
    theme: buildAppTheme(),
    home: const HubScreen(),
  );
}
```
There is **no `builder:` today** — a clean insertion. Also note `initState` at `main.dart:52-74`: `bindHapticsCache(ref)` / `bindBeacons(ref)` are the house "install one app-scope thing once, before any frame" seam; if the shell needs an app-start binding, follow that shape rather than inventing a new one.

---

### `test/shell/summon_geometry_test.dart` (test, driven viewport)

**Analog:** `test/trackpad/trackpad_screen_test.dart:119-240` — this is the exact five-viewport discriminator idiom 13-RESEARCH §6.5 names.

**The driven-metrics helper** (`:147-164`) — copy verbatim, including the comment:

```dart
/// Drives the raw view metrics. devicePixelRatio 1 keeps FakeViewPadding
/// values 1:1 with logical pixels. When an IME inset is present, `padding`
/// bottom is 0 while `viewPadding` keeps the nav-bar value — that is how
/// the platform reports it, and the difference is the whole point.
void driveView(
  WidgetTester t, {
  required Size size,
  required double top,
  required double bottom,
  double ime = 0,
}) {
  t.view.devicePixelRatio = 1.0;
  t.view.physicalSize = size;
  t.view.viewPadding = FakeViewPadding(top: top, bottom: bottom);
  t.view.padding = FakeViewPadding(top: top, bottom: ime > 0 ? 0 : bottom);
  t.view.viewInsets = FakeViewPadding(bottom: ime);
  addTearDown(t.view.reset);
}
```

**Computed-never-quoted expectations** (`:166-176`) — the `columnOf` / `floorFor` pair is the model for `availableFor()` / `summonSurfaceHeightFor()`:

```dart
double columnOf({required Size size, required double top, required double bottom, double ime = 0}) =>
    size.height - top - (ime > bottom ? ime : bottom);

double floorFor(double column) => 0.45 * column - 64;
```

**Invariant helper with a `reason:` that states the guarantee** (`:187-194`):

```dart
void expectColumnFits(WidgetTester t, double column) {
  final trackpad = t.getSize(find.byType(TrackpadCore)).height;
  ...
  expect(trackpad + bar + panel, closeTo(column, 0.01),
      reason: 'trackpad + button bar + panel must EXACTLY fill the shared '
          'column — a larger sum is a vertical overflow');
}
```
`closeTo(x, 0.01)` is the house tolerance — use it for I1–I4.

**The discriminator preamble** (`:119-145`) is a prose block naming which cases are references and which are discriminators, and why an inset-free harness cannot catch the bug class. Write the equivalent block for F1–F5 above the summon suite.

**Explicit-pump timing, `pumpAndSettle` avoided** (`:217-222`):

```dart
await t.tap(find.byIcon(Symbols.keyboard_rounded));
await t.pump();
await t.pump(const Duration(milliseconds: 250)); // panel slide
await t.pump();
```

---

### `test/shell/summon_shell_test.dart` (test, widget)

**Analog:** `test/bubble_scaffold_test.dart` — same host shape, same back-intercept case.

**Host + ProviderScope override** (`:83-100`):

```dart
Widget _host({required bool showBubble, ConnectionService? service, Widget? body}) =>
    ProviderScope(
      overrides: [
        connectionServiceProvider.overrideWith((ref) => service ?? _RecordingService()),
      ],
      child: MaterialApp(
        home: BubbleScaffold(
          showBubble: showBubble,
          body: body ?? const Scaffold(body: Center(child: Text('tool body'))),
        ),
      ),
    );
```

**The recording service double** (`:40-81`) — `_FakeSecureKv` / `_FakePrefsKv` / `_RecordingService extends ConnectionService` with a settable `authed` and an overridden `chipStatus`. Copy wholesale; it is how the shell gets a connected/disconnected `connectionStatusProvider` without a socket.

**SUM-02's surviving contract test** (`:156-186`) — the hit-testability case that must keep passing with the surface instead of the window:

```dart
await t.tap(find.text('body tap target'));
await t.pump();
expect(bodyTaps, 1,
    reason: 'the body is a Positioned.fill sibling that never rebuilds '
        'off expand and stays hit-testable around the open window');
```

**Back-intercept case** (`:188-200+`) — uses `final navKey = GlobalKey<NavigatorState>();` inside a `ProviderScope` + `MaterialApp`; the D5 spike follows this exact setup, plus `find.byType` for builder-above-Navigator.

**Header comment convention:** every suite opens with a numbered `must_haves` list naming the decision IDs it pins (`bubble_scaffold_test.dart:1-23`). Reproduce with BAR-/SUM-/MOT- ids.

---

### `test/push_sites_guard_test.dart` (test, source scan — D-13-16)

**Analog:** `test/icons_guard_test.dart` — copy the whole file and swap the regex.

```dart
/// Explicit, reasoned exceptions ... as `lib/…/foo.dart:<line>` strings.
const List<String> kIconsGuardAllowlist = <String>[];

final RegExp _classicIconsRef = RegExp(r'(^|[^A-Za-z0-9_$])Icons\.');

void main() {
  test('no lib file uses classic Icons.* (Material Symbols Rounded guard)', () {
    final libDir = Directory('lib');
    expect(libDir.existsSync(), isTrue, reason: 'lib/ must exist');
    final offenders = <String>[];
    for (final entity in libDir.listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final normalized = entity.path.replaceAll('\\', '/');
      final lines = entity.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final trimmed = lines[i].trim();
        if (trimmed.startsWith('//')) continue;      // comments exempt
        if (_classicIconsRef.hasMatch(lines[i])) {
          final location = '$normalized:${i + 1}';
          if (kIconsGuardAllowlist.contains(location)) continue;
          offenders.add('$location -> ${trimmed.isEmpty ? lines[i] : trimmed}');
        }
      }
    }
    expect(offenders, isEmpty, reason: '...found:\n${offenders.join('\n')}');
  });
}
```
Four details to preserve: `Directory('lib')` relative to the package root, `replaceAll('\\', '/')` for Windows, the `//`-comment skip, and a `path:line` allowlist with a written reason per entry. For the push-site guard the allowlist is non-empty by design (`lib/shell/…`), so the doc comment must name each reason — the analog's "Allowlist: EMPTY" header block is the model for that prose.

---

## Shared Patterns

### Theme tokens (build-failing guard)
**Source:** `lib/theme/tokens.dart:19-37`
**Apply to:** every new file under `lib/shell/`
```dart
const Color kBg = Color(0xFF0E0F12);
const Color kSurface = Color(0xFF16181D);
const Color kHairline = Color(0xFF2A2D34);
const Color kText = Color(0xFFE6E8EB);
const Color kMuted = Color(0xFF6B7280);
const Color kAccent = Color(0xFF4C8DFF);
const Color kError = Color(0xFFFF6B6B);
```
Import as `../theme/tokens.dart`. `test/theme_tokens_guard_test.dart` fails the build on any of these seven hex literals appearing outside `tokens.dart` (line comments exempt).

### Icons
**Source:** `lib/hub/hub_screen.dart:89, :97`; theme axis pin at `lib/theme/tokens.dart:60-65`
**Apply to:** bar icons, handle
```dart
import 'package:material_symbols_icons/symbols.dart';
Icon(Symbols.touch_app_rounded, size: 24, color: kMuted)
```
Always `const Symbols.<name>_rounded`. Never `Icons.`, never `Symbols.get()`. Axes (opsz 24 / wght 400 / FILL 0 / GRAD 0) are pinned app-wide by `buildAppTheme()`'s `iconTheme` — do not re-specify per call site.

### Connection state (value-equal, never `changes`)
**Source:** `lib/net/connection_providers.dart:85-106` + `lib/widgets/bubble_scaffold.dart:145-149`
**Apply to:** `SummonBar` / `SummonIconButton` only
```dart
final status = ref.watch(connectionStatusProvider);
final connected = status.chip == ChipStatus.connected;
```
`ConnectionStatus` implements `operator ==`/`hashCode` over `(chip, fsmState)`, which is what makes this rebuild-free on the trackpad hot path. Never subscribe to `ConnectionService.changes`, never a `Timer.periodic` (D-13-13, P9).

### Documentation
**Source:** `lib/widgets/bubble_scaffold.dart:1-32`, `lib/keyboard/key_pads.dart:127-142`
**Apply to:** every new file
A `///` library-level doc block ending in `library;` that names the decision IDs it implements, the pitfalls it avoids, and — for numeric constants — an explicit honesty note separating derived arithmetic from chosen design values. Every public field and constant carries a `///`.

### Copy constants
**Source:** `lib/hub/hub_screen.dart:348` (`kSettingsWithUpdateTooltip`, `kSettingsTitle`)
**Apply to:** `kSummonTrackpadLabel`, `kSummonKeyboardLabel`, `kSummonKeyboardBlockedLabel`, `kSummonHandleLabel`
Named `const String` in the file that renders it — no inline copy literals.

### Async fire-and-forget
**Source:** `lib/widgets/bubble_scaffold.dart:103, 108, 116`; `lib/hub/hub_screen.dart:283`
**Apply to:** every `controller.forward()/reverse()` and every `Navigator.push`
```dart
unawaited(_controller.forward());
```
(`import 'dart:async';` is what supplies `unawaited`.)

---

## No Analog Found

| File | Role | Data Flow | Reason |
|------|------|-----------|--------|
| `lib/shell/summon_scope.dart` | provider (`InheritedWidget`) | pub-sub | Zero `InheritedWidget` subclasses exist in `lib/` — Riverpod covers every existing case. Use 13-RESEARCH §3 verbatim |
| `lib/shell/summon_bar_suppressor.dart` (BAR-04) | middleware (route-scoped depth counter) | event-driven | No lifecycle-ordering depth counter exists in the tree; the closest reasoning is `key_pads.dart`'s pad-store gating, which is not the same shape. Use 13-RESEARCH §9 |

Predictive-back baseline capture has a *partial* analog only — the mock-method-channel setup at `test/haptics_gate_test.dart:17-32` (`TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, ...)` with a matching `tearDown` that nulls it). Reuse the harness; the `SystemNavigator.setFrameworkHandlesBack` assertion itself is new.

## Metadata

**Analog search scope:** `app/remote_control/lib/{widgets,hub,keyboard,trackpad,browser,screens,net,theme}`, `app/remote_control/test/`
**Files scanned:** ~14 read in full or in targeted ranges; `lib/` and `test/` inventoried by listing + grep
**Pattern extraction date:** 2026-08-14
