/// The Updates screen (D-06/SC3) — three component rows, one check footer, and
/// the install-permission explainer sheet.
///
/// **Nothing here is a redesign.** Every visual idiom is lifted from a shipped
/// widget and reused verbatim:
///
///   * the scaffold + app bar + `SafeArea > ListView(all: 16)` — the
///     `settings_screen.dart` Settings-family screen shape;
///   * [_GroupSurface] — a verbatim clone of `settings_screen.dart`'s private
///     group surface (`Material(kSurface)` radius 12, `kHairline` dividers,
///     14/600 `kMuted` heading 8px above with a 4px left inset);
///   * [UpdateRow] — the `_PairedPcRow` two-line-row geometry with a leading
///     glyph added;
///   * the 16x16 strokeWidth-2 spinner — `device_list_screen.dart`'s
///     `_EmptyState` indicator;
///   * [CheckFooter]'s button — `device_list_screen.dart`'s
///     `_connectByIpButton` secondary `TextButton.icon`;
///   * the sheet + its single filled CTA — the `_ConnectByIpSheet`
///     invocation and its primary button;
///   * `ConnectionHeaderChip` + `ReconnectingBannerSlot` — the
///     connected-screen chrome every tool screen already mounts.
///
/// The typography consts below are copied from `settings_screen.dart:108-127`
/// rather than shared: they are per-file consts there by house convention, and
/// this file is a Settings-family screen, so it uses the Settings row roles.
///
/// **This screen owns no update logic.** It renders [UpdatesViewState] from
/// 12-14 and fires that notifier's four commands. Every failure the user can
/// see arrives as one of five closed [UpdateFailure] values, so no error code,
/// HTTP status, exception class, file path, URL or hash is *representable*
/// here, let alone renderable (T-12-06).
///
/// Three structural rules are load-bearing rather than stylistic:
///
///   1. **All three rows render in every state.** A missing or unreachable
///      component is a state OF the row, never an absent row — a screen whose
///      row count changes with connectivity breaks the "three components"
///      promise of SC3 and is unreadable at a glance.
///   2. **The row body has no recognizer at all** — no `InkWell`, no press
///      flash. [UpdateRow]'s only gesture is the trailing `TextButton`'s, so
///      there is no gesture arena and no way a mis-tap on the row body can
///      start a 70 MB download or a PC install (T-12-51).
///   3. **The row never resizes between states.** The subtitle is a fixed
///      two-line box and the trailing slot reserves 48px, so a row on
///      `available`, `downloading` and `failed` is byte-identical in height.
///      Nothing below it moves while a download ticks.
///
/// Deliberately absent (12-UI-SPEC Non-Goals): a confirm dialog, a
/// slide-to-confirm, the destructive palette token, a toast, a snackbar,
/// release notes, a channel picker, a metered-network warning, a second
/// "waiting for your PC" indicator, pull-to-refresh, and any animation on a
/// row state change.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../net/connection_providers.dart';
import '../net/connection_service.dart' show ChipStatus, ConnectionService;
import '../settings/haptics.dart';
import '../theme/tokens.dart';
import '../widgets/connection_header.dart';
import 'update_format.dart';
import 'update_providers.dart';

// -- Copy (house rule: no inline literals) -----------------------------------

/// App-bar title.
const String kUpdatesTitle = 'Updates';

/// The one group heading on the screen.
const String kComponentsHeading = 'Components';

/// Row 1 title — the phone itself. Static in every state.
const String kAppRowTitle = 'This phone';

/// Row 2 title. Deliberately NOT the paired device's name: this screen
/// concerns exactly one PC, and a title that changed on reconnect would make
/// the row's identity flicker.
const String kPcRowTitle = 'Windows PC';

/// Row 3 title.
const String kExtensionRowTitle = 'Browser extension';

/// The one act that starts an install.
const String kUpdateActionLabel = 'Update';

/// The one act that recovers a failure (row-scoped and footer alike).
const String kRetryActionLabel = 'Retry';

