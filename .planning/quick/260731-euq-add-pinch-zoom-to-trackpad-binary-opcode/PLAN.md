---
quick_id: 260731-euq
slug: add-pinch-zoom-to-trackpad-binary-opcode
type: quick
autonomous: true
commits: 3
files_modified:
  - protocol/SPEC.md
  - protocol/schema/mouse-binary.md
  - protocol/fixtures/mouse-binary/07-zoom-in.json
  - protocol/fixtures/mouse-binary/08-zoom-out.json
  - server/server-core/src/codec/binary.rs
  - server/server-core/tests/fixtures.rs
  - app/packages/remote_protocol/lib/src/binary_codec.dart
  - app/packages/remote_protocol/test/fixture_test.dart
  - server/server-core/src/executors/mod.rs
  - server/server-core/src/executors/mock.rs
  - server/server-core/src/dispatch/router.rs
  - server/server-core/src/transport/session.rs
  - server/server-windows/src/input_thread.rs
  - server/server-windows/src/executors/mouse_keys.rs
  - app/remote_control/lib/trackpad/tuning.dart
  - app/remote_control/lib/trackpad/gesture_classifier.dart
  - app/remote_control/lib/trackpad/trackpad_driver.dart
  - app/remote_control/lib/trackpad/move_sender.dart
  - app/remote_control/lib/net/connection_service.dart
  - app/remote_control/lib/trackpad/trackpad_core.dart
  - app/remote_control/test/gesture_classifier_test.dart
  - app/remote_control/test/trackpad_driver_test.dart
requirements: [PAD-01, PAD-03]
must_haves:
  truths:
    - "Two fingers moving apart on the trackpad zooms the PC in; two fingers moving together zooms it out"
    - "Two-finger scroll is unchanged — an episode classified as scroll never emits a zoom frame, and vice versa; the classification LOCKS at the slop crossing"
    - "Two-finger tap still fires exactly one right click — the pinch decision lives entirely past kTapSlopPx, so the tap path is byte-identical"
    - "Ctrl is pressed and released INSIDE one input-thread Cmd arm — it is never held across a pinch, so no modifier can leak out of a dropped session"
    - "The scroll-direction setting (Natural/Reversed) does NOT invert zoom — pinch-apart is always zoom-in"
    - "The same 9-byte frame shape carries zoom: [0x03][dx f32 LE][dy f32 LE], dx reserved and ignored by the executor"
    - "Both codecs decode and re-encode the two new golden fixtures byte-for-byte"
    - "An OLD server receiving 0x03 drops the frame and counts it — the session stays alive (SPEC section 9 rule 4)"
    - "Zoom seeds no momentum and no fling — the pinch ends when the fingers leave"
    - "The work lands as exactly THREE commits: contract, server, client"
  artifacts:
    - path: "protocol/fixtures/mouse-binary/07-zoom-in.json"
      provides: "Golden zoom-in frame, opcode 0x03, dx 0.0, dy 1.5"
      contains: "03000000000000c03f"
    - path: "protocol/fixtures/mouse-binary/08-zoom-out.json"
      provides: "Golden zoom-out frame, opcode 0x03, dx 0.0, dy -0.5"
      contains: "0300000000000000bf"
    - path: "server/server-core/src/codec/binary.rs"
      provides: "OP_ZOOM + MouseFrame::Zoom, decoded and encoded like the other two"
      contains: "OP_ZOOM"
    - path: "app/packages/remote_protocol/lib/src/binary_codec.dart"
      provides: "opZoom + encodeZoom, and a decoder that accepts 0x03"
      contains: "opZoom"
    - path: "app/remote_control/lib/trackpad/gesture_classifier.dart"
      provides: "_Phase.pinching + the spread-vs-translation arbitration that locks for the episode"
      contains: "ZoomIntent"
    - path: "app/remote_control/lib/trackpad/tuning.dart"
      provides: "kZoomUnitPerPx, kPinchDominanceRatio, kPinchMinSpreadPx — the only new magic numbers, all in this file"
      contains: "kPinchDominanceRatio"
    - path: "server/server-windows/src/input_thread.rs"
      provides: "Cmd::Zoom + its own zoom_acc, Ctrl pressed and released inside the arm"
      contains: "Cmd::Zoom"
  key_links:
    - from: "route_binary MouseFrame::Zoom"
      to: "MouseKeys::zoom"
      via: "exec.mouse_keys.zoom(dx, dy)"
      pattern: "mouse_keys\\.zoom\\(dx, dy\\)"
    - from: "EnigoMouseKeys::zoom"
      to: "Cmd::Zoom"
      via: "self.tx.send(Cmd::Zoom(dx, dy))"
      pattern: "Cmd::Zoom\\(dx, dy\\)"
    - from: "TrackpadDriver ZoomIntent arm"
      to: "ConnectionService.sendZoom"
      via: "_onSendZoom(0.0, dz * kZoomUnitPerPx)"
      pattern: "kZoomUnitPerPx"
---

<objective>
Add pinch-to-zoom to the trackpad, end to end: a new two-finger gesture on the phone, a new binary opcode on the wire, and a Ctrl-wheel executor on Windows.

The mechanism is OWNER-LOCKED and is not to be re-litigated: a new 9-byte binary opcode `0x03` reusing the existing `[opcode u8][dx f32 LE][dy f32 LE]` layout exactly; the server's input thread maps it to Ctrl-down → `enigo.scroll(sy, Vertical)` → Ctrl-up, all inside one `Cmd` arm.

Output: THREE atomic commits, bottom-up, each independently green.

1. **Contract** — SPEC, schema doc, two golden fixtures, and BOTH codecs. The fixtures and the codecs must land together or the shared-fixture suites go red on an intermediate commit.
2. **Server** — `MouseKeys::zoom` on the trait, the mock, the router, the Windows `Cmd::Zoom` arm, and the `SERVER_PROTO_VERSION` bump to `"1.7"`.
3. **Client** — tuning constants, the classifier's pinch phase and arbitration, the driver arm, the sender and service seams, and their tests.
</objective>

