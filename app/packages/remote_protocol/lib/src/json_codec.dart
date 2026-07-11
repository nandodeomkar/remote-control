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

import 'dart:convert';

/// Read a required payload field, throwing [FormatException] naming the
/// missing key (D-05 hard error) or the type mismatch.
T _req<T>(Map<String, dynamic> p, String key) {
  if (!p.containsKey(key)) {
    throw FormatException('missing required field: $key');
  }
  final v = p[key];
  if (v is! T) {
    throw FormatException(
      'field $key has unexpected type: ${v.runtimeType}',
    );
  }
  return v;
}

/// Read an optional payload field: absent or null yields null; a present
/// value with the wrong type is a decode error.
T? _opt<T>(Map<String, dynamic> p, String key) {
  final v = p[key];
  if (v == null) return null;
  if (v is! T) {
    throw FormatException(
      'field $key has unexpected type: ${v.runtimeType}',
    );
  }
  return v;
}

/// Parse a `windows` array of `{id, title}` entries.
List<WindowInfo> _windowList(Object? v, String key) {
  if (v is! List) {
    throw FormatException('field $key must be an array');
  }
  return v.map((e) {
    if (e is! Map<String, dynamic>) {
      throw FormatException('entries of $key must be objects');
    }
    return WindowInfo(id: _req<int>(e, 'id'), title: _req<String>(e, 'title'));
  }).toList();
}

/// A window entry in `apps.list` replies and `apps.changed` pushes.
class WindowInfo {
  /// Opaque window id.
  final int id;

  /// Window title.
  final String title;

  /// Creates a window entry.
  const WindowInfo({required this.id, required this.title});

  /// Canonical JSON form: `{id, title}`.
  Map<String, Object?> toJson() => {'id': id, 'title': title};
}

/// Every message type in the protoVersion 1.0 registry (SPEC section 7),
/// plus [UnknownMsg] for unregistered `t` values (D-07).
sealed class RemoteMessage {
  const RemoteMessage();

  /// The wire type string `t`.
  String get t;

  /// Canonical payload containing ONLY spec-defined fields (`{}` when the
  /// family has no payload).
  Map<String, Object?> toPayload();
}

/// `hello` (C→S): opens the handshake (SPEC section 3).
final class HelloMsg extends RemoteMessage {
  /// `"major.minor"` protocol version string.
  final String protoVersion;

  /// Client device name.
  final String device;

  /// Creates a hello message.
  const HelloMsg({required this.protoVersion, required this.device});

  /// Decodes the `hello` payload.
  factory HelloMsg.fromPayload(Map<String, dynamic> p) => HelloMsg(
        protoVersion: _req<String>(p, 'protoVersion'),
        device: _req<String>(p, 'device'),
      );

  @override
  String get t => 'hello';

  @override
  Map<String, Object?> toPayload() =>
      {'protoVersion': protoVersion, 'device': device};
}

/// `pin` (C→S): pairing path. The PIN is a 6-digit zero-padded STRING.
final class PinMsg extends RemoteMessage {
  /// 6-digit zero-padded PIN string (leading zeros significant).
  final String pin;

  /// Creates a pin message.
  const PinMsg({required this.pin});

  /// Decodes the `pin` payload.
  factory PinMsg.fromPayload(Map<String, dynamic> p) =>
      PinMsg(pin: _req<String>(p, 'pin'));

  @override
  String get t => 'pin';

  @override
  Map<String, Object?> toPayload() => {'pin': pin};
}

/// `pairOk` (S→C): the only wire appearance of the raw token (SPEC 12).
final class PairOkMsg extends RemoteMessage {
  /// Raw token, 64 lowercase hex characters.
  final String token;

  /// Creates a pairOk message.
  const PairOkMsg({required this.token});

  /// Decodes the `pairOk` payload.
  factory PairOkMsg.fromPayload(Map<String, dynamic> p) =>
      PairOkMsg(token: _req<String>(p, 'token'));

  @override
  String get t => 'pairOk';

  @override
  Map<String, Object?> toPayload() => {'token': token};
}

/// `challenge` (S→C): fresh per-connection nonce.
final class ChallengeMsg extends RemoteMessage {
  /// Nonce, 64 lowercase hex characters.
  final String nonce;

  /// Creates a challenge message.
  const ChallengeMsg({required this.nonce});

  /// Decodes the `challenge` payload.
  factory ChallengeMsg.fromPayload(Map<String, dynamic> p) =>
      ChallengeMsg(nonce: _req<String>(p, 'nonce'));

  @override
  String get t => 'challenge';

