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

use pin::{PinOutcome, PinState};

/// Owns pairing state (active PIN + expiry), attempt/lockout tables, the
/// stored token hashes, and the active challenge nonce.
///
/// Shared across sessions as `Arc<std::sync::Mutex<AuthManager>>` (see
/// [`crate::transport::ServerDeps`]).
pub struct AuthManager {
    /// PIN window + per-IP lockout table (`HashMap<IpAddr, Instant>`) +
    /// global failure counter. Lives HERE, not on any session type, so
    /// lockout survives disconnect/reconnect (threat T-01-19).
    pin: PinState,
    /// Paired-device token hashes — SHA-256 ONLY, never raw tokens
    /// (threat T-01-17). In-memory for Phase 1; config persistence is
    /// Phase 7.
    paired_hashes: Vec<[u8; 32]>,
    /// Most recently issued challenge nonce (fresh per `issue_challenge`).
    active_nonce: Option<[u8; 32]>,
}

impl AuthManager {
    /// Create a manager with no stored pairing and empty lockout tables.
    pub fn new() -> Self {
        Self {
            pin: PinState::new(),
            paired_hashes: Vec::new(),
            active_nonce: None,
        }
    }

    /// Start a pairing window: generate a fresh 6-digit zero-padded PIN
    /// (CSPRNG), valid for [`pin::PIN_TTL_SECS`]. Returns the PIN string so
    /// the host UI (or a test) can display it.
    pub fn begin_pairing(&mut self) -> String {
        self.pin.begin()
    }

    /// Verify a submitted PIN against the active pairing window, enforcing
    /// expiry, per-source attempt limits, per-IP lockout, and the global
    /// failure cap (SPEC §5).
    pub fn verify_pin(&mut self, pin: &str, source: IpAddr) -> PinOutcome {
        self.pin.verify(pin, source)
    }

    /// Complete a successful pairing: issue a fresh 32-byte token, store
    /// ONLY its SHA-256 hash, and return the raw token hex (64 lowercase)
    /// for the one-time `pairOk` delivery (SPEC §3a, §12).
    pub fn complete_pairing(&mut self) -> String {
        let issued = token::issue_token();
        self.paired_hashes.push(issued.hash);
        // The raw hex leaves this scope immediately — AuthManager keeps no
        // raw-token field (threat T-01-17).
        issued.raw_hex
    }

    /// Whether at least one device has completed pairing (a token hash is
    /// stored). The composition root uses this to stop refreshing the pairing
    /// PIN once a phone is paired (WR-01).
    pub fn is_paired(&self) -> bool {
        !self.paired_hashes.is_empty()
    }

    /// Issue a fresh 32-byte CSPRNG challenge nonce for this connection
    /// (SPEC §3 — never reused).
    pub fn issue_challenge(&mut self) -> [u8; 32] {
        let nonce = challenge::new_nonce();
        self.active_nonce = Some(nonce);
        nonce
    }

    /// Verify an `auth` proof: recompute HMAC-SHA256 with the STORED hash as
    /// key over `nonce` and compare against `mac_hex` in constant time
    /// (SPEC §4). Returns `false` when no pairing is stored.
    pub fn verify_auth(&self, nonce: &[u8], mac_hex: &str) -> bool {
        self.paired_hashes
            .iter()
            .any(|hash| challenge::verify_mac(hash, nonce, mac_hex))
    }
}

#[cfg(test)]
mod tests {
    //! AuthManager wiring tests: challenge nonce lifecycle and the full
    //! pair -> proof -> verify round trip using ONLY the stored hash.

    use super::challenge::auth_proof;
    use super::AuthManager;

    #[test]
    fn issue_challenge_yields_fresh_nonces() {
        let mut auth = AuthManager::new();
        let a = auth.issue_challenge();
        let b = auth.issue_challenge();
        assert_ne!(a, b, "challenge nonces must never be reused (SPEC section 3)");
    }

    #[test]
    fn pair_then_prove_then_verify_round_trip() {
        let mut auth = AuthManager::new();
        let raw_hex = auth.complete_pairing();
        assert_eq!(raw_hex.len(), 64, "pairOk token is 64 lowercase hex chars");

        let nonce = auth.issue_challenge();
        // Client-side: derives the key from the RAW token it was handed.
        let mac = auth_proof(&hex::decode(&raw_hex).unwrap(), &nonce);
        // Server-side: verifies from the stored hash alone.
        assert!(auth.verify_auth(&nonce, &mac));
    }

    #[test]
    fn verify_auth_rejects_wrong_mac() {
        let mut auth = AuthManager::new();
        let _raw = auth.complete_pairing();
        let nonce = auth.issue_challenge();
        let bogus = "0".repeat(64);
        assert!(!auth.verify_auth(&nonce, &bogus));
    }

    #[test]
    fn is_paired_flips_after_complete_pairing() {
        let mut auth = AuthManager::new();
        assert!(!auth.is_paired(), "no pairing stored at construction");
        let _raw = auth.complete_pairing();
        assert!(auth.is_paired(), "a stored token hash means paired");
    }

    #[test]
    fn verify_auth_without_pairing_is_false() {
        let mut auth = AuthManager::new();
        let nonce = auth.issue_challenge();
        let mac = auth_proof(b"any raw token", &nonce);
        assert!(!auth.verify_auth(&nonce, &mac), "empty hash table must verify nothing");
    }
}
