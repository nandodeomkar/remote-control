//! Token issue + hashing (SPEC §4, §12): tokens are stored ONLY as SHA-256
//! hashes; the raw token crosses the wire exactly once (`pairOk`).

use rand::Rng;
use sha2::{Digest, Sha256};

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
    // ThreadRng is a CSPRNG (T-01-18): Rng::fill_bytes, never a
    // timestamp/xorshift seed.
    let mut raw = [0u8; 32];
    rand::rng().fill_bytes(&mut raw);
    IssuedToken { raw_hex: hex::encode(raw), hash: hash_token(&raw) }
}

/// SHA-256 of raw token bytes (the stored form AND the HMAC key).
pub fn hash_token(raw: &[u8]) -> [u8; 32] {
    Sha256::digest(raw).into()
}

#[cfg(test)]
mod tests {
    use sha2::{Digest, Sha256};

    use super::*;

    #[test]
    fn issued_raw_hex_is_64_lowercase_hex_chars() {
        let t = issue_token();
        assert_eq!(t.raw_hex.len(), 64, "32 bytes -> 64 hex chars");
        assert!(
            t.raw_hex
                .bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b)),
            "raw_hex must be lowercase hex, got {:?}",
            t.raw_hex
        );
    }

    #[test]
    fn issued_hash_is_sha256_of_raw_bytes() {
        let t = issue_token();
        let raw = hex::decode(&t.raw_hex).expect("raw_hex decodes");
        let expected: [u8; 32] = Sha256::digest(&raw).into();
        assert_eq!(t.hash, expected, "hash must be SHA-256(raw token bytes)");
        assert_eq!(t.hash, hash_token(&raw), "hash_token must agree");
    }

    #[test]
    fn two_issued_tokens_differ() {
        let a = issue_token();
        let b = issue_token();
        assert_ne!(a.raw_hex, b.raw_hex, "CSPRNG tokens must not repeat");
        assert_ne!(a.hash, b.hash);
    }
}