  @override
  Map<String, Object?> toPayload() => {'nonce': nonce};
}

/// `auth` (C→S): HMAC proof (SPEC section 4).
final class AuthMsg extends RemoteMessage {
  /// HMAC proof, 64 lowercase hex characters.
  final String mac;

  /// Creates an auth message.
  const AuthMsg({required this.mac});

  /// Decodes the `auth` payload.
  factory AuthMsg.fromPayload(Map<String, dynamic> p) =>
      AuthMsg(mac: _req<String>(p, 'mac'));

  @override
  String get t => 'auth';

  @override
  Map<String, Object?> toPayload() => {'mac': mac};
}

/// `authOk` (S→C): empty payload; session becomes Authed.
final class AuthOkMsg extends RemoteMessage {
  /// Creates an authOk message.
  const AuthOkMsg();

  /// Decodes the (empty) `authOk` payload.
  factory AuthOkMsg.fromPayload(Map<String, dynamic> p) => const AuthOkMsg();

  @override
  String get t => 'authOk';

  @override
  Map<String, Object?> toPayload() => {};
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

  /// Decodes the `authFail` payload.
  factory AuthFailMsg.fromPayload(Map<String, dynamic> p) => AuthFailMsg(
        reason: _req<String>(p, 'reason'),
        attemptsRemaining: _opt<int>(p, 'attemptsRemaining'),
        retryAfterSecs: _opt<int>(p, 'retryAfterSecs'),
      );

  @override
  String get t => 'authFail';

  @override
  Map<String, Object?> toPayload() => {
        'reason': reason,
        if (attemptsRemaining != null) 'attemptsRemaining': attemptsRemaining,
        if (retryAfterSecs != null) 'retryAfterSecs': retryAfterSecs,
      };
}

/// `click` (C→S): reliable click path.
final class ClickMsg extends RemoteMessage {
  /// `"left" | "middle" | "right"` (plain string at codec level).
  final String button;

  /// Creates a click message.
  const ClickMsg({required this.button});

  /// Decodes the `click` payload.
  factory ClickMsg.fromPayload(Map<String, dynamic> p) =>
      ClickMsg(button: _req<String>(p, 'button'));

  @override
  String get t => 'click';

  @override
  Map<String, Object?> toPayload() => {'button': button};
}

/// `drag` (C→S): held state tracked by the server (SPEC section 7).
final class DragMsg extends RemoteMessage {
  /// `"start" | "end"`.
  final String action;

  /// `"left" | "middle" | "right"`.
  final String button;

  /// Creates a drag message.
  const DragMsg({required this.action, required this.button});

  /// Decodes the `drag` payload.
  factory DragMsg.fromPayload(Map<String, dynamic> p) => DragMsg(
        action: _req<String>(p, 'action'),
        button: _req<String>(p, 'button'),
      );

  @override
  String get t => 'drag';

  @override
  Map<String, Object?> toPayload() => {'action': action, 'button': button};
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

  /// Decodes the `key` payload. `mods` defaults to `[]` when absent.
  factory KeyMsg.fromPayload(Map<String, dynamic> p) {
    final modsRaw = p['mods'];
    final List<String> mods;
    if (modsRaw == null) {
      mods = const [];
    } else if (modsRaw is List) {
      mods = modsRaw
          .map((e) => e is String
              ? e
              : throw const FormatException('mods entries must be strings'))
          .toList();
    } else {
      throw const FormatException('field mods must be an array');
    }
    return KeyMsg(
      code: _req<String>(p, 'code'),
      action: _req<String>(p, 'action'),
      mods: mods,
    );
  }

  @override
  String get t => 'key';

  @override
  Map<String, Object?> toPayload() => {
        'code': code,
        'action': action,
        if (mods.isNotEmpty) 'mods': mods,
      };
}

/// `text` (C→S): diff-ops (SPEC section 8).
final class TextMsg extends RemoteMessage {
  /// Trailing graphemes to delete (extended grapheme clusters).
  final int bs;

  /// Text to insert.
  final String ins;

  /// Creates a text message.
  const TextMsg({required this.bs, required this.ins});

  /// Decodes the `text` payload.
  factory TextMsg.fromPayload(Map<String, dynamic> p) =>
      TextMsg(bs: _req<int>(p, 'bs'), ins: _req<String>(p, 'ins'));

  @override
  String get t => 'text';

  @override
  Map<String, Object?> toPayload() => {'bs': bs, 'ins': ins};
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

