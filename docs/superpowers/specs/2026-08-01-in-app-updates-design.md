# In-App Updates — Design Spec

**Date:** 2026-08-01
**Status:** Approved (brainstorm session)
**Scope:** Flutter app, Windows server, browser extension, release tooling
**Protocol:** protoVersion 1.7 → 1.8 (additive)

## Summary

Add a "Check for updates" surface so the app, the Windows server, and the browser
extension can be updated without anyone downloading files from GitHub by hand.
The phone is the control surface: one Updates screen shows all three components,
and the PC updates itself on command from the phone. Release assets move to a
public mirror repo so no auth token has to ship inside any build artifact.

Today the owner builds three files, uploads them to the private repo, and his
wife installs them manually. After this change she taps a button.

## Decisions (from brainstorm)

| Question | Decision |
|---|---|
| Private-repo asset access | Second **public** repo `nandodeomkar/remote-control-releases` holding only binaries + notes. Source and `.planning/` stay private. No token in any artifact |
| Control surface | Phone drives all three; PC settings window keeps a fallback check |
| Check cadence | Manual button + quiet check on app launch, at most once per 24h, result cached. Nothing downloads until a button is tapped |
| Version identity | One `X.Y.Z` per release across all three components. Extension jumps 1.2.1 → next release version |
| Update manifest | None. The public releases API already returns tag, asset names, and a per-asset `sha256` digest |
| PC apply mechanism | Silent Inno install + self-relaunch via a detached helper script |
| Extension apply | Installer already overwrites `{app}\extension`; new server sends `ext.reload`, extension calls `chrome.runtime.reload()` |
| Release publishing | `tools/release.ps1` bumps all three versions, builds all three artifacts, publishes to the mirror |

## Distribution model

`https://api.github.com/repos/nandodeomkar/remote-control-releases/releases/latest`
is the sole source of truth. It returns `tag_name`, and per asset: `name`,
`browser_download_url`, `size`, and `digest` (`"sha256:<hex>"` — already present
on the existing v1.4.0 assets). Anonymous requests are rate-limited to 60/hour
per IP; a daily check spends one.

Installed version always comes from the package itself, never a hardcoded
constant — the drift that pinned `pubspec.yaml` at `1.0.0+1` across four
releases is exactly the failure this feature cannot tolerate:

- **App** — `package_info_plus`, as `settings/app_version.dart` already does.
- **Server** — `env!("CARGO_PKG_VERSION")`.
- **Extension** — `chrome.runtime.getManifest().version`, already sent to the
  server as `ext.hello`'s `extVersion` (protocol SPEC §15).

## Protocol additions (protoVersion 1.8)

| Message | Dir | Required payload | Optional |
|---|---|---|---|
| `update.check` | C→S | — (`p` is `{}`) | — |
| `update.status` | S→C | `serverVersion` (string), `extConnected` (bool) | `extVersion` (string; absent when the extension has never connected), `lastUpdate` (object, below) |
| `update.apply` | C→S | `target` (string, `X.Y.Z`) | — |
| `update.progress` | S→C | `stage` (string) | `pct` (integer 0–100), `version` (string), `error` (string) |
| `ext.reload` | srv→ext | — (`p` is `{}`) | — |

`stage` vocabulary: `checking`, `downloading`, `verifying`, `installing`,
`restarting`, plus the terminals `uptodate` and `failed`. `pct` accompanies
`downloading` only — the other stages have no meaningful fraction and omit it.
`error` is a fixed vocabulary, never free text and never a path: `network`,
`checksum`, `disk`, `installer`, `downgrade`, `stale`, `busy`.

`lastUpdate` is `{target: string, ok: bool, error?: string}` and reports the
outcome of the **previous** update attempt, read at startup from the marker file
described under Data flow. It is present only when a marker exists, and the
server clears the marker once it has been reported. It is the only way a failed
install can be diagnosed from the phone: the process that would have reported
the failure had already exited to let the installer run.

`update.check` and `update.apply` are executor-bound (SPEC §11) — refused while
paused. Both are additive, so a 1.7 server answers with
`err {code:"unknownType"}` and keeps the session alive (SPEC §10); the phone
renders that as "server too old to update itself".

### Security rule

`update.apply` carries a version string and nothing else. The server resolves the
asset URL and its sha256 itself, from the compiled-in repo constant, and refuses
any target that is not the current published latest. Accepting a URL or a hash
from the wire would convert a paired phone — or anything that got a token — into
arbitrary code execution on the PC. This rule is not negotiable for
convenience later.

