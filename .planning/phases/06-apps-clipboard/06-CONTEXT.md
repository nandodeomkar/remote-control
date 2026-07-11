# Phase 6: Apps & Clipboard - Context

**Gathered:** 2026-07-11
**Status:** Ready for planning

<domain>
## Phase Boundary

The phone manages PC windows/apps and moves text between devices — the two push-driven, platform-fiddly control-center features. In scope: real Windows executors replacing the Phase-1 `StubApps`/`StubClipboard` seeds, plus the Flutter Apps screen and Clipboard screen wired to the already-locked wire protocol.

**In scope (roadmap SC1–SC5 / APPS-01..03, CLIP-01..04):**
- Apps: list real user windows (Alt-Tab-quality filtering), focus, close (toast if window gone), launch pinned favorites, live refresh via `apps.changed` push
- Clipboard: send phone→PC, fetch PC→phone (one tap each), opt-in auto-sync with echo suppression (content-hash), last-5 history, honest Android 10+ limitation surfacing

**Out of scope (own phases):** tray settings window / device-name / port / paired-device revoke (Phase 7, SRV-03); persistent token storage / re-pairing (Phase 7). Clipboard sync *settings UI* lives in the Phase-7 settings window; Phase 6 owns the in-app toggle + behavior.

</domain>

<decisions>
## Implementation Decisions

### Pinned favorites (APPS-02)
- **D-01:** Pin from running windows — long-press a running window row in the Apps list to pin it; relaunch uses that window's resolved executable path. No separate app-picker or manual path entry. Favorites emerge from what the user actually uses.
- **D-02:** Favorites stored client-side (PrefsKv seam, same pattern as device store / keyboard rowGroup). Server stays stateless for favorites; `apps.launch` just receives the resolved path string.
- **Research flag:** resolving a window handle → launchable exe path (GetWindowThreadProcessId → QueryFullProcessImageName) is straightforward for classic Win32 apps but UWP/packaged apps relaunch differently — researcher to determine fallback (and whether packaged-app windows are pinnable at all in v1).

### Clipboard auto-sync (CLIP-03)
- **D-03:** Auto-sync defaults **OFF** — opt-in toggle in the Clipboard screen.
- **D-04:** When enabled, skip syncing very large text (size cap — researcher to pick a sane byte limit) and best-effort skip sensitive/password-manager clips (Windows sets a clipboard exclusion/`ExcludeClipboardContentFromMonitorProcessing`-style marker — researcher to confirm the detection mechanism).
- **D-05:** Echo suppression via content hash (roadmap-locked) — a copy that originated from the other device must not bounce back. Reuse the Phase-5 push-seam discipline (auth-gated S→C push; value-equal snapshot on the client).

### Clipboard history (CLIP-04)
- **D-06:** Last-5 history **persists** across app restart (PrefsKv), consecutive duplicate copies collapse (dedupe), and tapping a history entry sets it as the **PC** clipboard (reuse pushes to the PC, the primary value).

### Apps window list (APPS-01)
- **D-07:** List mirrors Windows **Z-order (Alt-Tab order)**, most-recent first, and shows each window's **app icon**.
- **Research flag:** icon extraction over the wire adds Win32 work + payload size — researcher to decide encoding (e.g. small PNG/base64 in `apps.changed`/`apps.list`, cache by process) and whether `WindowInfo` needs an icon field added to the (otherwise Phase-1-locked) payload.

### Android 10+ honesty (CLIP-03)
- **D-08:** phone→PC clipboard syncs on app resume (Android 10+ blocks background clipboard reads); surface this honestly with a short persistent explanatory note on the Clipboard screen rather than pretending live phone→PC works. PC→phone stays live via `clip.changed` push.

### Claude's Discretion
- Hub tile placement/order for the new Apps + Clipboard tiles (hub is a data-driven `kHubTiles` registry — insert cleanly, no grid rework).
- Server poll cadence/debounce for `apps.changed` and `clip.changed` (responsiveness vs CPU) — follow the Phase-5 250ms audio-poll precedent unless research says otherwise.
- Exact byte cap for large-clip skip; sensitive-clip detection mechanism.

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Wire protocol (already locked — Phase 1)
- `server/server-core/src/codec/json.rs` — all `apps.*` / `clip.*` message types already defined: `AppsListPayload`, `AppsLaunchPayload`, `AppsFocusPayload`, `AppsClosePayload`, `AppsChangedPayload`, `ClipSetPayload`, `ClipGetPayload`, `ClipChangedPayload`. A new icon field on `WindowInfo` (D-07) is the one likely protocol touch — treat as a minor amendment with fixtures, mirroring the Phase-5 `vol.changed` 1.1 amendment.
- `server/server-core/src/dispatch/router.rs` — existing `AppsList/Launch/Focus/Close` and `ClipSet/Get` router arms; `AppsChanged`/`ClipChanged` are in the S→C-only ignore arm (clients cannot spoof them upstream); read-only queries (`apps.list`, `clip.get`) exempt from the pause gate.
- `server/server-core/src/executors/mod.rs` — `Apps` trait (`list`/`launch`/`focus`/`close` → `Vec<WindowInfo>`) and `Clipboard` trait (`get`/`set`) to implement.