<critical_finding>
**The brief's compatibility framing is wrong and must not be repeated in any commit message or the SUMMARY.**

The brief states that "an old server would hard-fail the 0x03 decode". Verified against the current tree, it will not:

- `server-core/src/codec/binary.rs:48-52` dispatches on the opcode LAST and returns `CodecError::UnknownOpcode(op)` for anything that is not `OP_MOVE`/`OP_SCROLL`. That is an ordinary decode error.
- SPEC §9 strict-decode rule 4 (and `protocol/schema/mouse-binary.md`) already binds that error: *errored frames are dropped and counted, never routed to an executor, and never terminate the session.*
- `SERVER_PROTO_VERSION` is `"1.6"` (`session.rs:65`) and the handshake compares the MAJOR component only (`session.rs:554-583`); a minor mismatch is accepted, not rejected.

So a v1.4.0 server paired with a post-euq APK stays connected, keeps moving the cursor, keeps scrolling, and silently does nothing on pinch. **The real carry-forward is "pinch is silently absent until the server is updated", not "it breaks".** That is a milder claim and it is the accurate one — write it that way.

**Second finding, out of scope but recorded:** `app/packages/remote_protocol/lib/src/version.dart` still declares `protoVersion = '1.1'`, and `handshake_fsm.dart:23` aliases it into `clientProtoVersion`, so the phone has been advertising `"1.1"` in `hello` since phase 1 while the server advanced to 1.6. It is harmless for exactly the major-only reason above, but it is wrong. Do NOT fix it here — changing what the client advertises is a handshake-path behaviour change with its own test surface. Record it in the SUMMARY.
</critical_finding>

<execution_context>
@$HOME/.claude/gsd-core/workflows/execute-plan.md
@$HOME/.claude/gsd-core/templates/summary.md
</execution_context>

<context>
@.planning/STATE.md
@CLAUDE.md

**Already verified by the planner — do NOT re-derive:**

- Test baselines, measured on `ef9b9e6` immediately before this plan: `cargo test --workspace` = **202** passing across 7 suites; `dart test` in `app/packages/remote_protocol` = **13**; `flutter test` in `app/remote_control` = **609**.
- Every in-repo consumer of `MouseFrame` (the match arms that will fail to compile until they gain a `Zoom` arm — this is the desired forcing function): `dispatch/router.rs:443-444`, `tests/fixtures.rs:72-73`. `tests/integration.rs:333` constructs `Move` only and needs no change.
- Every in-repo consumer of the `MouseKeys` trait: `executors/mock.rs` (records into `Call`), `server-windows/src/executors/mouse_keys.rs` (forwards to `Cmd`). Adding a trait method breaks both at compile time — again desired.
- `Cmd` is declared at `server-windows/src/input_thread.rs:45-67`; the loop's match is at `:392` onward. `Key`, `Axis`, `Direction` and `map_mod` are ALL already in scope in that file (the `Cmd::KeyTap` arm at `:445-457` presses and releases modifiers around a key exactly the way the zoom arm must).
- `SubPixelAccumulator` (`input_thread.rs:69-80`, `.step(dx, dy) -> (i32, i32)`) is already instantiated twice (`move_acc`, `scroll_acc`) at `:388-389`. A third instance is the pattern, not an invention.
- `04-bad-opcode.json` uses opcode `0x7f`, NOT `0x03` — it remains a valid negative fixture after this change. Do not touch it.
- The Dart fixture driver at `app/packages/remote_protocol/test/fixture_test.dart:83` and `:89` uses TWO-WAY ternaries (`expected['op'] == 'move' ? opMove : opScroll` and `frame.op == opMove ? encodeMove : encodeScroll`). **A zoom fixture would silently be decoded and re-encoded as a scroll and the test would still pass.** Both ternaries MUST become three-way. This is the single highest-risk line in the task.
- `ConnectionService.sendScroll` (`connection_service.dart:540-544`) is the exact shape `sendZoom` must copy: volatile gate, `_sender?`, `_probe?.onMove()`.
- `TrackpadCore` (`trackpad_core.dart:160-175`) is the ONLY production construction site of `TrackpadDriver`. Wiring `onSendZoom` there gives both the full screen and the floating window the gesture with no surface-specific code.

**Deliberate non-changes (do not "helpfully" fix these):**
- `version.dart`'s stale `'1.1'` — see `<critical_finding>`. `app/packages/remote_protocol/` gets its codec changed and NOTHING else.
- `kScrollDirection` and the `scrollReversed` seam. Zoom must NOT read either. Pinch-apart-is-zoom-in is universal; the Natural/Reversed preference is a SCROLL preference and inverting zoom with it would be a bug, not a feature.
- The `_Phase.moving` → second finger → `_Phase.scrolling` transition (`gesture_classifier.dart:313-315`). An episode already past slop with one finger stays a scroll and can never become a pinch. Byte-identical.
- `REQUIREMENTS.md`. Pinch zoom is capability beyond the v1.0 requirement set; minting a PAD-06 is a requirements change, not a quick task. Recorded in the SUMMARY instead.
- No release, no version bumps in `pubspec.yaml` / `Cargo.toml` / `manifest.json`, no on-device UAT.
</context>

<tasks>

<task type="auto">
  <name>Task 1 (COMMIT 1): the wire contract — SPEC, schema, fixtures, both codecs</name>
  <files>protocol/SPEC.md, protocol/schema/mouse-binary.md, protocol/fixtures/mouse-binary/07-zoom-in.json, protocol/fixtures/mouse-binary/08-zoom-out.json, server/server-core/src/codec/binary.rs, server/server-core/tests/fixtures.rs, app/packages/remote_protocol/lib/src/binary_codec.dart, app/packages/remote_protocol/test/fixture_test.dart</files>

  <read_first>
