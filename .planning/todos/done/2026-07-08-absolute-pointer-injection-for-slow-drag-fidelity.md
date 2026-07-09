---
created: 2026-07-08T00:00:00Z
title: Absolute pointer injection so slow drags survive Windows pointer acceleration
area: server
files:
  - server/server-windows/src/input_thread.rs:67
---

## Problem

Discovered during the Phase-02 hard-gate run (02-04-GATE-RESULT.md): with Windows
"Enhance pointer precision" ENABLED (the OS default), slow/small finger drags
produce NO cursor movement while fast drags work. The server injects relative
motion (`enigo.move_mouse(ix, iy, Coordinate::Rel)` → `MOUSEEVENTF_MOVE`), and
Windows pointer ballistics scales small integer deltas toward zero at low speed.
The sub-pixel accumulator is NOT at fault — it correctly carries fractions; the
loss happens downstream at the OS ballistics curve.

Current workaround: owner disables "Enhance pointer precision" (Settings → Mouse
→ Pointer Options). The Phase-02 transport gate PASSED with this workaround
(p50 = 6ms / p95 = 10ms), so this is cursor-*feel* fidelity, not transport.

## Solution

Inject absolute motion instead of relative: GetCursorPos + accumulated delta →
normalized absolute SendInput (enigo `Coordinate::Abs`). Absolute injection
bypasses pointer ballistics entirely, giving true 1:1 tracking regardless of the
OS setting.

Watch the multi-monitor / virtual-desktop normalization edge case (absolute
coordinates are normalized to the virtual desktop, not the primary monitor).

Natural home: Phase 4 (Trackpad & Keyboard — "match a real laptop"), unless
picked up earlier as a quick task.
