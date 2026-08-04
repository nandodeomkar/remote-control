//! Extension leg (SPEC §15, BROW-01): a SECOND WebSocket listener bound to
//! 127.0.0.1 ONLY, spoken by the "Tab Bridge" browser extension on the same
//! machine. The loopback bind IS the auth boundary — a LAN device cannot
//! complete a TCP handshake to a loopback-bound socket; the kernel enforces
//! it (belt-and-braces `is_loopback` assert in the accept arm).
//!
//! Single-extension newest-wins policy: [`run_ext`] is ONE task owning one
//! optional extension session — no spawn-per-connection, zero task-abort
//! races. A second accepted connection replaces the current session.
//!
//! NO logging of tab titles/urls — nor, as of protoVersion 1.6, bookmark
//! node titles (T-01-31 / T-11-02: extension frames contain browsing data,
//! and a bookmark tree is a durable profile of it). If a log line is ever
//! added here it carries counts and lifecycle only. This module currently
//! logs nothing at all — server-core is deliberately log-free; lifecycle
//! visibility belongs to the composition root.

use futures_util::{SinkExt, StreamExt};
use serde::Deserialize;
use serde_json::Value;
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::{mpsc, watch};
use tokio_tungstenite::WebSocketStream;
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::tungstenite::protocol::WebSocketConfig;

use crate::codec::json::{self, Msg, TabsActivatePayload, TabsClosePayload};
use crate::executors::{
    BmNode, Bookmarks, BookmarksState, ExtInfo, GroupInfo, TabInfo, Tabs, TabsState,
};

/// Default extension-listener port (SPEC §15). Doc-pinned against the
/// sibling defaults: the main WS listener is 17777, the UDP discovery
/// beacon is 17778 — 17779 is verified collision-free. Overridable via the
/// composition root's `RC_EXT_PORT` env var.
pub const DEFAULT_EXT_PORT: u16 = 17779;

/// SPEC §13: the 64 KB WebSocket caps apply PER-LISTENER — the extension
/// leg gets the same limits as the main listener (an oversize frame kills
/// the extension session, never the server).
const MAX_WS_MESSAGE_BYTES: usize = 65536;

/// Server-side belt for the extension-side 50-tab cap (SPEC §15): a
/// `tabs.state` snapshot is truncated here regardless of what the extension
/// sent.
const MAX_EXT_TABS: usize = 50;

/// Server-side belt for the extension-side 16-group cap (SPEC §15,
/// protoVersion 1.5) — the MAX_EXT_TABS pattern applied to groups.
const MAX_EXT_GROUPS: usize = 16;

/// Server-side belt for the extension-side 500-node cap (SPEC §15,
/// protoVersion 1.6) — the MAX_EXT_TABS pattern applied to bookmark nodes.
const MAX_EXT_BM_NODES: usize = 500;

/// A phone-originated command relayed to the connected extension
/// (router → [`TabsRelay`]/[`BookmarksRelay`] → [`run_ext`] → extension
/// socket).
///
/// NOT `Copy` (unlike protoVersion 1.4/1.5): the protoVersion-1.6 bookmark
/// variants carry a heap-owned `String` node id. The command arm consumes an
/// owned value straight out of `cmd_rx.recv()`, so moving the `String` out of
/// the variant needs no clone.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ExtCmd {
    /// `tabs.activate {id}` — switch the browser to that tab.
    Activate(i64),
    /// `tabs.close {id}` — close that tab.
    Close(i64),
    /// `bm.open {nodeId}` — open that bookmark in a NEW tab; the extension
    /// resolves the url (it never crosses the phone-facing wire).
    BmOpen(String),
    /// `bm.star {tabId}` — bookmark that tab's url into the bookmarks bar.
    BmStar(i64),
    /// `bm.unstar {tabId}` — remove every bookmark matching that tab's url.
    BmUnstar(i64),
    /// `bm.remove {nodeId}` — remove one bookmark or one EMPTY folder (D-14;
    /// `removeTree` is never expressed).
    BmRemove(String),
    /// `ext.reload {}` — srv-to-ext ONLY, empty payload (protoVersion 1.8,
    /// D-18). The extension answers by calling `chrome.runtime.reload()`,
    /// which re-reads its files from disk — so a PC update that replaced
    /// `{app}\extension` takes effect without anyone opening
    /// `chrome://extensions` (SC7).
    ///
    /// It carries NOTHING. There is no path, no url and no version in it: the
    /// extension reloads itself from wherever it was already loaded, and this
    /// command cannot redirect that (T-12-01). The extension never sends it.
    Reload,
}