- `protocol/SPEC.md` §2 (the protoVersion table), §9 (binary frames) and §11 line 201 (the pause drop list).
- `protocol/schema/mouse-binary.md` — whole file (37 lines).
- `protocol/fixtures/mouse-binary/03-scroll.json` — the positive-fixture shape to clone.
- `protocol/fixtures/README.md` "Value discipline" — the lowercase-hex and f32-exact rules.
- `server/server-core/src/codec/binary.rs` — whole file (149 lines).
- `app/packages/remote_protocol/lib/src/binary_codec.dart` — whole file (72 lines).
- `app/packages/remote_protocol/test/fixture_test.dart` lines 61-96 (the mouse-binary group).
- `server/server-core/tests/fixtures.rs` lines 60-90 (the MouseFrame match).
- Do NOT open `server/server-windows/` or `app/remote_control/` in this task.
  </read_first>

  <action>
**1. `protocol/SPEC.md` §9 — the opcode table.** Add a third row to the opcode table: `` `0x03` `` | `zoom (Ctrl-wheel zoom delta)`. Immediately under the table add a short paragraph defining the payload semantics, because zoom is the first opcode that does not use both axes:

> For `0x03`, `dy` is the zoom delta in wheel units — positive zooms IN, negative zooms OUT — and `dx` is **reserved**: it is carried through the codec unchanged (so `encode(decode(wire))` still round-trips byte-for-byte) but the executor ignores it. Clients SHOULD send `dx = 0.0`.

Update the strict-decode bullet that reads "Unknown opcode → decode error" so it is unambiguous that `0x03` is now known. Do NOT weaken rule 4 — an unknown opcode is still dropped-and-counted, never fatal (this is exactly what protects an old server; see `<critical_finding>`).

**2. `protocol/SPEC.md` §2 — the protoVersion table.** Add the `1.7` row in the established style of the 1.4/1.5/1.6 rows: `1.7` — adds the `0x03` zoom binary opcode (pinch-to-zoom); a minor bump, so `1.6` peers stay fully interoperable — an older server rejects the opcode at decode and drops the frame, which costs zoom and nothing else.

**3. `protocol/SPEC.md` §11 — the pause drop list.** Line 201 already begins the executor-bound list with "binary frames", which covers `0x03` with no edit. Make it explicit rather than implicit by changing that phrase to "binary frames (move, scroll, zoom)". Change NOTHING else on that line — every JSON type listed after it stays byte-identical.

**4. `protocol/schema/mouse-binary.md`.** Update the title line from `(protoVersion 1.0)` to `(protoVersion 1.7)`. Add `0x03` to the offset-table's opcode cell and add the third row to the Opcodes table with the `dx` reserved / `dy` = zoom-delta semantics from step 1. Update strict-decode rule 2 so the known set reads `0x01`/`0x02`/`0x03`. Leave the Notes section's fixture conventions untouched.

**5. The two golden fixtures.** Create both, cloning `03-scroll.json`'s exact key order and formatting (2-space indent, trailing newline). The hex below was computed and verified by the planner — do NOT recompute or "correct" it:

`protocol/fixtures/mouse-binary/07-zoom-in.json`
- `name`: `zoom-in`
- `description`: must name opcode 0x03, dx 0.0, dy 1.5, say the values are f32-exact, and state that positive dy zooms in.
- `wire`: `03000000000000c03f`
- `expect`: `{ "op": "zoom", "dx": 0.0, "dy": 1.5 }`

`protocol/fixtures/mouse-binary/08-zoom-out.json`
- `name`: `zoom-out`
- `description`: same shape, dy -0.5, negative dy zooms out.
- `wire`: `0300000000000000bf`
- `expect`: `{ "op": "zoom", "dx": 0.0, "dy": -0.5 }`

Both dy values (1.5, -0.5) are exactly representable in f32, satisfying the README's no-epsilon rule.

**6. `server/server-core/src/codec/binary.rs`.** Add `pub const OP_ZOOM: u8 = 0x03;` under `OP_SCROLL` with a doc comment naming it the pinch-to-zoom delta and stating that `dx` is reserved. Add `Zoom { dx: f32, dy: f32 }` to `MouseFrame` with the same doc convention. Add the `OP_ZOOM => Ok(MouseFrame::Zoom { dx, dy })` arm to `decode`'s match and the `MouseFrame::Zoom { dx, dy } => (OP_ZOOM, dx, dy)` arm to `encode`'s. Do not reorder the existing checks — length, then f32 parse, then finite, then opcode dispatch is a documented cross-language ordering contract and the `nonfinite_beats_unknown_opcode` test pins it.

Add three unit tests to the existing `mod tests`, matching the naming of their neighbours: `decode_zoom_exact` (0x03 with dx 0.0, dy 1.5), `round_trip_zoom` (encode(decode(b)) == b for a zoom frame), and `rejects_unknown_opcode_still` — assert `0x04` is STILL `UnknownOpcode(0x04)`, proving the known set grew by exactly one.

**7. `server/server-core/tests/fixtures.rs`.** The match at lines 72-73 is exhaustive over `MouseFrame` and will not compile until it gains `binary::MouseFrame::Zoom { dx, dy } => ("zoom", dx, dy),`. Add exactly that arm in the same style.

**8. `app/packages/remote_protocol/lib/src/binary_codec.dart`.** Add `const int opZoom = 0x03;` with a doc comment matching `opScroll`'s, plus the reserved-`dx` note. Add `Uint8List encodeZoom(double dx, double dy) => _encode(opZoom, dx, dy);`. In `decodeMouseFrame`, extend the opcode guard from `op != opMove && op != opScroll` to also allow `opZoom`. Update the library doc comment's opcode list. The decode ORDER (length, f32, finite, opcode) must stay exactly as it is — the comment says it mirrors Rust, and it must keep doing so.

