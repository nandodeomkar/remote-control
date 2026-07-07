//! Typed codec errors (SPEC §1 strictness, §9 strict binary decode).

use thiserror::Error;

/// Errors produced by the binary and JSON codecs.
///
/// Decode paths reachable from wire input are Result-typed by contract
/// (threat T-01-07): no panicking parse path may be reachable from bytes an
/// unauthenticated peer controls.
#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum CodecError {
    /// Binary frame length != 9 bytes (SPEC §9).
    #[error("bad binary frame length: {0} bytes (expected exactly 9)")]
    BadLength(usize),

    /// Binary frame opcode is not 0x01 (move) or 0x02 (scroll) (SPEC §9).
    #[error("unknown binary opcode: {0:#04x}")]
    UnknownOpcode(u8),

    /// dx or dy is NaN / +Inf / -Inf (SPEC §9 strict decode).
    #[error("non-finite f32 value in binary frame")]
    NonFinite,

    /// Text frame is not valid JSON or not an object envelope (SPEC §1).
    #[error("malformed JSON frame: {0}")]
    BadJson(String),

    /// A spec-required field is absent (SPEC §1: hard decode error, D-05).
    #[error("missing required field: {0}")]
    MissingField(String),

    /// A hex-encoded wire field failed to decode as hex.
    #[error("invalid hex encoding")]
    BadHex,
}
