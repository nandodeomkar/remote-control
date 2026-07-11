//! Golden-fixture harness — the Rust half of phase success criterion 1.
//!
//! Loads the EXACT files in `protocol/fixtures/` (per-language copies are
//! forbidden, D-09) and drives the codec + auth contracts against them.
//! Fixture directories are enumerated at runtime: adding a fixture file
//! automatically extends coverage.
//!
//! RED by design in Wave 2 (codec and auth bodies are `todo!()`); plans
//! 01-03/01-04 make these green. Do not weaken assertions.
//!
//! Test names are load-bearing — later plans use them as cargo test
//! filters: `codec_fixtures_mouse_binary`, `codec_fixtures_handshake`,
//! `codec_fixtures_text`, `auth_proof_fixture`.

use std::fs;
use std::path::{Path, PathBuf};

use serde_json::Value;

use server_core::codec::{binary, json as json_codec};
use server_core::error::CodecError;

/// Fixture root resolved from the crate manifest — immune to test cwd
/// (RESEARCH Pattern 1): server/server-core → up 2 = repo root.
const FIXTURES_ROOT: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../../protocol/fixtures");

/// Enumerate every `*.json` fixture in a family directory, sorted by name.
fn fixture_files(family: &str) -> Vec<PathBuf> {
    let dir = Path::new(FIXTURES_ROOT).join(family);
    let mut files: Vec<PathBuf> = fs::read_dir(&dir)
        .unwrap_or_else(|e| panic!("cannot read fixture dir {}: {e}", dir.display()))
        .map(|entry| entry.expect("readable dir entry").path())
        .filter(|p| p.extension().is_some_and(|ext| ext == "json"))
        .collect();
    files.sort();
    assert!(!files.is_empty(), "no fixtures found in {}", dir.display());
    files
}

/// Load one fixture file as a JSON value.
fn load(path: &Path) -> Value {
    let text = fs::read_to_string(path)
        .unwrap_or_else(|e| panic!("cannot read fixture {}: {e}", path.display()));
    serde_json::from_str(&text)
        .unwrap_or_else(|e| panic!("fixture {} is not valid JSON: {e}", path.display()))
}

#[test]
fn codec_fixtures_mouse_binary() {
    for path in fixture_files("mouse-binary") {
        let name = path.file_name().unwrap().to_string_lossy().into_owned();
        let fixture = load(&path);

        let wire_hex = fixture["wire"]
            .as_str()
            .unwrap_or_else(|| panic!("{name}: binary wire must be a hex string"));
        let bytes =
            hex::decode(wire_hex).unwrap_or_else(|e| panic!("{name}: bad wire hex: {e}"));
        let expect = &fixture["expect"];

        if expect["error"].as_bool() == Some(true) {
            assert!(
                binary::decode(&bytes).is_err(),
                "{name}: decode must fail (SPEC section 9 strict decode)"
            );
            continue;
        }

        let frame =
            binary::decode(&bytes).unwrap_or_else(|e| panic!("{name}: decode failed: {e}"));
        let (op, dx, dy) = match frame {
            binary::MouseFrame::Move { dx, dy } => ("move", dx, dy),
            binary::MouseFrame::Scroll { dx, dy } => ("scroll", dx, dy),
        };
        assert_eq!(op, expect["op"].as_str().unwrap(), "{name}: op mismatch");
        // Fixture floats are f32-exact by construction: EXACT equality,
        // no epsilon comparison anywhere.
        assert_eq!(dx, expect["dx"].as_f64().unwrap() as f32, "{name}: dx mismatch");
        assert_eq!(dy, expect["dy"].as_f64().unwrap() as f32, "{name}: dy mismatch");

        let reencoded = binary::encode(&frame);
        assert_eq!(
            reencoded.as_slice(),
            bytes.as_slice(),
            "{name}: encode(decode(wire)) must reproduce the original 9 bytes"
        );
    }
}

