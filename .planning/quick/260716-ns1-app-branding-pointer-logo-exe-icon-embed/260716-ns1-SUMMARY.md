---
phase: quick-260716-ns1-app-branding
plan: 01
subsystem: branding
tags: [icons, winresource, tray, android-launcher, pillow]
requires: []
provides:
  - "tools/gen_icons.py — deterministic generator for all brand assets (locked Concept A geometry)"
  - "server-windows.exe with embedded pointer-logo icon + VERSIONINFO"
  - "Android launcher pointer-logo tile at all 5 densities"
  - "Tray brand-arrow glyph with per-state tinting (Normal/Paused/Warning)"
affects: [server-windows shell, android launcher]
tech-stack:
  added: [winresource 0.1.31 (build-dep only)]
  patterns: ["white tint-mask PNG + runtime RGB replace keeping source alpha"]
key-files:
  created:
    - tools/gen_icons.py
    - server/server-windows/build.rs
    - server/server-windows/assets/icon/icon.ico
    - server/server-windows/assets/icon/icon_{16,24,32,48,64,128,256}.png
    - server/server-windows/assets/icon/tray_arrow_32.png
  modified:
    - server/server-windows/Cargo.toml
    - server/Cargo.lock
    - server/server-windows/src/shell/tray.rs
    - app/remote_control/android/app/src/main/res/mipmap-{mdpi,hdpi,xhdpi,xxhdpi,xxxhdpi}/ic_launcher.png
decisions:
  - "png 0.18 Decoder needs BufRead + Seek: Cursor over the static bytes; output_buffer_size() returns Option<usize> in 0.18 (both Rule-3 inline fixes vs the plan's 0.17-era snippet)"
  - "tray.rs committed normally — orchestrator correction: Phase-10 shell redesign was already committed at 876beb4, plan's dirty-tree restriction was stale"
metrics:
  duration: ~11min
  completed: 2026-07-16
---

# Quick Task 260716-ns1: App Branding — Pointer Logo, Exe Icon Embed Summary

Deterministic Pillow generator draws the locked Concept A pointer mark and feeds every surface: winresource-embedded exe icon + VERSIONINFO, 5-density Android launcher, and a state-tinted tray arrow.

## Tasks Completed

