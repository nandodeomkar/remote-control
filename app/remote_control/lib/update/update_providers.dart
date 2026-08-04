/// The Updates state machine (D-06/D-07/D-11/D-26): four independent inputs —
/// the release feed, the phone's own installed version, the server's
/// `update.status`, and the live `update.progress` stream — turned into the
/// three row states the Updates screen renders, plus the Settings badge.
///
/// **This file produces no widgets.** It is the layer where the 12-UI-SPEC row
/// state matrix becomes an enumerable, value-equal Dart type, so every one of
/// its states is reachable and assertable before a pixel exists. The screen
/// (12-15) is a rendering of [UpdatesViewState] and owns no update logic of
/// its own.
///
/// Shape: the `bookmarks_store.dart` pattern — a Riverpod 3 unified [Notifier]
/// that subscribes to `ConnectionService.changes`, re-snapshots into a
/// value-equal state, and exposes its commands over the service's reliable
/// send path. Every external effect (feed fetch, download, verify, install,
/// cache, clock) arrives through an overridable provider, so the whole matrix
/// is drivable offline from a test.
///
/// Four rules from the contract are enforced HERE rather than in the copy map,
/// because a state that cannot be constructed cannot be rendered:
///
///   1. `available` is never produced for a version at or below installed, and
///      an unparseable version on either side resolves to `unknownVersion`
///      (D-26, T-12-18). A crafted tag cannot manufacture an Update button.
///   2. The Extension row's `available` is a distinct display-only case with
///      `actionable == false` (D-18) — its action is structurally absent, not
///      conditionally disabled.
///   3. `busy` is swallowed entirely (D-11): it means "your tap arrived while
///      an apply was already running", which the row already shows. It changes
///      nothing on screen, so it is never a row state.
///   4. `downgrade` degrades to `failed(installer)` and the real code goes to
///      the log. An impossible state must degrade to a generic honest message,
///      never to one that implies the user did something.
///
/// And two things this file deliberately does NOT contain: a reconnect timer
/// (D-17 — the existing FSM rides out the socket drop a PC update causes, and
/// the re-check on reconnect is what confirms the new version) and a persisted
/// "installing" flag (RESEARCH Pitfall 7 — the APK install kills this process,
/// so a persisted flag would be read as stuck by the fresh launch that is
/// itself the proof of success).
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../net/connection_providers.dart';
import '../net/connection_service.dart';
import '../settings/app_version.dart';
import 'apk_download.dart';
import 'apk_installer.dart';
import 'release_feed.dart';
import 'update_cache.dart';
import 'version.dart';

// -- Wire vocabularies (D-10 stages, D-11 errors) -----------------------------

/// `update.progress` stage: the server is resolving the feed.
const String kStageChecking = 'checking';

/// `update.progress` stage: the setup exe is being fetched (carries `pct`).
const String kStageDownloading = 'downloading';

/// `update.progress` stage: the sha256 gate is running.
const String kStageVerifying = 'verifying';

/// `update.progress` stage: the installer is running.
const String kStageInstalling = 'installing';

/// `update.progress` stage: the server is coming back up.
const String kStageRestarting = 'restarting';

/// `update.progress` terminal: nothing to do.
const String kStageUpToDate = 'uptodate';

/// `update.progress` terminal: the attempt failed, `error` says why.
const String kStageFailed = 'failed';

/// D-11 error: the bytes never arrived.
const String kErrNetwork = 'network';

/// D-11 error: the bytes arrived and could not be trusted.
const String kErrChecksum = 'checksum';

/// D-11 error: the bytes arrived and could not be stored.
const String kErrDisk = 'disk';

/// D-11 error: the installer did not finish.
const String kErrInstaller = 'installer';

/// D-11 error: the target is at or below the running version. **Impossible
/// through this UI** — see [mapWireError].
const String kErrDowngrade = 'downgrade';

/// D-11 error: the target is no longer what the server resolves as latest.
const String kErrStale = 'stale';

/// D-11 error: an apply was already running. **Swallowed** — see
/// [mapWireError].
const String kErrBusy = 'busy';

/// How many consecutive reconnect attempts count as "the PC never came back"
/// (D-25).
///
/// Read from the EXISTING reconnect FSM's counter
/// ([ConnectionService.reconnectAttempt]) rather than from a timer of this
/// phase's own: D-17 forbids a second reconnect path, and the FSM's backoff
/// ladder (1s, 2s, 4s, 8s, then 10s) means five consecutive failures is
/// roughly twenty-five seconds of a PC that is not answering — long enough
/// that a silent-install-and-relaunch would have completed.
const int kPcReturnAttempts = 5;

// -- The row state ------------------------------------------------------------

/// Every state a component row can be in — the 12-UI-SPEC row state matrix,
/// one enum member per row of that table.
///
/// The enum is the enumerability: a `switch` over it in the widget layer is
/// exhaustive, so a state added here cannot be forgotten by the renderer.
enum UpdateRowKind {
  /// A check is in flight for this row.
  checking,

  /// Installed is the latest published version.
  upToDate,

