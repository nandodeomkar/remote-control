//! PIN pairing rules (SPEC §5): 60s expiry, 5 attempts, 5-minute per-IP
//! lockout, discretionary global failure cap.

/// Seconds a displayed PIN stays valid.
pub const PIN_TTL_SECS: u64 = 60;
/// Wrong attempts allowed before lockout.
pub const PIN_MAX_ATTEMPTS: u32 = 5;
/// Per-source-IP lockout duration after exhausting attempts.
pub const LOCKOUT_SECS: u64 = 300;
/// Global failure cap across ALL sources (LAN attackers rotate IPs freely).
pub const GLOBAL_FAIL_CAP: u32 = 20;

/// Result of a PIN verification attempt (maps onto the `authFail` reason
/// enum, SPEC §5).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PinOutcome {
    /// PIN correct: proceed to `complete_pairing`.
    Ok,
    /// Wrong PIN; `attempts_remaining` before lockout (`pinInvalid`).
    WrongPin { attempts_remaining: u32 },
    /// The 60-second window elapsed (`pinExpired`).
    Expired,
    /// Source is locked out; seconds until retry allowed (`lockedOut`).
    LockedOut { retry_after_secs: u64 },
    /// No pairing window is active (`noPairing`).
    NoPairing,
}
