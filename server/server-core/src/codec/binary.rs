//! 9-byte binary mouse-frame codec (SPEC §9).
//!
//! Layout: `[opcode u8][dx f32 LE][dy f32 LE]` — exactly 9 bytes.
//! Strict decode: wrong length, unknown opcode, or non-finite f32 is a
//! [`CodecError`]; errored frames are dropped and counted by the caller,
//! never routed to an executor, and never terminate the session.

use crate::error::CodecError;

/// Opcode for a relative cursor move frame.
pub const OP_MOVE: u8 = 0x01;
/// Opcode for a relative scroll frame.
pub const OP_SCROLL: u8 = 0x02;

/// A decoded 9-byte binary mouse frame.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum MouseFrame {
    /// Relative cursor delta (opcode 0x01).
    Move { dx: f32, dy: f32 },
    /// Relative scroll delta (opcode 0x02).
    Scroll { dx: f32, dy: f32 },
}

/// Strictly decode a binary frame (SPEC §9).
///
/// Errors: [`CodecError::BadLength`] if `buf.len() != 9`,
/// [`CodecError::UnknownOpcode`] for any opcode other than
/// [`OP_MOVE`]/[`OP_SCROLL`], [`CodecError::NonFinite`] if `dx` or `dy` is
/// NaN or ±Inf.
pub fn decode(buf: &[u8]) -> Result<MouseFrame, CodecError> {
    // 1. Length check FIRST — everything below indexes into buf[0..9].
    if buf.len() != 9 {
        return Err(CodecError::BadLength(buf.len()));
    }

    // Infallible after the length check: buf[1..5] and buf[5..9] are
    // exactly 4 bytes each.
    let dx = f32::from_le_bytes(buf[1..5].try_into().expect("4-byte slice"));
    let dy = f32::from_le_bytes(buf[5..9].try_into().expect("4-byte slice"));

    // 2. Finite check BEFORE opcode dispatch (RESEARCH Code Example 1):
    // a non-finite payload is rejected regardless of opcode.
    if !dx.is_finite() || !dy.is_finite() {
        return Err(CodecError::NonFinite);
    }

    // 3. Opcode dispatch.
    match buf[0] {
        OP_MOVE => Ok(MouseFrame::Move { dx, dy }),
        OP_SCROLL => Ok(MouseFrame::Scroll { dx, dy }),
        op => Err(CodecError::UnknownOpcode(op)),
    }
}

/// Encode a frame to its exact 9-byte wire form (little-endian f32 pair).
///
/// `encode(&decode(wire)?)` must reproduce `wire` byte-for-byte for every
/// valid frame (golden-fixture round-trip contract).
pub fn encode(frame: &MouseFrame) -> [u8; 9] {
    let (op, dx, dy) = match *frame {
        MouseFrame::Move { dx, dy } => (OP_MOVE, dx, dy),
        MouseFrame::Scroll { dx, dy } => (OP_SCROLL, dx, dy),
    };
    let mut out = [0u8; 9];
    out[0] = op;
    out[1..5].copy_from_slice(&dx.to_le_bytes());
    out[5..9].copy_from_slice(&dy.to_le_bytes());
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Hand-build a 9-byte frame (independent of the golden fixtures).
    fn frame_bytes(op: u8, dx: f32, dy: f32) -> [u8; 9] {
        let mut b = [0u8; 9];
        b[0] = op;
        b[1..5].copy_from_slice(&dx.to_le_bytes());
        b[5..9].copy_from_slice(&dy.to_le_bytes());
        b
    }

    #[test]
    fn decode_move_exact() {
        let b = frame_bytes(OP_MOVE, 12.5, 100.0);
        assert_eq!(decode(&b).unwrap(), MouseFrame::Move { dx: 12.5, dy: 100.0 });
    }

    #[test]
    fn decode_scroll_exact() {
        let b = frame_bytes(OP_SCROLL, 0.0, -1.5);
        assert_eq!(decode(&b).unwrap(), MouseFrame::Scroll { dx: 0.0, dy: -1.5 });
    }

    #[test]
    fn rejects_bad_length_short() {
        assert_eq!(decode(&[0x01; 8]), Err(CodecError::BadLength(8)));
    }

    #[test]
    fn rejects_bad_length_long() {
        assert_eq!(decode(&[0x01; 10]), Err(CodecError::BadLength(10)));
    }

    #[test]
    fn rejects_empty() {
        assert_eq!(decode(&[]), Err(CodecError::BadLength(0)));
    }

    #[test]
    fn rejects_unknown_opcode() {
        let b = frame_bytes(0x7f, 1.0, 0.0);
        assert_eq!(decode(&b), Err(CodecError::UnknownOpcode(0x7f)));
    }

    #[test]
    fn rejects_nan_dx() {
        let b = frame_bytes(OP_MOVE, f32::NAN, 0.0);
        assert_eq!(decode(&b), Err(CodecError::NonFinite));
    }

    #[test]
    fn rejects_inf_dy() {
        let b = frame_bytes(OP_SCROLL, 0.0, f32::INFINITY);
        assert_eq!(decode(&b), Err(CodecError::NonFinite));
    }

    #[test]
    fn rejects_neg_inf_dx() {
        let b = frame_bytes(OP_MOVE, f32::NEG_INFINITY, 0.0);
        assert_eq!(decode(&b), Err(CodecError::NonFinite));
    }

    #[test]
    fn nonfinite_beats_unknown_opcode() {
        // Finite check happens BEFORE opcode dispatch: an unknown opcode
        // carrying NaN still reports NonFinite.
        let b = frame_bytes(0x7f, f32::NAN, 0.0);
        assert_eq!(decode(&b), Err(CodecError::NonFinite));
    }

    #[test]
    fn round_trip_negative_deltas() {
        let b = frame_bytes(OP_MOVE, -3.25, -0.5);
        let frame = decode(&b).unwrap();
        assert_eq!(encode(&frame), b);
    }
}