**9. `app/packages/remote_protocol/test/fixture_test.dart` — THE CRITICAL EDIT.** Both two-way ternaries in the mouse-binary group must become three-way, keyed off the fixture's `op` string:

- Replace `final expectedOp = expected['op'] == 'move' ? opMove : opScroll;` with a switch or map from `'move'`/`'scroll'`/`'zoom'` to `opMove`/`opScroll`/`opZoom` that THROWS (or fails the test with a clear reason) on any other string. A silent fallback is what made the old two-way form dangerous — do not write another one.
- Replace the re-encode ternary `frame.op == opMove ? encodeMove(...) : encodeScroll(...)` with a three-way dispatch to `encodeMove`/`encodeScroll`/`encodeZoom`, again with no silent fallback arm.

**10. Commit.** Stage exactly the eight paths above and commit with subject `feat(quick-260731-euq): add the 0x03 zoom opcode to the wire contract`. The body must state: the frame shape is unchanged and only the opcode set grew; `dx` is reserved on `0x03`; both codecs and both fixture suites move together in this commit BECAUSE a fixture without its codecs is a red suite; and the compatibility fact from `<critical_finding>` — an older server drops `0x03` at decode and keeps the session alive. Do NOT stage anything under `server/server-windows/` or `app/remote_control/`.
  </action>

  <verify>
    <automated>cd server &amp;&amp; cargo test --workspace 2>&amp;1 | grep -E "^test result:" &amp;&amp; cd ../app/packages/remote_protocol &amp;&amp; dart test</automated>
  </verify>

  <acceptance_criteria>
- `cargo test --workspace` totals **205** passing (baseline 202, +3 from the new binary.rs unit tests), 0 failed.
- `dart test` in `app/packages/remote_protocol` reports **13** passing — the count is unchanged because the two new fixtures are consumed by the existing looping `all scenarios` test, not by new test cases. If it reports anything other than 13 passing, a test was added or lost — reconcile before committing.
- Fixture-driver proof (the whole point of step 9): temporarily corrupting `07-zoom-in.json`'s `expect.op` from `"zoom"` to `"scroll"` MUST make `dart test` fail. Run it, confirm red, then restore the file and confirm green again. Do not commit the corrupted file.
- `grep -c "opZoom" app/packages/remote_protocol/lib/src/binary_codec.dart` is at least 3 (const, encodeZoom, decode guard).
- `grep -n "OP_ZOOM" server/server-core/src/codec/binary.rs` matches at least 3 times (const, decode arm, encode arm).
- `git diff --stat -- server/server-windows/ app/remote_control/` produces NO output.
- Exactly one commit was created by this task.
  </acceptance_criteria>

  <done>The wire knows about zoom: SPEC and the schema doc describe `0x03`, two golden fixtures pin its bytes, and both codecs decode and re-encode them byte-for-byte — with the Dart fixture driver now genuinely able to tell a zoom frame from a scroll frame.</done>
</task>

<task type="auto">
  <name>Task 2 (COMMIT 2): the server — trait, mock, router, Windows Ctrl-wheel arm</name>
  <files>server/server-core/src/executors/mod.rs, server/server-core/src/executors/mock.rs, server/server-core/src/dispatch/router.rs, server/server-core/src/transport/session.rs, server/server-windows/src/executors/mouse_keys.rs, server/server-windows/src/input_thread.rs</files>

  <read_first>
- `server/server-core/src/executors/mod.rs` lines 200-215 (the `MouseKeys` trait).
- `server/server-core/src/executors/mock.rs` lines 15-30 (the `Call` enum) and 125-140 (the `MouseKeys` impl).
- `server/server-core/src/dispatch/router.rs` lines 430-450 (`route_binary`, including the `paused` early-return) and the three existing binary tests at `:640-660`, `:910-920`, `:1335-1350`.
- `server/server-core/src/transport/session.rs` line 65 only.
- `server/server-windows/src/executors/mouse_keys.rs` — whole file.
- `server/server-windows/src/input_thread.rs` lines 45-67 (`Cmd`), 69-110 (`SubPixelAccumulator`), 385-400 (accumulator instantiation + the `Move` arm), and 445-457 (the `KeyTap` arm — the modifier press/release idiom to mirror).
- Do NOT open `app/` in this task.
  </read_first>

  <action>
**1. `executors/mod.rs` — extend the trait.** Add `fn zoom(&self, dx: f32, dy: f32);` to `MouseKeys`, directly after `scroll`. Doc-comment it: zoom by `dy` wheel units with Ctrl held (pinch-to-zoom, SPEC §9 opcode `0x03`); `dx` is reserved and implementations ignore it. No default body — every implementation must opt in deliberately, and the compile break in the two impls below is the point.

**2. `executors/mock.rs`.** Add `Zoom(f32, f32)` to the `Call` enum next to `Scroll`, and the recording impl `fn zoom(&self, dx: f32, dy: f32) { self.log.record(Call::Zoom(dx, dy)); }` next to `scroll`.

**3. `dispatch/router.rs`.** Add `MouseFrame::Zoom { dx, dy } => exec.mouse_keys.zoom(dx, dy),` to `route_binary`'s match, after the `Scroll` arm. The `paused` early-return above the match already covers it — do NOT add a second pause check, and do NOT restructure the function.

Extend the existing binary-routing tests rather than writing new ones where an existing test already owns the assertion:
- In the test at `:1343-1347` that routes a Move and a Scroll and asserts `vec![Call::MoveRel(1.5, -2.0), Call::Scroll(0.0, 3.0)]`, add a third `route_binary(MouseFrame::Zoom { dx: 0.0, dy: 2.0 }, ...)` call and extend the expected vec with `Call::Zoom(0.0, 2.0)`.
- Add ONE new test proving zoom is pause-gated, modelled on the `paused` test at `:915`: route a `MouseFrame::Zoom` with `paused = true` and assert the mock log is empty.

