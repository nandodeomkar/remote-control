//! Challenge-response construction (SPEC §4, LOCKED):
//!
//! ```text
//! mac = HMAC-SHA256( key = SHA-256(raw token bytes), message = nonce bytes )
//! ```
//!
//! encoded as 64 lowercase hex. The server verifies with its STORED hash
//! directly as the HMAC key — it never has the raw token after pairing.
//! Cross-language proof: `protocol/fixtures/handshake/05-auth-proof.json`
//! (macHex computed by independent .NET crypto).

use hmac::{Hmac, KeyInit, Mac};
use rand::Rng;
use sha2::{Digest, Sha256};

type HmacSha256 = Hmac<Sha256>;

/// Fresh 32-byte CSPRNG nonce — one per connection, never reused (SPEC §3).
pub fn new_nonce() -> [u8; 32] {
    let mut nonce = [0u8; 32];
    rand::rng().fill_bytes(&mut nonce);
    nonce
}

/// Client-side proof (used by tests and fixture verification): derive the
/// HMAC key as SHA-256(`raw_token`), MAC the `nonce`, return 64 lowercase
/// hex.
pub fn auth_proof(raw_token: &[u8], nonce: &[u8]) -> String {
    let key = Sha256::digest(raw_token); // key = SHA-256(raw token) — LOCKED
    let mut mac = HmacSha256::new_from_slice(&key).expect("HMAC accepts any key length");
    mac.update(nonce);
    hex::encode(mac.finalize().into_bytes())
}

/// Server-side verify: HMAC the `nonce` with `stored_hash` as key and
/// compare to `mac_hex` in constant time (`Mac::verify_slice`). Malformed
/// hex returns `false`, never panics.
pub fn verify_mac(stored_hash: &[u8; 32], nonce: &[u8], mac_hex: &str) -> bool {
    // Defensive hex decode: attacker-controlled input, bad hex is a plain
    // rejection, never a panic.
    let Ok(received) = hex::decode(mac_hex) else {
        return false;
    };
    let mut mac = HmacSha256::new_from_slice(stored_hash).expect("HMAC accepts any key length");
    mac.update(nonce);
    // Mac::verify_slice is constant-time by construction (CtOutput,
    // T-01-15) — the ONLY comparison; no manual byte compare.
    mac.verify_slice(&received).is_ok()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::auth::token::hash_token;

    /// The cross-language byte-identity anchor (SPEC §4): macHex computed
    /// by independent .NET crypto, loaded from the shared fixture tree
    /// (per-language copies forbidden, D-09).
    const FIXTURE_PATH: &str = concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../protocol/fixtures/handshake/05-auth-proof.json"
    );

    fn fixture() -> (Vec<u8>, Vec<u8>, String) {
        let text = std::fs::read_to_string(FIXTURE_PATH).expect("fixture readable");
        let v: serde_json::Value = serde_json::from_str(&text).expect("fixture is JSON");
        let token = hex::decode(v["input"]["tokenHex"].as_str().expect("tokenHex")).unwrap();
        let nonce = hex::decode(v["input"]["nonceHex"].as_str().expect("nonceHex")).unwrap();
        let mac = v["expect"]["macHex"].as_str().expect("macHex").to_owned();
        (token, nonce, mac)
    }

    #[test]
    fn auth_proof_reproduces_fixture_mac_byte_identically() {
        let (token, nonce, mac_hex) = fixture();
        assert_eq!(
            auth_proof(&token, &nonce),
            mac_hex,
            "HMAC-SHA256(key = SHA-256(token), msg = nonce) must match the .NET-computed mac"
        );
    }

    #[test]
    fn verify_mac_accepts_fixture_mac_using_only_the_stored_hash() {
        let (token, nonce, mac_hex) = fixture();
        let stored = hash_token(&token);
        assert!(
            verify_mac(&stored, &nonce, &mac_hex),
            "server must verify with the stored hash directly — no raw token needed"
        );
    }

    #[test]
    fn verify_mac_rejects_a_single_flipped_hex_char() {
        let (token, nonce, mac_hex) = fixture();
        let stored = hash_token(&token);
        let mut flipped = mac_hex.into_bytes();
        flipped[0] = if flipped[0] == b'0' { b'1' } else { b'0' };
        let flipped = String::from_utf8(flipped).unwrap();
        assert!(!verify_mac(&stored, &nonce, &flipped));
    }

    #[test]
    fn verify_mac_rejects_non_hex_mac_without_panicking() {
        let (token, nonce, _) = fixture();
        let stored = hash_token(&token);
        assert!(!verify_mac(&stored, &nonce, "zz-not-hex-at-all"));
        assert!(!verify_mac(&stored, &nonce, ""));
    }

    #[test]
    fn verify_mac_rejects_mac_bound_to_a_stale_nonce() {
        // Replay defense (T-01-16): a proof computed for one nonce must
        // fail against any other nonce.
        let (token, nonce, mac_hex) = fixture();
        let stored = hash_token(&token);
        let other_nonce = new_nonce();
        assert_ne!(other_nonce.as_slice(), nonce.as_slice());
        assert!(!verify_mac(&stored, &other_nonce, &mac_hex));
    }

    #[test]
    fn new_nonce_yields_distinct_values() {
        assert_ne!(new_nonce(), new_nonce(), "CSPRNG nonces must not repeat");
    }
}
