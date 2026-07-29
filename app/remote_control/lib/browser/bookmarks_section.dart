/// The Bookmarks list region of the Browser screen (phase 11, D-04…D-14) —
/// the folder bar, the folder/link rows, the body-state ladder, the
/// truncation and empty copy, and the long-press-plus-confirm delete gate.
///
/// Built as a standalone widget that takes its state and its callbacks as
/// parameters: it needs no provider, no service and no screen, so the D-13
/// confirm gate and the D-14 affordance gate are testable in isolation
/// instead of through a screen mount.
///
/// Effect ownership follows the `KeyboardTabBar` split: the callbacks report
/// INTENT only (`onOpen` / `onEnterFolder` / `onBack` / `onDelete`) and the
/// owning screen adds `hapticTick()` and the send. The one effect this widget
/// does own is the confirm dialog — that is where the [BuildContext] is.
///
/// Row chrome clones `_TabRow` (kSurface fill, radius 16, 1px border,
/// minHeight 56, 12px horizontal padding, tap-DOWN fire + a 100ms accent
/// press flash). There is NO resting accent anywhere in this segment: the
/// Tabs segment has a true "current" item to anchor on, the Bookmarks segment
/// does not, and inventing a highlighted row here would be a lie about PC
/// state.
///
/// Drill-in and back are instant list swaps — no route push, no transition —
/// because the phone navigates one pushed snapshot locally (D-06). There is
/// no swipe gesture on a bookmark row: swipe-to-close stays exclusive to tab
/// rows, and a destructive bookmark action must not have a fast,
/// undoable-looking gesture.
library;

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import 'package:remote_protocol/remote_protocol.dart';

import '../theme/tokens.dart';
import 'bookmark_confirm.dart';
import 'bookmarks_store.dart';
import 'install_hint_card.dart';

/// Empty state — the whole tree is empty.
const String kBmNoBookmarks = 'No bookmarks yet.';

/// Empty state — this folder has no children (and is not truncated).
const String kBmEmptyFolder = 'This folder is empty.';

/// Snapshot-level truncation line (top of the region).
const String kBmTruncatedSnapshot = 'Showing the first 500 bookmarks.';

/// Per-folder truncation line (below the rows).
const String kBmTruncatedFolder = "Some bookmarks here aren't shown.";

/// Long-press discoverability line — the delete affordance is invisible by
/// design (D-14), so the only folder that advertises it is one that has at
/// least one deletable child.
const String kBmDeleteHint = 'Long-press a bookmark to delete it.';

/// Semantic label for the icon-only folder back button.
const String kBmBackSemantic = 'Back to parent folder';

/// The 12/400 muted style shared by every one-liner in this region.
const TextStyle _mutedLabel = TextStyle(
  fontSize: 12,
  fontWeight: FontWeight.w400,
  color: kMuted,
);

/// The bookmarks list region: folder bar, rows, body-state ladder and the
/// delete gate, driven entirely by [bookmarks].
class BookmarksSection extends StatelessWidget {
  /// The value-equal view the store publishes.
  final BookmarksViewState bookmarks;

  /// `ChipStatus.connected` — gates every SEND. Navigation stays live.
  final bool enabled;

  /// Open the link node in a new PC tab (`bm.open`).
  final void Function(String nodeId) onOpen;

  /// Drill into a folder (local navigation — nothing crosses the wire).
  final void Function(String folderId) onEnterFolder;

  /// Pop one folder level.
  final VoidCallback onBack;

  /// Delete one bookmark or one empty folder — only ever called AFTER the
  /// confirm dialog resolves true.
  final void Function(String nodeId) onDelete;

