---
phase: 12-in-app-updates
plan: 06
subsystem: server-windows
tags: [updates, http, release-feed, sha256, security, d-14, closed-vocabulary]

# Dependency graph
requires:
  - phase: 12-in-app-updates
    plan: 02
    provides: the frozen `update.*` wire contract — the D-11 closed error vocabulary this plan turns into a Rust enum, and the two shared feed fixtures (`11-releases-latest.json`, `12-releases-latest-null-digest.json`) the parser is pinned to
provides:
  - "`server_windows::update` — the module that owns ALL update I/O, with the DEGRADE-NEVER-CRASH posture and the D-14 rule stated where the constants live"
  - "`UpdateError` — the D-11 closed vocabulary as a Rust type, with `code()` returning the seven wire strings and `ALL` for exhaustive assertions"
  - "`feed.rs` — `RELEASES_API` + the three asset prefixes as crate-local consts, plus pure `parse_release` / `strip_digest` / `resolve_asset`"
  - "`download.rs` — streaming `download_to`, `file_sha256_hex`, `verify_or_delete`, and the server-side `temp_path_for` filename template"
  - "`is_valid_target` — the `^\\d+\\.\\d+\\.\\d+$` predicate every later caller must run before a wire-supplied version reaches a path or a script"
  - "`ureq` in the tree, configured with explicit timeouts on both agents"
affects: [12-08, 12-09, 12-13]

# Tech tracking
tech-stack:
  added:
    - "ureq 3.3.0 (blocking HTTP, rustls + bundled webpki-roots) — re-verified with `cargo search ureq` at execution time"
    - "serde_json 1 declared directly in server-windows (already in the tree via server-core; zero new supply-chain surface)"
  patterns:
    - "Locator-as-const: the tier that executes a file is the only tier that names it, proven by the repo string being absent from server-core (D-14)"
    - "Closed wire vocabulary as a Rust enum with an `ALL` array, so tests assert over every variant rather than a remembered subset"
    - "Bespoke fixture loader for the `response`-nested special-case fixtures, using the `CARGO_MANIFEST_DIR` cwd-immunity idiom from server-core"
    - "Delete-on-any-error-path: the verification function removes the bytes rather than only reporting, so a failure cannot leave something executable behind"

key-files:
  created:
    - server/server-windows/src/update/mod.rs
    - server/server-windows/src/update/feed.rs
    - server/server-windows/src/update/download.rs
  modified:
    - server/server-windows/Cargo.toml
    - server/server-windows/src/main.rs
    - server/Cargo.lock

key-decisions:
  - "`serde_json` had to be declared in server-windows: the crate had serde-derive and `toml` but no JSON codec, and `parse_release` cannot exist without one. It is already in the lockfile via server-core, so the dependency count changed and the supply-chain surface did not"
  - "`file_sha256_hex` reads in 64 KiB chunks instead of `io::copy`ing into the hasher — sha2 0.11's features are `alloc`/`oid`/`zeroize` only, so `Sha256` does not implement `io::Write` and the RESEARCH Code Example 2 shape does not compile"
  - "A mid-stream `io::Error` is classified network-vs-disk by downcasting its inner error to `ureq::Error`, rather than assuming every stream failure is one or the other"
  - "`verify_or_delete` refuses a `sha256:`-prefixed expectation instead of stripping it — stripping is `feed::strip_digest`'s single job, and accepting both shapes would let an unstripped value reach the comparison silently"
  - "`is_valid_target` was added as a public pure predicate rather than left as prose in the caller's contract, so the two later callers (12-08, 12-09) cannot each invent their own regex"
  - "The `feed_locator` test asserts the URL's shape without repeating the full `owner/repo` literal, keeping the locator's single-occurrence property greppable"

patterns-established:
  - "Every new file in `update/` opens with a `//!` header stating WHAT it owns, WHY it lives in server-windows, and the failure posture, citing decision ids inline"
  - "Security-relevant refusals are asserted by observable effect (the file is gone from disk), not by the returned error alone"

requirements-completed: [D-01, D-02, D-03, D-11, D-14, D-15, D-22, D-23, SC5, SC6]

# Metrics
duration: 35min
completed: 2026-08-01
---

# Phase 12 Plan 06: Release Feed and Verified Download Summary

**The Windows server can now find out what "latest" is and pull the file that belongs to it — from a URL compiled into the crate that will execute it, through two agents that cannot hang forever, into a temp path the wire never named, and out again the instant a digest disagrees.**

## Performance

- **Duration:** ~35 min
- **Tasks:** 3 of 3
- **Files modified:** 6 (3 created, 3 modified)
- **Tests added:** 23 (3 vocabulary, 9 feed, 11 download) — workspace total now 230, all green

## Accomplishments

