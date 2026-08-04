//! Source-level guards over `extension/background.js`.
//!
//! The extension is the ONLY tier that can see bookmark URLs and the only tier
//! that can destroy a bookmark, so several of phase 11's hard rules cash out as
//! invariants about that one JS file. This repo has no JS test runner, and
//! adding one would mean a `package.json`, a lockfile and a dependency tree for
//! the sake of four string assertions — a straight violation of the phase's
//! zero-new-packages posture (T-11-SC). So the guards live here instead, inside
//! the existing `cargo test --workspace` gate, where CI already looks.
//!
//! These tests read source text. They are deliberately crude: they cannot prove
//! the extension is correct, only that four specific dangerous shapes are
//! absent. Do not weaken them — each one is the last automated line behind a
//! decision that has no undo path at runtime.

use std::fs;

/// The extension source, resolved from the crate manifest so the tests are
/// immune to the harness cwd (same idiom as `tests/fixtures.rs`'s
/// `FIXTURES_ROOT`): server/server-core -> up 2 = repo root.
const EXT_BACKGROUND: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../../extension/background.js");
const EXT_MANIFEST: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../../extension/manifest.json");

/// Read a file or fail loudly with the path — a moved/renamed extension must
/// break these guards rather than silently pass over a missing file.
fn read(path: &str) -> String {
    fs::read_to_string(path).unwrap_or_else(|e| panic!("cannot read {path}: {e}"))
}

/// The CODE lines of `extension/background.js` — every line whose trimmed form
/// does not start with `//` (line comment) or `*` (block-comment continuation).
///
/// Comment stripping is MANDATORY grep hygiene here, not a nicety. The file is
/// expected to DOCUMENT that `removeTree` is banned and that the hardcoded id
/// `"1"` is forbidden, naming both so a future reader understands the rule. A
/// naive whole-file scan would make that documentation self-invalidating: the
/// clearer the comment, the redder the test.
fn ext_code_lines() -> String {
    read(EXT_BACKGROUND)
        .lines()
        .filter(|l| {
            let t = l.trim_start();
            !t.starts_with("//") && !t.starts_with('*')
        })
        .collect::<Vec<_>>()
        .join("\n")
}

#[test]
fn extension_never_calls_remove_tree() {
    let code = ext_code_lines();
    assert!(
        !code.contains("removeTree"),
        "D-14 VIOLATION: extension/background.js calls chrome.bookmarks.removeTree.\n\
         The ban on removeTree is the ONLY thing that makes a phone-driven subtree \
         wipe structurally impossible. bm.remove must call chrome.bookmarks.remove \
         and nothing else, so at most one bookmark or one EMPTY folder can be \
         destroyed per command — Chrome itself rejects a non-empty folder. Chrome \
         offers no undo path the phone can reach and the phone offers no undo of \
         its own, so a recursive delete here is unrecoverable data loss on the \
         owner's machine. If you need to delete a folder's contents, delete the \
         children one command at a time from the phone."
    );
}

#[test]
fn extension_never_hardcodes_bookmarks_bar_id() {
    let code = ext_code_lines();
    for forbidden in ["parentId: \"1\"", "parentId:\"1\"", "parentId: '1'", "parentId:'1'"] {
        assert!(
            !code.contains(forbidden),
            "D-10 VIOLATION: extension/background.js hardcodes the bookmarks-bar \
             parent id ({forbidden}).\n\
             Chrome does not guarantee root numbering is stable across profiles, so \
             a hardcoded id files every new bookmark into the wrong folder with no \
             error anywhere. Resolve the root through bookmarksBarId(), which walks \
             chrome.bookmarks.getTree() and matches folderType === \"bookmarks-bar\" \
             — the stable documented enum. Do NOT substitute a title match either: \
             root titles are localized and \"Bookmarks bar\" does not exist on a \
             German or Japanese Chrome."
        );
    }
}