  /// Creates the region.
  const BookmarksSection({
    super.key,
    required this.bookmarks,
    required this.enabled,
    required this.onOpen,
    required this.onEnterFolder,
    required this.onBack,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[];

    if (bookmarks.truncated) {
      children.add(const _MutedLine(kBmTruncatedSnapshot));
      children.add(const SizedBox(height: 8));
    }

    if (bookmarks.depth > 0) {
      children.add(_folderBar());
      children.add(const SizedBox(height: 8));
    }

    children.add(_body());

    // Trailing lines, only when the extension is up: a "long-press to delete"
    // hint under an install card would advertise an affordance no row has.
    if (bookmarks.connected) {
      final trailing = <Widget>[];
      if (bookmarks.currentFolderTruncated) {
        trailing.add(const _MutedLine(kBmTruncatedFolder));
      }
      if (bookmarks.hasDeletableChild) {
        if (trailing.isNotEmpty) trailing.add(const SizedBox(height: 4));
        trailing.add(const _MutedLine(kBmDeleteHint));
      }
      if (trailing.isNotEmpty) {
        children.add(const SizedBox(height: 8));
        children.addAll(trailing);
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
  }

  /// Body ladder — FIRST MATCH WINS.
  ///
  /// A folder that is both empty and truncated deliberately falls through to
  /// the (empty) row list so the trailing truncation line is what the user
  /// reads: saying "This folder is empty." about a folder whose children were
  /// dropped by the byte budget would be a lie.
  Widget _body() {
    if (!bookmarks.connected) return const InstallHintCard();
    if (bookmarks.nodes.isEmpty) return const _MutedLine(kBmNoBookmarks);
    final rows = bookmarks.currentChildren;
    if (rows.isEmpty && !bookmarks.currentFolderTruncated) {
      return const _MutedLine(kBmEmptyFolder);
    }
    final widgets = <Widget>[];
    for (var i = 0; i < rows.length; i++) {
      if (i > 0) widgets.add(const SizedBox(height: 8));
      widgets.add(
        _BmRow(
          key: ValueKey(rows[i].id),
          node: rows[i],
          enabled: enabled,
          onOpen: onOpen,
          onEnterFolder: onEnterFolder,
          onDelete: onDelete,
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: widgets,
    );
  }

  /// The depth > 0 folder bar: a bar, not a card — no fill, no border, and
  /// 48px tall rather than the 56px row height.
  ///
  /// The back control stays LIVE even when [enabled] is false: popping a
  /// folder is local navigation, not a send, so gating it would strand an
  /// offline user inside a subfolder.
  Widget _folderBar() => SizedBox(
        height: 48,
        child: Row(
          children: [
            Semantics(
              button: true,
              label: kBmBackSemantic,
              child: SizedBox(
                width: 48,
                height: 48,
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: onBack,
                  child: const Icon(
                    Symbols.arrow_back_rounded,
                    size: 20,
                    color: kMuted,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                bookmarks.currentFolderTitle ?? '',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: kText,
                ),
              ),
            ),
          ],
        ),
      );
}

/// A left-aligned 12/400 muted one-liner (the shipped empty-state idiom — no
/// card, no icon).
class _MutedLine extends StatelessWidget {
  final String text;

  const _MutedLine(this.text);

  @override
  Widget build(BuildContext context) => Align(
        alignment: Alignment.centerLeft,
        child: Text(text, style: _mutedLabel),
      );
}

/// One bookmark row — folder or link, one widget.
///
/// The two kinds differ only in their leading glyph, their trailing content
/// and what tap-down fires; every measurement, color and gesture is shared,
/// so a folder row and a link row can never drift apart visually.
///
/// The long-press delete is offered ONLY when
/// [BookmarksViewState.isDeletable] says so — a link, or a folder with
/// `count == 0`, and in both cases not locked. Roots arrive marked locked, so
/// they are covered by the same rule with no special case. A non-deletable
/// row gets `onLongPress: null` with NO visual difference: there is nothing
/// to discover, which is precisely what makes a subtree wipe unreachable from
/// the phone (D-14).
class _BmRow extends StatefulWidget {
  final BmNode node;
  final bool enabled;
  final void Function(String nodeId) onOpen;
  final void Function(String folderId) onEnterFolder;
  final void Function(String nodeId) onDelete;

  const _BmRow({
    super.key,
    required this.node,
    required this.enabled,
    required this.onOpen,
    required this.onEnterFolder,
    required this.onDelete,
  });

  @override
  State<_BmRow> createState() => _BmRowState();
}

class _BmRowState extends State<_BmRow> {
  bool _pressed = false;

  bool get _isFolder => widget.node.folder == true;

  /// Tap-DOWN fire + the 100ms accent relax (the shipped `_TabRow._fire`).
  void _fire() {
    if (_isFolder) {
      widget.onEnterFolder(widget.node.id);
    } else {
      widget.onOpen(widget.node.id);
    }
    setState(() => _pressed = true);
    Future.delayed(const Duration(milliseconds: 100), () {
      if (mounted) setState(() => _pressed = false);
    });
  }

  /// Long-press → confirm → delete. [onDelete] fires ONLY on a true result,
  /// so Cancel and a barrier dismissal both destroy nothing (D-13).
  Future<void> _confirmDelete() async {
    final confirmed = await confirmDestructive(
      context,
      title: _isFolder ? kBmDeleteFolderTitle : kBmDeleteBookmarkTitle,
      body: _isFolder ? kBmDeleteFolderBody : kBmDeleteBookmarkBody,
      confirmLabel:
          _isFolder ? kBmDeleteFolderConfirm : kBmDeleteBookmarkConfirm,
    );
    if (!confirmed) return;
    widget.onDelete(widget.node.id);
  }

  @override
  Widget build(BuildContext context) {
    final leadingGlyph = _isFolder
        ? Symbols.folder_rounded
        : Symbols.bookmark_rounded;
    final borderColor = _pressed ? kAccent : kHairline;
    final glyphColor = _pressed ? kAccent : kMuted;
    final titleColor = !widget.enabled
        ? kMuted
        : _pressed
            ? kAccent
            : kText;
    final deletable =
        widget.enabled && BookmarksViewState.isDeletable(widget.node);
    return Material(
      color: kSurface,
      shape: RoundedRectangleBorder(
        side: BorderSide(color: borderColor),
        borderRadius: BorderRadius.circular(16),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: widget.enabled ? () {} : null,
        onTapDown: widget.enabled ? (_) => _fire() : null,
        onLongPress: deletable ? _confirmDelete : null,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 56),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                Icon(leadingGlyph, size: 24, color: glyphColor),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    widget.node.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w400,
                      color: titleColor,
                    ),
                  ),
                ),
                // The count is a SEPARATE Text, never concatenated into the
                // title (the _GroupHeader rule) — the title must stay a lone
                // Text so find.text(title) resolves to one known widget.
                if (_isFolder) ...[
                  Text('· ${widget.node.count ?? 0}', style: _mutedLabel),
                  const SizedBox(width: 4),
                  const Icon(
                    Symbols.chevron_right_rounded,
                    size: 20,
                    color: kMuted,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