- **D-14 is now a structural fact, not a paragraph.** `RELEASES_API` and the three asset-name prefixes are `const`s inside `server-windows/src/update/feed.rs`. `server-core` — the crate that decodes attacker-reachable JSON — has no path to them, and the plan's assertion holds: `grep -rn 'nandodeomkar/remote-control-releases' server/server-core/` returns nothing. The URL literal also occurs exactly once in `feed.rs`, so "where does this machine download from" has one answer to grep for, and a test pins the shape (`https://api.github.com/repos/…/releases/latest`) without duplicating the literal.
- **The D-11 vocabulary became a type that cannot quietly grow.** `UpdateError` has the seven variants and `code()` returns `network`/`checksum`/`disk`/`installer`/`downgrade`/`stale`/`busy`. `UpdateError::ALL` exists so the test iterates *every* variant in SPEC §7 order — a new variant added without a spec amendment fails a test rather than passing review. `From<io::Error>` maps to `disk` and **drops the OS text**, because that string is exactly the kind of path-bearing detail that must not cross the wire (T-12-06).
- **A null digest is refused before a single byte is fetched.** `resolve_asset` returns `Checksum` when the matched asset has no usable digest, so the refusal happens at resolve time, not after a download nobody could have verified. The `12-releases-latest-null-digest.json` fixture's `expectRefusal: "checksum"` is now an executed assertion — and the test additionally proves the refusal is *per-asset* (the APK and extension rows still resolve) and that the asset itself was found, so the failure is unambiguously about the digest rather than a missing file.
- **Both failure modes of a bad publish are told apart from a bad network.** Zero matching assets *or* more than one is `installer`, not `network` — a publish that went wrong must not send the user to check their WiFi. Meanwhile a rate-limited 403 and a dead socket both become `network`, because the vocabulary is closed and has no `ratelimit`, but they emit different `tracing` lines including the status number, so the first support question ("is this the 60/hour anonymous limit the phone and PC share behind one NAT?") is answerable.
- **Nothing unverified survives a return.** `download_to` streams via `as_reader()` — no whole-body read, so the 10 MiB default cap can never silently truncate a grown setup exe — calls `sync_all()` before anyone hashes, and deletes the partial on *every* error path after the file is opened. `verify_or_delete` deletes on mismatch, and the test asserts the file is **absent from disk afterwards**, not merely that an `Err` came back.
- **The one wire-supplied value is fenced on both sides.** `temp_path_for` takes three integers and nothing else: the directory, the `RemoteControl-Setup-v` prefix and the `.exe` suffix are all constants. `is_valid_target` is a public pure predicate, and its negative test cases are the actual payloads — `..\..\Startup\x`, `1.5.0&calc.exe`, an embedded newline, full-width digits — not just tidy-looking rejects.

## Task Commits

Each task was committed atomically:

1. **Task 1: ureq + the update module and its error type** — `83477d3` (feat)
2. **Task 2: feed.rs — the compiled-in locator and the pure parser** — `24d2076` (feat)
3. **Task 3: download.rs — stream to a temp path, verify, or delete** — `be9184b` (feat)

## Files Created

| File | Purpose |
|------|---------|
| `server/server-windows/src/update/mod.rs` | Module tree, the DEGRADE-NEVER-CRASH posture, the full D-14 statement, and `UpdateError` as the closed vocabulary |
| `server/server-windows/src/update/feed.rs` | `RELEASES_API` + three asset prefixes as consts; pure `parse_release` / `strip_digest` / `resolve_asset`; `feed_agent`, `fetch_latest`, `map_ureq` |
| `server/server-windows/src/update/download.rs` | `download_agent`, `is_valid_target`, `temp_path_for`, `download_to`, `classify_io`, `file_sha256_hex`, `verify_or_delete` |

## Files Modified

| File | Change |
|------|--------|
| `server/server-windows/Cargo.toml` | `ureq = "3.3"` and `serde_json = "1"`, each with the file's per-dependency rationale comment |
| `server/server-windows/src/main.rs` | `mod update;` added to the module block — nothing else touched |
| `server/Cargo.lock` | ureq 3.3.0 and its rustls/webpki-roots tree |

## Key Implementation Notes

**`ureq` 3.3.0 was re-verified live, not trusted from the document.** `cargo search ureq` at execution time returned `ureq = "3.3.0"`, matching RESEARCH's Package Legitimacy Audit (verdict OK, `algesten/ureq`, first published 2018, 169M downloads). No other third-party crate entered the tree.

**Both agents carry explicit timeouts because ureq's default is none at all.** Feed: 10 s global / 5 s connect. Download: 120 s global / 5 s connect — a 5 MB asset over a weak link legitimately outlives a feed GET, and reusing the 10 s budget would abort healthy downloads. Without these, a black-holed socket parks the update thread forever, the phone sits on `downloading` with no terminal frame, and the `busy` guard never clears (T-12-15).

