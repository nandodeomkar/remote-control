---
phase: quick-260731-euq
plan: 01
status: complete
subsystem: protocol + server-input + trackpad-gestures
tags: [pinch, zoom, binary-opcode, protocol-1.7, gesture-arbitration, ctrl-wheel]
requires: [phase-01, phase-02, phase-04]
provides:
  - "Binary opcode 0x03 (zoom) — same 9-byte frame, dy carries the delta, dx reserved"
  - "MouseKeys::zoom — new trait method, implemented by the mock and the enigo executor"
  - "Cmd::Zoom + its own SubPixelAccumulator + the Ctrl-held wheel tick on the input thread"
  - "ZoomIntent + _Phase.pinching + the spread-vs-translation arbitration that locks per episode"
  - "ConnectionService.sendZoom — the third volatile binary class"
  - "protoVersion 1.6 -> 1.7"
affects:
  - protocol contract (SPEC section 2/9/11, mouse-binary.md, 2 new golden fixtures)
  - both codecs (Rust server-core, Dart remote_protocol)
  - server-core executor trait + router; server-windows input thread
  - the shared TrackpadCore gesture stack — both surfaces, zero surface-specific code
tech-stack:
  added: []
  patterns:
    - "One arbitration at the slop crossing that LOCKS for the episode, rather than per-event reclassification — a gesture that can flip mid-contact feels broken even when each individual decision is right"
    - "Press-and-release a modifier INSIDE a single arm of a single-threaded executor loop, instead of holding it across a gesture and owing a release to session teardown"
    - "A reserved wire field is carried through the codec unchanged (so round-trips stay byte-exact) and dropped at the executor — reserving is a codec concern, ignoring is an executor concern"
    - "When adding a variant to a Rust enum consumed by exhaustive matches, the compile break defines the commit boundary — the contract and its consumers are one atomic unit whether the plan says so or not"
key-files:
  created:
    - protocol/fixtures/mouse-binary/07-zoom-in.json
    - protocol/fixtures/mouse-binary/08-zoom-out.json
  modified:
    - protocol/SPEC.md
    - protocol/schema/mouse-binary.md
    - protocol/fixtures/beacon/01-valid.json
    - server/server-core/src/codec/binary.rs
    - server/server-core/src/dispatch/router.rs
    - server/server-core/src/executors/mod.rs
    - server/server-core/src/executors/mock.rs
    - server/server-core/src/transport/session.rs
    - server/server-core/tests/fixtures.rs
    - server/server-windows/src/executors/mouse_keys.rs
    - server/server-windows/src/input_thread.rs
    - app/packages/remote_protocol/lib/src/binary_codec.dart
    - app/packages/remote_protocol/test/fixture_test.dart
    - app/remote_control/lib/trackpad/tuning.dart
    - app/remote_control/lib/trackpad/gesture_classifier.dart
    - app/remote_control/lib/trackpad/trackpad_driver.dart
    - app/remote_control/lib/trackpad/move_sender.dart
    - app/remote_control/lib/trackpad/trackpad_core.dart
    - app/remote_control/lib/net/connection_service.dart
    - app/remote_control/test/trackpad/gesture_classifier_test.dart
    - app/remote_control/test/trackpad/trackpad_driver_test.dart
    - app/remote_control/test/trackpad/trackpad_core_test.dart
    - app/remote_control/test/scroll_direction_test.dart
  deleted: []
decisions:
  - "The plan's 3-commit split (contract / server / client) collapsed to 2. Adding MouseFrame::Zoom breaks the exhaustive match in route_binary at compile time, so a contract-only commit does not build — the codec and its consumers are inseparable. Discovered at execution, not planning"
  - "protocol/fixtures/beacon/01-valid.json also moved 1.6 -> 1.7: the beacon payload embeds SERVER_PROTO_VERSION, so its encoder test is coupled to the constant. The plan did not anticipate this"
  - "Zoom is NOT gated by the D-11 scrollReversed seam — Natural/Reversed is a scroll preference and pinch-apart-is-zoom-in is invariant. Pinned by a driver test"
  - "A pinch goes quiet when one finger lifts, deliberately asymmetric with WR-04's full-rate single-finger scroll — one finger cannot define a separation"
  - "Zoom seeds no fling: _flingFrom is never consulted from any pinch path and _samples is never touched"
  - "kPinchMinSpreadPx is a defensive floor with no reachable test — see Findings"
  - "remote_protocol's stale protoVersion = '1.1' left unfixed — out of scope, see Findings"
  - "REQUIREMENTS.md untouched — no PAD requirement covers pinch zoom and minting one is a requirements change, not a quick task"
metrics:
  duration: ~50min
  tasks: 2
  commits: 2
  files: 25
  completed: 2026-07-31
---

# Quick Task 260731-euq — Pinch to zoom

Two fingers moving apart on the trackpad now zoom the PC in; moving together zooms out. It reaches Windows as a new binary opcode `0x03` executed as a Ctrl-held wheel tick, and it shares the two-finger gesture space with scroll via a single arbitration that locks per episode.

## What shipped

**Commit 1 — `d2900af` `feat(quick-260731-euq): add the 0x03 zoom opcode and execute it as Ctrl-wheel`**

The wire contract and the server, together. `[0x03][dx f32 LE][dy f32 LE]` — the frame shape is unchanged, only the opcode set grew. `dy` is the zoom delta in wheel units (positive zooms in); `dx` is **reserved**: the codec carries it through so `encode(decode(wire))` stays byte-exact for any value, and the executor ignores it. protoVersion 1.6 → 1.7.

