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

/// Parse a `windows` array of `{id, title, icon?, path?}` entries.
///
/// `icon`/`path` are optional (protocol 1.2, D-05 tolerant): absent → null,
/// unknown extra fields ignored. A present value with the wrong type is a
/// decode error (via [_opt]).
List<WindowInfo> _windowList(Object? v, String key) {
  if (v is! List) {
    throw FormatException('field $key must be an array');
  }
  return v.map((e) {
    if (e is! Map<String, dynamic>) {
      throw FormatException('entries of $key must be objects');
    }
    return WindowInfo(
      id: _req<int>(e, 'id'),
      title: _req<String>(e, 'title'),
      icon: _opt<String>(e, 'icon'),
      path: _opt<String>(e, 'path'),
    );
  }).toList();
}

/// A window entry in `apps.list` replies and `apps.changed` pushes.
class WindowInfo {
  /// Opaque window id.
  final int id;

  /// Window title.
  final String title;

  /// Base64 PNG icon (32×32), or null for legacy/iconless windows
  /// (protocol 1.2 additive field).
  final String? icon;

  /// Resolved executable path, or null when unresolved (UWP → non-pinnable,
  /// protocol 1.2 additive field).
  final String? path;

  /// Creates a window entry.
  const WindowInfo({
    required this.id,
    required this.title,
    this.icon,
    this.path,
  });

  /// Canonical JSON form: `{id, title}` plus `icon`/`path` only when non-null
  /// (mirrors the Rust `skip_serializing_if = "Option::is_none"`).
  Map<String, Object?> toJson() => {
        'id': id,
        'title': title,
        if (icon != null) 'icon': icon,
        if (path != null) 'path': path,
      };

  @override
  bool operator ==(Object other) =>
      other is WindowInfo &&
      other.id == id &&
      other.title == title &&
      other.icon == icon &&
      other.path == path;

  @override
  int get hashCode => Object.hash(id, title, icon, path);
}

/// Parse a `tabs` array of `{id, title, active, icon?}` entries
/// (protoVersion 1.4).
///
/// `icon` is optional (D-05 tolerant): absent → null, unknown extra fields
/// ignored. A present value with the wrong type is a decode error.
List<TabInfo> _tabList(Object? v, String key) {
  if (v is! List) {
    throw FormatException('field $key must be an array');
  }
  return v.map((e) {
    if (e is! Map<String, dynamic>) {
      throw FormatException('entries of $key must be objects');
    }
    return TabInfo(
      id: _req<int>(e, 'id'),
      title: _req<String>(e, 'title'),
      active: _req<bool>(e, 'active'),
      icon: _opt<String>(e, 'icon'),
      groupId: _opt<int>(e, 'groupId'),
      bookmarked: _opt<bool>(e, 'bookmarked'),
    );
  }).toList();
}

/// Parse a `groups` array of `{id, title, color, collapsed}` entries
/// (protoVersion 1.5, quick 260716-sme).
///
/// All four fields are REQUIRED per element (a missing field is a hard
/// decode error — fixture 08); unknown extra fields are ignored (D-05).
List<GroupInfo> _groupList(Object? v, String key) {
  if (v is! List) {
    throw FormatException('field $key must be an array');
  }
  return v.map((e) {
    if (e is! Map<String, dynamic>) {
      throw FormatException('entries of $key must be objects');
    }
    return GroupInfo(
      id: _req<int>(e, 'id'),
      title: _req<String>(e, 'title'),
      color: _req<String>(e, 'color'),
      collapsed: _req<bool>(e, 'collapsed'),
    );
  }).toList();
}

/// A tab entry in `tabs.list` replies and `tabs.changed` pushes
/// (protoVersion 1.4, BROW-01). No url field ever crosses the phone-facing
/// wire — titles are enough (SPEC section 7 privacy rule).
class TabInfo {
  /// Browser-assigned tab id.
  final int id;

  /// Tab title (may be empty).
  final String title;

  /// Whether this is THE active tab (exactly one per snapshot).
  final bool active;

