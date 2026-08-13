# Feature Research

**Domain:** Phone-as-remote-control apps — the summon/dismiss interaction model for a persistent input surface raised in place
**Researched:** 2026-08-12
**Milestone:** v1.1 The Summon Bar
**Confidence:** MEDIUM overall (see Confidence Note)

> **Scope guard.** This file covers ONLY the summon/dismiss interaction model for the new bottom bar. Trackpad, keyboard, media, power, presenter, browser, apps, clipboard and updates are already built and are treated here as fixed dependencies, not as things to design.

---

## Confidence Note — read before quoting anything below

The confidence seam (`gsd-tools query classify-confidence`) floors every finding reached through `WebSearch`/`WebFetch` at **LOW**, regardless of how authoritative the page is. I have not overridden it. Instead every competitor claim carries an **Evidence** grade so the roadmapper knows which ones are firm:

| Evidence grade | Meaning |
|---|---|
| **vendor-doc** | I fetched the vendor's own documentation page and read the sentence. Treat as reliable. |
| **secondary** | A reputable third-party write-up or the vendor's store listing, summarised via search. Directionally reliable, exact UI wording not guaranteed. |
| **community** | Forum/community guide. Plausible, unverified against the shipping app. Do not build a decision on this alone. |

**Nothing in this file was checked against a running copy of any competitor app.** Where the roadmapper needs certainty about a competitor's exact behaviour, the cheap move is to install it — not to re-research it.

---

## 1. Prior Art — how the category actually exposes a trackpad and a keyboard

Classification vocabulary: **destination** (you navigate to it), **persistent bar** (always on screen), **overlay** (raised over live content, nothing beneath moves), **IME-style panel** (the OS keyboard, raised over the app).

| App | Pointing surface | Keyboard | Raises IN PLACE? | Evidence |
|---|---|---|---|---|
| **Remote Mouse** (the app being replaced) | The mouse pad **is** the home surface; specialty panels (media, web, app switcher, power) are reached from a persistent bottom toolbar | Keyboard icon, reported as the **4th icon in the bottom toolbar**; raises the app's own keyboard | Keyboard: yes, over the pad. Panels: swap the surface | secondary |
| **Unified Remote** | "Basic Input" is one **remote among many** — a destination screen | A separate **Keyboard remote** — another destination | **No.** Quick Switch (top-right icon) opens a menu to *jump to* a remote | vendor-doc (Quick Switch), secondary (rest) |
| **KDE Connect** (Android) | "Remote Input" is a **destination** picked from the paired device's plugin list | **Keyboard icon in the top-right of that screen** raises the phone IME over the touchpad | Keyboard: yes. Touchpad: no | secondary |
| **Chrome Remote Desktop** (Android) | The remote desktop **is** the whole surface; trackpad is the default *input mode* | Not documented in Google's help page. Session menu opens from an **Arrow at the screen edge** | Session menu is an overlay drawer; input mode is a setting, not a summon | vendor-doc (session menu), **unknown** (keyboard) |
| **Microsoft Remote Desktop / Windows App** (Android) | Remote desktop is the whole surface; mouse mode (Direct touch vs Mouse pointer) switched in a "session overview" screen | **Persistent, draggable "connection bar" at the top with a keyboard toggle** — "the ability to toggle between showing and hiding the on-screen keyboard" | **Keyboard: yes, pure in-place toggle.** Pointer: a mode, not a surface | vendor-doc |
| **Steam Link** (Android) | A touch **overlay** over the live stream with MOUSE / CONTROLLER / CONTROLLER+MOUSE modes; `[...]` button top-left | A **keyboard button placed on the overlay** toggles the phone keyboard. Community guidance: place it *above* where the keyboard will appear so the same button can be pressed again to hide it | **Yes — both.** Closest analogue found to what v1.1 wants | community |
| **Google TV app remote** | "Swipe control" (touchpad) or "D pad control" — chosen in **settings**, a mode not a summon | **No dedicated keyboard button**; the IME pops automatically when the TV focuses a text field | Keyboard: auto, in place | secondary |
| **Apple TV Remote** (iOS) | The touch surface **is** the remote screen / Control Center module | Keyboard raises automatically when the TV shows a text field (via notification); a keyboard icon in the Remote app raises it manually | Keyboard: yes, in place | vendor-doc (auto-raise), secondary (manual icon) |
| **Roku app** | "Remote" is a **bottom-tab destination** (D-pad icon) | **Keyboard icon at the bottom of the Remote screen** raises the phone's native keyboard | Keyboard: yes. Remote: a tab destination | vendor-doc |

### The two findings that matter

**Finding 1 — the keyboard half of this milestone has overwhelming prior art, and it all says the same thing.**
Eight of nine surveyed apps expose the keyboard as **a toggle icon that raises a keyboard in place over whatever is already on screen**. Zero make it a destination you navigate to. Microsoft, Roku, KDE Connect, Steam Link and Apple all converge on: persistent icon → IME rises → same icon (or system back) hides it. Users arrive at this app already trained. *This half is copyable and low-risk.*

