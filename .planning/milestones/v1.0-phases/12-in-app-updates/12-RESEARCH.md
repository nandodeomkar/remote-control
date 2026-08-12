# Phase 12: In-App Updates - Research

**Researched:** 2026-08-01
**Domain:** Self-updating desktop + mobile distribution (GitHub Releases feed, Inno Setup silent self-replace, Android PackageInstaller, MV3 extension reload, PowerShell release automation)
**Confidence:** HIGH on the five named unknowns; MEDIUM on the two behaviours that only an on-device UAT can settle (Chrome file locks, manifest-version pickup after `chrome.runtime.reload()`)

---

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

Copied verbatim from `.planning/phases/12-in-app-updates/12-CONTEXT.md` `<decisions>`.

#### Distribution and versioning

- **D-01** — Release assets live in a second, PUBLIC repo,
  `nandodeomkar/remote-control-releases`, holding only the three binaries and
  release notes per tag. The existing private repo keeps source, `.planning/`,
  and history. Chosen specifically so that no auth token ships inside any build
  artifact: a token embedded in an APK is extractable, and fine-grained PATs
  expire, which would break every installed client on rotation.
- **D-02** — `https://api.github.com/repos/nandodeomkar/remote-control-releases/releases/latest`
  is the SOLE source of truth for "what is the latest version". It already
  returns `tag_name`, and per asset `name`, `browser_download_url`, `size`, and
  `digest` (`"sha256:<hex>"`).
- **D-03** — NO update-manifest file is published. The releases API already
  carries everything needed; a manifest would be a second source of truth that
  can drift from the assets it describes.
- **D-04** — ONE unified `X.Y.Z` per release across all three components, even
  when a component did not change. The extension jumps 1.2.1 → the next release
  version.
- **D-05** — Installed version always comes from the package itself, never a
  hardcoded constant: `package_info_plus` on the phone (as
  `app/remote_control/lib/settings/app_version.dart` already does),
  `env!("CARGO_PKG_VERSION")` in the server,
  `chrome.runtime.getManifest().version` in the extension. Rationale: a Dart
  constant is exactly the bug that pinned `pubspec.yaml` at `1.0.0+1` across
  four shipped releases.

#### Control surface and cadence

- **D-06** — The phone drives all three components from one Updates screen
  reached from Settings. The PC settings window keeps its own fallback check so
  a broken or unpaired phone does not leave the PC with no update path.
- **D-07** — Manual button PLUS a quiet check on app launch, at most once per
  24 hours, result cached. Nothing downloads until a button is tapped. A stale
  or failed background check must never interrupt the user.
- **D-08** — The Updates screen shows the download size before a download
  starts (the APK is ~70 MB). No metered-network detection.

#### Protocol (protoVersion 1.7 → 1.8, additive)

- **D-09** — New messages: `update.check` (C→S, `{}`); `update.status` (S→C,
  required `serverVersion`, `extConnected`; optional `extVersion`,
  `lastUpdate`); `update.apply` (C→S, required `target`); `update.progress`
  (S→C, required `stage`; optional `pct`, `version`, `error`); `ext.reload`
  (srv→ext, `{}`).
- **D-10** — `stage` vocabulary: `checking`, `downloading`, `verifying`,
  `installing`, `restarting`, plus terminals `uptodate` and `failed`. `pct`
  accompanies `downloading` only.
- **D-11** — `error` is a FIXED vocabulary, never free text and never a path:
  `network`, `checksum`, `disk`, `installer`, `downgrade`, `stale`, `busy`.
- **D-12** — `lastUpdate` is `{target, ok, error?}`, reporting the PREVIOUS
  attempt's outcome, read at startup from the marker file (D-16) and cleared
  once reported. It exists because the process that would report a failed
  install has already exited to let the installer replace it.
- **D-13** — `update.check` and `update.apply` are executor-bound (SPEC §11) —
  refused while paused. Both are additive, so a 1.7 server answers
  `err {code:"unknownType"}` and the session survives (SPEC §10); the phone
  renders that as "server too old to update itself".

#### Security (NON-NEGOTIABLE)

- **D-14** — `update.apply` carries a version string and NOTHING else. The
  server resolves the asset URL and its sha256 itself, from a compiled-in repo
  constant. It must refuse any URL or hash supplied, implied, or influenced by
  the wire. A wire-supplied URL would turn a paired phone — or anything that
  obtained a token — into arbitrary code execution on the PC. This rule is not
  to be relaxed for convenience, now or later.
