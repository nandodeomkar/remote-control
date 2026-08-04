//! The five OS-abstraction executor traits + protocol-level input types.
//!
//! Traits are SYNC (`&self` methods, `Send + Sync`): input injection
//! (enigo's SendInput in Phase 2) is synchronous and cheap, sync traits keep
//! mocks trivial, and dispatch stays inline in the read task (hot-path
//! rule). NO OS types anywhere — window ids are plain `u64`, keys are
//! protocol strings. OS implementations live in a sibling crate (Phase 2+).

pub mod mock;

use std::sync::Arc;

use serde::{Deserialize, Serialize};

/// Protocol mouse button (`click.button` / `drag.button` wire values).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Button {
    Left,
    Middle,
    Right,
}

/// Protocol key code — the wire `key.code` string, opaque to the core.
/// The OS executor maps it to a real key; the dispatcher only needs
/// equality/hashing for held-input tracking.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct KeyCode(pub String);

/// Protocol keyboard modifier (`key.mods` wire values).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Modifier {
    Ctrl,
    Alt,
    Shift,
    Win,
}

/// One entry of the `apps.list` / `apps.changed` window table. `id` is an
/// opaque protocol-level identifier (NEVER an HWND-shaped OS type).
///
/// `icon`/`path` are the protocol-1.2 additive amendment (D-07 / APPS-02):
/// both are `Option` with `skip_serializing_if` so a legacy 1.0/1.1 window
/// (neither field) still decodes and re-encodes without emitting the keys.
/// `icon` is a base64 PNG (32×32); `path` is the resolved exe path (`None`
/// for non-pinnable/UWP windows). `Option<String>` keeps the `Eq` derive.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct WindowInfo {
    pub id: u64,
    pub title: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub icon: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub path: Option<String>,
}

/// One entry of the `tabs.list` / `tabs.changed` tab table (protoVersion
/// 1.4, BROW-01). `id` is the browser-assigned tab id — `i64` (not `u64`)
/// because chrome.tabs.TAB_ID_NONE is `-1` (defensive; a real tab id is
/// always non-negative).
///
/// `icon` is a base64 PNG WITHOUT a `data:` prefix — the exact
/// [`WindowInfo::icon`] convention: `Option` with `skip_serializing_if` so
/// an iconless tab decodes and re-encodes without emitting the key.
/// NO url field exists anywhere on the phone-facing wire (SPEC §7 privacy
/// rule: titles are enough).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TabInfo {
    pub id: i64,
    pub title: String,
    pub active: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub icon: Option<String>,
    /// Owning tab-group id (protoVersion 1.5, quick 260716-sme). Absent =
    /// ungrouped — the WindowInfo `icon`/`path` skip-when-absent convention:
    /// never emitted as null, and never emitted as `-1` (the extension omits
    /// the key for TAB_GROUP_ID_NONE).
    #[serde(rename = "groupId", default, skip_serializing_if = "Option::is_none")]
    pub group_id: Option<i64>,
    /// Whether this tab's URL is bookmarked anywhere in the tree
    /// (protoVersion 1.6, phase 11, D-11). **TRI-STATE — `None` means
    /// UNKNOWN, NOT `false`**: the extension could not read the bookmark
    /// tree (`getTree()` failed, or the `bookmarks` permission is missing).
    /// This is the one place the skip-when-absent shape shared with
    /// `icon`/`group_id`/`WindowInfo::path` carries a DIFFERENT meaning —
    /// those read "there is none", this one reads "we do not know". The
    /// extension therefore emits an explicit `Some(true)`/`Some(false)` on
    /// EVERY tab when the URL set was built and `None` on EVERY tab when it
    /// was not, and the phone renders no star at all for `None` (rendering
    /// an empty star for an unreadable tree is the misreport D-11 forbids).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bookmarked: Option<bool>,
}

