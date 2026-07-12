/// The clipboard store (CLIP-01/02/04, D-06) — the persistent last-5 history
/// plus the Riverpod-3 notifier that drives Send / Fetch / reuse.
///
/// TWO layers, mirroring the house split (pure persistence + a thin Notifier):
///
/// 1. [HistoryStore] is a pure, [PrefsKv]-backed store (non-secrets only —
///    house rule, NEVER SecureKv; T-06-17). Clipboard text the user explicitly
///    moved is recorded as the most-recent entry; recording an entry that
///    already exists promotes it to the head (so a repeat — including a reuse
///    tap — collapses and moves to most-recent, D-06), and the list caps at
///    [maxEntries]. Load/save is corruption-tolerant (`try/on Object` degrade
///    to empty, never throws — device_store discipline).
///
/// 2. [ClipNotifier] clones [VolumeNotifier]/[AppsNotifier]: it subscribes to
///    `service.changes`, republishes a value-equal [ClipViewState] (the loaded
///    history + a connection-gating flag), and exposes send/fetch/reuse
///    commands. Send reads the phone clipboard (the screen supplies the text)
///    and pushes `clip.set`; Fetch pulls `clip.get` and writes the reply to the
///    phone clipboard; reuse re-pushes a history entry to the PC (D-06).
///
/// 06-06 adds the live auto-sync slice on top of the manual one:
///
/// - [AutoSyncStore] is a [PrefsKv]-backed bool (key `clip.autosync`, default
///   OFF, D-03) — a local persisted preference, always toggleable regardless of
///   connection.
/// - [ClipSyncPolicy] is the pure, IO-free apply/echo/resume decision seam
///   (clock-free sibling of [VolumeSliderPolicy]): PC→phone applies an incoming
///   `clip.changed` snapshot ONLY when auto-sync is on and the value is not an
///   echo (client-gated apply, RESEARCH A4; value-equality echo suppression,
///   D-05); phone→PC syncs on app resume only (Android 10+ background-read
///   limit, D-08), gated the same way. All IO (clipboard write, history record,
///   `clip.set` send) is injected so the decisions test without Flutter/wire.
/// - [ClipNotifier] wires both into the existing `changes` subscription and
///   exposes `autoSyncOn` (on [ClipViewState]), `setAutoSync`, and
///   `syncOnResume` for the screen's [AppLifecycleListener] resume hook.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:remote_protocol/remote_protocol.dart';

import '../net/connection_providers.dart';
import '../net/connection_service.dart';
import '../store/device_store.dart';

/// The client-side Send hard cap in UTF-8 bytes (~48 KiB). A Send over this is
/// refused so no `clip.set` frame nears the 64 KB tungstenite frame limit
/// (T-06-16b, client pre-send check). The server applies its own >16 KiB skip
/// (06-04); this is the belt-and-braces client guard.
const int kClipMaxBytes = 48 * 1024;

/// Whether [text] is too large to Send — over [kClipMaxBytes] UTF-8 bytes.
/// Byte length (not code-unit length) is the faithful proxy for the encoded
/// frame size.
bool clipTextTooLarge(String text) => utf8.encode(text).length > kClipMaxBytes;

/// The outcome of a Send attempt the screen renders as a snackbar/toast.
enum ClipSendResult {
  /// The text was recorded and `clip.set` pushed to the PC.
  sent,

  /// The text exceeded [kClipMaxBytes] and was NOT sent.
  tooLarge,
}

/// The outcome of a Fetch (`clip.get`) reply the screen renders.
enum ClipFetchOutcome {
  /// The PC clipboard text was written to the phone clipboard.
  copied,

  /// The PC clipboard was empty — nothing written.
  empty,
}

/// A single Fetch outcome, identity-tracked by the screen (a fresh instance is
/// published per reply so the screen can show exactly one snackbar even when
/// the value-equal [ClipViewState] does not rebuild — e.g. an empty PC clip).
class ClipFetchEvent {
  /// What happened to the Fetch reply.
  final ClipFetchOutcome outcome;

  /// Creates a fetch event (never `const` — identity distinguishes replies).
  ClipFetchEvent(this.outcome);
}

/// [PrefsKv]-backed clipboard history (key [prefsKey], JSON string list). Non-
/// secret → PrefsKv ONLY (house rule, T-06-17). Cap [maxEntries], most-recent
/// first, existing entries promoted to the head on re-record (D-06).
class HistoryStore {
  /// The prefs key holding the JSON history list.
  static const String prefsKey = 'clip.history';

  /// The last-N cap (D-06).
  static const int maxEntries = 5;

  final PrefsKv _prefs;