/// The [`Tabs`] executor backed by the extension relay: list reads come
/// from the watch channel [`run_ext`] produces into; activate/close are
/// fire-and-forget commands into [`run_ext`]'s mpsc (mirrors how WinApps
/// pairs a command sender with a snapshot receiver).
pub struct TabsRelay {
    state: watch::Receiver<TabsState>,
    cmd: mpsc::Sender<ExtCmd>,
}

impl TabsRelay {
    /// Pair the relay with `run_ext`'s channels: `state` is a clone of the
    /// receiver also handed to `ServerDeps.tabs`; `cmd` feeds `run_ext`.
    pub fn new(state: watch::Receiver<TabsState>, cmd: mpsc::Sender<ExtCmd>) -> Self {
        Self { state, cmd }
    }
}

impl Tabs for TabsRelay {
    fn list(&self) -> TabsState {
        self.state.borrow().clone()
    }

    /// Fire-and-forget from the sync trait: `try_send` — a full or closed
    /// channel is silently dropped (the phone already renders
    /// `connected:false`; the router's drop-silently posture).
    fn activate(&self, id: i64) {
        let _ = self.cmd.try_send(ExtCmd::Activate(id));
    }

    fn close(&self, id: i64) {
        let _ = self.cmd.try_send(ExtCmd::Close(id));
    }
}

/// The [`Bookmarks`] executor backed by the extension relay (protoVersion
/// 1.6) — the [`TabsRelay`] shape applied to the SECOND watch channel
/// [`run_ext`] produces into. `list` reads the watch; the four commands are
/// fire-and-forget into the SAME mpsc `TabsRelay` uses (one command stream,
/// one extension socket).
pub struct BookmarksRelay {
    state: watch::Receiver<BookmarksState>,
    cmd: mpsc::Sender<ExtCmd>,
}

impl BookmarksRelay {
    /// Pair the relay with `run_ext`'s channels: `state` is the receiver
    /// side of the bookmarks watch `run_ext` owns the sender for; `cmd` is a
    /// CLONE of the sender `TabsRelay` also holds.
    pub fn new(state: watch::Receiver<BookmarksState>, cmd: mpsc::Sender<ExtCmd>) -> Self {
        Self { state, cmd }
    }
}

impl Bookmarks for BookmarksRelay {
    fn list(&self) -> BookmarksState {
        self.state.borrow().clone()
    }

    /// Fire-and-forget from the sync trait: `try_send` — a full or closed
    /// channel is silently dropped (the phone already renders
    /// `connected:false`; the router's drop-silently posture). Identical for
    /// all four commands: SPEC §7 gives the `bm.*` family no err vocabulary,
    /// so every failure self-heals on the next full snapshot.
    fn open(&self, node_id: &str) {
        let _ = self.cmd.try_send(ExtCmd::BmOpen(node_id.to_string()));
    }

    fn star(&self, tab_id: i64) {
        let _ = self.cmd.try_send(ExtCmd::BmStar(tab_id));
    }

    fn unstar(&self, tab_id: i64) {
        let _ = self.cmd.try_send(ExtCmd::BmUnstar(tab_id));
    }

    fn remove(&self, node_id: &str) {
        let _ = self.cmd.try_send(ExtCmd::BmRemove(node_id.to_string()));
    }
}