/// Shared driver for the JSON text-frame families (`handshake/`, `text/`).
///
/// Skips `05-auth-proof.json` by filename — it has no `wire` field (special
/// format; covered by `auth_proof_fixture`). Ignores any `compute` block
/// (Dart-only diff-helper concern).
fn run_json_family(family: &str) {
    for path in fixture_files(family) {
        let name = path.file_name().unwrap().to_string_lossy().into_owned();
        if name == "05-auth-proof.json" {
            continue;
        }
        let fixture = load(&path);

        let wire = serde_json::to_string(&fixture["wire"])
            .unwrap_or_else(|e| panic!("{name}: cannot re-serialize wire object: {e}"));
        let expect = &fixture["expect"];

        // Version rejection is the SERVER's job, not the codec's (D-06):
        // a major-version-2 hello must DECODE fine; the integration suite
        // covers the server-side err{versionMismatch} + close behavior.
        if expect["reason"].as_str() == Some("versionMismatch") {
            assert!(
                json_codec::decode_text(&wire).is_ok(),
                "{name}: codec must decode a version-mismatched hello (server rejects it later)"
            );
            continue;
        }

        if expect["error"].as_bool() == Some(true) {
            let err = json_codec::decode_text(&wire)
                .expect_err(&format!("{name}: decode must fail (missing required field, D-05)"));
            if name == "09-auth-missing-mac.json" {
                assert!(
                    matches!(err, CodecError::MissingField(_)),
                    "{name}: must fail with MissingField, got: {err:?}"
                );
            }
            continue;
        }

        let decoded = json_codec::decode_text(&wire)
            .unwrap_or_else(|e| panic!("{name}: decode failed: {e}"));
        let reencoded = json_codec::encode_msg(&decoded.msg, decoded.seq);
        let reencoded: Value = serde_json::from_str(&reencoded)
            .unwrap_or_else(|e| panic!("{name}: encode_msg produced invalid JSON: {e}"));
        // Order-insensitive canonical comparison via serde_json::Value —
        // this is what proves D-05 unknown-field dropping on 01-hello-ok.
        assert_eq!(
            reencoded, *expect,
            "{name}: encode(decode(wire)) must equal the canonical expect envelope"
        );
    }
}

#[test]
fn codec_fixtures_handshake() {
    run_json_family("handshake");
}

#[test]
fn codec_fixtures_text() {
    run_json_family("text");
}

#[test]
fn codec_fixtures_volume() {
    run_json_family("volume");
}

#[test]
fn codec_fixtures_window_info() {
    // protocol 1.2 (APPS-02/APPS-03): the with-icon-path fixture round-trips
    // all four WindowInfo fields and drops an unknown per-window field (D-05);
    // the legacy fixture decodes with icon/path None and re-encodes without
    // the optional keys.
    run_json_family("window_info");
}

#[test]
fn auth_proof_fixture() {
    let path = Path::new(FIXTURES_ROOT).join("handshake/05-auth-proof.json");
    let fixture = load(&path);

    let token = hex::decode(fixture["input"]["tokenHex"].as_str().expect("input.tokenHex"))
        .expect("tokenHex must be valid hex");
    let nonce = hex::decode(fixture["input"]["nonceHex"].as_str().expect("input.nonceHex"))
        .expect("nonceHex must be valid hex");
    let mac_hex = fixture["expect"]["macHex"].as_str().expect("expect.macHex");

    // Client-side construction: HMAC key = SHA-256(raw token), msg = nonce.
    // macHex was computed by independent .NET crypto — the cross-language
    // byte-identity anchor (SPEC section 4).
    assert_eq!(
        server_core::auth::challenge::auth_proof(&token, &nonce),
        mac_hex,
        "auth_proof must reproduce the independently computed mac byte-identically"
    );

    // Server-side verification: the STORED hash is the HMAC key directly.
    let stored_hash = server_core::auth::token::hash_token(&token);
    assert!(
        server_core::auth::challenge::verify_mac(&stored_hash, &nonce, mac_hex),
        "verify_mac must accept the fixture mac against the stored token hash"
    );
}
