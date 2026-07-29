/// The one destructive-confirm gate the phase's three bookmark deletions
/// share (D-11 unstar, D-13 bookmark delete, D-14 empty-folder delete), plus
/// their copy.
///
/// Shape is a clone of the shipped revoke dialog
/// (`settings/settings_screen.dart` `_confirmRevoke`): an [AlertDialog] on
/// kSurface at radius 16, a 16/600 kText title, a 14/400 kMuted body, a muted
/// `Cancel` [TextButton] and a [FilledButton] confirm.
///
/// WHY this shape and not the Power screen's: `ConfirmTrackFsm`'s
/// slide-to-confirm and the red countdown dialog are calibrated for
/// IRREVERSIBLE MACHINE STATE — a restart or a shutdown that costs unsaved
/// work. A bookmark is a much lower-stakes action (one row on the PC, still
/// recoverable by hand), and the house already owns this lighter destructive
/// gate. Escalating it would train the owner to slide through a gesture that
/// must stay expensive where it actually matters.
///
/// All copy ships as named consts (the `kRevokeConfirm*` house convention) —
/// no inline literals anywhere. The unstar set lives here even though the tab
/// star (11-11) is its only consumer: one confirm module, one copy home.
library;

import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// Unstar confirm title (D-11).
const String kBmUnstarTitle = 'Remove bookmark?';

/// Unstar confirm body — states the "anywhere" blast radius explicitly,
/// because a truthful star may be filled by an entry the user never sees.
const String kBmUnstarBody =
    "This removes every bookmark on your PC that points to this page. "
    "It can't be undone.";

/// Unstar confirm button label.
const String kBmUnstarConfirm = 'Remove';

/// Bookmark-row delete confirm title (D-13).
const String kBmDeleteBookmarkTitle = 'Delete this bookmark?';

/// Bookmark-row delete confirm body.
const String kBmDeleteBookmarkBody =
    "It will be removed from your PC's bookmarks. This can't be undone.";

/// Bookmark-row delete confirm button label.
const String kBmDeleteBookmarkConfirm = 'Delete';

/// Empty-folder delete confirm title (D-14 — a non-empty folder never
/// reaches this dialog; it is offered no long-press at all).
const String kBmDeleteFolderTitle = 'Delete this folder?';

/// Empty-folder delete confirm body — says "empty folder" because that is
/// the only kind the phone can delete.
const String kBmDeleteFolderBody =
    "The empty folder will be removed from your PC's bookmarks. "
    "This can't be undone.";

/// Empty-folder delete confirm button label.
const String kBmDeleteFolderConfirm = 'Delete';

/// Cancel label, shared by all three confirms.
const String kBmConfirmCancel = 'Cancel';

/// Shows the destructive confirm dialog and resolves to whether the user
/// confirmed.
///
/// Returns `result == true`, so a barrier dismissal (which pops `null`) reads
/// as a CANCEL — the caller never has to distinguish "dismissed" from
/// "declined", and a mis-tap outside the dialog can never delete anything.
Future<bool> confirmDestructive(
  BuildContext context, {
  required String title,
  required String body,
  required String confirmLabel,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      backgroundColor: kSurface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Text(
        title,
        style: const TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w600,
          color: kText,
        ),
      ),
      content: Text(
        body,
        style: const TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w400,
          color: kMuted,
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text(
            kBmConfirmCancel,
            style: TextStyle(color: kMuted),
          ),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: kError,
            foregroundColor: kBg,
            minimumSize: const Size(0, 48),
          ),
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return result == true;
}