**Finding 2 — the trackpad half has essentially no prior art, and that is the real content of v1.1.**
In every surveyed app the pointing surface is either **the entire screen** (remote-desktop clients, where there is nothing else to look at) or **a destination** (Unified Remote, KDE Connect, Roku). **No app in the set raises a trackpad as an overlay over another remote's screen.** The nearest thing is Steam Link's hybrid CONTROLLER+MOUSE overlay, and even that is a mode on a permanent overlay rather than a summoned surface.

The consequence for the roadmap is direct: **the trackpad-raised-in-place surface is the novel, risky half and should be built and dogfooded first.** If the summon vocabulary is going to fail, it will fail there, and it should fail on one surface rather than two.

**Corollary — Remote Mouse's failure mode is instructive.** User reviews of Remote Mouse complain that "since the upgrade and move of the switch panel and mouse to the bottom of the screen… the bottom half of the screen now has the panel and buttons," making the pad hard to use *(secondary)*. That is the direct cost of a bottom bar plus a raised surface competing for pad area. It is the exact 56px this milestone knowingly re-pays, and it is worth watching for in UAT.

---

## 2. Dismiss vocabulary, and the trackpad-gesture conflict

### 2a. The vocabulary users actually have

| Gesture | Where they learned it | Trained? | Conflicts with the raised trackpad? |
|---|---|---|---|
| Swipe down **anywhere on the surface** | Material modal bottom sheet default; Samsung Keyboard / some Gboard builds hide on a downward swipe | Strongly | **YES — fatally. See 2b.** |
| Swipe down **on a drag handle** | M3 `BottomSheetDragHandleView` (48dp min target, a11y-aware, tap-to-cycle + double-tap-to-hide) | Strongly | **No** — the handle is not part of the pad |
| **Tap outside / scrim** | Modal bottom sheets, dialogs | Strongly | No, but costs a scrim and has hub-specific problems |
| **Back button / back gesture** | Android system already dismisses the IME on back before navigating | Universally | **No** |
| **Tap the same icon again** | MS Windows App connection bar, Roku keyboard icon, Steam Link overlay keyboard button | Strongly | **No** — the icon is on the bar, not the surface |

**Which combinations coexist:** handle-drag + back + tap-same-icon coexist perfectly. None of the three touches the surface body, so there is nothing to arbitrate. Scrim-tap coexists mechanically but is rejected on other grounds (below). Swipe-down-on-body coexists with nothing.

### 2b. The conflict, stated precisely

The raised trackpad consumes, on its body:

- one-finger vertical drag → **cursor Y delta** (continuous, unbounded, no rest position, no extent)
- two-finger vertical drag → **scroll wheel**
- one-finger drag after double-tap-hold → **drag**

A **downward one-finger drag on the pad is the single most common thing a user does on that surface.** There is no signal available that separates it from a dismiss:

- **Velocity threshold?** A fast downward flick *is* a legitimate large cursor throw — the exact gesture the full-screen Trackpad screen exists to serve. Thresholding makes fast throws randomly dismiss the surface. Fails.
- **Must start at the top edge?** That is a drag handle with the handle not drawn: an invisible affordance that also steals pad area. Strictly worse than drawing it.
- **Overscroll handoff (the iOS sheet model)?** Structurally unavailable. That model works because the content *has* a scroll extent, so "you reached the top and kept pulling" is a real event. **A trackpad has no scroll extent and no top.** There is nothing to over-scroll. This is not a hard problem — it is an absent precondition.
- **Re-arbitrate mid-drag?** Flutter cannot. Per flutter/flutter#161687, a developer "can either give the nested scroll or the drag to dismiss gesture priority, but cannot switch back and forth between either animations on one drag event." The choice is made once, at the start.
- **Two fingers down = dismiss?** Already bound to scroll.

**And the deciding argument is specific to this product.** In a normal bottom sheet, an accidental dismiss is annoying but self-announcing: the user is looking at the sheet, sees it go, and re-opens it. **Here the user is looking at the laptop, not the phone.** A false dismiss fires *invisibly*. What the user perceives is "the cursor stopped moving" — mid-throw, mid-point-at-something. That is a materially worse failure than a missed dismiss, and it raises the acceptable false-positive rate to approximately zero. Ambient, inferred dismiss gestures cannot meet that bar. **Deliberate, located ones can.**

### 2c. Recommended resolution — this is the recommendation, not one option among several

**Three dismiss routes. All three live outside the surface body. Zero gesture arbitration ever happens inside the pad.**

1. **Tap the same bar icon again — the primary dismiss.**
   The bar stays pinned and visible at all times; **the raised surface's bottom edge sits on top of the bar and never under it.** The active icon carries a selected state while its surface is raised. This satisfies the one-gesture-dismiss requirement, costs zero pad area, is a 48dp target at the thumb-optimal bottom of the screen, and is verbatim the vocabulary Microsoft's connection bar, Roku's keyboard icon and Steam Link's overlay button all use. Crucially **summon and dismiss become the same motor action on the same pixel** — which is precisely what makes rapid sequential bouncing cheap, and cheap sequential bouncing is the entire justification for the overlay-not-resize decision.

