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

use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::error::CodecError;
use crate::executors::WindowInfo;

/// The wire envelope `{t, seq?, p?}` (SPEC §1) — step 1 of the two-step
/// parse (RESEARCH Pattern 3). Private: callers only see [`Decoded`].
#[derive(Deserialize)]
struct Envelope {
    t: String,
    #[serde(default)]
    seq: Option<u64>,
    /// Absent `p` deserializes to `Value::Null` and is treated as `{}`.
    #[serde(default)]
    p: Value,
}

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

/// `vol.changed` payload (S→C push, protoVersion 1.1, D-03): server volume
/// state. BOTH fields required — a missing field is a hard decode error
/// (fixture 03), unlike `media.value` which is conditionally required.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct VolChangedPayload {
    pub value: u64,
    pub muted: bool,
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
    VolChanged(VolChangedPayload),
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
    let env: Envelope =
        serde_json::from_str(s).map_err(|e| CodecError::BadJson(e.to_string()))?;

    // Absent `p` is equivalent to `{}` (SPEC §1).
    let p = if env.p.is_null() {
        Value::Object(serde_json::Map::new())
    } else {
        env.p
    };

    let msg = match env.t.as_str() {
        "hello" => Msg::Hello(payload(p)?),
        "pin" => Msg::Pin(payload(p)?),
        "pairOk" => Msg::PairOk(payload(p)?),
        "challenge" => Msg::Challenge(payload(p)?),
        "auth" => Msg::Auth(payload(p)?),
        "authOk" => Msg::AuthOk(payload(p)?),
        "authFail" => Msg::AuthFail(payload(p)?),
        "click" => Msg::Click(payload(p)?),
        "drag" => Msg::Drag(payload(p)?),
        "key" => Msg::Key(payload(p)?),
        "text" => Msg::Text(payload(p)?),
        "media" => Msg::Media(payload(p)?),
        "vol.changed" => Msg::VolChanged(payload(p)?),
        "power" => Msg::Power(payload(p)?),
        "confirm" => Msg::Confirm(payload(p)?),
        "apps.list" => Msg::AppsList(payload(p)?),
        "apps.launch" => Msg::AppsLaunch(payload(p)?),
        "apps.focus" => Msg::AppsFocus(payload(p)?),
        "apps.close" => Msg::AppsClose(payload(p)?),
        "apps.changed" => Msg::AppsChanged(payload(p)?),
        "clip.set" => Msg::ClipSet(payload(p)?),
        "clip.get" => Msg::ClipGet(payload(p)?),
        "clip.changed" => Msg::ClipChanged(payload(p)?),
        "browser" => Msg::Browser(payload(p)?),
        "present" => Msg::Present(payload(p)?),
        "ping" => Msg::Ping(payload(p)?),
        "pong" => Msg::Pong(payload(p)?),
        "err" => Msg::Err(payload(p)?),
        // D-07: unknown `t` is a DECODED message, never a decode error —
        // the router's unknownType/silent-drop behavior depends on this.
        _ => Msg::Unknown { t: env.t },
    };

    Ok(Decoded { seq: env.seq, msg })
}

/// Step 2 of the two-step parse: convert the envelope's `p` into a typed
/// payload. serde's "missing field" errors become
/// [`CodecError::MissingField`] carrying the field name (D-05 hard error);
/// every other serde error is [`CodecError::BadJson`].
fn payload<T: DeserializeOwned>(p: Value) -> Result<T, CodecError> {
    serde_json::from_value(p).map_err(|e| {
        let s = e.to_string();
        match s
            .strip_prefix("missing field `")
            .and_then(|rest| rest.split('`').next())
        {
            Some(field) => CodecError::MissingField(field.to_string()),
            None => CodecError::BadJson(s),
        }
    })
}