  /// Creates a store over an injected [PrefsKv] (fakes in tests).
  HistoryStore({required PrefsKv prefs})
      : _prefs = prefs; // ignore: prefer_initializing_formals

  /// All persisted entries, most-recent first (empty when none or on corrupt
  /// data). Total by construction: a corrupt blob degrades to empty rather than
  /// throwing (device_store posture, T-06-17).
  Future<List<String>> all() async {
    final json = await _prefs.getString(prefsKey);
    if (json == null) return <String>[];
    try {
      final raw = jsonDecode(json) as List;
      return raw.whereType<String>().toList();
    } on Object {
      // Corrupt blob (invalid JSON, wrong shape): degrade to "no history".
      return <String>[];
    }
  }

  /// Records [text] as the most-recent entry and returns the new list. Removes
  /// any existing exact-equal entry first, so a repeat (consecutive dedupe) OR
  /// a reuse tap collapses and moves the entry to the head (D-06); then caps at
  /// [maxEntries].
  Future<List<String>> record(String text) async {
    final list = await all();
    list.removeWhere((e) => e == text); // collapse + promote-to-head (D-06)
    list.insert(0, text);
    if (list.length > maxEntries) {
      list.removeRange(maxEntries, list.length);
    }
    await _prefs.setString(prefsKey, jsonEncode(list));
    return list;
  }
}

/// [PrefsKv]-backed auto-sync toggle (key [prefsKey], bool as `'true'`/`'false'`
/// string). Non-secret → PrefsKv ONLY (house rule, T-06-17). Defaults OFF: an
/// absent key loads `false` (D-03), so a fresh install never auto-syncs until
/// the owner opts in.
class AutoSyncStore {
  /// The prefs key holding the toggle.
  static const String prefsKey = 'clip.autosync';

  final PrefsKv _prefs;

  /// Creates a store over an injected [PrefsKv] (fakes in tests).
  AutoSyncStore({required PrefsKv prefs})
      : _prefs = prefs; // ignore: prefer_initializing_formals

  /// The persisted toggle — `false` when absent (default OFF, D-03) or on any
  /// non-`'true'` value.
  Future<bool> load() async => await _prefs.getString(prefsKey) == 'true';

  /// Persists [on] (`'true'`/`'false'`).
  Future<void> set(bool on) =>
      _prefs.setString(prefsKey, on ? 'true' : 'false');
}

/// The pure PC↔phone auto-sync decision seam (IO-free sibling of
/// [VolumeSliderPolicy]). Owns the single [lastSynced] echo-suppression value
/// and decides — never performs — apply-vs-ignore and resume-vs-skip; the
/// actual clipboard write, history record, and `clip.set` send are injected so
/// the gates unit-test without Flutter or a [ConnectionService].
///
/// Echo suppression (D-05): [lastSynced] tracks the value that most recently
/// crossed in EITHER direction (a PC push we applied, a phone clip we sent, or
/// a value the notifier moved via [noteSynced]). A `clip.changed` push or a
/// resume-read equal to [lastSynced] is the bounce of a value already on both
/// sides and is dropped — no re-apply, no re-send, no loop.
class ClipSyncPolicy {
  /// Writes [text] to the phone clipboard (real: `Clipboard.setData`).
  final Future<void> Function(String text) writeClipboard;

  /// Records [text] to history (real: [HistoryStore.record] via the notifier).
  final Future<void> Function(String text) record;

  /// Sends [text] to the PC (real: `clip.set` over `sendReliable`).
  final void Function(String text) send;

  String? _lastSynced;

  /// The value that most recently crossed (applied or sent), or null. Exposed
  /// for the echo-suppression tests and the notifier's manual-move tracking.
  String? get lastSynced => _lastSynced;

  /// Creates a policy over injected IO seams.
  ClipSyncPolicy({
    required this.writeClipboard,
    required this.record,
    required this.send,
  });

  /// PC→phone: apply an incoming `clip.changed` [snapshotText] IFF auto-sync is
  /// on AND the text is non-null AND it is not an echo of [lastSynced]
  /// (client-gated apply, A4; echo suppression, D-05). Returns whether it
  /// applied. On apply: writes the phone clipboard, records history, and tracks
  /// [lastSynced].
  Future<bool> applyPush(String? snapshotText,
      {required bool autoSyncOn}) async {
    if (!autoSyncOn) return false;
    if (snapshotText == null) return false;
    if (snapshotText == _lastSynced) return false; // echo — already on both
    _lastSynced = snapshotText;
    await writeClipboard(snapshotText);
    await record(snapshotText);
    return true;
  }

