# Remote Control — Tab Bridge

Browser extension that shows your PC browser's open tabs AND its bookmark tree
on the phone's Browser screen. Tap a tab on the phone to switch to it, swipe or
long-press to close it; browse your bookmark folders, open a bookmark on the
PC, and star or unstar the tab you are on. The extension feeds both lists to
the Remote Control server on this PC and executes the tab and bookmark commands
the phone sends back.

**Privacy:** the extension talks ONLY to the Remote Control server running on
the same PC (`ws://127.0.0.1:17779` — localhost). No data ever leaves the
machine. It sends tab titles, favicons, and bookmark titles and ids to your own
server; full URLs — of tabs and of bookmarks alike — never leave the machine.

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

## Permissions

| Permission | Why it is needed |
|------------|------------------|
| `tabs` | Read the open tabs and switch or close them from the phone. This is what produces the "Read your browsing history" wording at load time. |
| `tabGroups` | Show which group a tab belongs to, and its colour. |
| `favicon` | Draw each tab's site icon on the phone. |
| `alarms` | Wake the service worker so it reconnects after the server restarts. |
| `bookmarks` | Show the bookmark tree on the phone, file a starred tab into the bookmarks bar, and remove a bookmark when you unstar. Only bookmark titles and ids are sent to your own server — never a bookmark URL. |

## Updating the extension

The extension is loaded **unpacked**, so an update is a file copy plus one
click:

1. Unzip the new release and copy its `extension` folder contents over the
   folder you originally loaded from. Use the **same path** — an unpacked
   extension's id is derived from its absolute folder path, so loading a second
   copy from a new location registers a second, duplicate Tab Bridge.
2. Press the **reload arrow** on the Tab Bridge card on `chrome://extensions`.

That is the whole procedure even when the update adds a permission. Going from
v1.1.0 (no bookmark access) to v1.2.0 (which adds `bookmarks`) in place, the
extension stays enabled across the reload — no re-approval prompt, no warning
banner, no greyed-out card — and the phone's Browser screen kept showing the
tab list the whole time. No prompt appears because the extension is loaded
unpacked rather than installed from a web store.

(Measured on real hardware on 2026-07-30, not taken from documentation: the
browser was **Comet 150.0.7871.115** — Perplexity's Chromium fork, *not*
Chrome — with the Tab Bridge loaded unpacked. The card went straight from
`1.1.0` to `1.2.0` and the browser's own permission record silently gained
`bookmarks`. This is evidence about the unpacked / reload-arrow path only,
which is how the Tab Bridge is distributed; web-store updates are documented
to handle a permission increase differently, and that path was not measured.)

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

## Bookmark snapshot check (developer)

Confirms the bookmark tree fits the wire budget on this profile. Read-only —
it builds a frame and measures it, and sends nothing. Open the extension's
service worker console and paste:

```javascript
buildBmSnapshot().then(s => console.log('nodes:', s.count, 'bytes:', bytesOf(s.frame)));
```

Expected: `nodes:` at or under **500** (`MAX_BM_NODES`) and `bytes:` under
**57344** (`MAX_FRAME_BYTES` — the 56 KB per-frame cap). Counts and sizes
only: like the shipped `[tab-bridge] bm snapshot sent:` log line, this prints
nothing that identifies any individual bookmark.

A collection bigger than the cap reports exactly 500 and the phone says so on
screen — that is honest truncation, not an error.
