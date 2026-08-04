//! Per-connection session task internals: read loop → codec →
//! `dispatch::router` behind the auth/pause gates, write half fed by an mpsc
//! queue, and the UNSKIPPABLE post-loop cleanup that releases held input
//! (CONN-07 — structured so cleanup runs after the loop exits on clean
//! close, socket error, abort, AND liveness-deadline expiry — the half-open
//! TCP leg after an abrupt WiFi loss, where no FIN/RST ever arrives).
//!
//! The handshake FSM (AwaitingHello → AwaitingAuth → Authed, SPEC §3) is
//! owned HERE, not in dispatch: `hello`/`pin`/`auth` never reach
//! [`router::route`]. Not part of the public API — everything external goes
//! through [`super::run`].
//!
//! No logging anywhere in this module (threat T-01-31): `pin` digits, `auth`
//! macs, tokens, and `text` payloads must never appear in any log sink.

use std::net::IpAddr;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use futures_util::{SinkExt, StreamExt};
use tokio::net::TcpStream;
use tokio::sync::{mpsc, watch};
// tokio's Instant (not std's) so the paused-clock regression test
// (`tokio::time::pause` + auto-advance) can drive the liveness deadline
// deterministically. Outside a test runtime it is std's Instant.
use tokio::time::{Instant, sleep_until};
use tokio_tungstenite::WebSocketStream;
use tokio_tungstenite::tungstenite::Message;

use crate::auth::AuthManager;
use crate::auth::pin::PinOutcome;
use super::{ClipState, VolumeState};
use crate::codec::json::{
    AppsChangedPayload, AuthFailPayload, AuthOkPayload, BmChangedPayload, ChallengePayload,
    ClipChangedPayload, ErrPayload, InputBlockedPayload, Msg, PairOkPayload, TabsChangedPayload,
    UpdateProgressPayload, VolChangedPayload,
};
use crate::codec::{binary, json};
use crate::dispatch::AuthState;
use crate::dispatch::held::HeldInput;
use crate::dispatch::router::{self, SessionCtx};
use crate::executors::{BookmarksState, Executors, TabsState, UpdateProgress, WindowInfo};

/// The server's protocol version (SPEC §2). Only the MAJOR component is
/// compared against the client's `hello.protoVersion`. `pub` (re-exported
/// via [`super`]) so the beacon's `proto` field AND tests asserting "the
/// current server version" reference it instead of duplicating the literal.
/// 1.1 adds the additive `vol.changed` S→C push (MED-02, D-03) — minor
/// bump: 1.0 clients are still accepted (§2). 1.2 adds the additive
/// `WindowInfo.icon`/`.path` fields + the `apps.changed` S→C push (APPS-02,
/// APPS-03) — still a minor bump, so 1.0/1.1 clients remain accepted (§2).
/// 1.3 adds the additive `input.blocked` S→C push (SRV-05, D-07) — a
/// transient UIPI-elevated-foreground-window notice — still a minor bump,
/// so 1.0/1.1/1.2 clients remain accepted (§2).
/// 1.4 adds the additive `tabs.*` family (BROW-01) — browser tab list fed
/// by the localhost extension leg (SPEC §15) — minor bump, 1.0–1.3 clients
/// still accepted (§2).
/// 1.5 adds tab-group visibility (BROW-01, quick 260716-sme) — the GroupEl
/// element, optional `groups` on the tabs payloads, and the optional TabEl
/// `groupId` — minor bump, 1.0–1.4 clients still accepted (§2).
/// 1.6 adds the additive `bm.*` bookmark family (phase 11) — bookmark tree
/// view, open, star/unstar and remove, fed by the localhost extension leg
/// (SPEC §15) — plus the optional tri-state `TabInfo.bookmarked` flag;
/// minor bump, so 1.0–1.5 clients remain accepted (§2).
/// 1.7 adds the additive `0x03` zoom binary opcode (quick 260731-euq) — a
/// 1.0–1.6 server's strict decoder simply drops the frame under §9 rule 4, so
/// the degradation is graceful and no JSON type was added.
/// 1.8 adds the additive `update.*` family (phase 12) — `update.check`,
/// `update.status`, `update.apply` and the `update.progress` S→C push, for
/// in-app APK and PC self-update; minor bump, so 1.0–1.7 clients remain
/// accepted (§2). **This literal is also embedded in the UDP beacon payload
/// (`beacon.rs`) and pinned TWICE in
/// `protocol/fixtures/beacon/01-valid.json` — changing it here without
/// changing the fixture fails `codec_fixtures_beacon`.**
pub const SERVER_PROTO_VERSION: &str = "1.8";
const SERVER_PROTO_MAJOR: u64 = 1;

