/// JSON text-frame codec: envelope `{t, seq?, p?}` + per-family payloads
/// (SPEC sections 1 and 7).
///
/// Strictness (D-05): unknown fields anywhere — top level or inside `p` —
/// are IGNORED on decode (read required keys, throw [FormatException] when
/// a required key is absent, ignore the rest). Missing required fields are
/// hard decode errors. Unknown `t` decodes to [UnknownMsg] — never an
/// error (D-07).
///
/// Enum-valued wire fields (`button`, `action`, `reason`, ...) stay plain
/// [String]s: the codec is value-lenient by design — semantic validation
/// (unknown action, version rejection per D-06) is the router/server's job.
library;

/// A window entry in `apps.list` replies and `apps.changed` pushes.
class WindowInfo {
  /// Opaque window id.
  final int id;

  /// Window title.
  final String title;

  /// Creates a window entry.
  const WindowInfo({required this.id, required this.title});
}

/// Every message type in the protoVersion 1.0 registry (SPEC section 7),
/// plus [UnknownMsg] for unregistered `t` values (D-07).
sealed class RemoteMessage {
  const RemoteMessage();
}

/// `hello` (C→S): opens the handshake (SPEC section 3).
final class HelloMsg extends RemoteMessage {
  /// `"major.minor"` protocol version string.
  final String protoVersion;

  /// Client device name.
  final String device;

  /// Creates a hello message.
  const HelloMsg({required this.protoVersion, required this.device});
}

/// `pin` (C→S): pairing path. The PIN is a 6-digit zero-padded STRING.
final class PinMsg extends RemoteMessage {
  /// 6-digit zero-padded PIN string (leading zeros significant).
  final String pin;

  /// Creates a pin message.
  const PinMsg({required this.pin});
}

/// `pairOk` (S→C): the only wire appearance of the raw token (SPEC 12).
final class PairOkMsg extends RemoteMessage {
  /// Raw token, 64 lowercase hex characters.
  final String token;

  /// Creates a pairOk message.
  const PairOkMsg({required this.token});
}

/// `challenge` (S→C): fresh per-connection nonce.
final class ChallengeMsg extends RemoteMessage {
  /// Nonce, 64 lowercase hex characters.
  final String nonce;

  /// Creates a challenge message.
  const ChallengeMsg({required this.nonce});
}

/// `auth` (C→S): HMAC proof (SPEC section 4).
final class AuthMsg extends RemoteMessage {
  /// HMAC proof, 64 lowercase hex characters.
  final String mac;

  /// Creates an auth message.
  const AuthMsg({required this.mac});
}

/// `authOk` (S→C): empty payload; session becomes Authed.
final class AuthOkMsg extends RemoteMessage {
  /// Creates an authOk message.
  const AuthOkMsg();
}

/// `authFail` (S→C): reason enum string + reason-specific extras (SPEC 5).
final class AuthFailMsg extends RemoteMessage {
  /// Failure reason (SPEC section 5 enum, kept as a plain string).
  final String reason;

  /// Attempts left before lockout (present for `pinInvalid`).
  final int? attemptsRemaining;

  /// Seconds until retry allowed (present for `lockedOut`).
  final int? retryAfterSecs;

  /// Creates an authFail message.
  const AuthFailMsg({
    required this.reason,
    this.attemptsRemaining,
    this.retryAfterSecs,
  });
}

/// `click` (C→S): reliable click path.
final class ClickMsg extends RemoteMessage {
  /// `"left" | "middle" | "right"` (plain string at codec level).
  final String button;

  /// Creates a click message.
  const ClickMsg({required this.button});
}

/// `drag` (C→S): held state tracked by the server (SPEC section 7).
final class DragMsg extends RemoteMessage {
  /// `"start" | "end"`.
  final String action;

  /// `"left" | "middle" | "right"`.
  final String button;

  /// Creates a drag message.
  const DragMsg({required this.action, required this.button});
}

/// `key` (C→S): single key with modifiers.
final class KeyMsg extends RemoteMessage {
  /// Key code string.
  final String code;

  /// `"tap" | "down" | "up"`.
  final String action;

  /// Modifiers (`"ctrl" | "alt" | "shift" | "win"`), default `[]`.
  final List<String> mods;

  /// Creates a key message.
  const KeyMsg({required this.code, required this.action, this.mods = const []});
}

/// `text` (C→S): diff-ops (SPEC section 8).
final class TextMsg extends RemoteMessage {
  /// Trailing graphemes to delete (extended grapheme clusters).
  final int bs;

  /// Text to insert.
  final String ins;

  /// Creates a text message.
  const TextMsg({required this.bs, required this.ins});
}

/// `media` (C→S): media-key actions; `value` required iff `setvol`
/// (enforced by the router, not the codec).
final class MediaMsg extends RemoteMessage {
  /// Media action string.
  final String action;

  /// Absolute volume 0-100 (only with `setvol`).
  final int? value;

  /// Creates a media message.
  const MediaMsg({required this.action, this.value});
}

