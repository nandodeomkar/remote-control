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
            binary::MouseFrame::Zoom { dx, dy } => ("zoom", dx, dy),
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

/// Fixture files that are NOT standard `{wire, expect}` wire fixtures and must
/// therefore be skipped by [`run_json_family`]. Each has its own bespoke loader
/// (`auth_proof_fixture`, `version_compare_matches_fixture`) or belongs to a
/// consumer outside this harness entirely (the release-feed parsers, 12-06 and
/// 12-10).
///
/// Keyed by `(family, filename)` rather than by filename alone: a bare name
/// list would silently skip a future `text/10-*.json` that IS a wire fixture,
/// which is the same silent-zero-coverage failure the hard-registration rule
/// below exists to prevent.
const SPECIAL_CASE_FIXTURES: &[(&str, &str)] = &[
    ("handshake", "05-auth-proof.json"),
    ("update", "10-version-compare.json"),
    ("update", "11-releases-latest.json"),
    ("update", "12-releases-latest-null-digest.json"),
];

/// Shared driver for the JSON text-frame families (`handshake/`, `text/`, …).
///
/// Skips the [`SPECIAL_CASE_FIXTURES`] by `(family, filename)` — those have no
/// `{wire, expect}` envelope. Ignores any `compute` block (Dart-only
/// diff-helper concern). Returns the number of fixtures actually exercised, so
/// a caller can pin the family's file count.
fn run_json_family(family: &str) -> usize {
    let mut exercised = 0usize;
    for path in fixture_files(family) {
        let name = path.file_name().unwrap().to_string_lossy().into_owned();
        if SPECIAL_CASE_FIXTURES.contains(&(family, name.as_str())) {
            continue;
        }
        exercised += 1;
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
    exercised
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
fn codec_fixtures_input_blocked() {
    // protocol 1.3 (07-02, SRV-05/D-07): the additive S→C input.blocked push
    // round-trips reason=="elevated" and drops the unknown `future` field on
    // re-encode (D-05) — the same shared fixture the Dart harness exercises.
    run_json_family("input_blocked");
}

#[test]
fn codec_fixtures_tabs() {
    // protocol 1.4 (BROW-01): the tabs.* family — tabs.changed round-trips
    // two TabEls (icon present + absent, unknown `future` field dropped per
    // D-05), the never-connected tabs.list reply shape, tabs.activate/close
    // round trips, and the missing-required-id negative. Hard-registered:
    // neither harness globs directories (07-02 lesson).
    run_json_family("tabs");
}

#[test]
fn codec_fixtures_bookmarks() {
    // protocol 1.6 (phase 11): the bm.* family — bm.changed round-trips
    // three BmEls (folder + plain link + truncated folder, unknown `future`
    // field dropped per D-05), the dual bm.list request/reply shape in both
    // directions, the four command payloads with nodeId as a STRING and
    // tabId as a NUMBER, and the two missing-required-field negatives.
    // Hard-registered: neither harness globs directories (the 07-02
    // input.blocked lesson), so without this function the nine golden files
    // would be silently untested — zero coverage AND zero failures.
    run_json_family("bookmarks");
}

#[test]
fn codec_fixtures_update() {
    // protocol 1.8 (phase 12): the update.* family — the empty update.check
    // request, the full update.status with its nested D-12 lastUpdate object
    // (unknown `future` key dropped per D-05) and the minimal never-connected
    // twin, the one-field update.apply that IS the D-14 rule, the three
    // update.progress shapes (pct on `downloading` only, `error` on `failed`
    // only, `uptodate` with nothing else), and the two missing-required-field
    // negatives. Hard-registered: neither harness globs directories (the 07-02
    // input.blocked lesson), so without this function the nine golden files
    // would be silently untested — zero coverage AND zero failures.
    //
    // The directory is MIXED-KIND: files 10-12 are special cases with no
    // {wire, expect} envelope and are excluded via SPECIAL_CASE_FIXTURES.
    // Pinning the count keeps that exclusion honest — dropping a wire fixture
    // into the skip list by mistake turns this test red instead of quietly
    // shrinking coverage.
    let exercised = run_json_family("update");
    assert_eq!(
        exercised, 9,
        "the update family has exactly nine wire fixtures (01-09); \
         10-12 are special cases with their own loaders"
    );
}

#[test]
fn version_compare_matches_fixture() {
    // SPECIAL CASE (protocol 1.8, D-26): 10-version-compare.json has no
    // {wire, expect} envelope — it is a cross-language truth table, and this
    // is its bespoke loader. The phone's Dart comparator loads the SAME file
    // and must agree case-for-case: a disagreement never shows as a test
    // failure, it shows in the field as a phone offering an update the server
    // then refuses as `stale`.
    let path = Path::new(FIXTURES_ROOT).join("update/10-version-compare.json");
    let fixture = load(&path);
    let cases = fixture["cases"]
        .as_array()
        .expect("10-version-compare.json must carry a `cases` array");
    assert!(!cases.is_empty(), "the truth table must not be empty");

    for case in cases {
        let a = case["a"].as_str().expect("case.a must be a string");
        let b = case["b"].as_str().expect("case.b must be a string");
        let expect = case["expect"].as_str().expect("case.expect must be a string");
        let why = case["why"].as_str().unwrap_or("");
        let actual = server_core::version::compare_versions(a, b);
        assert_eq!(
            actual.as_str(),
            expect,
            "compare_versions({a:?}, {b:?}) == {:?}, fixture says {expect:?} — {why}",
            actual.as_str()
        );
    }
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
