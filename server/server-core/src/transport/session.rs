//! Per-connection session task internals: read loop → codec →
//! `dispatch::router` behind the auth/pause gates, write half fed by an mpsc
//! queue, and the UNSKIPPABLE post-loop cleanup that releases held input
//! (CONN-07 — structured so cleanup runs after the loop exits on clean
//! close, socket error, and abort alike).
//!
//! Implemented in plan 01-06 (transport wave). Not part of the public API —
//! everything external goes through [`super::run`].