**4. `transport/session.rs` line 65.** Change `SERVER_PROTO_VERSION` from `"1.6"` to `"1.7"`. This commit is where the constant becomes true — commit 1 wrote the SPEC, this one ships the capability. If any test pins the literal `"1.6"`, update it in the same commit; if none does, note that in the commit body.

**5. `server-windows/src/executors/mouse_keys.rs`.** Add the forwarding impl next to `scroll`: `fn zoom(&self, dx: f32, dy: f32) { let _ = self.tx.send(Cmd::Zoom(dx, dy)); }`. Same fire-and-forget `let _ =` discipline as every other method — a full channel drops the command, never blocks the hot path.

**6. `server-windows/src/input_thread.rs` — the `Cmd` variant.** Add `Zoom(f32, f32)` after `Scroll`, doc-commented: zoom in fractional wheel units with Ctrl held; `dx` is reserved and ignored.

**7. `input_thread.rs` — the accumulator.** Add `let mut zoom_acc = SubPixelAccumulator::new();` alongside `move_acc` and `scroll_acc`. It MUST be its own instance — sharing `scroll_acc` would let a pinch consume the fractional remainder of an in-progress scroll and vice versa.

**8. `input_thread.rs` — the arm.** Add directly after the `Cmd::Scroll` arm:

```rust
Cmd::Zoom(_, dy) => {
    // dx is reserved on 0x03 (SPEC §9) — only the vertical axis
    // carries the zoom delta, so the accumulator is stepped with a
    // zero x and only sy is consumed.
    let (_, sy) = zoom_acc.step(0.0, dy);
    if sy != 0 {
        // Ctrl is pressed and released INSIDE this arm: the input
        // thread is single-threaded, so no other Cmd can interleave
        // between the press and the release, and a session that dies
        // mid-pinch can never leave Ctrl stuck down. This is why the
        // client has no Ctrl state machine.
        let _ = enigo.key(Key::Control, Direction::Press);
        let _ = enigo.scroll(sy, Axis::Vertical);
        let _ = enigo.key(Key::Control, Direction::Release);
    }
}
```

Follow the non-fatal-drop rule exactly as written — every enigo call is `let _ =`, nothing panics. Do NOT add a `maybe_check_uipi` call: the `Scroll` arm does not have one either, and the UIPI probe is deliberately debounced onto the `Move`/`Click` arms only (RESEARCH Pattern 5).

**9. Accumulator test.** Add one unit test to `input_thread.rs`'s existing `mod tests` proving a third accumulator instance is independent: step a `zoom_acc` and a `scroll_acc` with the same sub-integer sequence and assert neither observes the other's remainder. Name it in the style of its neighbours (e.g. `zoom_accumulator_is_independent_of_scroll`).

**10. Commit.** Stage exactly the six paths above and commit with subject `feat(quick-260731-euq): execute zoom frames as Ctrl-held wheel ticks`. The body must state that Ctrl never outlives the arm (and therefore owes nothing to CONN-07 `release_all`), that zoom carries its own sub-pixel accumulator, and that `SERVER_PROTO_VERSION` is now `"1.7"`. Do NOT stage anything under `app/` or `protocol/`.
  </action>

  <verify>
    <automated>cd server &amp;&amp; cargo build --workspace &amp;&amp; cargo test --workspace 2>&amp;1 | grep -E "^test result:"</automated>
  </verify>

  <acceptance_criteria>
- `cargo build --workspace` succeeds — this is the real gate, since it proves both `MouseKeys` implementations picked up the new trait method.
- `cargo test --workspace` totals **208** passing (205 after commit 1, +2 router tests, +1 accumulator test), 0 failed.
- `grep -n "fn zoom" server/server-core/src/executors/mod.rs server/server-core/src/executors/mock.rs server/server-windows/src/executors/mouse_keys.rs` matches in all three files.
- `grep -c "SubPixelAccumulator::new()" server/server-windows/src/input_thread.rs` is 3.
- `grep -n "SERVER_PROTO_VERSION: &str = \"1.7\"" server/server-core/src/transport/session.rs` matches.
- `grep -n "maybe_check_uipi" server/server-windows/src/input_thread.rs` still matches exactly the pre-existing call sites — the zoom arm added none.
- `git diff --stat -- app/ protocol/` produces NO output.
- Exactly one commit was created by this task, and it is the SECOND.
  </acceptance_criteria>

  <done>A `0x03` frame arriving at an authed, unpaused session presses Ctrl, turns the wheel by the accumulated integer delta, and releases Ctrl — all inside one arm on the single input thread. The server advertises `1.7`.</done>
</task>

<task type="auto">
  <name>Task 3 (COMMIT 3): the client — pinch phase, arbitration, driver arm, send seams</name>
  <files>app/remote_control/lib/trackpad/tuning.dart, app/remote_control/lib/trackpad/gesture_classifier.dart, app/remote_control/lib/trackpad/trackpad_driver.dart, app/remote_control/lib/trackpad/move_sender.dart, app/remote_control/lib/net/connection_service.dart, app/remote_control/lib/trackpad/trackpad_core.dart, app/remote_control/test/gesture_classifier_test.dart, app/remote_control/test/trackpad_driver_test.dart</files>

  <read_first>
- `app/remote_control/lib/trackpad/gesture_classifier.dart` — whole file (496 lines). The `_Phase` enum, all four pointer handlers, `reset`, `_emitScroll`, `_flingFrom`.
- `app/remote_control/lib/trackpad/tuning.dart` — whole file (76 lines).
- `app/remote_control/lib/trackpad/trackpad_driver.dart` — whole file (214 lines), especially the `handle` switch and the `_directionSign` gate.
- `app/remote_control/lib/trackpad/move_sender.dart` — whole file (38 lines).
- `app/remote_control/lib/net/connection_service.dart` lines 526-548 (`sendMove`/`sendScroll`/`sendReliable`).
- `app/remote_control/lib/trackpad/trackpad_core.dart` lines 156-176 (the driver construction).
- `app/remote_control/test/gesture_classifier_test.dart` and `test/trackpad_driver_test.dart` — enough of each to match their fake/seam conventions and naming.
  </read_first>

  <action>
