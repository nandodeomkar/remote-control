# Binary Mouse Frame Layout (protoVersion 1.7)

Binary WebSocket frames carry the mouse hot path only. Every frame is **exactly 9 bytes**:

```
[opcode u8][dx f32 LE][dy f32 LE]
```

## Byte-offset table

| Offset | Size (bytes) | Field | Type | Semantics |
|--------|--------------|-------|------|-----------|
| 0 | 1 | `opcode` | unsigned 8-bit | `0x01` = move, `0x02` = scroll, `0x03` = zoom |
| 1 | 4 | `dx` | IEEE-754 binary32, **little-endian** | Relative X delta |
| 5 | 4 | `dy` | IEEE-754 binary32, **little-endian** | Relative Y delta |

Total: 9 bytes. No padding, no trailing data.

## Opcodes

| Opcode | Meaning | dx / dy semantics |
|--------|---------|-------------------|
| `0x01` | move | Relative cursor delta in pixels (client sensitivity pre-applied) |
| `0x02` | scroll | Relative scroll delta (positive dy = scroll down convention decided by executor) |
| `0x03` | zoom (protoVersion 1.7) | `dy` = zoom delta in wheel units, **positive = zoom in**. `dx` is **reserved**: carried through the codec unchanged so round-trips stay byte-exact, but ignored by the executor. Clients SHOULD send `dx = 0.0` |

All other opcode values are invalid and MUST be rejected at decode.

## Strict decode rules (SPEC §9)

1. Frame length ≠ 9 bytes → decode error.
2. Unknown opcode (anything other than `0x01`/`0x02`/`0x03`) → decode error.
3. Non-finite f32 (`NaN`, `+Inf`, `-Inf`) in `dx` or `dy` → decode error.
4. Errored frames are dropped and counted; never routed to an executor, never fatal to the session.

## Notes

- Frames are fire-and-forget at input rate (~60–120 Hz); the server never acknowledges them.
- Pre-auth binary frames are silently dropped by the auth gate (SPEC §6).
- In fixtures (`protocol/fixtures/mouse-binary/`), the `wire` field is the frame's bytes as a **lowercase hex string** (18 hex chars for 9 bytes).
- Fixture float values are chosen exactly representable in f32 so decoded `dx`/`dy` compare exactly in both languages — no epsilon logic anywhere.