/// Encode a message to its canonical wire form `{t, seq?, p}`.
///
/// The output contains ONLY spec-defined fields; `seq` is emitted only when
/// `Some`. Parsed as JSON, `encode_msg(&d.msg, d.seq)` must equal the
/// fixture `expect` envelope (order-insensitive).
pub fn encode_msg(msg: &Msg, seq: Option<u64>) -> String {
    // Serializing spec-defined payload structs cannot fail (string keys,
    // no non-serializable types) — this is not a wire-data panic path.
    fn val<T: Serialize>(p: &T) -> Value {
        serde_json::to_value(p).expect("payload struct serialization is infallible")
    }

    let (t, p): (&str, Value) = match msg {
        Msg::Hello(pl) => ("hello", val(pl)),
        Msg::Pin(pl) => ("pin", val(pl)),
        Msg::PairOk(pl) => ("pairOk", val(pl)),
        Msg::Challenge(pl) => ("challenge", val(pl)),
        Msg::Auth(pl) => ("auth", val(pl)),
        Msg::AuthOk(pl) => ("authOk", val(pl)),
        Msg::AuthFail(pl) => ("authFail", val(pl)),
        Msg::Click(pl) => ("click", val(pl)),
        Msg::Drag(pl) => ("drag", val(pl)),
        Msg::Key(pl) => ("key", val(pl)),
        Msg::Text(pl) => ("text", val(pl)),
        Msg::Media(pl) => ("media", val(pl)),
        Msg::VolChanged(pl) => ("vol.changed", val(pl)),
        Msg::Power(pl) => ("power", val(pl)),
        Msg::Confirm(pl) => ("confirm", val(pl)),
        Msg::AppsList(pl) => ("apps.list", val(pl)),
        Msg::AppsLaunch(pl) => ("apps.launch", val(pl)),
        Msg::AppsFocus(pl) => ("apps.focus", val(pl)),
        Msg::AppsClose(pl) => ("apps.close", val(pl)),
        Msg::AppsChanged(pl) => ("apps.changed", val(pl)),
        Msg::ClipSet(pl) => ("clip.set", val(pl)),
        Msg::ClipGet(pl) => ("clip.get", val(pl)),
        Msg::ClipChanged(pl) => ("clip.changed", val(pl)),
        Msg::Browser(pl) => ("browser", val(pl)),
        Msg::Present(pl) => ("present", val(pl)),
        Msg::Ping(pl) => ("ping", val(pl)),
        Msg::Pong(pl) => ("pong", val(pl)),
        Msg::Err(pl) => ("err", val(pl)),
        Msg::Unknown { t } => (t.as_str(), Value::Object(serde_json::Map::new())),
    };

    let mut envelope = serde_json::Map::new();
    envelope.insert("t".to_string(), Value::String(t.to_string()));
    if let Some(seq) = seq {
        envelope.insert("seq".to_string(), Value::from(seq));
    }
    // `p` is ALWAYS emitted (as `{}` for empty payloads): every canonical
    // fixture expect envelope carries `p` — e.g. authOk's is `"p": {}`.
    envelope.insert("p".to_string(), p);

    serde_json::to_string(&Value::Object(envelope))
        .expect("envelope serialization is infallible")
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Round-trip helper: decode(encode(msg, seq)) must reproduce both the
    /// message and the seq exactly.
    fn round_trip(msg: Msg, seq: Option<u64>) {
        let wire = encode_msg(&msg, seq);
        let decoded = decode_text(&wire)
            .unwrap_or_else(|e| panic!("round-trip decode failed for {wire}: {e}"));
        assert_eq!(decoded.msg, msg, "msg mismatch after round trip: {wire}");
        assert_eq!(decoded.seq, seq, "seq mismatch after round trip: {wire}");
    }

    #[test]
    fn round_trip_click() {
        round_trip(Msg::Click(ClickPayload { button: "left".into() }), Some(1));
    }

    #[test]
    fn round_trip_drag() {
        round_trip(
            Msg::Drag(DragPayload { action: "start".into(), button: "right".into() }),
            Some(2),
        );
    }

    #[test]
    fn round_trip_key_with_mods() {
        round_trip(
            Msg::Key(KeyPayload {
                code: "KeyC".into(),
                action: "tap".into(),
                mods: vec!["ctrl".into(), "shift".into()],
            }),
            Some(3),
        );
    }

    #[test]
    fn round_trip_key_default_mods() {
        // mods defaults to [] on decode and is omitted on encode.
        let wire = r#"{"t":"key","p":{"code":"Enter","action":"down"}}"#;
        let decoded = decode_text(wire).unwrap();
        assert_eq!(
            decoded.msg,
            Msg::Key(KeyPayload {
                code: "Enter".into(),
                action: "down".into(),
                mods: vec![],
            })
        );
        let reencoded: Value = serde_json::from_str(&encode_msg(&decoded.msg, None)).unwrap();
        assert!(reencoded["p"].get("mods").is_none(), "empty mods must be omitted");
    }

    #[test]
    fn round_trip_media_plain() {
        round_trip(
            Msg::Media(MediaPayload { action: "playpause".into(), value: None }),
            None,
        );
    }

    #[test]
    fn round_trip_media_setvol_u8_value() {
        // setvol carries an integer 0-100 value typed u8.
        round_trip(
            Msg::Media(MediaPayload { action: "setvol".into(), value: Some(100u8) }),
            Some(4),
        );
    }

    #[test]
    fn media_value_rejects_out_of_u8_range() {
        let wire = r#"{"t":"media","p":{"action":"setvol","value":300}}"#;
        assert!(matches!(decode_text(wire), Err(CodecError::BadJson(_))));
    }

    #[test]
    fn round_trip_power_and_confirm() {
        round_trip(Msg::Power(PowerPayload { action: "shutdown".into() }), Some(5));
        round_trip(Msg::Confirm(ConfirmPayload { action: "shutdown".into() }), Some(6));
    }

    #[test]
    fn round_trip_apps_list_request_and_reply() {
        // Request form: windows absent.
        round_trip(Msg::AppsList(AppsListPayload { windows: None }), Some(7));
        // Reply form: windows present.
        round_trip(
            Msg::AppsList(AppsListPayload {
                windows: Some(vec![WindowInfo { id: 1, title: "Notepad".into() }]),
            }),
            None,
        );
    }

    #[test]
    fn round_trip_apps_launch_focus_close() {
        round_trip(Msg::AppsLaunch(AppsLaunchPayload { path: "C:\\x.exe".into() }), Some(8));
        round_trip(Msg::AppsFocus(AppsFocusPayload { id: 42 }), Some(9));
        round_trip(Msg::AppsClose(AppsClosePayload { id: 42 }), Some(10));
    }

    #[test]
    fn round_trip_apps_changed() {
        round_trip(
            Msg::AppsChanged(AppsChangedPayload {
                windows: vec![
                    WindowInfo { id: 1, title: "Firefox".into() },
                    WindowInfo { id: 2, title: "Terminal".into() },
                ],
            }),
            None,
        );
    }

    #[test]
    fn round_trip_clip_family() {
        round_trip(Msg::ClipSet(ClipSetPayload { text: "copied 📋".into() }), Some(11));
        round_trip(Msg::ClipGet(ClipGetPayload {}), Some(12));
        round_trip(Msg::ClipChanged(ClipChangedPayload { text: "pushed".into() }), None);
    }

    #[test]
    fn round_trip_browser_and_present() {
        round_trip(Msg::Browser(BrowserPayload { action: "newtab".into() }), Some(13));
        round_trip(Msg::Present(PresentPayload { action: "blank".into() }), Some(14));
    }

    #[test]
    fn round_trip_ping_pong_ts_echo() {
        // ts survives the round trip exactly in both directions.
        round_trip(Msg::Ping(PingPayload { ts: 1783436504123 }), Some(15));
        round_trip(Msg::Pong(PongPayload { ts: 1783436504123 }), None);
    }

    #[test]
    fn round_trip_err_with_version_extras() {
        round_trip(
            Msg::Err(ErrPayload {
                code: "versionMismatch".into(),
                msg: "major version mismatch".into(),
                server_version: Some("1.0".into()),
                client_version: Some("2.0".into()),
            }),
            None,
        );
        // Extras omitted when None (canonical form).
        let msg = Msg::Err(ErrPayload {
            code: "internal".into(),
            msg: "boom".into(),
            server_version: None,
            client_version: None,
        });
        let wire = encode_msg(&msg, None);
        let v: Value = serde_json::from_str(&wire).unwrap();
        assert!(v["p"].get("serverVersion").is_none());
        assert!(v["p"].get("clientVersion").is_none());
        round_trip(msg, None);
    }

    #[test]
    fn round_trip_auth_fail_extras() {
        round_trip(
            Msg::AuthFail(AuthFailPayload {
                reason: "pinInvalid".into(),
                attempts_remaining: Some(3),
                retry_after_secs: None,
            }),
            None,
        );
        round_trip(
            Msg::AuthFail(AuthFailPayload {
                reason: "lockedOut".into(),
                attempts_remaining: None,
                retry_after_secs: Some(300),
            }),
            None,
        );
    }

    #[test]
    fn unknown_type_decodes_not_errors() {
        // D-07: unrecognized `t` is Ok(Msg::Unknown), never an error.
        let decoded = decode_text(r#"{"t":"gesture.swipe","seq":9,"p":{"x":1}}"#).unwrap();
        assert_eq!(decoded.msg, Msg::Unknown { t: "gesture.swipe".into() });
        assert_eq!(decoded.seq, Some(9));
    }

    #[test]
    fn seq_survives_round_trip() {
        round_trip(Msg::Ping(PingPayload { ts: 1 }), Some(u64::MAX));
        round_trip(Msg::Ping(PingPayload { ts: 1 }), None);
    }

    #[test]
    fn absent_p_is_empty_object() {
        // SPEC section 1: absent p is equivalent to {}.
        let decoded = decode_text(r#"{"t":"clip.get"}"#).unwrap();
        assert_eq!(decoded.msg, Msg::ClipGet(ClipGetPayload {}));
    }

    #[test]
    fn hello_proto_version_is_opaque_string() {
        // The codec treats protoVersion as an opaque string — major parsing
        // is the server's job (D-06, Plan 06). A "2.0" hello decodes fine.
        round_trip(
            Msg::Hello(HelloPayload { proto_version: "2.0".into(), device: "Pixel 8".into() }),
            Some(1),
        );
    }

    #[test]
    fn missing_required_field_is_hard_error() {
        let err = decode_text(r#"{"t":"click","p":{}}"#).unwrap_err();
        assert_eq!(err, CodecError::MissingField("button".to_string()));
    }

    #[test]
    fn not_json_is_bad_json() {
        assert!(matches!(decode_text("not json"), Err(CodecError::BadJson(_))));
        assert!(matches!(decode_text("[1,2,3]"), Err(CodecError::BadJson(_))));
    }
}
