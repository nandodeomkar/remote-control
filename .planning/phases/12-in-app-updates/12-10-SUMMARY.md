---
phase: 12-in-app-updates
plan: 10
subsystem: updates
tags: [dart, flutter, httpclient, sha256, crypto, github-releases, streaming, security]

# Dependency graph
requires:
  - phase: 12-in-app-updates (12-07)
    provides: version.dart SemVer/isNewer, update_cache.dart, update_format.dart
  - phase: 12-in-app-updates (12-08)
    provides: ApkInstaller MethodChannel with cacheDir() and the outcomes stream
  - phase: 12-in-app-updates (12-03)
    provides: the published v1.5.0 release on the public mirror (D-21), which is what the parser was diffed against
provides:
  - "kReleasesApi + kApkAssetPrefix / kSetupAssetPrefix / kExtensionAssetPrefix (Dart)"
  - "Release and ReleaseAsset value types with == and hashCode"
  - "parseRelease / stripDigest / assetWithPrefix — pure, total, fixture-pinned"
  - "fetchLatest({HttpClient? client}) — never throws, collapses every failure to null"
  - "downloadApk / sha256OfFile / verifyOrDelete — streamed, throttled, chunk-hashed, delete-on-failure"
  - "DownloadError closed vocabulary (network | disk | checksum)"
  - "test/update/fake_http.dart — offline dart:io HTTP fakes for the whole phase"
affects: [12-11, 12-12, 12-13, 12-14, 12-15, 12-18]

# Tech tracking
tech-stack:
  added: ["crypto ^3.0.7 (the phase's only new Dart package)"]
  patterns:
    - "SDK primitives over wrapper packages: dart:io HttpClient, not the pub http package"
    - "Injectable HttpClient + injectable destination Directory = fully offline tests"
    - "A hand-written Sink<Digest> instead of pulling in package:convert for AccumulatorSink"
    - "Grep-gated security invariants: the forbidden header/package names are not spelled in lib/"

key-files:
  created:
    - app/remote_control/lib/update/release_feed.dart
    - app/remote_control/lib/update/apk_download.dart
    - app/remote_control/test/update/release_feed_test.dart
    - app/remote_control/test/update/apk_download_test.dart
    - app/remote_control/test/update/fake_http.dart
  modified:
    - app/remote_control/pubspec.yaml
    - app/remote_control/pubspec.lock

key-decisions:
  - "The live mirror feed was diffed field-for-field against 11-releases-latest.json: the shapes AGREE (all 7 top-level keys, all 6 asset keys, digest = sha256: + 64 lowercase hex). Only synthetic values and asset ORDER differ, so the fixture stands."
  - "Asset order is NOT a contract — the live feed returns assets alphabetically (Extension, Setup, APK) while the fixture lists APK first. Resolution is by name via assetWithPrefix, never by index; a regression test pins it."
  - "stripDigest matches the Rust strip_digest exactly: uppercase HEX is accepted and lowercased (a digest is a value, not a spelling), while an uppercase SHA256: prefix is rejected (Rust's strip_prefix is case-sensitive)."
  - "Release.version carries the tag verbatim minus a leading v; it is deliberately NOT run through normalize(), because deciding whether a version is usable is version.dart's job (UNKNOWN IS NEVER NEWER) and rejecting at parse time would turn a version question into a feed error."
  - "downloadApk gained an optional onError callback carrying the closed DownloadError vocabulary — without it the network/disk/checksum mapping the plan mandates could not reach the UI at all."
  - "A hand-written DigestSink replaces package:convert's AccumulatorSink: convert is only a transitive dependency here, and depending on an undeclared package is both a lint failure and a silent breakage when the transitive graph shifts."
  - "The asset name is sanitised before it is joined to a directory path — a feed-supplied name containing .. or a separator would otherwise choose the write location."

patterns-established:
  - "Offline HTTP fakes: implement the dart:io interface, forward the rest to noSuchMethod, so unimplemented surface fails loudly instead of stubbing to null"
  - "Security invariants asserted twice — once by a grep gate over lib/, once by an executable test that reads back what was actually sent"
  - "Failure discipline: one helper (fail(code, reason)) owns close + delete + map + log for every failure path, so a new failure branch cannot forget the delete"

requirements-completed: [D-02, D-03, D-08, D-15, D-19, D-22, D-23, SC3, SC4]