/// One entry of the optional `groups` array on the `tabs.list` reply /
/// `tabs.changed` push / ext-leg `tabs.state` (protoVersion 1.5, BROW-01,
/// quick 260716-sme). All four fields are wire-required (a missing field is
/// a hard decode error, exactly like TabEl's id/title/active).
///
/// `color` is Chrome's NAMED group-color string (SPEC §7 GroupEl:
/// `grey|blue|red|yellow|green|pink|purple|cyan|orange`) passed through
/// verbatim — the server never validates the vocabulary (the codec stays
/// value-lenient, the Phase-01 enum-string rule); unknown names render as a
/// neutral fallback client-side.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct GroupInfo {
    pub id: i64,
    pub title: String,
    pub color: String,
    pub collapsed: bool,
}

/// The full tab-relay state carried by the `tabs.list` reply and the
/// `tabs.changed` push (protoVersion 1.4, BROW-01). Core-owned plain data —
/// ZERO OS deps, so server-core keeps compiling on CI Linux. Lives HERE
/// (next to the [`Tabs`] trait that returns it) per the WindowInfo
/// precedent: trait-returned types live with the traits.
///
/// `Default` is the never-connected shape
/// `{connected: false, tabs: [], groups: []}` — exactly what the phone's
/// install-hint state keys on.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct TabsState {
    /// Whether a browser extension is currently connected to the ext
    /// listener (SPEC §15).
    pub connected: bool,
    /// The current full tab snapshot (extension order, max 50).
    pub tabs: Vec<TabInfo>,
    /// The current tab groups (protoVersion 1.5, max 16 — server belt).
    pub groups: Vec<GroupInfo>,
}

/// One entry of the `bm.list` reply / `bm.changed` push node array — the
/// wire BmEl element (protoVersion 1.6, phase 11). The tree is shipped as
/// ONE FLAT breadth-first list, not a recursive structure (D-06), so the
/// codec never recurses.
///
/// `id`, `parent_id` and `title` are ALL wire-required — a missing field is
/// a HARD decode error, following [`GroupInfo`] rather than [`TabInfo`]'s
/// optional tail. The optional fields use the `WindowInfo::icon`
/// skip-when-absent convention: never emitted as null.
///
/// `id`/`parent_id` are Chrome bookmark ids and are **STRINGS**, deliberately
/// unlike [`TabInfo::id`]'s integer. That is exactly why the commands name
/// their fields `nodeId` (bookmark node, string) and `tabId` (tab, integer)
/// instead of both reusing `id`: the codec is value-lenient, so a swapped id
/// would decode fine and fail silently at the extension.
///
/// Root `"0"` is **NEVER shipped as a node**; its children carry
/// `parent_id: "0"` and the phone treats `"0"` as the virtual top level
/// (D-08). `folder: Some(true)` marks a folder (absent = a link) and `count`
/// is that folder's direct-child count, which gates the D-14 delete
/// affordance (`count == 0` ⇒ delete may be offered). `locked: Some(true)`
/// mirrors Chrome's `BookmarkTreeNode.unmodifiable` (managed/admin
/// bookmarks) so the phone hides a delete Chrome would reject.
/// `truncated: Some(true)` marks a folder whose children were dropped by the
/// extension's size-budget loop (SPEC §15).
///
/// There is deliberately **NO url field and NO icon field**: the no-url rule
/// is the same locked invariant [`TabInfo`] carries (URL resolution stays
/// extension-side — the phone sends `bm.open {nodeId}` and the extension
/// resolves it), and D-07 drops the icon so the whole tree fits one frame.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct BmNode {
    pub id: String,
    #[serde(rename = "parentId")]
    pub parent_id: String,
    pub title: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub folder: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub count: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub locked: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub truncated: Option<bool>,
}