  /// Base64 PNG favicon WITHOUT a `data:` prefix (the WindowInfo icon
  /// convention), or null for iconless tabs.
  final String? icon;

  /// Owning tab-group id (protoVersion 1.5), or null when ungrouped.
  /// Absent on the wire = ungrouped — never emitted as null or `-1`.
  final int? groupId;

  /// Whether this tab's URL is bookmarked anywhere in the tree
  /// (protoVersion 1.6, D-11). TRI-STATE: `true` bookmarked, `false` not
  /// bookmarked, and **null means UNKNOWN — NOT `false`** (the extension
  /// could not read the bookmark tree). Unlike [icon] and [groupId], whose
  /// absence reads "there is none", absence here reads "we do not know", so
  /// a null must render NO star at all rather than an empty one.
  final bool? bookmarked;

  /// Creates a tab entry.
  const TabInfo({
    required this.id,
    required this.title,
    required this.active,
    this.icon,
    this.groupId,
    this.bookmarked,
  });

  /// Canonical JSON form: `{id, title, active}` plus `icon`/`groupId`/
  /// `bookmarked` only when non-null (mirrors the Rust
  /// `skip_serializing_if = "Option::is_none"`).
  Map<String, Object?> toJson() => {
        'id': id,
        'title': title,
        'active': active,
        if (icon != null) 'icon': icon,
        if (groupId != null) 'groupId': groupId,
        if (bookmarked != null) 'bookmarked': bookmarked,
      };

  @override
  bool operator ==(Object other) =>
      other is TabInfo &&
      other.id == id &&
      other.title == title &&
      other.active == active &&
      other.icon == icon &&
      other.groupId == groupId &&
      other.bookmarked == bookmarked;

  @override
  int get hashCode =>
      Object.hash(id, title, active, icon, groupId, bookmarked);
}

/// A tab-group entry in the optional `groups` array on `tabs.list` replies
/// and `tabs.changed` pushes (protoVersion 1.5, BROW-01, quick 260716-sme).
///
/// `color` is Chrome's NAMED group-color string
/// (`grey|blue|red|yellow|green|pink|purple|cyan|orange`) passed through
/// verbatim — map it to a color in the app layer; unknown names fall back
/// neutrally. `title` may be empty (Chrome allows unnamed groups).
/// `collapsed` is display metadata only — view-only, no wire message
/// toggles it.
class GroupInfo {
  /// Browser-assigned group id (referenced by [TabInfo.groupId]).
  final int id;

  /// Group title (may be empty; capped at 32 chars extension-side).
  final String title;

  /// Chrome named group color, passed through verbatim.
  final String color;

  /// Whether the group is collapsed on the PC (display metadata only).
  final bool collapsed;

  /// Creates a group entry.
  const GroupInfo({
    required this.id,
    required this.title,
    required this.color,
    required this.collapsed,
  });

  /// Canonical JSON form: all four keys, always.
  Map<String, Object?> toJson() => {
        'id': id,
        'title': title,
        'color': color,
        'collapsed': collapsed,
      };

  @override
  bool operator ==(Object other) =>
      other is GroupInfo &&
      other.id == id &&
      other.title == title &&
      other.color == color &&
      other.collapsed == collapsed;

  @override
  int get hashCode => Object.hash(id, title, color, collapsed);
}

/// A bookmark node in `bm.list` replies and `bm.changed` pushes
/// (protoVersion 1.6, phase 11) — the flat BmEl element (SPEC section 7).
///
/// [id] and [parentId] are Chrome bookmark ids and are **STRINGS**, unlike
/// the integer [TabInfo.id] — which is why the commands name their fields
/// `nodeId` (bookmark node) and `tabId` (tab) instead of both reusing `id`:
/// the codec is value-lenient, so a swapped id would decode fine and fail
/// SILENTLY at the extension.
///
/// The tree is flat and breadth-first: root `"0"` is NEVER shipped as a
/// node, its children carry `parentId: "0"`, and the phone treats `"0"` as
/// the virtual top level (D-08).
///
/// There is **no `url` field and no `icon` field** — URL resolution stays
/// extension-side (the locked no-url invariant TabEl also carries), and the
/// icon is dropped (D-07) to keep the whole tree inside one frame.
final class BmNode {
  /// Chrome bookmark id (a STRING, not an integer).
  final String id;

