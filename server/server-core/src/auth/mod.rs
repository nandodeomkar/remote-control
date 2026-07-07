//! Pairing, token, and challenge-response auth state machine (SPEC §3–§5).
//!
//! Lockout state lives HERE (keyed by source IP), never on the session — it
//! must survive disconnect/reconnect. Tokens are stored ONLY as SHA-256
//! hashes (threat T-01-08); the raw token exists in memory solely to be
//! handed to the phone once at pairing (`pairOk`).

pub mod challenge;
pub mod pin;
pub mod token;

use std::net::IpAddr;

use pin::PinOutcome;

/// Owns pairing state (active PIN + expiry), attempt/lockout tables, the
/// stored token hash, and per-connection challenge nonces.
///
/// Shared across sessions as `Arc<std::sync::Mutex<AuthManager>>` (see
/// [`crate::transport::ServerDeps`]).
pub struct AuthManager {}

impl AuthManager {
    /// Create a manager with no stored pairing and empty lockout tables.
    pub fn new() -> Self {
        todo!("implemented in plan 01-04 (auth wave)")
    }

    /// Start a pairing window: generate a fresh 6-digit zero-padded PIN
    /// (CSPRNG), valid for [`pin::PIN_TTL_SECS`]. Returns the PIN string so
    /// the host UI (or a test) can display it.
    pub fn begin_pairing(&mut self) -> String {
        todo!("implemented in plan 01-04 (auth wave)")
    }

    /// Verify a submitted PIN against the active pairing window, enforcing
    /// expiry, per-source attempt limits, per-IP lockout, and the global
    /// failure cap (SPEC §5).
    pub fn verify_pin(&mut self, pin: &str, source: IpAddr) -> PinOutcome {
        todo!("implemented in plan 01-04 (auth wave)")
    }

    /// Complete a successful pairing: issue a fresh 32-byte token, store
    /// ONLY its SHA-256 hash, and return the raw token hex (64 lowercase)
    /// for the one-time `pairOk` delivery (SPEC §3a, §12).
    pub fn complete_pairing(&mut self) -> String {
        todo!("implemented in plan 01-04 (auth wave)")
    }

    /// Issue a fresh 32-byte CSPRNG challenge nonce for this connection
    /// (SPEC §3 — never reused).
    pub fn issue_challenge(&mut self) -> [u8; 32] {
        todo!("implemented in plan 01-04 (auth wave)")
    }

    /// Verify an `auth` proof: recompute HMAC-SHA256 with the STORED hash as
    /// key over `nonce` and compare against `mac_hex` in constant time
    /// (SPEC §4). Returns `false` when no pairing is stored.
    pub fn verify_auth(&self, nonce: &[u8], mac_hex: &str) -> bool {
        todo!("implemented in plan 01-04 (auth wave)")
    }
}
