# Remote Control — Tab Bridge

Browser extension that shows your PC browser's open tabs on the phone's
Browser screen — tap a tab on the phone to switch to it, swipe or long-press
to close it.

**Privacy:** the extension talks ONLY to the Remote Control server running on
the same PC (`ws://127.0.0.1:17779` — localhost). No data ever leaves the
machine. It sends tab titles and favicons to your own server; full URLs never
leave the machine.

## Install on Chrome

1. Download the release's extension zip (`RemoteControl-Extension-vX.zip`)
   and unzip it somewhere permanent.
2. Visit `chrome://extensions`.
3. Toggle **Developer mode** on (top right).
4. Click **Load unpacked** and select the `extension` folder from the unzip.
5. Done — with the Remote Control server running, the tab list appears on
   the phone's Browser screen within a few seconds.

## Install on Edge

Identical steps via `edge://extensions` — the **Developer mode** toggle is at
the **bottom-left** of that page. Chrome MV3 extensions load in Edge
unmodified.

## Troubleshooting

- **"service worker (inactive)" on the extensions page** — NORMAL when the
  Remote Control server is down. The extension wakes itself within ~30
  seconds of the server coming back; no action needed.
- **Keep the unzipped folder.** Chrome loads the extension from that folder
  on disk — deleting or moving it breaks the extension. Pick a permanent
  spot before loading.
- **Changed the server's `RC_EXT_PORT`?** Edit the `PORT` const at the top of
  `background.js` to match, then press the reload arrow for the extension on
  the extensions page.
- **"Read your browsing history" install warning** — this comes from the
  `tabs` permission, which the extension needs to read tab titles. It is the
  standard Chrome wording for that permission; nothing is sent anywhere
  except your own PC's Remote Control server.

## Smoke test (developer)

Load-unpacked smoke test (no server needed): open `chrome://extensions`,
enable Developer mode, Load unpacked → select `extension/`. Click "service
worker" to open its console. Confirm:

1. No manifest errors.
2. The WS connect attempt logs a connection-refused style network error,
   NOT a SecurityError/permission error (A2 — `ws://127.0.0.1` from a
   service worker needs no `host_permissions`).
3. Paste
   `fetch('chrome-extension://' + chrome.runtime.id + '/_favicon/?pageUrl=' + encodeURIComponent('https://github.com') + '&size=32').then(r => r.blob()).then(b => console.log(b.type, b.size))`
   into the SW console — logs `image/png` with a nonzero size (A3).
4. Paste
   `chrome.tabs.query({}).then(t => console.log(t.length, t[0].title !== undefined))`
   — logs a count and `true` (A4).
5. `chrome.alarms.getAll().then(console.log)` shows `rc-reconnect` with
   `periodInMinutes: 0.5` (A5).

If any check fails, apply the RESEARCH fallback for that assumption
(e.g. A2 fallback: add `host_permissions: ["ws://127.0.0.1/*"]` to
`manifest.json`) and note it here.