/// The extension-leg envelope: tolerant local decode — the ext leg has no
/// codec harness (SPEC §15); unknown `t` and malformed payloads are ignored.
#[derive(Deserialize)]
struct ExtFrame {
    t: String,
    #[serde(default)]
    p: Value,
}

/// The `ext.reload` wire frame, spelled ONCE.
///
/// Two call sites reach it — the [`ExtCmd::Reload`] dispatch arm and the
/// version-drift nudge on `ext.hello` — and a second spelling is a second
/// thing that can drift from `background.js`'s `case "ext.reload"`.
fn reload_frame() -> String {
    serde_json::json!({"t": "ext.reload", "p": {}}).to_string()
}

/// Should a stale `ext.hello` be answered with exactly one reload nudge?
///
/// Pure, so the three ways to say "no" are testable without a socket:
///
///   1. **No reported version at all** — unknown is not "different". An
///      extension built before protoVersion 1.8 omits `extVersion` entirely,
///      and nudging it would reload a browser worker on no evidence.
///   2. **The reported version already matches** — nothing to do.
///   3. **A reload was already attempted for this server version this process
///      run** — THE LOOP BREAKER (D-18, T-12-56). `chrome.runtime.reload()`
///      makes the extension reconnect and send a fresh `ext.hello`, so if the
///      overwrite did not actually take (Chrome held the file), that second
///      hello carries the SAME stale version. Without this clause the pair
///      would nudge each other forever.
///
/// The guard is keyed on the SERVER's version, not the extension's: the
/// question it answers is "have I already asked for this target", and the
/// target is what the server wants the extension to become.
fn should_nudge(reported: Option<&str>, server_version: &str, attempted_for: Option<&str>) -> bool {
    match reported {
        None => false,
        Some(v) if v == server_version => false,
        Some(_) => attempted_for != Some(server_version),
    }
}

/// Reset EVERY relay watch to its never-connected default — the single
/// session-death cleanup point.
///
/// Called at all three session-end sites (cmd-send failure, pong-send
/// failure, stream end/error). It exists so the sites cannot drift apart: a
/// stale bookmark tree sitting next to a correct "install the extension"
/// hint is exactly the bug a per-site `send(Default)` invites. **A future
/// FOURTH relay watch must be added HERE and nowhere else** — then a missed
/// site is structurally impossible rather than merely unlikely.
///
/// The three watches are tabs (protoVersion 1.4), bookmarks (1.6) and ext
/// info (1.8). The last resets to `{connected: false, version: None}`, which
/// is what makes `update.status` stop claiming a browser extension is
/// connected the instant it is not — and stop reporting the version of an
/// extension that is no longer running.
fn reset_relay_watches(
    tabs_tx: &watch::Sender<TabsState>,
    bm_tx: &watch::Sender<BookmarksState>,
    ext_tx: &watch::Sender<ExtInfo>,
) {
    let _ = tabs_tx.send(TabsState::default());
    let _ = bm_tx.send(BookmarksState::default());
    let _ = ext_tx.send(ExtInfo::default());
}