  /// Decodes the `media` payload.
  factory MediaMsg.fromPayload(Map<String, dynamic> p) =>
      MediaMsg(action: _req<String>(p, 'action'), value: _opt<int>(p, 'value'));

  @override
  String get t => 'media';

  @override
  Map<String, Object?> toPayload() => {
        'action': action,
        if (value != null) 'value': value,
      };
}

/// `vol.changed` (S→C push, protoVersion 1.1, D-03): server volume state.
/// BOTH fields required — a missing field is a hard decode error (fixture
/// 03), unlike `media.value` which is conditionally required.
final class VolChangedMsg extends RemoteMessage {
  /// Absolute volume 0-100.
  final int value;

  /// Whether the server output is muted.
  final bool muted;

  /// Creates a vol.changed message.
  const VolChangedMsg({required this.value, required this.muted});

  /// Decodes the `vol.changed` payload.
  factory VolChangedMsg.fromPayload(Map<String, dynamic> p) => VolChangedMsg(
      value: _req<int>(p, 'value'), muted: _req<bool>(p, 'muted'));

  @override
  String get t => 'vol.changed';

  @override
  Map<String, Object?> toPayload() => {'value': value, 'muted': muted};
}

/// `power` (C→S): requires follow-up `confirm`.
final class PowerMsg extends RemoteMessage {
  /// `"lock" | "sleep" | "restart" | "shutdown"`.
  final String action;

  /// Creates a power message.
  const PowerMsg({required this.action});

  /// Decodes the `power` payload.
  factory PowerMsg.fromPayload(Map<String, dynamic> p) =>
      PowerMsg(action: _req<String>(p, 'action'));

  @override
  String get t => 'power';

  @override
  Map<String, Object?> toPayload() => {'action': action};
}

/// `confirm` (C→S): must match a pending `power` action within 10 seconds.
final class ConfirmMsg extends RemoteMessage {
  /// Same enum as `power`.
  final String action;

  /// Creates a confirm message.
  const ConfirmMsg({required this.action});

  /// Decodes the `confirm` payload.
  factory ConfirmMsg.fromPayload(Map<String, dynamic> p) =>
      ConfirmMsg(action: _req<String>(p, 'action'));

  @override
  String get t => 'confirm';

  @override
  Map<String, Object?> toPayload() => {'action': action};
}

/// `apps.list` (C→S request / S→C reply): request payload is `{}`; the
/// reply carries `windows`.
final class AppsListMsg extends RemoteMessage {
  /// Present in replies, absent in requests.
  final List<WindowInfo>? windows;

  /// Creates an apps.list message.
  const AppsListMsg({this.windows});

  /// Decodes the `apps.list` payload.
  factory AppsListMsg.fromPayload(Map<String, dynamic> p) {
    final raw = p['windows'];
    return AppsListMsg(
      windows: raw == null ? null : _windowList(raw, 'windows'),
    );
  }

  @override
  String get t => 'apps.list';

  @override
  Map<String, Object?> toPayload() => {
        if (windows != null)
          'windows': windows!.map((w) => w.toJson()).toList(),
      };
}

/// `apps.launch` (C→S).
final class AppsLaunchMsg extends RemoteMessage {
  /// Executable path to launch.
  final String path;

  /// Creates an apps.launch message.
  const AppsLaunchMsg({required this.path});

  /// Decodes the `apps.launch` payload.
  factory AppsLaunchMsg.fromPayload(Map<String, dynamic> p) =>
      AppsLaunchMsg(path: _req<String>(p, 'path'));

  @override
  String get t => 'apps.launch';

  @override
  Map<String, Object?> toPayload() => {'path': path};
}

/// `apps.focus` (C→S).
final class AppsFocusMsg extends RemoteMessage {
  /// Window id to focus.
  final int id;

  /// Creates an apps.focus message.
  const AppsFocusMsg({required this.id});

  /// Decodes the `apps.focus` payload.
  factory AppsFocusMsg.fromPayload(Map<String, dynamic> p) =>
      AppsFocusMsg(id: _req<int>(p, 'id'));

  @override
  String get t => 'apps.focus';

  @override
  Map<String, Object?> toPayload() => {'id': id};
}

/// `apps.close` (C→S).
final class AppsCloseMsg extends RemoteMessage {
  /// Window id to close.
  final int id;

  /// Creates an apps.close message.
  const AppsCloseMsg({required this.id});

  /// Decodes the `apps.close` payload.
  factory AppsCloseMsg.fromPayload(Map<String, dynamic> p) =>
      AppsCloseMsg(id: _req<int>(p, 'id'));

  @override
  String get t => 'apps.close';

