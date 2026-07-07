//! OS-agnostic server core for Remote Control.
//!
//! This crate owns the wire-protocol codecs (`codec`), the pairing/auth state
//! machine (`auth`), message routing with auth/pause gates and held-input
//! tracking (`dispatch`), the five OS-abstraction executor traits plus their
//! recording mocks (`executors`), and the WebSocket transport (`transport`).
//!
//! Contract: zero Windows dependencies. OS-specific executor implementations
//! live in a sibling crate (Phase 2+); this crate is fully testable on any OS
//! against `executors::mock`.
//!
//! The public API surface in this crate is the Wave-2 contract of phase
//! 01-protocol-contract-server-core: signatures are final, bodies are
//! `todo!()` until Waves 3–4 implement them (plans 01-03..01-06).

pub mod auth;
pub mod codec;
pub mod dispatch;
pub mod error;
pub mod executors;
pub mod transport;

pub use error::CodecError;
pub use transport::run;