/// The footer's manual check (D-07).
const String kCheckForUpdatesLabel = 'Check for updates';

/// Footer status line before any check has ever succeeded.
const String kFooterNeverChecked = 'Not checked yet.';

/// Footer status line prefix — `Last checked {ago}.`
const String kFooterLastCheckedPrefix = 'Last checked ';

/// Footer status line terminator (the full stop after `{ago}`).
const String kFooterLastCheckedSuffix = '.';

/// Footer status line while a TAPPED check runs (the quiet launch check never
/// produces this — D-07).
const String kFooterChecking = 'Checking…';

/// Footer status line after a feed failure (D-22).
const String kFooterCouldNotCheck = "Couldn't check for updates.";

// -- Copy: row subtitles (12-UI-SPEC row state matrix) -----------------------

/// `checking` — the ellipsis is the single character U+2026.
const String kSubtitleChecking = 'Checking…';

/// `upToDate` prefix — `Up to date · {installed}`.
const String kSubtitleUpToDatePrefix = 'Up to date · ';

/// The version transition arrow, U+2192, with its surrounding spaces.
const String kSubtitleTransitionArrow = ' → ';

/// The middot separator before the size (or the extension tail).
const String kSubtitleSeparator = ' · ';

/// `available` tail on the Extension row — it has no download of its own.
const String kSubtitleExtensionTail = 'updates with your PC';

/// `downloading` prefix — `Downloading… {pct}%`.
const String kSubtitleDownloadingPrefix = 'Downloading… ';

/// `downloading` suffix.
const String kSubtitleDownloadingSuffix = '%';

/// `verifying` — no jargon: never "sha256", never "checksum".
const String kSubtitleVerifying = 'Checking the download…';

/// `installing`.
const String kSubtitleInstalling = 'Installing…';

/// `restarting` (PC row only).
const String kSubtitleRestarting = 'Restarting on your PC…';

/// `couldNotCheck` — screen-scoped, so all three rows read this at once and
/// the single retry lives in the footer (D-22).
const String kSubtitleCouldNotCheck = "Couldn't check";

/// `serverDisconnected` (PC + Extension rows).
const String kSubtitleServerDisconnected = 'Connect to your PC to check';

/// `serverTooOld` (D-13) — the same sentence on both PC-side rows, so the
/// cause reads once rather than twice with different words.
const String kSubtitleServerTooOld =
    'This PC needs one more update by hand before it can update itself';

/// `pcDidNotReturn` (D-25).
const String kSubtitlePcDidNotReturn =
    "PC didn't come back — start it from the Start Menu";

/// `extensionNeverConnected`.
const String kSubtitleExtensionNeverConnected =
    'Not connected — open your browser';

/// `extensionNeedsBrowserRestart` (D-18) — the one `ext.reload` attempt did
/// not take, and there is no second one.
const String kSubtitleExtensionNeedsBrowserRestart =
    'Restart your browser to finish updating';

/// `unknownVersion` — the answer to every comparison that cannot be made.
const String kSubtitleUnknownVersion = 'Version unknown';

// -- Copy: the D-11 code -> sentence map -------------------------------------
//
// Named `kFail*` rather than after the wire codes on purpose: the destructive
// palette token is banned from this phase, and a plan-check greps this file
// for that identifier. These five sentences are the ONLY failures the user can
// see. Each names the problem AND what is now true, so the user knows whether
// anything is broken. None of them blames the user, and none of them can carry
// a code, a status, a path, a URL or a hash.

/// `network` — the bytes never arrived.
const String kFailNetwork = 'Download failed — check your connection.';

/// `checksum` — the bytes arrived and could not be trusted. "Signature", never
/// "sha256".
const String kFailChecksum =
    "The download didn't match its signature. Nothing was installed.";

/// `disk` — the bytes arrived and could not be stored.
const String kFailDisk = 'Not enough space for the download.';

/// `installer` prefix — `The installer didn't finish. Your PC is still on
/// {installed}.`
const String kFailInstallerPrefix =
    "The installer didn't finish. Your PC is still on ";