  /// A strictly newer version exists. Actionable on the App and PC rows only.
  available,

  /// Bytes are arriving; `pct` is present.
  downloading,

  /// The sha256 gate is running.
  verifying,

  /// The installer is running.
  installing,

  /// The PC is restarting into the new build.
  restarting,

  /// A row-scoped apply failure; `error` says which of the closed sentences.
  failed,

  /// The feed check failed — SCREEN-scoped, so all three rows show it and the
  /// single retry lives in the footer (D-22).
  couldNotCheck,

  /// No live authed socket. PC and Extension rows only — the App row is never
  /// gated by connection state.
  serverDisconnected,

  /// The PC predates protoVersion 1.8 and cannot update itself (D-13).
  serverTooOld,

  /// An apply was sent and the PC has not come back (D-25).
  pcDidNotReturn,

  /// The extension has never connected to the server.
  extensionNeverConnected,

  /// The server is current but the extension is not: the reload did not take,
  /// and there is no second attempt (D-18).
  extensionNeedsBrowserRestart,

  /// A version on one side of the comparison does not parse. **Never
  /// `available`** (D-26).
  unknownVersion,
}

/// The closed set of failures that may reach the screen.
///
/// `busy` and `downgrade` are deliberately ABSENT: neither is renderable, so
/// neither can be rendered. No HTTP status, exception class, path, URL or hash
/// is representable here either, which is the whole T-12-06 mitigation — the
/// copy map turns one of these five into one fixed sentence and there is no
/// channel by which anything else could arrive.
enum UpdateFailure {
  /// `Download failed — check your connection.`
  network,

  /// `The download didn't match its signature. Nothing was installed.`
  checksum,

  /// `Not enough space for the download.`
  disk,

  /// `The installer didn't finish. Your PC is still on {installed}.`
  installer,

  /// `That version is no longer the latest. Check again.`
  stale,
}

/// Maps a wire error code (D-11) to the failure the screen may show, or null
/// when the code must not become a row state at all.
///
/// Two codes never surface, for two different reasons:
///
///   * `busy` returns null — it means an apply was already running, which the
///     row is already showing. Surfacing it would blame the user for a race
///     they cannot even provoke (the button is disabled mid-apply).
///   * `downgrade` returns [UpdateFailure.installer] and logs the real code —
///     it is a server-side guard against a condition the `available` rule
///     already prevents this UI from offering, so if it arrives at all,
///     something is wrong that the user did not do.
///
/// An unrecognised code from a future server also degrades to `installer`
/// rather than inventing a sentence: the vocabulary is closed by contract, and
/// an honest generic beats a specific guess.
UpdateFailure? mapWireError(String? code) {
  switch (code) {
    case kErrNetwork:
      return UpdateFailure.network;
    case kErrChecksum:
      return UpdateFailure.checksum;
    case kErrDisk:
      return UpdateFailure.disk;
    case kErrInstaller:
      return UpdateFailure.installer;
    case kErrStale:
      return UpdateFailure.stale;
    case kErrBusy:
      debugPrint('update: swallowing $kErrBusy — an apply is already running');
      return null;
    case kErrDowngrade:
      debugPrint('update: received $kErrDowngrade, which this UI cannot offer '
          '— rendering the generic installer failure');
      return UpdateFailure.installer;
    default:
      debugPrint('update: unrecognised failure code — rendering the generic '
          'installer failure');
      return UpdateFailure.installer;
  }
}

/// One component row's complete visual state — immutable and value-equal, so
/// an unchanged tick rebuilds nothing (T-12-49).
///
/// Constructed only through the named constructors below, one per matrix row.
/// The fields a state does not use stay null, which is what makes two states
/// of the same kind comparable without a per-kind subclass.
final class UpdateRowState {
  /// Which row of the matrix this is.
  final UpdateRowKind kind;

  /// The installed version, verbatim, where the state has one.
  final String? installed;

  /// The latest published version, verbatim, where the state has one.
  final String? latest;

  /// Download size in bytes for an actionable `available` (D-08).
  final int? sizeBytes;

  /// Download percentage for `downloading`.
  final int? pct;

  /// Which of the five renderable failures, for `failed`.
  final UpdateFailure? error;

  /// Whether this row offers an ENABLED action right now.
  ///
  /// Part of the value, not a widget-layer decision, so "the Extension row
  /// never has an enabled action" (D-18) is a fact a test can assert about the
  /// state rather than a property of a widget tree.
  final bool actionable;

  const UpdateRowState._({
    required this.kind,
    this.installed,
    this.latest,
    this.sizeBytes,
    this.pct,
    this.error,
    this.actionable = false,
  });

  /// `Checking…`
  const UpdateRowState.checking() : this._(kind: UpdateRowKind.checking);

  /// `Up to date · {installed}`
  const UpdateRowState.upToDate(String installed)
      : this._(kind: UpdateRowKind.upToDate, installed: installed);