/// The full bookmark-relay state carried by the `bm.list` reply and the
/// `bm.changed` push (protoVersion 1.6, phase 11) — the [`TabsState`] clone
/// for bookmarks. Core-owned plain data, ZERO OS deps.
///
/// `Default` is the never-connected shape
/// `{connected: false, nodes: [], truncated: false}` — exactly what the
/// phone's install-hint state keys on, and exactly what the watch resets to
/// when the extension session ends for ANY reason.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct BookmarksState {
    /// Whether a browser extension is currently connected to the ext
    /// listener (SPEC §15).
    pub connected: bool,
    /// The current full bookmark snapshot, flat breadth-first (max 500 —
    /// server belt).
    pub nodes: Vec<BmNode>,
    /// Whether the extension dropped nodes to fit its frame budget.
    pub truncated: bool,
}

/// Mouse + keyboard injection.
///
/// Explicit `*_down`/`*_up` pairs exist (not just tap/click) because the
/// dispatcher's held-input map updates on `down` and clears on `up`
/// (CONN-07).
pub trait MouseKeys: Send + Sync {
    fn move_rel(&self, dx: f32, dy: f32);
    fn scroll(&self, dx: f32, dy: f32);
    /// Zoom by `dy` wheel units with Ctrl held (pinch-to-zoom, SPEC §9
    /// opcode `0x03`). `dx` is reserved — implementations ignore it.
    ///
    /// Implementations MUST press and release Ctrl around the tick rather
    /// than holding it across the gesture, so a session that dies mid-pinch
    /// can never leave the modifier stuck down.
    fn zoom(&self, dx: f32, dy: f32);
    fn click(&self, button: Button);
    fn button_down(&self, button: Button);
    fn button_up(&self, button: Button);
    fn key_down(&self, code: KeyCode);
    fn key_up(&self, code: KeyCode);
    fn key_tap(&self, code: KeyCode, mods: &[Modifier]);
    fn type_text(&self, text: &str);
    fn backspace(&self, n: u32);
}

/// Media keys + absolute volume.
pub trait Media: Send + Sync {
    fn play_pause(&self);
    fn next(&self);
    fn prev(&self);
    fn vol_up(&self);
    fn vol_down(&self);
    fn mute(&self);
    fn set_volume(&self, pct: u8);
}

/// Power actions (always behind the `power` → `confirm` double-confirm gate,
/// SPEC §7).
pub trait Power: Send + Sync {
    fn lock(&self);
    fn sleep(&self);
    fn restart(&self);
    fn shutdown(&self);
}

/// Window enumeration and app control.
///
/// `launch`/`focus`/`close` return `bool` (APPS-01): `false` signals the
/// action could not be performed (window gone, launch failed) so the router
/// can surface `err{windowGone|launchFailed}` to the client instead of
/// silently succeeding. `list` stays a plain read.
pub trait Apps: Send + Sync {
    fn list(&self) -> Vec<WindowInfo>;
    fn launch(&self, path: &str) -> bool;
    fn focus(&self, id: u64) -> bool;
    fn close(&self, id: u64) -> bool;
}

/// Clipboard text get/set.
pub trait Clipboard: Send + Sync {
    fn get(&self) -> String;
    fn set(&self, text: &str);
}

/// Browser tab relay (protoVersion 1.4, BROW-01).
///
/// `activate`/`close` return NOTHING — deliberately unlike [`Apps`]' bool
/// returns: the SPEC §7 tabs family is fire-and-forget (no err reply; a
/// stale id self-heals via the next `tabs.changed` push), so there is no
/// failure to surface. `list` is a plain read of the latest relay state.
pub trait Tabs: Send + Sync {
    fn list(&self) -> TabsState;
    fn activate(&self, id: i64);
    fn close(&self, id: i64);
}

