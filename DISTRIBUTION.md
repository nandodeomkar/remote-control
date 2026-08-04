# Distribution Guide

How a Remote Control release is cut, where it lands, and how it reaches a
phone and a PC.

## 1. Releasing

One command makes a release exist:

```
.\tools\release.ps1 -Version 1.5.0
```

`tools/release.ps1` is the whole procedure. Nothing is built, bumped, tagged
or published by hand — a release assembled by hand is how three components
end up claiming three different versions.

**Preview first.** `-DryRun` is side-effect-free: it runs every preflight,
prints one `BUMP <path> <old> -> <new>` line per version file and the exact
command line of every later stage prefixed with `DRYRUN `, and writes,
builds, tags and publishes nothing.

```
.\tools\release.ps1 -Version 1.5.0 -DryRun
```

`tools/verify-release-dryrun.ps1` is the automated proof of that claim: it
runs the dry run in a child PowerShell host and asserts three bump lines at
one version and a byte-identical `git status --porcelain` before and after.

### The six stages

| Stage | What it does |
|---|---|
| 1. Preflight | Version format, clean tree, `gh`, release keystore, and the mirror's currently published latest. |
| 2. Bump | Rewrites the three version-bearing files to one `X.Y.Z`. |
| 3. Build | `dist\RemoteControl-vX.Y.Z.apk`, `dist\RemoteControl-Setup-vX.Y.Z.exe`, `dist\RemoteControl-Extension-vX.Y.Z.zip`. |
| 4. Hash | Prints the three sha256 values, so the published digests can be checked against what this machine actually built. |
| 5. Tag | Commits the bump as `chore(release): vX.Y.Z`, tags the private repo, pushes both. |
| 6. Publish | `gh release create` on the public mirror, carrying all three assets. |

### The five refusals

Each one throws a message that says what to do about it:

- **Dirty working tree** — a release must be reproducible from its own tag.
  Commit or stash first. (`dist/` is gitignored and never appears here.)
- **A version at or below the mirror's published latest** — clients only ever
  move forward, so such a release would be invisible at best and a downgrade
  at worst. Versions are compared as integer triples, never as strings.
- **Missing `app/remote_control/android/key.properties`** — without it
  `flutter build apk --release` still succeeds but DEBUG-signs the APK, and a
  debug-signed APK can never upgrade a release-signed install (Android rejects
  it with `STATUS_FAILURE_CONFLICT`).
- **`gh` not found** — looked for on PATH, then at
  `C:\Program Files\GitHub CLI\gh.exe`. Install with
  `winget install --id GitHub.cli -e -s winget`, then `gh auth login` once.
- **The mirror unreachable, or not yet created** — the published latest cannot
  be confirmed without it, and publishing over an unknown latest risks a
  downgrade.

Under `-DryRun` the two environment-state refusals (dirty tree, unreachable
mirror) print the identical message and continue, so the preview stays
runnable mid-work. The argument refusals (bad version format, a version at or
below the published latest) refuse in both modes.

### One-time prerequisites

- **[Inno Setup 6](https://jrsoftware.org/isdl.php)** (6.3 or newer — the
  script uses `WizardIsTaskSelected`). A per-user install works; no admin
  rights needed. `winget install --id JRSoftware.InnoSetup -e -s winget`.
- **The GitHub CLI**, authenticated as the repo owner (`gh auth status`).
- **An Android release keystore.** Create it with `keytool` (ships with the
  JDK bundled in Android Studio) and store the `.jks` OUTSIDE the repo:

  ```
  keytool -genkey -v -keystore C:/Users/YOUR_NAME/keys/remotecontrol-release.jks -keyalg RSA -keysize 2048 -validity 10000 -alias upload
  ```

  Then copy `app/remote_control/android/key.properties.template` to
  `key.properties` in the same directory and fill in the four fields
  (store/key passwords, alias, keystore path — forward slashes). The file is
  gitignored; never commit it. The release script refuses to run without it.

The bare `cargo build --release -p server-windows` still works for
development and still lands a self-contained
`server/target/release/server-windows.exe` — but do not hand that out: it has
no shortcuts, no uninstaller, and its autostart entry points wherever the file
happens to sit.

## 2. Two repositories

| Repository | Holds |
|---|---|
| `nandodeomkar/remote-control` (private) | Source, `.planning/`, history, and the release tags. |
| `nandodeomkar/remote-control-releases` (public) | Only the three binaries per tag, and release notes. No source, no `.planning/`. |

The mirror is public so that **no auth token ever has to ship inside a build
artifact**: a token embedded in an APK is extractable by anyone who downloads
it, and a fine-grained PAT expires, which would break every installed client
the day it rotated. Clients read
`https://api.github.com/repos/nandodeomkar/remote-control-releases/releases/latest`
anonymously, with no credential at all. The release script authenticates only
through the operator's own `gh` login, which never enters an artifact.

Anonymous GitHub API reads are rate-limited to 60/hour per IP. A daily check
spends one, and the phone and the PC share that budget when they sit behind
one NAT.

## 3. One version across three components

Every release carries ONE `X.Y.Z` across all three components, even when a
component did not change. `tools/release.ps1` enforces it at build time, in
one place, instead of three runtime constants that drift — which is exactly
the bug that pinned `pubspec.yaml` at `1.0.0+1` across four shipped releases.

| File | Anchor | Note |
|---|---|---|
| `server/server-windows/Cargo.toml` | first `version = "..."` line | The same anchor `installer/build-installer.ps1` reads, so the two scripts cannot disagree about where the server's version lives. It is also the exe's VERSIONINFO. |
| `app/remote_control/pubspec.yaml` | `version: X.Y.Z+N` | **Both halves.** |
| `extension/manifest.json` | `"version": "..."` | The extension joined the unified line at 1.5.0, from 1.2.1. |

