# Distribution Guide

How to build the Remote Control release artifacts and hand them to a friend.

## 1. Building the release artifacts (owner)

### Windows server installer

**One-time prerequisite:** [Inno Setup 6](https://jrsoftware.org/isdl.php)
(6.3 or newer — the script uses `WizardIsTaskSelected`). A per-user install
works; no admin rights needed.

```
winget install --id JRSoftware.InnoSetup -e -s winget
```

**Build**, from the repo root:

```
.\installer\build-installer.ps1
```

That runs `cargo build --release -p server-windows` and compiles
`installer/RemoteControl.iss`, producing
`dist/RemoteControl-Setup-v<version>.exe` (~5 MB). The version comes from
`server/server-windows/Cargo.toml` — the same value embedded in the exe's
VERSIONINFO — so bump it there for a release. Pass `-Version` to override for a
one-off build, or `-SkipBuild` to repackage an existing binary.

The setup exe is what goes on the GitHub Release. It installs per-user into
`%LOCALAPPDATA%\Programs\RemoteControl` (no UAC prompt), creates a Start Menu
entry, and offers a desktop shortcut and a start-with-Windows checkbox. The
browser extension is bundled inside it.

The bare `cargo build --release -p server-windows` still works and still lands
a self-contained `server/target/release/server-windows.exe` — useful for
development, but do not hand that out: it has no shortcuts, no uninstaller, and
its autostart entry points wherever the file happens to sit.

### Android APK

**One-time keystore setup (before the first real release build):**

1. Create a release keystore with `keytool` (ships with the JDK bundled in
   Android Studio). It prompts for passwords interactively, so no secret ever
   touches a file in this repo. Store the `.jks` OUTSIDE the repo:

   ```
   keytool -genkey -v -keystore C:/Users/YOUR_NAME/keys/remotecontrol-release.jks -keyalg RSA -keysize 2048 -validity 10000 -alias upload
   ```

2. Copy `app/remote_control/android/key.properties.template` to
   `key.properties` in the same directory and fill in the four fields
   (store/key passwords, alias, keystore path — forward slashes). The file is
   gitignored; never commit it.

**Build:**

From `app/remote_control`:

```
flutter build apk --release
```

The APK lands at `build/app/outputs/flutter-apk/app-release.apk`.

### Browser extension

The installer ships the extension inside the setup exe (installed to
`%LOCALAPPDATA%\Programs\RemoteControl\extension`, with a Start Menu shortcut
that opens that folder), so a separate download is no longer required — and
this way the extension can never drift out of sync with the server it talks to.

The standalone zip remains useful for anyone running the bare exe:

```
Compress-Archive -Path extension -DestinationPath RemoteControl-Extension-v1.0.0.zip
```

Recipients unzip it and load the `extension` folder unpacked in Chrome or Edge
— the zip's own `README.md` walks them through it.

> **Signing note:** without `key.properties` the same command still builds,
> but the APK is DEBUG-signed. That is fine for personal sideloads, NOT for
> handing out — debug keys are public, and switching to a real keystore later
> changes the app signature, forcing everyone who installed the debug-signed
> APK to uninstall and reinstall.

**Owner migration note (one-time, after the package rename):** the app id
changed from `com.example.remote_control` to `dev.omkar.remotecontrol`, so
existing installs of the old id on your phones become orphaned separate apps.
Uninstall the old app manually, install the new APK, and re-pair with the PC —
the auth token store is per-app-id, so the new install starts unpaired. The
stale phone entry on the server can be revoked in the server's Settings.

## 2. Installing on a friend's machine

### Windows (the PC being controlled)

1. Run `RemoteControl-Setup-vX.Y.Z.exe`.
2. SmartScreen will show "Windows protected your PC" (unknown publisher — the
   setup exe is unsigned, same as the bare exe was). Click **More info**, then
   **Run anyway**.
3. The wizard asks for nothing but two checkboxes — a desktop shortcut and
   start-with-Windows, both on by default. No admin rights, no UAC prompt: it
   installs into the user's own `%LOCALAPPDATA%\Programs\RemoteControl`.
4. On the Windows Firewall prompt at first launch, allow access on **Private**
   networks.
5. The tray icon appears when the server is up. Afterwards it can be started
   from the Start Menu (search "Remote Control") or the desktop shortcut.

**Upgrading:** run the newer setup exe over the top. It keeps the install
location, settings, and paired devices. If the server is running, Setup asks
for it to be closed first — quit it from the tray menu so it can save its
config cleanly.

**Logs:** the server runs windowed with no console, so nothing is printed
anywhere visible. It writes a rolling daily log to
`%APPDATA%\RemoteControl\logs\server.log.<date>` instead — that is the first
place to look when something misbehaves. Set `RUST_LOG=debug` before launching
for more detail. The files are dated in UTC, so late-evening local sessions
land in the next day's file.

**Uninstalling:** Settings → Apps → *Remote Control* → Uninstall. That removes
the exe, both shortcuts, and the autostart entry, then asks whether to delete
`%APPDATA%\RemoteControl` (settings, paired devices, and logs). Answering No keeps a
later reinstall paired.

### Android (the phone doing the controlling)

1. Send the APK to the phone any way you like (Drive / USB / chat).
2. Android blocks unknown sources by default — when prompted, allow
   **Install unknown apps** for the app you are installing from, then install.

### Pairing

1. Phone and PC must be on the **same WiFi network**.
2. On the PC, open the tray menu and start pairing — the pair window shows a
   QR code and a 6-digit PIN, valid for 60 seconds.
3. On the phone, pick the PC from the device list and tap **Scan QR**
   (or type the PIN instead).
4. After the first pair, the phone reconnects automatically.

## 3. Draft release notes — v1.0

> Draft only: the repo currently has no remote; publishing a GitHub Release is
> a later, separate step.

**Remote Control v1.0** — your phone as a wireless trackpad, keyboard, and
control center for a Windows PC over WiFi. Free, no accounts, LAN-only.

- Instant trackpad: measured p50 6 ms / p95 10 ms cursor latency on real WiFi
- Full keyboard, including modifiers, F-keys, and IME-safe text input
- Floating trackpad bubble available over every screen
- Media controls + absolute volume with live PC readback
- App switcher with window icons and pinned favorites
- Clipboard sync with history
- Power controls: lock / sleep / restart / shutdown — destructive actions
  double-confirmed (slide + countdown)
- Presenter mode with slide controls and an on-phone timer
- Browser macros (back/forward, tabs, zoom, bookmark)
- QR or PIN pairing (60-second expiry, lockout on repeated failures)
- LAN-only with SHA-256-hashed tokens; power actions double-gated
- Dark minimal UI

**Platforms:** Windows 10/11 server + Android app, same-WiFi LAN.

**Known limitations:**

- Starting a slideshow from web Google Slides is unsupported — PowerPoint
  desktop is the presenter target (its shortcut differs).
- Windows "Enhance pointer precision" should be OFF for faithful slow cursor
  movement.