/// POST-auth liveness deadline: an Authed session receiving NO inbound
/// frames for this long breaks its read loop so the CONN-07 cleanup
/// releases held input.
///
/// Rationale: the client emits protocol pings every ~250ms under move load
/// and ~2s idle (latency_probe.dart `pingIntervalMillis` /
/// `idlePingIntervalMillis`), so 10s is ≥ 5× the slowest healthy inbound
/// cadence — a live client can never trip this. Without it, a half-open TCP
/// connection after an abrupt WiFi kill (no FIN, no RST) keeps
/// `stream.next()` pending for OS-timeout minutes while held input stays
/// stuck (04-UAT Test 5, threat class T-04-04). Private on purpose —
/// nothing else needs it; the integration test hard-codes a longer wait
/// and names the coupling.
const LIVENESS_TIMEOUT: Duration = Duration::from_secs(10);

/// PRE-auth liveness deadline (review CR-01): before `Authed`, the client
/// sends NOTHING while the user reads the PIN off the PC toast and types 6
/// digits — protocol pings only start post-auth — so pre-auth silence is
/// the NORMAL pairing shape, routinely >10s. The auth PIN window budgets
/// 60s ([`crate::auth::pin::PIN_TTL_SECS`]) for exactly this; 90s = that
/// window + margin, so the deadline can never race a still-valid PIN.
/// Held input only exists post-auth, so the UAT Test 5 contract (10s)
/// loses nothing here; a silent pre-hello socket squatter still dies in
/// 90s instead of holding a session task forever (T-04-10-02, relaxed).
const PRE_AUTH_LIVENESS_TIMEOUT: Duration = Duration::from_secs(90);