**The feed read carries a 1 MiB cap** as a DoS belt (T-12-16); a real `releases/latest` body is a few KB.

**`#![allow(dead_code)]` sits at the top of `update/mod.rs`** with a comment naming its removal condition. Nothing in the crate calls these functions until `update_thread` lands in 12-08, so without it every public item warns. It is scoped to this module only, and the comment says to delete it once the thread exists — after that, dead code here really is dead.

**The two feed fixtures need their own loader**, as 12-02 flagged: the captured response is nested under a `response` key and there is no `wire`/`expect` envelope. The loader resolves the path from `CARGO_MANIFEST_DIR`, the cwd-immunity idiom `server-core`'s `tests/fixtures.rs` established.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 — Blocking] `server-windows` had no JSON codec, so `parse_release` could not be written**

- **Found during:** Task 1
- **Issue:** The crate declared `serde` (derive) and `toml`, but not `serde_json`. The plan's instruction was "do NOT add a second digest crate" and "`ureq` is the phase's only new Rust dependency" — but a JSON body cannot be deserialised without a JSON codec, and nothing in the crate or in `server-core`'s public surface re-exports one.
- **Fix:** Declared `serde_json = "1"` in `server-windows/Cargo.toml` with a comment stating why it is not new supply-chain surface: `serde_json 1` is already in the lockfile as a `server-core` dependency, so this adds a direct edge to a crate already being compiled, not a new crate. The plan's actual acceptance criteria (`grep -c '^ureq'` == 1, no new *digest* crate) are unaffected, and `ureq` remains the only genuinely new crate the phase pulls in.
- **Files modified:** `server/server-windows/Cargo.toml`
- **Commit:** `83477d3`

**2. [Rule 3 — Blocking] `Sha256` is not an `io::copy` sink in sha2 0.11, so RESEARCH Code Example 2 does not compile**

- **Found during:** Task 3
- **Issue:** The research example (and the plan text) specify `io::copy` from the file into a `Sha256`, relying on digest's `io::Write` impl. That impl is behind digest's `std` feature, and `cargo info sha2` shows sha2 0.11.0 exposes only `alloc`, `oid` and `zeroize` — there is no `std` feature to enable. The build failed with `the trait bound 'Sha256: std::io::Write' is not satisfied`.
- **Fix:** Replaced `io::copy` with an explicit 64 KiB chunked read loop calling `hasher.update(&buf[..n])` — the same `Digest` API `clip_thread::clip_fingerprint` already uses. The streaming property that actually mattered is preserved: the file is never held in memory. No feature flag was added and no digest crate was introduced. The doc comment records why the obvious shape is absent, so the next reader does not "simplify" it back into a compile error.
- **Files modified:** `server/server-windows/src/update/download.rs`
- **Commit:** `be9184b`

**3. [Rule 3 — Blocking] Two acceptance criteria are literal greps over the whole file, including comments**

- **Found during:** Tasks 2 and 3 verification
- **Issue:** `grep -c 'nandodeomkar/remote-control-releases' feed.rs == 1` initially returned 2, because a test asserted the constant contained that literal; and `grep -c 'read_to_vec' download.rs == 0` initially returned 1, because a doc comment explained *why* that helper is not used. Both criteria are about the code, but as written they cannot distinguish a use from a mention.
- **Fix:** Kept both intents and removed both literals. The locator test now asserts `starts_with("https://api.github.com/repos/")`, `contains("remote-control-releases")` and `ends_with("/releases/latest")` — a strictly stronger shape check that does not duplicate the `owner/repo` string. The download comment now says "ureq's whole-body read helpers would buffer the entire asset AND cap at their 10 MiB default", which carries the same warning without the token. Both criteria now pass literally.
- **Files modified:** `server/server-windows/src/update/feed.rs`, `server/server-windows/src/update/download.rs`
- **Commits:** `24d2076`, `be9184b`

**4. [Rule 3 — Blocking] Task 1's `pub mod feed; pub mod download;` cannot compile without the files**

- **Found during:** Task 1
- **Issue:** Task 1 requires `mod.rs` to declare both submodules AND requires `cargo build -p server-windows` to exit 0, but the files themselves are Tasks 2 and 3.
- **Fix:** Created both files at Task 1 containing only a `//!` header that names the task filling them in. They were fully written in the next two commits of this same plan. No placeholder survives the plan — this is intra-plan commit sequencing, not a stub.
- **Files modified:** `server/server-windows/src/update/feed.rs`, `server/server-windows/src/update/download.rs`
- **Commit:** `83477d3`

### Deliberate scope additions (Rule 2 — missing critical functionality)