  /// `{installed} → {latest} · {size}` with an enabled `Update` — App and PC
  /// rows only. Only reachable when latest is STRICTLY newer (D-26).
  const UpdateRowState.available({
    required String installed,
    required String latest,
    required int sizeBytes,
  }) : this._(
          kind: UpdateRowKind.available,
          installed: installed,
          latest: latest,
          sizeBytes: sizeBytes,
          actionable: true,
        );

  /// `{installed} → {latest} · updates with your PC` — the Extension row's
  /// display-only variant. No size (it has no download of its own) and no
  /// action, ever (D-18).
  const UpdateRowState.availableNoAction({
    required String installed,
    required String latest,
  }) : this._(
          kind: UpdateRowKind.available,
          installed: installed,
          latest: latest,
        );

  /// `Downloading… {pct}%`
  const UpdateRowState.downloading(int pct)
      : this._(kind: UpdateRowKind.downloading, pct: pct);

  /// `Checking the download…`
  const UpdateRowState.verifying() : this._(kind: UpdateRowKind.verifying);

  /// `Installing…`
  const UpdateRowState.installing() : this._(kind: UpdateRowKind.installing);

  /// `Restarting on your PC…`
  const UpdateRowState.restarting() : this._(kind: UpdateRowKind.restarting);

  /// One of the five closed failure sentences, with `Retry`.
  const UpdateRowState.failed(UpdateFailure error)
      : this._(kind: UpdateRowKind.failed, error: error, actionable: true);

  /// `Couldn't check` — retry lives in the footer, not here (D-22).
  const UpdateRowState.couldNotCheck()
      : this._(kind: UpdateRowKind.couldNotCheck);

  /// `Connect to your PC to check`
  const UpdateRowState.serverDisconnected()
      : this._(kind: UpdateRowKind.serverDisconnected);

  /// `This PC needs one more update by hand before it can update itself`
  const UpdateRowState.serverTooOld()
      : this._(kind: UpdateRowKind.serverTooOld);

  /// `PC didn't come back — start it from the Start Menu`, with `Retry`.
  const UpdateRowState.pcDidNotReturn()
      : this._(kind: UpdateRowKind.pcDidNotReturn, actionable: true);

  /// `Not connected — open your browser`
  const UpdateRowState.extensionNeverConnected()
      : this._(kind: UpdateRowKind.extensionNeverConnected);

  /// `Restart your browser to finish updating`
  const UpdateRowState.extensionNeedsBrowserRestart()
      : this._(kind: UpdateRowKind.extensionNeedsBrowserRestart);

  /// `Version unknown` — the answer to every comparison that cannot be made.
  const UpdateRowState.unknownVersion()
      : this._(kind: UpdateRowKind.unknownVersion);

  @override
  bool operator ==(Object other) =>
      other is UpdateRowState &&
      other.kind == kind &&
      other.installed == installed &&
      other.latest == latest &&
      other.sizeBytes == sizeBytes &&
      other.pct == pct &&
      other.error == error &&
      other.actionable == actionable;

  @override
  int get hashCode =>
      Object.hash(kind, installed, latest, sizeBytes, pct, error, actionable);

  @override
  String toString() => 'UpdateRowState(${kind.name}'
      '${installed == null ? '' : ', installed: $installed'}'
      '${latest == null ? '' : ', latest: $latest'}'
      '${pct == null ? '' : ', pct: $pct'}'
      '${error == null ? '' : ', error: ${error!.name}'}'
      '${actionable ? ', actionable' : ''})';
}

// -- The footer ---------------------------------------------------------------

/// The four states of the check footer (12-UI-SPEC Component 2).
enum CheckFooterKind {
  /// `Not checked yet.` — no successful check has ever been recorded.
  neverChecked,

  /// `Last checked {ago}.`
  ok,

  /// `Checking…` — reached by a TAP only; the quiet launch check never
  /// produces this (D-07).
  checking,

  /// `Couldn't check for updates.` with the single `Retry` (D-22).
  failed,
}

/// The footer's complete state — value-equal.
final class CheckFooterState {
  /// Which of the four.
  final CheckFooterKind kind;

  /// When the last SUCCESSFUL check happened, for [CheckFooterKind.ok].
  final DateTime? lastCheckedAt;

  const CheckFooterState._(this.kind, [this.lastCheckedAt]);

  /// `Not checked yet.`
  const CheckFooterState.neverChecked()
      : this._(CheckFooterKind.neverChecked);

  /// `Last checked {ago}.`
  const CheckFooterState.ok(DateTime lastCheckedAt)
      : this._(CheckFooterKind.ok, lastCheckedAt);

  /// `Checking…`
  const CheckFooterState.checking() : this._(CheckFooterKind.checking);

  /// `Couldn't check for updates.`
  const CheckFooterState.failed() : this._(CheckFooterKind.failed);

  @override
  bool operator ==(Object other) =>
      other is CheckFooterState &&
      other.kind == kind &&
      other.lastCheckedAt == lastCheckedAt;

  @override
  int get hashCode => Object.hash(kind, lastCheckedAt);

  @override
  String toString() => 'CheckFooterState(${kind.name}, $lastCheckedAt)';
}

