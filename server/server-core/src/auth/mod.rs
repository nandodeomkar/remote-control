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
use std::time::{SystemTime, UNIX_EPOCH};

use pin::{PinOutcome, PinState};
use tokio::sync::watch;

/// A single paired device: its stored token hash plus the metadata the
/// settings paired-device list and config persistence need (D-04). Stores
/// the SHA-256 hash ONLY — there is deliberately NO raw-token field
/// (threat T-01-08 / T-01-17).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PairedDevice {
    /// SHA-256 of the raw token — the ONLY persisted token form, used
    /// directly as the HMAC verification key.
    pub hash: [u8; 32],
    /// The phone's `hello.device` name, recorded at pairing for the
    /// settings multi-device list (D-04).
    pub name: String,
    /// Unix seconds when this device completed pairing (D-04).
    pub paired_at: u64,
}

impl PairedDevice {
    /// Construct a paired-device record from its hash, name, and pairing
    /// time (unix seconds).
    pub fn new(hash: [u8; 32], name: String, paired_at: u64) -> Self {
        Self { hash, name, paired_at }
    }
}

/// The result of a successful named pairing: the raw token hex to hand the
/// phone ONCE (`pairOk`) plus the stored hash so the caller can correlate the
/// delivery. The raw hex is a return value only — it is never retained by
/// [`AuthManager`] (threat T-01-08).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PairingResult {
    /// 64 lowercase hex chars encoding the 32-byte token — for the one-time
    /// `pairOk` delivery.
    pub token_hex: String,
    /// SHA-256 of the raw token bytes — the stored form.
    pub hash: [u8; 32],
}

/// Owns pairing state (active PIN + expiry), attempt/lockout tables, the
/// stored paired-device records, and the active challenge nonce.
///
/// Shared across sessions as `Arc<std::sync::Mutex<AuthManager>>` (see
/// [`crate::transport::ServerDeps`]).
pub struct AuthManager {
    /// PIN window + per-IP lockout table (`HashMap<IpAddr, Instant>`) +
    /// global failure counter. Lives HERE, not on any session type, so
    /// lockout survives disconnect/reconnect (threat T-01-19).
    pin: PinState,
    /// Paired-device records — each carries a SHA-256 hash ONLY, never raw
    /// tokens (threat T-01-17). Seeded from `config.toml` at startup
    /// (Phase 7 D-01) and mutated by pairing/revoke.
    paired: Vec<PairedDevice>,
    /// Most recently issued challenge nonce (fresh per `issue_challenge`).
    active_nonce: Option<[u8; 32]>,
    /// Change-signal: bumped on EVERY paired-set mutation so the composition
    /// root can subscribe (via [`AuthManager::changes`]) and re-serialize
    /// `config.toml`. Starts at 0.
    changes_tx: watch::Sender<u64>,
}

impl Default for AuthManager {
    fn default() -> Self {
        Self::new()
    }
}

impl AuthManager {
    /// Create a manager with no stored pairing and empty lockout tables.
    pub fn new() -> Self {
        Self::from_paired(Vec::new())
    }

    /// Create a manager seeded with previously-paired device records — the
    /// restore path used at startup after decoding `config.toml` (D-01).
    /// Lockout tables start empty (lockout is per-run, not persisted).
    pub fn from_paired(records: Vec<PairedDevice>) -> Self {
        Self {
            pin: PinState::new(),
            paired: records,
            active_nonce: None,
            changes_tx: watch::Sender::new(0),
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
    /// ONLY its SHA-256 hash under a default `"phone"` name, and return the
    /// raw token hex (64 lowercase) for the one-time `pairOk` delivery
    /// (SPEC §3a, §12). Signature preserved for callers that do not thread
    /// the phone's `hello.device` name; see [`Self::complete_pairing_named`].
    pub fn complete_pairing(&mut self) -> String {
        self.complete_pairing_named("phone".to_owned()).token_hex
    }

    /// Complete a successful pairing recording the phone's `name` (its
    /// `hello.device`) and the pairing time. Stores ONLY the SHA-256 hash
    /// (threat T-01-08), bumps the change-signal (D-01 config re-serialize),
    /// and returns the raw token hex + hash as a [`PairingResult`] — the raw
    /// hex is never retained.
    pub fn complete_pairing_named(&mut self, name: String) -> PairingResult {
        let issued = token::issue_token();
        self.paired
            .push(PairedDevice::new(issued.hash, name, now_unix()));
        self.bump_changes();
        // The raw hex leaves in the return value only — AuthManager keeps no
        // raw-token field (threat T-01-17).
        PairingResult { token_hex: issued.raw_hex, hash: issued.hash }
    }

    /// Whether at least one device has completed pairing (a record is
    /// stored). The composition root uses this to stop refreshing the pairing
    /// PIN once a phone is paired (WR-01) and for smart startup (D-03).
    pub fn is_paired(&self) -> bool {
        !self.paired.is_empty()
    }

    /// Remove every paired record matching `hash`, bump the change-signal,
    /// and report whether anything was removed (D-05). A revoked hash then
    /// fails all future auth: [`Self::verify_auth_hash`] returns `None`.
    pub fn revoke(&mut self, hash: &[u8; 32]) -> bool {
        let before = self.paired.len();
        self.paired.retain(|d| &d.hash != hash);
        let removed = self.paired.len() != before;
        if removed {
            self.bump_changes();
        }
        removed
    }

    /// The stored token hashes only — for the session revoke-branch
    /// membership check (07-05).
    pub fn paired_hashes(&self) -> Vec<[u8; 32]> {
        self.paired.iter().map(|d| d.hash).collect()
    }

    /// The full paired-device records — for config serialization (07-07) and
    /// the settings paired list (07-08).
    pub fn paired_records(&self) -> &[PairedDevice] {
        &self.paired
    }

    /// Subscribe to the paired-set change-signal. The returned [`watch::Receiver`]
    /// observes an increment on EVERY paired mutation (pairing / revoke); the
    /// composition root re-serializes `config.toml` on each bump (D-01).
    pub fn changes(&self) -> watch::Receiver<u64> {
        self.changes_tx.subscribe()
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
        self.verify_auth_hash(nonce, mac_hex).is_some()
    }

    /// Like [`Self::verify_auth`] but returns the FIRST stored hash whose HMAC
    /// verifies, so a session can record WHICH hash authed it — the revoke
    /// branch (D-05) checks that hash for continued membership. Returns
    /// `None` when no stored hash verifies (including the no-pairing case).
    pub fn verify_auth_hash(&self, nonce: &[u8], mac_hex: &str) -> Option<[u8; 32]> {
        self.paired
            .iter()
            .find(|d| challenge::verify_mac(&d.hash, nonce, mac_hex))
            .map(|d| d.hash)
    }

    /// Advance the change-signal by one — called on every paired-set
    /// mutation. `send_modify` bumps the value even with no live receivers.
    fn bump_changes(&self) {
        self.changes_tx.send_modify(|v| *v += 1);
    }
}

/// Current unix time in whole seconds, saturating to 0 before the epoch —
/// never panics (a backwards clock must not crash the auth path).
fn now_unix() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
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
