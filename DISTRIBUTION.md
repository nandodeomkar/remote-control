# Distribution Guide

How to build the Remote Control release artifacts and hand them to a friend.

## 1. Building the release artifacts (owner)

### Windows server

From `server/`:

```
cargo build --release -p server-windows
```

The binary lands at `server/target/release/server-windows.exe`. It is a single
self-contained executable — no runtime installs needed on the target machine.

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

From the repo root, zip the `extension/` folder (PowerShell):

```
Compress-Archive -Path extension -DestinationPath RemoteControl-Extension-v1.0.0.zip
```

Attach `RemoteControl-Extension-v1.0.0.zip` to the GitHub release beside the
exe and the apk. Recipients unzip it and load the `extension` folder unpacked
in Chrome or Edge — the zip's own `README.md` walks them through it.

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

1. Copy `server-windows.exe` anywhere on the PC and run it.
2. SmartScreen will show "Windows protected your PC" (unknown publisher — the
   exe is unsigned). Click **More info**, then **Run anyway**.
3. On the Windows Firewall prompt, allow access on **Private** networks.
4. The tray icon appears when the server is up.

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