/// Run one connection to completion: write task + read loop + handshake FSM
/// + unconditional held-input cleanup (CONN-07).
pub(super) async fn run_session(
    ws: WebSocketStream<TcpStream>,
    peer_ip: IpAddr,
    executors: Executors,
    auth: Arc<Mutex<AuthManager>>,
    mut pause: watch::Receiver<bool>,
    mut volume: watch::Receiver<VolumeState>,
    mut apps: watch::Receiver<Vec<WindowInfo>>,
    mut clip: watch::Receiver<ClipState>,
    conn_count: Arc<watch::Sender<usize>>,
    mut revoke: watch::Receiver<u64>,
    mut blocked: watch::Receiver<u64>,
    mut tabs: watch::Receiver<TabsState>,
    mut bookmarks: watch::Receiver<BookmarksState>,
    mut update: watch::Receiver<UpdateProgress>,
) {
    let (mut sink, mut stream) = ws.split();

    // Write task: the read loop never touches the sink directly — replies
    // are queued on this channel and written (in order) by a dedicated task.
    let (tx, mut rx) = mpsc::channel::<Message>(64);
    let write_task = tokio::spawn(async move {
        while let Some(msg) = rx.recv().await {
            if sink.send(msg).await.is_err() {
                break;
            }
        }
    });

    let mut ctx = SessionCtx {
        auth_state: AuthState::AwaitingHello,
        held: HeldInput::default(),
        pending_power: None,
    };
    // The challenge nonce issued to THIS connection (SPEC §3): fresh per
    // connection, consumed by the `auth` verification path.
    let mut session_nonce: Option<[u8; 32]> = None;
    // Errored binary frames are dropped and counted, never routed and never
    // fatal (SPEC §9). Diagnostics-only until tracing lands in Phase 2.
    let mut binary_decode_errors: u64 = 0;
    // The pause watch sender may drop before the session ends; disable the
    // branch then (`changed()` would return Err forever and busy-loop).
    let mut pause_alive = true;
    // Same discipline for the volume watch (MED-02): producer dropped →
    // disable the branch, never busy-loop.
    let mut volume_alive = true;
    // Same discipline for the apps watch (APPS-03): producer dropped →
    // disable the branch, never busy-loop.
    let mut apps_alive = true;
    // Same discipline for the clip watch (CLIP-03): producer dropped →
    // disable the branch, never busy-loop.
    let mut clip_alive = true;
    // Same discipline for the revoke epoch (D-05): producer dropped →
    // disable the branch, never busy-loop.
    let mut revoke_alive = true;
    // Same discipline for the blocked epoch (SRV-05): producer dropped →
    // disable the branch, never busy-loop.
    let mut blocked_alive = true;
    // Same discipline for the tabs watch (BROW-01): producer dropped (e.g.
    // the ext listener failed to bind) → disable the branch, never busy-loop.
    let mut tabs_alive = true;
    // Same discipline for the bookmarks watch (protoVersion 1.6): producer
    // dropped (e.g. the ext listener failed to bind) → disable the branch,
    // never busy-loop.
    let mut bookmarks_alive = true;
    // Same discipline for the update-progress watch (protoVersion 1.8):
    // producer dropped (e.g. the update thread exited) → disable the branch,
    // never busy-loop.
    let mut update_alive = true;
    // The phone's `hello.device` name, captured when Hello is processed so
    // the pin (pairing) path can record it via `complete_pairing_named`
    // (D-04/A7). `None` until Hello arrives.
    let mut hello_device: Option<String> = None;
    // Which stored hash authed THIS session (set at the pin-Ok / auth-Ok
    // transition) — the revoke branch (D-05) checks this hash for continued
    // membership in `AuthManager::paired_hashes()`.
    let mut authed_hash: Option<[u8; 32]> = None;
    // Whether this session has already incremented `conn_count` — set at
    // the Authed transition, guards the CONN-07 cleanup's decrement so a
    // session that never authed cannot under/over-count (SRV-01).
    let mut counted = false;
    // Last time ANY inbound bytes arrived from the peer; drives the
    // liveness deadline branch below.
    let mut last_inbound = Instant::now();

    'read: loop {
        tokio::select! {
            // Liveness deadline (04-UAT Test 5): no inbound frames for the
            // deadline means the peer is gone (half-open TCP after an
            // abrupt WiFi kill never yields None/Err from stream.next()).
            // Breaking 'read lands on the EXISTING straight-line CONN-07
            // cleanup below the loop — no new cleanup code, that is the
            // entire point of the straight-line structure. Constructing the
            // sleep_until future fresh each iteration is correct: select!
            // re-creates non-pinned futures per pass, and the loop rate is
            // bounded by the inbound frame rate. The deadline scales by
            // auth state (review CR-01): pre-auth silence is the normal
            // pairing shape (the user typing the PIN, no client pings yet),
            // so only Authed sessions get the tight 10s held-input contract.
            () = sleep_until(last_inbound + if ctx.auth_state == AuthState::Authed {
                LIVENESS_TIMEOUT
            } else {
                PRE_AUTH_LIVENESS_TIMEOUT
            }) => break 'read,
            changed = pause.changed(), if pause_alive => {
                match changed {
                    Ok(()) => {
                        // Pause activation IMMEDIATELY releases held input
                        // (SPEC §11, RESEARCH pitfall 12).
                        if *pause.borrow() {
                            ctx.held.release_all(&*executors.mouse_keys);
                        }
                    }
                    Err(_) => pause_alive = false,
                }
            }
            // MED-02 live push (D-03), authed-gated: the volume watch fires
            // for EVERY session, but only Authed ones may see host state —
            // the guard is what stands between host state and an unauthed
            // socket (threat T-05-05 / RESEARCH Pitfall 8). watch is
            // latest-value-only (no backlog to flood, T-05-06); frames ride
            // the same bounded write queue as replies.
            changed = volume.changed(), if volume_alive && ctx.auth_state == AuthState::Authed => {
                match changed {
                    Ok(()) => {
                        // borrow_and_update clears the changed flag so this
                        // branch and the after-auth snapshot below never
                        // double-fire on the same state.
                        let state = *volume.borrow_and_update();
                        // WR-08: try_send, NEVER a blocking await inside a
                        // select! arm. A blocked send stalls the whole session
                        // task — the liveness deadline branch included — so an
                        // alive-but-not-reading client (frozen app, full TCP
                        // window) could hold input past the CONN-07 10s
                        // contract. A full queue safely drops this push: watch
                        // is latest-value-only, so the next change re-delivers
                        // current state. Receiver gone → write task exited →
                        // session over.
                        match tx.try_send(vol_changed_frame(state)) {
                            Ok(()) => {}
                            Err(mpsc::error::TrySendError::Full(_)) => {}
                            Err(mpsc::error::TrySendError::Closed(_)) => break 'read,
                        }
                    }
                    Err(_) => volume_alive = false,
                }
            }
            // APPS-03 live push, authed-gated: identical privacy backstop to
            // the volume branch (threat T-06-01 / RESEARCH Pitfall 8) — the
            // window list must never cross to an unauthed socket. watch is
            // latest-value-only (no backlog flood). Unlike volume there is NO
            // after-auth snapshot: the client pulls the current list via
            // `apps.list` on the Apps screen, so this branch is the ONLY apps
            // push site.
            changed = apps.changed(), if apps_alive && ctx.auth_state == AuthState::Authed => {
                match changed {
                    Ok(()) => {
                        // Vec<WindowInfo> is not Copy: clone the borrowed
                        // snapshot. borrow_and_update clears the changed flag.
                        let windows = apps.borrow_and_update().clone();
                        // WR-08: non-blocking try_send (see the vol branch) —
                        // drop on a full queue, the latest-value re-delivers.
                        match tx.try_send(apps_changed_frame(windows)) {
                            Ok(()) => {}
                            Err(mpsc::error::TrySendError::Full(_)) => {}
                            Err(mpsc::error::TrySendError::Closed(_)) => break 'read,
                        }
                    }
                    Err(_) => apps_alive = false,
                }
            }
            // CLIP-03 live push, authed-gated: identical privacy backstop to
            // the volume/apps branches (threat T-06-05 / RESEARCH Pitfall 8) —
            // the PC clipboard must never cross to an unauthed socket. watch is
            // latest-value-only (no backlog flood). Like apps — and UNLIKE
            // volume — there is NO after-auth snapshot: dumping the PC
            // clipboard to a connecting phone is a privacy leak (Pitfall 8), so
            // this branch is the ONLY clip push site. The client pulls the
            // current value via `clip.get`. The producer already skips
            // sensitive/oversized/echo clips before they reach this watch.
            changed = clip.changed(), if clip_alive && ctx.auth_state == AuthState::Authed => {
                match changed {
                    Ok(()) => {
                        // ClipState owns a String (not Copy): clone the
                        // borrowed snapshot. borrow_and_update clears the flag.
                        let text = clip.borrow_and_update().text.clone();
                        // WR-08: non-blocking try_send (see the vol branch) —
                        // drop on a full queue, the latest-value re-delivers.
                        match tx.try_send(clip_changed_frame(text)) {
                            Ok(()) => {}
                            Err(mpsc::error::TrySendError::Full(_)) => {}
                            Err(mpsc::error::TrySendError::Closed(_)) => break 'read,
                        }
                    }
                    Err(_) => clip_alive = false,
                }
            }
            // D-05 revoke: force-disconnect a LIVE authed session whose hash
            // was just removed from AuthManager.paired. This is a SIBLING
            // arm (not authed-gated) because a pre-auth session has no
            // authed_hash yet — the `if let Some(h) = authed_hash` guard
            // below is what actually filters. A revoked hash lands on the
            // EXISTING straight-line CONN-07 cleanup: no new teardown code.
            changed = revoke.changed(), if revoke_alive => {
                match changed {
                    Ok(()) => {
                        let _ = revoke.borrow_and_update();
                        if let Some(h) = authed_hash {
                            let still_paired = auth
                                .lock()
                                .expect("auth mutex poisoned")
                                .paired_hashes()
                                .contains(&h);
                            if !still_paired {
                                break 'read;
                            }
                        }
                    }
                    Err(_) => revoke_alive = false,
                }
            }
            // SRV-05 input.blocked live push, authed-gated: identical
            // privacy backstop to the volume/apps/clip branches (T-07-14 /
            // RESEARCH Pitfall 8) — a UIPI-elevated-foreground transition
            // must never cross to an unauthed socket. Unlike volume there is
            // NO after-auth snapshot (mirrors apps/clip) — this is a
            // transition event, not a state prime.
            changed = blocked.changed(), if blocked_alive && ctx.auth_state == AuthState::Authed => {
                match changed {
                    Ok(()) => {
                        let _ = blocked.borrow_and_update();
                        // WR-08: non-blocking try_send (see the vol branch) —
                        // a dropped elevated notice re-fires on the next epoch
                        // advance; blocking here would stall the liveness arm.
                        match tx.try_send(input_blocked_frame("elevated")) {
                            Ok(()) => {}
                            Err(mpsc::error::TrySendError::Full(_)) => {}
                            Err(mpsc::error::TrySendError::Closed(_)) => break 'read,
                        }
                    }
                    Err(_) => blocked_alive = false,
                }
            }
            // BROW-01 tabs.changed live push, authed-gated: byte-discipline
            // clone of the apps.changed branch (threat T-TABS-02 / T-06-01 —
            // tab titles are browsing data and must never cross to an
            // unauthed socket). watch is latest-value-only (no backlog
            // flood). Like apps there is NO after-auth snapshot: the client
            // pulls the current state via `tabs.list` on the Browser screen,
            // so this branch is the ONLY tabs push site.
            changed = tabs.changed(), if tabs_alive && ctx.auth_state == AuthState::Authed => {
                match changed {
                    Ok(()) => {
                        // TabsState owns a Vec (not Copy): clone the borrowed
                        // snapshot. borrow_and_update clears the changed flag.
                        let state = tabs.borrow_and_update().clone();
                        // WR-08: non-blocking try_send (see the vol branch) —
                        // drop on a full queue, the latest-value re-delivers.
                        match tx.try_send(tabs_changed_frame(state)) {
                            Ok(()) => {}
                            Err(mpsc::error::TrySendError::Full(_)) => {}
                            Err(mpsc::error::TrySendError::Closed(_)) => break 'read,
                        }
                    }
                    Err(_) => tabs_alive = false,
                }
            }
            // Phase-11 bm.changed live push, authed-gated: byte-discipline
            // clone of the tabs.changed branch (threat T-11-01 / T-06-01 —
            // bookmark titles are browsing data and must never cross to an
            // unauthed socket; the `== AuthState::Authed` guard is THE
            // privacy backstop, removing it leaks the owner's bookmark
            // titles). watch is latest-value-only (no backlog flood). Like
            // tabs there is NO after-auth snapshot: the phone pulls the
            // current state via `bm.list` on first Bookmarks-segment display
            // (D-03 lazy prime), so this branch is the ONLY bookmarks push
            // site.
            changed = bookmarks.changed(), if bookmarks_alive && ctx.auth_state == AuthState::Authed => {
                match changed {
                    Ok(()) => {
                        // BookmarksState owns a Vec (not Copy): clone the
                        // borrowed snapshot. borrow_and_update clears the
                        // changed flag.
                        let state = bookmarks.borrow_and_update().clone();
                        // WR-08: non-blocking try_send (see the vol branch) —
                        // drop on a full queue, the latest-value re-delivers.
                        match tx.try_send(bm_changed_frame(state)) {
                            Ok(()) => {}
                            Err(mpsc::error::TrySendError::Full(_)) => {}
                            Err(mpsc::error::TrySendError::Closed(_)) => break 'read,
                        }
                    }
                    Err(_) => bookmarks_alive = false,
                }
            }
            // Phase-12 update.progress live push, authed-gated: byte-discipline
            // clone of the bm.changed branch (threat T-12-42 — progress names
            // the versions running on the owner's machine and must never cross
            // to an unauthed socket; the `== AuthState::Authed` guard is THE
            // gate). watch is latest-value-only, and coalescing is exactly
            // right for a percentage: a dropped tick re-delivers as a NEWER
            // one. Like bookmarks there is NO after-auth snapshot — progress
            // is a transition event, not a state prime (see ServerDeps).
            changed = update.changed(), if update_alive && ctx.auth_state == AuthState::Authed => {
                match changed {
                    Ok(()) => {
                        // UpdateProgress owns Strings (not Copy): clone the
                        // borrowed snapshot. borrow_and_update clears the
                        // changed flag.
                        let progress = update.borrow_and_update().clone();
                        // The EMPTY-stage sentinel NEVER reaches the wire
                        // (T-12-46): it is the watch's initial value, and the
                        // D-10 vocabulary has no idle stage — publishing it
                        // would put an out-of-vocabulary `stage` on a wire
                        // whose only defined values are checking/downloading/
                        // verifying/installing/restarting/uptodate/failed.
                        // The flag is still cleared above, so the branch does
                        // not re-fire.
                        if !progress.stage.is_empty() {
                            // WR-08: non-blocking try_send (see the vol
                            // branch) — drop on a full queue, the
                            // latest-value re-delivers (T-12-47).
                            match tx.try_send(update_progress_frame(progress)) {
                                Ok(()) => {}
                                Err(mpsc::error::TrySendError::Full(_)) => {}
                                Err(mpsc::error::TrySendError::Closed(_)) => break 'read,
                            }
                        }
                    }
                    Err(_) => update_alive = false,
                }
            }
            incoming = stream.next() => {
                let msg = match incoming {
                    // Clean close: the client finished the WS close
                    // handshake (or dropped the socket).
                    None => break 'read,
                    // Protocol/socket error — including a frame exceeding
                    // the 64 KB caps (SPEC §13): terminate the session.
                    Some(Err(_)) => break 'read,
                    Some(Ok(m)) => m,
                };
                // ANY inbound bytes prove the peer is alive — refreshed
                // BEFORE the frame-type match so Text, Binary, and WS
                // control frames (Ping/Pong in the `_` arm) all count.
                // The pause branch above deliberately does NOT refresh:
                // a server-side pause toggle says nothing about the
                // phone's reachability.
                last_inbound = Instant::now();
                match msg {
                    Message::Text(text) => {
                        // Captured BEFORE handle_text so the D-03 snapshot
                        // below fires exactly at the two Authed transitions
                        // (pairOk and authOk) — never on later frames.
                        let was_authed = ctx.auth_state == AuthState::Authed;
                        let (replies, close_after, newly_authed_hash) = handle_text(
                            text.as_str(),
                            &mut ctx,
                            &mut session_nonce,
                            &mut hello_device,
                            peer_ip,
                            &executors,
                            &auth,
                            &pause,
                        );
                        for reply in replies {
                            let frame = Message::text(json::encode_msg(&reply, None));
                            // WR-08: non-blocking send. A reply cannot be
                            // dropped without corrupting protocol state, so a
                            // full queue (client stopped reading) is treated as
                            // a dead session — fall through to the CONN-07
                            // cleanup, keeping the liveness guarantee reachable.
                            if tx.try_send(frame).is_err() {
                                break 'read; // queue full (not reading) or gone
                            }
                        }
                        if close_after {
                            // versionMismatch (D-06): err queued above is
                            // written first (mpsc preserves order), then the
                            // close frame, then the session ends.
                            let _ = tx.try_send(Message::Close(None));
                            break 'read;
                        }
                        // D-03 "right after auth": exactly one vol.changed
                        // snapshot, queued AFTER the pairOk/authOk reply
                        // (mpsc preserves order). borrow_and_update here AND
                        // in the branch above prevents an immediate
                        // duplicate branch-fire on a pre-auth state change.
                        // The SAME transition is where conn_count (SRV-01)
                        // and authed_hash (D-05) are recorded — both are
                        // exactly-once-per-session facts tied to this guard.
                        if !was_authed && ctx.auth_state == AuthState::Authed {
                            authed_hash = newly_authed_hash;
                            if !counted {
                                conn_count.send_modify(|n| *n += 1);
                                counted = true;
                            }
                            let state = *volume.borrow_and_update();
                            // WR-08: non-blocking; a full queue here means the
                            // client isn't reading — treat as a dead session.
                            if tx.try_send(vol_changed_frame(state)).is_err() {
                                break 'read;
                            }
                        }
                    }
                    Message::Binary(bytes) => {
                        // Pre-auth binary frames are silently dropped
                        // BEFORE decode (SPEC §6 — no probing oracle).
                        if ctx.auth_state == AuthState::Authed {
                            match binary::decode(bytes.as_ref()) {
                                Ok(frame) => router::route_binary(
                                    frame,
                                    &ctx,
                                    &executors,
                                    *pause.borrow(),
                                ),
                                // Dropped and counted, never fatal (SPEC §9).
                                Err(_) => binary_decode_errors += 1,
                            }
                        }
                    }
                    // WS control frames: tungstenite answers Ping itself and
                    // acknowledges Close internally (next() then yields
                    // None). Nothing to do here — protocol-level `ping` is a
                    // JSON text message, not a WS control frame.
                    _ => {}
                }
            }
        }
    }

    // ── CONN-07: UNSKIPPABLE cleanup ────────────────────────────────────
    // Straight-line code after the read loop — reached on clean close,
    // socket error, oversize-frame error, and version-reject alike. No
    // phantom held input survives this session. (release_all is drain-based
    // and idempotent: if the pause branch already released, this is a no-op.)
    ctx.held.release_all(&*executors.mouse_keys);

    // SRV-01: undo this session's conn_count increment (if any) exactly
    // once. counted guards the case where the session never reached Authed.
    if counted {
        conn_count.send_modify(|n| *n = n.saturating_sub(1));
    }

    // Closing the channel lets the write task drain anything still queued
    // (e.g. the versionMismatch err + close frames), then exit.
    drop(tx);
    let _ = write_task.await;
    let _ = binary_decode_errors; // surfaced via tracing in Phase 2
}