#[test]
fn extension_bm_elements_carry_no_url() {
    let code = ext_code_lines();
    // FORBIDDEN: any `url` member on an element object. Both snapshot builders
    // name their element variable `el`, so `el.url` (or its bracket forms) is
    // exactly the shape that would put a URL on the wire — and §7 says no url
    // ever crosses the phone-facing wire (T-11-03).
    //
    // LEGITIMATE and deliberately NOT matched by this assertion:
    //   * `tab.url`   — read to compute the favicon and the bookmarked flag
    //   * `n.url`     — read in buildBmSnapshot into the module-local bmUrlSet
    //   * `node.url`  — read in the bm.open arm before chrome.tabs.create
    //   * `url: tab.url` / `url: node.url` — arguments to Chrome APIs
    //     (bookmarks.create, bookmarks.search, tabs.create), which never leave
    //     the machine
    // Keep this list narrow. Widening the assertion to a bare "url" would trip
    // on every legitimate read above and the next author would delete the test
    // instead of fixing the bug it exists to catch.
    for forbidden in ["el.url", "el[\"url\"]", "el['url']"] {
        assert!(
            !code.contains(forbidden),
            "T-11-03 VIOLATION: extension/background.js puts a url on a snapshot \
             element ({forbidden}).\n\
             Neither a TabEl nor a BmEl may ever carry a url — SPEC §7. Bookmark \
             URLs are a more durable profile of the owner than a live tab list is, \
             and the whole bm.* design keeps URL resolution extension-side \
             precisely so none of them reach the phone. The bookmark URL set must \
             stay in the module-local bmUrlSet, which never crosses the wire."
        );
    }
}

/// protoVersion 1.8 / D-18 / SC7: the extension must answer `ext.reload` by
/// calling `chrome.runtime.reload()`.
///
/// Source-text, like its siblings, because the failure it guards is silent.
/// The server sends the nudge whether or not this arm exists, and the guard is
/// keyed on the target version — so a missing arm produces no error, no retry
/// and no log line anywhere. The only symptom is a version mismatch on the
/// phone's Updates screen that never resolves.
#[test]
fn extension_reloads_itself_on_command() {
    let code = ext_code_lines();

    assert!(
        code.contains("case \"ext.reload\""),
        "extension/background.js has no `ext.reload` arm in its switch (msg.t).\n\
         SC7 depends on it: after a PC update replaces {{app}}\\extension, the \
         server compares the extension's getManifest().version against its own \
         and sends ONE ext.reload. Without this arm that nudge lands in the \
         default branch and is silently ignored — the extension keeps running \
         the old code, no error is raised on either side, and the only visible \
         symptom is a version mismatch on the phone's Updates screen that never \
         clears. The server will not ask again: the guard is once per target \
         version per process run, deliberately, so this arm is the whole \
         mechanism."
    );

    assert!(
        code.contains("chrome.runtime.reload"),
        "extension/background.js never calls chrome.runtime.reload().\n\
         An `ext.reload` arm that does anything else does not satisfy D-18: \
         re-reading the extension's files from disk is the entire point, and it \
         is the only Chrome API that does it without the user opening \
         chrome://extensions. Reconnecting the socket, re-sending ext.hello or \
         re-running the snapshot walk all leave the OLD code running."
    );
}

#[test]
fn extension_declares_bookmarks_permission() {
    let manifest: serde_json::Value = serde_json::from_str(&read(EXT_MANIFEST))
        .unwrap_or_else(|e| panic!("extension/manifest.json is not valid JSON: {e}"));
    let permissions = manifest["permissions"]
        .as_array()
        .expect("extension/manifest.json must declare a `permissions` array");
    assert!(
        permissions.iter().any(|p| p == "bookmarks"),
        "extension/manifest.json does not declare the \"bookmarks\" permission, but \
         background.js depends on chrome.bookmarks for the snapshot walk and all \
         four bm.* commands.\n\
         Without it the namespace is undefined at runtime: no bm.state frame is \
         ever sent, the server keeps BookmarksState.connected false, and the phone \
         shows the install hint forever while the extension still looks connected. \
         Declared permissions: {permissions:?}"
    );
}
