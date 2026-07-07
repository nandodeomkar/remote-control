//! Wire-protocol codecs (SPEC §1, §9).
//!
//! Pure functions only — no session state, no I/O. Fixture-tested in
//! isolation against `protocol/fixtures/` (D-09).

pub mod binary;
pub mod json;
