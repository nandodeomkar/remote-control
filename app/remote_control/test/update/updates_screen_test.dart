// Task 3 (12-15) — the Updates screen, driven across the whole state matrix.
//
// This file is the executable form of the 12-UI-SPEC "Row state matrix" and
// "Trailing slot" table. Every row of the matrix is pumped through the real
// widget tree with `updatesStateProvider` overridden by a stub notifier, so the
// screen renders offline: no feed request, no socket, no platform channel and
// no download. 12-14's `update_providers_test.dart` proves which states the
// machine can PRODUCE; this file proves the screen RENDERS each one, which is
// the SC3 promise ("renders every failure state without breaking the screen").
//
// Three disciplines borrowed from the shipped suite:
//
//   * the `browser_screen_test` seam — a `ConnectionService` subclass over fake
//     KV with an overridable `chipStatus`, so no socket is ever dialled;
//   * `_unmount` after every pump — `ConnectionHeaderChip` runs a 500ms
//     `Timer.periodic`, so a test that leaves the screen mounted trips the
//     pending-timer check at teardown;
//   * NO `pumpAndSettle` anywhere — that same periodic setState schedules a
//     frame forever, so settling never terminates. Every wait here is an
//     explicit `pump` with a duration.
//
// One reconciliation, recorded so it does not read as a gap: the matrix lists
// `checking` as "applies to: all" with a busy spinner, while the trailing-slot
// table says the Empty slot is used "always on the Extension row". The second
// rule is the more specific one and is what `UpdateRow.neverActs` implements —
// the Extension row's trailing slot is empty in EVERY state, spinner included.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:remote_control/net/connection_providers.dart';
import 'package:remote_control/net/connection_service.dart';
import 'package:remote_control/store/device_store.dart';
import 'package:remote_control/theme/tokens.dart';
import 'package:remote_control/update/apk_installer.dart';
import 'package:remote_control/update/update_format.dart';
import 'package:remote_control/update/update_providers.dart';
import 'package:remote_control/update/updates_screen.dart';

// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------

class _FakeSecureKv implements SecureKv {
  final Map<String, String> backing = {};

  @override
  Future<String?> read(String key) async => backing[key];

  @override
  Future<void> write(String key, String value) async => backing[key] = value;

  @override
  Future<void> delete(String key) async => backing.remove(key);
}

class _FakePrefsKv implements PrefsKv {
  final Map<String, String> backing = {};

  @override
  Future<String?> getString(String key) async => backing[key];

  @override
  Future<void> setString(String key, String value) async {
    backing[key] = value;
  }
}

/// The `browser_screen_test` recording seam: a real [ConnectionService] over
/// fake storage with a settable chip status. Never dials, never sends.
class _FakeService extends ConnectionService {
  _FakeService({this.chip = ChipStatus.connected})
      : super(
          store: DeviceStore(secure: _FakeSecureKv(), prefs: _FakePrefsKv()),
        );

  ChipStatus chip;

  @override
  ChipStatus get chipStatus => chip;

  @override
  bool get isAuthed => chip == ChipStatus.connected;
}

/// The `PackageInstaller` channel, faked — only the sheet's CTA reaches it.
class _FakeInstaller extends ApkInstaller {
  final StreamController<InstallEvent> _out =
      StreamController<InstallEvent>.broadcast();

  int openPermissionCalls = 0;

  @override
  Stream<InstallEvent> get outcomes => _out.stream;

  @override
  Future<bool> canInstall() async => true;

  @override
  Future<void> openInstallPermission() async => openPermissionCalls++;
}

/// The screen's ONLY input: a fixed [UpdatesViewState] plus a recorder for the
/// four commands. `build` is overridden whole, so none of the real notifier's
/// wiring (connection subscription, installer stream, feed fetch) ever runs.
class _StubUpdates extends UpdatesNotifier {
  _StubUpdates(this.view, {this.appResult = UpdateAppResult.started});

  final UpdatesViewState view;

  /// What [updateApp] resolves to — `needsInstallGrant` drives the D-19 sheet.
  final UpdateAppResult appResult;

  int ensureCheckedCalls = 0;
  int checkCalls = 0;
  int updateAppCalls = 0;
  int retryPcCalls = 0;
  final List<String> pcTargets = <String>[];

  @override
  UpdatesViewState build() => view;

