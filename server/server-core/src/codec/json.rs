//! JSON text-frame codec: envelope `{t, seq?, p?}` + per-family payloads
//! (SPEC §1, §7).
//!
//! Strictness (D-05): unknown fields anywhere — top level or inside `p` —
//! are IGNORED on decode (serde's default; the strict-unknown-fields serde
//! attribute is forbidden in this crate — D-05). Missing REQUIRED fields
//! are hard decode errors
//! ([`CodecError::MissingField`]). The canonical decoded form contains ONLY
//! spec-defined fields: `encode_msg(decode_text(wire))`, parsed as JSON,
//! equals the fixture `expect` envelope (field order insignificant).
//!
//! Enum-valued wire fields (`button`, `action`, `reason`, …) decode as plain
//! `String`s: the codec is value-lenient by design — semantic validation
//! (unknown action, version rejection per D-06) is the router/server's job,
//! not the codec's.

use serde::{Deserialize, Serialize};

use crate::error::CodecError;
use crate::executors::WindowInfo;

/// A decoded JSON text frame: the envelope's `seq` plus the typed message.
#[derive(Debug, Clone, PartialEq)]
pub struct Decoded {
    /// Client-assigned sequence number. Opaque to the server (SPEC §1).
    pub seq: Option<u64>,
    /// The typed message with its payload.
    pub msg: Msg,
}

/// `hello` payload (C→S, SPEC §3 step 1).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct HelloPayload {
    #[serde(rename = "protoVersion")]
    pub proto_version: String,
    pub device: String,
}

/// `pin` payload (C→S, SPEC §3 step 2a). Always a 6-digit zero-padded STRING.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PinPayload {
    pub pin: String,
}

/// `pairOk` payload (S→C): the raw token, 64 lowercase hex (SPEC §3a, §12).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PairOkPayload {
    pub token: String,
}

/// `challenge` payload (S→C): fresh per-connection nonce, 64 lowercase hex.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ChallengePayload {
    pub nonce: String,
}

/// `auth` payload (C→S): HMAC proof, 64 lowercase hex (SPEC §4).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct AuthPayload {
    pub mac: String,
}

/// `authOk` payload (S→C): empty (SPEC §3b).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct AuthOkPayload {}

/// `authFail` payload (S→C): reason enum string + reason-specific extras
/// (SPEC §5).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct AuthFailPayload {
    pub reason: String,
    #[serde(
        rename = "attemptsRemaining",
        default,
        skip_serializing_if = "Option::is_none"
    )]
    pub attempts_remaining: Option<u32>,
    #[serde(
        rename = "retryAfterSecs",
        default,
        skip_serializing_if = "Option::is_none"
    )]
    pub retry_after_secs: Option<u64>,
}

/// `click` payload (C→S): `button` is `"left" | "middle" | "right"`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ClickPayload {
    pub button: String,
}

/// `drag` payload (C→S): `action` is `"start" | "end"` (SPEC §7).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct DragPayload {
    pub action: String,
    pub button: String,
}

/// `key` payload (C→S): `action` is `"tap" | "down" | "up"`; `mods` defaults
/// to `[]` (SPEC §7).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct KeyPayload {
    pub code: String,
    pub action: String,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub mods: Vec<String>,
}

/// `text` payload (C→S): diff-ops — delete `bs` graphemes at end, insert
/// `ins` (SPEC §8).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct TextPayload {
    pub bs: u64,
    pub ins: String,
}

/// `media` payload (C→S): `value` required iff `action == "setvol"` —
/// enforced by the router, not the codec.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct MediaPayload {
    pub action: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub value: Option<u8>,
}

/// `power` payload (C→S): `"lock" | "sleep" | "restart" | "shutdown"`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PowerPayload {
    pub action: String,
}

/// `confirm` payload (C→S): must match a pending `power` action within 10s.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ConfirmPayload {
    pub action: String,
}

/// `apps.list` payload: request is `{}` (windows absent); reply carries
/// `windows` (SPEC §7).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct AppsListPayload {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub windows: Option<Vec<WindowInfo>>,
}