### Seeds to replace
- `server/server-windows/src/executors/stubs.rs` — `StubApps` (EnumWindows/ShellExecuteW) and `StubClipboard` (arboard) no-op seeds; comments already name the intended real backends.
- `server/server-windows/src/main.rs` — where the real executors get wired into `Executors` (see Phase-5 `WinMedia`/`WinPower` wiring precedent).

### Design spec
- `docs/superpowers/specs/2026-07-07-remote-control-design.md` — apps/clipboard screens, error handling, Android 10+ clipboard scoping, `apps.changed`/`clip.changed` push semantics.

### Requirements / roadmap
- `.planning/REQUIREMENTS.md` — APPS-01/02/03, CLIP-01/02/03/04 rows + traceability.
- `.planning/ROADMAP.md` §"Phase 6: Apps & Clipboard" — goal + 5 success criteria.

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- Server push seam (Phase 5): `session.rs` `select!` branch pattern gated on `AuthState::Authed` + a `watch`/latest-value channel — `apps.changed` and `clip.changed` reuse this exact discipline (no pre-auth leak, no flood).
- Client push→state pattern (Phase 5): `VolChangedMsg` → value-equal `VolumeSnapshot` parked on `ConnectionService` → `changes` ping → Notifier → screen renders from pushed snapshot. Apps list + clipboard mirror this (`AppsSnapshot`, `ClipSnapshot`).
- PrefsKv seam (Phase 3 device store / Phase 4 keyboard rowGroup): client-side persistence for pinned favorites (D-02) and last-5 history (D-06).
- `hub_screen.dart` `kHubTiles` data-driven registry (Phase 5, now 5 tiles) — Apps + Clipboard tiles insert as two more `HubTileSpec` entries.
- MockExecutors (`server-core`) already record apps/clip calls for integration tests.

### Established Patterns
- Auth + pause gates apply to every C→S command; `apps.launch/focus/close` and `clip.set` are gated, read-only queries exempt (router already enforces).
- Dedicated OS thread for blocking/COM work (Phase-5 audio thread precedent) — apps/clipboard polling that touches Win32/COM should not run on a tokio worker.
- Windows executor methods that can block `thread::spawn` (Phase-5 power precedent).

### Integration Points
- `Executors` struct in `main.rs` — swap `StubApps`/`StubClipboard` for `WinApps`/`WinClipboard`.
- Server watch seam feeding `apps.changed`/`clip.changed` into the authed session write path.
- New Flutter screens routed from the hub; auth-gating of send controls per Phase-5 presenter/power screen precedent.

</code_context>

<specifics>
## Specific Ideas

- "Pin from running windows" is the explicit favorites model — no manual paths, no installed-app scan (D-01).
- Clipboard reuse (tap history) pushes to the **PC** clipboard, not the phone (D-06).
- Alt-Tab ordering + icons are the target look for the window list (D-07).
- Be honest about the Android 10+ background-clipboard limit — visible note, sync-on-resume (D-08).

</specifics>

<deferred>
## Deferred Ideas

- Clipboard sync configuration in a proper settings window → Phase 7 (SRV-03). Phase 6 ships only the in-app toggle + behavior.

### Reviewed Todos (not folded)
- **"Server supports only one pairing per process run — re-pair needs a restart until Phase-7 persistence"** (`.planning/todos/pending/2026-07-09-server-one-pairing-per-run.md`) — deferred: closes with Phase-7 persistent token storage, not an apps/clipboard concern.
- **"Split the overloaded `noPairing` authFail reason so pairing-window-absent gets its own copy"** (`.planning/todos/pending/2026-07-09-nopairing-reason-overloaded-copy.md`) — deferred: server-protocol + pairing copy, belongs with Phase-7 pairing work.

</deferred>

---

*Phase: 6-Apps & Clipboard*
*Context gathered: 2026-07-11*