  @override
  void ensureChecked() => ensureCheckedCalls++;

  @override
  Future<void> check() async => checkCalls++;

  @override
  Future<UpdateAppResult> updateApp() async {
    updateAppCalls++;
    return appResult;
  }

  @override
  void updatePc(String target) => pcTargets.add(target);

  @override
  void retryPcReturn() => retryPcCalls++;
}

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

const String _kInstalled = '1.4.0';
const String _kLatest = '1.5.0';

/// The real APK magnitude (66 MB), so the D-08 size clause is asserted against
/// the string the shipped formatter actually produces.
const int _kApkBytes = 69630935;

/// A fixed clock — the footer's `{ago}` is a pure function of this.
final DateTime _kNow = DateTime.utc(2026, 8, 4, 12);

/// The neutral filler the two rows under test-focus carry, so a subtitle find
/// scoped to one row can never collide with another row's copy.
const UpdateRowState _filler = UpdateRowState.unknownVersion();

UpdatesViewState _view({
  UpdateRowState app = _filler,
  UpdateRowState pc = _filler,
  UpdateRowState extension = _filler,
  CheckFooterState footer = const CheckFooterState.neverChecked(),
  bool badge = false,
}) =>
    UpdatesViewState(
      app: app,
      pc: pc,
      extension: extension,
      footer: footer,
      badge: badge,
    );

// ---------------------------------------------------------------------------
// Harness
// ---------------------------------------------------------------------------

/// Pumps the real [UpdatesScreen] over [stub]. Returns after the post-frame
/// `ensureChecked` has run.
Future<void> _pumpScreen(
  WidgetTester t, {
  required _StubUpdates stub,
  _FakeService? service,
  _FakeInstaller? installer,
}) async {
  await t.binding.setSurfaceSize(const Size(800, 1400));
  addTearDown(() => t.binding.setSurfaceSize(null));
  await t.pumpWidget(
    ProviderScope(
      overrides: [
        connectionServiceProvider.overrideWithValue(service ?? _FakeService()),
        updatesStateProvider.overrideWith(() => stub),
        updateClockProvider.overrideWithValue(() => _kNow),
        apkInstallerProvider.overrideWithValue(installer ?? _FakeInstaller()),
      ],
      child: const MaterialApp(home: UpdatesScreen()),
    ),
  );
  await t.pump();
}

/// Unmounts so the header chip's 500ms periodic ticker is cancelled — without
/// this the binding reports a pending timer at teardown.
Future<void> _unmount(WidgetTester t) => t.pumpWidget(const SizedBox());

Finder _row(String title) => find.widgetWithText(UpdateRow, title);

Finder _inRow(String title, Finder matching) =>
    find.descendant(of: _row(title), matching: matching);

/// What the trailing slot must be for a given matrix row.
enum _Slot {
  /// A `TextButton` carrying `Update` or `Retry`.
  action,

  /// The determinate download arc.
  arc,

  /// The indeterminate busy spinner.
  spinner,

  /// `SizedBox.shrink()` — no button, no indicator.
  empty,
}

void _expectSlot(
  WidgetTester t,
  String title,
  _Slot slot, {
  String? actionLabel,
  double? arcValue,
}) {
  final buttons = _inRow(title, find.byType(TextButton));
  final indicators = _inRow(title, find.byType(CircularProgressIndicator));

  switch (slot) {
    case _Slot.action:
      expect(
        _inRow(title, find.widgetWithText(TextButton, actionLabel!)),
        findsOneWidget,
        reason: '"$title" must offer $actionLabel',
      );
      expect(indicators, findsNothing,
          reason: '"$title" shows an action, so no indicator');
    case _Slot.arc:
      expect(buttons, findsNothing, reason: '"$title" is not actionable');
      expect(indicators, findsOneWidget);
      expect(
        t.widget<CircularProgressIndicator>(indicators).value,
        closeTo(arcValue!, 1e-9),
        reason: 'the arc is determinate and tracks pct',
      );
    case _Slot.spinner:
      expect(buttons, findsNothing, reason: '"$title" is not actionable');
      expect(indicators, findsOneWidget);
      expect(
        t.widget<CircularProgressIndicator>(indicators).value,
        isNull,
        reason: 'a busy spinner is indeterminate',
      );
    case _Slot.empty:
      expect(buttons, findsNothing, reason: '"$title" must offer no action');
      expect(indicators, findsNothing, reason: '"$title" must show no spinner');
  }
}