The build number after the `+` in `pubspec.yaml` is Android's `versionCode`
and **must strictly increase**: Android refuses to install a lower code over a
higher one. The script increments it on every release and aborts if it would
not increase.

The rewrite is an anchored single-line regex splice, never a YAML/TOML/JSON
round trip — both `Cargo.toml` and `pubspec.yaml` carry load-bearing comments
that a parse-and-reserialise would silently delete. Exactly one line per file
may change, and that line must contain the new version, or the release aborts
before anything is built.

## 4. Pre-releases

```
.\tools\release.ps1 -Version 1.6.0 -PreRelease
```

`-PreRelease` publishes the mirror release marked as a pre-release, for the
owner's own testing. **A pre-release is never offered to clients**, by
design and twice over: GitHub's `releases/latest` endpoint — the only one any
client reads — excludes pre-releases, and the client version parser rejects an
`X.Y.Z-rcN` tag as unparseable.

That is the deliberate reading of "latest stable only". There is no beta
channel, no opt-in ring, and no channel selector anywhere in the app or the
server; other update channels are out of scope. A stable tag is required
before any client can be offered anything.

## 5. Installing an update

The **in-app path is the normal route** for all three components: on the
phone, *Settings → Updates* shows what is installed, what is latest, and
offers the update. Accepting it updates the phone's APK; the PC's server (and
the extension bundled inside its installer) updates the same way from the same
release. Nothing has to be downloaded, unzipped or hand-installed.

> Status: the in-app Updates screen ships in **1.6.0**. `1.5.0` is the first
> release published through `tools/release.ps1` and exists so that there is a
> real, anonymously readable feed for the update path to check against; it
> cannot itself be tapped to install.

The manual route below remains, for first installs and for recovery when the
in-app path cannot be used.

### Windows (the PC being controlled)

1. Download `RemoteControl-Setup-vX.Y.Z.exe` from the mirror's Releases page
   and run it.
2. SmartScreen will show "Windows protected your PC" (unknown publisher — the
   setup exe is unsigned). Click **More info**, then **Run anyway**.
3. The wizard asks for nothing but two checkboxes — a desktop shortcut and
   start-with-Windows, both on by default. No admin rights, no UAC prompt: it
   installs into the user's own `%LOCALAPPDATA%\Programs\RemoteControl`.
4. On the Windows Firewall prompt at first launch, allow access on **Private**
   networks.
5. The tray icon appears when the server is up. Afterwards it can be started
   from the Start Menu (search "Remote Control") or the desktop shortcut.

The browser extension is bundled inside the setup exe (installed to
`%LOCALAPPDATA%\Programs\RemoteControl\extension`, with a Start Menu shortcut
that opens that folder), so it can never drift out of sync with the server it
talks to. The standalone
`RemoteControl-Extension-vX.Y.Z.zip` on the release is for anyone running the
bare exe: unzip it and load the `extension` folder unpacked in Chrome or Edge
— the zip's own `README.md` walks through it.

**Upgrading by hand:** run the newer setup exe over the top. It keeps the
install location, settings, and paired devices. If the server is running,
Setup asks for it to be closed first — quit it from the tray menu so it can
save its config cleanly.

**Logs:** the server runs windowed with no console, so nothing is printed
anywhere visible. It writes a rolling daily log to
`%APPDATA%\RemoteControl\logs\server.log.<date>` — the first place to look
when something misbehaves. Set `RUST_LOG=debug` before launching for more
detail. The files are dated in UTC, so late-evening local sessions land in the
next day's file.

**Uninstalling:** Settings → Apps → *Remote Control* → Uninstall. That removes
the exe, both shortcuts, and the autostart entry, then asks whether to delete
`%APPDATA%\RemoteControl` (settings, paired devices, and logs). Answering No
keeps a later reinstall paired.

### Android (the phone doing the controlling)

1. Get `RemoteControl-vX.Y.Z.apk` onto the phone any way you like (Drive /
   USB / chat), or download it directly from the mirror's Releases page.
2. Android blocks unknown sources by default — when prompted, allow
   **Install unknown apps** for the app you are installing from, then install.

### Pairing

1. Phone and PC must be on the **same WiFi network**.
2. On the PC, open the tray menu and start pairing — the pair window shows a
   QR code and a 6-digit PIN, valid for 60 seconds.
3. On the phone, pick the PC from the device list and tap **Scan QR**
   (or type the PIN instead).
4. After the first pair, the phone reconnects automatically.

## 6. Known one-time cost

**Every client installed before this update path existed has to be upgraded by
hand, once.** Both users are in that position: their installed app and server
predate the in-app updater, so nothing on them can offer the first update to
themselves. Download the APK and the setup exe from the mirror and install
them the manual way above; from the next release onwards the in-app path takes
over.

This is expected, not a defect. No migration code exists for it and none is
planned — writing an updater into a build that is already on someone's phone
is not possible, and the cost is two manual installs, once.

**Owner migration note (one-time, from the package rename):** the app id
changed from `com.example.remote_control` to `dev.omkar.remotecontrol`, so
existing installs of the old id became orphaned separate apps. Uninstall the
old app manually, install the new APK, and re-pair with the PC — the auth
token store is per-app-id, so the new install starts unpaired. The stale phone
entry on the server can be revoked in the server's Settings.

## 7. Known limitations

- Starting a slideshow from web Google Slides is unsupported — PowerPoint
  desktop is the presenter target (its shortcut differs).
- Windows "Enhance pointer precision" should be OFF for faithful slow cursor
  movement.
- The setup exe and the bare server exe are unsigned, so SmartScreen warns on
  first run.