/// `power` (C→S): requires follow-up `confirm`.
final class PowerMsg extends RemoteMessage {
  /// `"lock" | "sleep" | "restart" | "shutdown"`.
  final String action;

  /// Creates a power message.
  const PowerMsg({required this.action});
}

/// `confirm` (C→S): must match a pending `power` action within 10 seconds.
final class ConfirmMsg extends RemoteMessage {
  /// Same enum as `power`.
  final String action;

  /// Creates a confirm message.
  const ConfirmMsg({required this.action});
}

/// `apps.list` (C→S request / S→C reply): request payload is `{}`; the
/// reply carries `windows`.
final class AppsListMsg extends RemoteMessage {
  /// Present in replies, absent in requests.
  final List<WindowInfo>? windows;

  /// Creates an apps.list message.
  const AppsListMsg({this.windows});
}

/// `apps.launch` (C→S).
final class AppsLaunchMsg extends RemoteMessage {
  /// Executable path to launch.
  final String path;

  /// Creates an apps.launch message.
  const AppsLaunchMsg({required this.path});
}

/// `apps.focus` (C→S).
final class AppsFocusMsg extends RemoteMessage {
  /// Window id to focus.
  final int id;

  /// Creates an apps.focus message.
  const AppsFocusMsg({required this.id});
}

/// `apps.close` (C→S).
final class AppsCloseMsg extends RemoteMessage {
  /// Window id to close.
  final int id;

  /// Creates an apps.close message.
  const AppsCloseMsg({required this.id});
}

/// `apps.changed` (S→C push).
final class AppsChangedMsg extends RemoteMessage {
  /// Current window list.
  final List<WindowInfo> windows;

  /// Creates an apps.changed message.
  const AppsChangedMsg({required this.windows});
}

/// `clip.set` (C↔S).
final class ClipSetMsg extends RemoteMessage {
  /// Clipboard text.
  final String text;

  /// Creates a clip.set message.
  const ClipSetMsg({required this.text});
}

/// `clip.get` (C→S): empty payload; server replies with `clip.set`.
final class ClipGetMsg extends RemoteMessage {
  /// Creates a clip.get message.
  const ClipGetMsg();
}

/// `clip.changed` (S→C push, auto-sync).
final class ClipChangedMsg extends RemoteMessage {
  /// Clipboard text.
  final String text;

  /// Creates a clip.changed message.
  const ClipChangedMsg({required this.text});
}

/// `browser` (C→S): key-macro actions.
final class BrowserMsg extends RemoteMessage {
  /// Browser action string.
  final String action;

  /// Creates a browser message.
  const BrowserMsg({required this.action});
}

/// `present` (C→S): presenter-remote actions.
final class PresentMsg extends RemoteMessage {
  /// Presenter action string.
  final String action;

  /// Creates a present message.
  const PresentMsg({required this.action});
}

/// `ping` (C→S): latency probe.
final class PingMsg extends RemoteMessage {
  /// Client timestamp.
  final int ts;

  /// Creates a ping message.
  const PingMsg({required this.ts});
}

/// `pong` (S→C): echoes the `ping` timestamp.
final class PongMsg extends RemoteMessage {
  /// Echoed timestamp.
  final int ts;

  /// Creates a pong message.
  const PongMsg({required this.ts});
}

/// `err` (S→C): `code` + human-readable `msg` + code-specific extras.
final class ErrMsg extends RemoteMessage {
  /// Error code (SPEC section 7 err-code table).
  final String code;

  /// Human-readable message.
  final String msg;

  /// Present for `versionMismatch`.
  final String? serverVersion;

  /// Present for `versionMismatch`.
  final String? clientVersion;

  /// Creates an err message.
  const ErrMsg({
    required this.code,
    required this.msg,
    this.serverVersion,
    this.clientVersion,
  });
}

/// Unregistered message type: carries the offending `t` (D-07 — decoded,
/// never a decode error).
final class UnknownMsg extends RemoteMessage {
  /// The unrecognized type string.
  final String t;

  /// Creates an unknown-type message.
  const UnknownMsg({required this.t});
}

/// Decode a JSON text frame via the two-step envelope parse (envelope
/// `{t, seq?, p?}` first, then the family payload from `p`).
///
/// Absent `p` is equivalent to `{}`. Unknown fields are ignored (D-05).
/// Missing required payload fields throw [FormatException]. Unknown `t`
/// decodes to [UnknownMsg] — never an error (D-07).
({RemoteMessage msg, int? seq}) decodeText(String jsonText) {
  throw UnimplementedError('implemented by 01-08 Task 2');
}

/// Encode a message to its canonical wire form `{t, seq?, p}`.
///
/// The output contains ONLY spec-defined fields; `seq` is emitted only
/// when non-null; `p` is ALWAYS emitted (as `{}` for empty payloads).
String encodeMessage(RemoteMessage msg, {int? seq}) {
  throw UnimplementedError('implemented by 01-08 Task 2');
}