# Metrics
duration: 42min
completed: 2026-08-04
---

# Phase 12 Plan 10: Feed Fetch and APK Download Summary

**The phone now resolves the latest release itself over anonymous `dart:io HttpClient` against the same fixture the Rust parser is pinned to, and streams the ~70 MB APK to the app cache with throttled progress, chunked sha256, and a delete on every failure path.**

## Performance

- **Duration:** ~42 min
- **Started:** 2026-08-04T13:15Z
- **Completed:** 2026-08-04T13:57Z
- **Tasks:** 2
- **Files modified:** 7 (5 created, 2 modified)

## Accomplishments

- **The phone reads the same feed the server does.** `parseRelease` / `stripDigest` / `assetWithPrefix` are written case-for-case against the Rust `parse_release` / `strip_digest` / `resolve_asset` and pinned to `protocol/fixtures/update/11-releases-latest.json` and `12-releases-latest-null-digest.json` — the same two files `server-windows/src/update/feed.rs` loads.
- **The published feed was verified against the fixture, live.** The mirror `12-03` published returns 200 anonymously and its shape matches the checked-in fixture exactly (details below), so the parser is pinned to reality rather than to a guess.
- **Every check failure is one silent failure (D-22).** A `SocketException`, an HTTP 403 rate limit and a malformed body all resolve to `null` from `fetchLatest`. The status branch logs the NUMBER so a rate limit stays diagnosable; the caller learns nothing but "no release".
- **A missing digest is a hard refusal (D-15), not a skipped verification.** `verifyOrDelete(file, null)` deletes the file and returns `false`. Two tests assert the file is gone from disk afterwards — for a null digest and for a mismatched one.
- **The APK never exists twice in memory and never survives a failure.** Streamed into an `IOSink`, hashed via `sha256.startChunkedConversion` fed from `openRead()`, with no whole-file read anywhere. A dropped socket, a non-200, a write error, a stall and a digest mismatch all delete before returning.
- **The phase's Dart dependency surface stayed at exactly one package.** `crypto ^3.0.7` and nothing else: no `http`, no directory-lookup plugin, no mocking package, no `convert`.

## Task Commits

1. **Task 1: crypto dependency and release_feed.dart** — `00d181b` (feat)
2. **Task 2: apk_download.dart — stream, hash, verify, or delete** — `94144a0` (feat)

## Files Created/Modified

- `app/remote_control/lib/update/release_feed.dart` — `kReleasesApi`, the three asset prefixes, `Release`/`ReleaseAsset`, `parseRelease`, `stripDigest`, `assetWithPrefix`, `fetchLatest`
- `app/remote_control/lib/update/apk_download.dart` — `downloadApk`, `sha256OfFile`, `verifyOrDelete`, `DownloadError`, `safeFileName`, `resolveCacheDir`, `DigestSink`
- `app/remote_control/test/update/release_feed_test.dart` — 16 tests, fixture-pinned
- `app/remote_control/test/update/apk_download_test.dart` — 17 tests, all offline
- `app/remote_control/test/update/fake_http.dart` — shared `HttpClient`/`Request`/`Response`/`Headers` fakes
- `app/remote_control/pubspec.yaml` — one dependency line (`crypto: ^3.0.7`) plus its rationale comment
- `app/remote_control/pubspec.lock` — `crypto` moved transitive → direct

## Live-feed vs fixture comparison (required by the plan)

Fetched `https://api.github.com/repos/nandodeomkar/remote-control-releases/releases/latest` anonymously (no credential header) on 2026-08-04. **HTTP 200. The shapes AGREE.**

| Check | Result |
|-------|--------|
| Top-level keys the fixture uses (`tag_name`, `name`, `prerelease`, `draft`, `published_at`, `html_url`, `assets`) | all present in the live body, none missing |
| `tag_name` | `v1.5.0` — matches |
| `draft` / `prerelease` | `false` / `false` — matches |
| Asset count | 3 live, 3 in the fixture |
| Per-asset keys the fixture uses (`name`, `browser_download_url`, `size`, `state`, `content_type`, `digest`) | all present on all three live assets |
| Asset names | identical (`RemoteControl-v1.5.0.apk`, `RemoteControl-Setup-v1.5.0.exe`, `RemoteControl-Extension-v1.5.0.zip`) |
| `digest` form | `sha256:` + 64 lowercase hex on all three, live |
| `state` | `uploaded` on all three, live |

