# Remote Control

Turn your Android phone into a wireless mouse, keyboard, and control center for a Windows PC. Your phone controls the computer over your home WiFi — instant cursor response, a full keyboard, and extras like media controls, an app switcher, clipboard sync, presenter mode, and power controls. All free.

## Install

You need two devices: the **Windows PC** you want to control and the **Android phone** that will control it. Both must be on the **same WiFi network**. The whole setup takes about five minutes.

1. **Accept the invite.** This project is private, so first accept the GitHub invitation that was emailed to you (check the email address tied to your GitHub account). Until you accept, the download page will show a "404 not found" error.

2. **Get the files.** Open the [Releases page](../../releases/latest) and you will see two files (the numbers at the end are the version, so they change with each update):
   - `RemoteControl-Setup-v1.3.2.exe` — for the **PC**
   - `RemoteControl-v1.3.2.apk` — for the **phone**

   Download the `.exe` on the PC. For the `.apk`, open the Releases page in your **phone's browser** and download it directly on the phone — that skips the hassle of transferring the file between devices.

### On your PC

1. Download the `RemoteControl-Setup` file and double-click it.
2. Windows shows a blue **"Windows protected your PC"** warning. This is normal for programs that don't come from the Microsoft Store. Click **More info**, then **Run anyway**.
3. The installer asks you two things: whether to put an icon on your desktop, and whether to start Remote Control automatically when you turn on your PC. Both are ticked already — leave them on unless you'd rather not. Then click **Install**. It never asks for an administrator password.
4. A firewall popup appears the first time it runs — click **Allow access**.
5. Success looks like this: a small icon appears in the tray near the clock (you may need to click the **^** arrow to see it).

From now on you can start it any time from the **Start menu** (type "Remote Control") or the desktop icon. To remove it later, go to **Settings → Apps**, find Remote Control, and choose Uninstall.

### On your phone

1. Open the [Releases page](../../releases/latest) in your phone's browser and download `RemoteControl-v1.3.2.apk`.
2. Tap the downloaded file. Your phone warns about installing apps from outside the Play Store — when asked, allow it for your browser (**"Install unknown apps"** / **"Allow from this source"**).
3. Install, then open **Remote Control**.

### Pair them

1. Make sure the phone and the PC are on the **same WiFi**.
2. On the PC, click the tray icon and open the pair window — it shows a QR code.
3. On the phone, pick your PC from the list and tap **Scan QR**, then point the camera at the code. Done — you're paired.

If the camera scan doesn't work, the pair window also shows a 6-digit PIN you can type into the phone instead. After the first pairing, the phone reconnects by itself.

### Browser tab list (optional)

Want to see and switch your PC browser's open tabs from the phone? The installer already put the extension on your PC — nothing extra to download. Open the **Start menu**, type "Remote Control", and pick **Remote Control browser extension**: that opens the folder you point Chrome or Edge at. The walkthrough is in that folder's README ([view it here](extension/README.md)). It's a small free browser extension that only talks to the Remote Control server on your own PC.

## What you get

- A trackpad with instant cursor response
- A full keyboard, including special keys
- A floating trackpad bubble you can use over any screen
- Media controls and volume, with the PC's real volume shown live
- An app switcher to jump between open windows
- Clipboard sync between phone and PC, with history
- Power controls: lock, sleep, restart, shutdown — the dangerous ones are double-confirmed so you can't trigger them by accident
- Presenter mode with slide controls and an on-phone timer
- Browser shortcuts: back/forward, tabs, zoom
- See and switch your browser's open tabs from the phone (optional free extension)
- Everything is free, no accounts, and it only works on your own WiFi

## Troubleshooting

**The phone can't find the PC.** Confirm BOTH devices are on the same WiFi network — a phone on mobile data won't find it.

**I closed the program on the PC and can't find it again.** Open the **Start menu**, type "Remote Control", and click it — or use the desktop icon if you kept one. Clicking it twice is harmless: the second click just points you back to the tray icon.

**I clicked past the firewall popup (or hit "Cancel").** Quit the tray program on the PC, start Remote Control again from the Start menu, and the popup comes back — click **Allow access** this time.

**The QR code stopped working.** The code expires after 60 seconds for safety. Close the pair window on the PC and open it again for a fresh code.

## For developers

This is a protocol-first monorepo: the wire contract in `protocol/` is the source of truth, and both the Rust server and the Dart/Flutter client are tested against the same golden fixtures.

### Layout

| Directory | Contents |
|-----------|----------|
| `protocol/` | Versioned wire spec (`SPEC.md`), JSON schema, and golden fixtures — the shared cross-language contract |
| `server/` | Rust cargo workspace: `server-core` (OS-agnostic protocol/auth/dispatch core) + the `server-windows` binary |
| `app/` | Flutter client; `app/packages/remote_protocol` is the pure Dart protocol package |
| `extension/` | Unpacked Chrome/Edge extension for the browser tab list |
| `installer/` | Inno Setup script + build script for the Windows setup exe |

### Testing

The local test suites are the CI gate — both must pass before any commit is considered done:

```
cd server && cargo test --workspace
cd app/packages/remote_protocol && dart test
```

The Dart invocation MUST run from the package root (`app/packages/remote_protocol`) — the fixture tests load `protocol/fixtures/` by relative path.

`protocol/fixtures/` is the shared cross-language contract: the Rust and Dart codecs are tested against the same fixture bytes, and no codec may adjust a fixture to match its own output. A dormant GitHub Actions workflow (`.github/workflows/ci.yml`) runs the same two suites and activates automatically if the repo is ever pushed to GitHub.

See [DISTRIBUTION.md](DISTRIBUTION.md) for how to build and distribute the release files.