// -- The screen state ---------------------------------------------------------

/// Everything the Updates screen renders, in one value-equal snapshot.
final class UpdatesViewState {
  /// `This phone` — never gated by connection state.
  final UpdateRowState app;

  /// `Windows PC`
  final UpdateRowState pc;

  /// `Browser extension` — never actionable.
  final UpdateRowState extension;

  /// The check footer.
  final CheckFooterState footer;

  /// Whether the Settings badge dot is lit. Same truth rule, same source as
  /// [updateBadgeProvider] — see [badgeLit].
  final bool badge;

  /// Creates a view snapshot.
  const UpdatesViewState({
    required this.app,
    required this.pc,
    required this.extension,
    required this.footer,
    required this.badge,
  });

  /// The state before anything is known: three rows that cannot compare
  /// anything yet, a never-checked footer, no badge.
  const UpdatesViewState.initial()
      : app = const UpdateRowState.unknownVersion(),
        pc = const UpdateRowState.unknownVersion(),
        extension = const UpdateRowState.unknownVersion(),
        footer = const CheckFooterState.neverChecked(),
        badge = false;

  @override
  bool operator ==(Object other) =>
      other is UpdatesViewState &&
      other.app == app &&
      other.pc == pc &&
      other.extension == extension &&
      other.footer == footer &&
      other.badge == badge;

  @override
  int get hashCode => Object.hash(app, pc, extension, footer, badge);

  @override
  String toString() =>
      'UpdatesViewState(app: $app, pc: $pc, ext: $extension, $footer, '
      'badge: $badge)';
}

/// What [UpdatesNotifier.updateApp] did.
enum UpdateAppResult {
  /// The download started; the App row is now `downloading`.
  started,

  /// The "install unknown apps" grant is missing — the caller opens the
  /// explainer sheet (D-19) and the row stays on `available`. Nothing was
  /// downloaded.
  needsInstallGrant,

  /// There is no resolved APK asset to install. Nothing happened.
  unavailable,
}

// -- Injectable seams ---------------------------------------------------------

/// Resolves the latest release, or null on ANY failure (never throws).
typedef ReleaseFetcher = Future<Release?> Function();

/// Streams an asset to disk, returning its path or null on failure.
typedef ApkDownloader = Future<String?> Function(
  ReleaseAsset asset, {
  required void Function(int received, int total) onProgress,
  void Function(DownloadError code)? onError,
});

/// Verifies a downloaded file against its published digest, deleting it on
/// any failure.
typedef ApkVerifier = Future<bool> Function(File file, String? expectedHex);

/// The feed seam. Overridden in tests so no request is ever made.
final releaseFetcherProvider =
    Provider<ReleaseFetcher>((ref) => () => fetchLatest());

/// The download seam.
final apkDownloaderProvider = Provider<ApkDownloader>((ref) => downloadApk);

/// The sha256 gate seam. Kept separate from the download so the gate is
/// visible at the call site rather than buried in a success path.
final apkVerifierProvider = Provider<ApkVerifier>((ref) => verifyOrDelete);

/// The `PackageInstaller` channel seam.
final apkInstallerProvider = Provider<ApkInstaller>((ref) => ApkInstaller());

/// The clock, injected so the 24h cadence and the `Last checked` line are
/// testable without waiting.
final updateClockProvider = Provider<DateTime Function()>((ref) => DateTime.now);

// -- The cache, in memory -----------------------------------------------------

/// The last successful check, held in memory and mirrored to
/// `shared_preferences`.
///
/// One in-memory copy shared by the rows and the badge, so the Settings badge
/// and the Updates screen can never disagree about what the last check said.
/// The initial value is [UpdateCacheState.neverChecked] and the real entry
/// arrives asynchronously — every read degrades, so a slow or failed load
/// costs one extra check and nothing else.
class UpdateCacheNotifier extends Notifier<UpdateCacheState> {
  bool _disposed = false;

  @override
  UpdateCacheState build() {
    _disposed = false;
    ref.onDispose(() => _disposed = true);
    final store = ref.watch(updateCacheStoreProvider);
    unawaited(store.load().then((loaded) {
      if (_disposed) return;
      state = loaded;
    }));
    return const UpdateCacheState.neverChecked();
  }

  /// Records a SUCCESSFUL check of [version] at [at].
  ///
  /// Only ever called on success: overwriting a good entry with a failure
  /// would blank the `Last checked` line, which is precisely the visible
  /// interruption D-07 and D-22 forbid.
  Future<void> record({required String version, required DateTime at}) async {
    final next = UpdateCacheState(
      lastCheckAtMillis: at.millisecondsSinceEpoch,
      lastSeenVersion: version,
    );
    if (!_disposed) state = next;
    await ref.read(updateCacheStoreProvider).save(next);
  }
}

/// The in-memory update cache both the rows and the badge read.
final updateCacheStateProvider =
    NotifierProvider<UpdateCacheNotifier, UpdateCacheState>(
        UpdateCacheNotifier.new);

// -- The badge ----------------------------------------------------------------