/// Handle one decoded-or-not text frame through the handshake FSM.
///
/// Returns the replies to queue, whether the session must close after
/// sending them (true only for the D-06 version reject), and — ONLY on a
/// pin-Ok or auth-Ok transition to Authed — the stored hash that authed this
/// session (D-05 revoke-branch correlation; `None` otherwise).
fn handle_text(
    text: &str,
    ctx: &mut SessionCtx,
    session_nonce: &mut Option<[u8; 32]>,
    hello_device: &mut Option<String>,
    peer_ip: IpAddr,
    executors: &Executors,
    auth: &Mutex<AuthManager>,
    pause: &watch::Receiver<bool>,
) -> (Vec<Msg>, bool, Option<[u8; 32]>) {
    let decoded = match json::decode_text(text) {
        Ok(decoded) => decoded,
        Err(e) => {
            // Pre-auth: silent drop (SPEC §6 — no probing oracle for
            // unauthenticated peers, malformed frames included).
            if ctx.auth_state != AuthState::Authed {
                return (Vec::new(), false, None);
            }
            // Post-auth decode error: the SPEC §7 err table defines no
            // decode-failure code ("badMessage" does not exist), so by
            // documented choice this replies with the closest existing
            // code — `internal` ("server-side failure executing a
            // request") — and KEEPS the connection. A malformed frame is
            // thus visible to an authed client without inventing an
            // off-spec code.
            return (
                vec![Msg::Err(ErrPayload {
                    code: "internal".to_string(),
                    msg: format!("failed to decode message: {e}"),
                    server_version: None,
                    client_version: None,
                })],
                false,
                None,
            );
        }
    };

    match ctx.auth_state {
        // ── AwaitingHello: ONLY hello is processed (SPEC §3, §6) ────────
        AuthState::AwaitingHello => match decoded.msg {
            Msg::Hello(p) => {
                let major = p
                    .proto_version
                    .split('.')
                    .next()
                    .and_then(|m| m.parse::<u64>().ok());
                if major == Some(SERVER_PROTO_MAJOR) {
                    // Captured for the pin (pairing) path below: the phone's
                    // display name for the paired-device record (D-04/A7).
                    *hello_device = Some(p.device.clone());
                    // Minor mismatch is accepted (SPEC §2).
                    let nonce = auth.lock().expect("auth mutex poisoned").issue_challenge();
                    *session_nonce = Some(nonce);
                    ctx.auth_state = AuthState::AwaitingAuth;
                    (
                        vec![Msg::Challenge(ChallengePayload { nonce: hex::encode(nonce) })],
                        false,
                        None,
                    )
                } else {
                    // D-06: major mismatch (or unparseable version) → err
                    // carrying BOTH versions, then close.
                    (
                        vec![Msg::Err(ErrPayload {
                            code: "versionMismatch".to_string(),
                            msg: format!(
                                "server speaks protoVersion {SERVER_PROTO_VERSION}; \
                                 client sent {}",
                                p.proto_version
                            ),
                            server_version: Some(SERVER_PROTO_VERSION.to_string()),
                            client_version: Some(p.proto_version),
                        })],
                        true,
                        None,
                    )
                }
            }
            // Everything else pre-hello — including protocol `ping` — is
            // silently dropped (SPEC §6).
            _ => (Vec::new(), false, None),
        },

        // ── AwaitingAuth: ONLY pin / auth are processed (SPEC §3) ───────
        AuthState::AwaitingAuth => match decoded.msg {
            Msg::Pin(p) => {
                let outcome = auth
                    .lock()
                    .expect("auth mutex poisoned")
                    .verify_pin(&p.pin, peer_ip);
                match outcome {
                    PinOutcome::Ok => {
                        let name = hello_device.clone().unwrap_or_else(|| "phone".to_owned());
                        let result = auth
                            .lock()
                            .expect("auth mutex poisoned")
                            .complete_pairing_named(name);
                        ctx.auth_state = AuthState::Authed;
                        (
                            vec![Msg::PairOk(PairOkPayload { token: result.token_hex })],
                            false,
                            Some(result.hash),
                        )
                    }
                    PinOutcome::WrongPin { attempts_remaining } => {
                        (vec![auth_fail("pinInvalid", Some(attempts_remaining), None)], false, None)
                    }
                    PinOutcome::Expired => (vec![auth_fail("pinExpired", None, None)], false, None),
                    PinOutcome::LockedOut { retry_after_secs } => (
                        vec![auth_fail("lockedOut", None, Some(retry_after_secs))],
                        false,
                        None,
                    ),
                    PinOutcome::NoPairing => {
                        (vec![auth_fail("noPairing", None, None)], false, None)
                    }
                }
            }
            Msg::Auth(p) => {
                // The mac must be bound to THIS connection's nonce; a
                // session that never got a challenge verifies nothing.
                // verify_auth_hash (not the plain bool verify_auth) so the
                // session can record WHICH stored hash authed it — the
                // revoke branch (D-05) needs this for its membership check.
                let verified_hash = session_nonce.and_then(|nonce| {
                    auth.lock()
                        .expect("auth mutex poisoned")
                        .verify_auth_hash(&nonce, &p.mac)
                });
                if let Some(hash) = verified_hash {
                    ctx.auth_state = AuthState::Authed;
                    (vec![Msg::AuthOk(AuthOkPayload {})], false, Some(hash))
                } else {
                    (vec![auth_fail("badMac", None, None)], false, None)
                }
            }
            // Everything else pre-auth is silently dropped (SPEC §6).
            _ => (Vec::new(), false, None),
        },

        // ── Authed: full registry via the dispatch gates ────────────────
        AuthState::Authed => match &decoded.msg {
            // Handshake replays post-auth are ignored: the FSM owns these
            // types and they must never reach route() (its debug_assert).
            Msg::Hello(_) | Msg::Pin(_) | Msg::Auth(_) => (Vec::new(), false, None),
            _ => (
                router::route(decoded, ctx, executors, auth, *pause.borrow()),
                false,
                None,
            ),
        },
    }
}