Additional server-side gates:

- Refuse a `target` lower than or equal to the running version (`downgrade`).
- Refuse a `target` that does not match the version the server itself just
  resolved as latest (`stale`) — the phone's cached feed can be up to 24 hours
  old, and the server trusts only what it fetched.
- Refuse a second `update.apply` while one is in flight (`busy`).
- Verify sha256 before the installer is ever spawned; a mismatch deletes the
  file and never executes it.

## Data flow

1. Phone opens Settings → Updates. It sends `update.check` and receives the
   server's and extension's installed versions. Independently it fetches the
   release feed and renders three rows.
2. **Update app** — download the APK to the app cache with progress, verify
   sha256, hand the file to `PackageInstaller`. Android shows its own confirm
   dialog. Same keystore means the signature matches and the install is an
   upgrade, not a fresh install.
3. **Update PC** — phone sends `update.apply {target}`. The server re-resolves
   the asset, downloads to `%TEMP%`, verifies sha256, writes a helper script,
   spawns it detached, and exits. The helper waits for the server PID to die
   (releasing `AppMutex=RemoteControl.SingleInstance`), runs the setup with
   `/VERYSILENT /NORESTART`, then relaunches the installed exe. No `.iss` change
   is needed — its `[Run]` entry is already `skipifsilent`. No SmartScreen
   prompt either: the server's own HTTP client writes the file, so it never
   receives a Mark-of-the-Web.
4. Before spawning the helper, the server writes
   `%APPDATA%\RemoteControl\update-result.json` with `{target, ok:false,
   error:"installer"}`. The helper rewrites it to `ok:true` after a zero exit
   code. Whichever server comes back reads the marker at startup and reports it
   as `update.status`'s `lastUpdate`, then deletes it. Without this marker a
   failed install is indistinguishable from a slow one, because the process that
   knew about the failure had to exit for the installer to replace it.
5. The socket drops during the swap. The phone's existing reconnect FSM rides it
   out and re-checks on reconnect, which is what confirms the new version.
6. **Extension** — no phone action. The installer has already overwritten
   `{app}\extension`. The new server compares `ext.hello`'s `extVersion` to its
   own version and, on mismatch, sends `ext.reload` **once per target version
   per process run** (in-memory guard). The extension calls
   `chrome.runtime.reload()`, which re-reads the files from disk. If the
   versions still disagree after that, no second attempt is made — the phone
   row falls back to "restart your browser".

## Components

### Phone — new `lib/update/`

One job per file, so each can be tested without the others:

- **`version.dart`** — parse and compare `X.Y.Z`. Pure, no I/O. Malformed tags
  compare as "unknown", never as "newer".
- **`release_feed.dart`** — GET the releases API, return
  `Release{version, assets:[{name, url, sizeBytes, sha256}]}`. Uses
  `dart:io HttpClient`, not the `http` package — the same call the project
  already made choosing `RawDatagramSocket` over a stale wrapper.
- **`update_cache.dart`** — last-check timestamp and last-seen version in
  `shared_preferences` (non-secret, so never secure storage). 24h TTL.
- **`apk_download.dart`** — stream to the app cache directory with progress,
  verify sha256, delete the file on any failure path.
- **`apk_installer.dart`** — `MethodChannel('remote_control/installer')` with
  `canInstall`, `openInstallPermission`, and `install`. Mirrors the existing
  hand-written `platform/multicast_lock.dart` pattern, including its
  `MissingPluginException` no-op contract so widget tests never touch the
  channel.
- **`update_providers.dart`** — Riverpod wiring: feed + installed app version +
  server-reported versions → three row states.
- **`updates_screen.dart`** — the three rows, entered from Settings; badge dot
  on the Settings entry when anything is out of date.

Android side: ~40 lines of Kotlin in `MainActivity.kt` opening a
`PackageInstaller` session and committing it. Manifest gains
`REQUEST_INSTALL_PACKAGES`; `INTERNET` is already declared.

New Dart dependency: `crypto` (sha256 — Dart has no built-in digest).

### Server — new `server-windows/src/update/`

- **`feed.rs`** — fetch and parse the release feed. Mirrors `release_feed.dart`
  and is pinned to it by a shared fixture.
- **`download.rs`** — temp-file download plus sha256 verification, using the
  `sha2` already in the tree.
- **`apply.rs`** — helper-script generation and the detached spawn
  (`DETACHED_PROCESS | CREATE_NO_WINDOW`).