/// `installer` terminator (the full stop after `{installed}`).
const String kFailInstallerSuffix = '.';

/// `installer` when the installed version is not part of the failure state.
///
/// A failed row carries no version (12-14's `UpdateRowState.failed` holds only
/// the closed failure value), so the version clause is dropped rather than
/// rendered as an empty gap or the word "null". The sentence still names the
/// problem and still says nothing was replaced.
const String kFailInstallerNoVersion = "The installer didn't finish.";

/// `stale` — the target is no longer what the feed resolves as latest.
const String kFailStale = 'That version is no longer the latest. Check again.';

// -- Copy: the install-permission explainer sheet (D-19) ---------------------

/// Sheet title.
const String kInstallSheetTitle = 'Allow Remote Control to install updates';

/// Sheet body — states what the grant does and that it is revocable.
const String kInstallSheetBody =
    'Android asks for this once. It lets Remote Control install its own update '
    'and nothing else — you can turn it off again any time.';

/// Sheet primary CTA — the phase's ONLY filled button.
const String kInstallSheetCta = 'Open settings';

/// Sheet dismiss. Resolves identically to the scrim and the back gesture.
const String kInstallSheetDismiss = 'Not now';

// -- Copy: accessibility ------------------------------------------------------

/// The badge dot's semantics label — it is a purely visual signal otherwise.
const String kUpdateBadgeSemantic = 'Update available';

/// The hub gear's tooltip while the badge shows. `IconButton` surfaces
/// `tooltip` as its semantics label, so this costs no extra node and cannot
/// desync from the dot.
const String kSettingsWithUpdateTooltip = 'Settings — update available';

// -- Geometry ----------------------------------------------------------------

/// Screen edge padding, row horizontal padding, sheet inner padding (md).
const double kUpdatesEdgePadding = 16;

/// Gap between the component group and the check footer (lg).
const double kUpdatesGroupFooterGap = 24;

/// Every touch target, and the height the trailing slot always reserves so the
/// row cannot resize between states.
const double kUpdatesTouchTarget = 48;

/// The Body role's font size (12-UI-SPEC Typography).
const double kSubtitleFontSize = 14;

/// The Body role's line height multiplier.
const double kSubtitleLineHeight = 1.5;

/// Subtitle lines a row always reserves. FIXED at two: the D-11 error copy and
/// the version-transition string do not fit one phone line, and a box that
/// grew from one line to two would move everything below it mid-download.
const int kSubtitleLines = 2;

/// The fixed subtitle box height, derived from the type scale rather than
/// written as a new measurement.
const double kSubtitleBoxHeight =
    kSubtitleFontSize * kSubtitleLineHeight * kSubtitleLines;

/// The badge dot's diameter (the `sm` token used as a diameter).
const double kBadgeDotDiameter = 8;

/// The inline spinner box — the shipped `_EmptyState` indicator, verbatim.
const double kInlineSpinnerBox = 16;

/// The inline spinner's stroke — the shipped `_EmptyState` indicator.
const double kInlineSpinnerStroke = 2;

/// Row leading glyph size.
const double kRowGlyphSize = 24;

/// Gap between a row's leading glyph and its text column.
const double kRowGlyphGap = 12;

/// Title -> subtitle gap. The ONE off-grid value this phase carries (it is the
/// shipped `_PairedPcRow` geometry), never a new one.
const double kRowTitleSubtitleGap = 2;

/// Group-surface corner radius.
const double kGroupRadius = 12;

/// Sheet top corner radius.
const double kSheetRadius = 16;

// -- Typography (the Settings roles, copied verbatim from settings_screen) ----

const TextStyle _appBarTitle = TextStyle(
  fontSize: 16,
  fontWeight: FontWeight.w600,
  color: kText,
);
const TextStyle _groupHeading = TextStyle(
  fontSize: 14,
  fontWeight: FontWeight.w600,
  color: kMuted,
);
const TextStyle _rowTitle = TextStyle(
  fontSize: 16,
  fontWeight: FontWeight.w400,
  color: kText,
);