/// Browser bookmark relay (protoVersion 1.6, phase 11) — the [`Tabs`] shape
/// applied to bookmarks.
///
/// All FOUR commands return NOTHING: the SPEC §7 `bm.*` family is
/// fire-and-forget with no err reply (the same posture as `tabs.activate`),
/// so there is no failure to surface. A stale `node_id`/`tab_id`, a
/// permission-denied Chrome call, an unmodifiable managed bookmark — every
/// failure self-heals on the next full `bm.changed` snapshot. `list` is a
/// plain read of the latest relay state.
///
/// `remove` targets ONE bookmark or ONE **EMPTY** folder only (D-14). There
/// is deliberately no recursive/subtree method on this trait: the server
/// tier cannot express a subtree wipe, so the ext leg's escalated
/// destructive residual (SPEC §15) stays bounded by construction rather than
/// by convention.
pub trait Bookmarks: Send + Sync {
    fn list(&self) -> BookmarksState;
    fn open(&self, node_id: &str);
    fn star(&self, tab_id: i64);
    fn unstar(&self, tab_id: i64);
    fn remove(&self, node_id: &str);
}

/// One `update.progress` push in plain-data form (protoVersion 1.8, phase 12,
/// D-10/D-11) — the core-owned twin of `codec::json::UpdateProgressPayload`,
/// ZERO OS deps so server-core keeps compiling on CI Linux.
///
/// **`Default` yields an EMPTY `stage`, and an empty stage is a SENTINEL that
/// is NEVER sent on the wire** — the session push arm skips it. The D-10
/// vocabulary (`checking`, `downloading`, `verifying`, `installing`,
/// `restarting`, `uptodate`, `failed`) has no idle value, and a watch channel
/// needs an initial one; rather than invent an eighth stage that the phone
/// would have to learn to ignore, the initial value is a shape the protocol
/// cannot express and the producer filters out. Anything reading this type
/// must treat `stage.is_empty()` as "nothing has happened yet", not as a
/// stage.
///
/// `pct` belongs to `downloading` alone (D-10) and `error` draws from the
/// closed D-11 vocabulary — never free text, never a path, never a URL.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct UpdateProgress {
    /// Closed D-10 vocabulary, or EMPTY for the never-sent initial value.
    pub stage: String,
    /// `downloading` only (D-10).
    pub pct: Option<u8>,
    pub version: Option<String>,
    /// Closed D-11 vocabulary.
    pub error: Option<String>,
}

/// The outcome of the PREVIOUS update attempt (protoVersion 1.8, D-12) — the
/// plain-data twin of `codec::json::LastUpdatePayload`.
///
/// Read at startup from a marker file the server wrote before handing control
/// to the installer. It exists because the process that would otherwise have
/// reported a failed install **had already exited to let the installer replace
/// it**: without the marker, a failed PC install is indistinguishable from a
/// successful one that simply took a while to come back.
///
/// Deliberately NOT `Default`: there is no meaningful "no previous attempt"
/// value of this struct — that state is `UpdateInfo::last_update == None`.
#[derive(Debug, Clone, PartialEq)]
pub struct LastUpdate {
    pub target: String,
    pub ok: bool,
    /// Closed D-11 vocabulary; present only when `ok` is `false`.
    pub error: Option<String>,
}

/// Everything behind an `update.status` reply (protoVersion 1.8, D-09/D-12) —
/// the plain-data twin of `codec::json::UpdateStatusPayload`, returned by
/// [`UpdateExecutor::info`].
///
/// `Default` is the "no version known, extension never connected, no previous
/// attempt" shape. A real implementation always fills `server_version` from
/// its own compiled-in version, so the default's empty string should never
/// reach the wire.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct UpdateInfo {
    pub server_version: String,
    pub ext_connected: bool,
    /// `None` when the extension has never connected — skipped on the wire,
    /// never emitted as null.
    pub ext_version: Option<String>,
    /// `None` is the NORMAL case (no marker); see [`LastUpdate`].
    pub last_update: Option<LastUpdate>,
}