/// The forbidden-chrome sweep run on EVERY matrix case: the destructive token
/// is not used in this phase, and neither is a dialog or a snackbar.
void _expectNoForbiddenChrome(WidgetTester t, {required String reason}) {
  for (final text in t.widgetList<Text>(find.byType(Text))) {
    expect(text.style?.color, isNot(kError), reason: 'kError text — $reason');
  }
  for (final icon in t.widgetList<Icon>(find.byType(Icon))) {
    expect(icon.color, isNot(kError), reason: 'kError glyph — $reason');
  }
  for (final indicator
      in t.widgetList<CircularProgressIndicator>(
          find.byType(CircularProgressIndicator))) {
    expect(indicator.color, isNot(kError),
        reason: 'kError indicator — $reason');
  }
  for (final box in t.widgetList<Container>(find.byType(Container))) {
    final decoration = box.decoration;
    if (decoration is BoxDecoration) {
      expect(decoration.color, isNot(kError),
          reason: 'kError surface — $reason');
    }
  }
  expect(find.byType(SnackBar), findsNothing, reason: 'no snackbar — $reason');
  expect(find.byType(Dialog), findsNothing, reason: 'no dialog — $reason');
  expect(find.byType(AlertDialog), findsNothing,
      reason: 'no dialog — $reason');
}

// ---------------------------------------------------------------------------
// The matrix
// ---------------------------------------------------------------------------

/// One row of the 12-UI-SPEC row state matrix, bound to the row it applies to.
class _MatrixCase {
  /// Matrix row name, used as the test name.
  final String name;

  /// Which component row this state applies to.
  final String rowTitle;

  /// The state under test.
  final UpdateRowState state;

  /// The exact subtitle sentence the matrix promises.
  final String subtitle;

  /// The exact trailing slot the slot table promises.
  final _Slot slot;

  /// The action label, when [slot] is [_Slot.action].
  final String? actionLabel;

  /// The arc value, when [slot] is [_Slot.arc].
  final double? arcValue;

  const _MatrixCase({
    required this.name,
    required this.rowTitle,
    required this.state,
    required this.subtitle,
    required this.slot,
    this.actionLabel,
    this.arcValue,
  });

  /// Places [state] on its row, leaving the other two on the filler.
  UpdatesViewState get view => switch (rowTitle) {
        kAppRowTitle => _view(app: state),
        kPcRowTitle => _view(pc: state),
        _ => _view(extension: state),
      };
}

/// `{i} → {l} · {s}` — assembled from the shipped consts and the shipped
/// formatter, never hand-typed, so a copy change cannot pass by being wrong in
/// two places at once.
String _availableSubtitle({int? sizeBytes}) =>
    '$_kInstalled$kSubtitleTransitionArrow$_kLatest$kSubtitleSeparator'
    '${sizeBytes == null ? kSubtitleExtensionTail : formatSize(sizeBytes)}';

const UpdateRowState _availableApp = UpdateRowState.available(
  installed: _kInstalled,
  latest: _kLatest,
  sizeBytes: _kApkBytes,
);