/// The row subtitle. Two divergences from the shipped `_rowSubtitle`, both
/// declared in the UI-SPEC so neither reads as drift:
///
///   * an explicit `height` — the fixed two-line box is derived from it, so it
///     cannot be left to the font's default;
///   * tabular figures — the download percentage updates ~4x/second, and
///     proportional digits would reflow the subtitle on every tick. Applied to
///     every subtitle rather than only the percentage, because version strings
///     churn digits too and one style is one thing to keep true.
const TextStyle _rowSubtitle = TextStyle(
  fontSize: kSubtitleFontSize,
  fontWeight: FontWeight.w400,
  height: kSubtitleLineHeight,
  color: kMuted,
  fontFeatures: [FontFeature.tabularFigures()],
);

/// The row-action label — 14/600, matching the shipped `kRevokeLabel` button.
/// NOT the 16/600 heading role despite sharing its weight.
const TextStyle _rowActionLabel = TextStyle(
  fontSize: 14,
  fontWeight: FontWeight.w600,
  color: kAccent,
);

/// The footer status line — the 12/400 Label role.
const TextStyle _footerStatus = TextStyle(
  fontSize: 12,
  fontWeight: FontWeight.w400,
  color: kMuted,
);

/// The footer button label — the Body role, colour from the button's
/// `foregroundColor` so the three footer states are one style with three
/// foregrounds.
const TextStyle _footerButtonLabel = TextStyle(
  fontSize: 14,
  fontWeight: FontWeight.w400,
);

/// The sheet title — the 16/600 Heading role.
const TextStyle _sheetTitle = TextStyle(
  fontSize: 16,
  fontWeight: FontWeight.w600,
  color: kText,
);

/// The sheet body — the Body role.
const TextStyle _sheetBody = TextStyle(
  fontSize: 14,
  fontWeight: FontWeight.w400,
  color: kMuted,
);

// -- Copy derivation ----------------------------------------------------------

/// The subtitle sentence for [state] — the 12-UI-SPEC row state matrix as one
/// exhaustive `switch`.
///
/// Exhaustive over [UpdateRowKind] on purpose: a state added to the machine
/// cannot be forgotten here, because the analyzer refuses the switch until it
/// is handled.
String updateRowSubtitle(UpdateRowState state) {
  switch (state.kind) {
    case UpdateRowKind.checking:
      return kSubtitleChecking;
    case UpdateRowKind.upToDate:
      return '$kSubtitleUpToDatePrefix${state.installed ?? ''}';
    case UpdateRowKind.available:
      final transition =
          '${state.installed}$kSubtitleTransitionArrow${state.latest}';
      final size = state.sizeBytes;
      // No size means the Extension row's display-only variant: it rides the
      // PC installer and has no download of its own to measure.
      return size == null
          ? '$transition$kSubtitleSeparator$kSubtitleExtensionTail'
          : '$transition$kSubtitleSeparator${formatSize(size)}';
    case UpdateRowKind.downloading:
      return '$kSubtitleDownloadingPrefix'
          '${state.pct ?? 0}'
          '$kSubtitleDownloadingSuffix';
    case UpdateRowKind.verifying:
      return kSubtitleVerifying;
    case UpdateRowKind.installing:
      return kSubtitleInstalling;
    case UpdateRowKind.restarting:
      return kSubtitleRestarting;
    case UpdateRowKind.failed:
      return updateFailureSentence(state.error, installed: state.installed);
    case UpdateRowKind.couldNotCheck:
      return kSubtitleCouldNotCheck;
    case UpdateRowKind.serverDisconnected:
      return kSubtitleServerDisconnected;
    case UpdateRowKind.serverTooOld:
      return kSubtitleServerTooOld;
    case UpdateRowKind.pcDidNotReturn:
      return kSubtitlePcDidNotReturn;
    case UpdateRowKind.extensionNeverConnected:
      return kSubtitleExtensionNeverConnected;
    case UpdateRowKind.extensionNeedsBrowserRestart:
      return kSubtitleExtensionNeedsBrowserRestart;
    case UpdateRowKind.unknownVersion:
      return kSubtitleUnknownVersion;
  }
}