Server side: `MouseKeys::zoom` on the trait (no default body — both implementations opt in deliberately), `Call::Zoom` in the mock, the `route_binary` arm, and `Cmd::Zoom` on the Windows input thread with its **own** `SubPixelAccumulator`. Ctrl is pressed and released inside the single arm; the input thread is single-threaded, so nothing can interleave between press and release and a session dying mid-pinch cannot strand the modifier.

Two golden fixtures (`07-zoom-in`, `08-zoom-out`) pin the bytes; both codecs decode and re-encode them.

**Commit 2 — `3a7b0c8` `feat(quick-260731-euq): pinch two fingers to zoom the PC`**

`ZoomIntent(dz)`, `_Phase.pinching`, and the arbitration. Past the slop crossing, accumulated **spread** (change in inter-finger distance) must clear `kPinchMinSpreadPx` **and** beat accumulated **translation** (midpoint movement) by `kPinchDominanceRatio`. Decided once, locked for the contact. Wired into `TrackpadCore` only, so both the full screen and the floating window inherit it — `trackpad_screen.dart` and `floating_trackpad_window.dart` are byte-identical.

## Findings

**1. The brief's compatibility claim was wrong, in the reassuring direction.** The brief said an old server would "hard-fail the 0x03 decode". It will not: `binary.rs` returns `CodecError::UnknownOpcode`, which SPEC §9 rule 4 binds to *dropped and counted, never fatal*, and the handshake compares only the major version component. A v1.4.0 server paired with a post-euq APK stays connected and keeps moving, scrolling and clicking — **pinch is silently absent, not broken**. The carry-forward below is written accordingly.

**2. The Dart fixture driver was blind to new opcodes.** `fixture_test.dart` used two-way ternaries (`expected['op'] == 'move' ? opMove : opScroll` and the mirrored re-encode). A zoom fixture would have been decoded *and re-encoded as a scroll* and the suite would still have passed — permanently silent on the Dart half of the cross-language contract. Both are now three-way with a loud `fail()` on any unknown op. Proven by corrupting `07-zoom-in.json`'s `expect.op` to `"scroll"`, confirming the suite goes red with `07-zoom-in.json: op mismatch`, and restoring it.

**3. The beacon fixture is coupled to `SERVER_PROTO_VERSION`.** `protocol/fixtures/beacon/01-valid.json` embeds the constant (`beacon.rs:56`), so bumping to 1.7 broke `encode_beacon_matches_valid_fixture_wire` until the fixture moved too. Unplanned, caught by the suite. `02-extra-fields.json` deliberately stays on `"1.0"` — it is a decoder forward-compat fixture, not an encoder mirror.

**4. `remote_protocol` still advertises `protoVersion = '1.1'`.** `version.dart` has been stale since phase 1; `handshake_fsm.dart:23` aliases it into `clientProtoVersion`, so the phone literally sends `"1.1"` in `hello` while the server is now at `"1.7"`. Harmless for exactly the major-only reason in finding 1, but wrong. **Deliberately not fixed here** — changing what the client advertises is a handshake-path behaviour change with its own test surface. Flagged as a follow-up.

**5. `kPinchMinSpreadPx` has no reachable test.** Reaching the arbitration requires `_combinedTravel > kTapSlopPx` (10px), and travel that is radial enough to matter carries spread of comparable magnitude — so by the time the decision runs, spread is either well above the 6px floor or dominated by translation anyway. The floor is a defensive guard, not a reachable branch. Rotation-about-the-midpoint is tested instead (it must scroll, never zoom).

**6. Four pre-existing driver construction sites needed the new required seam.** `onSendZoom` is required rather than optional so no future call site can silently omit it; the cost was adding it to `scroll_direction_test.dart` (×2), `trackpad_core_test.dart` and `trackpad_driver_test.dart`. No existing test changed its name or its assertions.

## Known edge, accepted

**T-euq-02 — sticky Ctrl.** If the user holds Ctrl via a keyboard-panel sticky modifier (`Cmd::KeyDown(ctrl)`, tracked in `dispatch/held.rs`) **and** pinches, the zoom arm's `Direction::Release` drops that held Ctrl without updating `held.rs`'s bookkeeping. It requires a sticky Ctrl and a pinch in the same instant, and self-corrects on the next modifier interaction. Consulting held state from the input thread is a larger change than this task warranted.

## Verification

| Suite | Before | After |
|-------|--------|-------|
| `cargo test --workspace` | 202 | **207** (+3 codec, +1 router pause-gate, +1 accumulator independence) |
| `dart test` (remote_protocol) | 13 | **13** — the new fixtures ride the existing loop |
| `flutter test` | 609 | **622** (+9 classifier, +4 driver) |
| `flutter analyze` | clean | clean |

The plan predicted 208 Rust tests; the actual is 207 because the plan counted an *extended* existing router test as a new one. Fully accounted for.

Commit hygiene: `HEAD~1` touches only `protocol/`, `server/` and `app/packages/remote_protocol/`; `HEAD` touches only `app/remote_control/`. Neither spans the other's subsystem.

## Carry-forward

**The server exe MUST ship alongside the APK in the next release.** protoVersion is now 1.7 and the zoom opcode is server-side work. An old server does not break — the session stays up and everything else keeps working — but pinch will silently do nothing until the server is updated. This is the same "ship both halves" rule the keymap growth in phase 10 established, for the same reason.

Not done here, by scope: no release, no version bumps (`pubspec.yaml`, `Cargo.toml`, `manifest.json` untouched), no on-device UAT. Pinch feel (`kZoomUnitPerPx = 0.02`, `kPinchDominanceRatio = 1.5`) is a D-06 on-device tuning starting point, not a final — retune in `tuning.dart` and nowhere else.