/// Encode one `vol.changed` push frame (S→C, protoVersion 1.1) from the
/// core-owned [`VolumeState`] — used by both the live watch branch and the
/// D-03 after-auth snapshot so the wire shape can never diverge.
fn vol_changed_frame(state: VolumeState) -> Message {
    Message::text(json::encode_msg(
        &Msg::VolChanged(VolChangedPayload {
            value: u64::from(state.value),
            muted: state.muted,
        }),
        None,
    ))
}

/// Encode one `apps.changed` push frame (S→C, protoVersion 1.2, APPS-03)
/// from the core-owned window list. The sole apps-push encoder — no
/// after-auth snapshot analog (the client pulls via `apps.list`).
fn apps_changed_frame(windows: Vec<WindowInfo>) -> Message {
    Message::text(json::encode_msg(
        &Msg::AppsChanged(AppsChangedPayload { windows }),
        None,
    ))
}

/// Encode one `clip.changed` push frame (S→C, protoVersion 1.2, CLIP-03)
/// from the core-owned clipboard text. The sole clip-push encoder — no
/// after-auth snapshot analog (the client pulls via `clip.get`; dumping the
/// clipboard at auth would be a privacy leak, RESEARCH Pitfall 8).
fn clip_changed_frame(text: String) -> Message {
    Message::text(json::encode_msg(
        &Msg::ClipChanged(ClipChangedPayload { text }),
        None,
    ))
}

