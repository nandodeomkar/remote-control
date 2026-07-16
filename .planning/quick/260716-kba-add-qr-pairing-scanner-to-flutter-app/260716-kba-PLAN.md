---
quick_id: 260716-kba
type: quick
autonomous: true
files_modified:
  - app/remote_control/pubspec.yaml
  - app/remote_control/android/app/src/main/AndroidManifest.xml
  - app/remote_control/lib/net/pair_qr.dart
  - app/remote_control/lib/screens/qr_scan_screen.dart
  - app/remote_control/lib/screens/pairing_dialog.dart
  - app/remote_control/lib/screens/connection_copy.dart
  - app/remote_control/test/pair_qr_test.dart
  - app/remote_control/test/qr_scan_pairing_test.dart
  - app/remote_control/test/pairing_flow_test.dart
requirements: [CONN-02]
must_haves:
  truths:
    - "The pairing sheet shows a 'Scan QR' secondary affordance; manual PIN entry stays and is unchanged"
    - "Scanning the PC pair window's rc://pair QR feeds host/port/pin into the EXISTING pairing flow — a matching target submits the PIN through the same _submit path as typing, a different target fires a fresh connectTo and auto-feeds the PIN at needPin"
    - "A non-rc:// or field-invalid QR shows explicit malformed copy on the scanner screen and scanning continues"
    - "Camera permission denied renders an explicit copy panel, never a crash or blank preview"
    - "An expired PIN scanned from a stale QR renders the existing 'That PIN expired' line via the untouched authFail path"
  artifacts:
    - path: "app/remote_control/lib/net/pair_qr.dart"
      provides: "PairQrData + parsePairQr strict rc://pair URI validation"
      contains: "parsePairQr"
    - path: "app/remote_control/lib/screens/qr_scan_screen.dart"
      provides: "Full-screen MobileScanner route popping PairQrData, with malformed + denied states"
      contains: "MobileScanner"
    - path: "app/remote_control/android/app/src/main/AndroidManifest.xml"
      provides: "CAMERA permission"
      contains: "android.permission.CAMERA"
    - path: "app/remote_control/pubspec.yaml"
      provides: "mobile_scanner dependency"
      contains: "mobile_scanner"
  key_links:
    - from: "app/remote_control/lib/screens/pairing_dialog.dart"
      to: "lib/screens/qr_scan_screen.dart"
      via: "scanQr seam (showPairingSheet pushes QrScanScreen, tests inject a fake)"
      pattern: "scanQr"
    - from: "app/remote_control/lib/screens/qr_scan_screen.dart"
      to: "lib/net/pair_qr.dart"
      via: "parsePairQr on each detected barcode rawValue"
      pattern: "parsePairQr"
    - from: "app/remote_control/lib/screens/pairing_dialog.dart (scan result)"
      to: "ConnectionService.feedPin / connectTo"
      via: "onSubmitPin (matched target) or onConnectScanned + _pendingPin auto-feed (new target)"
      pattern: "onConnectScanned"
---

<objective>
Add a QR pairing scanner to the Flutter app. The Windows server pair window
(server/server-windows/src/shell/pair_window.rs, commit 876beb4) renders a QR
whose payload is `rc://pair?host=<ip>&port=<port>&pin=<6 digits>` (built at
pair_window.rs line ~77); the PIN expires 60s after issue. The app gets a
"Scan QR" secondary affordance on the existing PIN pairing sheet (manual PIN
entry stays), a dark-minimal full-screen scanner route using mobile_scanner,
a strict rc://pair parser, and wiring that feeds the scan result into the
EXISTING pairing code path — never a parallel pairing implementation.

