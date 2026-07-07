//! Token issue + hashing (SPEC §4, §12): tokens are stored ONLY as SHA-256
//! hashes; the raw token crosses the wire exactly once (`pairOk`).

/// A freshly issued token: the raw hex to hand to the phone once, plus the
/// SHA-256 hash — the ONLY form the server persists (threat T-01-08).
pub struct IssuedToken {
    /// 64 lowercase hex chars encoding 32 CSPRNG bytes.
    pub raw_hex: String,
    /// SHA-256 of the raw token bytes — used directly as the HMAC
    /// verification key (SPEC §4).
    pub hash: [u8; 32],
}

/// Generate a fresh 32-byte CSPRNG token.
pub fn issue_token() -> IssuedToken {
    todo!("implemented in plan 01-04 (auth wave)")
}

/// SHA-256 of raw token bytes (the stored form AND the HMAC key).
pub fn hash_token(raw: &[u8]) -> [u8; 32] {
    todo!("implemented in plan 01-04 (auth wave)")
}
