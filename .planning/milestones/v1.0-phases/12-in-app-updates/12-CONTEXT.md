# Phase 12: In-App Updates - Context

**Gathered:** 2026-08-01
**Status:** Ready for planning
**Source:** PRD Express Path (docs/superpowers/specs/2026-08-01-in-app-updates-design.md, commit 3e0135f)

<domain>
## Phase Boundary

Both users can update every component of Remote Control without downloading a
file from GitHub by hand. The phone is the control surface: an Updates screen
reports the installed version of the Flutter app, the Windows server, and the
browser extension against the latest published release, and one tap installs
each. Release assets move to a public mirror repo so no auth token ships inside
any build artifact, and a single release script keeps all three versions in
lockstep and publishes them.

**In scope:** the mirror repo + `tools/release.ps1`; unified versioning; the
protoVersion 1.8 `update.*` message family plus srv→ext `ext.reload`; server-side
feed/download/verify/apply; the phone's Updates screen and APK self-install; the
extension's in-place reload; the PC settings fallback check.

**Out of scope (explicit):** auto-download before the user asks; delta or patch
updates; rollback to a previous version; update channels other than
latest-stable; iOS, Linux, or macOS clients; metered-network detection.

**Owner action outside the codebase:** the public mirror repo
`nandodeomkar/remote-control-releases` does not exist yet and must be created by
the owner before the release script can publish. Plans may assume its name but
must not assume it already exists.

**Known one-time cost, not a defect:** every already-installed client predates
this phase, so the first upgrade onto it is a manual install for both users.

</domain>

<decisions>
## Implementation Decisions

Every decision below is LOCKED — approved by the owner in the 2026-08-01
brainstorm and recorded in the design spec's Decisions table. Numbering is
this document's; the spec is the source of truth for prose.

### Distribution and versioning

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

### Control surface and cadence

- **D-06** — The phone drives all three components from one Updates screen
  reached from Settings. The PC settings window keeps its own fallback check so
  a broken or unpaired phone does not leave the PC with no update path.
- **D-07** — Manual button PLUS a quiet check on app launch, at most once per
  24 hours, result cached. Nothing downloads until a button is tapped. A stale
  or failed background check must never interrupt the user.
- **D-08** — The Updates screen shows the download size before a download
  starts (the APK is ~70 MB). No metered-network detection.

### Protocol (protoVersion 1.7 → 1.8, additive)

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

### Security (NON-NEGOTIABLE)

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

### Apply mechanics