final List<_MatrixCase> _matrix = [
  // -- checking --------------------------------------------------------------
  const _MatrixCase(
    name: 'checking (App)',
    rowTitle: kAppRowTitle,
    state: UpdateRowState.checking(),
    subtitle: kSubtitleChecking,
    slot: _Slot.spinner,
  ),
  const _MatrixCase(
    name: 'checking (PC)',
    rowTitle: kPcRowTitle,
    state: UpdateRowState.checking(),
    subtitle: kSubtitleChecking,
    slot: _Slot.spinner,
  ),
  const _MatrixCase(
    name: 'checking (Extension — the slot is empty even while busy)',
    rowTitle: kExtensionRowTitle,
    state: UpdateRowState.checking(),
    subtitle: kSubtitleChecking,
    slot: _Slot.empty,
  ),
  // -- upToDate --------------------------------------------------------------
  const _MatrixCase(
    name: 'upToDate (App)',
    rowTitle: kAppRowTitle,
    state: UpdateRowState.upToDate(_kInstalled),
    subtitle: '$kSubtitleUpToDatePrefix$_kInstalled',
    slot: _Slot.empty,
  ),
  const _MatrixCase(
    name: 'upToDate (PC)',
    rowTitle: kPcRowTitle,
    state: UpdateRowState.upToDate(_kInstalled),
    subtitle: '$kSubtitleUpToDatePrefix$_kInstalled',
    slot: _Slot.empty,
  ),
  const _MatrixCase(
    name: 'upToDate (Extension)',
    rowTitle: kExtensionRowTitle,
    state: UpdateRowState.upToDate(_kInstalled),
    subtitle: '$kSubtitleUpToDatePrefix$_kInstalled',
    slot: _Slot.empty,
  ),
  // -- available -------------------------------------------------------------
  _MatrixCase(
    name: 'available (App) — D-08 shows both versions and the size',
    rowTitle: kAppRowTitle,
    state: _availableApp,
    subtitle: _availableSubtitle(sizeBytes: _kApkBytes),
    slot: _Slot.action,
    actionLabel: kUpdateActionLabel,
  ),
  _MatrixCase(
    name: 'available (PC)',
    rowTitle: kPcRowTitle,
    state: _availableApp,
    subtitle: _availableSubtitle(sizeBytes: _kApkBytes),
    slot: _Slot.action,
    actionLabel: kUpdateActionLabel,
  ),
  _MatrixCase(
    name: 'available (Extension) — display only, never an action (D-18)',
    rowTitle: kExtensionRowTitle,
    state: const UpdateRowState.availableNoAction(
      installed: _kInstalled,
      latest: _kLatest,
    ),
    subtitle: _availableSubtitle(),
    slot: _Slot.empty,
  ),
  // -- the apply stages ------------------------------------------------------
  const _MatrixCase(
    name: 'downloading (App)',
    rowTitle: kAppRowTitle,
    state: UpdateRowState.downloading(42),
    subtitle: '${kSubtitleDownloadingPrefix}42$kSubtitleDownloadingSuffix',
    slot: _Slot.arc,
    arcValue: 0.42,
  ),
  const _MatrixCase(
    name: 'downloading (PC)',
    rowTitle: kPcRowTitle,
    state: UpdateRowState.downloading(7),
    subtitle: '${kSubtitleDownloadingPrefix}7$kSubtitleDownloadingSuffix',
    slot: _Slot.arc,
    arcValue: 0.07,
  ),
  const _MatrixCase(
    name: 'verifying (App)',
    rowTitle: kAppRowTitle,
    state: UpdateRowState.verifying(),
    subtitle: kSubtitleVerifying,
    slot: _Slot.spinner,
  ),
  const _MatrixCase(
    name: 'verifying (PC)',
    rowTitle: kPcRowTitle,
    state: UpdateRowState.verifying(),
    subtitle: kSubtitleVerifying,
    slot: _Slot.spinner,
  ),
  const _MatrixCase(
    name: 'installing (App)',
    rowTitle: kAppRowTitle,
    state: UpdateRowState.installing(),
    subtitle: kSubtitleInstalling,
    slot: _Slot.spinner,
  ),
  const _MatrixCase(
    name: 'installing (PC)',
    rowTitle: kPcRowTitle,
    state: UpdateRowState.installing(),
    subtitle: kSubtitleInstalling,
    slot: _Slot.spinner,
  ),
  const _MatrixCase(
    name: 'restarting (PC)',
    rowTitle: kPcRowTitle,
    state: UpdateRowState.restarting(),
    subtitle: kSubtitleRestarting,
    slot: _Slot.spinner,
  ),
  // -- failed: the five closed sentences, and nothing else (D-11, T-12-06) ----
  const _MatrixCase(
    name: 'failed network (App)',
    rowTitle: kAppRowTitle,
    state: UpdateRowState.failed(UpdateFailure.network),
    subtitle: kFailNetwork,
    slot: _Slot.action,
    actionLabel: kRetryActionLabel,
  ),
  const _MatrixCase(
    name: 'failed checksum (App)',
    rowTitle: kAppRowTitle,
    state: UpdateRowState.failed(UpdateFailure.checksum),
    subtitle: kFailChecksum,
    slot: _Slot.action,
    actionLabel: kRetryActionLabel,
  ),
  const _MatrixCase(
    name: 'failed disk (App)',
    rowTitle: kAppRowTitle,
    state: UpdateRowState.failed(UpdateFailure.disk),
    subtitle: kFailDisk,
    slot: _Slot.action,
    actionLabel: kRetryActionLabel,
  ),
  const _MatrixCase(
    name: 'failed installer (PC)',
    rowTitle: kPcRowTitle,
    state: UpdateRowState.failed(UpdateFailure.installer),
    subtitle: kFailInstallerNoVersion,
    slot: _Slot.action,
    actionLabel: kRetryActionLabel,
  ),
  const _MatrixCase(
    name: 'failed stale (PC)',
    rowTitle: kPcRowTitle,
    state: UpdateRowState.failed(UpdateFailure.stale),
    subtitle: kFailStale,
    slot: _Slot.action,
    actionLabel: kRetryActionLabel,
  ),
  // -- the screen-scoped and component-scoped refusals ------------------------
  const _MatrixCase(
    name: 'couldNotCheck (App) — the retry lives in the footer (D-22)',
    rowTitle: kAppRowTitle,
    state: UpdateRowState.couldNotCheck(),
    subtitle: kSubtitleCouldNotCheck,
    slot: _Slot.empty,
  ),
  const _MatrixCase(
    name: 'serverDisconnected (PC)',
    rowTitle: kPcRowTitle,
    state: UpdateRowState.serverDisconnected(),
    subtitle: kSubtitleServerDisconnected,
    slot: _Slot.empty,
  ),
  const _MatrixCase(
    name: 'serverDisconnected (Extension)',
    rowTitle: kExtensionRowTitle,
    state: UpdateRowState.serverDisconnected(),
    subtitle: kSubtitleServerDisconnected,
    slot: _Slot.empty,
  ),
  const _MatrixCase(
    name: 'serverTooOld (PC) — D-13',
    rowTitle: kPcRowTitle,
    state: UpdateRowState.serverTooOld(),
    subtitle: kSubtitleServerTooOld,
    slot: _Slot.empty,
  ),
  const _MatrixCase(
    name: 'serverTooOld (Extension) — the same sentence, so the cause '
        'reads once',
    rowTitle: kExtensionRowTitle,
    state: UpdateRowState.serverTooOld(),
    subtitle: kSubtitleServerTooOld,
    slot: _Slot.empty,
  ),
  const _MatrixCase(
    name: 'pcDidNotReturn (PC) — D-25',
    rowTitle: kPcRowTitle,
    state: UpdateRowState.pcDidNotReturn(),
    subtitle: kSubtitlePcDidNotReturn,
    slot: _Slot.action,
    actionLabel: kRetryActionLabel,
  ),
  const _MatrixCase(
    name: 'extensionNeverConnected (Extension)',
    rowTitle: kExtensionRowTitle,
    state: UpdateRowState.extensionNeverConnected(),
    subtitle: kSubtitleExtensionNeverConnected,
    slot: _Slot.empty,
  ),
  const _MatrixCase(
    name: 'extensionNeedsBrowserRestart (Extension) — D-18, no second attempt',
    rowTitle: kExtensionRowTitle,
    state: UpdateRowState.extensionNeedsBrowserRestart(),
    subtitle: kSubtitleExtensionNeedsBrowserRestart,
    slot: _Slot.empty,
  ),
  const _MatrixCase(
    name: 'unknownVersion (App) — never an update offer (D-26)',
    rowTitle: kAppRowTitle,
    state: UpdateRowState.unknownVersion(),
    subtitle: kSubtitleUnknownVersion,
    slot: _Slot.empty,
  ),
];