/// The badge truth rule, as one pure function (12-UI-SPEC Component 4).
///
/// > The dot lights when, and only when, at least one component whose
/// > installed version is KNOWN is strictly behind the cached latest version.
///
/// [isNewer] returns false whenever either side fails to parse, so every
/// "unknown" case falls out of the rule rather than needing its own branch:
/// an absent cache, an unparseable tag, a PC that has not answered
/// (`serverDisconnected`, `serverTooOld`, and every `couldNotCheck`) and an
/// extension that has never connected all leave the dot dark.
///
/// **A cache older than the TTL still lights the dot.** A version comparison
/// does not expire: if the phone knew an update existed yesterday and has been
/// offline since, that is still true. `update_cache.dart` states the same rule
/// from the other side — a failed check "leaves the previous good entry
/// untouched … the badge keeps its last known answer instead of blanking".
/// Staleness drives WHEN to check again, never WHAT to display.
bool badgeLit({
  required String? cachedLatest,
  required String? appInstalled,
  required UpdateStatusSnapshot? status,
}) {
  final latest = cachedLatest;
  if (latest == null) return false;
  if (appInstalled != null && isNewer(candidate: latest, installed: appInstalled)) {
    return true;
  }
  if (status == null) return false;
  if (isNewer(candidate: latest, installed: status.serverVersion)) return true;
  final ext = status.extVersion;
  return ext != null && isNewer(candidate: latest, installed: ext);
}

/// The Settings badge dot (D-06).
///
/// Reads the CACHE, not a live feed, so it is correct offline and before the
/// Updates screen has ever been opened — the phone's own version is always
/// knowable without a socket. There is no dismiss gesture and no "seen" flag:
/// a badge the user can silence while the condition holds is a lie, so this
/// clears the frame the last out-of-date known component reaches `upToDate`
/// and not one moment sooner.
final updateBadgeProvider = Provider<bool>((ref) {
  final cache = ref.watch(updateCacheStateProvider);
  final installed = ref.watch(appBareVersionProvider).value;
  final wire = ref.watch(updateWireProvider);
  return badgeLit(
    cachedLatest: cache.lastSeenVersion,
    appInstalled: installed,
    status: wire.status,
  );
});

// -- The wire snapshot --------------------------------------------------------

/// Re-snapshots [ConnectionService.updateSnapshot] on every `changes` ping
/// (the `bookmarks_store.dart` subscribe-and-re-snapshot pattern).
///
/// Split out of [UpdatesNotifier] so the badge can watch the wire without
/// bringing the whole Updates screen state — and therefore its check
/// commands — to life just because the Settings screen was opened.
class UpdateWireNotifier extends Notifier<UpdateSnapshot> {
  StreamSubscription<void>? _sub;

  @override
  UpdateSnapshot build() {
    final service = ref.watch(connectionServiceProvider);
    _sub?.cancel();
    _sub = service.changes.listen((_) => state = service.updateSnapshot);
    ref.onDispose(() {
      _sub?.cancel();
      _sub = null;
    });
    return service.updateSnapshot;
  }
}

/// The session's update snapshot, value-equal.
final updateWireProvider =
    NotifierProvider<UpdateWireNotifier, UpdateSnapshot>(
        UpdateWireNotifier.new);

// -- The notifier -------------------------------------------------------------

/// The App row's local install phase. Local because an APK install is entirely
/// phone-side: there is no wire message for it.
enum _AppPhase { idle, downloading, verifying, installing, failed }

/// Derives the three row states, the footer and the badge, and owns the four
/// commands the Updates screen fires.
class UpdatesNotifier extends Notifier<UpdatesViewState> {
  ConnectionService? _service;
  StreamSubscription<void>? _sub;
  StreamSubscription<InstallEvent>? _installSub;
  bool _disposed = false;

  // -- Session state (survives `changes` pings; never persisted) -------------

  /// The live feed result. Null until a check succeeds THIS session — the
  /// cached version is deliberately not used here, because the `available`
  /// subtitle needs a download size and the cache stores none.
  Release? _release;

  /// The last check failed (D-22). Screen-scoped: all three rows read
  /// `couldNotCheck` and the single retry lives in the footer.
  bool _feedFailed = false;

  /// A TAPPED check is in flight. The quiet launch check never sets this.
  bool _checking = false;

  /// The last wire progress this notifier ACCEPTED — `busy` never gets here.
  UpdateProgressSnapshot? _pcProgress;

  /// The last wire progress this notifier has already looked at, accepted or
  /// not, so a repeat is not re-processed.
  UpdateProgressSnapshot? _seenProgress;

  /// An `update.apply` was sent and the PC has not confirmed a new version.
  bool _pcApplyOutstanding = false;

  /// Previous authed-ness, for detecting the reconnect that confirms a PC
  /// update (D-17).
  bool _wasAuthed = false;

  _AppPhase _appPhase = _AppPhase.idle;
  int _appPct = 0;
  UpdateFailure? _appFailure;