/// The D-11 code -> sentence map, over the closed [UpdateFailure] vocabulary.
///
/// A null [failure] cannot arrive from a `failed` row state, but degrades to
/// the generic installer sentence rather than to an empty subtitle: an honest
/// generic beats a blank row.
String updateFailureSentence(UpdateFailure? failure, {String? installed}) {
  switch (failure) {
    case UpdateFailure.network:
      return kFailNetwork;
    case UpdateFailure.checksum:
      return kFailChecksum;
    case UpdateFailure.disk:
      return kFailDisk;
    case UpdateFailure.stale:
      return kFailStale;
    case UpdateFailure.installer:
    case null:
      return installed == null
          ? kFailInstallerNoVersion
          : '$kFailInstallerPrefix$installed$kFailInstallerSuffix';
  }
}

/// The action label for [state], or null when the row offers no action.
String? updateRowActionLabel(UpdateRowState state) {
  if (!state.actionable) return null;
  switch (state.kind) {
    case UpdateRowKind.available:
      return kUpdateActionLabel;
    case UpdateRowKind.failed:
    case UpdateRowKind.pcDidNotReturn:
      return kRetryActionLabel;
    // Every other kind constructs with `actionable: false`, so this is
    // unreachable — and an unreachable state renders nothing rather than
    // guessing a label.
    default:
      return null;
  }
}

/// The footer's status line for [state], resolved against [now].
String checkFooterStatus(CheckFooterState state, {required DateTime now}) {
  switch (state.kind) {
    case CheckFooterKind.neverChecked:
      return kFooterNeverChecked;
    case CheckFooterKind.checking:
      return kFooterChecking;
    case CheckFooterKind.failed:
      return kFooterCouldNotCheck;
    case CheckFooterKind.ok:
      final at = state.lastCheckedAt;
      if (at == null) return kFooterNeverChecked;
      return '$kFooterLastCheckedPrefix'
          '${formatAgo(now.difference(at))}'
          '$kFooterLastCheckedSuffix';
  }
}

// -- The screen ---------------------------------------------------------------

/// The Updates screen: three component rows and one check footer.
class UpdatesScreen extends ConsumerStatefulWidget {
  /// Creates the Updates screen.
  const UpdatesScreen({super.key});

  @override
  ConsumerState<UpdatesScreen> createState() => _UpdatesScreenState();
}

class _UpdatesScreenState extends ConsumerState<UpdatesScreen> {
  late final ConnectionService _service;

  /// The last version the PC row offered.
  ///
  /// A `failed` row state carries no target (it holds only the closed failure
  /// value), so `Retry` would have nothing to re-apply. The UI-SPEC gesture map
  /// defines row `Retry` as "re-run that row's last failed action", and this is
  /// that memory. Widget-local by design: it must not survive a process
  /// restart, because a stale target is exactly what the server's `stale` guard
  /// exists to refuse.
  String? _lastPcTarget;