**Two value-level differences, both expected and both left alone:**

1. **Sizes and digests differ** (live APK 69663775 B / `083e3d13…` vs fixture 69630935 B / `3333cf18…`). The fixture's values are synthetic-but-real-magnitude by design and are ALSO loaded by the Rust test — replacing them would break the cross-language pin. The plan explicitly forbids a wholesale replacement; not done.
2. **Asset ORDER differs.** Live returns them alphabetically — Extension, Setup, APK — while the fixture lists APK first. This is the one finding with teeth: any parser that resolved assets by index would have passed its tests and picked the wrong file in the user's hand. `assetWithPrefix` resolves by name, and a dedicated test (`asset order is not assumed`) now pins that.

## Decisions Made

See `key-decisions` in the frontmatter. The three that a later plan should not re-litigate:

- **`Release.version` is the tag minus a leading `v`, verbatim** — not normalised. `version.dart` owns the "is this usable" question, and UNKNOWN-is-never-newer already covers a junk tag.
- **`stripDigest` accepts uppercase hex and lowercases it, but rejects an uppercase `SHA256:` prefix.** That is exactly what Rust does. The plan's phrase "rejects … uppercase input" was read as the algorithm prefix, because its own spec sentence says the function "lowercases" — which only means something if uppercase hex passes. Both cases have tests, so the intent is now executable either way.
- **`downloadApk` takes an optional `onError`.** The plan fixed the return type at `String?` and separately demanded the `network`/`disk`/`checksum` mapping; without a callback the mapping would have been computed and thrown away.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 2 - Missing Critical] Asset-name path-traversal guard before the write**
- **Found during:** Task 2
- **Issue:** `asset.name` arrives from the network and was to be joined to a directory path. A name containing `..`, `/` or `\` would have chosen the write location — the destination must be picked by this device, never by the feed. The plan's threat model covers the APK's CONTENT (T-12-31) but not its NAME.
- **Fix:** `safeFileName` accepts only `[A-Za-z0-9._-]+` (and no leading dot) and replaces anything else outright with `update.apk` — replaced, not sanitised piecewise, because a partial escape is the failure mode that gets missed.
- **Files modified:** `app/remote_control/lib/update/apk_download.dart`
- **Verification:** Test `an asset name that is not a plain file name cannot escape the destination directory` downloads with the name `../../../../evil.apk` and asserts the path starts with the injected temp dir and ends with the fallback name.
- **Committed in:** `94144a0`

**2. [Rule 3 - Blocking] Shared test HTTP fakes in a third file**
- **Found during:** Task 1
- **Issue:** Both test files need an injectable `HttpClient`/`Request`/`Response`/`Headers`; the plan named only the two test files. Duplicating ~130 lines of fakes twice would have let the two halves of the phase drift apart, and adding a mocking package would have broken the one-dependency budget.
- **Fix:** Created `app/remote_control/test/update/fake_http.dart`. Test-only, zero `lib/` surface, zero new dependency; unimplemented SDK members fall through to `noSuchMethod` and throw rather than stubbing to null.
- **Files modified:** `app/remote_control/test/update/fake_http.dart`
- **Verification:** Both test files import it; 33 new tests pass; `flutter analyze` clean.
- **Committed in:** `00d181b`

**3. [Rule 3 - Blocking] Grep-gated words removed from doc comments**
- **Found during:** Tasks 1 and 2
- **Issue:** The acceptance criteria are literal grep counts (`Authorization` = 0, `package:http` = 0, `path_provider` = 0, `startChunkedConversion` = 1). The first drafts explained the rules by NAMING the forbidden things in doc comments, which trips the very gates that prove the rules hold.
- **Fix:** Rewrote the comments to state the rule without spelling the token ("the standard HTTP credential header", "the pub `http` package", "the usual plugin for this job"), and each now says explicitly that a grep for the name must return zero. The executable half moved into the tests, where it belongs: `release_feed_test.dart` reads back every header the request set and asserts `authorization` is absent.
- **Files modified:** `app/remote_control/lib/update/release_feed.dart`, `app/remote_control/lib/update/apk_download.dart`
- **Verification:** All four grep counts now hold (0 / 0 / 0 / 1).
- **Committed in:** `00d181b`, `94144a0`

**4. [Rule 1 - Bug] `unnecessary_underscores` lint on eight `(_, __)` closures**
- **Found during:** Task 2
- **Issue:** `flutter analyze` reported 8 infos; the project's gate is a clean analyzer.
- **Fix:** `(_, __)` → `(_, _)` (Dart 3.7 wildcard parameters).
- **Files modified:** `app/remote_control/test/update/apk_download_test.dart`
- **Verification:** `flutter analyze` → `No issues found!`
- **Committed in:** `94144a0`

---

**Total deviations:** 4 auto-fixed (1 missing-critical security, 2 blocking, 1 lint bug)
**Impact on plan:** No scope creep. The path-traversal guard is the only behavioural addition and it closes a real hole in the same trust boundary the plan's threat model already names.

## Issues Encountered

- **`AccumulatorSink` is in `package:convert`, which is only transitive here.** RESEARCH Code Example 4 imports it directly; doing so would have been a `depend_on_referenced_packages` failure or a second declared dependency. Replaced by a 4-line hand-written `DigestSink implements Sink<Digest>`. The example's *shape* (`startChunkedConversion` fed from `openRead()`) is unchanged — this is the Dart-side twin of the Rust-side note that `sha2 0.11` is not an `io::copy` sink.
- **`grep -rc 'path_provider' lib/update/` is 1, not 0.** The single hit is a pre-existing doc comment in `apk_installer.dart:146` (written by 12-08) explaining why `cacheDir()` exists so that `path_provider` is NOT needed. The plan's own criterion is scoped to `apk_download.dart`, which is 0. Not touched — editing 12-08's file to satisfy a grep would be worse than the grep.

## Verification Results

| Gate | Result |
|------|--------|
| `flutter test test/update/release_feed_test.dart` | **16 passed** (≥8 required) |
| `flutter test test/update/apk_download_test.dart` | **17 passed** (≥6 required) |
| `flutter test test/update/` | **90 passed** |
| `flutter analyze` | **No issues found** |
| `grep -c 'nandodeomkar/remote-control-releases' release_feed.dart` | 1 |
| `grep -ci 'authorization' release_feed.dart` | 0 |
| `grep -rc 'package:http' lib/update/` | 0 |
| `git diff pubspec.yaml` | one dependency line + its comment |
| `grep -c 'startChunkedConversion' apk_download.dart` | 1 |
| `grep -c 'path_provider' apk_download.dart` | 0 |
| `grep -c 'readAsBytes' lib/update/` | 0 |
| `parseRelease` on the null-digest fixture | asset `sha256` is `null` (not `''`, not a throw) |
| `fetchLatest` with an injected 403 | resolves to `null`, does not throw |

## Known Stubs

None. Both modules are fully wired to real behaviour; nothing returns a hardcoded empty value. They are not yet CALLED by any screen — that wiring is 12-12/12-14/12-15's job, which is the plan's stated scope boundary, not a stub.

## Threat Flags

None beyond the plan's register. One new surface was found and mitigated inside it — the feed-supplied asset NAME as a path component (see deviation 1); it belongs to the existing `GitHub API / CDN -> phone` boundary rather than opening a new one.

## User Setup Required

None — no external service configuration. The mirror repo already exists and is public (12-03), and no credential is used or wanted.

## Next Phase Readiness

Ready for wave 5 (`12-12`, `12-14`):

- `fetchLatest()` → `Release` → `assetWithPrefix(r, kApkAssetPrefix)` → `downloadApk(...)` → `verifyOrDelete(...)` → `ApkInstaller().install(path)` is the complete phone-side chain, and every seam in it is injectable and offline-testable.
- **Never persist a `browser_download_url`.** It redirects to a time-limited signed CDN URL; re-resolve the release immediately before each download. Both files document this.
- **`sizeBytes` is available before the download starts** (D-08), so the `downloading` row can render `{size}` and a percentage from the very first progress callback. Recall the wave-2 carry-forward: `update_cache.dart` does NOT cache asset sizes, so an offline `{size}` still needs a third `update.` key.
- **`DownloadError` is a closed vocabulary of three.** 12-15's copy map should key off `network` / `disk` / `checksum` and must never render the enum name itself.
- `test/update/fake_http.dart` is available to any later test that needs an offline HTTP seam.

## Self-Check: PASSED

All five source/test files exist on disk, the SUMMARY exists, and both task commits (`00d181b`, `94144a0`) are present in `git log`.
