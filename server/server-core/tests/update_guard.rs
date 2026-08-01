//! Source-level guards over the `update.*` types — the structural half of SC6.
//!
//! WHAT THEY OWN: the single rule that D-14 cashes out to, expressed so that
//! the compiler's test run enforces it rather than a reviewer remembering it.
//! `update.apply` carries a version string and NOTHING else; the server
//! resolves every asset URL and its sha256 ITSELF, from a repo constant
//! compiled into its own binary, in a crate the codec cannot see.
//!
//! WHY SOURCE TEXT: the property being defended is the ABSENCE of a field, and
//! absence has no runtime representation to assert on. A behavioural test can
//! only prove that the fields which exist behave; it cannot notice a new
//! `url: String` that a future plan adds "for convenience". So these guards
//! read `src/codec/json.rs` and `src/executors/mod.rs` as text and fail if a
//! locator-named field or parameter appears inside the update payload structs
//! or the `UpdateExecutor` trait. The style is `tests/extension_guard.rs`'s.
//!
//! FAILURE POSTURE: deliberately crude and deliberately loud. These tests
//! cannot prove the update path is safe — only that one specific catastrophic
//! shape is absent. **Do not weaken them.** A wire-supplied locator turns a
//! paired phone, or anything that ever obtained a token, into arbitrary code
//! execution on the owner's PC, and there is no undo for that at runtime.
//!
//! DOC COMMENTS ARE EXCLUDED FROM THE SCAN, and that exclusion is mandatory
//! rather than a nicety: the update types deliberately DOCUMENT that urls and
//! hashes are forbidden, naming them so a future reader understands the rule. A
//! naive whole-file scan would make that documentation self-invalidating — the
//! clearer the comment, the redder the test.

use std::fs;

/// Sources resolved from the crate manifest so the tests are immune to the
/// harness cwd (the `tests/fixtures.rs` idiom).
const JSON_CODEC: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/src/codec/json.rs");
const EXECUTORS: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/src/executors/mod.rs");

/// Substrings that must never appear in a field or parameter name reachable
/// from the wire. Case-insensitive.
///
/// `file` and `path` are here alongside the obvious three because a locator
/// does not have to be spelled `url` to be one: `assetName`, `fileName` and
/// `installerPath` are the same authority under a friendlier name.
const FORBIDDEN: &[&str] = &["url", "asset", "sha256", "digest", "hash", "file", "path"];

/// The blocks the scan covers: every `update.*` payload struct, the nested
/// `lastUpdate` object, and the trait whose signature is the narrowest point
/// the wire can reach.
const GUARDED_BLOCKS: &[(&str, &str)] = &[
    (JSON_CODEC, "pub struct UpdateCheckPayload"),
    (JSON_CODEC, "pub struct LastUpdatePayload"),
    (JSON_CODEC, "pub struct UpdateStatusPayload"),
    (JSON_CODEC, "pub struct UpdateApplyPayload"),
    (JSON_CODEC, "pub struct UpdateProgressPayload"),
    (EXECUTORS, "pub trait UpdateExecutor"),
];

/// Read a file or fail loudly with the path — a moved or renamed source must
/// break these guards rather than silently pass over a missing file.
fn read(path: &str) -> String {
    fs::read_to_string(path).unwrap_or_else(|e| panic!("cannot read {path}: {e}"))
}

/// The CODE lines of the block whose declaration starts with `header`: from the
/// opening `{` line through the first line whose trimmed form is exactly `}`,
/// with every comment line removed (`///`, `//!`, `//`, and `*` block-comment
/// continuations).
///
/// Panics if the block is not found — a renamed or deleted type must turn this
/// suite RED. Silently scanning nothing is precisely the failure mode that
/// would let the rule lapse unnoticed.
fn block_code_lines(path: &str, header: &str) -> String {
    let src = read(path);
    let mut lines = src.lines().skip_while(|l| !l.trim_start().starts_with(header));
    let opening = lines
        .next()
        .unwrap_or_else(|| panic!("{path}: no declaration starting with {header:?} — \
             the guarded type was renamed or removed; update GUARDED_BLOCKS, do not \
             delete the guard"));
    assert!(
        opening.contains('{'),
        "{path}: expected {header:?} to open its block on the same line"
    );
    // An empty struct closes on its declaration line (`pub struct Foo {}`).
    if opening.trim_end().ends_with("{}") {
        return String::new();
    }
    let mut body = Vec::new();
    for line in lines {
        if line.trim() == "}" {
            return body.join("\n");
        }
        let t = line.trim_start();
        if t.starts_with("//") || t.starts_with('*') {
            continue;
        }
        body.push(line);
    }
    panic!("{path}: block {header:?} is never closed by a line containing only `}}`");
}

#[test]
fn update_types_carry_no_locator_field() {
    for (path, header) in GUARDED_BLOCKS {
        let code = block_code_lines(path, header).to_lowercase();
        for forbidden in FORBIDDEN {
            assert!(
                !code.contains(forbidden),
                "D-14 VIOLATION: {header} in {path} contains a field or parameter \
                 naming {forbidden:?}.\n\
                 \n\
                 update.apply carries a VERSION STRING AND NOTHING ELSE. The server \
                 resolves the asset's download URL and its sha256 itself, from a repo \
                 constant compiled into its own binary, and never accepts, derives, or \
                 is influenced by a locator supplied over the wire. The target string \
                 is used for exactly two things — an equality check against the \
                 version the server just resolved as latest (mismatch => `stale`) and \
                 an ordering check against the running version (at-or-below => \
                 `downgrade`) — and is never concatenated into a URL or a filesystem \
                 path.\n\
                 \n\
                 A wire-supplied locator is REMOTE CODE EXECUTION ON THE PC: a paired \
                 phone, or anything that ever obtained a token, would choose which \
                 binary the machine downloads and runs. This is the strongest \
                 constraint in the protocol and it is not to be relaxed for \
                 convenience, now or later.\n\
                 \n\
                 If you are adding a field because the update flow needs more \
                 information, the answer is that the SERVER must resolve it. Do not \
                 widen the wire. Do not widen the trait. Do not delete this test.\n\
                 \n\
                 Offending block:\n{}",
                block_code_lines(path, header)
            );
        }
    }
}

#[test]
fn update_apply_payload_has_exactly_one_field() {
    let code = block_code_lines(JSON_CODEC, "pub struct UpdateApplyPayload");
    let fields: Vec<&str> = code
        .lines()
        .map(str::trim)
        .filter(|l| l.starts_with("pub ") && l.contains(':'))
        .collect();
    assert_eq!(
        fields.len(),
        1,
        "D-14 VIOLATION: UpdateApplyPayload declares {} fields, expected exactly 1 \
         (`target: String`).\n\
         \n\
         The one-field shape IS the security rule, not a coincidence of the current \
         feature set. protocol/fixtures/update/04-update-apply.json asserts the same \
         thing on the wire (its `p` has exactly one key) and \
         protocol/schema/messages.schema.json closes that one payload with \
         `additionalProperties: false` — the only payload in the whole schema that \
         suspends the D-05 ignore-unknown leniency. All three say the same thing on \
         purpose: no future field may narrow what the server would otherwise resolve \
         on its own.\n\
         \n\
         Declared fields: {fields:?}",
        fields.len()
    );
    assert!(
        fields[0].starts_with("pub target:"),
        "D-14: UpdateApplyPayload's single field must be `target`, found: {:?}",
        fields[0]
    );
}