  @override
  void initState() {
    super.initState();
    _service = ref.read(connectionServiceProvider);
    // Post-frame, not inline: `ensureChecked` publishes notifier state, and a
    // provider mutation during the mounting frame is exactly the write-during-
    // build Riverpod refuses.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(updatesStateProvider.notifier).ensureChecked();
    });
  }

  @override
  Widget build(BuildContext context) {
    final status = ref.watch(connectionStatusProvider);
    final view = ref.watch(updatesStateProvider);
    final now = ref.watch(updateClockProvider)();

    final pcLatest = view.pc.latest;
    if (pcLatest != null) _lastPcTarget = pcLatest;

    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        backgroundColor: kBg,
        title: const Text(kUpdatesTitle, style: _appBarTitle),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: kUpdatesEdgePadding),
            child: Center(child: ConnectionHeaderChip.forService(_service)),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            // The ONLY reconnect surface on this screen (D-17): the PC update
            // deliberately drops the socket, and reconnection is what confirms
            // it worked. No second "waiting for your PC" indicator.
            ReconnectingBannerSlot(
              visible: status.chip == ChipStatus.reconnecting,
              onRetry: _service.retryNow,
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(kUpdatesEdgePadding),
                children: [
                  _GroupSurface(
                    heading: kComponentsHeading,
                    children: [
                      // FIXED order: nearest surface first. The App row leads
                      // because it is the only update the user can complete
                      // with no PC in the room.
                      UpdateRow(
                        glyph: Symbols.smartphone_rounded,
                        title: kAppRowTitle,
                        state: view.app,
                        onAction: view.app.actionable ? _onAppAction : null,
                      ),
                      UpdateRow(
                        glyph: Symbols.computer_rounded,
                        title: kPcRowTitle,
                        state: view.pc,
                        onAction: view.pc.actionable ? _onPcAction : null,
                      ),
                      UpdateRow(
                        glyph: Symbols.extension_rounded,
                        title: kExtensionRowTitle,
                        state: view.extension,
                        // D-18: structurally absent, not conditionally
                        // disabled. An affordance that can never fire is worse
                        // than none.
                        neverActs: true,
                      ),
                    ],
                  ),
                  const SizedBox(height: kUpdatesGroupFooterGap),
                  CheckFooter(
                    state: view.footer,
                    now: now,
                    onCheck: _onCheck,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// The App row's `Update` / `Retry`.
  ///
  /// The grant check lives inside `updateApp`, which returns without
  /// downloading a byte when the grant is missing — so the explainer sheet is
  /// never opened pre-emptively and never on a row that is not actionable.
  Future<void> _onAppAction() async {
    hapticTick();
    final result = await ref.read(updatesStateProvider.notifier).updateApp();
    if (!mounted) return;
    if (result == UpdateAppResult.needsInstallGrant) {
      await showInstallPermissionSheet(context);
    }
  }

  /// The PC row's `Update` / `Retry`.
  void _onPcAction() {
    hapticTick();
    final notifier = ref.read(updatesStateProvider.notifier);
    if (ref.read(updatesStateProvider).pc.kind ==
        UpdateRowKind.pcDidNotReturn) {
      // D-25: ask the EXISTING reconnect FSM to dial now. This phase starts no
      // reconnect path of its own.
      notifier.retryPcReturn();
      return;
    }
    final target = _lastPcTarget;
    // No remembered target (a failure inherited from a previous session) can
    // only be recovered by re-resolving the feed — never by guessing a version.
    if (target == null) {
      unawaited(notifier.check());
      return;
    }
    notifier.updatePc(target);
  }

  void _onCheck() {
    hapticTick();
    unawaited(ref.read(updatesStateProvider.notifier).check());
  }
}

/// Opens the D-19 install-permission explainer sheet.
///
/// The shipped `_ConnectByIpSheet` invocation, verbatim. Dismissing by scrim,
/// by back gesture or by `Not now` all resolve identically: the App row stays
/// on `available`, nothing downloads, nothing is logged as a failure.
Future<void> showInstallPermissionSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: kSurface,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(kSheetRadius)),
    ),
    builder: (_) => const InstallPermissionSheet(),
  );
}

// -- The group surface (a verbatim clone of settings_screen's) ---------------

/// A `kSurface` surface wrapping [children] as hairline-separated rows, with a
/// muted group [heading] above it. Cloned from `settings_screen.dart:168-200`,
/// whose copy is private to that file.
class _GroupSurface extends StatelessWidget {
  final String? heading;
  final List<Widget> children;

  const _GroupSurface({this.heading, required this.children});