**1. `tuning.dart` — three new constants, in a new `// -- Pinch zoom (SPEC §9 opcode 0x03) --` section placed after the scroll/fling section.** No magic number introduced by this task may live anywhere else (D-06).

- `kZoomUnitPerPx = 0.02` — wheel units per pixel of inter-finger separation change. Doc: a ~100px pinch produces ~2 wheel units, i.e. roughly two zoom steps, which matches a physical trackpad's feel. Deliberately smaller than `kScrollUnitPerPx` (0.05) because separation change accumulates faster than scroll travel for the same intent.
- `kPinchDominanceRatio = 1.5` — how far the spread signal must beat the translation signal before the episode is classified as a pinch. Doc: the tie-break deliberately favours SCROLL, which is the far more common two-finger gesture; a genuine pinch has near-zero translation and clears 1.5 easily.
- `kPinchMinSpreadPx = 6.0` — absolute floor on accumulated spread. Doc: without it, two nearly-stationary fingers whose jitter happens to be radial would classify as a pinch and emit zoom on what the user meant as a rest.

**2. `gesture_classifier.dart` — the intent.** Add `ZoomIntent` to the sealed hierarchy, next to `ScrollIntent`, following the file's exact convention (final class, `const` ctor, `operator ==`, `hashCode` via `Object.hash`, `toString`). It carries ONE field: `final double dz` — the raw change in inter-pointer separation in logical px, positive when the fingers moved apart. The driver, not the classifier, converts px to wheel units (same division of labour as `ScrollIntent`).

**3. `gesture_classifier.dart` — the phase.** Add `pinching` to `_Phase` with a doc comment matching its siblings: two-finger separation dominated the episode — streaming `ZoomIntent`s, locked for the rest of the contact.

**4. `gesture_classifier.dart` — pinch tracking state.** Add private fields alongside `_combinedTravel`: `double _spreadAccum = 0`, `double _transAccum = 0`, `double? _lastDist`, and a last-midpoint pair (two doubles or a small private holder — match the file's existing `_Pointer`/`_Sample` style rather than importing anything). Seed them when the SECOND finger lands (in `onPointerDown`'s second-finger branch): zero both accumulators and record the current distance and midpoint from the two live `_pointers`.

**5. `gesture_classifier.dart` — signal accumulation.** In `onPointerMove`, AFTER the existing `_combinedTravel` update and only while exactly two pointers are tracked, update both signals from the two live positions:
- new distance `d` between the two pointers; `_spreadAccum += (d - _lastDist).abs()`; then `_lastDist = d`.
- new midpoint `m`; `_transAccum += distance(m, _lastMid)`; then `_lastMid = m`.

Accumulate ABSOLUTE magnitudes on both, so an in-and-out pinch and a there-and-back scroll both register honestly.

**6. `gesture_classifier.dart` — the arbitration (the core of the task).** In `onPointerMove`'s `case _Phase.tapPending2:`, the existing early return `if (_combinedTravel <= kTapSlopPx) return const [];` is UNCHANGED — this is what keeps the two-finger tap byte-identical. Past that gate, replace the unconditional `_phase = _Phase.scrolling` with the decision:

```
final isPinch = _spreadAccum >= kPinchMinSpreadPx &&
    _spreadAccum >= kPinchDominanceRatio * _transAccum;
```

If `isPinch`, set `_phase = _Phase.pinching` and return the first `ZoomIntent`; otherwise set `_phase = _Phase.scrolling` and return `_emitScroll(dx, dy)` exactly as today. The decision is made ONCE, here — neither phase ever reconsiders, which is the locking requirement.

**7. `gesture_classifier.dart` — the pinching arm.** Add `case _Phase.pinching:` to `onPointerMove` returning a `ZoomIntent` built from the separation delta computed in step 5 — **but only while two pointers are live**. If one finger has lifted, return `const []`: a single finger cannot define a separation. Note the deliberate asymmetry with `scrolling`, which by WR-04 keeps scrolling at full rate on one remaining finger — write that contrast into the doc comment so nobody "fixes" it later.

**8. `gesture_classifier.dart` — lift and cancel.** Add `case _Phase.pinching:` to `onPointerUp`: when pointers remain, return `const []`; when the last lifts, set `_phase = _Phase.idle` and return `const []`. **A pinch NEVER seeds a fling** — do not call `_flingFrom`, and do not touch `_samples` from any pinch path. `onPointerCancel` needs no new arm (it is phase-agnostic) but confirm the pinch fields are reset by its `_pointers.isEmpty` branch or by `reset()`.

**9. `gesture_classifier.dart` — `reset()`.** Clear `_spreadAccum`, `_transAccum`, `_lastDist` and the last-midpoint fields alongside the existing state, so a disconnect mid-pinch leaves nothing stale.

**10. `trackpad_driver.dart`.** Add a required `onSendZoom` seam mirroring `onSendScroll` in every respect (ctor param, private field, doc mention in the library comment). Add the `handle` arm:

```
case ZoomIntent(:final dz):
  _onSendZoom(0.0, dz * kZoomUnitPerPx);
```

`dx` is 0.0 because SPEC §9 reserves it on `0x03`. **The `_directionSign()` / `scrollReversed` gate is deliberately NOT applied** — add a comment saying so explicitly, naming the reason: Natural/Reversed is a scroll preference, and pinch-apart-is-zoom-in is invariant. No momentum, no generation counter, no timer — a pinch has no fling.

**11. `move_sender.dart`.** Add `void sendZoom(double dx, double dy) { sink.add(encodeZoom(dx, dy)); }` next to `sendScroll`, with a doc comment matching its neighbours. Never re-implement the encoder here.