/// Encode one `input.blocked` push frame (S→C, protoVersion 1.3, SRV-05)
/// carrying a fixed-vocabulary `reason` (e.g. `"elevated"`) — NEVER a window
/// title/exe path/PII (T-07-05). The sole input.blocked encoder — no
/// after-auth snapshot analog (mirrors apps/clip: a transition event, not a
/// state prime).
fn input_blocked_frame(reason: &str) -> Message {
    Message::text(json::encode_msg(
        &Msg::InputBlocked(InputBlockedPayload { reason: reason.to_owned() }),
        None,
    ))
}

/// Encode one `tabs.changed` push frame (S→C, protoVersion 1.4, BROW-01)
/// from the core-owned tab-relay state. The sole tabs-push encoder — no
/// after-auth snapshot analog (the client pulls via `tabs.list`). Privacy
/// backstop (T-06-01 style): this frame only ever leaves through the
/// authed-gated select! branch above, and tab titles never touch a log sink
/// (T-01-31).
fn tabs_changed_frame(state: TabsState) -> Message {
    Message::text(json::encode_msg(
        &Msg::TabsChanged(TabsChangedPayload {
            connected: state.connected,
            tabs: state.tabs,
            // The 1.5 server ALWAYS emits groups in its pushes (empty when
            // none); 1.4 clients ignore the unknown key per D-05.
            groups: Some(state.groups),
        }),
        None,
    ))
}

