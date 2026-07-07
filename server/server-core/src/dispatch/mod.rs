//! Message dispatch: auth gate → pause gate → family routing, plus
//! dispatcher-owned held-input tracking (CONN-07).
//!
//! Gate order is fixed (SPEC §6, §11): parse → auth state → pause → route.
//! Pre-auth, ONLY `hello`/`pin`/`auth` are processed; everything else —
//! including binary frames and `ping` — is silently dropped (no probing
//! oracle, threat T-01-09). The auth gate is structural: [`AuthState`] is an
//! explicit argument of the routing layer, not ambient state.

pub mod held;
pub mod router;

/// Per-connection handshake FSM state (SPEC §3).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AuthState {
    /// Fresh connection: only `hello` is processed.
    AwaitingHello,
    /// `challenge` sent: only `pin` / `auth` are processed.
    AwaitingAuth,
    /// Session authenticated: full registry available.
    Authed,
}