Routing decision (locked by the task description "same code path as manual
PIN entry"): a scanned payload whose host+port match the sheet's current
target fills the PIN field and calls the sheet's existing _submit() —
byte-identical to typing. A payload naming a DIFFERENT host or port means the
user scanned another PC's pair window: park the pin as _pendingPin (the
sheet's existing post-authFail retry mechanism) and fire a fresh
ConnectionService.connectTo at the scanned target with a manualDeviceKey —
the existing didUpdateWidget needPin-transition hook auto-feeds the pin.
Expired-PIN rejection needs NO new code: the server replies
authFail{pinExpired} and pairingErrorCopy already renders "That PIN expired —
check your PC for a new one" on the sheet's reserved error line.

Purpose: zero-typing pairing — scan the PC's QR instead of transcribing six
digits before the 60s window closes.
Output: mobile_scanner dependency + CAMERA permission, lib/net/pair_qr.dart,
lib/screens/qr_scan_screen.dart, Scan QR affordance in pairing_dialog.dart,
new copy in connection_copy.dart, unit + widget tests.
</objective>

<context>
@.planning/STATE.md
@app/remote_control/lib/screens/pairing_dialog.dart
@app/remote_control/lib/screens/connection_copy.dart
@app/remote_control/lib/screens/device_list_screen.dart
@app/remote_control/lib/net/reconnect_fsm.dart
@app/remote_control/lib/store/device_store.dart
@app/remote_control/lib/theme/tokens.dart
@app/remote_control/test/pairing_flow_test.dart
@server/server-windows/src/shell/pair_window.rs
</context>

<tasks>

<task type="auto" tdd="true">
  <name>Task 1: mobile_scanner dependency, CAMERA permission, strict rc://pair parser + copy</name>
  <files>app/remote_control/pubspec.yaml, app/remote_control/android/app/src/main/AndroidManifest.xml, app/remote_control/lib/net/pair_qr.dart, app/remote_control/lib/screens/connection_copy.dart, app/remote_control/test/pair_qr_test.dart</files>
  <behavior>
    - parsePairQr('rc://pair?host=192.168.1.50&port=17777&pin=123456') returns PairQrData(host: '192.168.1.50', port: 17777, pin: '123456')
    - Whitespace-padded input parses (trim first); extra unknown query params are ignored
    - ALL of the following return null (malformed): wrong scheme ('http://pair?...', plain text, a URL), wrong authority ('rc://other?...'), missing any of host/port/pin, host that is not an IP literal (InternetAddress.tryParse fails, e.g. 'my-pc'), port not in 1..65535 (0, 70000, non-numeric), pin not exactly 6 digits (5 digits, 7 digits, letters, '12 456')
    - PairQrData is value-equal (== and hashCode over host/port/pin) and does NOT override toString with the pin embedded (T-03-23 secrets discipline — the pin must never leak via logs/interpolation)
  </behavior>
  <action>
Add `mobile_scanner: ^7.2.1` to app/remote_control/pubspec.yaml dependencies
with a one-line comment: QR pairing scanner — the maintained package (the old
qr_code_scanner is deprecated); user-locked in the task description. Before
adding, verify legitimacy on pub.dev (https://pub.dev/packages/mobile_scanner
— verified publisher steenbakker.dev, the same author as the project's
existing flutter_secure_storage). Run `flutter pub get` in
app/remote_control. If pub or a later build complains about Android
minSdk/compileSdk for mobile_scanner 7.x, raise minSdk/compileSdk in
app/remote_control/android/app/build.gradle(.kts) to the minimum the error
names — nothing speculative.

Add `<uses-permission android:name="android.permission.CAMERA"/>` to
app/remote_control/android/app/src/main/AndroidManifest.xml beside the
existing INTERNET/CHANGE_WIFI_MULTICAST_STATE permissions, extending the
existing comment block: camera backs the QR pairing scanner; mobile_scanner
requests the runtime grant itself when the scanner starts.

Create app/remote_control/lib/net/pair_qr.dart (dart:io import for
InternetAddress): an immutable value class PairQrData{String host, int port,
String pin} with const ctor, == and hashCode (hand-rolled, house style — no
package:collection), NO toString override; and a top-level
`PairQrData? parsePairQr(String raw)` implementing the behavior table above
via Uri.tryParse on the trimmed input, checking uri.scheme == 'rc' and
uri.host == 'pair' (that is how `rc://pair?...` parses — 'pair' lands in the
authority), then queryParameters host/port/pin: host must satisfy
InternetAddress.tryParse != null (consistent with the manual-IP sheet's
validation in device_list_screen.dart), port int.tryParse in 1..65535, pin
must match RegExp(r'^\d{6}$'). Any failure returns null — the caller treats
null as malformed. Doc comment must cite the server payload source
(pair_window.rs `rc://pair?host={}&port={}&pin={}`) so the contract is
traceable.

Add copy constants to lib/screens/connection_copy.dart under a new
"QR pairing scanner" section, following the locked tone contract (plain,
names problem AND next step, no exclamation marks, no raw values):
kScanQrLabel = 'Scan QR'; kScanQrTitle = 'Scan the QR on your PC';
kScanQrHint = 'Point the camera at the QR code in the pairing window';
kQrMalformedCopy = "That's not a Remote Control pairing code — scan the QR in
the pairing window on your PC"; kCameraDeniedCopy = 'Camera access is off —
allow Camera for Remote Control in Android settings, then try again';
kCameraErrorCopy = "Couldn't start the camera — close other camera apps and
try again". Screens must reference these constants; no inline copy literals
in widget files (file-level contract already documented in
connection_copy.dart's header).

Write test/pair_qr_test.dart FIRST (RED) covering every behavior case above
as a table of (input, expected) pairs plus the value-equality and
no-pin-in-toString assertions, then implement pair_qr.dart until green.
  </action>
  <verify>
    <automated>cd app/remote_control && flutter test test/pair_qr_test.dart</automated>
  </verify>
  <done>
mobile_scanner resolves in pubspec.lock; AndroidManifest.xml carries the
CAMERA uses-permission; parsePairQr passes the full malformed/valid table;
PairQrData is value-equal and never embeds the pin in toString; the six new
copy constants exist in connection_copy.dart.
  </done>
</task>

<task type="auto">
  <name>Task 2: QrScanScreen route + Scan QR affordance on the pairing sheet</name>
  <files>app/remote_control/lib/screens/qr_scan_screen.dart, app/remote_control/lib/screens/pairing_dialog.dart</files>
  <action>
Create lib/screens/qr_scan_screen.dart: a StatefulWidget QrScanScreen pushed
as a full-screen MaterialPageRoute&lt;PairQrData&gt; that pops with a
PairQrData on success (or null when the user backs out). Dark-minimal per
tokens.dart: Scaffold/AppBar kBg, title Text(kScanQrTitle) in the 16/w600
kText style used by the sibling sheets, body = MobileScanner filling the
space above a bottom hint area: kScanQrHint in the 14/w400 kMuted style plus
a RESERVED fixed-height error line (kError 14/w400, SizedBox height 24,
SizedBox.shrink when clear — the house no-jump pattern from
pairing_dialog.dart). Own a MobileScannerController constructed with
formats: [BarcodeFormat.qrCode] and dispose it in dispose(). Check the
resolved mobile_scanner 7.x API on the installed package (onDetect takes a
BarcodeCapture; errorBuilder builds the error state) rather than trusting
older 5.x snippets.

onDetect handling: guard with a bool _done so the route pops exactly once
(onDetect fires repeatedly per frame). Take the first barcode with a
non-null rawValue, run parsePairQr: valid -> set _done, Navigator.pop with
the data; invalid -> setState the malformed error line to kQrMalformedCopy
with a ~2s cooldown timestamp (DateTime-based, no Timer needed) so one bad
frame doesn't re-trigger setState continuously — scanning continues, the
line clears on the next valid pop or stays until a fresh malformed read
refreshes it. NEVER log or interpolate the raw QR contents or the pin
(T-03-23).

errorBuilder: extract a public, camera-free QrScanErrorPanel widget (so the
widget test can pump it directly without the MobileScanner platform view)
that takes the MobileScannerException's errorCode and renders a centered
column — Symbols.no_photography_rounded (size 48, kMuted; classic Icons.* is
banned in lib/ by icons_guard_test) over kCameraDeniedCopy when the code is
MobileScannerErrorCode.permissionDenied, else Symbols.videocam_off_rounded
over kCameraErrorCopy; copy in the 14/w400 kMuted body style, maxLines 2,
centered. mobile_scanner requests the runtime permission itself on start; a
denial surfaces through this errorBuilder — that IS the explicit
denied-state UI. No settings-deeplink package is added.

Wire the pairing sheet (lib/screens/pairing_dialog.dart). PairingSheet gains
four required constructor parameters: `String targetHost`, `int targetPort`,
`void Function(String host, int port) onConnectScanned`, and
`Future&lt;PairQrData?&gt; Function() scanQr` (the injected seam — house
pattern, tests pass a fake, production pushes the real route). Add a private
`Future&lt;void&gt; _scan()` to _PairingSheetState: await widget.scanQr();
bail on !mounted or null; if result.host == widget.targetHost &amp;&amp;
result.port == widget.targetPort then set _pinCtrl.text = result.pin and
call the EXISTING _submit() — literally the manual-entry code path,
including the failure-retry branch and the _canSubmit lockout no-op (during
lockout the field fills, the countdown line explains, and the user taps Pair
when it ends — identical to typing during lockout); else (different PC or
port — the QR is authoritative for where that PIN lives) set _pendingPin =
result.pin and call widget.onConnectScanned(result.host, result.port) — the
existing didUpdateWidget needPin-transition hook then auto-feeds the pin,
zero new feed plumbing. Render the affordance as a TextButton.icon directly
below the Pair FilledButton (8px gap): icon Symbols.qr_code_scanner_rounded
size 20, label Text(kScanQrLabel) in the sheet's 14/w400 body style, house
secondary style (TextButton.styleFrom minimumSize Size(48, 48),
foregroundColor kText — accent stays reserved for the primary CTA, D-03
convention), onPressed: _scan.

In showPairingSheet, wire the real values: targetHost: target.host,
targetPort: target.port, scanQr: () =&gt;
Navigator.of(sheetContext).push&lt;PairQrData&gt;(MaterialPageRoute(builder:
(_) =&gt; const QrScanScreen())), and onConnectScanned: (host, port) =&gt;
unawaited(service.connectTo(DeviceTarget(key: manualDeviceKey(host, port),
name: host, host: host, port: port))) — the same manual-key connect shape as
_ConnectByIpSheet._submit in device_list_screen.dart (import
../store/device_store.dart for manualDeviceKey and ../net/pair_qr.dart for
the type). The scanned host still crosses the EXISTING RFC1918 dial guard
inside connectTo — a hostile QR naming a public host is refused there
(T-03-16), no new guard needed. Update the existing _sheet() helper in
test/pairing_flow_test.dart with neutral defaults (targetHost
'192.168.1.50', targetPort 17777, onConnectScanned no-op, scanQr async =&gt;
null) so the current suite compiles unchanged; behavior assertions land in
Task 3.
  </action>
  <verify>
    <automated>cd app/remote_control && flutter analyze && flutter test test/pairing_flow_test.dart</automated>
  </verify>
  <done>
QrScanScreen exists (dark-minimal, QR-only formats, pop-once, reserved
malformed line, QrScanErrorPanel extracted); PairingSheet renders the Scan QR
TextButton below the Pair CTA and routes scan results per the
matched/mismatched rule; showPairingSheet wires the real route + manual-key
connectTo; analyzer clean; existing pairing_flow_test suite green with the
updated helper.
  </done>
</task>

<task type="auto" tdd="true">
  <name>Task 3: Widget tests for scan-result routing + full-suite/guard verification</name>
  <files>app/remote_control/test/qr_scan_pairing_test.dart</files>
  <behavior>
    - The sheet renders the Scan QR affordance: a TextButton with kScanQrLabel and Symbols.qr_code_scanner_rounded, alongside the still-present PIN TextField and Pair FilledButton (manual entry stays)
    - Matched scan (fake scanQr returns PairQrData at the sheet's targetHost/targetPort, status needPin, no failure): tapping Scan QR results in onSubmitPin('123456') and the PIN field containing 123456
    - Mismatched scan (data names a different host): onConnectScanned('10.0.0.9', 17777) fires, onSubmitPin does NOT; then rebuilding the sheet with status transitioning to needPin auto-feeds onSubmitPin('123456') via the existing _pendingPin hook
    - Cancelled scan (fake returns null): no callback fires, field unchanged
    - Matched scan while lockedOut (failure reason 'lockedOut', retryAfterSecs 30): field fills with the pin but onSubmitPin/onRetryConnect do NOT fire (the _canSubmit gate holds)
    - Expired-PIN round trip: after a matched scan feeds the pin, rebuilding the sheet with failure FailedEffect(reason 'pinExpired') renders exactly 'That PIN expired — check your PC for a new one' and no raw 'pinExpired' string appears in any rendered Text
    - QrScanErrorPanel(MobileScannerErrorCode.permissionDenied) renders kCameraDeniedCopy; any other code renders kCameraErrorCopy — pumped directly, no camera platform channel
  </behavior>
  <action>
Write test/qr_scan_pairing_test.dart following the house harness in
pairing_flow_test.dart (constructor-injected PairingSheet inside
MaterialApp/Scaffold, no Riverpod, no sockets, a _renderedTexts helper for
the negative raw-enum assertion). The fake scanQr is a closure returning a
canned Future so no navigation or camera is involved; the mismatched-scan
transition test drives didUpdateWidget by pumping the same PairingSheet with
status moving from connecting (or null) to HandshakeStatus.needPin, exactly
how the existing retry-path test exercises _pendingPin. Do NOT pump
MobileScanner or QrScanScreen in tests — the platform view has no test
binding; QrScanErrorPanel is the camera-free surface under test (import
mobile_scanner only for the MobileScannerErrorCode enum, which is a plain
Dart enum). After the new file is green, run the FULL suite — the two guard
tests (icons_guard_test: no classic Icons.* in the new lib files;
theme_tokens_guard_test: no banned palette hex literals — use tokens.dart
consts only) plus all 423+ existing tests must stay green — and a release
build sanity check (the 08-06 lesson: gradle/manifest breakage only
surfaces at build time).
  </action>
  <verify>
    <automated>cd app/remote_control && flutter analyze && flutter test && flutter build apk --release</automated>
  </verify>
  <done>
qr_scan_pairing_test.dart passes all seven behavior cases; flutter analyze is
clean; the full test suite (existing + guards + new) is green; the release
APK builds with the CAMERA permission and mobile_scanner linked.
  </done>
</task>

</tasks>

<threat_model>
## Trust Boundaries

| Boundary | Description |
|----------|-------------|
| camera -> app | Arbitrary QR content (any code in view) crosses into the parser |
| app -> LAN | Scanned host/port select where the app dials |

## STRIDE Threat Register

| Threat ID | Category | Component | Disposition | Mitigation Plan |
|-----------|----------|-----------|-------------|-----------------|
| T-QR-01 | Tampering/Spoofing | parsePairQr + connectTo | mitigate | Strict whitelist parse (rc scheme, IP-literal host, 1..65535 port, exactly 6-digit pin); scanned targets dial through the EXISTING RFC1918 guard in ConnectionService (T-03-16) — a QR naming a public host is refused before any socket opens |
| T-QR-02 | Information disclosure | PairQrData / scanner | mitigate | Pin never logged or interpolated; PairQrData has no pin-embedding toString (extends T-03-23); PIN is 60s-expiring server-side |
| T-QR-03 | Elevation via pairing | server auth path | accept | Scanning only feeds the same PIN handshake the user could type; server-side attempt/lockout/expiry enforcement (Phase-1 code) is untouched |
| T-QR-SC | Tampering | pub install mobile_scanner | mitigate | User-locked package, verified on pub.dev (verified publisher steenbakker.dev — same author as the in-tree flutter_secure_storage) before install in Task 1 |
</threat_model>

<verification>
- `cd app/remote_control && flutter analyze` — clean.
- `cd app/remote_control && flutter test` — full suite green: pair_qr_test
  table, qr_scan_pairing_test routing cases, updated pairing_flow_test, and
  both guards (icons_guard_test, theme_tokens_guard_test) over the new files.
- `cd app/remote_control && flutter build apk --release` — builds with
  CAMERA permission and mobile_scanner.
- grep checks: `android.permission.CAMERA` present in AndroidManifest.xml;
  no `Icons.` classic refs and no banned hex literals in the two new lib
  files; no `print(`/log of pin or raw QR content in pair_qr.dart /
  qr_scan_screen.dart / pairing_dialog.dart.
- On-device confirmation (manual, post-merge dogfood — not a gate here):
  scan the PC pair window's QR end-to-end, then let the PIN expire and
  re-scan to see the 'That PIN expired' line.
</verification>

<success_criteria>
- Scan QR sits on the pairing sheet beside intact manual PIN entry; scanning
  a live QR pairs through the existing flow with zero typing.
- Malformed QR, camera-denied, and expired-PIN paths each render their
  explicit locked copy — no crashes, no raw values.
- Dark-minimal + Symbols-only contracts hold (guard tests prove it); full
  suite and release build green.
</success_criteria>

<output>
Update `.planning/STATE.md` Quick Tasks Completed table when this quick task
lands (handled by the quick workflow). No SUMMARY file required.
</output>