/// Encode one `bm.changed` push frame (S→C, protoVersion 1.6, phase 11)
/// from the core-owned bookmark-relay state. The sole bookmarks-push
/// encoder — no after-auth snapshot analog (the phone pulls via `bm.list`
/// on first Bookmarks-segment display, D-03). Privacy backstop (T-11-01 /
/// T-11-02): this frame only ever leaves through the authed-gated select!
/// branch above, and bookmark node titles never touch a log sink (T-01-31,
/// SPEC §12 redaction-mandatory list).
fn bm_changed_frame(state: BookmarksState) -> Message {
    Message::text(json::encode_msg(
        &Msg::BmChanged(BmChangedPayload {
            connected: state.connected,
            nodes: state.nodes,
            // The 1.6 server ALWAYS emits `truncated` in its pushes (the
            // "1.5 server always emits groups" posture); older clients drop
            // the unknown key per SPEC §1.
            truncated: Some(state.truncated),
        }),
        None,
    ))
}

/// Build the `update.progress` push frame (protoVersion 1.8, phase 12,
/// D-10/D-11).
///
/// There is NO after-auth snapshot for this family — progress is a transition
/// event, and the empty-stage sentinel is filtered by the caller, so this
/// function is only ever reached with a stage drawn from the D-10 vocabulary.
/// Privacy backstop (T-12-42): the frame only ever leaves through the
/// authed-gated select! branch above. `error` is the closed D-11 vocabulary —
/// never a path, never a URL, never an HTTP status (SPEC §12).
fn update_progress_frame(progress: UpdateProgress) -> Message {
    Message::text(json::encode_msg(
        &Msg::UpdateProgress(UpdateProgressPayload {
            stage: progress.stage,
            pct: progress.pct,
            version: progress.version,
            error: progress.error,
        }),
        None,
    ))
}

/// Build an `authFail` reply with the SPEC §5 reason string and its
/// reason-specific extras.
fn auth_fail(
    reason: &str,
    attempts_remaining: Option<u32>,
    retry_after_secs: Option<u64>,
) -> Msg {
    Msg::AuthFail(AuthFailPayload {
        reason: reason.to_string(),
        attempts_remaining,
        retry_after_secs,
    })
}