  @override
  UpdatesViewState build() {
    _disposed = false;
    final service = ref.watch(connectionServiceProvider);
    _service = service;
    _wasAuthed = service.isAuthed;

    _sub?.cancel();
    _sub = service.changes.listen((_) => _onChange());

    _installSub?.cancel();
    _installSub = ref.read(apkInstallerProvider).outcomes.listen(_onInstall);

    // Listened rather than watched: a rebuild of this notifier would discard
    // the in-flight download, the feed result and the apply bookkeeping above,
    // none of which is recoverable. These two only ever need to re-derive.
    ref.listen(appBareVersionProvider, (_, _) => _publish());
    ref.listen(updateCacheStateProvider, (_, _) => _publish());

    ref.onDispose(() {
      _disposed = true;
      _sub?.cancel();
      _sub = null;
      _installSub?.cancel();
      _installSub = null;
    });

    return _view();
  }

  // -- Derivation -------------------------------------------------------------

  void _publish() {
    if (_disposed) return;
    state = _view();
  }

  UpdatesViewState _view() {
    final service = _service;
    final wire = service?.updateSnapshot ?? UpdateSnapshot.empty;
    final connected = service?.chipStatus == ChipStatus.connected;
    final installedAsync = ref.read(appBareVersionProvider);
    final cache = ref.read(updateCacheStateProvider);
    final release = _release;

    return UpdatesViewState(
      app: _appRow(installedAsync, release),
      pc: _pcRow(wire, connected, release),
      extension: _extensionRow(wire, connected, release?.version),
      footer: _footer(cache),
      badge: badgeLit(
        cachedLatest: cache.lastSeenVersion,
        appInstalled: installedAsync.value,
        status: wire.status,
      ),
    );
  }

  /// The comparison every row ends in. **The ONLY producer of `available`.**
  ///
  /// An unparseable version on either side, a missing latest, or a release
  /// with no matching asset all resolve to `unknownVersion` — never to an
  /// update offer (D-26, T-12-18).
  UpdateRowState _compare({
    required String installed,
    required String? latest,
    required ReleaseAsset? asset,
  }) {
    if (SemVer.tryParse(installed) == null) {
      return const UpdateRowState.unknownVersion();
    }
    if (latest == null || SemVer.tryParse(latest) == null) {
      return const UpdateRowState.unknownVersion();
    }
    if (!isNewer(candidate: latest, installed: installed)) {
      return UpdateRowState.upToDate(installed);
    }
    if (asset == null) {
      // A release that published no artifact for this component cannot be
      // offered: there would be nothing to download, and D-08 promises a size
      // before the download starts.
      return const UpdateRowState.unknownVersion();
    }
    return UpdateRowState.available(
      installed: installed,
      latest: latest,
      sizeBytes: asset.sizeBytes,
    );
  }

  /// `This phone`. **Never gated by connection state** — its version comes
  /// from the package and its feed comes from the internet, so it works with
  /// no PC in the room. That asymmetry is correct and must not be harmonised.
  UpdateRowState _appRow(AsyncValue<String> installedAsync, Release? release) {
    switch (_appPhase) {
      case _AppPhase.downloading:
        return UpdateRowState.downloading(_appPct);
      case _AppPhase.verifying:
        return const UpdateRowState.verifying();
      case _AppPhase.installing:
        // The last observable state before the process is replaced. Nothing is
        // persisted here: a fresh launch reading `upToDate` from a new
        // package_info_plus value IS the success signal.
        return const UpdateRowState.installing();
      case _AppPhase.failed:
        return UpdateRowState.failed(_appFailure ?? UpdateFailure.installer);
      case _AppPhase.idle:
        break;
    }
    if (_checking) return const UpdateRowState.checking();
    if (_feedFailed) return const UpdateRowState.couldNotCheck();

    final installed = installedAsync.value;
    if (installed == null) {
      // Still resolving the package is a check in progress; a hard failure is
      // a version that will never be known this run.
      return installedAsync.hasError
          ? const UpdateRowState.unknownVersion()
          : const UpdateRowState.checking();
    }
    return _compare(
      installed: installed,
      latest: release?.version,
      asset: release == null ? null : assetWithPrefix(release, kApkAssetPrefix),
    );
  }

