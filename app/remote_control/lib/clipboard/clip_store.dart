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
/// The auto-sync toggle and the incoming `clip.changed` apply-vs-ignore gate
/// are DEFERRED to 06-06 — this plan ships the manual send/fetch/history slice.
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

/// Immutable, value-equal view of the Clipboard screen state: the persisted
/// history + a connection-gating flag. Value-equality lets the notifier skip
/// no-op rebuilds on `changes` pings that don't alter the visible state (house
/// pattern — mirrors [VolumeViewState]/[AppsViewState]).
class ClipViewState {
  /// Persisted history, most-recent first (client-side, D-06).
  final List<String> history;

  /// Whether the session is authed (drives the muted/gated control state).
  final bool connected;

  /// Creates a view snapshot.
  const ClipViewState({required this.history, required this.connected});

  @override
  bool operator ==(Object other) =>
      other is ClipViewState &&
      other.connected == connected &&
      _listEq(other.history, history);

  @override
  int get hashCode => Object.hash(Object.hashAll(history), connected);

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
  List<String> _history = const [];

  /// True between [fetch] and its reply — while true the next NEW fetch reply
  /// is consumed (written to the phone clipboard + recorded).
  bool _awaitingFetch = false;

  /// Identity of the last reply already handled. A reply frame decodes to a
  /// fresh String instance, so an unrelated `changes` ping (identical reply
  /// reference) is never mistaken for a new Fetch reply.
  Object? _lastSeenReply;

  ClipFetchEvent? _lastFetchEvent;

  /// The most recent Fetch outcome, or null. The screen identity-tracks this to
  /// show exactly one snackbar per Fetch (even when the value-equal view does
  /// not rebuild, e.g. an empty PC clipboard).
  ClipFetchEvent? get lastFetchEvent => _lastFetchEvent;

  @override
  ClipViewState build() {
    _service = ref.watch(connectionServiceProvider);
    _store = ref.watch(clipHistoryStoreProvider);
    _lastSeenReply = _service.clipFetchReply; // don't consume a stale reply
    _sub?.cancel();
    _sub = _service.changes.listen((_) => _onChange());
    ref.onDispose(() {
      _sub?.cancel();
      _sub = null;
    });
    unawaited(_loadHistory()); // async prime — publishes when loaded
    return _view();
  }

  Future<void> _loadHistory() async {
    _history = await _store.all();
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
    state = _view();
  }

  ClipViewState _view() =>
      ClipViewState(history: _history, connected: _service.isAuthed);

  /// Sends [text] to the PC clipboard (`clip.set`, CLIP-01). Refuses (returns
  /// [ClipSendResult.tooLarge], no send) when over the [kClipMaxBytes] hard cap
  /// (T-06-16b); otherwise records it to history (D-06) and pushes reliably.
  Future<ClipSendResult> send(String text) async {
    if (clipTextTooLarge(text)) return ClipSendResult.tooLarge;
    _history = await _store.record(text);
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
    state = _view();
    _service.sendReliable(ClipSetMsg(text: entry));
  }

  Future<void> _applyFetchReply(String reply) async {
    if (reply.isEmpty) {
      _lastFetchEvent = ClipFetchEvent(ClipFetchOutcome.empty);
    } else {
      await Clipboard.setData(ClipboardData(text: reply));
      _history = await _store.record(reply);
      _lastFetchEvent = ClipFetchEvent(ClipFetchOutcome.copied);
    }
    state = _view();
  }
}

/// The clipboard history store over real (non-secret) shared_preferences.
final clipHistoryStoreProvider = Provider<HistoryStore>(
  (ref) => HistoryStore(prefs: SharedPrefsKv()),
);

/// The clipboard view state the Clipboard screen watches (history + gating).
final clipStateProvider =
    NotifierProvider<ClipNotifier, ClipViewState>(ClipNotifier.new);
