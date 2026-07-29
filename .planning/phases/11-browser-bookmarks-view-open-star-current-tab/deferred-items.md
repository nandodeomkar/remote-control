# Deferred items — phase 11

Out-of-scope discoveries logged during execution. Not fixed here.

| # | Found in | Item | Why deferred |
|---|----------|------|--------------|
| 1 | 11-05 task 3 | `extension/background.js` caps GROUP titles with `(g.title \|\| "").slice(0, MAX_GROUP_TITLE)`. Like the bookmark title cap, this slices on UTF-16 code units and can leave a lone surrogate when an emoji straddles char 32 — `JSON.stringify` then emits a bare `\ud83d`, which serde_json rejects as a hard decode error. 11-05 fixed its OWN new title cap (`capBmTitle`) but left the shipped group cap untouched. | Pre-existing shipped code on the `tabs.state` path, not caused by 11-05's changes (SCOPE BOUNDARY). Lower blast radius than the bookmark case: `groups` is parsed LENIENTLY server-side (11-02 decision) whereas `bm.state` nodes are strict, and a group title is far less likely than a bookmark title to be emoji-decorated at exactly the cap. Fix is one line: route the group title through the same lone-surrogate trim. |