  /// phone→PC: on app resume, send [phoneText] to the PC IFF auto-sync is on
  /// AND the text is non-empty AND it is not an echo of [lastSynced] (D-08
  /// resume-only, D-05 echo). Returns whether it sent. On send: pushes
  /// `clip.set`, records history, and tracks [lastSynced].
  Future<bool> syncOnResume(String? phoneText,
      {required bool autoSyncOn}) async {
    if (!autoSyncOn) return false;
    if (phoneText == null || phoneText.isEmpty) return false;
    if (phoneText == _lastSynced) return false; // phone already holds it
    _lastSynced = phoneText;
    send(phoneText);
    await record(phoneText);
    return true;
  }

  /// Records [text] as the last value this device moved (a manual Send, reuse,
  /// or Fetch), so a subsequent server push of that exact value is recognized
  /// as an echo and suppressed (D-05).
  void noteSynced(String text) => _lastSynced = text;
}

/// Immutable, value-equal view of the Clipboard screen state: the persisted
/// history + a connection-gating flag + the auto-sync toggle. Value-equality
/// lets the notifier skip no-op rebuilds on `changes` pings that don't alter
/// the visible state (house pattern — mirrors [VolumeViewState]/[AppsViewState]).
class ClipViewState {
  /// Persisted history, most-recent first (client-side, D-06).
  final List<String> history;

  /// Whether the session is authed (drives the muted/gated control state).
  final bool connected;

  /// Whether auto-sync is on (drives the switch + the apply-vs-ignore gate).
  final bool autoSyncOn;

  /// Creates a view snapshot.
  const ClipViewState({
    required this.history,
    required this.connected,
    this.autoSyncOn = false,
  });

  @override
  bool operator ==(Object other) =>
      other is ClipViewState &&
      other.connected == connected &&
      other.autoSyncOn == autoSyncOn &&
      _listEq(other.history, history);

  @override
  int get hashCode =>
      Object.hash(Object.hashAll(history), connected, autoSyncOn);

