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
//! NO logging of tab titles/urls anywhere in this module (T-01-31: extension
//! frames contain browsing data). This module currently logs nothing at all
//! — server-core is deliberately log-free; lifecycle visibility belongs to
//! the composition root.

use futures_util::{SinkExt, StreamExt};
use serde::Deserialize;
use serde_json::Value;
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::{mpsc, watch};
use tokio_tungstenite::WebSocketStream;
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::tungstenite::protocol::WebSocketConfig;

use crate::codec::json::{self, Msg, TabsActivatePayload, TabsClosePayload};
use crate::executors::{GroupInfo, TabInfo, Tabs, TabsState};

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

/// A phone-originated command relayed to the connected extension
/// (router → [`TabsRelay`] → [`run_ext`] → extension socket).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ExtCmd {
    /// `tabs.activate {id}` — switch the browser to that tab.
    Activate(i64),
    /// `tabs.close {id}` — close that tab.
    Close(i64),
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

/// The extension-leg envelope: tolerant local decode — the ext leg has no
/// codec harness (SPEC §15); unknown `t` and malformed payloads are ignored.
#[derive(Deserialize)]
struct ExtFrame {
    t: String,
    #[serde(default)]
    p: Value,
}

/// Run the extension accept/relay loop until every [`ExtCmd`] sender is
/// dropped. A SINGLE task owning one optional extension session
/// (newest-wins, SPEC §15).
///
/// Watch-channel contract: `tabs_tx` carries `{connected:true, tabs}` on
/// every extension `tabs.state` frame and resets to [`TabsState::default`]
/// UNCONDITIONALLY when the extension session ends for ANY reason
/// (CONN-07-style cleanup — this is what flips the phone to the
/// install-hint state when the browser closes).
pub async fn run_ext(
    listener: TcpListener,
    tabs_tx: watch::Sender<TabsState>,
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
                // pushes a full tabs.state within moments.
                session = Some(ws);
            }
            cmd = cmd_rx.recv() => {
                let Some(cmd) = cmd else {
                    // Every TabsRelay sender dropped: the relay is over.
                    break;
                };
                if let Some(ws) = session.as_mut() {
                    let msg = match cmd {
                        ExtCmd::Activate(id) => {
                            Msg::TabsActivate(TabsActivatePayload { id })
                        }
                        ExtCmd::Close(id) => Msg::TabsClose(TabsClosePayload { id }),
                    };
                    let frame = Message::text(json::encode_msg(&msg, None));
                    if ws.send(frame).await.is_err() {
                        // Send failure: the extension is gone — drop the
                        // session AND reset the watch (hint state).
                        session = None;
                        let _ = tabs_tx.send(TabsState::default());
                    }
                }
                // No session → the command is dropped silently (the phone
                // already renders connected:false).
            }
            incoming = async { session.as_mut().expect("branch guarded by is_some").next().await }, if session.is_some() => {
                match incoming {
                    Some(Ok(Message::Text(text))) => {
                        if let Some(pong) = handle_ext_text(text.as_str(), &tabs_tx) {
                            if let Some(ws) = session.as_mut() {
                                if ws.send(pong).await.is_err() {
                                    session = None;
                                    let _ = tabs_tx.send(TabsState::default());
                                }
                            }
                        }
                    }
                    // Binary/control frames: tungstenite answers WS Ping
                    // itself; anything else on this leg is ignored.
                    Some(Ok(_)) => {}
                    // Stream end or error — INCLUDING a 64 KB-cap kill:
                    // reset the watch UNCONDITIONALLY (CONN-07-style
                    // cleanup) and clear the session.
                    None | Some(Err(_)) => {
                        session = None;
                        let _ = tabs_tx.send(TabsState::default());
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
fn handle_ext_text(text: &str, tabs_tx: &watch::Sender<TabsState>) -> Option<Message> {
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
        "ext.ping" => Some(Message::text(
            serde_json::json!({"t": "ext.pong", "p": {}}).to_string(),
        )),
        // First frame after connect: accepted silently (SPEC §15).
        "ext.hello" => None,
        // Unknown type: ignored (forward compatibility).
        _ => None,
    }
}