**12. `connection_service.dart`.** Add `sendZoom` immediately after `sendScroll`, structurally identical: volatile gate via `_policy.shouldSendVolatile()`, `_sender?.sendZoom(dx, dy)`, `_probe?.onMove()`. Doc-comment it as the third volatile binary class — dropped, never queued, for the same reason moves and scrolls are (a queued zoom would fire a burst of zoom steps on reconnect).

**13. `trackpad_core.dart`.** Wire `onSendZoom: _service.sendZoom` into the `TrackpadDriver` construction, next to `onSendScroll`. This is the ONLY wiring change in the entire client — both the full screen and the floating window inherit the gesture from here, and NOTHING surface-specific may be added to either.

**14. Tests — `test/gesture_classifier_test.dart`.** Add a `group` for pinch covering, at minimum:
- **pinch classifies and locks**: two fingers separating past slop emit `ZoomIntent`s and NEVER a `ScrollIntent`, even if the fingers subsequently translate together.
- **scroll classifies and locks**: two fingers translating past slop emit `ScrollIntent`s and NEVER a `ZoomIntent`, even if their separation subsequently changes.
- **two-finger tap regression**: the existing right-click path still emits exactly `ClickRightIntent` — under slop, no pinch decision is reached.
- **sign**: fingers apart gives positive `dz`; fingers together gives negative `dz`.
- **one finger lifts mid-pinch**: emits nothing further (no crash, no zero-division, no phantom zoom).
- **no fling from a pinch**: lifting both fingers fast after a pinch emits NO `FlingIntent`.
- **`reset()` clears pinch state**: a reset mid-pinch followed by a fresh two-finger episode classifies from scratch.
- **`kPinchMinSpreadPx` floor**: tiny radial jitter under the floor classifies as scroll, not pinch.

**15. Tests — `test/trackpad_driver_test.dart`.** Add: the `ZoomIntent` arm calls `onSendZoom` with `dx == 0.0` and `dy == dz * kZoomUnitPerPx`; and — the important one — flipping the injected `scrollReversed` seam to `true` changes the SCROLL sign but leaves the ZOOM sign untouched.

**16. Commit.** Stage exactly the eight paths above and commit with subject `feat(quick-260731-euq): pinch two fingers to zoom the PC`. The body must state the arbitration rule (spread vs translation, decided once at the slop crossing, locked for the episode), that the two-finger tap path is untouched, and that the scroll-direction preference deliberately does not invert zoom.
  </action>

  <verify>
    <automated>cd app/remote_control &amp;&amp; flutter analyze &amp;&amp; flutter test</automated>
  </verify>

  <acceptance_criteria>
- `flutter analyze` is clean — no new warnings, no unused constant, and the exhaustive `switch` over `GestureIntent` in the driver compiles (a missing `ZoomIntent` arm is a compile error by design, since the hierarchy is sealed).
- `flutter test` reports **609 + N** passing where N is the number of new tests added in steps 14-15, 0 failed. State the exact final number in the SUMMARY. No pre-existing test may change its name or its assertions.
- `grep -rn "scrollReversed\|_directionSign" app/remote_control/lib/trackpad/trackpad_driver.dart` shows those symbols appearing ONLY on the scroll and momentum paths — never inside the `ZoomIntent` arm.
- `grep -rn "kZoomUnitPerPx\|kPinchDominanceRatio\|kPinchMinSpreadPx" app/remote_control/lib/` shows each constant DEFINED once in `tuning.dart` and used only in `trackpad_driver.dart` (the unit) / `gesture_classifier.dart` (the two thresholds). No literal `0.02`, `1.5` or `6.0` appears in either consumer.
- `git diff --stat -- app/remote_control/lib/trackpad/trackpad_screen.dart app/remote_control/lib/trackpad/floating_trackpad_window.dart` produces NO output — both surfaces inherit the gesture with zero surface-specific code.
- `git diff --stat -- server/ protocol/ app/packages/remote_protocol/` produces NO output.
- Exactly one commit was created by this task, and it is the THIRD.
  </acceptance_criteria>

  <done>Two fingers moving apart on either trackpad surface emits `0x03` frames that zoom the PC in; two-finger scroll and two-finger tap behave exactly as they did before; and the classification is decided once and locked.</done>
</task>

</tasks>

<threat_model>
## Trust Boundaries

| Boundary | Description |
|----------|-------------|
| phone → PC server | A new executor-bound binary opcode reaches `SendInput`/enigo; the client controls its magnitude and sign |
| input thread → foreground window | Ctrl is now synthesised by a path that is not the keyboard's held-key bookkeeping |

## STRIDE Threat Register

| Threat ID | Category | Component | Disposition | Mitigation Plan |
|-----------|----------|-----------|-------------|-----------------|
| T-euq-01 | Elevation of Privilege | `Cmd::Zoom` synthesising Ctrl | mitigate | Ctrl is pressed and released within a single arm on the single-threaded input loop, so no other `Cmd` can interleave and no session teardown can strand it held. The existing CONN-07 `release_all` contract is untouched and gains no new obligation |
| T-euq-02 | Tampering | held-modifier interaction | accept + document | If the user is holding Ctrl via a keyboard-panel sticky modifier (`Cmd::KeyDown(ctrl)`, tracked in `dispatch/held.rs`) AND pinches, the zoom arm's `Direction::Release` drops that held Ctrl without updating `held.rs`'s bookkeeping. Obscure (it requires a sticky Ctrl and a pinch in the same instant) and self-correcting on the next modifier interaction. Consulting held state from the input thread is a larger change than this task warrants — record it in the SUMMARY as a known edge |
| T-euq-03 | Denial of Service | unbounded zoom magnitude | mitigate | A hostile or buggy client cannot exceed what scroll already permits: the same 9-byte frame, the same strict decode (non-finite rejected before dispatch), the same pause gate, and the same fire-and-forget mpsc that drops rather than blocks when full. Zoom adds no new unbounded surface |
| T-euq-04 | Denial of Service | fixture-driver silent fallback | mitigate | The pre-existing two-way ternaries in `fixture_test.dart` would decode a zoom fixture AS A SCROLL and still pass, permanently blinding the Dart half of the cross-language contract. Task 1 step 9 replaces both with no-silent-fallback dispatch, and the acceptance criteria require proving the driver goes red on a corrupted fixture |
| T-euq-05 | Information Disclosure | logging | mitigate | The zoom arm logs nothing. Deltas are not logged, matching the `Move`/`Scroll` arms and SPEC §12 redaction |
| T-euq-SC | Tampering | supply chain | mitigate | ZERO package installs. `pubspec.yaml`, `pubspec.lock`, `Cargo.toml`, `Cargo.lock` and `extension/manifest.json` are NOT in `files_modified`; a diff touching any of them is a task failure. No Package Legitimacy Audit is required because no npm/pub/cargo install occurs |
</threat_model>