  /// Parent bookmark id; `"0"` for a virtual-top-level node (D-08).
  final String parentId;

  /// Node title (capped at 48 chars extension-side; may be empty).
  final String title;

  /// Whether this node is a folder (absent = a link).
  final bool? folder;

  /// Direct-child count of a folder — gates the D-14 delete affordance
  /// (`count == 0` ⇒ delete may be offered). Absent on links.
  final int? count;

  /// Mirrors Chrome's `BookmarkTreeNode.unmodifiable` (managed/admin
  /// bookmarks) so the phone hides a delete Chrome would reject.
  final bool? locked;

  /// `true` marks a folder whose children were dropped by the extension's
  /// byte-budget loop (SPEC section 15).
  final bool? truncated;

  /// Creates a bookmark node.
  const BmNode({
    required this.id,
    required this.parentId,
    required this.title,
    this.folder,
    this.count,
    this.locked,
    this.truncated,
  });

  /// Canonical JSON form: `{id, parentId, title}` plus each flag only when
  /// non-null (mirrors the Rust `skip_serializing_if = "Option::is_none"`).
  Map<String, Object?> toJson() => {
        'id': id,
        'parentId': parentId,
        'title': title,
        if (folder != null) 'folder': folder,
        if (count != null) 'count': count,
        if (locked != null) 'locked': locked,
        if (truncated != null) 'truncated': truncated,
      };

  @override
  bool operator ==(Object other) =>
      other is BmNode &&
      other.id == id &&
      other.parentId == parentId &&
      other.title == title &&
      other.folder == folder &&
      other.count == count &&
      other.locked == locked &&
      other.truncated == truncated;

  @override
  int get hashCode =>
      Object.hash(id, parentId, title, folder, count, locked, truncated);
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

/// `input.blocked` (S→C push, protoVersion 1.3, SRV-05/D-07): the foreground
/// window is higher-integrity (elevated) so injected input is being silently
/// dropped by UIPI. `reason` is a fixed vocabulary string (currently
/// `"elevated"`) — never a window title/exe path/PII. Additive: older servers
/// never send it, and unknown payload fields are ignored on decode (D-05).
final class InputBlockedMsg extends RemoteMessage {
  /// Fixed-vocabulary block reason (e.g. `"elevated"`).
  final String reason;

  /// Creates an input.blocked message.
  const InputBlockedMsg({required this.reason});

  /// Decodes the `input.blocked` payload.
  factory InputBlockedMsg.fromPayload(Map<String, dynamic> p) =>
      InputBlockedMsg(reason: _req<String>(p, 'reason'));

  @override
  String get t => 'input.blocked';

  @override
  Map<String, Object?> toPayload() => {'reason': reason};
}

/// `tabs.list` (C→S request / S→C reply, protoVersion 1.4): request payload
/// is `{}`; the reply carries `connected` + `tabs`. With the extension never
/// connected the reply is `{connected:false, tabs:[]}` — the phone's
/// install-hint state.
final class TabsListMsg extends RemoteMessage {
  /// Present in replies, absent in requests.
  final bool? connected;

  /// Present in replies, absent in requests.
  final List<TabInfo>? tabs;

  /// Tab groups (protoVersion 1.5): null when absent (a 1.4 server), a list
  /// (possibly empty) when present. Absent stays absent on canonical
  /// re-encode; present round-trips.
  final List<GroupInfo>? groups;

  /// Creates a tabs.list message (const request form: all fields null).
  const TabsListMsg({this.connected, this.tabs, this.groups});