  @override
  Widget build(BuildContext context) {
    final heading = this.heading;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (heading != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8, left: 4),
            child: Text(heading, style: _groupHeading),
          ),
        Material(
          color: kSurface,
          borderRadius: BorderRadius.circular(kGroupRadius),
          child: Column(
            children: [
              for (var i = 0; i < children.length; i++) ...[
                if (i > 0)
                  const Divider(height: 1, thickness: 1, color: kHairline),
                children[i],
              ],
            ],
          ),
        ),
      ],
    );
  }
}

// -- Component 1: the row ------------------------------------------------------

/// One component row: leading glyph, static title, state subtitle, trailing
/// slot.
///
/// **The body is inert.** There is no `InkWell` and no press flash — the row's
/// only recognizer is the trailing `TextButton`'s. That is what makes a
/// mis-tap on the row body unable to start a 70 MB download (T-12-51), and it
/// is why the press-flash idiom (which signals "this fires something") is
/// deliberately absent.
class UpdateRow extends StatelessWidget {
  /// The leading glyph — decorative beside a text title, so deliberately
  /// unlabelled for a screen reader.
  final IconData glyph;

  /// The row title. Static in every state, so the three rows read as a stable
  /// index while their subtitles churn.
  final String title;

  /// The row's complete visual state.
  final UpdateRowState state;

  /// Fired by the trailing action. Null renders no action.
  final VoidCallback? onAction;

  /// When true the trailing slot is always empty (D-18: the Extension row has
  /// no phone action in any state — not an enabled one, and not a greyed one).
  final bool neverActs;

  /// Creates a component row.
  const UpdateRow({
    super.key,
    required this.glyph,
    required this.title,
    required this.state,
    this.onAction,
    this.neverActs = false,
  });

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: kUpdatesTouchTarget),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: kUpdatesEdgePadding,
          vertical: 8,
        ),
        child: Row(
          children: [
            Icon(glyph, size: kRowGlyphSize, color: kMuted),
            const SizedBox(width: kRowGlyphGap),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: _rowTitle,
                  ),
                  const SizedBox(height: kRowTitleSubtitleGap),
                  // A FIXED two-line box: the row height is identical on
                  // `available`, `downloading` and `failed`, so nothing below
                  // the row moves while a download ticks.
                  SizedBox(
                    height: kSubtitleBoxHeight,
                    child: Text(
                      updateRowSubtitle(state),
                      maxLines: kSubtitleLines,
                      overflow: TextOverflow.ellipsis,
                      style: _rowSubtitle,
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(
              height: kUpdatesTouchTarget,
              child: Center(child: _trailing()),
            ),
          ],
        ),
      ),
    );
  }

  /// Exactly one of: an action label, a determinate arc, an indeterminate
  /// spinner, or nothing.
  ///
  /// The download percentage is deliberately NOT here — it lives in the
  /// subtitle, as live text a screen reader can follow. The arc is the ambient
  /// signal; the number is the precise one, and they do not share a place.
  Widget _trailing() {
    if (neverActs) return const SizedBox.shrink();

    final label = updateRowActionLabel(state);
    if (label != null && onAction != null) {
      return TextButton(
        onPressed: onAction,
        child: Text(label, style: _rowActionLabel),
      );
    }

    switch (state.kind) {
      case UpdateRowKind.downloading:
        return _spinner(value: (state.pct ?? 0) / 100);
      case UpdateRowKind.checking:
      case UpdateRowKind.verifying:
      case UpdateRowKind.installing:
      case UpdateRowKind.restarting:
        return _spinner();
      default:
        return const SizedBox.shrink();
    }
  }

  /// The shipped 16x16 strokeWidth-2 indicator, in accent.
  ///
  /// Excluded from semantics while it spins: the stage and the percentage are
  /// already in the subtitle as live text, and a second announcement of the
  /// same fact is noise.
  Widget _spinner({double? value}) {
    return ExcludeSemantics(
      child: SizedBox(
        width: kInlineSpinnerBox,
        height: kInlineSpinnerBox,
        child: CircularProgressIndicator(
          strokeWidth: kInlineSpinnerStroke,
          value: value,
          color: kAccent,
        ),
      ),
    );
  }
}