<verification>
Run after ALL THREE commits exist. `HEAD~3..HEAD` must be exactly this task's three commits — if it is not, stop.

1. `cd server && cargo build --workspace` — succeeds.
2. `cd server && cargo test --workspace` — **208** passing (baseline 202, +3 codec, +2 router, +1 accumulator), 0 failed.
3. `cd app/packages/remote_protocol && dart test` — **13** passing (unchanged; the new fixtures ride the existing loop).
4. `cd app/remote_control && flutter analyze` — clean.
5. `cd app/remote_control && flutter test` — 609 + N passing, 0 failed. Record N and the total in the SUMMARY.
6. Cross-language byte contract: both `07-zoom-in.json` and `08-zoom-out.json` are consumed by the Rust suite (`tests/fixtures.rs`) AND the Dart suite (`test/fixture_test.dart`), and neither codec was allowed to adjust a fixture to match itself.
7. Commit hygiene: `git show --stat HEAD~2` touches only `protocol/`, `server/server-core/src/codec/`, `server/server-core/tests/`, and `app/packages/remote_protocol/`. `git show --stat HEAD~1` touches only `server/`. `git show --stat HEAD` touches only `app/remote_control/`. No commit spans two of those groups.
8. `git log --oneline -3` shows, top to bottom: the client commit, the server commit, the contract commit.
9. Scope fence: `git diff --stat HEAD~3..HEAD -- extension/ installer/ dist/ app/remote_control/pubspec.yaml server/server-windows/Cargo.toml server/Cargo.lock` produces NO output.
10. `git status` is clean — no stray corrupted fixture left over from the task-1 red-proof step.
</verification>

<success_criteria>
- Two fingers moving apart zooms the PC in; two fingers moving together zooms it out; both work identically on the full Trackpad screen and in the floating window.
- Two-finger scroll and two-finger tap are behaviourally unchanged, and the pinch/scroll decision is made once at the slop crossing and locked for the episode.
- The wire carries zoom as `[0x03][dx f32 LE][dy f32 LE]` with `dx` reserved, pinned by two golden fixtures that BOTH codecs decode and re-encode byte-for-byte.
- Ctrl is never held across a pinch — it is pressed and released inside one input-thread arm.
- The scroll-direction preference does not invert zoom.
- Zoom has its own sub-pixel accumulator, is pause-gated with the other binary frames, and seeds no momentum.
- Exactly THREE commits — contract, server, client — none spanning two subsystems.
- Suites: Rust 208, Dart protocol 13, Flutter 609 + N.
</success_criteria>

<artifacts_produced>
**Commit 1 — contract**
- `OP_ZOOM` / `MouseFrame::Zoom` (Rust), `opZoom` / `encodeZoom` (Dart) — the codec halves of opcode `0x03`.
- `protocol/fixtures/mouse-binary/07-zoom-in.json`, `08-zoom-out.json` — new golden fixtures.
- `fixture_test.dart`'s mouse-binary driver — both two-way ternaries replaced with three-way, no-silent-fallback dispatch.
- SPEC §2 gains a `1.7` row; §9 gains the `0x03` opcode and its reserved-`dx` semantics; §11's drop list names the three binary kinds explicitly.

**Commit 2 — server**
- `MouseKeys::zoom` — new trait method (no default body); implemented by `MockMouseKeys` (recording `Call::Zoom`) and `EnigoMouseKeys` (forwarding `Cmd::Zoom`).
- `Cmd::Zoom` + `zoom_acc` + the Ctrl-wheel arm in `input_thread.rs`.
- `SERVER_PROTO_VERSION` `"1.6"` → `"1.7"`.

**Commit 3 — client**
- `ZoomIntent(dz)` — new sealed-hierarchy member; `_Phase.pinching`; the spread-vs-translation arbitration.
- `kZoomUnitPerPx`, `kPinchDominanceRatio`, `kPinchMinSpreadPx` — new tunables, `tuning.dart` only.
- `TrackpadDriver.onSendZoom`, `MoveSender.sendZoom`, `ConnectionService.sendZoom` — the new volatile send seam, wired once in `TrackpadCore`.
</artifacts_produced>

<output>
Create `.planning/quick/260731-euq-add-pinch-zoom-to-trackpad-binary-opcode/SUMMARY.md` when done.

The SUMMARY must record:
- The corrected compatibility claim from `<critical_finding>` — an old server DROPS `0x03` and stays alive, so the carry-forward is "pinch is silently absent until the server ships", not "it breaks". State plainly that the server exe must ship alongside the APK in the next release.
- The `fixture_test.dart` two-way-ternary hazard that would have made the Dart half of the contract blind to zoom, and that it was fixed and proven red-then-green.
- The stale `remote_protocol` `protoVersion = '1.1'` finding, deliberately left unfixed and why.
- The T-euq-02 sticky-Ctrl edge case, accepted and unmitigated.
- That no PAD requirement covers pinch zoom, so `REQUIREMENTS.md` was intentionally not touched.
- The exact final Flutter test count.
</output>