void main() {
  group('the row state matrix renders in full (SC3)', () {
    for (final c in _matrix) {
      testWidgets(c.name, (t) async {
        final stub = _StubUpdates(c.view);
        await _pumpScreen(t, stub: stub);

        expect(find.byType(UpdateRow), findsNWidgets(3),
            reason: 'three rows in every state, always');
        expect(
          _inRow(c.rowTitle, find.text(c.subtitle)),
          findsOneWidget,
          reason: '"${c.rowTitle}" must read exactly: ${c.subtitle}',
        );
        _expectSlot(
          t,
          c.rowTitle,
          c.slot,
          actionLabel: c.actionLabel,
          arcValue: c.arcValue,
        );
        _expectNoForbiddenChrome(t, reason: c.name);

        await _unmount(t);
      });
    }

    test('the matrix table above covers every UpdateRowKind', () {
      final covered = _matrix.map((c) => c.state.kind).toSet();
      expect(
        covered,
        UpdateRowKind.values.toSet(),
        reason: 'a state the machine can produce that this file never pumps '
            'is a state nobody has ever seen rendered',
      );
    });
  });

  group('the three rows are structural, not conditional (SC3)', () {
    testWidgets('three rows in the fixed order, socket down', (t) async {
      final stub = _StubUpdates(_view(
        app: const UpdateRowState.upToDate(_kInstalled),
        pc: const UpdateRowState.serverDisconnected(),
        extension: const UpdateRowState.serverDisconnected(),
      ));
      await _pumpScreen(t, stub: stub, service: _FakeService(chip: ChipStatus.disconnected));

      expect(find.byType(UpdateRow), findsNWidgets(3));
      final app = t.getTopLeft(find.text(kAppRowTitle)).dy;
      final pc = t.getTopLeft(find.text(kPcRowTitle)).dy;
      final ext = t.getTopLeft(find.text(kExtensionRowTitle)).dy;
      expect(pc, greaterThan(app), reason: 'App leads — it needs no PC');
      expect(ext, greaterThan(pc));

      await _unmount(t);
    });

    testWidgets('three rows after a feed failure', (t) async {
      final stub = _StubUpdates(_view(
        app: const UpdateRowState.couldNotCheck(),
        pc: const UpdateRowState.couldNotCheck(),
        extension: const UpdateRowState.couldNotCheck(),
        footer: const CheckFooterState.failed(),
      ));
      await _pumpScreen(t, stub: stub);

      expect(find.byType(UpdateRow), findsNWidgets(3));
      expect(find.text(kSubtitleCouldNotCheck), findsNWidgets(3),
          reason: 'the failure is screen-scoped, so all three say so');

      await _unmount(t);
    });

    testWidgets('a feed failure produces exactly ONE retry, in the footer '
        '(D-22)', (t) async {
      final stub = _StubUpdates(_view(
        app: const UpdateRowState.couldNotCheck(),
        pc: const UpdateRowState.couldNotCheck(),
        extension: const UpdateRowState.couldNotCheck(),
        footer: const CheckFooterState.failed(),
      ));
      await _pumpScreen(t, stub: stub);

      expect(find.text(kRetryActionLabel), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(CheckFooter),
          matching: find.text(kRetryActionLabel),
        ),
        findsOneWidget,
        reason: 'the single retry belongs to the footer, never to a row',
      );
      expect(find.text(kFooterCouldNotCheck), findsOneWidget);

      await _unmount(t);
    });

    testWidgets('the Extension row renders no action in ANY of its states '
        '(D-18)', (t) async {
      final extensionStates = _matrix
          .where((c) => c.rowTitle == kExtensionRowTitle)
          .map((c) => c.state)
          .toList();
      expect(extensionStates, isNotEmpty);

      for (final state in extensionStates) {
        final stub = _StubUpdates(_view(extension: state));
        await _pumpScreen(t, stub: stub);

        // Not an enabled action, and not a greyed one either: the slot is
        // structurally empty, so there is no affordance to disable.
        expect(_inRow(kExtensionRowTitle, find.byType(TextButton)), findsNothing,
            reason: 'no button on $state');
        expect(_inRow(kExtensionRowTitle, find.byType(ButtonStyleButton)),
            findsNothing,
            reason: 'no button of any kind on $state');

        await _unmount(t);
      }
    });
  });

  group('the row does not resize between states (T-12-49 / D-24)', () {
    testWidgets('available, downloading and failed are the same height',
        (t) async {
      final heights = <double>[];
      for (final state in <UpdateRowState>[
        _availableApp,
        const UpdateRowState.downloading(42),
        const UpdateRowState.failed(UpdateFailure.checksum),
      ]) {
        final stub = _StubUpdates(_view(app: state));
        await _pumpScreen(t, stub: stub);
        heights.add(t.getRect(_row(kAppRowTitle)).height);
        await _unmount(t);
      }

      expect(heights[1], heights[0],
          reason: 'downloading must not resize the row');
      expect(heights[2], heights[0],
          reason: 'the longest failure sentence must not resize the row');
    });
  });

  group('the check footer (D-07)', () {
    testWidgets('never checked reads the fixed sentence', (t) async {
      final stub = _StubUpdates(_view());
      await _pumpScreen(t, stub: stub);

      expect(find.text(kFooterNeverChecked), findsOneWidget);
      expect(find.widgetWithText(TextButton, kCheckForUpdatesLabel),
          findsOneWidget);

      await _unmount(t);
    });

    testWidgets('ok renders `Last checked {ago}.` off the injected clock',
        (t) async {
      final stub = _StubUpdates(_view(
        footer: CheckFooterState.ok(_kNow.subtract(const Duration(hours: 3))),
      ));
      await _pumpScreen(t, stub: stub);

      expect(
        find.text('$kFooterLastCheckedPrefix'
            '${formatAgo(const Duration(hours: 3))}'
            '$kFooterLastCheckedSuffix'),
        findsOneWidget,
      );

      await _unmount(t);
    });

    testWidgets('checking is muted and non-pressable', (t) async {
      final stub = _StubUpdates(_view(
        footer: const CheckFooterState.checking(),
      ));
      await _pumpScreen(t, stub: stub);

      expect(find.text(kFooterChecking), findsOneWidget);
      final button =
          t.widget<TextButton>(find.widgetWithText(TextButton, kCheckForUpdatesLabel));
      expect(button.onPressed, isNull, reason: 'a check is already running');
      expect(
        button.style?.foregroundColor?.resolve({WidgetState.disabled}),
        kMuted,
        reason: 'the disabled footer is kMuted, not the theme disabled colour',
      );

      await _unmount(t);
    });

    testWidgets('tapping the footer fires exactly one check', (t) async {
      final stub = _StubUpdates(_view());
      await _pumpScreen(t, stub: stub);

      await t.tap(find.widgetWithText(TextButton, kCheckForUpdatesLabel));
      await t.pump();

      expect(stub.checkCalls, 1);

      await _unmount(t);
    });
  });

  group('the install-permission sheet (D-19)', () {
    testWidgets('Update with the grant missing opens the sheet and leaves the '
        'row on available', (t) async {
      final stub = _StubUpdates(
        _view(app: _availableApp),
        appResult: UpdateAppResult.needsInstallGrant,
      );
      final installer = _FakeInstaller();
      await _pumpScreen(t, stub: stub, installer: installer);

      await t.tap(_inRow(kAppRowTitle, find.text(kUpdateActionLabel)));
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));

      expect(find.text(kInstallSheetTitle), findsOneWidget);
      expect(find.text(kInstallSheetBody), findsOneWidget);
      expect(stub.updateAppCalls, 1);
      // The grant check happens inside `updateApp`, which returns before a byte
      // is fetched — 12-14's suite proves that; here the observable truth is
      // that the row never left `available`.
      expect(
        _inRow(kAppRowTitle,
            find.text(_availableSubtitle(sizeBytes: _kApkBytes))),
        findsOneWidget,
      );

      await t.tap(find.text(kInstallSheetDismiss));
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));

      expect(find.text(kInstallSheetTitle), findsNothing);
      expect(
        _inRow(kAppRowTitle,
            find.text(_availableSubtitle(sizeBytes: _kApkBytes))),
        findsOneWidget,
        reason: 'dismissing is not a failure — the row is unchanged',
      );
      expect(_inRow(kAppRowTitle, find.text(kUpdateActionLabel)), findsOneWidget);
      expect(installer.openPermissionCalls, 0,
          reason: '`Not now` must not route to system settings');
      expect(stub.updateAppCalls, 1, reason: 'and must not retry the update');

      await _unmount(t);
    });

    testWidgets('the CTA routes to system settings and closes the sheet',
        (t) async {
      final stub = _StubUpdates(
        _view(app: _availableApp),
        appResult: UpdateAppResult.needsInstallGrant,
      );
      final installer = _FakeInstaller();
      await _pumpScreen(t, stub: stub, installer: installer);

      await t.tap(_inRow(kAppRowTitle, find.text(kUpdateActionLabel)));
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));

      await t.tap(find.text(kInstallSheetCta));
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));

      expect(installer.openPermissionCalls, 1);
      expect(find.text(kInstallSheetTitle), findsNothing);
      // No poll and no auto-resume: the user comes back and taps Update again.
      expect(stub.updateAppCalls, 1);

      await _unmount(t);
    });

    testWidgets('a granted Update never opens the sheet', (t) async {
      final stub = _StubUpdates(
        _view(app: _availableApp),
        appResult: UpdateAppResult.started,
      );
      await _pumpScreen(t, stub: stub);

      await t.tap(_inRow(kAppRowTitle, find.text(kUpdateActionLabel)));
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));

      expect(find.text(kInstallSheetTitle), findsNothing);
      expect(stub.updateAppCalls, 1);

      await _unmount(t);
    });
  });

  group('the row body is inert (T-12-51)', () {
    testWidgets('tapping the body of an actionable row does nothing', (t) async {
      final stub = _StubUpdates(_view(
        app: _availableApp,
        pc: _availableApp,
      ));
      await _pumpScreen(t, stub: stub);

      await t.tap(find.text(kAppRowTitle));
      await t.tap(find.text(kPcRowTitle));
      await t.tap(_inRow(
        kAppRowTitle,
        find.text(_availableSubtitle(sizeBytes: _kApkBytes)),
      ).first);
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));

      expect(stub.updateAppCalls, 0, reason: 'no download from a mis-tap');
      expect(stub.pcTargets, isEmpty, reason: 'no PC install from a mis-tap');
      expect(stub.checkCalls, 0);
      expect(stub.retryPcCalls, 0);
      expect(find.text(kInstallSheetTitle), findsNothing);
      expect(find.byType(UpdatesScreen), findsOneWidget,
          reason: 'the body is not a nav row — nothing was pushed');

      await _unmount(t);
    });

    testWidgets('the row body carries no recognizer and no press flash',
        (t) async {
      final stub = _StubUpdates(_view(app: _availableApp));
      await _pumpScreen(t, stub: stub);

      // Scoped to the body, not the row: the trailing `TextButton` builds an
      // `InkWell` of its own, and that one is the row's ONLY recognizer. What
      // must not exist is a recognizer wrapping the title/subtitle column,
      // which is what a mis-tap would land on.
      for (final body in <Finder>[
        find.text(kAppRowTitle),
        find.text(_availableSubtitle(sizeBytes: _kApkBytes)),
      ]) {
        expect(find.ancestor(of: body, matching: find.byType(InkWell)),
            findsNothing);
        expect(find.ancestor(of: body, matching: find.byType(GestureDetector)),
            findsNothing);
      }

      await _unmount(t);
    });

    testWidgets('a row with no action carries no recognizer at all', (t) async {
      final stub = _StubUpdates(_view(
        app: const UpdateRowState.upToDate(_kInstalled),
      ));
      await _pumpScreen(t, stub: stub);

      expect(_inRow(kAppRowTitle, find.byType(InkWell)), findsNothing);
      expect(_inRow(kAppRowTitle, find.byType(GestureDetector)), findsNothing);

      await _unmount(t);
    });
  });

  group('the PC row commands', () {
    testWidgets('Update sends the resolved target and nothing else (D-14)',
        (t) async {
      final stub = _StubUpdates(_view(pc: _availableApp));
      await _pumpScreen(t, stub: stub);

      await t.tap(_inRow(kPcRowTitle, find.text(kUpdateActionLabel)));
      await t.pump();

      expect(stub.pcTargets, [_kLatest],
          reason: 'the screen can only ask for the version the feed resolved');

      await _unmount(t);
    });

    testWidgets('pcDidNotReturn Retry asks the EXISTING reconnect FSM (D-25)',
        (t) async {
      final stub = _StubUpdates(_view(pc: const UpdateRowState.pcDidNotReturn()));
      await _pumpScreen(t, stub: stub);

      await t.tap(_inRow(kPcRowTitle, find.text(kRetryActionLabel)));
      await t.pump();

      expect(stub.retryPcCalls, 1);
      expect(stub.pcTargets, isEmpty, reason: 'a retry is not a new apply');

      await _unmount(t);
    });
  });

  testWidgets('mounting runs the session check exactly once', (t) async {
    final stub = _StubUpdates(_view());
    await _pumpScreen(t, stub: stub);

    expect(stub.ensureCheckedCalls, 1);
    // The quiet launch check never animates the screen (D-07/D-22): mounting
    // alone leaves the footer where it was.
    expect(find.text(kFooterChecking), findsNothing);

    await _unmount(t);
  });
}