/// Run the extension accept/relay loop until every [`ExtCmd`] sender is
/// dropped. A SINGLE task owning one optional extension session
/// (newest-wins, SPEC §15).
///
/// Watch-channel contract: `tabs_tx` carries `{connected:true, tabs}` on
/// every extension `tabs.state` frame, `bm_tx` carries
/// `{connected:true, nodes}` on every `bm.state` frame, `ext_tx` carries
/// `{connected:true, version}` from the moment an `ext.hello` is received,
/// and ALL THREE reset to their defaults UNCONDITIONALLY and in the SAME
/// instant when the extension session ends for ANY reason (CONN-07-style
/// cleanup — this is what flips the phone to the install-hint state when the
/// browser closes). Resetting only some would leave the phone rendering a
/// stale, tappable bookmark tree — or a stale extension version on the
/// Updates screen — beside a correct install hint.
///
/// `ext_tx` (protoVersion 1.8, D-09/D-18) is the odd one out in one respect:
/// its producer frame is `ext.hello`, which arrives ONCE at the start of a
/// session rather than repeatedly like the two snapshot frames. Its `version`
/// is the extension's OWN self-report and is used only for display and for
/// 12-16's version comparison — never as a locator (D-14), and never trusted
/// as an authenticated claim (T-12-40: a local process able to open the
/// loopback socket already owns the machine, SPEC §15).
/// `server_version` is the SHIPPING binary's version, passed in from the
/// composition root (D-05). It is deliberately NOT read from this crate's own
/// package-version env var — that would be `server-core`'s library version,
/// which is not what ships and not what an extension should be compared
/// against. A plan-check greps this file for that env var and requires zero
/// occurrences, which is why this sentence does not spell it.
pub async fn run_ext(
    listener: TcpListener,
    tabs_tx: watch::Sender<TabsState>,
    bm_tx: watch::Sender<BookmarksState>,
    ext_tx: watch::Sender<ExtInfo>,
    mut cmd_rx: mpsc::Receiver<ExtCmd>,
    server_version: String,
) {
    // SPEC §13 per-listener caps, applied AT ACCEPT (same as listener.rs).
    let config = WebSocketConfig::default()
        .max_message_size(Some(MAX_WS_MESSAGE_BYTES))
        .max_frame_size(Some(MAX_WS_MESSAGE_BYTES));

    let mut session: Option<WebSocketStream<TcpStream>> = None;

    // The target version a reload has already been attempted for, this process
    // run. NEVER reset — not on session end, not in `reset_relay_watches`, not
    // on a newest-wins replacement. A server restart is the only reset, and
    // that is precisely the intent (D-18, T-12-56): a reload makes the
    // extension reconnect and hello again, so anything that cleared this would
    // reopen the loop it exists to close.
    let mut reload_attempted_for: Option<String> = None;

    loop {
        tokio::select! {
            accepted = listener.accept() => {
                let (stream, peer) = match accepted {
                    Ok(conn) => conn,
                    // Transient accept errors must not kill the relay.
                    Err(_) => continue,
                };
                // Belt-and-braces (T-TABS-01): the 127.0.0.1 bind already
                // kernel-enforces this — a non-loopback peer is dropped.
                if !peer.ip().is_loopback() {
                    continue;
                }
                let ws = match tokio_tungstenite::accept_async_with_config(
                    stream,
                    Some(config),
                )
                .await
                {
                    Ok(ws) => ws,
                    Err(_) => continue,
                };
                // Newest-wins: REPLACE the current session (old stream
                // dropped). No watch reset on replace — the new extension
                // pushes a full tabs.state (and bm.state) within moments,
                // and blanking the bookmark tree on every reconnect would be
                // a visible flicker for no gain.
                session = Some(ws);
            }
            cmd = cmd_rx.recv() => {
                let Some(cmd) = cmd else {
                    // Every TabsRelay sender dropped: the relay is over.
                    break;
                };
                if let Some(ws) = session.as_mut() {
                    // The tabs commands round-trip through the phone-facing
                    // codec; the bookmark commands are built from a LOCAL
                    // json! envelope instead. Why the asymmetry: the ext leg
                    // is its own contract (SPEC §15 — no codec harness), and
                    // ingress already parses this leg with the local tolerant
                    // `ExtFrame` rather than the phone-facing `Msg` enum.
                    // Keeping egress local too means `run_ext` does not
                    // depend on the phone-facing bm codec at all (it lands in
                    // 11-03), and the exact key names are pinned by the
                    // ext_relay.rs socket tests instead.
                    //
                    // `nodeId` (STRING) vs `tabId` (INTEGER) is load-bearing:
                    // a swap decodes fine on both sides and then fails
                    // silently at the extension.
                    let text = match cmd {
                        ExtCmd::Activate(id) => {
                            json::encode_msg(&Msg::TabsActivate(TabsActivatePayload { id }), None)
                        }
                        ExtCmd::Close(id) => {
                            json::encode_msg(&Msg::TabsClose(TabsClosePayload { id }), None)
                        }
                        ExtCmd::BmOpen(node_id) => {
                            serde_json::json!({"t": "bm.open", "p": {"nodeId": node_id}}).to_string()
                        }
                        ExtCmd::BmStar(tab_id) => {
                            serde_json::json!({"t": "bm.star", "p": {"tabId": tab_id}}).to_string()
                        }
                        ExtCmd::BmUnstar(tab_id) => {
                            serde_json::json!({"t": "bm.unstar", "p": {"tabId": tab_id}}).to_string()
                        }
                        ExtCmd::BmRemove(node_id) => {
                            serde_json::json!({"t": "bm.remove", "p": {"nodeId": node_id}})
                                .to_string()
                        }
                        ExtCmd::Reload => reload_frame(),
                    };
                    if ws.send(Message::text(text)).await.is_err() {
                        // Send failure: the extension is gone — drop the
                        // session AND reset EVERY watch (hint state).
                        session = None;
                        reset_relay_watches(&tabs_tx, &bm_tx, &ext_tx);
                    }
                }
                // No session → the command is dropped silently (the phone
                // already renders connected:false).
            }
            incoming = async { session.as_mut().expect("branch guarded by is_some").next().await }, if session.is_some() => {
                match incoming {
                    Some(Ok(Message::Text(text))) => {
                        if let Some(pong) = handle_ext_text(
                            text.as_str(),
                            &tabs_tx,
                            &bm_tx,
                            &ext_tx,
                            &server_version,
                            &mut reload_attempted_for,
                        ) {
                            if let Some(ws) = session.as_mut() {
                                if ws.send(pong).await.is_err() {
                                    session = None;
                                    reset_relay_watches(&tabs_tx, &bm_tx, &ext_tx);
                                }
                            }
                        }
                    }
                    // Binary/control frames: tungstenite answers WS Ping
                    // itself; anything else on this leg is ignored.
                    Some(Ok(_)) => {}
                    // Stream end or error — INCLUDING a 64 KB-cap kill:
                    // reset EVERY watch UNCONDITIONALLY (CONN-07-style
                    // cleanup) and clear the session.
                    None | Some(Err(_)) => {
                        session = None;
                        reset_relay_watches(&tabs_tx, &bm_tx, &ext_tx);
                    }
                }
            }
        }
    }
}

