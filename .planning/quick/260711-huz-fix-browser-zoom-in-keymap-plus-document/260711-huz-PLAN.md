---
quick_id: 260711-huz
type: quick
autonomous: true
files_modified:
  - server/server-windows/src/executors/keymap.rs
  - .planning/STATE.md
requirements: [BROW-01, SC5, SC4]
must_haves:
  truths:
    - "Ctrl+Plus (browser zoom-in) fires instead of being dropped by enigo"
    - "keymap.rs resolves the wire code \"Plus\" to '=' (unshifted), not '+'"
    - "The Google Slides F5-vs-Ctrl+F5 presenter gap is recorded as a known limitation"
  artifacts:
    - path: "server/server-windows/src/executors/keymap.rs"
      provides: "Layout-safe zoom-in mapping (Plus -> Key::Unicode('='))"
      contains: "Key::Unicode('=')"
    - path: ".planning/STATE.md"
      provides: "Known-limitation note for the presenter start-show F5 on web slides"
  key_links:
    - from: "server-core/src/dispatch/router.rs browser_macro (zoomin => Plus, Ctrl)"
      to: "keymap.rs map_key(\"Plus\")"
      via: "key_tap"
      pattern: "\"Plus\" => Key::Unicode\\('='\\)"
---

<objective>
Fix the browser zoom-in chord so Ctrl+Plus actually fires, and record the
Google Slides presenter F5 gap as a known limitation.

Root cause (already diagnosed — do NOT re-investigate): `keymap.rs` maps the
wire code `"Plus"` to `Key::Unicode('+')`. On a US layout '+' is Shift+'=';
enigo's Windows path calls `VkKeyScanW('+')` = 0x01BB (443 dec), whose high
byte 0x01 flags "shift required". enigo feeds the whole 443 into its scancode
lookup, gets 0, logs `The result for the input 443 is zero ... no mapping`,
and DROPS the keystroke — so Ctrl+Plus never reaches the browser. Zoom-out via
'-' (0xBD, unshifted) works, which is why only zoom-in is broken.

Fix: map `"Plus"` to `Key::Unicode('=')`. Ctrl+'=' is the universal browser
zoom-in chord (Chrome/Edge/Firefox) and '=' is unshifted, so enigo resolves it
cleanly. This is the Pitfall 11 fallback documented in 05-RESEARCH. The wire
code string stays `"Plus"` (router.rs `browser_macro` is UNCHANGED; its tests
stay green) — ONLY the server-windows resolution changes.

Second item (doc-only, no code): the presenter "start show" macro sends F5.
F5 starts the slideshow in the PowerPoint desktop app (works — the locked SC4
target) but reloads the page in a web browser (Google Slides; its present
shortcut is Ctrl+F5). Web Google Slides is out of scope — record this as a
known limitation, not a bug.

Purpose: Close the Phase 05 UAT zoom-in gap (SC5 / BROW-01) and log the SC4
web-slides boundary durably.
Output: 1 code edit + 1 comment fix in keymap.rs; 1 known-limitation note in
STATE.md.
</objective>

<context>
@.planning/STATE.md
@server/server-windows/src/executors/keymap.rs
@server/server-core/src/dispatch/router.rs
</context>

<tasks>

<task type="auto">
  <name>Task 1: Map "Plus" to '=' for layout-safe zoom-in + fix the stale comment</name>
  <files>server/server-windows/src/executors/keymap.rs</files>
  <action>
In `map_key` change the `"Plus"` arm (currently line ~139)
`"Plus" => Key::Unicode('+'),` to `"Plus" => Key::Unicode('='),`. Leave the
adjacent `"Minus" => Key::Unicode('-'),` arm untouched — unshifted '-' already
resolves. Do NOT touch `CLIENT_KEY_CODES`, `ROUTER_MACRO_CODES` (the wire
string stays `"Plus"`), or any test — `router_macro_codes_covered` still passes
because `"Plus"` still maps to `Some`.

Then fix the now-inaccurate explanatory comment above the browser-macro arms
(the block near line ~126-128 that ends "...so Ctrl+T / Ctrl+W / Ctrl+Plus
chord correctly"). Rewrite that trailing sentence in directive prose so it no
longer claims Ctrl+Plus works: state that Ctrl+T / Ctrl+W chord correctly via
VkKeyScanW, but the wire code `"Plus"` deliberately resolves to '=' (unshifted),
NOT '+', because on a US layout '+' is Shift+'=' and enigo's
`VkKeyScanW('+')` = 0x01BB shift-flag path yields a zero scancode and drops the
tap (RESEARCH Pitfall 11); Ctrl+'=' is the universal browser zoom-in chord
(Chrome/Edge/Firefox). Keep it comment prose — no code fences.
  </action>
  <verify>
    <automated>cargo test --manifest-path server/Cargo.toml --workspace</automated>
  </verify>
  <done>
`grep -n "\"Plus\" => Key::Unicode('=')" server/server-windows/src/executors/keymap.rs`
returns the arm; no remaining `Key::Unicode('+')` in the file; the comment above
the browser-macro arms no longer says "Ctrl+Plus chord correctly" and explains
the '=' resolution; `cargo test --workspace` is green (including
`router_macro_codes_covered`, `keymap_covers_all_codes`, and router
`browser_macro_table_maps_every_action`, which are unchanged). Physical
zoom-in behavior remains an on-device manual check (Phase 05 SC5/BROW-01).
  </done>
</task>

<task type="auto">
  <name>Task 2: Record the Google Slides presenter F5 known limitation</name>
  <files>.planning/STATE.md</files>
  <action>
Append a new entry to the `### Blockers/Concerns` list in STATE.md, matching
the existing bullet style (a `[Phase 05 — KNOWN LIMITATION]` prefix). State:
the presenter "start show" macro sends F5, which starts the slideshow in the
PowerPoint desktop app (the locked SC4 target — works) but reloads the page in
a web browser; Google Slides' present shortcut is Ctrl+F5, so starting a show
from web Google Slides is out of scope for v1. Note this is a known limitation,
not a bug, and that PowerPoint desktop is the supported presenter surface. Do
NOT change any code, tests, or the `present_macro` table in router.rs — this is
documentation only.
  </action>
  <verify>
    <automated>grep -n "Google Slides" .planning/STATE.md</automated>
  </verify>
  <done>
A new `Blockers/Concerns` bullet in STATE.md records the F5-vs-Ctrl+F5
PowerPoint-desktop-vs-web-Google-Slides limitation, flagged as a known
limitation (not a bug) with PowerPoint desktop named as the SC4 target. No
source files changed by this task.
  </done>
</task>

</tasks>

<verification>
- `cargo test --manifest-path server/Cargo.toml --workspace` passes (server-core
  router tests + server-windows keymap coverage tests all green).
- keymap.rs `"Plus"` arm resolves to `Key::Unicode('=')`; router.rs is byte-for-byte
  unchanged.
- STATE.md carries the presenter web-slides known-limitation note.
</verification>

<success_criteria>
- Ctrl+Plus zoom-in no longer dropped by enigo (layout-safe '=' resolution) —
  final confirmation is the on-device Phase 05 SC5/BROW-01 manual gesture.
- Workspace tests stay green; no wire-contract or router changes.
- The Google Slides F5 limitation is durably recorded.
</success_criteria>

<output>
Update `.planning/STATE.md` Quick Tasks Completed table when this quick task lands
(handled by the quick workflow). No SUMMARY file required for a quick task.
</output>