2. **System back / back gesture — the free second route.**
   Back dismisses the raised surface *before* popping the route. Costs zero pixels, needs zero teaching, and matches what Android already does for the IME. Mechanics in §3.

3. **A 48dp drag handle strip at the top of the raised surface — the third route, and the one that carries discoverability.**
   It is **the only place on the surface where a downward drag means dismiss.** It matches `BottomSheetDragHandleView` (48dp minimum touch target; accessibility services can drive it; supports tap-to-toggle and double-tap-to-hide). Beyond dismiss, it is the visual signal that this thing *is* a raised, dismissable surface rather than a screen — without it, a raised trackpad reads as navigation, which would undo the milestone's premise.

**Explicitly excluded: swipe-down-to-dismiss anywhere on the surface body — on the trackpad AND on the keyboard.**
The keyboard could technically afford it. Ship it anyway and you teach a gesture that then silently does nothing on the trackpad, which is worse than never teaching it. Two surfaces raised by one bar must dismiss identically. **This is the single most important call in the milestone.**

**Falsifiable acceptance test — put this verbatim into the phase's success criteria:**

> With the trackpad surface raised, 30 consecutive full-height downward one-finger cursor throws starting at the top of the pad produce **zero** dismissals, and 30 consecutive two-finger downward scrolls produce zero dismissals.

Any design that cannot pass that test is the wrong design, and this test is cheap enough to run on hardware in two minutes.

**Complexity:** LOW–MEDIUM. The handle is a widget; the icon toggle is one boolean; back is a `PopScope`. The MEDIUM part is *proving* the pad never sees a dismiss path, which is a test-design task, not an implementation one.

---

## 3. Android system back and predictive back

### What is true in 2026

- Predictive back requires **Android 13 (API 33)** plus `android:enableOnBackInvokedCallback="true"` in the manifest; **Android 14 (API 34) enables predictive back animations by default** for system gestures where the app supports them. *(vendor-doc — docs.flutter.dev)*
- The Android system **already dismisses the IME on back before navigating**: "The Back button supports dismissing floating windows, contextual action bars, and hiding the onscreen keyboard (IME)." *(vendor-doc — developer.android.com)* Users are fully trained on "back closes the raised thing first."
- `WillPopScope` is gone. `PopScope` + `onPopInvokedWithResult` is the current API; `onPopInvoked` is deprecated. *(secondary, corroborated by api.flutter.dev)*

**Verdict: back-dismisses-the-surface-before-popping-the-route is TABLE STAKES, not a nicety.** Not doing it reads as a bug.

### The trap the plan must carry — this is a whole-app regression waiting to happen

The obvious implementation is to wrap every screen (the bar is on every screen) in `PopScope(canPop: false)` and handle back manually. **Do not.** The official Dart API docs for `PopScope.canPop` state:

> *"Android's predictive back feature will not animate when this boolean is false."*

Because the bar is on **every screen**, a static `canPop: false` would **disable predictive back across the entire app**, including on every screen where nothing is raised. That is a visible, whole-app downgrade introduced by a local convenience — exactly the kind of thing that ships and is never noticed until a user mentions it.

**Required shape:**

```
canPop: !isSurfaceRaised
```

- Nothing raised → `canPop: true` → the route pops with the full predictive animation intact.
- Something raised → `canPop: false` → back is intercepted and dismisses the surface. Losing the predictive *preview* here is correct: there is no route transition to preview.

### Two more mechanics to carry into planning