  /// Decodes the `tabs.list` payload.
  factory TabsListMsg.fromPayload(Map<String, dynamic> p) {
    final raw = p['tabs'];
    final rawGroups = p['groups'];
    return TabsListMsg(
      connected: _opt<bool>(p, 'connected'),
      tabs: raw == null ? null : _tabList(raw, 'tabs'),
      groups: rawGroups == null ? null : _groupList(rawGroups, 'groups'),
    );
  }

  @override
  String get t => 'tabs.list';

  @override
  Map<String, Object?> toPayload() => {
        if (connected != null) 'connected': connected,
        if (tabs != null) 'tabs': tabs!.map((e) => e.toJson()).toList(),
        if (groups != null) 'groups': groups!.map((e) => e.toJson()).toList(),
      };
}

/// `tabs.changed` (S→C push, protoVersion 1.4): on any tab change AND on
/// extension connect/disconnect. `connected` and `tabs` required — a missing
/// field is a hard decode error. `groups` (protoVersion 1.5) is optional:
/// a 1.4 frame without it must decode (additive).
final class TabsChangedMsg extends RemoteMessage {
  /// Whether the browser extension is connected to the server.
  final bool connected;

  /// Current full tab snapshot (extension order).
  final List<TabInfo> tabs;

  /// Tab groups (protoVersion 1.5): null when absent (a 1.4 server), a list
  /// (possibly empty) when present. Absent stays absent on canonical
  /// re-encode; present round-trips.
  final List<GroupInfo>? groups;

  /// Creates a tabs.changed message.
  const TabsChangedMsg({required this.connected, required this.tabs, this.groups});

  /// Decodes the `tabs.changed` payload.
  factory TabsChangedMsg.fromPayload(Map<String, dynamic> p) {
    if (!p.containsKey('tabs')) {
      throw const FormatException('missing required field: tabs');
    }
    final rawGroups = p['groups'];
    return TabsChangedMsg(
      connected: _req<bool>(p, 'connected'),
      tabs: _tabList(p['tabs'], 'tabs'),
      groups: rawGroups == null ? null : _groupList(rawGroups, 'groups'),
    );
  }

  @override
  String get t => 'tabs.changed';

  @override
  Map<String, Object?> toPayload() => {
        'connected': connected,
        'tabs': tabs.map((e) => e.toJson()).toList(),
        if (groups != null) 'groups': groups!.map((e) => e.toJson()).toList(),
      };
}

/// `tabs.activate` (C→S, protoVersion 1.4): switch the PC browser to that
/// tab. Fire-and-forget — no err reply; stale ids self-heal via the next
/// `tabs.changed`.
final class TabsActivateMsg extends RemoteMessage {
  /// Tab id to activate.
  final int id;

  /// Creates a tabs.activate message.
  const TabsActivateMsg({required this.id});

  /// Decodes the `tabs.activate` payload.
  factory TabsActivateMsg.fromPayload(Map<String, dynamic> p) =>
      TabsActivateMsg(id: _req<int>(p, 'id'));

  @override
  String get t => 'tabs.activate';

  @override
  Map<String, Object?> toPayload() => {'id': id};
}

/// `tabs.close` (C→S, protoVersion 1.4): close that tab. Fire-and-forget —
/// same semantics as `tabs.activate`.
final class TabsCloseMsg extends RemoteMessage {
  /// Tab id to close.
  final int id;

  /// Creates a tabs.close message.
  const TabsCloseMsg({required this.id});

  /// Decodes the `tabs.close` payload.
  factory TabsCloseMsg.fromPayload(Map<String, dynamic> p) =>
      TabsCloseMsg(id: _req<int>(p, 'id'));

  @override
  String get t => 'tabs.close';

  @override
  Map<String, Object?> toPayload() => {'id': id};
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
    'input.blocked' => InputBlockedMsg.fromPayload(p),
    'tabs.list' => TabsListMsg.fromPayload(p),
    'tabs.changed' => TabsChangedMsg.fromPayload(p),
    'tabs.activate' => TabsActivateMsg.fromPayload(p),
    'tabs.close' => TabsCloseMsg.fromPayload(p),
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