| Task | Name | Commit | Files |
| ---- | ---- | ------ | ----- |
| 1 | Icon generator script + all assets | ff499da | tools/gen_icons.py, assets/icon/* (9), 5 mipmap PNGs |
| 2 | winresource build.rs exe embed | fa7bfb4 | build.rs, Cargo.toml, Cargo.lock |
| 3 | Tray glyph swap (states preserved) | 1279415 | src/shell/tray.rs |

## What Was Built

- **`tools/gen_icons.py`** (Python 3.12 + Pillow 12.2): renders the locked geometry (140-unit REF tile, #0E0F12 fill, #2A303C border w3 r28, arrow polygon `(48,36)...(100,85)` in #3B82F6) at 4x supersample with LANCZOS downscale. Emits 7 tile PNGs, a 7-frame `icon.ico` (each frame rendered independently — no auto-downscale blur), the white `tray_arrow_32.png` tint mask (arrow at 82% canvas height, centered), and the 5 Android launcher PNGs (48/72/96/144/192). Self-asserts size/mode on every output. **Determinism proven**: two runs, sha256 of `icon.ico` (`3f0b01fa...70cda`) and `tray_arrow_32.png` (`7b7ce408...8ed4`) byte-identical.
- **`build.rs`**: winresource embed gated on `CARGO_CFG_TARGET_OS == "windows"` (target, not host — cross-compile safe; server-core untouched). `set_icon(assets/icon/icon.ico)` + ProductName/FileDescription "Remote Control". Verified on the built exe: `VersionInfo.FileDescription == "Remote Control"`, FileVersion 0.1.0 (auto from CARGO_PKG_VERSION).
- **Tray**: `solid_circle_icon` deleted; `tinted_arrow_pixels(rgb)` (pure, unit-tested) decodes the embedded mask with the in-tree `png` crate and replaces RGB per state while keeping source alpha (smooth antialiased silhouette). `TrayState`, `icon_for`'s color match (#38BDF8/#6B7280/#FF6B6B), `set_tooltip` count-only privacy (T-07-20), and all public methods unchanged.

## Plan-Mandated Records

- **(a) winresource version resolved:** 0.1.31 (Cargo.lock). Legitimacy check passed at execution time: crates.io `winresource` exists, not yanked, `repository = github.com/BenjaminRi/winresource` (maintained winres fork), 2.65M downloads / 928K recent.
- **(b) tray.rs commit status:** COMMITTED at 1279415 — NOT left uncommitted as the plan text said. The plan's "dirty Phase-10 WIP, do not stage tray.rs" restriction was stale: the orchestrator's dispatch correction confirmed the Phase-10 shell redesign landed at 876beb4 (verified ancestor of HEAD, working tree clean at start). Staging tray.rs was safe and correct.
- **(c) fresh-APK reminder:** any later on-device launcher-icon check MUST run `flutter build apk --release` first — `flutter install` alone reuses stale APKs (08-06 lesson). A fresh release APK (65.9MB) was built during this task, so the current `build/app/outputs/flutter-apk/app-release.apk` already carries the new tile.

## Verification Results

1. `python tools/gen_icons.py` — exit 0 both runs, self-asserts pass, byte-identical hashes.
2. `cargo build --release -p server-windows` — green (twice: post-build.rs, post-tray-edit); `VersionInfo.FileDescription` == "Remote Control".
3. `cargo test --workspace` — green (99+7+22+38 passed, incl. new `tinted_arrow_pixels_tints_rgb_and_keeps_alpha`).
4. `flutter test` — 454 green (plan said 454; matches). `flutter build apk --release` — exit 0.
5. Git: exactly 5 mipmap PNGs modified pre-commit; no file deletions across the 3 commits; working tree clean after.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] png 0.18 Decoder API drift from plan snippet**
- **Found during:** Task 3
- **Issue:** Plan's `png::Decoder::new(&TRAY_ARROW_PNG[..])` is the 0.17-era API; png 0.18 requires `BufRead + Seek` on the reader, and `output_buffer_size()` now returns `Option<usize>`.
- **Fix:** `Decoder::new(std::io::Cursor::new(TRAY_ARROW_PNG))`; `.expect` on the buffer size.
- **Files modified:** server/server-windows/src/shell/tray.rs
- **Commit:** 1279415

### Plan Corrections Applied (orchestrator-directed)

**2. [Correction] tray.rs staged and committed normally**
- Plan forbade staging `src/shell/*.rs` claiming uncommitted Phase-10 WIP; verified stale (876beb4 in HEAD ancestry, clean tree). Task-3 commit contains ONLY tray.rs — no unrelated shell files existed to leak.

**3. [Correction] Commit granularity**
- Plan's Task 3 described one combined scoped commit; executed as three atomic per-task commits per executor protocol. The plan's "include `.planning/quick/...` in the commit" instruction was overridden by the dispatch constraints (PLAN/SUMMARY/STATE not committed).

## Known Stubs

None — all assets wired end-to-end (exe resource, launcher mipmaps, tray runtime tint).

## Threat Flags

None beyond the plan's register. T-Q-SC mitigation executed (crates.io check passed); T-Q-01 held by construction (tooltip logic untouched, unit-visible in diff).

## Self-Check: PASSED

- tools/gen_icons.py — FOUND
- server/server-windows/assets/icon/icon.ico — FOUND
- server/server-windows/assets/icon/tray_arrow_32.png — FOUND
- server/server-windows/build.rs — FOUND
- Commits ff499da, fa7bfb4, 1279415 — FOUND in git log
