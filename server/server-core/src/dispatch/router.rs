//! Family routing behind the auth and pause gates (SPEC §6, §7, §10, §11).

use std::sync::Mutex;
use std::time::Instant;

use crate::auth::AuthManager;
use crate::codec::binary::MouseFrame;
use crate::codec::json::{Decoded, Msg};
use crate::dispatch::AuthState;
use crate::dispatch::held::HeldInput;
use crate::executors::Executors;

/// Maximum `text.bs` value; larger requests are rejected with
/// `err{code:"bsTooLarge"}` and not executed (SPEC §8).
pub const MAX_BS: u64 = 10000;

/// Mutable per-session routing context.
pub struct SessionCtx {
    /// Handshake FSM state — the structural auth gate (threat T-01-09).
    pub auth_state: AuthState,
    /// Held buttons/keys for CONN-07 release-on-session-end.
    pub held: HeldInput,
    /// Pending `power` action awaiting `confirm`: (action, requested-at).
    /// The confirm window is 10 seconds (SPEC §7).
    pub pending_power: Option<(String, Instant)>,
}

/// Route one decoded JSON message through the gates.
///
/// Behavior contract:
/// - Pre-auth: only `hello`/`pin`/`auth` are processed; everything else is
///   silently dropped — NO reply (SPEC §6).
/// - Paused: executor-bound messages are silently dropped; handshake and
///   `ping`/`pong` still work (SPEC §11).
/// - Unknown `t` post-auth: reply `err{unknownType}`, keep session (D-07).
///
/// Returns the messages the session must send back to the client (possibly
/// empty).
pub fn route(
    decoded: Decoded,
    ctx: &mut SessionCtx,
    exec: &Executors,
    auth: &Mutex<AuthManager>,
    paused: bool,
) -> Vec<Msg> {
    todo!("implemented in plan 01-05 (dispatch wave)")
}

/// Route one decoded binary mouse frame (fire-and-forget hot path).
///
/// Dropped silently unless `ctx.auth_state` is [`AuthState::Authed`] and not
/// `paused` (SPEC §6, §11). Never replies.
pub fn route_binary(frame: MouseFrame, ctx: &SessionCtx, exec: &Executors, paused: bool) {
    todo!("implemented in plan 01-05 (dispatch wave)")
}