// -- Component 2: the footer ---------------------------------------------------

/// The manual check (D-07): a status line and one button.
///
/// There is no pull-to-refresh anywhere on this screen — a second,
/// gesture-triggered check would spend the anonymous feed budget invisibly.
class CheckFooter extends StatelessWidget {
  /// The footer's complete state.
  final CheckFooterState state;

  /// Now, injected through the clock provider so `{ago}` is testable.
  final DateTime now;

  /// Fired by the button.
  final VoidCallback onCheck;

  /// Creates the footer.
  const CheckFooter({
    super.key,
    required this.state,
    required this.now,
    required this.onCheck,
  });

  @override
  Widget build(BuildContext context) {
    final checking = state.kind == CheckFooterKind.checking;
    final failed = state.kind == CheckFooterKind.failed;
    final label = failed ? kRetryActionLabel : kCheckForUpdatesLabel;
    final foreground = failed ? kAccent : (checking ? kMuted : kText);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(checkFooterStatus(state, now: now), style: _footerStatus),
        const SizedBox(height: 8),
        TextButton.icon(
          onPressed: checking ? null : onCheck,
          style: TextButton.styleFrom(
            minimumSize: const Size(kUpdatesTouchTarget, kUpdatesTouchTarget),
            foregroundColor: foreground,
          ),
          icon: const Icon(Symbols.refresh_rounded, size: 20),
          label: Text(label, style: _footerButtonLabel),
        ),
      ],
    );
  }
}

// -- Component 3: the explainer sheet -----------------------------------------

/// The D-19 install-permission explainer.
///
/// Opened only when the App row's `Update` was tapped AND the grant is
/// missing. On API below 26 the grant does not exist as a per-app concept and
/// `canInstall` reports true, so this never opens there — it is not an error
/// path to render.
class InstallPermissionSheet extends ConsumerWidget {
  /// Creates the sheet body.
  const InstallPermissionSheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: EdgeInsets.only(
        left: kUpdatesEdgePadding,
        right: kUpdatesEdgePadding,
        top: kUpdatesEdgePadding,
        bottom: kUpdatesEdgePadding + MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(kInstallSheetTitle, style: _sheetTitle),
          const SizedBox(height: 8),
          const Text(kInstallSheetBody, style: _sheetBody),
          const SizedBox(height: kUpdatesGroupFooterGap),
          SizedBox(
            height: kUpdatesTouchTarget,
            width: double.infinity,
            // The phase's ONLY filled button: this sheet is a single-purpose
            // surface with a single primary act.
            child: FilledButton(
              onPressed: () {
                hapticTick();
                // Fire and forget, then close. The app does NOT poll for the
                // grant and does NOT auto-resume the download on return — the
                // user comes back and taps Update again. Auto-resuming after an
                // app switch is exactly the surprise 70 MB should not be.
                unawaited(ref.read(apkInstallerProvider).openInstallPermission());
                Navigator.of(context).pop();
              },
              child: const Text(kInstallSheetCta),
            ),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: () => Navigator.of(context).pop(),
              style: TextButton.styleFrom(
                minimumSize:
                    const Size(kUpdatesTouchTarget, kUpdatesTouchTarget),
                foregroundColor: kMuted,
              ),
              child: const Text(kInstallSheetDismiss),
            ),
          ),
        ],
      ),
    );
  }
}

// -- Component 4: the badge dot ------------------------------------------------

/// The 8px accent dot, shared by the Settings `Updates` row and the hub gear.
///
/// One widget, one source of truth (`updateBadgeProvider`), no animation on
/// appear or clear: a badge that pulses draws attention to itself rather than
/// to the thing it marks, and this one already means exactly one thing.
class UpdateBadgeDot extends StatelessWidget {
  /// Creates the badge dot.
  const UpdateBadgeDot({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: kBadgeDotDiameter,
      height: kBadgeDotDiameter,
      decoration: const BoxDecoration(color: kAccent, shape: BoxShape.circle),
    );
  }
}