/// Handle one extension text frame. Returns an optional frame to send back —
/// `ext.pong` for a ping, or the one `ext.reload` nudge for a version-drifted
/// hello. Tolerant end to end: malformed JSON, a bad `tabs` payload, and
/// unknown types are all ignored (SPEC §15 — no err vocabulary on this leg).
///
/// The reload rides the existing return channel rather than looping back
/// through `cmd_rx`: a self-send into the mpsc this same `select!` drains
/// would be a needless round trip, and a full channel would silently drop the
/// nudge. `reload_attempted_for` is `&mut` because the decision and the
/// recording of it must be the same step — a guard set anywhere other than the
/// instant the nudge is emitted is a guard with a window in it.
fn handle_ext_text(
    text: &str,
    tabs_tx: &watch::Sender<TabsState>,
    bm_tx: &watch::Sender<BookmarksState>,
    ext_tx: &watch::Sender<ExtInfo>,
    server_version: &str,
    reload_attempted_for: &mut Option<String>,
) -> Option<Message> {
    let frame: ExtFrame = match serde_json::from_str(text) {
        Ok(frame) => frame,
        Err(_) => return None,
    };
    match frame.t.as_str() {
        "tabs.state" => {
            let raw = frame.p.get("tabs").cloned().unwrap_or(Value::Null);
            // Tolerant: a parse failure ignores the frame entirely.
            if let Ok(mut tabs) = serde_json::from_value::<Vec<TabInfo>>(raw) {
                // Server-side belt for the extension-side cap (SPEC §15).
                tabs.truncate(MAX_EXT_TABS);
                // Groups (protoVersion 1.5): MORE tolerant than tabs — a
                // malformed/absent groups array degrades to empty rather
                // than discarding the whole frame (tabs are the payload
                // that matters; groups are decoration).
                let mut groups = frame
                    .p
                    .get("groups")
                    .cloned()
                    .map(serde_json::from_value::<Vec<GroupInfo>>)
                    .and_then(Result::ok)
                    .unwrap_or_default();
                groups.truncate(MAX_EXT_GROUPS);
                let _ = tabs_tx.send(TabsState { connected: true, tabs, groups });
            }
            None
        }
        // protoVersion 1.6: ONE flattened snapshot of the whole bookmark
        // tree (D-06), never a diff. STRICT like `tabs`, not lenient like
        // `groups`: nodes ARE the payload, so a parse failure ignores the
        // whole frame and the watch keeps the last good tree — a half-parsed
        // or emptied tree would be a wrong answer rendered as a real one.
        "bm.state" => {
            let raw = frame.p.get("nodes").cloned().unwrap_or(Value::Null);
            if let Ok(mut nodes) = serde_json::from_value::<Vec<BmNode>>(raw) {
                // Server-side belt for the extension-side cap (SPEC §15) —
                // applied regardless of what the extension claims it sent.
                nodes.truncate(MAX_EXT_BM_NODES);
                // The snapshot-level flag is read leniently (the node array
                // is the strict part): absent or non-bool ⇒ false.
                let truncated = frame
                    .p
                    .get("truncated")
                    .and_then(Value::as_bool)
                    .unwrap_or(false);
                let _ = bm_tx.send(BookmarksState { connected: true, nodes, truncated });
            }
            None
        }
        "ext.ping" => Some(Message::text(
            serde_json::json!({"t": "ext.pong", "p": {}}).to_string(),
        )),
        // First frame after connect: still answered silently (SPEC §15 — no
        // reply on this leg), but no longer a no-op. protoVersion 1.8 turns
        // it into the THIRD relay watch's producer (D-09/D-18): the server
        // learns which extension build is running, which is what
        // `update.status` reports as `extConnected`/`extVersion`.
        //
        // `extVersion` is read with the LENIENT ext-leg convention (the
        // `truncated` precedent above): absent, null or non-string yields
        // `None` — never an error, never a dropped frame. An extension built
        // before 1.8 does not send it, and "connected but version unknown" is
        // a truthful state the wire can express by omitting `extVersion`.
        // T-12-41: this is also why a malformed payload cannot panic here.
        //
        // protoVersion 1.8 also makes this the ONLY place a version-drift
        // nudge can originate (D-18): the hello is the one frame that reports
        // which extension build is running, so it is the one frame that can
        // notice the build is behind the server.
        "ext.hello" => {
            let version = frame
                .p
                .get("extVersion")
                .and_then(Value::as_str)
                .map(str::to_string);
            let _ = ext_tx.send(ExtInfo {
                connected: true,
                version: version.clone(),
            });
            // D-18/SC7: the extension is running an older build than the
            // server, so a PC update replaced `{app}\extension` under it.
            // Nudge it EXACTLY once per target version per process run — set
            // the guard in the same step that emits, so there is no window in
            // which a second hello could slip past.
            if should_nudge(
                version.as_deref(),
                server_version,
                reload_attempted_for.as_deref(),
            ) {
                *reload_attempted_for = Some(server_version.to_string());
                return Some(Message::text(reload_frame()));
            }
            None
        }
        // Unknown type: ignored (forward compatibility).
        _ => None,
    }
}