- **D-16** — PC apply: download to `%TEMP%`, verify sha256, write
  `%APPDATA%\RemoteControl\update-result.json` as `{target, ok:false,
  error:"installer"}`, spawn a detached helper script, exit. The helper waits
  for the server PID to die (releasing `AppMutex=RemoteControl.SingleInstance`,
  `installer/RemoteControl.iss`), runs the setup
  `/VERYSILENT /NORESTART /SUPPRESSMSGBOXES`, rewrites the marker to `ok:true`
  on a zero exit code, then relaunches the installed exe. No SmartScreen prompt:
  the server's own HTTP client writes the file, so it never receives a
  Mark-of-the-Web.

  **CORRECTED 2026-08-01 by 12-RESEARCH.md** (this supersedes the design spec's
  wording, which said `/VERYSILENT /NORESTART` and "no `.iss` change is
  needed"):
  - `/VERYSILENT` ALONE DOES NOT suppress the AppMutex dialog. Verified from
    Inno's `Setup.MainFunc.pas`: the check is a suppressible `MB_OKCANCEL` whose
    suppression is armed only by `/SUPPRESSMSGBOXES` combined with a silent
    switch, and it runs BEFORE the `CloseApplications` stage. `/SUPPRESSMSGBOXES`
    is therefore mandatory, and the helper's wait-for-PID-exit is load-bearing
    rather than defensive — its suppressed default is `IDCANCEL`, so a still-held
    mutex aborts the install outright.
  - The "no `.iss` change is needed" claim holds ONLY for `[Run]`'s
    `skipifsilent` (the helper does the relaunch). It is OPEN for extension-file
    locking — see the D-18 note.
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

  **RISK RAISED 2026-08-01 by 12-RESEARCH.md (Open Question 1), not anticipated
  by the design spec:** if Chrome holds a write lock on `{app}\extension\*`,
  Inno's file-replace failure raises an Abort/Retry/Ignore whose SUPPRESSED
  DEFAULT IS ABORT — which aborts the ENTIRE server install, not just the
  extension. That would turn "the browser happened to be open" into a total
  PC-update failure, which is the common case rather than an edge case. Two
  consequences for planning: (a) whether Chrome actually holds such a lock must
  be settled by observation BEFORE the extension slice is planned in detail —
  it is a five-minute manual check; (b) if it does, the `restartreplace`
  mitigation the research proposes DOES require an `.iss` change, which is why
  D-16's "no `.iss` change is needed" is scoped to `[Run]` only. Do not treat
  the extension slice as low-risk glue.
- **D-19** — APK apply: download to the app cache with progress, verify sha256,
  install via `PackageInstaller` session behind a MethodChannel. Requires
  `REQUEST_INSTALL_PACKAGES` plus the one-time per-device "install unknown apps"
  grant; the same keystore means the signature matches and it is an upgrade.
  A declined system dialog returns the row to "update available" with no retry
  loop; a missing grant gets an explainer sheet and a button to the system
  settings intent.

### Release tooling

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

### Error handling (each row is a required behavior)

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

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### The design contract for this phase
- `docs/superpowers/specs/2026-08-01-in-app-updates-design.md` — the approved
  design. Source of truth for scope, protocol shape, apply mechanics, error
  vocabulary, and the out-of-scope list.

### Wire protocol
- `protocol/SPEC.md` — §2 versioning (currently 1.7, this phase takes it to
  1.8), §7 message registry, §10 unknown-type tolerance, §11 pause semantics
  and executor binding, §15 the localhost extension leg where `ext.hello`
  already carries `extVersion`.
- `protocol/fixtures/` — every message family is pinned by fixtures shared
  between the Rust and Dart decoders; `update.*` must be too.
- `protocol/schema/` — JSON schema for the envelope and payloads.

### Version-bearing files (all three must move together)
- `server/server-windows/Cargo.toml` — server version, embedded into the exe's
  VERSIONINFO by `build.rs` and read by the installer script.
- `app/remote_control/pubspec.yaml` — app version AND build number.
- `extension/manifest.json` — extension version.

### Packaging and distribution
- `installer/RemoteControl.iss` — `AppMutex=RemoteControl.SingleInstance`,
  `CloseApplications=yes`, the `[Run]` entry's `skipifsilent` flag, and the
  bundled `{app}\extension` folder. All four matter to the apply path.
- `installer/build-installer.ps1` — the existing build entry point the release
  script must call rather than reimplement.
- `DISTRIBUTION.md` — the current by-hand release and install procedure this
  phase automates; it needs updating.

### Code the new work must match or reuse
- `app/remote_control/lib/settings/app_version.dart` — the installed-version
  provider and the reasoning against hardcoded version constants.
- `app/remote_control/lib/platform/multicast_lock.dart` +
  `android/app/src/main/kotlin/dev/omkar/remotecontrol/MainActivity.kt` — the
  hand-written MethodChannel pattern the installer channel should follow.
- `app/remote_control/lib/net/reconnect_fsm.dart` — the existing reconnect
  behavior the PC update rides on (D-17).
- `server/server-windows/src/single_instance.rs` — the mutex name shared
  verbatim with the installer.
- `server/server-windows/src/apps_thread.rs`, `clip_thread.rs`,
  `audio_thread.rs` — the dedicated-OS-thread pattern for blocking work.
- `server/server-core/src/transport/session.rs` — `SERVER_PROTO_VERSION`.
- `extension/background.js` — the srv→ext command switch `ext.reload` joins.

</canonical_refs>

<specifics>
## Specific Ideas

- Release asset names follow the existing convention and are matched, not
  guessed: `RemoteControl-Setup-vX.Y.Z.exe`, `RemoteControl-vX.Y.Z.apk`,
  `RemoteControl-Extension-vX.Y.Z.zip`.
- Anonymous GitHub API requests are rate-limited to 60/hour per IP; a daily
  check spends one. No auth header is sent — sending one would reintroduce the
  token problem D-01 exists to avoid.
- `gh.exe` is installed at `C:\Program Files\GitHub CLI\gh.exe` and is NOT on
  PATH; the release script must not assume a bare `gh` resolves.
- The existing `dist/` directory already holds prior releases' three artifacts
  per version — the release script writes there.
- Malformed or unparseable version tags must compare as "unknown", never as
  "newer" — an unknown must not trigger an update offer.

</specifics>

<deferred>
## Deferred Ideas

- Auto-download before the user asks (rejected: ~70 MB of background data to
  save a few seconds).
- Delta / patch updates.
- Rollback to a previous version.
- Update channels other than latest-stable.
- Metered-network detection (costs a dependency; both users are known).
- iOS / Linux / macOS clients.

</deferred>

---

*Phase: 12-in-app-updates*
*Context gathered: 2026-08-01 via PRD Express Path*