  static bool _listEq<T>(List<T> a, List<T> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// Re-snapshots [ClipViewState] on every service `changes` ping and drives the
/// send/fetch/reuse commands. Clones [VolumeNotifier]'s subscribe-and-snapshot
/// shape; adds the D-06 history plumbing and the Fetch-reply consumption.
class ClipNotifier extends Notifier<ClipViewState> {
  StreamSubscription<void>? _sub;
  late final ConnectionService _service;
  late final HistoryStore _store;
  late final AutoSyncStore _autoSyncStore;
  late final ClipSyncPolicy _policy;
  List<String> _history = const [];

  /// The local auto-sync toggle (D-03) — primed from [AutoSyncStore.load] on
  /// build, flipped by [setAutoSync]. Defaults OFF until the async load lands.
  bool _autoSyncOn = false;

  /// True between [fetch] and its reply — while true the next NEW fetch reply
  /// is consumed (written to the phone clipboard + recorded).
  bool _awaitingFetch = false;

  /// Identity of the last reply already handled. A reply frame decodes to a
  /// fresh String instance, so an unrelated `changes` ping (identical reply
  /// reference) is never mistaken for a new Fetch reply.
  Object? _lastSeenReply;

  /// Identity of the last `clip.changed` snapshot already ingested. Each real
  /// push parks a fresh [ClipSnapshot] instance, so identity-tracking applies
  /// each genuine push exactly once (value-level echo is handled by the policy).
  Object? _lastSeenSnapshot;

  ClipFetchEvent? _lastFetchEvent;

  /// The most recent Fetch outcome, or null. The screen identity-tracks this to
  /// show exactly one snackbar per Fetch (even when the value-equal view does
  /// not rebuild, e.g. an empty PC clipboard).
  ClipFetchEvent? get lastFetchEvent => _lastFetchEvent;

  @override
  ClipViewState build() {
    _service = ref.watch(connectionServiceProvider);
    _store = ref.watch(clipHistoryStoreProvider);
    _autoSyncStore = ref.watch(clipAutoSyncStoreProvider);
    _policy = ClipSyncPolicy(
      writeClipboard: (t) => Clipboard.setData(ClipboardData(text: t)),
      record: (t) async {
        _history = await _store.record(t);
      },
      send: (t) => _service.sendReliable(ClipSetMsg(text: t)),
    );
    _lastSeenReply = _service.clipFetchReply; // don't consume a stale reply
    _lastSeenSnapshot = _service.clipSnapshot; // don't apply a stale push
    _sub?.cancel();
    _sub = _service.changes.listen((_) => _onChange());
    ref.onDispose(() {
      _sub?.cancel();
      _sub = null;
    });
    unawaited(_loadState()); // async prime — publishes when loaded
    return _view();
  }

  Future<void> _loadState() async {
    _history = await _store.all();
    _autoSyncOn = await _autoSyncStore.load();
    state = _view();
  }

  void _onChange() {
    final reply = _service.clipFetchReply;
    if (_awaitingFetch && reply != null && !identical(reply, _lastSeenReply)) {
      _lastSeenReply = reply;
      _awaitingFetch = false;
      unawaited(_applyFetchReply(reply)); // publishes state
      return;
    }
    // Live auto-sync (PC→phone): apply each NEW clip.changed push through the
    // client-gated policy (ignored when auto-sync is off, RESEARCH A4).
    final snap = _service.clipSnapshot;
    if (snap != null && !identical(snap, _lastSeenSnapshot)) {
      _lastSeenSnapshot = snap;
      unawaited(_applyPush(snap.text)); // publishes state
      return;
    }
    state = _view();
  }

  Future<void> _applyPush(String text) async {
    await _policy.applyPush(text, autoSyncOn: _autoSyncOn); // records via seam
    state = _view();
  }

  /// Sets the auto-sync toggle (D-03): persists it and republishes the view.
  /// Always available — the switch is a local preference, never connection-gated.
  Future<void> setAutoSync(bool on) async {
    await _autoSyncStore.set(on);
    _autoSyncOn = on;
    state = _view();
  }

  /// phone→PC resume sync (D-08): reads the phone clipboard and — when auto-sync
  /// is on and the value is a genuine new (non-echo) clip — pushes it to the PC.
  /// Called from the screen's [AppLifecycleListener] on `resumed`.
  Future<void> syncOnResume() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    await _policy.syncOnResume(data?.text, autoSyncOn: _autoSyncOn);
    state = _view();
  }

  ClipViewState _view() => ClipViewState(
        history: _history,
        connected: _service.isAuthed,
        autoSyncOn: _autoSyncOn,
      );

  /// Sends [text] to the PC clipboard (`clip.set`, CLIP-01). Refuses (returns
  /// [ClipSendResult.tooLarge], no send) when over the [kClipMaxBytes] hard cap
  /// (T-06-16b); otherwise records it to history (D-06) and pushes reliably.
  Future<ClipSendResult> send(String text) async {
    if (clipTextTooLarge(text)) return ClipSendResult.tooLarge;
    _history = await _store.record(text);
    _policy.noteSynced(text); // a later server echo of this value is suppressed
    state = _view();
    _service.sendReliable(ClipSetMsg(text: text));
    return ClipSendResult.sent;
  }

  /// Pulls the PC clipboard (`clip.get`, CLIP-02). The reply lands as a
  /// `clip.set` frame on a later `changes` ping; [_onChange] then writes it to
  /// the phone clipboard and records it.
  void fetch() {
    _lastSeenReply = _service.clipFetchReply; // baseline: only a NEW reply wins
    _awaitingFetch = true;
    _service.sendReliable(const ClipGetMsg());
  }

  /// Re-pushes a history [entry] to the PC clipboard (`clip.set`, D-06 reuse →
  /// PC) and promotes it to the most-recent history slot.
  Future<void> reuse(String entry) async {
    _history = await _store.record(entry); // move-to-head (D-06)
    _policy.noteSynced(entry); // suppress the server echo of the re-pushed value
    state = _view();
    _service.sendReliable(ClipSetMsg(text: entry));
  }

  Future<void> _applyFetchReply(String reply) async {
    // Set the outcome SYNCHRONOUSLY (before the first await) so the screen's
    // listener — which runs on the same reply `changes` ping, right after this
    // notifier's handler — sees the fresh event and shows exactly one snackbar.
    if (reply.isEmpty) {
      _lastFetchEvent = ClipFetchEvent(ClipFetchOutcome.empty);
      state = _view();
      return;
    }
    _lastFetchEvent = ClipFetchEvent(ClipFetchOutcome.copied);
    state = _view();
    await Clipboard.setData(ClipboardData(text: reply));
    _history = await _store.record(reply);
    _policy.noteSynced(reply); // the fetched value is now on the phone — no echo
    state = _view();
  }
}

/// The clipboard history store over real (non-secret) shared_preferences.
final clipHistoryStoreProvider = Provider<HistoryStore>(
  (ref) => HistoryStore(prefs: SharedPrefsKv()),
);

/// The auto-sync toggle store over real (non-secret) shared_preferences (D-03).
final clipAutoSyncStoreProvider = Provider<AutoSyncStore>(
  (ref) => AutoSyncStore(prefs: SharedPrefsKv()),
);

/// The clipboard view state the Clipboard screen watches (history + gating).
final clipStateProvider =
    NotifierProvider<ClipNotifier, ClipViewState>(ClipNotifier.new);