- **Multiple `PopScope`s in one route subtree AND together** — every `canPop` in the subtree must be `true` for the route to pop *(api.flutter.dev)*. A bar wrapper on every screen plus any pre-existing per-screen `PopScope` is a real interaction. **Audit for existing `PopScope`/`WillPopScope` usages before adding the bar's.**
- **Nested `Navigator` breaks predictive back** (flutter/flutter#139903, *community/issue-tracker*). This argues directly against implementing the bar by wrapping screens in a nested `Navigator`. **Use a root-level `Overlay`/`OverlayPortal` above the root Navigator instead.** That choice also happens to be what makes "nothing beneath resizes" free.

### One-back-one-effect

Back must dismiss the surface **or** pop the route, never both in one gesture. Trivially stated, easy to get wrong when the interception and the pop live in different widgets.

---

## 4. State restoration — and what "no visible jump" actually costs

### The perceptual thresholds, with sources

| Threshold | Value | What it governs | Source |
|---|---|---|---|
| Feels instantaneous / direct manipulation | **100 ms** | *Response to input* — how long until something starts happening after the tap | NN/g (vendor-doc) |
| Average visual perception latency | **~230 ms** | Why 200 ms animations are reliably *seen* as movement rather than as a cut | Model Human Processor, via valhead.com (secondary) |
| Comfortable UI animation upper bound | **~500 ms** | Beyond this, animation reads as waiting | secondary |

### The key distinction the requirement hinges on

**The 100 ms figure does not apply to the "no visible jump" requirement, and treating it as if it does is the mistake to avoid.**

- 100 ms governs **response to input**: tap → something begins. The incumbent 200 ms `kBubbleExpandDuration` is defensible against this — it sits right in the perceivable-as-motion band, and dropping much below ~150 ms starts reading as a *pop* or glitch rather than a movement. **Recommendation: keep 200 ms for summon, and consider a slightly faster dismiss (~150 ms) — dismissals want to feel like getting out of the way, not like a transition.**
- "No visible jump" is a completely different problem: it is **change detection on already-painted content**. A large surface whose contents hop after first paint is perceptible far below 100 ms. **The practical budget is zero frames — ~16.7 ms at 60 Hz, ~8 ms at 120 Hz.**

### Therefore: the answer to OQ-A1 sub-question 2 is a design constraint, not a measurement

The design note flags that the docked panel "seeds its landing pad from the persisted value with a one-shot restore jump that covers the async prefs load." **Do not measure whether that hop is visible. It is visible when the read is cold and invisible when it is warm** — which means it will pass hardware UAT (warm) and fail in real use (first summon after launch). Measurement is the wrong tool for a race.

**Recommendation: hoist the prefs read out of the summon path entirely.** Read pad state once at app start / first mount into a synchronous provider; the summon path reads an in-memory value and lays out correctly on frame one. This converts "no visible jump" from a latency hope into a structural guarantee, and it also answers OQ-A1 sub-question 4 — there is then no first-summon-per-screen cost distinct from subsequent summons, because the expensive part happened before either.

### What users notice when restoration is imperfect — ordered by real cost

1. **The surface comes back on the wrong keyboard pad.** *Highest cost, and it is not cosmetic.* The user has already begun the motor program for the key they wanted. Landing on a different pad sends **a wrong keystroke to whatever has focus on the PC**. That is a destructive error in someone else's application. This is the argument that pad restoration is table stakes rather than polish.
2. **A locked modifier survives the dismiss** (landmine #1). Worse under a summon model than the note states: an invisible locked Ctrl now persists *across a gap in which there is no chip on screen to reveal or clear it*, so anything typed by any means in that gap is silently modified.
3. **The surface appears and then hops.** Cosmetic, but at dozens of summons per session it is the thing that makes the whole model feel cheap.
4. **Scroll position or non-keyboard sub-state resets.** Low cost; users do not track it.

### Recommendation — restore layout, reset input state

**Restore:** which surface was raised, which keyboard pad was showing, surface height/geometry.
**Reset:** all held and locked modifiers — release them on the PC and show the surface clean.

This settles OQ-A1 sub-question 3 and landmine #1 with one rule, and the two halves do not fight: *layout* is what "quick" means to the user, *input state* is what "safe" means, and **nobody expects a modifier to survive a dismiss they performed deliberately.** Restoring a locked Ctrl would be restoring a hazard.

---

## 5. The two-icon affordance

### Get the component vocabulary right first

- **M3 navigation bar:** 3–5 destinations, top-level only. A two-item bar is *below* that minimum — which is good, because it means it should not be styled as one. **These are actions, not destinations.** The whole milestone is about the trackpad and keyboard *ceasing* to be destinations; styling the bar as navigation would reassert the thing being removed. *(secondary)*
- **M3 bottom app bar:** up to four actions — but **deprecated in M3 Expressive**, replaced by the **docked toolbar**, which "spans the full width of the window and is best used for global actions that remain the same across multiple pages." *(secondary)* That sentence is a verbatim description of this bar.
- M3 also advises not pairing a toolbar with a navigation bar. This app has a hub, not a nav bar, so there is no conflict — worth remembering if one is ever added.

**Recommendation: build it as a docked toolbar of two icon actions. Do not build it as, or style it as, a navigation bar.**

### The alternatives, and what each costs

| Option | Discoverability | Why rejected / accepted |
|---|---|---|
| **Two icon actions in a docked toolbar** | **Best.** Both surfaces one tap, both visible, active state legible, tap-active-to-dismiss reads naturally | **ACCEPT** |
| Segmented control (2 segments) | Good | Wrong semantics twice: it implies *mutually exclusive selection*, but "neither raised" is a legal and common state (there is no valid default segment), and there is no "off" affordance so tap-to-dismiss reads as broken. **REJECT** |
| FAB cluster / speed dial | Medium | Adds a tap before **every** summon — a direct tax on the interaction the milestone exists to make cheap. Also floats over and occludes content, which is exactly the bubble being retired, minus the fix. **REJECT** |
| Single icon + long-press alternate | **Worst.** Long-press is invisible and this app has no onboarding | Makes one of the two surfaces strictly more expensive than the other, and puts a 400–500 ms hold timer in front of an action whose entire value is being instant. **REJECT** |

**Cost of discoverability, ranked (lower is better):** two icons < FAB cluster ≈ segmented < long-press alternate. Two icons wins on the axis that matters, and it is the only option that keeps summon and dismiss on the same pixel.

---

## Feature Landscape

### Table Stakes (Users Expect These)

| Feature | Why Expected | Complexity | Depends on (existing) |
|---|---|---|---|
| Keyboard raises in place from a persistent toggle icon | 8 of 9 surveyed apps do exactly this; users arrive trained | MEDIUM | `KeyboardInputController` (quick `260809-ipc`) |
| Tap the same icon again to dismiss | Same eight apps; it is *the* toggle vocabulary in this category | LOW | bar state |
| Bar stays visible and tappable while a surface is raised (surface sits **on top of** the bar, never under) | Otherwise the primary dismiss is occluded; Steam Link's guide calls this out explicitly | LOW | overlay layout |
| Back / back gesture dismisses the raised surface **before** popping the route | Android already does this for the IME; not doing it reads as a bug | LOW | dynamic `canPop` |
| Predictive back still works when nothing is raised | Default-on from Android 14; regressing it is a whole-app downgrade | **MEDIUM** (it is a trap, not a task — see §3) | root `Overlay`, not nested `Navigator` |
| 48dp drag handle on the raised surface | M3 `BottomSheetDragHandleView` minimum; it is both the a11y-supported drag route and the signal the surface is dismissable | LOW | — |
| Restore which keyboard pad was showing, on frame one | Wrong pad = wrong keystroke into a PC app. Destructive, not cosmetic | MEDIUM (must be synchronous) | pad persistence in `keyboard_panel.dart` |
| Release all held/locked modifiers on dismiss | Landmine #1; dismiss becomes the most frequent gesture in the app | MEDIUM | `KeyboardInputController` |
| `ModifierChip` row fits at 360dp | Known 7.3px overflow; a third narrow mount makes it visible again | LOW | the pinning test that must start **failing** |
| Surfaces do not resize, scroll or push anything beneath | The stated contract; the whole design rests on it | LOW (free if root Overlay) | — |
| Summon and dismiss animate at a stated, measured budget | "Quickly" is unverifiable otherwise (OQ-A1) | LOW | — |

### Differentiators (Competitive Advantage)

| Feature | Value Proposition | Complexity | Notes |
|---|---|---|---|
| **Trackpad raised as an overlay over another remote's screen** | **No surveyed app does this.** Every competitor makes the pointing surface either the whole screen or a destination. This is the actual novel claim of v1.1 | **MEDIUM–HIGH** | Carries all the gesture risk. Build and dogfood first |
| One bar summons **both** surfaces with an identical dismiss vocabulary | Competitors summon the keyboard in place but leave the pointer as a mode or a destination. One vocabulary for both is the differentiator | MEDIUM | Requires the §2c discipline to hold on both |
| Zero-frame state restore (synchronous, no post-paint hop) | Competitors mostly hand off to the OS IME, which restores itself for free. A custom surface has to earn this, and most don't | MEDIUM | Structural, not a tuning exercise |
| Active-state icon showing which surface is raised | Small, but it is what makes tap-to-dismiss legible rather than a guess | LOW | — |
| Summon/dismiss latency as a written, measured success criterion | Turns OQ-A1 from an argument into a number | LOW | Owner judgement still closes the phase |
| Bar reaches the **hub** too | Design-note assumption #4. No surveyed competitor puts input access on its home/hub surface — Roku, Unified Remote and KDE Connect all require you to enter a remote first | LOW | Flagged as an assumption; if a planner excludes the hub, this is what it contradicts |

### Anti-Features (Commonly Requested, Often Problematic)

| Anti-Feature | Why Requested | Why Problematic | Instead |
|---|---|---|---|
| **Resize/inset contract — pushing content up above the raised surface** | It is what the Android IME does, so it looks like the "correct" pattern | Nothing on the phone is the input target, so there is no field to keep visible. Costs: every tool screen must become scrollable, a **fourth** inset context appears, and landmine #2's raw-window-metrics clamp gains another consumer. Already decided against — this row exists so a planner does not re-derive it | Overlay. Nothing beneath moves |
| **Swipe-down-anywhere-on-the-surface to dismiss** | Material bottom sheet default; Samsung/Gboard keyboard gesture | Ambiguous by construction against cursor drag and two-finger scroll; the iOS overscroll-handoff resolution is *structurally unavailable* (a trackpad has no scroll extent); Flutter cannot re-arbitrate mid-drag (#161687); and false dismisses fire while the user is looking at the laptop, so they are **invisible** | Drag handle only. Never the body. Same rule on the keyboard, for consistency |
| **Scrim behind the raised surface** | Makes it feel modal; free tap-outside dismiss | The bar reaches the hub, where "outside" is tiles — a tap there is ambiguous. The raised trackpad leaves little outside to tap, and what remains is a thumb-hostile top reach. A scrim also asserts "the content beneath is disabled," a claim this design has no need to make | No scrim. Elevation + shadow only |
| **Filling the bar's dead width with more actions** (media, power, clipboard…) | The bar is on every screen and looks mostly empty | Turns the summon bar into a second hub — duplicating the hub. Breaks the two-icons-one-vocabulary story and pushes toward navigation-bar semantics (3–5 destinations) that contradict the milestone's premise | Exactly two icons. Ship it looking empty |
| **Keeping the bubble as a fallback or a settings toggle** | Zero-risk migration; "let the user choose" | Two affordances doing one job — the exact call phase 08 made when it deleted the quick-bar. Also doubles the surfaces that can hold a trackpad, doubling the state-restore and modifier-leak surface area | Delete `TrackpadBubble`, `FloatingTrackpadWindow`, `windowPositionProvider` outright |
| **Multi-height raised surface (peek + expanded)** | Bottom sheets do it; more pad area is better | Adds a *second* meaning to vertical drag on a surface that cannot afford a first one, and multiplies the state to restore | One height per surface. The full-screen Trackpad tile already **is** the "more area" answer, which is why it survives |
| **Static `PopScope(canPop: false)` in the bar wrapper** | Simplest way to intercept back | Disables predictive back on every screen the bar is on — i.e. all of them | `canPop: !isRaised` |
| **Implementing the bar by wrapping screens in a nested `Navigator`** | Natural way to keep the bar outside route transitions | Nested `Navigator` is a known predictive-back breaker (flutter/flutter#139903) | Root-level `Overlay`/`OverlayPortal` above the root Navigator |
| **Auto-dismiss on inactivity, disconnect, or screen change** | "Tidiness"; frees the screen | Same invisible-failure class as accidental swipe dismiss — the user is looking at the laptop. On reconnect the user wants the surface exactly where it was, not gone | Never auto-dismiss. Mute or disable the surface, don't remove it |
| **Long-press / double-tap alternates on the bar icons** | Free extra capability at zero pixel cost | Invisible, and this app has no onboarding. Puts a hold timer in front of the only two actions the milestone exists to make instant | Single tap only |
| **Hide-on-scroll for the bar** | M3 docked toolbars support it; reclaims the 56px | The bar's entire value is being *unconditionally* present. A bar that hides is the old quick-bar's navigate-away flaw in a new costume | Always visible. The 56px was accepted knowingly (D8-06 reversal) |
| **Haptic or sound on dismiss** | Feedback is good | The app already uses haptics for *clicks and keys* — i.e. for things that happen on the PC. A haptic for a phone-local UI event muddies that signal | Visual only for summon/dismiss |

---

## Feature Dependencies

```
Summon bar (docked toolbar, 2 icon actions, every screen incl. hub)
    └──requires──> root-level Overlay above the root Navigator   [NOT a nested Navigator]
    └──requires──> dynamic canPop (!isRaised)                    [preserves predictive back]
    └──requires──> layout: raised surface bottom == bar top      [keeps the primary dismiss reachable]
    └──requires──> audit of existing PopScope/WillPopScope usages [multiple PopScopes AND together]

Raised keyboard surface  (third mount point)
    └──requires──> KeyboardInputController                    [EXISTING — quick 260809-ipc]
    └──requires──> hidden IME input mounted in BOTH states,
                   OUTSIDE the animating chrome               [landmine #3]
    └──requires──> pad-height clamp re-derived for a 3rd inset context  [landmine #2 — re-derive, do not copy]
    └──requires──> synchronous pad restore  ──replaces──>  async prefs seed  [OQ-A1 #2 / #4]
    └──requires──> modifier release on dismiss                [landmine #1]
    └──requires──> ModifierChip 360dp overflow fix            [landmine #4]

Raised trackpad surface
    └──requires──> existing trackpad gesture stack            [EXISTING — Phase 4 + pinch zoom]
    └──requires──> 48dp drag handle (the ONLY dismiss drag target)
    └──CONFLICTS──> swipe-down-on-body dismiss                [NEVER SHIP — see §2b]

Bubble retirement
    └──requires──> showBubble flag semantics re-read, not mechanically ported  [landmine #5]
    └──requires──> test migration: bubble_scaffold_test.dart,
                   floating_trackpad_window_test.dart

Hub tile reorder (both tiles move to end of kHubTiles)
    └──independent of everything above
```

### Dependency Notes

- **Root `Overlay` is load-bearing twice.** It is what makes "nothing beneath resizes" free, *and* it is what avoids the nested-`Navigator` predictive-back breakage. One structural choice retires two risks.
- **Synchronous pad restore replaces the async seed — it does not sit alongside it.** Keeping the one-shot restore jump "as a fallback" reintroduces the exact hop being eliminated.
- **The `ModifierChip` overflow test inverts.** It currently drains overflow deliberately and asserts the drain count is non-zero. **That test failing is the success signal**, not a flake. Say so in the plan or someone will "fix" it back.
- **Landmine #2 says re-derive, not reuse.** The pad-height clamp reads raw window metrics precisely because its ancestor `MediaQuery` had insets stripped. A bar-hosted overlay is a third inset context; copying the arithmetic will produce a plausible-looking wrong number.
- **Trackpad surface before keyboard surface.** The trackpad half is the one with no prior art and all the gesture risk. Proving the dismiss vocabulary there first means a failure costs one surface, not two.

---

## MVP Definition

### Launch With (v1.1)

- [ ] **Docked toolbar, two icon actions, every screen including the hub** — the affordance the milestone is named for
- [ ] **Root-level overlay host with dynamic `canPop`** — the chassis; retires the predictive-back trap and the resize temptation in one move
- [ ] **Trackpad raised in place, dismiss via icon / back / handle only** — the novel half; carries the risk
- [ ] **Keyboard raised in place as a third mount point** — the copyable half; inherits the same vocabulary verbatim
- [ ] **Synchronous pad restore (zero-frame)** — the hard requirement, made structural
- [ ] **Modifier release on dismiss** — landmine #1; safety, not polish
- [ ] **`ModifierChip` fits at 360dp on both keyboard surfaces** — landmine #4
- [ ] **Bubble deleted outright** (`TrackpadBubble`, `FloatingTrackpadWindow`, `windowPositionProvider`) + test migration
- [ ] **Both hub tiles moved to the end of `kHubTiles`** — neither deleted
- [ ] **Measured summon/dismiss budget written as a success criterion** — closes OQ-A1

### Add After Validation (v1.2)

- [ ] **Delete the Keyboard hub tile** — trigger: the bar has been lived with for a week and the full Keyboard screen is demonstrably only buying height. The design note explicitly defers this; do not pull it forward
- [ ] **Remember the last-raised surface across app launches** — trigger: the owner reports re-summoning the same surface as the first act of every session
- [ ] **Landscape-specific surface geometry** — trigger: any real landscape use appears

### Future Consideration (v2+)

- [ ] **A third bar icon** — only if a specific remote proves to be needed *while* pointing, sequentially. Defer hard: it breaks the two-icon story and edges toward navigation-bar semantics
- [ ] **User-reorderable / user-chosen bar icons** — defer: personal-use app, one user, zero demand
- [ ] **Swipe left/right on the bar to switch the raised surface** — defer: a second gesture vocabulary on a bar whose value is that it has exactly one

---

## Feature Prioritization Matrix

| Feature | User Value | Implementation Cost | Priority |
|---|---|---|---|
| Docked toolbar, two icons, every screen | HIGH | LOW | **P1** |
| Root overlay host + dynamic `canPop` | HIGH (invisible, but everything rests on it) | MEDIUM | **P1** |
| Trackpad raised in place | HIGH | MEDIUM | **P1** |
| Keyboard raised in place (3rd mount) | HIGH | MEDIUM | **P1** |
| Tap-same-icon-to-dismiss | HIGH | LOW | **P1** |
| Back dismisses surface before popping | HIGH | LOW | **P1** |
| 48dp drag handle | MEDIUM (discoverability + a11y) | LOW | **P1** |
| Synchronous pad restore | HIGH (wrong pad = wrong keystroke) | MEDIUM | **P1** |
| Modifier release on dismiss | HIGH (safety) | MEDIUM | **P1** |
| `ModifierChip` 360dp fix | MEDIUM | LOW | **P1** |
| Bubble deletion + test migration | MEDIUM (removes a second affordance) | MEDIUM | **P1** |
| Hub tile reorder | LOW | LOW | **P1** (trivial, do last) |
| Active-state icon | MEDIUM | LOW | **P1** |
| Measured animation budget | MEDIUM | LOW | **P1** |
| Remember last-raised surface across launches | LOW | LOW | P2 |
| Delete the Keyboard hub tile | LOW | LOW | P2 (deliberately deferred) |
| Landscape geometry | LOW | MEDIUM | P3 |
| Third bar icon | LOW | MEDIUM | P3 (anti-feature-adjacent) |

---

## Competitor Feature Analysis

| Aspect | Microsoft Windows App (Android) | Roku app | Steam Link | KDE Connect | **Our Approach** |
|---|---|---|---|---|---|
| Keyboard access | Toggle on a persistent, draggable top connection bar | Keyboard icon at the bottom of the Remote screen | Keyboard button placed on the touch overlay | Keyboard icon top-right of Remote Input | **Icon in a persistent bottom docked toolbar, on every screen** |
| Keyboard raises in place? | Yes | Yes | Yes | Yes | **Yes** |
| Pointing surface | The whole session; mouse mode is a setting | Not offered | Overlay mode over the live stream | A destination screen | **Raised overlay on any screen — no prior art** |
| Dismiss the keyboard | Same toggle | Same icon (+ system back) | Same button, positioned to stay uncovered | System back | **Same icon (primary) + back + drag handle** |
| Bar persists across screens? | In-session only | No — "Remote" is a tab destination | Overlay only, during streaming | No | **Yes — every screen, hub included** |
| Content beneath resizes? | No | No | No | No | **No** |

**Nobody in the category resizes content for a raised input surface.** The overlay-not-resize decision is not a deviation from the norm — it *is* the norm. The IME's resize behaviour is the outlier, and it is an outlier for a reason that does not apply here.

---

## Open Questions the Roadmapper Should Carry

1. **Does the app already declare `android:enableOnBackInvokedCallback="true"`?** If not, predictive back was never on, and "don't regress it" becomes "turn it on and verify it" — a different, slightly larger task. Cheap to check; check before planning.
2. **How many existing `PopScope`/`WillPopScope` usages are there?** They AND with the bar's. An audit is a 5-minute grep and prevents a confusing bug.
3. **Where exactly does the raised surface's top edge land?** The full-screen Trackpad screen must remain meaningfully *more* precise than the raised one, or the tile-survival rationale evaporates.
4. **The hub assumption (design-note #4) is still an assumption.** No surveyed competitor puts input access on its home surface. That is weak evidence against, and it is worth one deliberate on-device check rather than a silent adoption.

---

## Sources

**Vendor documentation (read directly):**
- [Use features of the Remote Desktop client for Android and Chrome OS — Microsoft Learn](https://learn.microsoft.com/en-us/previous-versions/remote-desktop-client/client-features-android-chrome-os) — connection bar, keyboard toggle, session overview, mouse modes
- [Add the predictive-back gesture — Flutter](https://docs.flutter.dev/platform-integration/android/predictive-back) — Android 13/14 requirements, `enableOnBackInvokedCallback`
- [PopScope class — Flutter API](https://api.flutter.dev/flutter/widgets/PopScope-class.html) and [PopScope.canPop](https://api.flutter.dev/flutter/widgets/PopScope/canPop.html) — "predictive back … will not animate when this boolean is false"; multiple PopScopes AND together
- [Android predictive back — Flutter breaking changes](https://docs.flutter.dev/release/breaking-changes/android-predictive-back)
- [Navigation with Back and Up — Android Developers](https://stuff.mit.edu/afs/sipb/project/android/docs/design/patterns/navigation.html) — Back dismisses the IME before navigating
- [Handle input method visibility — Android Developers](https://developer.android.com/develop/ui/views/touch-and-input/keyboard-input/visibility)
- [BottomSheetDragHandleView — Android Developers](https://developer.android.com/reference/com/google/android/material/bottomsheet/BottomSheetDragHandleView) — 48dp min, a11y services, tap-to-cycle, double-tap-to-hide
- [Bottom sheets — Material Design 3](https://m3.material.io/components/bottom-sheets/guidelines) and [accessibility](https://m3.material.io/components/bottom-sheets/accessibility)
- [Navigation bar — Material Design 3](https://m3.material.io/components/navigation-bar/guidelines) — 3–5 destinations
- [Response Time Limits — Nielsen Norman Group](https://www.nngroup.com/articles/response-times-3-important-limits/) — the 0.1 s instantaneous limit
- [How to use the Roku mobile app to control your Roku — Roku Support](https://support.roku.com/article/roku-remote-on-your-phone)
- [Use your iPhone or iPad as a keyboard on Apple TV — Apple Support](https://support.apple.com/guide/tv/atvb827791d6/tvos)
- [How To Use Quick Switch — Unified Remote](https://www.unifiedremote.com/tutorials/how-to-use-quick-switch)
- [Set up Chrome Remote Desktop — Google Support (Android)](https://support.google.com/chrome/answer/1649523?co=GENIE.Platform%3DAndroid) — edge Arrow / session menu / Configure touch input

**Secondary and community (directionally reliable, not verified against the shipping app):**
- [How to Use Remote Mouse to Control Your Computer With Your Phone — TechPP](https://techpp.com/2022/09/14/remote-mouse-guide/) — bottom toolbar, keyboard as 4th icon *(403 on direct fetch; summarised via search)*
- [Remote Mouse — Google Play listing](https://play.google.com/store/apps/details?id=com.hungrybolo.remotemouseandroid) — specialty panels, reorderable panels
- [Steam Link Touch Controller Guide — Steam Community](https://steamcommunity.com/sharedfiles/filedetails/?id=1888830141) — `[...]` menu, MOUSE/CONTROLLER modes, keyboard button placement advice *(fetch returned Steam chrome only; summarised via search — treat as community)*
- [How to Use Your Android Phone as a PC Remote With KDE Connect — MakeUseOf](https://www.makeuseof.com/kde-connect-use-android-as-pc-remote/) and [KDEConnect — KDE UserBase](https://userbase.kde.org/KDEConnect)
- [Google TV app adds a remote control for your Android TV — XDA](https://www.xda-developers.com/google-tv-app-adds-remote-control-android-tv/) — swipe control vs D-pad, no dedicated keyboard button
- [How fast should your UI animations be? — Val Head](https://valhead.com/2016/05/05/how-fast-should-your-ui-animations-be/) — Model Human Processor ~230 ms, 200 ms / 500 ms bounds
- [flutter/flutter#161687](https://github.com/flutter/flutter/issues/161687) — cannot switch drag priority mid-gesture
- [flutter/flutter#139903](https://github.com/flutter/flutter/issues/139903) — nested Navigator breaks predictive back
- [Floating toolbars in Material 3 Expressive — 9to5Google](https://9to5google.com/2025/05/18/material-3-expressive-toolbars/) — docked toolbar replaces the deprecated bottom app bar

**Project sources:**
- `.planning/notes/summon-bar-trackpad-keyboard.md` — the design decision and its five landmines
- `.planning/PROJECT.md` — milestone scope, D8-05/D8-06/D-10 reversals
- `.planning/research/questions.md` — OQ-A1 (§4 answers sub-questions 1–4)

---
*Feature research for: summon/dismiss interaction model, v1.1 The Summon Bar*
*Researched: 2026-08-12*