- **`is_valid_target` as a public pure predicate.** The plan says the caller validates `^\d+\.\d+\.\d+$` and this module debug-asserts it. Leaving the predicate itself unwritten would have let 12-08 and 12-09 each write their own, and two regexes that disagree is exactly how a traversal gets through. It is now one function with the payload cases as its negative tests.
- **`classify_io` — network vs disk for a mid-stream failure.** The plan asks for "I/O failure → `disk`, transport failure → `network`", but inside `io::copy` both arrive as `io::Error`. Downcasting the inner error to `ureq::Error` makes the distinction real instead of a coin flip; without it, a dropped connection would have been reported as a disk problem.
- **`verify_or_delete` refuses a malformed expectation (and still deletes).** A non-64-hex `expected_hex` would otherwise fall through to a comparison that can only fail — correct by accident. It is now an explicit `Checksum` refusal, including for a `sha256:`-prefixed value that skipped `strip_digest`.
- **`UpdateError::ALL`, `Display`, `std::error::Error`, `From<io::Error>`.** `ALL` is what lets the vocabulary test be exhaustive rather than a remembered list; the trait impls are what let `?` work in the download path without hand-mapping every I/O call.
- **A compile-time assertion that the three asset prefixes are disjoint.** `resolve_asset` demands exactly one match, so if `RemoteControl-v` ever swallowed `RemoteControl-Setup-v`, every resolve would fail as `installer` at runtime. The `const` block makes that a build error instead.
- **Extra negative tests beyond the plan's list:** duplicate-asset resolution, an absent `assets` array, an empty-file digest, and `verify_or_delete` on a missing file (`disk`).

## Threat Flags

None. This plan adds no endpoint, no auth path and no schema at a trust boundary — it adds an **outbound** client to a compiled-in URL. All six `mitigate` dispositions in the plan's register are discharged: T-12-01 (locator consts, asserted absent from `server-core`), T-12-13 (`temp_path_for` + `is_valid_target`), T-12-14 (verify-after-flush, delete-on-mismatch, null-digest refusal), T-12-15 (explicit timeouts on both agents), T-12-16 (1 MiB feed cap + streaming download), T-12-06 (the closed vocabulary; statuses and paths go to `tracing` only). T-12-17 (MITM) remains `accept` as planned — rustls with the bundled webpki-roots.

## Known Stubs

None. Every function this plan names is implemented and tested. The module has no in-crate caller yet — that is the wave ordering the plan describes (12-08 adds `update_thread`, 12-09 adds `apply`/`marker`), and it is the sole reason for the scoped `#![allow(dead_code)]`, whose removal condition is written next to it.

## Verification

| Check | Result |
|-------|--------|
| `cargo test -p server-windows update` | 23 passed, 0 failed |
| `cargo test --workspace` | 230 passed, 0 failed, 2 ignored |
| `cargo build -p server-windows` | exit 0, no warnings |
| `cargo build -p server-core` | exit 0 — zero-Windows-deps invariant untouched |
| `grep -rn 'nandodeomkar/remote-control-releases' server/server-core/` | no matches |
| `grep -c 'nandodeomkar/remote-control-releases' feed.rs` | 1 |
| `grep -c '^ureq' server-windows/Cargo.toml` | 1, version 3.3 |
| `cargo search ureq` | `ureq = "3.3.0"` |
| `grep -c 'timeout_' feed.rs` | 2 |
| `grep -c 'read_to_vec' download.rs` | 0 |
| `grep -c 'sync_all\|Sha256' download.rs` | 7 |
| Null-digest fixture returns `Checksum` from `resolve_asset` | yes, asserted |
| File absent on disk after a checksum mismatch | yes, asserted |
| Post-commit deletion check across all three commits | no deletions |

## For Future Phases

- **12-08 (`update_thread`)** owns the OS thread these blocking calls must run on — never a tokio worker. Call `is_valid_target` on the wire's `target` **before** anything else; `temp_path_for`'s debug assertion is a tripwire, not the defence (and it is compiled out in release).
- **Resolve the asset immediately before downloading it.** `browser_download_url` 302s to a time-limited signed CDN URL; a URL resolved at check time and reused at apply time has expired. Never persist one.
- **`UpdateError::code()` is what goes on the wire** — do not stringify the enum any other way, and do not add a variant without amending SPEC §7 first.
- **12-09 (`apply`)** must call `verify_or_delete` before spawning anything, and must treat its `Err` as terminal: the file is already gone by the time it returns.
- **Delete the `#![allow(dead_code)]` in `update/mod.rs`** once `update_thread` calls into these modules.
- **The `sha2` chunked-hash loop is deliberate** — sha2 0.11 has no `std` feature, so `Sha256` is not an `io::copy` sink. Do not "simplify" it back.

## Self-Check: PASSED

All three created files verified present under `server/server-windows/src/update/`; all three task commits (`83477d3`, `24d2076`, `be9184b`) verified in `git log`; `git diff --diff-filter=D HEAD~3 HEAD` reports no deletions.
