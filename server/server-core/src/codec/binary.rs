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
    todo!("implemented in plan 01-03 (codec wave)")
}

/// Encode a frame to its exact 9-byte wire form (little-endian f32 pair).
///
/// `encode(&decode(wire)?)` must reproduce `wire` byte-for-byte for every
/// valid frame (golden-fixture round-trip contract).
pub fn encode(frame: &MouseFrame) -> [u8; 9] {
    todo!("implemented in plan 01-03 (codec wave)")
}