- **D-15** — Server-side refusals, each mapping to a D-11 error code: a
  `target` at or below the running version (`downgrade`); a `target` that does
  not match what the server itself just resolved as latest (`stale` — the
  phone's cached feed can be 24h old); a second `update.apply` while one is in
  flight (`busy`). sha256 is verified BEFORE the installer is ever spawned; a
  mismatch deletes the file and never executes it.

#### Apply mechanics

- **D-16** — PC apply: download to `%TEMP%`, verify sha256, write
  `%APPDATA%\RemoteControl\update-result.json` as `{target, ok:false,
  error:"installer"}`, spawn a detached helper script, exit. The helper waits
  for the server PID to die (releasing `AppMutex=RemoteControl.SingleInstance`,
  `installer/RemoteControl.iss`), runs the setup `/VERYSILENT /NORESTART`,
  rewrites the marker to `ok:true` on a zero exit code, then relaunches the
  installed exe. No `.iss` change is needed — its `[Run]` entry is already
  `skipifsilent`. No SmartScreen prompt either: the server's own HTTP client
  writes the file, so it never receives a Mark-of-the-Web.
- **D-17** — The socket drops during the swap. The phone's EXISTING reconnect
  FSM rides it out and re-checks on reconnect; that re-check is what confirms
  the new version. Do not build a second reconnect path.
- **D-18** — Extension apply: no phone action. The installer already overwrites
  `{app}\extension` (`installer/RemoteControl.iss` line 106). The new server
  compares `ext.hello`'s `extVersion` to its own version and, on mismatch, sends
  `ext.reload` ONCE PER TARGET VERSION PER PROCESS RUN (in-memory guard). The
  extension calls `chrome.runtime.reload()`, re-reading files from disk. If the
  versions still disagree afterwards there is no second attempt — the phone row
  falls back to "restart your browser". The guard exists so a Chrome-blocked
  overwrite cannot produce a reload loop.
- **D-19** — APK apply: download to the app cache with progress, verify sha256,
  install via `PackageInstaller` session behind a MethodChannel. Requires
  `REQUEST_INSTALL_PACKAGES` plus the one-time per-device "install unknown apps"
  grant; the same keystore means the signature matches and it is an upgrade.
  A declined system dialog returns the row to "update available" with no retry
  loop; a missing grant gets an explainer sheet and a button to the system
  settings intent.

#### Release tooling

- **D-20** — `tools/release.ps1 -Version X.Y.Z [-PreRelease] [-DryRun]` refuses
  a dirty tree and refuses a version at or below the latest published. It bumps
  `server/server-windows/Cargo.toml`, `app/remote_control/pubspec.yaml` (BOTH
  halves — Android refuses an install whose build number did not increase), and
  `extension/manifest.json`; builds the APK, the setup exe (through the existing
  `installer/build-installer.ps1`), and the extension zip into `dist/`; prints
  the three sha256 values; tags both repos; and publishes the release with all
  three assets to the public mirror.
- **D-21** — Sequencing constraint: the mirror repo and the release script come
  FIRST. Nothing client-side is testable end to end until a real release exists
  to check against.

#### Error handling (each row is a required behavior)

- **D-22** — No internet / API down / rate-limited: the row reads "couldn't
  check" with a retry button; the daily background check fails silently.
- **D-23** — Download interrupted or disk full: abort, delete the partial file,
  report `failed` / `disk`.
- **D-24** — Installer exits non-zero: the helper relaunches the still-installed
  old exe, leaves the marker at `ok:false`, and appends to
  `%APPDATA%\RemoteControl\logs\update.log`; the phone shows the failure from
  `lastUpdate`.
- **D-25** — Server never comes back: the existing reconnect FSM handles it;
  after its timeout the row reads "PC didn't come back — start it from the
  Start Menu".
- **D-26** — A version at or below the installed one is never offered, on
  either side.

### Claude's Discretion

Not decided by the owner — the planner and executors choose, with the notes
below as entry-scan observations rather than locked constraints:

- Rust HTTP client crate. `ureq` 3.3 (blocking, rustls) looks right because the
  work belongs on a dedicated OS thread alongside the existing
  `apps_thread` / `clip_thread` / `audio_thread`, and it avoids pulling a second
  async stack in beside tokio. Confirm against the RESEARCH package audit.
- Dart sha256 source (`crypto` package — Dart has no built-in digest) and the
  HTTP client choice (`dart:io HttpClient` matches the project's existing
  preference for SDK primitives over thin wrappers, per the `RawDatagramSocket`
  precedent).
- Internal file layout under `lib/update/` and `server-windows/src/update/`,
  and the exact split between `server-core` (codecs + an `UpdateExecutor` trait
  through `ServerDeps`) and `server-windows` (all I/O). The `server-core`
  zero-Windows-dependencies invariant is NOT discretionary — it must hold.
- The Android MethodChannel's exact method names and Kotlin structure; the
  existing hand-written `platform/multicast_lock.dart` is the pattern to follow,
  including its `MissingPluginException` no-op contract for tests.
- Updates-screen visual composition within the existing dark-minimal tokens.
- Whether the PC settings fallback performs its own feed check or links out.

### Deferred Ideas (OUT OF SCOPE)

- Auto-download before the user asks (rejected: ~70 MB of background data to
  save a few seconds).
- Delta / patch updates.
- Rollback to a previous version.
- Update channels other than latest-stable.
- Metered-network detection (costs a dependency; both users are known).
- iOS / Linux / macOS clients.
</user_constraints>

---

<phase_requirements>
## Phase Requirements

No REQ-IDs are mapped to this phase (`.planning/ROADMAP.md`: *"Requirements: none mapped — the acceptance surface is the design spec's Decisions table"*). The acceptance surface is D-01..D-26 above plus ROADMAP's eight success criteria, mapped here to the research that enables them.

| SC | Success criterion (abridged) | Research support |
|----|------------------------------|------------------|
| SC1 | `tools/release.ps1` bumps three version fields, builds three artifacts, publishes to the mirror | §Release tooling mechanics; §Pitfall 9 (regex-not-parse rewriting); §Environment Availability (gh 2.96.0 verified at an absolute path) |
| SC2 | Every component reports the package's own version | Already true for the app (`app_version.dart`); `env!("CARGO_PKG_VERSION")` and `chrome.runtime.getManifest().version` verified in tree; §Version State Inventory |
| SC3 | Updates screen: three components, on-demand + ≤1×/24h, every failure state rendered | §Feed layer (Dart); §Pitfall 2 (rate limit → 403, not a network error); §Row-state matrix |
| SC4 | APK end-to-end: sha256 verified, `PackageInstaller` invoked, missing grant explained | §Unknown 2; §Code Examples 4–6; §Pitfall 5/6/7 |
| SC5 | PC end-to-end: verify, silent install, relaunch, marker diagnoses failure | §Unknown 1 + 3; §Code Examples 1–3; §Pitfall 3/4 |
| SC6 | Server resolves URL + hash itself; forged `update.apply` cannot fetch an arbitrary URL | §Security Domain (V5 input validation); §Pattern 2 (the resolve-locally seam and its test) |
| SC7 | Extension runs the new version without touching `chrome://extensions`; blocked overwrite degrades, no loop | §Unknown 4; §Open Question 1/2 |
| SC8 | 1.7 server + 1.8 phone still interoperate | SPEC §10 already implemented (`json.rs` unknown-type path); §Version State Inventory note on the stale Dart `protoVersion` |
</phase_requirements>

---

## Project Constraints (from CLAUDE.md)

Directives the planner must honour. All are already satisfied by the recommendations below; listed so a plan-check can verify.

| Directive | Bearing on this phase |
|-----------|----------------------|
| Locked stack: Flutter client, Rust server (tokio + tungstenite, enigo, tray-icon) | No change. `ureq` runs on an OS thread, not in tokio; no second async runtime enters the tree |
| Transport: WebSocket only, JSON + 9-byte binary; transport abstracted | `update.*` is JSON on the existing socket. No new transport, no new listener |
| Security: PIN pairing, SHA-256-hashed tokens, LAN-only binding, power actions double-confirmed | `update.apply` inherits auth gating (SPEC §6) and pause binding (SPEC §11). D-14 adds a stricter rule than any existing family |
| `sha2` 0.11 already in tree (server-core token hashing + `clip_thread` fingerprint) | Reuse it. Do NOT add a second digest crate to the Rust side |
| `dirs` 6.0 already in tree for `%APPDATA%` | Reuse `dirs::config_dir()` for the marker file and `update.log`. Do not hand-roll `%APPDATA%` |
| "What NOT to Use": storing app settings in `flutter_secure_storage` | The 24h check cache and last-seen version go in `shared_preferences` (already a dependency), never secure storage |
| "What NOT to Use": `flutter_secure_storage` `encryptedSharedPreferences: true` | Untouched by this phase |
| `flutter_riverpod` 3.x unified `Notifier`, no `StateNotifier` | `update_providers.dart` uses Riverpod 3 `Notifier`/`AsyncNotifier` with constructor args |
| `dart:io RawDatagramSocket` precedent — SDK primitives over stale wrappers | Use `dart:io HttpClient` for the feed and the APK download, not `package:http` |
| Rolling file logs via `tracing-appender` under `%APPDATA%\RemoteControl\logs` | D-24's `update.log` should live beside `server.log.<date>` in the same directory. Prefer appending through the existing `tracing` pipeline where the writer is the *server*; the *helper script* writes it directly (the server is dead by then) |
| Secrets never logged (SPEC §12) | The update path logs no token, no PIN. Asset URLs and hashes are non-secret and MAY be logged — that is useful diagnostics |

**No project skills directory exists** (`.claude/skills/`, `.agents/skills/`, `.cursor/skills/`, `.github/skills/`, `.codex/skills/` all absent) — verified 2026-08-01.

---

## Summary

This phase has five hard technical unknowns and every one of them resolved in favour of the design already locked in CONTEXT.md — with three material corrections and one genuine risk that must be carried into planning as an on-device gate.

**What confirms the design.** The GitHub releases API really does carry a per-asset `digest` of the form `sha256:<64 hex>`; live-verified on a real public repo, present on every asset, alongside `name`, `size`, `state:"uploaded"` and `browser_download_url` [VERIFIED: api.github.com live call]. The anonymous rate limit is 60/hour/IP with `X-RateLimit-*` headers on every response [VERIFIED: live response headers]. `ureq` 3.3.0 is current, healthy (169M downloads, `algesten/ureq`, clean legitimacy verdict), streams a body to disk through `body_mut().as_reader()` + `std::io::copy`, follows cross-host redirects by default (max 10), and defaults to rustls with the static webpki-roots bundle — no Windows root-store dependency and no OpenSSL. Android's `PackageInstaller` session sequence is exactly `createSession → openSession → openWrite → fsync → close → commit(IntentSender)`. Chrome's own docs state that reloading an *unpacked* extension "is treated as an update" and fires `onInstalled` with reason `"update"` — which is the strongest available evidence that `chrome.runtime.reload()` re-reads from disk rather than merely restarting the service worker.

**The three corrections.** (1) **ureq sets no timeouts by default.** Every `timeout_*` is `None` except `timeout_await_100`; a stalled TCP connection on a phone-triggered download would hang the update thread forever with the phone stuck on `downloading`. `timeout_global` must be set explicitly on both the feed agent and the download agent. (2) **`/VERYSILENT` alone does NOT suppress the AppMutex dialog.** Verified against the Inno Setup source: the mutex check is `LoggedMsgBox(..., MB_OKCANCEL, Suppressible=True, Default=IDCANCEL)`, and `InitSuppressMsgBoxes` is only set when `/SUPPRESSMSGBOXES` is combined with a silent switch. Run `/VERYSILENT` with the mutex still held and a real modal error box appears on the user's desktop from a "silent" install. The helper's wait-for-PID-exit step is therefore load-bearing, not defensive, and `/SUPPRESSMSGBOXES` should be added as a belt so any surviving box aborts to a decodable exit code instead of blocking on screen forever. (3) **`browser_download_url` redirects cross-host to a time-limited signed URL** on `release-assets.githubusercontent.com` — so the resolved URL must never be cached across a run, and any client that does not follow cross-host redirects fails.

**The genuine risk.** D-18's extension path depends on `chrome.runtime.reload()` picking up a changed `manifest.json` *version* while Chrome is running, and on Inno being able to overwrite `{app}\extension\*` while Chrome holds that directory. Neither is documented. Community tooling for unpacked extensions consistently warns that manifest changes need a manual `chrome://extensions` refresh, and Chrome writes its own `_metadata` folder into unpacked extension directories. If Chrome does hold write locks, Inno's file-replace failure raises an Abort/Retry/Ignore dialog whose suppressed default is **Abort** — which would abort the *entire* server install, not just the extension, turning a Chrome-open-during-update into a total PC-update failure. That is a bigger blast radius than D-18 anticipates and it needs a planned mitigation, not just a UAT step (see Open Question 1 and Pitfall 4).

**Primary recommendation:** Build the release script and mirror repo first (D-21), then protocol 1.8 with fixtures, then the three client paths — and put a `checkpoint:human-verify` **before** the extension slice that answers, on a real machine with Chrome open, whether Inno can overwrite `{app}\extension` and whether `chrome.runtime.reload()` reports the new manifest version. Give the `[Files]` entry for `..\extension\*` a `skipifsilent`-independent mitigation (see Pattern 5) so that a Chrome lock can never abort the server install.

---

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| Resolve "what is the latest version" | **API/Backend** (GitHub Releases, read-only) | — | D-02/D-03: the API is the single source of truth; nothing else publishes it |
| Resolve the PC asset URL + sha256 for a given version | **PC server** (`server-windows/src/update/feed.rs`) | — | D-14 non-negotiable: the tier that *executes* the installer is the only tier allowed to name the file it executes |
| Resolve the APK asset URL + sha256 | **Phone** (`lib/update/release_feed.dart`) | — | The phone executes the APK install, so the phone resolves the APK. Symmetry with D-14, not an exception to it |
| Report installed version of each component | **The component itself** | — | D-05. Server: `CARGO_PKG_VERSION`. App: `package_info_plus`. Extension: `getManifest().version`, relayed to the server via the already-existing `ext.hello` |
| Aggregate the three versions for display | **PC server** (`update.status`) + **Phone** (feed + own version) | — | The server owns what it can see locally (itself + the extension leg); the phone owns its own version and the feed |
| Decide *whether* an update is offered | **Phone UI** (`lib/update/version.dart`) and **PC server** independently | — | D-26 requires refusal on *both* sides; a single shared decision point would be a single point of bypass |
| Download + verify the PC asset | **PC server**, dedicated OS thread | — | Blocking I/O; matches `apps_thread`/`clip_thread`/`audio_thread`. Never on the tokio runtime |
| Download + verify the APK | **Phone**, isolate-free async `dart:io` | — | `HttpClient` is already non-blocking; sha256 chunking keeps the 70 MB off the heap twice |
| Apply the PC install | **Detached OS helper process** | PC server (spawn only) | The server must die for Inno's AppMutex gate to pass; only a process outside it can sequence wait→install→relaunch |
| Apply the APK install | **Android system** (`PackageInstaller`) | Phone Kotlin/MethodChannel | The OS owns package installation; the app only stages bytes and commits |
| Apply the extension update | **Inno installer** (file overwrite) + **extension** (`chrome.runtime.reload()`) | PC server (`ext.reload` trigger only) | D-18: the extension rides the server installer; the server only nudges |
| Persist "what happened last time" | **Filesystem marker** `%APPDATA%\RemoteControl\update-result.json` | — | D-12/D-16: no in-process tier survives the swap, so the only tier that can carry the answer is disk |
| Bump + publish versions | **Build tier** (`tools/release.ps1`) | — | D-20: version identity is a build-time invariant, enforced once, not three times at runtime |

**Tier-assignment trap to watch in planning:** the phone is the *control surface* (D-06), not the *decision surface*. Every "which file, which hash" decision belongs to the tier that will execute the file. A plan that has the phone pass a URL, a filename, an asset index, or a hash to the server violates D-14 even if the value looks innocuous.

---

## Standard Stack

### Core — new dependencies

| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| `ureq` (Rust, `server-windows`) | 3.3.0 | Blocking HTTPS GET of the release feed + streaming asset download | The de-facto blocking Rust HTTP client. Rustls by default with a bundled root store (no OpenSSL, no Windows cert-store plumbing), one dependency tree, and a `std::io::Read` body that streams straight to a file. Blocking is a *feature* here: the work belongs on a dedicated OS thread beside `apps_thread`/`clip_thread`/`audio_thread`, and `reqwest` would drag a second async surface into a crate that already runs tokio [VERIFIED: crates.io + docs.rs] |
| `crypto` (Dart, `app/remote_control`) | 3.0.7 | sha256 of the downloaded APK | Dart has no built-in digest. Published by the `dart.dev` verified publisher, 160/160 pub points, ~9.9M downloads/30d. `Hash.startChunkedConversion` hashes a 70 MB file without a second copy in memory [VERIFIED: pub.dev API] |

**That is the entire new-dependency surface.** Everything else this phase needs is already in the tree.

### Supporting — already in tree, reuse, do not re-add

| Library | Version in tree | Use in this phase |
|---------|-----------------|-------------------|
| `sha2` | 0.11 (`server-windows` + `server-core`) | sha256 of the downloaded setup exe. Same `Digest` API `clip_thread::clip_fingerprint` already uses |
| `serde` / `serde_json` | 1.x | Feed parse (`server-windows`), `update.*` codecs (`server-core`), marker file read/write |
| `dirs` | 6.0 | `dirs::config_dir()` → `%APPDATA%\Roaming\RemoteControl` for the marker and `update.log` |
| `tracing` / `tracing-appender` | 0.1 / 0.2 | Server-side update logging into the existing rolling log |
| `anyhow` | 1 | Error plumbing inside `server-windows/src/update/` |
| `package_info_plus` | ^10.2.1 (latest is 10.2.1) | Installed app version — `appVersionProvider` already exists and already has the test-override seam |
| `shared_preferences` | ^2.5.5 (latest is 2.5.5) | 24h check cache + last-seen version (D-07). Non-secret → never secure storage |
| `dart:io HttpClient` | SDK (Dart 3.12.2) | Feed GET + APK download with progress. `followRedirects=true`, `maxRedirects=5` by default |
| `flutter_riverpod` | ^3.3.2 | `update_providers.dart` row-state wiring |
| `remote_protocol` (path dep) | — | Dart `update.*` codecs, pinned to the shared fixtures |

### Alternatives Considered

| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| `ureq` 3.3 | `reqwest` (blocking feature) | `reqwest`'s blocking mode spins a private tokio runtime internally — a second runtime inside a process that already owns one, for a request every 24 hours. Bigger tree, no benefit |
| `ureq` 3.3 | `windows` crate WinHTTP (`Win32_Networking_WinHttp`) | Zero new dependencies and uses the Windows cert store, but ~150 lines of unsafe COM-ish plumbing for redirects, streaming and timeouts that `ureq` gets right. Only worth it if a corporate proxy story ever matters (it does not — two known users) |
| `ureq` default webpki-roots | `ureq` + `platform-verifier` feature | Uses the Windows root store, so an enterprise MITM proxy or a future root rotation is handled by the OS. Costs a feature flag and a platform-specific code path. **Recommendation: stay on the default** — webpki-roots is a static Mozilla bundle refreshed with each `ureq` release, and `api.github.com` chains to a mainstream root. Revisit only if a user reports a TLS failure |
| Dart `crypto` | Hashing on the Kotlin side inside the MethodChannel | Would avoid a Dart dependency but moves a security gate into platform code that widget tests cannot reach. `crypto` keeps verification in testable Dart, with the channel doing only what only it can do |
| `dart:io HttpClient` | `package:http` | `http` gives no streaming-with-progress ergonomics worth the dependency, and the project already chose SDK primitives over wrappers for the beacon socket (`RawDatagramSocket` over the stale `udp` package). Follow the precedent |
| Hand-written PowerShell version rewrite | `powershell-yaml` / a TOML parser module | A parse-and-reserialise round trip would reformat `pubspec.yaml` and `Cargo.toml`, destroying every comment those files carry (and both carry load-bearing comments). Targeted regex replacement of a single line is correct here — see Pitfall 9 |
| A `.cmd`/`.ps1` helper script written to `%TEMP%` | A second small Rust binary shipped in the installer | A dedicated `rc-updater.exe` would be more robust (no script-execution policy questions, typed exit codes) but adds a second artifact to build, sign-less-ship and version. **Recommendation: `.cmd`, not `.ps1`** — `cmd.exe` has no execution policy, is always present, and the whole script is four commands. See Pattern 3 |

**Installation:**

```bash
# Rust — server/server-windows/Cargo.toml
# ureq = "3.3"     (default features: rustls + gzip)

# Dart — app/remote_control/pubspec.yaml
# crypto: ^3.0.7
```

**Version verification (run at plan/execute time, do not trust this document's numbers):**

```bash
cargo search ureq            # expect 3.3.x
curl -s https://pub.dev/api/packages/crypto | jq -r .latest.version   # expect 3.0.x
```

Verified on 2026-08-01: `ureq` max_stable `3.3.0` (newest version published 2026-03-21, not yanked); `crypto` latest `3.0.7` (published 2025-11-04).

---

## Package Legitimacy Audit

| Package | Registry | Age | Downloads | Source Repo | Verdict | Disposition |
|---------|----------|-----|-----------|-------------|---------|-------------|
| `ureq` 3.3.0 | crates.io | first published 2018-06-22 (~8 yrs) | 169,078,147 total; ~3.69M/week | github.com/algesten/ureq | **OK** | Approved |
| `crypto` 3.0.7 | pub.dev | long-established Dart team package | ~9,917,156 / 30 days | github.com/dart-lang/core (`pkgs/crypto`) | **OK** | Approved |

**Method.** `ureq` was checked with `gsd-tools query package-legitimacy check --ecosystem crates ureq` → `verdict: OK`, `reasons: []`, `deprecated: false`, `postinstall: null`, and cross-checked against the crates.io API for `max_stable_version`, `newest_version`, yank status and repository URL. It was discovered from an authoritative source (docs.rs official crate documentation), so it qualifies for `[VERIFIED: crates.io]`.

`crypto` could **not** be checked by the seam — `package-legitimacy check` supports `npm|pypi|crates` only, and running it against `pypi` returns a misleading `SUS` for an entirely different PyPI package of the same name. That is a false signal and must not be carried forward. It was verified manually against the pub.dev API instead: `publisherId: "dart.dev"` (verified publisher), `grantedPoints: 160 / 160`, `likeCount: 1883`, `downloadCount30Days: 9,917,156`. Discovered from the official Dart `crypto` package documentation. **Cross-ecosystem confusion is exactly the documented hallucination vector here — never validate a pub.dev package against PyPI or npm.**

**Packages removed due to [SLOP] verdict:** none.
**Packages flagged as suspicious [SUS]:** none. (The `crypto`/PyPI `SUS` result above is a tool-ecosystem mismatch, not a finding.)

**No postinstall/build-script risk:** `ureq` is a pure library crate with no `build.rs` network activity; `crypto` is pure Dart with no platform channels or native code.

---

## Version State Inventory

This is a distribution-model migration, so the "what carries the old value at runtime" question applies. Every category answered explicitly.

| Category | Items found | Action required |
|----------|-------------|-----------------|
| **Version-bearing source files** | `server/server-windows/Cargo.toml` = `1.4.0`; `app/remote_control/pubspec.yaml` = `1.4.0+8`; `extension/manifest.json` = `1.2.1` | D-04 unifies all three at the next release version. The extension jumps `1.2.1 → X.Y.Z`. `pubspec` build number must also increase (currently `+8` → `+9` or higher) |
| **Git tags (private repo)** | `v1.0.0`, `v1.1.0`, `v1.2.0`, `v1.4.0` — **`v1.3.0`, `v1.3.1`, `v1.3.2` were never tagged**, though those releases shipped (their artifacts are in `dist/`) | Evidence that hand-tagging drifts; D-20's "tag both repos" step is the fix. No back-filling required, but the script must not assume tag continuity when computing "latest published" |
| **Public mirror repo** | `nandodeomkar/remote-control-releases` → HTTP **404**. Does not exist [VERIFIED: api.github.com] | Owner action outside the codebase (CONTEXT `<domain>`). Plans may name it; the release script must fail with a clear message if it is absent, not with a raw `gh` error |
| **Private repo anonymous readability** | `api.github.com/repos/nandodeomkar/remote-control` → **404** to an anonymous caller (private repos 404 rather than 403) | Confirms D-01's premise: an installed client with no token cannot read the current repo's releases at all. The mirror is not an optimisation, it is the only anonymous path |
| **Existing release artifacts** | `dist/` holds v1.3.0/1.3.1/1.3.2/1.4.0-rc1/1.4.0 triples. Real sizes: **APK 69,630,935 B (66.4 MiB)**, **Setup 5,177,240 B (4.94 MiB)**, **extension zip 13,454 B** | Confirms D-08's "~70 MB" figure. `dist/` is **gitignored** (`.gitignore` line 9 `/dist/`), so the release script writes to a non-tracked directory — correct, and it means "refuse a dirty tree" will not be tripped by its own output |
| **Installed clients in the field** | Both users are on artifacts predating this phase | CONTEXT already records this: the first upgrade onto this feature is a manual install. No migration code needed |
| **Runtime marker file** | `%APPDATA%\RemoteControl\update-result.json` does not exist yet | New. Its **absence must be the normal case** — a missing marker is "no previous attempt", never an error |
| **Chrome-created state inside `{app}\extension`** | Chrome writes a `_metadata` folder into unpacked extension directories at load time [CITED: chromium-extensions group] | Inno's `[Files] ... recursesubdirs` copies *into* the directory and does not prune, so `_metadata` survives an overwrite harmlessly. `[UninstallDelete] Type: filesandordirs; Name: "{app}\extension"` already removes it on uninstall. **No action** — but do not add a `deleteafterinstall`/clean-directory step that would fight Chrome |
| **Stale advertised protocol version (client)** | `app/packages/remote_protocol/lib/src/version.dart` still declares `protoVersion = '1.1'`; the phone advertises `"1.1"` in `hello` while the server is at `"1.7"`. Recorded as a known-stale item in STATE.md | **Do not fix as a side effect of this phase.** It is harmless (SPEC §2: only the major is compared) but SC8 talks about a "1.8 phone" — the plan must be explicit that 1.8 means *the phone knows the `update.*` types*, not *the phone advertises `"1.8"`*. Changing the advertised string is a handshake-path behaviour change with its own test surface and belongs in its own task if it is done at all |
| **`SERVER_PROTO_VERSION`** | `server/server-core/src/transport/session.rs:65` = `"1.7"`; also embedded in the UDP beacon (`beacon.rs:56`) | Bumping it to `"1.8"` changes the beacon payload too. The beacon fixture family (`protocol/fixtures/beacon/`) may pin the string — check before bumping |
| **Secrets / env vars** | None. No token, no env var is introduced or renamed by this phase — that is the whole point of D-01. `RC_EXT_PORT`/`RC_BEACON_PORT` untouched | None |
| **OS-registered state** | HKCU `...\CurrentVersion\Run` value `"Remote Control"` points at `{app}\RemoteControl.exe`. A same-directory in-place upgrade (`UsePreviousAppDir=yes`, fixed `AppId`) leaves it valid | None — but the helper must relaunch **`{app}\RemoteControl.exe`**, resolved from the install directory, not `std::env::current_exe()` captured before the swap (they happen to be the same path, but relying on that is fragile if the owner ever changes `DefaultDirName`) |
| **Build artifacts** | `server/target/release/server-windows.exe` is renamed to `RemoteControl.exe` by the installer's `DestName` | The running process is `RemoteControl.exe`; `current_exe()` returns the installed path. Fine for PID/exe resolution |

---

## Architecture Patterns

### System Architecture Diagram

```
                    ┌──────────────────────────────────────┐
                    │  api.github.com                      │
                    │  /repos/<owner>/remote-control-      │
                    │   releases/releases/latest           │
                    │  (PUBLIC, anonymous, 60 req/h/IP)    │
                    └───────┬───────────────────┬──────────┘
                            │ GET (JSON)        │ GET (JSON)
                            │                   │
        ┌───────────────────▼──────┐   ┌────────▼──────────────────────┐
        │  PHONE                   │   │  PC SERVER (Windows)          │
        │                          │   │                               │
        │ launch ──┐               │   │  update_thread (OS thread,    │
        │  (≤1/24h)│               │   │   NOT tokio)                  │
        │          ▼               │   │        ▲        │             │
        │   update_cache (prefs)   │   │        │        │             │
        │          │               │   │  UpdateCmd     stage/pct      │
        │          ▼               │   │  (mpsc)        (watch)        │
        │   release_feed ──► Release│   │        │        ▼             │
        │          │  {version,     │   │  ┌─────┴────────────────┐    │
        │          │   assets[]}    │   │  │ server-core session  │    │
        │          ▼               │   │  │  dispatch (SPEC §11   │    │
        │   version.compare  ◄──────┼───┼──┤  executor-bound)     │    │
        │          │               │   │  └─────┬────────────────┘    │
        │          ▼               │   │        │                     │
        │   ┌──────────────────┐   │   │        │ ext.hello.extVersion │
        │   │ Updates screen   │   │   │        │ (already on the wire)│
        │   │  ┌────────────┐  │   │   │        ▼                     │
        │   │  │ App row    │  │   │   │  ext leg 127.0.0.1:17779     │
        │   │  │ PC row     │  │   │   │        │                     │
        │   │  │ Ext row    │  │   │   │        │ ext.reload           │
        │   │  └────────────┘  │   │   │        ▼                     │
        │   └───┬───────┬──────┘   │   │  ┌──────────────┐            │
        └───────┼───────┼──────────┘   │  │ EXTENSION    │            │
                │       │              │  │ MV3 SW       │            │
   update.check │       │ update.apply │  │ runtime      │            │
   update.status│       │ {target}     │  │  .reload()   │            │
   update.progress◄─────┴──────────────┼──┤              │            │
                │        (WebSocket)   │  └──────┬───────┘            │
                │                      │         │ re-read from disk  │
                ▼                      │         ▼                    │
   ┌────────────────────────┐          │  {app}\extension\*           │
   │ apk_download           │          │         ▲                    │
   │  stream → app cache    │          │         │ overwritten by     │
   │  progress (bytes/total)│          │         │                    │
   │         │              │          │  ┌──────┴──────────────────┐ │
   │         ▼              │          │  │ RemoteControl-Setup.exe │ │
   │  sha256 (chunked)      │          │  │  /VERYSILENT /NORESTART │ │
   │         │              │          │  │  /SUPPRESSMSGBOXES      │ │
   │    match? ──no──► delete, failed  │  └──────▲──────────────────┘ │
   │         │yes            │         │         │ run                 │
   │         ▼               │         │  ┌──────┴──────────────────┐ │
   │  PackageInstaller       │         │  │ DETACHED HELPER (.cmd)  │ │
   │   session.commit()      │         │  │ 1 wait for server PID   │ │
   │         │               │         │  │ 2 run setup             │ │
   │         ▼               │         │  │ 3 rewrite marker ok     │ │
   │  Android confirm dialog │         │  │ 4 relaunch exe          │ │
   │         │               │         │  └──────▲──────────────────┘ │
   │    ┌────┴────┐          │         │         │ spawn DETACHED     │
   │  decline   accept       │         │         │ + exit(0)          │
   │    │         │          │         │  ┌──────┴──────────────────┐ │
   │  row back  process      │         │  │ download → %TEMP%       │ │
   │  to avail  KILLED       │         │  │ verify sha256           │ │
   └────────────────────────┘          │  │ write marker ok:false   │ │
                                       │  └─────────────────────────┘ │
                                       │         │                    │
                                       │         ▼                    │
                                       │  %APPDATA%\RemoteControl\    │
                                       │    update-result.json ───────┼──► read at
                                       │    logs\update.log           │    next startup
                                       └──────────────────────────────┘    → lastUpdate
```

Trace the primary use case (update the PC): phone reads the feed → renders the PC row → user taps → `update.apply {target}` → dispatch (auth + pause gated) → `UpdateCmd` to the update thread → thread **re-resolves** the feed itself → downloads to `%TEMP%` → verifies sha256 → writes the pessimistic marker → spawns the detached helper → server exits → helper waits for PID death → runs setup silently → rewrites the marker → relaunches → new server starts, reads the marker, reports it as `lastUpdate` on the next `update.status`, deletes it.

### Recommended Project Structure

```
tools/
└── release.ps1              # D-20: bump 3 versions, build 3 artifacts, tag, publish

server/server-core/src/
├── codec/json.rs            # + update.* encode/decode (additive to the existing registry)
└── transport/
    ├── mod.rs               # + ServerDeps.update: Arc<dyn UpdateExecutor>
    ├── ext.rs               # + capture ext.hello extVersion; + ExtCmd::Reload
    └── session.rs           # SERVER_PROTO_VERSION "1.7" -> "1.8"; update.* dispatch arms

server/server-windows/src/
├── update/
│   ├── mod.rs               # UpdateExecutor impl (the ServerDeps-facing seam)
│   ├── feed.rs              # ureq GET + serde parse -> Release{version, assets}
│   ├── download.rs          # streaming download to %TEMP% + sha2 verify
│   ├── apply.rs             # helper .cmd generation + DETACHED_PROCESS spawn
│   ├── marker.rs            # update-result.json read/write/clear
│   └── update_thread.rs     # the dedicated OS thread (apps_thread shape)
├── main.rs                  # + channel pair, + thread spawn, + ServerDeps field
└── shell/settings.rs        # + Updates section (D-06 fallback)

app/remote_control/lib/update/
├── version.dart             # pure X.Y.Z parse+compare; malformed => unknown
├── release_feed.dart        # dart:io HttpClient GET -> Release
├── update_cache.dart        # shared_preferences: lastCheckAt, lastSeenVersion (24h TTL)
├── apk_download.dart        # streamed download + chunked sha256 + delete-on-fail
├── apk_installer.dart       # MethodChannel('remote_control/installer')
├── update_providers.dart    # Riverpod 3: feed x installed x server-reported -> row states
└── updates_screen.dart      # three rows + the Settings badge

app/remote_control/android/app/src/main/kotlin/dev/omkar/remotecontrol/
├── MainActivity.kt          # + second MethodChannel, mirroring the multicast one
└── InstallResultReceiver.kt # BroadcastReceiver for the commit IntentSender

protocol/
├── SPEC.md                  # §2 add the 1.8 line; §7 add 5 rows; §11 add executor binding; §15 add ext.reload
├── schema/messages.schema.json
└── fixtures/update/         # new family, shared by both codecs
```

### Pattern 1 — The dedicated update thread (clone the existing house pattern)

**What:** All blocking update I/O lives on one `std::thread`, commanded over `std::sync::mpsc`, publishing progress over a `tokio::sync::watch`.
**When to use:** Always. `apps_thread`, `clip_thread` and `audio_thread` are all this shape; `main.rs` already has the wiring boilerplate at lines 113–169 to copy.
**Why it matters here specifically:** `ureq` is blocking. Calling it from a tokio task would stall a runtime worker for the whole 5 MB download.

```rust
// server-windows/src/main.rs — same three lines as every other worker thread
let (update_cmd_tx, update_cmd_rx) = std::sync::mpsc::channel::<UpdateCmd>();
let (update_tx, update_rx) = tokio::sync::watch::channel(UpdateProgress::default());
std::thread::spawn(move || update_thread::run_update_thread(update_cmd_rx, update_tx));
```

The `watch` receiver goes into `ServerDeps` exactly like `volume`, `apps`, `clip`, `tabs` and `bookmarks` already do, so the authed-gated push arm in `session.rs` is a copy of the `vol.changed` arm. The `mpsc::Sender` goes into the `UpdateExecutor` impl, exactly like `ClipCmd`/`AppsCmd`.

**Progress throttling:** the `watch` channel coalesces by design (a slow consumer sees only the latest value), which is exactly right for `pct`. Send at most one update per ~1% or per ~250 ms — the existing threads' 250 ms cadence is the house rhythm.

### Pattern 2 — Resolve-locally (the D-14 seam) and how to test it

**What:** `update.apply` decodes to a bare `String` version. The executor's signature takes only that string. The URL never appears in any type reachable from the codec.
**When to use:** This is the phase's single most important structural rule.

```rust
// server-core: the ONLY thing the wire can influence
pub trait UpdateExecutor: Send + Sync {
    fn check(&self);
    /// `target` is a version string and nothing else (D-14).
    fn apply(&self, target: &str);
}
```

Make it structurally impossible to widen: put the repo constant in `server-windows` where the codec cannot see it.

```rust
// server-windows/src/update/feed.rs
const RELEASES_API: &str =
    "https://api.github.com/repos/nandodeomkar/remote-control-releases/releases/latest";
const SETUP_ASSET_PREFIX: &str = "RemoteControl-Setup-v";
```

**The SC6 test** ("a forged `update.apply` cannot make the server fetch an arbitrary URL") should assert two things, and the second is the one that survives refactoring:

1. Behavioural: a session sending `update.apply {target: "https://evil/x.exe"}` produces `update.progress {stage:"failed", error:"stale"}` and no network call (a recording fake `UpdateExecutor` observes only the string).
2. Structural: a compile-time/grep assertion that no `update.*` payload struct in `codec/json.rs` has a field named `url`, `asset`, `sha256`, `digest`, `hash`, `file`, or `path`. This project already pins string invariants by test (`single_instance.rs::mutex_name_matches_the_installer_contract`) — the same trick applies.

**Refusal ordering** (all three are D-15, and the order matters for which error the user sees):

```
1. busy      — an apply is already in flight        (cheapest, no I/O)
2. downgrade — target <= CARGO_PKG_VERSION          (pure compare, no I/O)
3. <fetch the feed>                                  (network; failure => network)
4. stale     — target != freshly-resolved latest
5. <resolve asset by name>                           (absent => installer)
6. <download>                                        (failure => network or disk)
7. checksum  — digest mismatch => delete, never exec
```

### Pattern 3 — The detached helper: sequencing, not politeness

**What:** A `.cmd` written to `%TEMP%`, spawned with `DETACHED_PROCESS | CREATE_NO_WINDOW`, that outlives its parent.

Four requirements, each with a reason:

1. **Wait for the server PID to exit before running setup.** Not optional — see Unknown 3. The mutex gate fires before anything else and, without `/SUPPRESSMSGBOXES`, puts a modal dialog on the desktop.
2. **Wait without a busy loop and without assuming any tool is present.** `cmd.exe`'s only always-present sleep is `timeout /t 1 /nobreak` — but `timeout` fails when stdin is not a console, which a `DETACHED_PROCESS` child is. Use **`ping -n 2 127.0.0.1 >nul`** as the one-second delay: it is a Windows built-in, needs no console, and has been the standard `cmd` sleep for two decades. Poll with `tasklist /FI "PID eq <pid>" /NH | find "<pid>" >nul` — also always present.
3. **Bound the wait.** A server that refuses to die must not leave the helper spinning forever. Cap at ~30 iterations (≈30 s) and, on timeout, leave the marker at `ok:false` / `installer`, append to `update.log`, and exit without running setup — the still-installed old server keeps working.
4. **Relaunch the installed exe, not a remembered handle.** `start "" "%INSTALLED_EXE%"` after a zero exit code.

`[Run] ... skipifsilent` in `installer/RemoteControl.iss:135` means Setup will **not** start the app itself under `/VERYSILENT`, so step 4 is mandatory, not redundant [VERIFIED: `installer/RemoteControl.iss` line 135 read in tree; Inno docs on `skipifsilent`].

**Why `.cmd` and not `.ps1`:** PowerShell script execution is subject to `ExecutionPolicy`, which is machine/user configurable and can be `Restricted`. `cmd.exe` has no equivalent gate. The helper is four commands; the robustness is worth more than the ergonomics.

### Pattern 4 — Marker-file lifecycle (D-12/D-16)

The marker is written **pessimistically** (`ok:false, error:"installer"`) *before* the helper is spawned, so that any way the process dies leaves an honest record.

| Moment | Marker state | Who writes |
|--------|--------------|------------|
| Before spawning the helper | `{target, ok:false, error:"installer"}` | Server (about to exit) |
| Setup exits 0 | `{target, ok:true}` | Helper |
| Setup exits non-zero | unchanged (`ok:false`) + a line in `update.log` | Helper (log only) |
| Helper's PID wait times out | unchanged (`ok:false`) + a log line | Helper (log only) |
| Next server startup | read → held in memory → **file deleted** | New server |
| Reported | as `update.status.lastUpdate`, once | New server |

Two rules that are easy to get wrong: **delete on read, not on report** (a phone that never reconnects must not leave a permanent marker), and **an absent marker is the normal case** — never log an error for it, never surface it as a failure.

### Pattern 5 — Make the extension overwrite non-fatal to the server install

This is a **new recommendation**, not in CONTEXT, and it addresses the Open Question 1 risk.

`installer/RemoteControl.iss:102` currently reads:

```
Source: "..\extension\*"; DestDir: "{app}\extension"; Flags: ignoreversion recursesubdirs createallsubdirs
```

If Chrome holds a write lock on any file under `{app}\extension`, Inno's file-replace failure raises an Abort/Retry/Ignore dialog whose suppressed default is **Abort** — aborting the whole install, including the server exe that had nothing to do with the extension. Add `skipifsilent`-independent tolerance:

```
Source: "..\extension\*"; DestDir: "{app}\extension"; \
    Flags: ignoreversion recursesubdirs createallsubdirs restartreplace uninsrestartdelete
```

`restartreplace` makes Inno schedule a locked file for replacement at next boot (`MoveFileEx(MOVEFILE_DELAY_UNTIL_REBOOT)`) instead of erroring. The extension then updates on the next reboot rather than failing the whole install — a graceful degrade that lands in exactly the same "restart your browser" user-facing state D-18 already specifies.

**Caveat:** `restartreplace` on a per-user install without admin rights may itself fail (the pending-rename registry key is `HKLM`). If it does, the fallback is to accept the abort and surface it. **This directive must be tested, not assumed** — see Open Question 1. It is a one-line `.iss` change, which contradicts D-16's "No `.iss` change is needed"; D-16's claim is correct about the `[Run]` entry specifically and about the AppMutex mechanism, but not about extension-file locking, which the design did not consider.

### Pattern 6 — `ext.reload` guard: keyed on target version, in memory

D-18's "once per target version per process run" is precisely a `Option<String>` beside the extension session state:

```
on ext.hello { extVersion }:
    if extVersion != CARGO_PKG_VERSION
       and last_reload_attempted_for != Some(CARGO_PKG_VERSION):
        last_reload_attempted_for = Some(CARGO_PKG_VERSION)
        send ext.reload
```

Because `chrome.runtime.reload()` causes the extension to reconnect and send a fresh `ext.hello`, the guard is what breaks the loop: the second `ext.hello` carrying the *same old* version finds the guard already set and sends nothing. Reset the guard **never** during a process run — a server restart is the only reset, which is exactly the intent.

The extension side is a single arm added to the existing `switch (msg.t)` in `extension/background.js:140`:

```js
case "ext.reload":
  chrome.runtime.reload();
  break;
```

No `.catch()` needed — `reload()` returns void and terminates the worker.

### Pattern 7 — Row-state matrix (the Dart testing surface)

Each of the three rows is one of these states; the widget tests enumerate them.

| State | Trigger |
|-------|---------|
| `checking` | a check is in flight |
| `upToDate` | installed >= latest |
| `available(version, sizeBytes)` | latest > installed (D-08 requires the size) |
| `downloading(pct)` | APK/PC download in progress |
| `verifying` / `installing` / `restarting` | mirrors the `stage` vocabulary |
| `failed(errorCode)` | one of the seven D-11 codes, rendered as copy |
| `couldNotCheck` | feed fetch failed / rate-limited (D-22), with retry |
| `serverDisconnected` | no live authed socket (PC + extension rows) |
| `serverTooOld` | `err {code:"unknownType"}` came back for `update.check` (D-13) |
| `extensionUnknown` | `extConnected:false` — the extension has never connected |
| `unknownVersion` | a version string that failed to parse (Specifics: never "newer") |

### Anti-Patterns to Avoid

- **Accepting any wire-supplied locator.** Not a URL, not a filename, not an asset index, not "which of the three assets", not a hash. D-14. If a plan task's action mentions passing anything but a version string, it is wrong.
- **Reusing a resolved `browser_download_url` across time.** It 302s to a signed, time-limited CDN URL. Resolve immediately before downloading, every time.
- **Running `ureq` on the tokio runtime.** Blocks a worker for the whole download.
- **Buffering the download in memory.** `read_to_vec()` caps at 10 MB by default and would need `.limit()` raising — the 5 MB setup exe fits today and would silently break the day it grows. Stream with `as_reader()` + `io::copy` regardless of size.
- **Trusting `digest` to be present.** It is `null` for assets uploaded before 2025-06-03. A `None` digest must be a hard refusal (`checksum`), never a skipped verification — D-15 makes sha256 a gate.
- **Reporting `network` for an HTTP 403.** A rate-limited feed fetch is `ureq::Error::StatusCode(403)` because `http_status_as_error` defaults to `true`. Both 403 and a genuine socket failure map to the same user-facing "couldn't check" (D-22), but the log line must distinguish them or the first support question is unanswerable.
- **A second reconnect path for the PC update.** D-17: the existing `reconnect_fsm.dart` handles it. Adding a bespoke "waiting for server to come back" timer duplicates state that is already correct.
- **Hardcoding a Dart version constant anywhere.** The whole feature exists because that bug shipped four times (D-05, `app_version.dart` header comment).
- **Parsing and re-serialising `pubspec.yaml` / `Cargo.toml` in the release script.** Both files carry substantial load-bearing comments that a round trip would destroy. Regex-replace the one line.
- **Making a fresh `git tag` assumption.** `v1.3.x` tags are missing from history; "latest published" must come from the mirror's releases API (D-20's own refusal rule), not from `git describe`.

---

## Don't Hand-Roll

| Problem | Don't build | Use instead | Why |
|---------|-------------|-------------|-----|
| HTTPS GET with TLS, redirects, timeouts | A WinHTTP/`windows`-crate wrapper | `ureq` 3.3 | Cross-host redirect chains, chunked encoding, gzip, connection reuse, and a correct root store — all already right |
| Streaming a body to a file | Manual `read`/`write` loop with a buffer | `std::io::copy(&mut body.as_reader(), &mut file)` | Correct buffer sizing, correct partial-read handling, and it is one line |
| sha256 in Dart | Hand-rolled or a wrapper package | `package:crypto` `Hash.startChunkedConversion` | Dart's only sane digest; the chunked API is what keeps a 70 MB APK off the heap twice |
| sha256 in Rust | A new crate | `sha2` 0.11 already in the tree | Same major as `server-core`'s token hashing; zero new supply-chain surface |
| APK installation | A `am start -a VIEW` intent to the package installer | `PackageInstaller` session | The legacy `ACTION_VIEW`/`ACTION_INSTALL_PACKAGE` path is deprecated and gives no status callback. The session API is the only way to learn the outcome |
| Locating `%APPDATA%` | `std::env::var("APPDATA")` | `dirs::config_dir()` (in tree) | Already the project's answer for `config.toml` and `logs/`; keeps one convention |
| Waiting for a PID in the helper | A `timeout /t` loop, or a PowerShell `Wait-Process` | `tasklist /FI` + `ping -n 2 127.0.0.1 >nul` | `timeout` needs a console a detached process does not have; PowerShell needs an execution policy |
| Detecting "is a newer version available" | String comparison, or `f64` parsing of `"1.10.0"` | An explicit `(major, minor, patch)` tuple compare | `"1.10.0" < "1.9.0"` lexically, and `1.10` parses as a float smaller than `1.9`. Both are classic and both are wrong |
| Extension file distribution | A separate downloader in the server | The Inno installer's existing `{app}\extension` copy | D-18. It already ships in the setup exe (`RemoteControl.iss:102`) |
| Marker-file JSON | A hand-rolled key=value format | `serde_json` (in tree) | Three fields, but a `target` string could contain anything; escaping is not worth hand-writing |

**Key insight:** every "custom" temptation in this phase is a temptation to re-derive something the platform already decided — redirect semantics, digest streaming, package installation authority, version ordering. The phase's genuinely novel work is small: the sequencing of *who exits when*, and the discipline that the executing tier resolves its own file. Everything else should be a call into something that exists.

---

## Common Pitfalls

### Pitfall 1 — `ureq` has no default timeouts, so a stalled socket hangs the update thread forever

**What goes wrong:** The phone taps "Update PC", the server's update thread starts a download, the WiFi degrades to a black hole, and the thread blocks in `read()` indefinitely. The phone sits on `downloading 43%` forever, the `busy` guard refuses every retry, and the only fix is quitting the server from the tray.
**Why it happens:** Every `ConfigBuilder` timeout defaults to `None` except `timeout_await_100` (1 s) [VERIFIED: docs.rs ConfigBuilder]. "No timeout" is `ureq`'s deliberate default.
**How to avoid:** Set `timeout_global` on both agents. Suggested: **10 s** for the feed (a small JSON body; a slow response is a broken network), **120 s** for the download (5 MB over a bad link). Additionally set `timeout_connect` (~5 s) so DNS/TCP failures fail fast.
**Warning signs:** An update stuck at a fixed `pct` for more than a minute; a `busy` refusal that never clears.

### Pitfall 2 — A rate-limited feed is an `Err(StatusCode)`, not a network error

**What goes wrong:** The code matches only on transport errors, so an HTTP 403 from the rate limiter either panics on an `unwrap` or is reported as something unhelpful.
**Why it happens:** `http_status_as_error` defaults to `true`, so `ureq` turns 4xx/5xx into `Err(Error::StatusCode(n))` [VERIFIED: docs.rs Config]. Anonymous callers get 60 requests/hour/IP [VERIFIED: live `X-RateLimit-Limit: 60`].
**How to avoid:** Match `Error::StatusCode` explicitly. Map 403/429 and every transport error to the same user-facing `network` (D-11 has no `ratelimit` code, and adding one would break the locked vocabulary), but log them differently. Note that the phone and the PC are usually behind the *same* NAT, so they share the 60/hour budget — a debugging session that hammers the retry button can exhaust it for both.
**Warning signs:** "Couldn't check" appearing on all three rows simultaneously after repeated retries.

### Pitfall 3 — `/VERYSILENT` alone still shows the AppMutex dialog

**What goes wrong:** The helper races the server's exit, runs setup while the mutex is still held, and a modal *"Setup has detected that Remote Control is currently running…"* box appears on the desktop from a supposedly silent install. Setup then blocks forever waiting for a click that no one expects to give.
**Why it happens:** Source-verified [VERIFIED: `jrsoftware/issrc` `Setup.MainFunc.pas`]:

```pascal
while CheckForMutexes(ExpandedAppMutex) do
  if LoggedMsgBox(FmtSetupMessage1(msgSetupAppRunningError, ExpandedAppName),
     SetupMessages[msgSetupAppTitle], mbError, MB_OKCANCEL, True, IDCANCEL) <> IDOK then
    Abort;
```

`LoggedMsgBox` only short-circuits when `InitSuppressMsgBoxes` is set, and that flag is set only by `/SUPPRESSMSGBOXES` **combined with** a silent switch. The check also runs *before* the Preparing-to-Install stage, so `CloseApplications=yes` cannot rescue it.
**How to avoid:** Both belts. (a) The helper waits for the PID to exit — the mutex is a kernel object released on process death, including a hard kill, so PID death is a sufficient signal (`single_instance.rs` header documents this). (b) Pass `/SUPPRESSMSGBOXES` so that if the wait ever fails, the box defaults to `IDCANCEL` → `Abort` → a non-zero exit the helper can decode, instead of a stuck dialog.
**Warning signs:** A "silent" update that leaves a dialog on screen; the server never coming back and the marker never flipping to `ok:true`.

### Pitfall 4 — A blocked file replace aborts the whole install, not just the file

**What goes wrong:** Chrome has `{app}\extension\background.js` open, Inno cannot replace it, the suppressed Abort/Retry/Ignore default is **Abort**, and the server exe never gets replaced either. Exit code 5. The helper relaunches the old exe and the phone reports `installer` — with no hint that the *extension* was the cause.
**Why it happens:** `/SUPPRESSMSGBOXES`'s documented default answers include *"Abort in Abort/Retry situations"* [CITED: jrsoftware.org/ishelp/topic_setupcmdline.htm], and the file-replace failure path in `Setup.Install.pas` uses exactly `AbortRetryIgnoreTaskDialogMsgBox`. Suppression trades a stuck dialog for an aggressive default.
**How to avoid:** Pattern 5 (`restartreplace` on the extension `[Files]` entry) so a locked extension file degrades to next-boot replacement rather than aborting. Order the `[Files]` entries so the **server exe is listed first** — Inno processes them in order, so the critical artifact lands before the risky one. And log the setup's own log: pass `/LOG="%TEMP%\rc-setup.log"` from the helper so a failure is diagnosable at all.
**Warning signs:** `error:"installer"` reported with the old version still running, and Chrome was open at the time.

### Pitfall 5 — `canRequestPackageInstalls()` does not exist below API 26, and the project's minSdk is 24

**What goes wrong:** `PackageManager.canRequestPackageInstalls()` is API 26+; `Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES` likewise. The project's effective `minSdk` is Flutter 3.44.5's default of **24** [VERIFIED: `FlutterExtension.kt:26` in the local Flutter 3.44.5 install; `build.gradle.kts` uses `flutter.minSdkVersion`]. On an API 24/25 device those calls throw `NoSuchMethodError`.
**Why it happens:** The install-unknown-apps model changed from a global toggle to a per-app grant in Android 8.0 (API 26) [CITED: android-developers.googleblog.com "Making it safer to get apps on Android O"].
**How to avoid:** Guard with `Build.VERSION.SDK_INT >= Build.VERSION_CODES.O` in the Kotlin handler and return `true` for `canInstall` on older levels (the global setting governs there and the system dialog will surface it). Practically both users are on modern devices (STATE.md records the owner's Xiaomi on Android 16), so this is a crash-avoidance guard, not a feature.
**Warning signs:** A `PlatformException` from `canInstall` on any older test device.

### Pitfall 6 — `PendingIntent` mutability on API 31+ and the two-hop status flow

**What goes wrong:** `session.commit()` throws `IllegalArgumentException` on Android 12+ because the `PendingIntent` specified neither `FLAG_MUTABLE` nor `FLAG_IMMUTABLE`; or it works but `STATUS_PENDING_USER_ACTION` is never acted on, so the confirm dialog never appears and the row hangs on `installing`.
**Why it happens:** API 31 requires explicit mutability [CITED: Android Developers "All About PendingIntents"]. And `commit()` does not show a dialog itself: it *first* calls back with `STATUS_PENDING_USER_ACTION`, whose `Intent.EXTRA_INTENT` is the confirmation activity the app must launch.
**How to avoid:** Use `PendingIntent.FLAG_MUTABLE or PendingIntent.FLAG_UPDATE_CURRENT` for the status receiver, and in the receiver handle `STATUS_PENDING_USER_ACTION` by launching `EXTRA_INTENT` with `FLAG_ACTIVITY_NEW_TASK` (a `BroadcastReceiver` has no activity context). See Code Example 5.
**Warning signs:** No system dialog after tapping Update App; `IllegalArgumentException: Strongly consider using FLAG_IMMUTABLE`.

### Pitfall 7 — The app is killed mid-install, so `STATUS_SUCCESS` is never observed

**What goes wrong:** The Dart side awaits a success callback that never arrives, and the row is coded to treat "no callback" as a failure.
**Why it happens:** Replacing the APK terminates the app's process. The success broadcast is delivered to a process that is being torn down — or to the *new* app after restart, which has no in-flight state.
**How to avoid:** Design the phone's APK row so the **terminal states it can observe are `pendingUserAction`, `declined`, and `failure`** — success is confirmed by the app simply relaunching at a new `package_info_plus` version, exactly the way D-17 confirms the PC update by reconnecting. Do not persist an "installing" flag that a fresh launch would read as stuck.
**Warning signs:** A stuck "installing" row after a successful update.

### Pitfall 8 — Signature/downgrade refusals surface as an opaque `STATUS_FAILURE_CONFLICT`

**What goes wrong:** A debug-signed test APK over a release-signed install (or a lower `versionCode`) fails with a code the user cannot act on.
**Why it happens:** `INSTALL_FAILED_UPDATE_INCOMPATIBLE` (signature mismatch) maps to `STATUS_FAILURE_CONFLICT`; a lower `versionCode` is refused outright. D-20's "bump BOTH halves of `pubspec.yaml`" exists precisely because of the second [CITED: `pubspec.yaml` comment block and its four-release history].
**How to avoid:** Release builds always through `tools/release.ps1` with `key.properties` present (DISTRIBUTION.md's signing note). Surface `STATUS_FAILURE_CONFLICT` with actionable copy, and forward `EXTRA_STATUS_MESSAGE` to the log (not to the UI — it can be device-specific noise).
**Warning signs:** "App not installed" from the system dialog during on-device testing.

### Pitfall 9 — Rewriting version fields destroys file formatting

**What goes wrong:** The release script parses `pubspec.yaml` with a YAML module and writes it back; every comment in the file — including the 8-line block explaining why the build number must increase, and the per-dependency rationale comments the project's convention depends on — is gone. Same for `Cargo.toml`'s dependency justifications.
**Why it happens:** No mainstream YAML/TOML round-trip in PowerShell preserves comments.
**How to avoid:** Targeted, anchored, single-line regex replacement, each with a **post-condition assertion** that exactly one line changed:

| File | Anchor | Note |
|------|--------|------|
| `server/server-windows/Cargo.toml` | first `^\s*version\s*=\s*"..."` | The existing `build-installer.ps1` already uses exactly this anchor (`Select-Object -First 1`) — reuse its regex verbatim so the two cannot disagree |
| `app/remote_control/pubspec.yaml` | `^version:\s*(\d+\.\d+\.\d+)\+(\d+)$` | Must rewrite BOTH halves; the build number must strictly increase (currently `+8`) |
| `extension/manifest.json` | `"version": "..."` | Small enough that a JSON round trip is *almost* safe, but the file has no comments to lose either way — regex is still simpler and avoids `ConvertTo-Json`'s depth/escaping quirks |

**Warning signs:** A diff in `git status` that touches far more lines than three.

### Pitfall 10 — `gh` is not on PATH on this machine

**What goes wrong:** `gh release create ...` fails with "command not found" the first time the release script runs.
**Why it happens:** Verified: `gh.exe` exists at `C:\Program Files\GitHub CLI\gh.exe` (version **2.96.0**, 2026-07-02) and `command -v gh` finds nothing [VERIFIED: local filesystem + `gh --version`].
**How to avoid:** Resolve it defensively — `Get-Command gh` first, then the known absolute path, then a clear error naming both (the same three-candidate shape `build-installer.ps1` already uses for `ISCC.exe`). Do not hardcode the absolute path alone; it would break on any other machine.

### Pitfall 11 — Bumping `SERVER_PROTO_VERSION` changes the beacon payload

**What goes wrong:** A beacon fixture that pins `"proto": "1.7"` fails after the bump, and the failure looks unrelated to the update work.
**Why it happens:** `beacon.rs:56` embeds `SERVER_PROTO_VERSION` in the broadcast payload; `transport/mod.rs:22` re-exports the constant.
**How to avoid:** Check `protocol/fixtures/beacon/` before bumping and update it in the same task as the SPEC §2 edit, so the change is atomic.

---

## Code Examples

### 1. Feed fetch + streaming download (Rust, `server-windows`)

```rust
// Source: docs.rs/ureq/latest (Agent, Body, Config) — API shapes verified 2026-08-01
use std::time::Duration;
use ureq::Agent;

fn feed_agent() -> Agent {
    // Pitfall 1: ureq sets NO timeouts by default. Without these a black-holed
    // socket parks this OS thread forever and the `busy` guard never clears.
    Agent::config_builder()
        .timeout_global(Some(Duration::from_secs(10)))
        .timeout_connect(Some(Duration::from_secs(5)))
        .user_agent("RemoteControl-Updater")   // GitHub requires a UA; ureq/<ver> is fine too
        .build()
        .into()
}

fn fetch_latest(agent: &Agent) -> Result<Release, UpdateError> {
    // http_status_as_error defaults to TRUE: a rate-limited 403 arrives as
    // Err(Error::StatusCode(403)), NOT as a 403 response (Pitfall 2).
    let mut res = agent.get(RELEASES_API).call().map_err(map_ureq)?;
    // The feed is small; a limit is a DoS belt, not a functional constraint.
    let body = res.body_mut().with_config().limit(1 << 20).read_to_string()?;
    parse_release(&body)
}

fn download_to(agent: &Agent, url: &str, dest: &std::path::Path) -> Result<(), UpdateError> {
    // browser_download_url 302s to a DIFFERENT host (release-assets.github
    // usercontent.com) with a time-limited signed query. ureq follows
    // cross-host redirects by default (max_redirects = 10) and strips
    // Authorization on redirect (redirect_auth_headers = Never) — both correct
    // here, and we send no auth header anyway (D-01).
    let mut res = agent.get(url).call().map_err(map_ureq)?;
    let mut file = std::fs::File::create(dest)?;   // create() truncates any stale partial
    // as_reader() streams; read_to_vec() would buffer AND cap at 10 MB.
    std::io::copy(&mut res.body_mut().as_reader(), &mut file)?;
    file.sync_all()?;   // flush before hashing — a buffered tail would hash wrong
    Ok(())
}
```

### 2. sha256 verify with `sha2` already in the tree (Rust)

```rust
// Source: the identical Digest API already used by clip_thread::clip_fingerprint
use sha2::{Digest, Sha256};

fn file_sha256_hex(path: &std::path::Path) -> std::io::Result<String> {
    let mut file = std::fs::File::open(path)?;
    let mut hasher = Sha256::new();
    std::io::copy(&mut file, &mut hasher)?;   // Sha256 implements io::Write
    Ok(hex::encode(hasher.finalize()))        // hex 0.4 is already a dependency
}

/// D-15: verify BEFORE anything is executed; a mismatch deletes and never runs.
/// D-02: the API's digest is "sha256:<hex>" — strip the prefix, compare lowercase.
fn verify_or_delete(path: &std::path::Path, expected: &str) -> Result<(), UpdateError> {
    let want = expected.strip_prefix("sha256:").ok_or(UpdateError::Checksum)?;
    let got = file_sha256_hex(path)?;
    if got.eq_ignore_ascii_case(want) {
        Ok(())
    } else {
        let _ = std::fs::remove_file(path);    // never leave unverified bytes on disk
        Err(UpdateError::Checksum)
    }
}
```

### 3. Detached helper spawn (Rust) and the helper itself

```rust
// Source: doc.rust-lang.org std::os::windows::process::CommandExt + MS
// "Process Creation Flags". Child has no Drop impl, so not waiting on it is
// what lets it outlive this process.
use std::os::windows::process::CommandExt;
use std::process::{Command, Stdio};

const DETACHED_PROCESS: u32 = 0x0000_0008;
const CREATE_NO_WINDOW: u32 = 0x0800_0000;

fn spawn_helper(script: &std::path::Path) -> std::io::Result<()> {
    Command::new("cmd.exe")
        .args(["/c", &script.to_string_lossy()])
        .creation_flags(DETACHED_PROCESS | CREATE_NO_WINDOW)
        .stdin(Stdio::null())      // an inherited handle would keep this process's
        .stdout(Stdio::null())     // pipes alive and can block the child's writes
        .stderr(Stdio::null())
        .spawn()?;                 // deliberately NOT .wait() — we are about to exit
    Ok(())
}
```

```bat
@echo off
REM %TEMP%\rc-update-<pid>.cmd — generated by apply.rs. Four jobs, in order.
setlocal
set PID=__PID__
set SETUP=__SETUP_PATH__
set EXE=__INSTALLED_EXE__
set MARKER=__MARKER_PATH__
set LOG=__UPDATE_LOG__

REM 1. Wait for the server to die -> the AppMutex is released (Pitfall 3).
REM    `ping` not `timeout`: timeout needs a console this detached child lacks.
set /a N=0
:wait
tasklist /FI "PID eq %PID%" /NH 2>nul | find "%PID%" >nul || goto gone
set /a N+=1
if %N% GEQ 30 (
  echo [%DATE% %TIME%] server pid %PID% still alive after 30s; aborting >> "%LOG%"
  goto end
)
ping -n 2 127.0.0.1 >nul
goto wait
:gone

REM 2. Silent install. /SUPPRESSMSGBOXES is the belt for a mutex we somehow
REM    still hit; /LOG makes an installer failure diagnosable at all.
"%SETUP%" /VERYSILENT /NORESTART /SUPPRESSMSGBOXES /LOG="%TEMP%\rc-setup.log"
if errorlevel 1 (
  echo [%DATE% %TIME%] setup exited %ERRORLEVEL% >> "%LOG%"
  goto relaunch
)

REM 3. Zero exit -> flip the marker to ok:true (D-16).
> "%MARKER%" echo {"target":"__TARGET__","ok":true}

REM 4. [Run] carries skipifsilent, so Setup did NOT start it (RemoteControl.iss:135).
:relaunch
start "" "%EXE%"
:end
del "%SETUP%" 2>nul
endlocal
(goto) 2>nul & del "%~f0"
```

The last line is the standard `cmd` self-delete: `(goto) 2>nul` closes the batch context so the file is no longer locked, then `del "%~f0"` removes it.

### 4. Chunked sha256 over the downloaded APK (Dart)

```dart
// Source: pub.dev/packages/crypto — Hash.startChunkedConversion + AccumulatorSink
import 'dart:io';
import 'package:convert/convert.dart' show AccumulatorSink;
import 'package:crypto/crypto.dart';

/// Hashes without ever holding the ~70 MB file in memory (Pitfall: two copies).
Future<String> sha256OfFile(File file) async {
  final output = AccumulatorSink<Digest>();
  final input = sha256.startChunkedConversion(output);
  await for (final chunk in file.openRead()) {
    input.add(chunk);
  }
  input.close();
  return output.events.single.toString(); // lowercase hex
}
```

### 5. `PackageInstaller` session behind the MethodChannel (Kotlin)

```kotlin
// Source: developer.android.com PackageInstaller.Session + PackageInstaller
// Mirrors the hand-written multicast channel already in MainActivity.kt.
private fun install(apk: File, result: MethodChannel.Result) {
    val installer = packageManager.packageInstaller
    val params = PackageInstaller.SessionParams(
        PackageInstaller.SessionParams.MODE_FULL_INSTALL
    )
    val sessionId = installer.createSession(params)
    installer.openSession(sessionId).use { session ->
        session.openWrite("rc", 0, apk.length()).use { out ->
            apk.inputStream().use { it.copyTo(out) }
            session.fsync(out)                       // required before close
        }
        val intent = Intent(this, InstallResultReceiver::class.java)
        // API 31+ demands explicit mutability; the SYSTEM fills in the status
        // extras, so this one must be MUTABLE (Pitfall 6).
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S)
                PendingIntent.FLAG_MUTABLE else 0
        val pi = PendingIntent.getBroadcast(this, sessionId, intent, flags)
        session.commit(pi.intentSender)              // does NOT show a dialog itself
    }
    result.success(null)
}
```

```kotlin
// InstallResultReceiver.kt — commit() calls back here FIRST with
// STATUS_PENDING_USER_ACTION; the confirm dialog is an Intent we must launch.
class InstallResultReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.getIntExtra(PackageInstaller.EXTRA_STATUS, -1)) {
            PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                val confirm = IntentCompat.getParcelableExtra(
                    intent, Intent.EXTRA_INTENT, Intent::class.java
                )
                // A receiver has no activity context.
                confirm?.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                confirm?.let { context.startActivity(it) }
            }
            // STATUS_SUCCESS is usually NEVER seen: replacing the APK kills this
            // process (Pitfall 7). Success is confirmed by relaunching at a new
            // package_info_plus version, the D-17 pattern.
            else -> { /* forward status + EXTRA_STATUS_MESSAGE to Dart / log */ }
        }
    }
}
```

### 6. The unknown-apps grant check + route to settings (Kotlin)

```kotlin
// Source: developer.android.com PackageManager.canRequestPackageInstalls +
// Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES
"canInstall" -> {
    // API 26 introduced the per-app grant; minSdk here is 24 (Pitfall 5).
    val ok = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
        packageManager.canRequestPackageInstalls() else true
    result.success(ok)
}
"openInstallPermission" -> {
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
        startActivity(
            Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                   Uri.parse("package:$packageName"))
        )
    }
    result.success(null)
}
```

### 7. Version compare — the shared contract both sides must agree on

```dart
// lib/update/version.dart — pure, no I/O. Specifics: malformed compares as
// UNKNOWN, never as newer; an unknown must not trigger an update offer.
class SemVer implements Comparable<SemVer> {
  final int major, minor, patch;
  const SemVer(this.major, this.minor, this.patch);

  /// Accepts "1.4.0" and "v1.4.0". Returns null for anything else —
  /// including "1.4", "1.4.0-rc1", "" and "latest".
  static SemVer? tryParse(String s) {
    final m = RegExp(r'^v?(\d+)\.(\d+)\.(\d+)$').firstMatch(s.trim());
    if (m == null) return null;
    return SemVer(int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!));
  }

  @override
  int compareTo(SemVer o) => major != o.major
      ? major.compareTo(o.major)
      : minor != o.minor ? minor.compareTo(o.minor) : patch.compareTo(o.patch);
}

/// The ONLY question the UI asks. Null-in => false: unknown is never newer.
bool isNewer({required String candidate, required String installed}) {
  final c = SemVer.tryParse(candidate);
  final i = SemVer.tryParse(installed);
  if (c == null || i == null) return false;
  return c.compareTo(i) > 0;
}
```

**Pin the two implementations against each other**, exactly the way every codec in this project is pinned: add `protocol/fixtures/update/version-compare.json` as a table of `{a, b, expect}` triples that both the Dart test and the Rust test load. Include at minimum: `1.10.0 > 1.9.0` (the lexical trap), `1.4.0 == 1.4.0`, `1.4.0 < 1.4.1`, `v1.4.0` vs `1.4.0`, and the unknown cases `1.4`, `1.4.0-rc1`, `""`, `"latest"`, `"999999999999999999999.0.0"` (int overflow). This is the cheapest possible insurance against the two sides disagreeing about what "newer" means — which would show as a phone offering an update the server then refuses as `stale`.

**Pre-release note:** `-PreRelease` in D-20 produces tags like `v1.4.0-rc1` (the pattern `dist/` already shows). `tryParse` above returns `null` for those, so a pre-release is **never offered** to a client. That is a defensible reading of "latest-stable only" (Deferred: update channels) — but it must be a deliberate, documented choice in the plan, not an accident, because `/releases/latest` on GitHub already excludes pre-releases, making the client-side rejection a second belt rather than the primary mechanism.

---

## State of the Art

| Old approach | Current approach | When changed | Impact here |
|--------------|------------------|--------------|-------------|
| Publish sha256 in a sidecar `.sha256` file or in release notes | Per-asset `digest` field on the releases API | 2025-06-03 | D-03's "no manifest" decision is only viable because of this. Assets uploaded before that date have `digest: null` |
| `ureq` 2.x: `ureq::get(..).call()?.into_reader()`, `AgentBuilder` | `ureq` 3.x: `Agent::config_builder()`, `Response<Body>`, `body_mut().as_reader()`, `into_with_config().limit()` | ureq 3.0 (2025) | 2.x snippets do not compile against 3.x. Any training-data example is likely 2.x-shaped |
| `Intent(ACTION_INSTALL_PACKAGE)` / `ACTION_VIEW` on an `application/vnd.android.package-archive` | `PackageInstaller` session API | `ACTION_INSTALL_PACKAGE` deprecated in API 29 | The legacy path gives no status callback at all, which D-19's "declined returns the row to available" requires |
| Global "Unknown sources" toggle in Settings | Per-app `REQUEST_INSTALL_PACKAGES` + `canRequestPackageInstalls()` | Android 8.0 (API 26) | D-19's explainer sheet + settings intent is the modern shape |
| MV2 persistent background page | MV3 service worker (`extension/manifest.json` is already MV3) | Chrome 88+ / MV2 sunset | The worker is evictable; the existing 20 s `ext.ping` keepalive is why `ext.reload` can be delivered at all |
| `PendingIntent` implicitly mutable | Explicit `FLAG_MUTABLE` / `FLAG_IMMUTABLE` required | Android 12 (API 31) | Pitfall 6 |

**Deprecated / outdated — do not use:**

- `ureq::AgentBuilder`, `Response::into_reader()`, `Response::into_string()` — 2.x API, removed.
- `Intent.ACTION_INSTALL_PACKAGE` — deprecated API 29, and it cannot report an outcome.
- `PackageInstaller.SessionParams.setAllowDowngrade()` — system/privileged apps only; irrelevant to a self-updating user app and would not help anyway (D-26 forbids downgrades).
- `chrome.runtime.requestUpdateCheck()` — applies to Web Store-hosted extensions. This extension is loaded unpacked from `{app}\extension`, so it has no update URL and this API is meaningless here.

---

## Assumptions Log

Claims tagged `[ASSUMED]` in this research. The planner should gate anything here behind evidence before locking it into a task's success criterion.

| # | Claim | Section | Risk if wrong |
|---|-------|---------|---------------|
| A1 | `chrome.runtime.reload()` on an unpacked extension re-reads a **changed `manifest.json` version** from disk, not just the code | Unknown 4 / D-18 | D-18's entire mechanism fails silently: the extension row permanently reads "restart your browser" even after a successful install. SC7 unmet |
| A2 | Chrome does **not** hold exclusive write locks on `{app}\extension\*` that would fail Inno's overwrite | Pitfall 4 / Pattern 5 | Worse than A1: the *whole* PC install aborts (exit 5) whenever Chrome is open, which is most of the time. SC5 and SC7 both unmet |
| A3 | `restartreplace` works on a per-user (`PrivilegesRequired=lowest`) install without admin rights | Pattern 5 | The Pattern 5 mitigation does not mitigate; a different approach (e.g. install the extension to a versioned sibling directory) is needed |
| A4 | Inno aborts with a non-zero exit (code 2 family) when the AppMutex gate is hit under `/SUPPRESSMSGBOXES` | Pitfall 3 | The `IDCANCEL → Abort` path is source-verified; the specific numeric exit code is inferred from Inno's own `ecCancelledBeforeInstall = 2` constant rather than observed. Mitigated by treating **any non-zero exit as failure** rather than decoding codes — recommended regardless |
| A5 | A `.cmd` helper written to `%TEMP%` executes without interference from Controlled Folder Access, SmartScreen, or an AV heuristic | Pattern 3 | The helper never runs; the server exits and never comes back. D-25's copy covers the user experience but the update silently never happens |
| A6 | `ping -n 2 127.0.0.1 >nul` works inside a `DETACHED_PROCESS` `cmd.exe` child with null stdio | Pattern 3 / Code Example 3 | The wait loop spins at 100% CPU or exits instantly, racing the mutex (→ Pitfall 3) |
| A7 | The APK download's `browser_download_url` behaves identically to the setup exe's (one cross-host 302, signed, time-limited) | Unknown 5 | Only the setup-exe-shaped case was live-tested (on a third-party repo). Very likely identical — GitHub serves all release assets the same way — but not observed for a ~70 MB asset |
| A8 | Both users' devices are API 26+ so the `canRequestPackageInstalls` guard is never exercised | Pitfall 5 | Just a crash guard; low impact |
| A9 | The extension zip asset is downloaded by nobody — it exists for the bare-exe audience only, and the in-app extension path rides the installer exclusively | D-18 / D-20 | If the phone were ever expected to update the extension directly it could not (no filesystem access to `{app}`). Reading D-18 this way seems unambiguous, but the release script still publishes the zip, so the plan should state explicitly that no client consumes it |

---

## Open Questions

### 1. Does Chrome block Inno's overwrite of `{app}\extension`, and what does that do to the whole install?

- **What we know:** Chrome loads unpacked extensions from the filesystem directly and writes a `_metadata` folder into the directory [CITED: chromium-extensions group]. Anecdotal reports say the folder is locked while Chrome runs. Inno's file-replace failure raises an Abort/Retry/Ignore whose suppressed default is **Abort** [CITED: jrsoftware.org], and the abort takes the whole install with it.
- **What's unclear:** Whether the lock is real, whether it covers `background.js` and `manifest.json` or only `_metadata`, and whether `restartreplace` succeeds on a per-user install.
- **Recommendation:** This is the phase's highest-risk unknown and it is cheap to settle. Put a **`checkpoint:human-verify` task before the extension slice** with a five-minute manual procedure: install v1.4.0, load `{app}\extension` unpacked in Chrome, leave Chrome running, run the v1.4.0 setup exe again with `/VERYSILENT /SUPPRESSMSGBOXES /LOG="%TEMP%\t.log"`, then check `%ERRORLEVEL%` and grep the log for `ErrorReplacingExistingFile`. If it aborts, Pattern 5 (or a versioned-sibling install directory) becomes mandatory and the plan changes shape. **Do not plan the extension slice as if the answer is known.**

### 2. Does `chrome.runtime.reload()` pick up a changed manifest version?

- **What we know:** Chrome's own docs state that reloading an unpacked extension "is treated as an update" and fires `onInstalled` with reason `"update"` [CITED: developer.chrome.com/docs/extensions/reference/api/runtime]. An update path necessarily re-parses the manifest. Against that, extension-hot-reload tooling READMEs consistently warn that manifest changes need a manual `chrome://extensions` refresh.
- **What's unclear:** Whether that warning describes `chrome.runtime.reload()` or the weaker `chrome.tabs.reload()`-style approaches those tools also offer, and whether behaviour differs between Chrome and Edge.
- **Recommendation:** Fold into the same checkpoint as Question 1 — after the overwrite, the extension should reconnect and its `ext.hello` should carry the NEW version. Watching the server log for that one field is the entire test. If it does not, D-18's fallback copy ("restart your browser") is already specified, so the feature degrades rather than breaks; but the plan should not claim SC7 is met until observed.

### 3. Should the PC settings fallback do its own feed check, or link out?

- **What we know:** Explicitly Claude's Discretion. `shell/settings.rs` is 560 lines of egui running on the shared winit loop; the update thread and the feed parser already exist by the time settings needs them.
- **What's unclear:** Nothing technical.
- **Recommendation:** **Do its own check.** The infrastructure is already built and injected (the same `mpsc::Sender<UpdateCmd>` the WebSocket path uses), so a "Check for updates" button plus a version label is ~30 lines of egui and no new I/O. Linking out to a browser would make the PC path depend on the very thing (a browser, a manual download, SmartScreen) that D-01/D-16 exist to eliminate. Reuse the `watch::Receiver<UpdateProgress>` for the button's state so both surfaces show the same truth.

### 4. Where exactly does `update.log` live and who owns its rotation?

- **What we know:** D-24 says `%APPDATA%\RemoteControl\logs\update.log`. The server's own logs are `server.log.<date>` via `tracing-appender` daily rotation.
- **What's unclear:** `update.log` is appended by the **helper script** (a `cmd` process with no `tracing`), so it cannot participate in rotation and will grow unbounded — slowly, but forever.
- **Recommendation:** Accept unbounded growth (a few lines per update attempt is noise). Alternatively have the *server* truncate it at startup if it exceeds ~64 KB, which is three lines of Rust in the marker-read path. Decide in planning; do not leave it implicit.

### 5. What does the `-PreRelease` flag mean end-to-end?

- **What we know:** D-20 has the flag. `/releases/latest` excludes pre-releases. `SemVer.tryParse` above rejects `1.4.0-rc1`.
- **What's unclear:** Whether the owner expects a `-PreRelease` publish to be invisible to clients (the current design) or reachable somehow.
- **Recommendation:** Document it as invisible — a pre-release is for the owner's own manual UAT and is deliberately not offered to clients, which is consistent with "update channels other than latest-stable" being deferred. Say so in `DISTRIBUTION.md`.

---

## Environment Availability

| Dependency | Required by | Available | Version | Fallback |
|------------|-------------|-----------|---------|----------|
| `gh` CLI | `tools/release.ps1` publish + cross-repo tag | ✓ (NOT on PATH) | 2.96.0 (2026-07-02) at `C:\Program Files\GitHub CLI\gh.exe` | Resolve via `Get-Command` → known path → clear error. `git push --tags` + a manual upload is the degraded path |
| Inno Setup 6 `ISCC.exe` | `installer/build-installer.ps1` (called by the release script) | assumed ✓ (releases have shipped) | 6.3+ required for `WizardIsTaskSelected` | The existing script already emits a full install-instruction error |
| Rust toolchain / cargo | Server build | ✓ | pinned by `server/rust-toolchain.toml` | — |
| Flutter SDK | APK build | ✓ | **3.44.5 stable**, Dart 3.12.2, at `C:\dev\flutter` | — |
| Android release keystore + `key.properties` | A signed, upgradeable APK | assumed ✓ (v1.4.0 shipped signed) | — | **None. Blocking.** A debug-signed APK cannot upgrade a release-signed install (`STATUS_FAILURE_CONFLICT`). The release script must fail loudly if `android/key.properties` is absent rather than silently producing a debug-signed artifact |
| `git` | Dirty-tree check, tagging | ✓ | — | — |
| Public mirror repo `nandodeomkar/remote-control-releases` | Everything client-side | ✗ **404 — does not exist** | — | **None. Blocking, and it is an owner action outside the codebase** |
| Chrome or Edge with the extension loaded unpacked | Extension slice UAT | assumed ✓ | — | The extension row degrades to `extConnected:false`, which is a valid rendered state |
| Internet access from both devices | Everything | ✓ | — | D-22's "couldn't check" path |

**Missing dependencies with no fallback:**

- **The public mirror repo does not exist.** Confirmed by API. The release script's first action should be a reachability probe with a message naming the exact repo and the exact `gh repo create` command, not a raw `gh` failure.
- **Release signing** must be verified present, not assumed.

**Missing dependencies with fallback:** none.

---

## Validation Architecture

`workflow.nyquist_validation` is `true` in `.planning/config.json`.

### Test Framework

| Property | Value |
|----------|-------|
| Framework (Rust) | `cargo test` (built-in), workspace at `server/` |
| Framework (Dart) | `flutter_test` (SDK) + `test` for the pure `remote_protocol` package |
| Config file | `server/Cargo.toml` (workspace); `app/remote_control/pubspec.yaml`; `app/packages/remote_protocol/pubspec.yaml` |
| Quick run command (Rust) | `cargo test -p server-windows update` (from `server/`) |
| Quick run command (Dart) | `flutter test test/update/` (from `app/remote_control`) |
| Full suite (Rust) | `cargo test --workspace` (from `server/`) |
| Full suite (Dart) | `flutter test` + `dart test` in `app/packages/remote_protocol` |
| Shared fixtures | `protocol/fixtures/` — loaded by BOTH codecs; per-language copies are forbidden (SPEC §14) |

### Phase Requirements → Test Map

| Ref | Behavior | Test type | Automated command | File exists? |
|-----|----------|-----------|-------------------|--------------|
| D-09 | `update.*` round-trips byte-identically in Rust and Dart | codec/fixture | `cargo test -p server-core update_fixtures` / `dart test` in remote_protocol | ❌ Wave 0 (`protocol/fixtures/update/`) |
| D-13 / SC8 | A 1.7 server answers `err {code:"unknownType"}` for `update.check` and keeps the session | integration | `cargo test -p server-core unknown_type` | ✅ (existing §10 path; add an `update.*`-specific case) |
| D-13 | `update.check` / `update.apply` are dropped while paused | unit | `cargo test -p server-core pause_drops_update` | ❌ Wave 0 |
| D-14 / SC6 | A forged `update.apply` cannot make the server fetch an arbitrary URL | unit + structural | `cargo test -p server-core forged_apply_is_refused` and `cargo test -p server-core no_locator_fields_in_update_codec` | ❌ Wave 0 |
| D-15 | `downgrade` / `stale` / `busy` refusals, in that order | unit | `cargo test -p server-windows refusal_order` | ❌ Wave 0 |
| D-15 | sha256 mismatch deletes the file and never spawns | unit | `cargo test -p server-windows verify_or_delete` | ❌ Wave 0 |
| D-02 | Feed parse against a checked-in real API response | unit (both) | `cargo test -p server-windows feed_parse` / `flutter test test/update/release_feed_test.dart` | ❌ Wave 0 (shared fixture) |
| D-02 | A `null` digest is a hard refusal, not a skipped verification | unit | same fixture family, negative case | ❌ Wave 0 |
| Specifics | Malformed version compares as unknown, never newer; Rust and Dart agree | unit (both, shared fixture) | `cargo test version_compare` / `flutter test test/update/version_test.dart` | ❌ Wave 0 |
| D-07 | 24h cache TTL; a stale cache triggers a re-check, a fresh one does not | unit | `flutter test test/update/update_cache_test.dart` | ❌ Wave 0 |
| D-16 | Helper-script text is generated correctly (PID, paths, target substituted) | unit (golden string) | `cargo test -p server-windows helper_script_text` | ❌ Wave 0 |
| D-12 | Marker write → read → report → delete lifecycle; absent marker is normal | unit | `cargo test -p server-windows marker_lifecycle` | ❌ Wave 0 |
| D-18 | `ext.reload` guard fires once per target version per run; no loop when the version does not change | unit | `cargo test -p server-core ext_reload_guard` | ❌ Wave 0 |
| D-22/D-23 | Row-state matrix renders all 11 states | widget | `flutter test test/update/updates_screen_test.dart` | ❌ Wave 0 |
| D-06 | Settings badge appears when anything is out of date and clears | widget | `flutter test test/settings/settings_screen_test.dart` | ✅ (extend existing) |
| D-19 | `apk_installer.dart` no-ops on `MissingPluginException` | unit | `flutter test test/update/apk_installer_test.dart` | ❌ Wave 0 (mirror `multicast_lock` test) |
| SC1 | `release.ps1 -DryRun` bumps three files to the same version and changes exactly one line each | script test | `pwsh tools/release.ps1 -Version 9.9.9 -DryRun` + `git diff --stat` assertion | ❌ Wave 0 |
| SC4/SC5/SC7 | On-device end-to-end | **manual-only** | — (UAT gate plan) | n/a — genuinely requires two physical devices, a browser, and a real published release |

### Sampling Rate

- **Per task commit:** the touched side's quick command — `cargo test -p <crate> update` or `flutter test test/update/`.
- **Per wave merge:** `cargo test --workspace` from `server/` **and** `flutter test` from `app/remote_control` **and** `dart test` from `app/packages/remote_protocol` (the fixture contract spans all three).
- **Phase gate:** all three full suites green, plus the on-device UAT plan, before `/gsd-verify-work`.

### Wave 0 Gaps

- [ ] `protocol/fixtures/update/` — the `update.*` family, plus `version-compare.json` and a real captured `releases/latest` response. Loaded by both codecs
- [ ] `server/server-windows/tests/` or `#[cfg(test)]` modules under `src/update/` — feed parse, verify, refusal order, helper text, marker lifecycle
- [ ] `app/remote_control/test/update/` — version, feed, cache, row states, screen, installer channel
- [ ] Extend the existing Rust fixture harness registration (the pattern 11-03/11-07 established) to include the `update` family on both sides
- [ ] A `-DryRun` mode in `release.ps1` that is genuinely side-effect-free, so SC1 is testable without publishing

No framework installation is needed — every runner already exists in the tree.

---

## Security Domain

`workflow.security_enforcement: true`, `security_asvs_level: 1`, `security_block_on: "high"`.

This phase introduces the project's first **code-execution** capability: a message from the LAN causes an executable to be downloaded and run with the user's privileges. That is a categorical step up from every prior phase, all of which only injected input or read state.

### Applicable ASVS Categories

| ASVS category | Applies | Standard control |
|---------------|---------|------------------|
| V2 Authentication | yes (inherited) | `update.*` is post-auth only — SPEC §6 silently drops everything pre-auth. No new auth surface |
| V3 Session Management | yes (inherited) | Executor-bound per SPEC §11 (D-13); the existing revoke epoch force-disconnects a revoked device mid-update |
| V4 Access Control | **yes — new** | D-14: the server refuses any locator from the wire. The only authority the phone has is "please move to version X", and even that is re-validated against the server's own fetch (D-15 `stale`) |
| V5 Input Validation | **yes — the primary control** | `target` is validated as `^\d+\.\d+\.\d+$` **before** any use, then compared to `CARGO_PKG_VERSION` (downgrade) and to the freshly-resolved latest (stale). It is never interpolated into a path, a URL, or a command line without that validation |
| V6 Cryptography | **yes — new** | sha256 via `sha2` 0.11 (Rust) and `package:crypto` (Dart). Never hand-rolled. Verification is a gate, not a warning: a mismatch deletes the file (D-15) |
| V7 Error Handling & Logging | yes | D-11's fixed error vocabulary is itself a security control — it prevents a path or a URL from leaking to the phone. `update.log` may contain paths but never a token (SPEC §12) |
| V12 File & Resource | **yes — new** | Downloads go to `%TEMP%` (server) and the app cache (phone), both process-writable and neither user-facing. The filename is derived from a *server-side* template plus a validated version, never from the wire |
| V13 API & Web Service | yes | Outbound only, TLS via rustls with a pinned-by-vendoring root bundle. No inbound API is added |

### Known Threat Patterns for this stack

| Pattern | STRIDE | Standard mitigation | Status in this design |
|---------|--------|---------------------|-----------------------|
| Wire-supplied download URL → arbitrary code execution | **Elevation of Privilege** | Server resolves its own locator from a compile-time constant | D-14, enforced structurally by the trait signature (Pattern 2). **This is the phase's dominant risk** |
| Path traversal via `target` into the temp filename | Tampering | Strict `^\d+\.\d+\.\d+$` validation before any string interpolation | Must be an explicit task step — a `target` of `..\..\Startup\x` would otherwise reach a filename |
| Command injection via `target` into the helper `.cmd` | Elevation of Privilege | Same validation, plus quoting every substituted value in the generated script | The helper is generated text; `set TARGET=__TARGET__` with an unvalidated value is a `cmd` injection |
| Downgrade attack (forcing an old, vulnerable build) | Tampering | Refuse `target <= running` on both sides | D-15 + D-26 |
| MITM of the release feed or the asset | Tampering | TLS to `api.github.com` and to the CDN host; sha256 from the TLS-protected feed verified over the TLS-delivered file | The digest and the file arrive over independent TLS connections but from the same trust root — adequate for this threat model, and identical to what every package manager does |
| Serving a stale/replayed feed response | Spoofing | The server fetches the feed itself immediately before download; no caching of the resolved URL | Explicitly designed in (D-15 `stale`) |
| Unverified bytes executed on a partial download | Tampering | Verify **after** `sync_all()`, **before** spawn; delete on mismatch | D-15. `File::create` truncating a stale partial also matters |
| Local process on the PC forging `ext.reload` traffic | Spoofing | Already-accepted residual (SPEC §15): a local process able to open a loopback socket owns the machine | No change. Note `ext.reload` is srv→ext only — the extension never *sends* it, so nothing new is trusted |
| A second `update.apply` racing the first | DoS / corruption | `busy` refusal, in-flight flag checked first | D-15 |
| Token exfiltration via a build artifact | Information Disclosure | No token exists in any artifact | D-01 — this is the reason the mirror repo exists |
| Malicious/compromised mirror repo | Tampering | Out of scope: the mirror is owner-controlled, and compromising it is equivalent to compromising the private repo | Document as an accepted residual, consistent with SPEC §12's style |

**Recommended addition to SPEC §12** when it is amended for 1.8: a short paragraph recording that `update.apply` grants the phone *no* locator authority, and that this is the strongest constraint in the protocol — so a future reader cannot relax it without seeing why it exists.

---

## Sources

### Primary (HIGH confidence — official docs or verified live)

- `docs.rs/ureq/latest/` — crate overview, `Agent::config_builder`, rustls/webpki-roots defaults, default features
- `docs.rs/ureq/latest/ureq/config/struct.Config.html` — `max_redirects` = 10, `redirect_auth_headers` = Never, `max_response_header_size` = 64 KB
- `docs.rs/ureq/latest/ureq/config/struct.ConfigBuilder.html` — every timeout defaults to `None` except `timeout_await_100`; `http_status_as_error` = true
- `docs.rs/ureq/latest/ureq/struct.Body.html` — 10 MB default limit on `read_to_*`, `as_reader()` streaming, `with_config().limit()`
- `crates.io/api/v1/crates/ureq` — max_stable 3.3.0, newest published 2026-03-21, not yanked, 169,078,147 downloads, repo `algesten/ureq`
- `gsd-tools query package-legitimacy check --ecosystem crates ureq` — verdict OK, no reasons, no postinstall
- `pub.dev/api/packages/crypto` + `/publisher` + `/score` — 3.0.7, publisher `dart.dev`, 160/160 points, 9.9M downloads/30d
- `api.github.com/repos/jrsoftware/issrc/releases/latest` (live) — `digest: "sha256:<hex>"` present on every asset alongside `name`/`size`/`state`/`browser_download_url`
- Live response headers on the same call — `X-RateLimit-Limit: 60`, `Remaining`, `Used`, `Reset`, `Resource: core`
- Live redirect trace of a `browser_download_url` — exactly one 302 to `release-assets.githubusercontent.com` with a time-limited signed query
- `raw.githubusercontent.com/jrsoftware/issrc/main/Projects/Src/Setup.MainFunc.pas` — the AppMutex `LoggedMsgBox(..., MB_OKCANCEL, Suppressible=True, Default=IDCANCEL)` loop; `InitSuppressMsgBoxes` set only by `/SUPPRESSMSGBOXES` + silent; exit-code constants
- `raw.githubusercontent.com/jrsoftware/issrc/main/Projects/Src/Setup.Install.pas` — file-replace failure raises `AbortRetryIgnoreTaskDialogMsgBox`
- `jrsoftware.org/ishelp/topic_setupexitcodes.htm` — the full 0–8 exit code list
- `jrsoftware.org/ishelp/topic_setupcmdline.htm` — `/SILENT`, `/VERYSILENT`, `/SUPPRESSMSGBOXES`, `/NORESTART`, `/LOG`, `/CLOSEAPPLICATIONS`
- `jrsoftware.org/ishelp/topic_setup_appmutex.htm` — the AppMutex message text and semantics
- `developer.chrome.com/docs/extensions/reference/api/runtime` — `reload()`, `getManifest()`, and the explicit note that reloading an *unpacked* extension is treated as an update firing `onInstalled` with reason `"update"`
- `developer.android.com/reference/android/content/pm/PackageInstaller.Session` — createSession → openSession → openWrite → fsync → close → commit; status constants; extras; `setRequireUserAction` (API 31+)
- `raw.githubusercontent.com/dart-lang/sdk/main/sdk/lib/_http/http.dart` — `followRedirects = true`, `maxRedirects = 5` defaults
- Local: `C:\dev\flutter` — Flutter 3.44.5 stable / Dart 3.12.2; `FlutterExtension.kt` defaults minSdk 24, targetSdk 36, compileSdk 36
- Local: `gh --version` → 2.96.0 at `C:\Program Files\GitHub CLI\gh.exe`, not on PATH
- In-tree reads: `protocol/SPEC.md` (§1/§2/§6/§7/§10/§11/§12/§15), `installer/RemoteControl.iss`, `installer/build-installer.ps1`, `server/server-core/src/transport/{mod,ext,session}.rs`, `server/server-windows/src/{main,clip_thread,single_instance}.rs`, `server/server-windows/Cargo.toml`, `app/remote_control/{pubspec.yaml,lib/settings/app_version.dart,lib/platform/multicast_lock.dart}`, `android/app/src/main/AndroidManifest.xml`, `MainActivity.kt`, `extension/{manifest.json,background.js}`, `.planning/{STATE,ROADMAP,config.json}`, `DISTRIBUTION.md`

### Secondary (MEDIUM confidence — search-derived, cross-checked against an official source)

- github.blog changelog 2025-06-03 "Releases now expose digests for release assets" — introduction date; pre-2025-06-03 assets have `digest: null`
- Android Developers "All About PendingIntents" — `FLAG_MUTABLE` required from API 31 for a receiver the system fills in
- android-developers.googleblog.com "Making it safer to get apps on Android O" — `ACTION_MANAGE_UNKNOWN_APP_SOURCES` + `canRequestPackageInstalls()` introduced with the per-app model in API 26
- MS Learn "Process Creation Flags" — `DETACHED_PROCESS` 0x8, `CREATE_NO_WINDOW` 0x08000000, mutual exclusion with `CREATE_NEW_CONSOLE`
- `doc.rust-lang.org` std::process — `Child` has no `Drop`, so an unwaited child outlives the parent
- pub.dev `crypto` docs + community writeups — `Hash.startChunkedConversion` + `AccumulatorSink<Digest>` for streamed hashing

### Tertiary (LOW confidence — flagged for validation)

- Community reports that Chrome holds file locks on unpacked extension directories on Windows → **Open Question 1**, must be settled by UAT
- Extension hot-reload tooling READMEs claiming manifest changes need a manual `chrome://extensions` refresh → **Open Question 2**, contradicted by the official "treated as an update" statement
- The specific numeric exit code Inno returns when the AppMutex gate aborts under `/SUPPRESSMSGBOXES` → **A4**; mitigated by treating any non-zero as failure

---

## Metadata

**Confidence breakdown:**

| Area | Level | Reason |
|------|-------|--------|
| Standard stack (`ureq`, `crypto`) | HIGH | Versions, API shapes, defaults and legitimacy all verified against docs.rs / crates.io / pub.dev live in this session |
| GitHub releases feed contract | HIGH | Live API call against a real public repo confirmed the `digest` shape, the asset fields, the anonymous rate limit headers, and the cross-host signed redirect |
| Inno silent + AppMutex behaviour | HIGH | Read from the Inno Setup source, not from prose — the message-box call site, its suppressibility and its `IDCANCEL` default are quoted verbatim |
| Android `PackageInstaller` flow | MEDIUM-HIGH | Sequence and status constants from the official reference; the `FLAG_MUTABLE` and `EXTRA_INTENT` details are search-derived from Android Developers material and should be confirmed the first time the channel is run |
| Extension reload semantics | **MEDIUM** | The official "treated as an update" statement is strong, but the manifest-version-pickup case and the file-lock case are both unverified. Two `[ASSUMED]` entries and one checkpoint |
| Detached spawn + helper mechanics | MEDIUM | Flags and `Child`-drop semantics are solid; the `ping`-as-sleep and self-delete idioms inside a detached, null-stdio `cmd` are established practice but not verified in this environment |
| Release-tooling mechanics | HIGH | `gh`, `ISCC` resolution, artifact sizes, `dist/` gitignore status, tag history and version-field anchors all read from the actual repo and machine |
| Architecture / seam design | HIGH | Every recommendation is a clone of a pattern already shipped in this codebase (worker thread, `watch` push arm, `ServerDeps` injection, MethodChannel with a `MissingPluginException` no-op, shared fixture pinning) |

**Research date:** 2026-08-01
**Valid until:** 2026-08-31 for the stack facts (ureq/crypto/Flutter move slowly); **re-verify before execution** if more than ~2 weeks elapse, because `ureq` 3.x is still evolving its config surface and the GitHub `digest` field is barely a year old.
