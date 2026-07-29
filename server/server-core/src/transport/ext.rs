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
    BmNode, Bookmarks, BookmarksState, GroupInfo, TabInfo, Tabs, TabsState,
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

/// Reset EVERY relay watch to its never-connected default — the single
/// session-death cleanup point.
///
/// Called at all three session-end sites (cmd-send failure, pong-send
/// failure, stream end/error). It exists so the sites cannot drift apart: a
/// stale bookmark tree sitting next to a correct "install the extension"
/// hint is exactly the bug a per-site `send(Default)` invites. **A future
/// fourth relay watch must be added HERE and nowhere else** — then a missed
/// site is structurally impossible rather than merely unlikely.
fn reset_relay_watches(
    tabs_tx: &watch::Sender<TabsState>,
    bm_tx: &watch::Sender<BookmarksState>,
) {
    let _ = tabs_tx.send(TabsState::default());
    let _ = bm_tx.send(BookmarksState::default());
}

/// Run the extension accept/relay loop until every [`ExtCmd`] sender is
/// dropped. A SINGLE task owning one optional extension session
/// (newest-wins, SPEC §15).
///
/// Watch-channel contract: `tabs_tx` carries `{connected:true, tabs}` on
/// every extension `tabs.state` frame, `bm_tx` carries
/// `{connected:true, nodes}` on every `bm.state` frame, and BOTH reset to
/// their defaults UNCONDITIONALLY and in the SAME instant when the extension
/// session ends for ANY reason (CONN-07-style cleanup — this is what flips
/// the phone to the install-hint state when the browser closes). Resetting
/// only one would leave the phone rendering a stale, tappable bookmark tree
/// beside a correct install hint.
pub async fn run_ext(
    listener: TcpListener,
    tabs_tx: watch::Sender<TabsState>,
    bm_tx: watch::Sender<BookmarksState>,
    mut cmd_rx: mpsc::Receiver<ExtCmd>,
) {
    // SPEC §13 per-listener caps, applied AT ACCEPT (same as listener.rs).
    let config = WebSocketConfig::default()
        .max_message_size(Some(MAX_WS_MESSAGE_BYTES))
        .max_frame_size(Some(MAX_WS_MESSAGE_BYTES));

    let mut session: Option<WebSocketStream<TcpStream>> = None;

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
                    };
                    if ws.send(Message::text(text)).await.is_err() {
                        // Send failure: the extension is gone — drop the
                        // session AND reset BOTH watches (hint state).
                        session = None;
                        reset_relay_watches(&tabs_tx, &bm_tx);
                    }
                }
                // No session → the command is dropped silently (the phone
                // already renders connected:false).
            }
            incoming = async { session.as_mut().expect("branch guarded by is_some").next().await }, if session.is_some() => {
                match incoming {
                    Some(Ok(Message::Text(text))) => {
                        if let Some(pong) = handle_ext_text(text.as_str(), &tabs_tx, &bm_tx) {
                            if let Some(ws) = session.as_mut() {
                                if ws.send(pong).await.is_err() {
                                    session = None;
                                    reset_relay_watches(&tabs_tx, &bm_tx);
                                }
                            }
                        }
                    }
                    // Binary/control frames: tungstenite answers WS Ping
                    // itself; anything else on this leg is ignored.
                    Some(Ok(_)) => {}
                    // Stream end or error — INCLUDING a 64 KB-cap kill:
                    // reset BOTH watches UNCONDITIONALLY (CONN-07-style
                    // cleanup) and clear the session.
                    None | Some(Err(_)) => {
                        session = None;
                        reset_relay_watches(&tabs_tx, &bm_tx);
                    }
                }
            }
        }
    }
}

/// Handle one extension text frame. Returns an optional reply frame
/// (`ext.pong`). Tolerant end to end: malformed JSON, a bad `tabs` payload,
/// and unknown types are all ignored (SPEC §15 — no err vocabulary on this
/// leg).
fn handle_ext_text(
    text: &str,
    tabs_tx: &watch::Sender<TabsState>,
    bm_tx: &watch::Sender<BookmarksState>,
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
        // First frame after connect: accepted silently (SPEC §15).
        "ext.hello" => None,
        // Unknown type: ignored (forward compatibility).
        _ => None,
    }
}