- **`update_thread.rs`** — owns the blocking work off the async runtime, the
  same shape as the existing `apps_thread` / `clip_thread` / `audio_thread`.

One new crate: **ureq 3.3** (blocking, rustls) — appropriate for a dedicated OS
thread and it avoids pulling a second async stack in beside tokio.

`server-core` gains only the `update.*` codecs and an `UpdateExecutor` trait
injected through `ServerDeps`, preserving its zero-Windows-dependencies
invariant. The `ext.reload` decision lives in `server-core` beside the existing
extension session handling.

The PC settings window (`shell/settings.rs`) gains an Updates section: current
version, a check button, and the same apply path the phone command uses.

### Release tooling — `tools/release.ps1`

`-Version X.Y.Z [-PreRelease] [-DryRun]`. Refuses a dirty tree, and refuses a
version at or below the latest published. Then:

1. Bump `server/server-windows/Cargo.toml`, `app/remote_control/pubspec.yaml`
   (**both halves** — Android refuses an install whose build number did not
   increase), and `extension/manifest.json`.
2. Build the APK, the setup exe (through the existing
   `installer/build-installer.ps1`), and the extension zip into `dist/`.
3. Print the three sha256 values.
4. Tag both repos; publish the release with all three assets to the public
   mirror.

## Error handling

| Failure | Behavior |
|---|---|
| No internet, API down, or rate-limited | Row reads "couldn't check" with a retry button. The daily background check fails silently — it never interrupts |
| sha256 mismatch | Abort, delete the temp file, report `failed` / `checksum`. Unverified bytes are never executed |
| Download interrupted or disk full | Abort, delete the partial file, report `failed` / `disk` |
| Installer exits non-zero | The helper relaunches the still-installed old exe, leaves the marker at `ok:false`, and appends to `%APPDATA%\RemoteControl\logs\update.log`. The phone shows the failure from `lastUpdate` on the next `update.status` |
| Server never comes back | The existing reconnect FSM handles it; after its timeout the row reads "PC didn't come back — start it from the Start Menu" |
| User declines the Android install dialog | The row returns to "update available". No retry loop, no nagging |
| "Install unknown apps" not granted | Explainer sheet plus a button to the system settings intent |
| Chrome blocks the extension overwrite | `ext.reload` is a no-op; the row falls back to "restart your browser" |
| Offered version at or below installed | Never offered. Downgrade is refused on both sides |

The APK is roughly 70 MB, so the row shows the download size before the user
commits to it. No metered-network detection: it costs a dependency and both
users are known.

## Testing

**Dart unit** — version compare including malformed tags; feed parse against a
checked-in fixture of a real API response; cache TTL; the row-state matrix
(up-to-date, available, checking, error, server-disconnected, server-too-old).

**Dart widget** — the updates screen in each state; the Settings badge appears
and clears.

**Rust unit** — feed parse against the same shared fixture; sha256 verification
over a temp file; helper-script text; the `ext.reload` guard, asserting no loop
when the reported version does not change after a reload.

**Rust codec** — `update.*` round-trip fixtures in `protocol/fixtures/`, plus
the 1.7-server `unknownType` path.

**On-device UAT** — publish a real rc release; update the PC from the phone;
confirm the extension reloads without a browser restart; self-update the APK.

## Implementation order

The pieces have one hard ordering constraint: nothing client-side can be tested
end to end until a real release exists in the mirror repo. So the tooling comes
first, not last.

1. **Mirror repo + `tools/release.ps1`.** Create the public repo, unify the
   three version fields, and publish one release through the script. This is
   also the first proof that unified versioning holds.
2. **Protocol 1.8.** Codecs in `server-core` plus fixtures in
   `protocol/fixtures/`, and the Dart side in `packages/remote_protocol`. Both
   decoders pinned to the same fixtures, as every other message family already
   is.
3. **Server update path.** `feed.rs` / `download.rs` / `apply.rs` /
   `update_thread.rs`, the marker file, and the PC settings section. Testable
   from the PC alone, before any phone work exists.
4. **Phone update path.** `lib/update/`, the Kotlin installer channel, the
   Updates screen, the Settings badge.
5. **Extension reload.** The `ext.reload` message, the version-mismatch guard,
   and the extension handler.
6. **On-device UAT** across a real rc → stable upgrade.

Steps 3, 4, and 5 are independent of each other once step 2 lands.

## Out of scope

Auto-download before the user asks; delta or patch updates; rollback to a
previous version; update channels other than latest-stable; iOS, Linux, or macOS
clients.