  @override
  Map<String, Object?> toPayload() => {'id': id};
}

/// `apps.changed` (S→C push).
final class AppsChangedMsg extends RemoteMessage {
  /// Current window list.
  final List<WindowInfo> windows;

  /// Creates an apps.changed message.
  const AppsChangedMsg({required this.windows});

  /// Decodes the `apps.changed` payload.
  factory AppsChangedMsg.fromPayload(Map<String, dynamic> p) {
    if (!p.containsKey('windows')) {
      throw const FormatException('missing required field: windows');
    }
    return AppsChangedMsg(windows: _windowList(p['windows'], 'windows'));
  }

  @override
  String get t => 'apps.changed';

  @override
  Map<String, Object?> toPayload() =>
      {'windows': windows.map((w) => w.toJson()).toList()};
}

/// `clip.set` (C↔S).
final class ClipSetMsg extends RemoteMessage {
  /// Clipboard text.
  final String text;

  /// Creates a clip.set message.
  const ClipSetMsg({required this.text});

  /// Decodes the `clip.set` payload.
  factory ClipSetMsg.fromPayload(Map<String, dynamic> p) =>
      ClipSetMsg(text: _req<String>(p, 'text'));

  @override
  String get t => 'clip.set';

  @override
  Map<String, Object?> toPayload() => {'text': text};
}

/// `clip.get` (C→S): empty payload; server replies with `clip.set`.
final class ClipGetMsg extends RemoteMessage {
  /// Creates a clip.get message.
  const ClipGetMsg();

  /// Decodes the (empty) `clip.get` payload.
  factory ClipGetMsg.fromPayload(Map<String, dynamic> p) => const ClipGetMsg();

  @override
  String get t => 'clip.get';

  @override
  Map<String, Object?> toPayload() => {};
}

/// `clip.changed` (S→C push, auto-sync).
final class ClipChangedMsg extends RemoteMessage {
  /// Clipboard text.
  final String text;

  /// Creates a clip.changed message.
  const ClipChangedMsg({required this.text});

  /// Decodes the `clip.changed` payload.
  factory ClipChangedMsg.fromPayload(Map<String, dynamic> p) =>
      ClipChangedMsg(text: _req<String>(p, 'text'));

  @override
  String get t => 'clip.changed';

  @override
  Map<String, Object?> toPayload() => {'text': text};
}

/// `browser` (C→S): key-macro actions.
final class BrowserMsg extends RemoteMessage {
  /// Browser action string.
  final String action;

  /// Creates a browser message.
  const BrowserMsg({required this.action});

  /// Decodes the `browser` payload.
  factory BrowserMsg.fromPayload(Map<String, dynamic> p) =>
      BrowserMsg(action: _req<String>(p, 'action'));

  @override
  String get t => 'browser';

  @override
  Map<String, Object?> toPayload() => {'action': action};
}

/// `present` (C→S): presenter-remote actions.
final class PresentMsg extends RemoteMessage {
  /// Presenter action string.
  final String action;

  /// Creates a present message.
  const PresentMsg({required this.action});

  /// Decodes the `present` payload.
  factory PresentMsg.fromPayload(Map<String, dynamic> p) =>
      PresentMsg(action: _req<String>(p, 'action'));

  @override
  String get t => 'present';

  @override
  Map<String, Object?> toPayload() => {'action': action};
}

/// `ping` (C→S): latency probe.
final class PingMsg extends RemoteMessage {
  /// Client timestamp.
  final int ts;

  /// Creates a ping message.
  const PingMsg({required this.ts});

  /// Decodes the `ping` payload.
  factory PingMsg.fromPayload(Map<String, dynamic> p) =>
      PingMsg(ts: _req<int>(p, 'ts'));

  @override
  String get t => 'ping';

  @override
  Map<String, Object?> toPayload() => {'ts': ts};
}

/// `pong` (S→C): echoes the `ping` timestamp.
final class PongMsg extends RemoteMessage {
  /// Echoed timestamp.
  final int ts;

  /// Creates a pong message.
  const PongMsg({required this.ts});

  /// Decodes the `pong` payload.
  factory PongMsg.fromPayload(Map<String, dynamic> p) =>
      PongMsg(ts: _req<int>(p, 'ts'));

  @override
  String get t => 'pong';

  @override
  Map<String, Object?> toPayload() => {'ts': ts};
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

  /// Decodes the `err` payload.
  factory ErrMsg.fromPayload(Map<String, dynamic> p) => ErrMsg(
        code: _req<String>(p, 'code'),
        msg: _req<String>(p, 'msg'),
        serverVersion: _opt<String>(p, 'serverVersion'),
        clientVersion: _opt<String>(p, 'clientVersion'),
      );

