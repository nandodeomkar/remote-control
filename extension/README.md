# Remote Control — Tab Bridge

Browser extension that shows your PC browser's open tabs on the phone's
Browser screen. It talks ONLY to the Remote Control server running on the
same PC (`ws://127.0.0.1:17779`) — no data ever leaves the machine.

> Full install walkthrough coming in the release docs (Task 5).

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
