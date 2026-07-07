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

/// Fresh 32-byte CSPRNG nonce — one per connection, never reused (SPEC §3).
pub fn new_nonce() -> [u8; 32] {
    todo!("implemented in plan 01-04 (auth wave)")
}

/// Client-side proof (used by tests and fixture verification): derive the
/// HMAC key as SHA-256(`raw_token`), MAC the `nonce`, return 64 lowercase
/// hex.
pub fn auth_proof(raw_token: &[u8], nonce: &[u8]) -> String {
    todo!("implemented in plan 01-04 (auth wave)")
}

/// Server-side verify: HMAC the `nonce` with `stored_hash` as key and
/// compare to `mac_hex` in constant time (`Mac::verify_slice`). Malformed
/// hex returns `false`, never panics.
pub fn verify_mac(stored_hash: &[u8; 32], nonce: &[u8], mac_hex: &str) -> bool {
    todo!("implemented in plan 01-04 (auth wave)")
}
