# Feature Research

**Domain:** Phone-as-remote-input apps (wireless mouse/keyboard/control-center for PCs)
**Researched:** 2026-07-07
**Confidence:** MEDIUM-HIGH (competitor feature sets verified against official sites/store listings; input-feel details verified against libinput documentation and community bug trackers; some UX judgments synthesized from user reviews)

Competitors surveyed: Remote Mouse (the app this project replaces), Unified Remote, KDE Connect. Intel Unison / Microsoft Phone Link are a different product class (phone-to-PC mirroring/notifications, not PC input) and are excluded.

## Feature Landscape

### Table Stakes (Users Expect These)

Every serious product in this class ships these. Missing any = product feels broken relative to the free tier of any competitor.

| Feature | Why Expected | Complexity | Notes |
|---------|--------------|------------|-------|
| Relative trackpad (move, L/M/R click, tap-to-click, 2-finger scroll, drag) | Core value; all three competitors have it | HIGH | High complexity is in the *feel*, not the plumbing — see Behavior Details below |
| Full keyboard text entry via system IME | All competitors; users expect their swipe/autocomplete keyboard to work | MEDIUM | Incremental send-as-you-type; must handle IME word-commits, backspace, enter (KDE Connect's most notorious bug class) |
| Special keys: modifiers, F1–F12, Esc, Tab, arrows/nav | Android IME lacks these; users hit the wall within minutes (KDE Connect bug 391083; Remote Mouse paywalls Ctrl/Esc) | LOW | Sticky modifier chips are the standard pattern |
| Media keys + volume | Present in all competitors' free or near-free tier | LOW | Absolute volume slider is above-baseline (see Differentiators) |
| LAN auto-discovery | Unified Remote "automatic server detection", Remote Mouse, KDE Connect all have it; manual IP entry alone reads as amateur | MEDIUM | UDP beacon per spec; show IP to disambiguate duplicate names |
| Authenticated pairing | Remote Mouse's *lack* of default auth produced the "Mouse Trap" CVEs (CVE-2021-27572/27573, unauthenticated RCE); Unified Remote offers password+encryption; KDE Connect uses certificate pairing | MEDIUM | PIN + hashed token per spec clears the bar |
| Silent reconnect for remembered devices | Users treat re-pairing as failure; Remote Mouse reviews cite connection friction as a top complaint | MEDIUM | Backoff + beacon re-listen per spec; must survive PC sleep and phone WiFi doze |
| Presentation remote | In all three competitors (Unified Remote "presentations" remote, KDE Connect slideshow control) | LOW | Key macros (F5/arrows/B/Esc) |
| Server tray app with pause + autostart | Standard server form factor for this class | MEDIUM | "Pause input" is the trust feature — user must be able to kill remote input instantly from the PC |
| Connection status + latency visibility | Users blame the app for WiFi problems; status ambiguity drives 1-star reviews | LOW | Header status + ping RTT per spec |
| Haptic feedback on clicks/keys | Phones give no physical feedback; without haptics taps feel dead | LOW | Toggleable per spec |

### Table Stakes — Behavior Details Within the Fixed v1 Features

The v1 feature list is fixed; this is what separates "feels like a real trackpad" from "feels like a cheap toy" *inside* those features. These should become explicit requirements — competitors that skip them are exactly the ones reviewers call "laggy" and "jumpy."

**Trackpad feel (the make-or-break area):**

| Behavior | Expectation | Why It Matters | Complexity |
|----------|-------------|----------------|------------|
| Pointer acceleration curve | Finger *velocity* maps non-linearly to cursor velocity: slow finger → fine precision, fast flick → cross-screen | A flat linear gain is the #1 "cheap" tell — either too slow to cross the screen or too twitchy to hit a button. libinput/Windows both apply velocity-based transfer functions ("pointer ballistics") for exactly this reason | MEDIUM |
| Sub-pixel delta accumulation | Server accumulates fractional f32 deltas instead of truncating per-frame | Truncation makes slow precise movement stall (dead-zone) then jump; protocol's f32 deltas only help if the injector keeps remainders | LOW |
| Send every motion sample, flush immediately | Read Android MotionEvent batched/historical samples; one binary frame per sample batch at input rate; **TCP_NODELAY on both sides** | Nagle + delayed-ACK can add up to ~200ms of batching — this alone reproduces Remote Mouse's "jumpy, overshooting cursor" complaints | LOW (but easy to forget) |
| Tap vs move discrimination | Tap = touch down→up within a timeout AND under a movement threshold; otherwise it's a move | Without both gates, micro-drags fire phantom clicks and quick repositions get eaten (libinput tap state machine) | MEDIUM |
| Two-finger tap grace period | Fingers never land simultaneously; allow a short window to count fingers before classifying tap | Otherwise 2-finger tap randomly fires left-click instead of right-click | MEDIUM |
| Drag continuation at screen edge | Long-press drag must survive the finger hitting the phone-screen edge: drag lock (lift + replace within timeout keeps button held) or explicit release | Phone screens are small; every long drag hits the edge. libinput ships drag-lock for this exact problem | MEDIUM |
| Scroll momentum with instant stop | Flick → kinetic scroll with exponential decay; any new touch immediately halts it | Momentum without touch-stop feels out of control; no momentum feels stiff. Decay per-axis, then combine | MEDIUM |
| Scroll axis intent locking | Mostly-vertical two-finger motion locks to vertical scroll | Unlocked diagonal scroll wobbles horizontally in documents — a classic cheap-feel tell | LOW |
| Separate scroll vs pointer sensitivity + natural-scroll toggle | Users' scroll-direction expectations are split ~50/50; one shared gain never satisfies both gestures | Spec already has direction toggle; add independent scroll gain | LOW |
| Never queue mouse frames across a blip | Drop, don't buffer (already in spec) | Buffered deltas replay as cursor teleport on reconnect | LOW |

**Keyboard feel:**

| Behavior | Expectation | Why It Matters | Complexity |
|----------|-------------|----------------|------------|
| IME-commit-friendly text protocol | Accept characters *or* whole committed words; handle IME "delete word / recompose" (backspace counts) | KDE Connect/GSConnect's broken backspace+enter via IME is their single most-reported input bug | MEDIUM |
| Autorepeat on held on-screen keys | Holding Backspace/arrows/Del on the toggleable rows repeats: initial delay (~500ms) then repeat rate, implemented as server-side key-down/hold/key-up — not client-synthesized tap spam | Without repeat, deleting a sentence means 40 taps; tap-spam repeat trips Windows sticky-keys detection (documented aRDP/VNC failure mode) | MEDIUM |
| Key action model: tap vs down/up | Protocol `action: tap` plus down/up for modifiers and held keys | Needed for autorepeat, sticky modifiers, and games/shortcuts that read key state | LOW (protocol already leans this way) |
| Sticky modifiers with visible state + auto-reset | Chip shows latched state; one-shot by default; reset on disconnect (in spec) and on screen leave | A silently-latched Ctrl turns the next tap into a destructive shortcut | LOW |
| Instant local echo of intent | Haptic tick + visual key-press state at touch time, not at server ack | Perceived latency is dominated by feedback latency, not network latency | LOW |

**Connection feel:**

| Behavior | Expectation | Why It Matters | Complexity |
|----------|-------------|----------------|------------|
| Reconnect without user action, with honest status | "Reconnecting…" state, backoff, beacon re-listen for IP changes (in spec) | Remote Mouse's connect failures are its top review complaint; silent hangs are worse than visible reconnects | MEDIUM |
| Fast connect on app resume | Phone doze/backgrounding kills sockets; re-auth on resume must be sub-second | Users open the app for a 2-second volume tweak; a 5s connect ruins the product's core value | MEDIUM |
| Absolute volume slider reflects PC state | Server pushes current volume on connect and on external change; slider never "jumps" when first touched | An absolute control without state feedback stutters between phone and PC values | LOW (needs a `media.changed`-style push — small protocol addition) |

### Differentiators (Competitive Advantage)

| Feature | Value Proposition | Complexity | Notes |
|---------|-------------------|------------|-------|
| Everything free, no ads, no account | Remote Mouse paywalls media/web/BT/Ctrl+Esc and shows ads; Unified Remote free tier is limited. "All features, free" is the project's stated reason to exist | — | Structural, not a feature to build |
| Absolute volume slider (Core Audio) | Competitors mostly do relative volup/voldown; direct-set slider is a visibly nicer interaction | LOW | Depends on state push (above) |
| App launcher/switcher (running windows + pinned favorites) | None of the three competitors list/focus/close arbitrary windows from the phone; Unified Remote needs per-app remotes | MEDIUM | EnumWindows edge cases (UWP ghost windows, elevated apps) — expect pitfall research |
| Clipboard with manual send/fetch + history + opt-in auto-sync | KDE Connect only auto-syncs (privacy complaints spawned a fork that removed it); manual-first with last-5 history is a better default | MEDIUM | Auto-sync OFF by default is the differentiating stance |
| Security done credibly (PIN + hashed tokens, LAN-only, confirmed power actions) | Remote Mouse shipped 6 unpatched CVEs incl. unauthenticated RCE and never responded to disclosure; "not a security liability" is a real differentiator in this category | MEDIUM | Also: no HTTP update channel (CVE-2021-27574 was MITM-able updates) |
| Modern dark-minimal UI, latency readout | Remote Mouse's dated UI is an explicit owner complaint; pro-tool aesthetic | LOW | Locked by mockups |
| Protocol-first, versioned, schema-validated | Enables iOS/Linux/macOS later; none of the closed competitors offer this | MEDIUM | Already core to the spec |

### Anti-Features (Commonly Requested, Often Problematic)

| Feature | Why Requested | Why Problematic | Alternative |
|---------|---------------|-----------------|-------------|
| Custom in-app keyboard (replacing system IME) | "Full control over keys" — Remote Mouse's approach | Loses swipe typing, autocomplete, user's language/layout; huge surface to build; still worse than the IME users chose | System IME for text + toggleable special-key rows (spec's approach) |
| Absolute phone-screen→PC-screen cursor mapping | "Point where you want" intuition | Phone/PC aspect mismatch, fat-finger precision impossible, feels like a broken touchscreen | Relative deltas + acceleration curve |
| Gyro/air mouse | Marquee feature in Remote Mouse listings | Drift, calibration, hand-tremor noise; novelty that goes unused; owner doesn't need it | Deferred (already out of scope); consider gyro *presenter laser pointer* (KDE Connect's version) as a v2 nice-to-have |
| Bluetooth/USB fallback transport | "Works without WiFi" | Doubles transport code and failure modes; Remote Mouse uses fake WiFi-problem nags to upsell its BT mode — a dark pattern to avoid, not copy | WiFi-only, honest connection status (spec decision) |
| Cloud relay / internet control | "Control PC from anywhere" | Account infrastructure, relay costs, massive security exposure for an input-injection protocol | LAN-only binding, stated as a security posture |
| Extensible per-app remote plugins (Unified Remote's 90+ remotes) | Long-tail app control | Content treadmill; most are thin key-macro wrappers; plugin systems in input servers are attack surface | Generic keyboard/media/browser macros cover the same ground |
| File transfer / file manager | Adjacent "connect phone to PC" expectation | Different data path (large payloads vs 9-byte frames), storage permissions, resume logic — scope explosion | Out of scope v1; clipboard covers text/URLs |
| Always-on clipboard auto-sync (default ON) | "Seamless" | Sends passwords/2FA codes to another device silently; documented KDE Connect user revolt | Opt-in toggle, manual send/fetch primary (spec's approach) |
| Screen mirroring / remote desktop view | "See what I'm controlling" | Entirely different product (video encoding, latency budget, permissions); Unified Remote ships it paid and it's mediocre | None — user is in front of the PC by definition |
| Voice input passthrough | Remote Mouse markets it | It's just the IME's mic button once you use the system IME | Free via system IME |
| Wake-on-LAN | Unified Remote has it; genuinely handy | Not problematic, just premature: NIC/BIOS config support burden disproportionate for v1 personal use | v1.x candidate — tiny protocol addition (magic packet from phone while server offline) |

## Feature Dependencies

```
Discovery (UDP beacon)
    └──requires──> nothing (server-side broadcast)
Pairing (PIN → token)
    └──requires──> Discovery
Connection/auth session
    └──requires──> Pairing
ALL input features ──require──> Connection/auth session

Trackpad drag ──requires──> tap state machine (tap/move discrimination)
Trackpad feel ──requires──> binary frame hot path + TCP_NODELAY + server delta accumulation
Scroll momentum ──requires──> client-side flick velocity tracking (client-only; server just receives deltas)

Keyboard special rows ──requires──> key down/up protocol actions
Autorepeat ──requires──> key down/up protocol actions (server-side hold)
Sticky modifiers ──requires──> key down/up + connection-state reset hook
Presenter, Browser ──require──> keyboard key/macro executor (thin layers; near-zero marginal cost)

Absolute volume slider ──requires──> server→client media state push (volume on connect + change echo)
Apps screen ──requires──> server→client push (apps.changed)
Clipboard auto-sync ──requires──> server clipboard polling + clip.changed push
Clipboard history ──enhances──> manual send/fetch (client-side ring buffer)

Power actions ──require──> confirm round-trip (protocol) + slide-to-confirm (UI) — build together

Reconnect UX ──conflicts──> input queueing (mouse frames must drop, not queue)
Custom in-app keyboard ──conflicts──> IME send-as-you-type (pick one; spec picked IME)
```

### Dependency Notes

- **Presenter/Browser depend on Keyboard executor:** both are key-combo macros (F5/arrows/B; Ctrl+T/W/Tab etc.). Sequencing keyboard first makes these two nearly free — strong argument for phase ordering.
- **Push-capable protocol before Apps/Clipboard/Volume-state:** three features need unsolicited server→client messages. Land the push pattern once, early, rather than retrofitting.
- **Tap state machine before drag:** drag (tap-and-hold, drag lock, edge continuation) is states bolted onto tap detection; building drag first forces a rewrite.
- **Key down/up model before autorepeat and sticky modifiers:** if v1 protocol only had `tap`, both would require a protocol rev.

## MVP Definition

### Launch With (v1)

The v1 feature set is already fixed by the design spec; this maps it to validation priority.

- [ ] Discovery + PIN pairing + silent reconnect — everything depends on it; also where the security differentiation lives
- [ ] Trackpad with full feel checklist (acceleration, tap discrimination, drag lock, momentum, NODELAY) — the product is judged on this screen alone
- [ ] Keyboard (IME text + special rows + sticky mods + autorepeat) — the second most-used screen; KDE Connect's failure here is the cautionary tale
- [ ] Media + absolute volume with state push — the "walk to the couch" use case
- [ ] Power (slide-to-confirm), Presenter, Browser — thin macro layers, high perceived completeness per unit effort
- [ ] Apps launcher/switcher — the only genuinely novel v1 feature vs competitors
- [ ] Clipboard (manual + history, auto-sync opt-in) — differentiating default posture
- [ ] Server tray: pause input, revoke device, autostart, firewall self-test — trust features

### Add After Validation (v1.x)

- [ ] Wake-on-LAN — trigger: owner starts wishing the PC were on before walking to it; trivially small protocol addition
- [ ] UDP channel for mouse deltas — trigger: measured real-world jitter on owner's WiFi (spec explicitly reserves this)
- [ ] Gyro laser pointer in Presenter — trigger: real presentation use; KDE Connect proves the interaction
- [ ] Per-device trackpad profiles (sensitivity per PC) — trigger: second paired machine

### Future Consideration (v2+)

- [ ] iOS client, Linux/macOS servers — gated on Android+Windows proven (per PROJECT.md)
- [ ] File/URL share — only with public release; scope-heavy
- [ ] Home-screen widgets / Quick Settings tile (media, pause) — public-release polish
- [ ] Installer, Play Store, crash reporting — public-release gate items

## Feature Prioritization Matrix

| Feature | User Value | Implementation Cost | Priority |
|---------|------------|---------------------|----------|
| Trackpad feel package (accel, tap SM, drag lock, momentum, NODELAY) | HIGH | HIGH | P1 |
| Discovery/pairing/reconnect | HIGH | MEDIUM | P1 |
| Keyboard (IME + special keys + autorepeat + sticky mods) | HIGH | MEDIUM | P1 |
| Media + absolute volume w/ state push | HIGH | LOW | P1 |
| Server tray (pause, revoke, autostart) | HIGH | MEDIUM | P1 |
| Presenter + Browser macros | MEDIUM | LOW | P1 (cheap once keyboard exists) |
| Power w/ confirm | MEDIUM | LOW | P1 |
| Apps launcher/switcher | MEDIUM | MEDIUM | P2 (novel but not daily-critical; Win32 enumeration edge cases) |
| Clipboard manual + history | MEDIUM | LOW | P2 |
| Clipboard auto-sync | LOW | MEDIUM | P2 (polling + push; opt-in) |
| Wake-on-LAN | MEDIUM | LOW | P3 |
| Gyro presenter pointer | LOW | MEDIUM | P3 |

## Competitor Feature Analysis

| Feature | Remote Mouse | Unified Remote | KDE Connect | Our Approach |
|---------|--------------|----------------|-------------|--------------|
| Trackpad | Free; reviews cite jumpy/laggy cursor | Free tier; multi-touch | Free; basic feel | Full feel checklist; <30ms budget; NODELAY |
| Keyboard | System IME; Ctrl/Esc behind paywall | Free basic keyboard | IME-based; chronic backspace/enter bugs | IME + special rows + autorepeat, all free |
| Media/volume | Paywalled package | Free basic; more remotes paid | MPRIS control, free | Free; absolute Core Audio slider |
| App control | Paywalled "app switcher" | Per-app remote plugins (mostly paid) | None | Generic window list + favorites, free |
| Clipboard | No | No (file manager instead, paid) | Auto-sync (privacy complaints → fork) | Manual-first + history; auto-sync opt-in |
| Presenter | Paywalled in bundle | Dedicated remote | Free + gyro pointer | Free key macros; gyro pointer v2 |
| Pairing/security | Optional password; shipped 6 unpatched CVEs (unauth RCE) | Password + encryption | TLS + certificate pairing | PIN + SHA-256 tokens, LAN-only, confirmed power |
| Discovery | Auto + manual IP | Auto server detection | mDNS-style auto | UDP beacon + GUID disambiguation |
| Monetization | Ads + 3 separate IAP packs + subscription keys | Freemium, one-time Pro | Free OSS | Free, no ads, no account |
| Transport | WiFi free, BT paywalled (with dark-pattern nags) | WiFi + BT | WiFi (TLS) | WiFi-only, honest status |

## Sources

- [Remote Mouse official site](https://www.remotemouse.net/), [Google Play listing](https://play.google.com/store/apps/details?id=com.hungrybolo.remotemouseandroid) — feature set, free/paid split (HIGH confidence for features, MEDIUM for paywall boundaries which shift over time)
- [Remote Mouse reviews (justuseapp)](https://justuseapp.com/en/app/385894596/remote-mouse/reviews), [Setapp review roundup](https://setapp.com/apps/remote-mouse/customer-reviews) — lag/jumpy-cursor, ads, IAP-fragmentation, BT-nag complaints (MEDIUM)
- [Mouse Trap disclosure — Axel Persinger](https://axelp.io/MouseTrap), [CVE list](https://www.cvedetails.com/vulnerability-list/vendor_id-24559/Remotemouse.html), [MouseTrap exploit suite](https://github.com/CuckooEXE/MouseTrap) — CVE-2021-27569/27572/27573/27574, ignored 90-day disclosure (HIGH)
- [Unified Remote features](https://www.unifiedremote.com/features), [WOL tutorial](https://www.unifiedremote.com/tutorials/how-to-configure-wake-on-lan-on-windows), [Power remote](https://www.unifiedremote.com/remotes/power) — 90+ remotes, WOL, encryption (HIGH)
- [KDE Connect UserBase wiki](https://userbase.kde.org/KDEConnect), [Wikipedia](https://en.wikipedia.org/wiki/KDE_Connect), [XDA on gyro pointer](https://www.xda-developers.com/kde-connect-does-something-between-phone-pc-even-apple-hasnt-figured-out/) — feature set, presenter gyro pointer (HIGH)
- [GSConnect issue #1831](https://github.com/GSConnect/gnome-shell-extension-gsconnect/issues/1831), [KDE bug 466644](https://www.mail-archive.com/kde-bugs-dist@kde.org/msg786848.html), [KDE bug 391083](https://kde-bugs-dist.kde.narkive.com/tgcwf7QI/kdeconnect-bug-391083-new-allow-user-to-press-keys-that-aren-t-on-android-keyboard), [clipboard-privacy fork](https://github.com/fabian-thomas/kdeconnect) — IME backspace/enter failures, missing special keys, auto-sync privacy revolt (MEDIUM-HIGH)
- [libinput tap-to-click docs](https://wayland.freedesktop.org/libinput/doc/latest/tapping.html), [libinput pointer acceleration docs](https://wayland.freedesktop.org/libinput/doc/latest/pointer-acceleration.html) — tap state machine, drag lock modes, velocity-based acceleration profiles (HIGH; authoritative reference implementation)
- [Marc Brooker: "It's always TCP_NODELAY"](https://brooker.co.za/blog/2024/05/09/nagle.html), [Nagle's algorithm — Wikipedia](https://en.wikipedia.org/wiki/Nagle's_algorithm) — Nagle+delayed-ACK up-to-200ms stalls on small-packet interactive traffic (HIGH)
- [Ariya Hidayat: flick list momentum scrolling](https://ariya.io/2011/10/flick-list-with-its-momentum-scrolling-and-deceleration) — exponential-decay kinetic scroll, per-axis decomposition (MEDIUM)
- [aRDP key-repeat thread](https://groups.google.com/g/bvnc-ardp-aspice-opaque-remote-desktop-clients/c/xoETRCX_tc0), [RH bug 450033 (VNC autorepeat)](https://bugzilla.redhat.com/show_bug.cgi?id=450033) — tap-spam vs held-key autorepeat failure modes in remote input (MEDIUM)

---
*Feature research for: phone-as-remote-input apps*
*Researched: 2026-07-07*