  /// `Windows PC`.
  UpdateRowState _pcRow(
    UpdateSnapshot wire,
    bool connected,
    Release? release,
  ) {
    final progress = _pcProgress;
    if (progress != null) {
      switch (progress.stage) {
        case kStageChecking:
          return const UpdateRowState.checking();
        case kStageDownloading:
          return UpdateRowState.downloading(progress.pct ?? 0);
        case kStageVerifying:
          return const UpdateRowState.verifying();
        case kStageInstalling:
          return const UpdateRowState.installing();
        case kStageRestarting:
          return const UpdateRowState.restarting();
        case kStageFailed:
          final failure = mapWireError(progress.error);
          if (failure != null) return UpdateRowState.failed(failure);
      }
    }
    if (_pcApplyOutstanding && !connected) {
      // D-17/D-25: the EXISTING reconnect FSM is the only mechanism here. Its
      // own attempt counter is what "the PC never came back" looks like — this
      // phase starts no timer of its own.
      final attempts = _service?.reconnectAttempt ?? 0;
      return attempts >= kPcReturnAttempts
          ? const UpdateRowState.pcDidNotReturn()
          : const UpdateRowState.restarting();
    }
    if (wire.serverTooOld) return const UpdateRowState.serverTooOld();
    if (!connected) return const UpdateRowState.serverDisconnected();
    if (_checking) return const UpdateRowState.checking();
    if (_feedFailed) return const UpdateRowState.couldNotCheck();

    final status = wire.status;
    if (status == null) return const UpdateRowState.unknownVersion();

    final last = status.lastUpdate;
    if (last != null && !last.ok) {
      final failure = mapWireError(last.error);
      if (failure != null) return UpdateRowState.failed(failure);
    }
    return _compare(
      installed: status.serverVersion,
      latest: release?.version,
      asset:
          release == null ? null : assetWithPrefix(release, kSetupAssetPrefix),
    );
  }

  /// `Browser extension` — no enabled action in ANY state (D-18).
  UpdateRowState _extensionRow(
    UpdateSnapshot wire,
    bool connected,
    String? latest,
  ) {
    // A 1.7 server cannot report extVersion through a family it does not know,
    // so both PC-side rows read the same sentence — the cause reads once.
    if (wire.serverTooOld) return const UpdateRowState.serverTooOld();
    if (!connected) return const UpdateRowState.serverDisconnected();
    if (_checking) return const UpdateRowState.checking();
    if (_feedFailed) return const UpdateRowState.couldNotCheck();

    final status = wire.status;
    if (status == null) return const UpdateRowState.unknownVersion();

    final installed = status.extVersion;
    if (installed == null) {
      return status.extConnected
          ? const UpdateRowState.unknownVersion()
          : const UpdateRowState.extensionNeverConnected();
    }
    if (latest == null ||
        SemVer.tryParse(latest) == null ||
        SemVer.tryParse(installed) == null) {
      return const UpdateRowState.unknownVersion();
    }
    if (!isNewer(candidate: latest, installed: installed)) {
      return UpdateRowState.upToDate(installed);
    }
    // The extension rides the PC installer (D-18). If the PC is ALREADY on the
    // latest version and the extension still is not, the one `ext.reload`
    // attempt did not take and there is no second one.
    final serverKnown = SemVer.tryParse(status.serverVersion) != null;
    if (serverKnown &&
        !isNewer(candidate: latest, installed: status.serverVersion)) {
      return const UpdateRowState.extensionNeedsBrowserRestart();
    }
    return UpdateRowState.availableNoAction(
      installed: installed,
      latest: latest,
    );
  }

  CheckFooterState _footer(UpdateCacheState cache) {
    if (_checking) return const CheckFooterState.checking();
    if (_feedFailed) return const CheckFooterState.failed();
    final at = cache.lastCheckAt;
    if (at == null) return const CheckFooterState.neverChecked();
    return CheckFooterState.ok(at);
  }

  // -- Wire absorption --------------------------------------------------------

  void _onChange() {
    final service = _service;
    if (service == null) return;
    final progress = service.updateSnapshot.progress;

    if (progress == null) {
      // The session (and with it the snapshot) went away.
      _seenProgress = null;
      _pcProgress = null;
    } else if (progress != _seenProgress) {
      _seenProgress = progress;
      _absorb(progress);
    }

    final authed = service.isAuthed;
    if (authed && !_wasAuthed && _pcApplyOutstanding) {
      // D-17: reconnection IS the success signal. The re-check that confirms
      // the new version is the only thing this phase does about it — no timer,
      // no bespoke "waiting for your PC" state.
      _pcApplyOutstanding = false;
      _pcProgress = null;
      service.sendUpdateCheck();
    }
    _wasAuthed = authed;

    _publish();
  }

  void _absorb(UpdateProgressSnapshot progress) {
    switch (progress.stage) {
      case kStageFailed:
        if (progress.error == kErrBusy) {
          // D-11 rule 7: the tap arrived while an apply was already running,
          // which the row is already showing. Log it, change NOTHING.
          debugPrint('update: pc reported $kErrBusy — leaving the row alone');
          return;
        }
        _pcProgress = progress;
        _pcApplyOutstanding = false;
      case kStageUpToDate:
        _pcProgress = null;
        _pcApplyOutstanding = false;
      default:
        _pcProgress = progress;
    }
  }

  void _onInstall(InstallEvent event) {
    switch (event.outcome) {
      case InstallOutcome.pendingUserAction:
        // The system dialog is up; the row stays `installing`.
        break;
      case InstallOutcome.declined:
        // D-19: back to `available`, with no error copy, no toast and no
        // retry loop. The user said no; that is not a failure.
        _appPhase = _AppPhase.idle;
        _appFailure = null;
      case InstallOutcome.failure:
        _appPhase = _AppPhase.failed;
        _appFailure = UpdateFailure.installer;
    }
    _publish();
  }

  // -- Commands ---------------------------------------------------------------