  @override
  String get t => 'err';

  @override
  Map<String, Object?> toPayload() => {
        'code': code,
        'msg': msg,
        if (serverVersion != null) 'serverVersion': serverVersion,
        if (clientVersion != null) 'clientVersion': clientVersion,
      };
}

/// Unregistered message type: carries the offending `t` (D-07 — decoded,
/// never a decode error).
final class UnknownMsg extends RemoteMessage {
  /// The unrecognized type string.
  @override
  final String t;

  /// Creates an unknown-type message.
  const UnknownMsg({required this.t});

  @override
  Map<String, Object?> toPayload() => {};
}

/// Decode a JSON text frame via the two-step envelope parse (envelope
/// `{t, seq?, p?}` first, then the family payload from `p`).
///
/// Absent `p` is equivalent to `{}`. Unknown fields are ignored (D-05).
/// Missing required payload fields throw [FormatException]. Unknown `t`
/// decodes to [UnknownMsg] — never an error (D-07).
({RemoteMessage msg, int? seq}) decodeText(String jsonText) {
  // jsonDecode already throws FormatException on invalid JSON.
  final root = jsonDecode(jsonText);
  if (root is! Map<String, dynamic>) {
    throw const FormatException('envelope must be a JSON object');
  }

  final tRaw = root['t'];
  if (tRaw is! String) {
    throw const FormatException('missing required envelope field: t');
  }

  final seqRaw = root['seq'];
  if (seqRaw != null && seqRaw is! int) {
    throw const FormatException('envelope field seq must be an integer');
  }
  final seq = seqRaw as int?;

  // Absent `p` is equivalent to `{}` (SPEC section 1).
  final pRaw = root['p'];
  final Map<String, dynamic> p;
  if (pRaw == null) {
    p = const {};
  } else if (pRaw is Map<String, dynamic>) {
    p = pRaw;
  } else {
    throw const FormatException('envelope field p must be an object');
  }

  final msg = switch (tRaw) {
    'hello' => HelloMsg.fromPayload(p),
    'pin' => PinMsg.fromPayload(p),
    'pairOk' => PairOkMsg.fromPayload(p),
    'challenge' => ChallengeMsg.fromPayload(p),
    'auth' => AuthMsg.fromPayload(p),
    'authOk' => AuthOkMsg.fromPayload(p),
    'authFail' => AuthFailMsg.fromPayload(p),
    'click' => ClickMsg.fromPayload(p),
    'drag' => DragMsg.fromPayload(p),
    'key' => KeyMsg.fromPayload(p),
    'text' => TextMsg.fromPayload(p),
    'media' => MediaMsg.fromPayload(p),
    'vol.changed' => VolChangedMsg.fromPayload(p),
    'power' => PowerMsg.fromPayload(p),
    'confirm' => ConfirmMsg.fromPayload(p),
    'apps.list' => AppsListMsg.fromPayload(p),
    'apps.launch' => AppsLaunchMsg.fromPayload(p),
    'apps.focus' => AppsFocusMsg.fromPayload(p),
    'apps.close' => AppsCloseMsg.fromPayload(p),
    'apps.changed' => AppsChangedMsg.fromPayload(p),
    'clip.set' => ClipSetMsg.fromPayload(p),
    'clip.get' => ClipGetMsg.fromPayload(p),
    'clip.changed' => ClipChangedMsg.fromPayload(p),
    'browser' => BrowserMsg.fromPayload(p),
    'present' => PresentMsg.fromPayload(p),
    'ping' => PingMsg.fromPayload(p),
    'pong' => PongMsg.fromPayload(p),
    'err' => ErrMsg.fromPayload(p),
    // D-07: unknown `t` is a DECODED message, never a decode error —
    // the router's unknownType/silent-drop behavior depends on this.
    _ => UnknownMsg(t: tRaw),
  };

  return (msg: msg, seq: seq);
}

/// Encode a message to its canonical wire form `{t, seq?, p}`.
///
/// The output contains ONLY spec-defined fields; `seq` is emitted only
/// when non-null; `p` is ALWAYS emitted (as `{}` for empty payloads) —
/// every canonical fixture expect envelope carries `p`.
String encodeMessage(RemoteMessage msg, {int? seq}) {
  final envelope = <String, Object?>{
    't': msg.t,
    if (seq != null) 'seq': seq,
    'p': msg.toPayload(),
  };
  return jsonEncode(envelope);
}