/// What the server knows about the connected browser extension (protoVersion
/// 1.8, phase 12) — the THIRD relay watch payload, beside [`TabsState`] and
/// [`BookmarksState`].
///
/// The ext relay publishes into it when it captures `ext.hello`'s `extVersion`
/// (12-12), and the Windows update executor reads it to fill
/// `update.status`'s `extConnected` and `extVersion`. It is defined HERE, in
/// the plan that owns the update state types, so that the executor can be
/// constructed a wave before the relay actually produces into it.
///
/// `Default` is the never-connected shape `{connected: false, version: None}`
/// — and `version: None` means "we have never seen a version", which is
/// exactly what `update.status` renders by omitting `extVersion`.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct ExtInfo {
    /// Whether a browser extension is currently connected (SPEC §15).
    pub connected: bool,
    /// The extension's self-reported version, `None` until an `ext.hello`
    /// carrying one has been seen.
    pub version: Option<String>,
}

/// In-app update control (protoVersion 1.8, phase 12).
///
/// Sync `&self` methods and NO OS types, per this module's header rule — which
/// here is not only a portability rule but the security boundary itself
/// (D-14, below). All I/O (feed fetch, download, sha256, installer spawn)
/// lives in the `server-windows` implementation, in a crate the codec cannot
/// see.
pub trait UpdateExecutor: Send + Sync {
    /// The data behind an `update.status` reply.
    ///
    /// A CHEAP READ with NO I/O — it reports state the executor already holds
    /// (its own version, the latest relay snapshot, a marker read once at
    /// startup). It never touches the network: the release feed is polled on
    /// the executor's own schedule, never on the request path.
    ///
    /// **It TAKES the pending `last_update`** rather than copying it: a marker
    /// is reported on exactly ONE `update.status` and never again (D-12).
    /// Reporting a stale marker on every subsequent status would show the
    /// owner a failure that has already been superseded — possibly by a
    /// success. That is why this read is `&self` but not idempotent.
    fn info(&self) -> UpdateInfo;

    /// Install `target` on this machine. FIRE-AND-FORGET: the work happens on
    /// the executor's own thread and reports back through `update.progress`
    /// pushes, so there is no return value and no error to surface here.
    ///
    /// **D-14 — `target` is a version string and NOTHING else.** The executor
    /// resolves the asset's download URL and its sha256 **itself**, from a
    /// repo constant compiled into its own binary, and never accepts, derives,
    /// or is influenced by a locator supplied over the wire. `target` is used
    /// for exactly two things: an equality check against the version the
    /// executor just resolved as latest (mismatch ⇒ `stale`) and an ordering
    /// check against the running version (at-or-below ⇒ `downgrade`, D-15).
    /// It is never concatenated into a URL or a filesystem path.
    ///
    /// **Widening this signature to accept a URL, a filename, an asset index,
    /// an asset id or a hash would convert a paired phone — or anything that
    /// obtained a token — into arbitrary code execution on the PC.** This is
    /// the strongest constraint in the protocol; it must not be relaxed for
    /// convenience, now or later. `tests/update_guard.rs` fails the build if a
    /// locator-named parameter appears here.
    fn apply(&self, target: &str);
}

/// The full executor bundle injected into dispatch and transport.
#[derive(Clone)]
pub struct Executors {
    pub mouse_keys: Arc<dyn MouseKeys>,
    pub media: Arc<dyn Media>,
    pub power: Arc<dyn Power>,
    pub apps: Arc<dyn Apps>,
    pub clipboard: Arc<dyn Clipboard>,
    pub tabs: Arc<dyn Tabs>,
    pub bookmarks: Arc<dyn Bookmarks>,
    /// In-app updates (protoVersion 1.8, phase 12) — the wire's ONE and ONLY
    /// route into the update path (T-12-01). It is a trait object like every
    /// sibling, and its `apply` takes a single `&str` version: there is
    /// deliberately no second entry point, no locator parameter and no
    /// side-channel through which the router could name a file (D-14).
    pub update: Arc<dyn UpdateExecutor>,
}