  /// The footer's `Check for updates` / `Retry` (D-07). VISIBLE: the footer
  /// and all three rows read `Checking…` while it runs.
  Future<void> check() async {
    if (_checking) return;
    _checking = true;
    _feedFailed = false;
    _publish();

    final service = _service;
    if (service != null && service.isAuthed) service.sendUpdateCheck();

    final release = await ref.read(releaseFetcherProvider)();
    _checking = false;
    if (release == null) {
      // D-22: one HTTP failure is screen-scoped. The cache is NOT touched, so
      // the badge keeps its last known answer.
      _feedFailed = true;
      _publish();
      return;
    }
    _release = release;
    _feedFailed = false;
    _publish();
    if (_disposed) return;
    await ref.read(updateCacheStateProvider.notifier).record(
          version: release.version,
          at: ref.read(updateClockProvider)(),
        );
  }

  /// The D-07 quiet launch check: at most once per 24 hours, and INVISIBLE.
  ///
  /// It never sets the footer to `Checking…`, never moves a row, and on
  /// failure leaves the previous cached result and its timestamp exactly where
  /// they were. A background check that animates the screen is an
  /// interruption; a background check that blanks `Last checked` is worse.
  Future<void> quietLaunchCheck() async {
    final cache = ref.read(updateCacheStateProvider);
    if (!isStale(cache, now: ref.read(updateClockProvider)())) return;

    final release = await ref.read(releaseFetcherProvider)();
    if (release == null) return; // silent, by contract
    if (_disposed) return;
    _release = release;
    _publish();
    await ref.read(updateCacheStateProvider.notifier).record(
          version: release.version,
          at: ref.read(updateClockProvider)(),
        );
  }

  /// Called when the Updates screen mounts: check only if this session has no
  /// feed result yet. A screen that already has one renders it instantly and
  /// spends nothing of the 60/hour anonymous budget.
  void ensureChecked() {
    if (_release == null && !_checking && !_feedFailed) unawaited(check());
  }

  /// The App row's `Update` (D-19): grant check, download, verify, install.
  ///
  /// Returns [UpdateAppResult.needsInstallGrant] WITHOUT downloading anything
  /// when the "install unknown apps" grant is missing — the caller opens the
  /// explainer sheet and the row stays on `available`.
  Future<UpdateAppResult> updateApp() async {
    final release = _release;
    if (release == null) return UpdateAppResult.unavailable;
    final asset = assetWithPrefix(release, kApkAssetPrefix);
    if (asset == null) return UpdateAppResult.unavailable;

    final installer = ref.read(apkInstallerProvider);
    if (!await installer.canInstall()) {
      return UpdateAppResult.needsInstallGrant;
    }

    _appPhase = _AppPhase.downloading;
    _appPct = 0;
    _appFailure = null;
    _publish();

    DownloadError? failure;
    final path = await ref.read(apkDownloaderProvider)(
      asset,
      onProgress: (received, total) {
        if (total <= 0) return;
        final pct = (received * 100 ~/ total).clamp(0, 100);
        if (pct == _appPct) return;
        _appPct = pct;
        if (_appPhase == _AppPhase.downloading) _publish();
      },
      onError: (code) => failure = code,
    );
    if (_disposed) return UpdateAppResult.started;
    if (path == null) {
      _appPhase = _AppPhase.failed;
      _appFailure = switch (failure) {
        DownloadError.disk => UpdateFailure.disk,
        DownloadError.checksum => UpdateFailure.checksum,
        _ => UpdateFailure.network,
      };
      _publish();
      return UpdateAppResult.started;
    }

    _appPhase = _AppPhase.verifying;
    _publish();
    final verified = await ref.read(apkVerifierProvider)(
      File(path),
      asset.sha256,
    );
    if (_disposed) return UpdateAppResult.started;
    if (!verified) {
      // verifyOrDelete has already removed the file — a null digest is a hard
      // refusal (D-15), never permission to skip the gate.
      _appPhase = _AppPhase.failed;
      _appFailure = UpdateFailure.checksum;
      _publish();
      return UpdateAppResult.started;
    }

    _appPhase = _AppPhase.installing;
    _publish();
    await installer.install(path);
    return UpdateAppResult.started;
  }

  /// The PC row's `Update`: `update.apply {target}` and nothing else (D-14).
  ///
  /// Takes a bare version string. There is no second parameter, no options
  /// object and no place to pass a URL — the server resolves its own asset.
  void updatePc(String target) {
    _pcApplyOutstanding = true;
    _pcProgress = null;
    _seenProgress = null;
    _service?.sendUpdateApply(target);
    _publish();
  }

  /// The PC row's `Retry` after `pcDidNotReturn`: ask the existing reconnect
  /// FSM to try now. Deliberately not a new dial path of this phase's own.
  void retryPcReturn() {
    _service?.retryNow();
    _publish();
  }
}

/// The Updates screen's view state (12-15 renders this and nothing else).
final updatesStateProvider =
    NotifierProvider<UpdatesNotifier, UpdatesViewState>(UpdatesNotifier.new);
