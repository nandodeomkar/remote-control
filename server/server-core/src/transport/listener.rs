//! Accept-loop internals: TCP accept → `set_nodelay(true)` →
//! `accept_async_with_config` (64 KB message/frame caps, SPEC §13) → spawn
//! session task.
//!
//! Implemented in plan 01-06 (transport wave). Not part of the public API —
//! everything external goes through [`super::run`].