/// `apps.launch` payload (C→S).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct AppsLaunchPayload {
    pub path: String,
}

/// `apps.focus` payload (C→S).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct AppsFocusPayload {
    pub id: u64,
}

/// `apps.close` payload (C→S).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct AppsClosePayload {
    pub id: u64,
}

/// `apps.changed` payload (S→C push).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct AppsChangedPayload {
    pub windows: Vec<WindowInfo>,
}

/// `clip.set` payload (C↔S).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ClipSetPayload {
    pub text: String,
}

/// `clip.get` payload (C→S): empty; server replies with `clip.set`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ClipGetPayload {}

/// `clip.changed` payload (S→C push).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ClipChangedPayload {
    pub text: String,
}

/// `browser` payload (C→S): key-macro actions (SPEC §7).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct BrowserPayload {
    pub action: String,
}

/// `present` payload (C→S): presenter-remote actions (SPEC §7).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PresentPayload {
    pub action: String,
}

/// `ping` payload (C→S): latency probe timestamp.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PingPayload {
    pub ts: u64,
}

/// `pong` payload (S→C): echoes the `ping` timestamp.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PongPayload {
    pub ts: u64,
}

/// `err` payload (S→C): `code` + human-readable `msg` + code-specific extras
/// (SPEC §7 err-code table).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ErrPayload {
    pub code: String,
    pub msg: String,
    #[serde(
        rename = "serverVersion",
        default,
        skip_serializing_if = "Option::is_none"
    )]
    pub server_version: Option<String>,
    #[serde(
        rename = "clientVersion",
        default,
        skip_serializing_if = "Option::is_none"
    )]
    pub client_version: Option<String>,
}

/// Every message type in the protoVersion 1.0 registry (SPEC §7), plus
/// `Unknown` for unregistered `t` values (D-07: unknown types are decoded,
/// not decode errors — the router replies `err{unknownType}` post-auth and
/// drops silently pre-auth).
#[derive(Debug, Clone, PartialEq)]
pub enum Msg {
    Hello(HelloPayload),
    Pin(PinPayload),
    PairOk(PairOkPayload),
    Challenge(ChallengePayload),
    Auth(AuthPayload),
    AuthOk(AuthOkPayload),
    AuthFail(AuthFailPayload),
    Click(ClickPayload),
    Drag(DragPayload),
    Key(KeyPayload),
    Text(TextPayload),
    Media(MediaPayload),
    Power(PowerPayload),
    Confirm(ConfirmPayload),
    AppsList(AppsListPayload),
    AppsLaunch(AppsLaunchPayload),
    AppsFocus(AppsFocusPayload),
    AppsClose(AppsClosePayload),
    AppsChanged(AppsChangedPayload),
    ClipSet(ClipSetPayload),
    ClipGet(ClipGetPayload),
    ClipChanged(ClipChangedPayload),
    Browser(BrowserPayload),
    Present(PresentPayload),
    Ping(PingPayload),
    Pong(PongPayload),
    Err(ErrPayload),
    /// Unregistered message type: carries the offending `t` (D-07).
    Unknown { t: String },
}

/// Decode a JSON text frame via the two-step envelope parse (envelope
/// `{t, seq?, p?}` first, then the family payload from `p`).
///
/// Absent `p` is equivalent to `{}`. Unknown fields are ignored (D-05).
/// Missing required payload fields are [`CodecError::MissingField`].
/// Unknown `t` decodes to [`Msg::Unknown`] — never an error (D-07).
pub fn decode_text(s: &str) -> Result<Decoded, CodecError> {
    todo!("implemented in plan 01-03 (codec wave)")
}

/// Encode a message to its canonical wire form `{t, seq?, p}`.
///
/// The output contains ONLY spec-defined fields; `seq` is emitted only when
/// `Some`. Parsed as JSON, `encode_msg(&d.msg, d.seq)` must equal the
/// fixture `expect` envelope (order-insensitive).
pub fn encode_msg(msg: &Msg, seq: Option<u64>) -> String {
    todo!("implemented in plan 01-03 (codec wave)")
}
