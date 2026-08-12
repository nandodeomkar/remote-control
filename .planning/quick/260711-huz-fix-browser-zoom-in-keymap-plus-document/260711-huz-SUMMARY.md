---
status: complete
quick_id: 260711-huz
type: quick
completed: 2026-07-11
requirements: [BROW-01, SC5, SC4]
files_modified:
  - server/server-windows/src/executors/keymap.rs
  - .planning/STATE.md
commits:
  - b27f617: fix(260711-huz) map wire code "Plus" to '=' for layout-safe zoom-in
---

# Quick Task 260711-huz: Fix Browser Zoom-In Keymap + Document Slides F5 Gap Summary

Mapped the wire code `"Plus"` to `Key::Unicode('=')` (unshifted) so enigo stops dropping the Ctrl+Plus browser zoom-in chord, and recorded the Google Slides F5 presenter gap as a durable known limitation.

## What Was Done

### Task 1 — Layout-safe zoom-in mapping (code)
- `server/server-windows/src/executors/keymap.rs`: the `"Plus"` arm now resolves to `Key::Unicode('=')` instead of `Key::Unicode('+')`.
- Root cause (pre-diagnosed): on a US layout `'+'` is Shift+`'='`; enigo's Windows path calls `VkKeyScanW('+') = 0x01BB`, whose high byte flags "shift required", yields a zero scancode, and DROPS the keystroke — so Ctrl+Plus never reached the browser. Zoom-out via `'-'` (unshifted) already worked, which is why only zoom-in was broken.
- Ctrl+`'='` is the universal browser zoom-in chord (Chrome/Edge/Firefox) and `'='` is unshifted, so enigo resolves it cleanly (RESEARCH Pitfall 11 fallback).
- The stale comment above the browser-macro arms was rewritten: it no longer claims "Ctrl+Plus chord correctly" and now explains the deliberate `'='` resolution.
- Wire contract untouched: `CLIENT_KEY_CODES`, `ROUTER_MACRO_CODES` (the wire string stays `"Plus"`), and `router.rs` `browser_macro` are byte-for-byte unchanged.
- Committed atomically as `b27f617`.

### Task 2 — Known-limitation note (docs)
- `.planning/STATE.md` Blockers/Concerns list gained a `[Phase 05 — KNOWN LIMITATION]` bullet: the presenter "start show" macro sends F5, which starts the slideshow in PowerPoint desktop (the locked SC4 target — works) but reloads the page in a web browser. Google Slides' present shortcut is Ctrl+F5, so starting a show from web Google Slides is out of scope for v1 — a known limitation, not a bug, with PowerPoint desktop named as the supported presenter surface.
- Documentation only; no code, tests, or the `present_macro` table changed. (Committed by the orchestrator with the other docs artifacts.)

## Verification

- `cargo test --manifest-path server/Cargo.toml --workspace` — GREEN. Keymap coverage tests (`keymap_covers_all_codes`, `media_key_codes_covered`, `router_macro_codes_covered`, `unknown_code_maps_none`) and the server-core router tests all pass.
- `grep "Key::Unicode('+')" keymap.rs` — no remaining `'+'` mapping.
- `grep "Google Slides" .planning/STATE.md` — the limitation note is present.
- Physical zoom-in behavior remains an on-device manual check (Phase 05 SC5 / BROW-01).

## Deviations from Plan

None — plan executed exactly as written.

## Self-Check: PASSED

- FOUND: server/server-windows/src/executors/keymap.rs (`"Plus" => Key::Unicode('=')`)
- FOUND: .planning/STATE.md (Google Slides known-limitation bullet)
- FOUND: commit b27f617
