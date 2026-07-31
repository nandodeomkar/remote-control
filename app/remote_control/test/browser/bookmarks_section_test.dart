// Task 3 (11-09) — isolated widget proof of the bookmarks region: the body
// ladder, row anatomy, tap-down routing, folder-bar semantics, the D-14
// delete AFFORDANCE gate and the D-13 CONFIRM gate.
//
// BookmarksSection takes its state and every callback as parameters, so these
// tests pump it directly inside a bare MaterialApp + Scaffold on the same
// 800x1600 surface browser_screen_test.dart uses — no BrowserScreen, no
// ConnectionService fake, no ProviderContainer.
//
// Every assertion is against a named copy const, never an inline literal
// (the house rule that keeps the copy contract single-homed).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:remote_protocol/remote_protocol.dart';

import 'package:remote_control/browser/bookmark_confirm.dart';
import 'package:remote_control/browser/bookmarks_section.dart';
import 'package:remote_control/browser/bookmarks_store.dart';
import 'package:remote_control/browser/install_hint_card.dart';

// -- fixture tree ------------------------------------------------------------
//
//   '0' (virtual root, D-08)
//    ├─ '1'  Bookmarks bar   folder, count 2, LOCKED
//    │   ├─ '10' Empty       folder, count 0          <- deletable
//    │   └─ '11' Docs        link                     <- deletable
//    ├─ '30' Managed         folder, count 0, LOCKED  <- NOT deletable
//    └─ '20' Parent          folder, count 1
//        └─ '21' Sub         folder, count 1          <- NOT deletable
//            └─ '22' Deep    link

const BmNode _bar =
    BmNode(id: '1', parentId: '0', title: 'Bookmarks bar', folder: true, count: 2, locked: true);
const BmNode _emptyFolder =
    BmNode(id: '10', parentId: '1', title: 'Empty', folder: true, count: 0);
const BmNode _docs = BmNode(id: '11', parentId: '1', title: 'Docs');
const BmNode _managed =
    BmNode(id: '30', parentId: '0', title: 'Managed', folder: true, count: 0, locked: true);
const BmNode _parent =
    BmNode(id: '20', parentId: '0', title: 'Parent', folder: true, count: 1);
const BmNode _sub =
    BmNode(id: '21', parentId: '20', title: 'Sub', folder: true, count: 1);
const BmNode _deep = BmNode(id: '22', parentId: '21', title: 'Deep');

const List<BmNode> _tree = [
  _bar,
  _managed,
  _parent,
  _emptyFolder,
  _docs,
  _sub,
  _deep,
];

/// The same folders-first stable partition [BookmarksNotifier] builds, so a
/// hand-made fixture indexes exactly like a pushed snapshot.
BookmarksViewState _state(
  List<BmNode> nodes, {
  bool connected = true,
  bool truncated = false,
  String currentFolderId = '0',
  List<String> backStack = const [],
}) {
  final buckets = <String, List<BmNode>>{};
  for (final n in nodes) {
    (buckets[n.parentId] ??= <BmNode>[]).add(n);
  }
  final index = <String, List<BmNode>>{};
  buckets.forEach((parentId, bucket) {
    final folders = <BmNode>[];
    final links = <BmNode>[];
    for (final n in bucket) {
      if (n.folder == true) {
        folders.add(n);
      } else {
        links.add(n);
      }
    }
    index[parentId] = [...folders, ...links];
  });
  return BookmarksViewState(
    connected: connected,
    nodes: nodes,
    truncated: truncated,
    currentFolderId: currentFolderId,
    backStack: backStack,
    childrenByParent: index,
  );
}

/// Records what the region asked its owner to do.
class _Rec {
  final List<String> opened = [];
  final List<String> entered = [];
  final List<String> deleted = [];
  int backs = 0;
}

Future<void> _pump(
  WidgetTester t,
  BookmarksViewState state,
  _Rec rec, {
  bool enabled = true,
}) async {
  await t.binding.setSurfaceSize(const Size(800, 1600));
  addTearDown(() => t.binding.setSurfaceSize(null));
  await t.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: BookmarksSection(
            bookmarks: state,
            enabled: enabled,
            onOpen: rec.opened.add,
            onEnterFolder: rec.entered.add,
            onBack: () => rec.backs++,
            onDelete: rec.deleted.add,
          ),
        ),
      ),
    ),
  );
}

/// Drains the 100ms press-flash relax so no fake timer outlives the test.
Future<void> _settleFlash(WidgetTester t) =>
    t.pump(const Duration(milliseconds: 150));

void main() {
  group('body ladder', () {
    testWidgets('not connected renders the SHARED install hint card',
        (t) async {
      await _pump(t, _state(const [], connected: false), _Rec());

      expect(find.byType(InstallHintCard), findsOneWidget);
      expect(find.text(kInstallHintTitle), findsOneWidget);
      expect(find.text(kBmNoBookmarks), findsNothing);
    });

    testWidgets('connected with an empty tree renders kBmNoBookmarks',
        (t) async {
      await _pump(t, _state(const []), _Rec());

      expect(find.text(kBmNoBookmarks), findsOneWidget);
      expect(find.byType(InstallHintCard), findsNothing);
    });

    testWidgets('an empty, non-truncated folder renders kBmEmptyFolder',
        (t) async {
      await _pump(
        t,
        _state(_tree, currentFolderId: '10', backStack: const ['0', '1']),
        _Rec(),
      );

      expect(find.text(kBmEmptyFolder), findsOneWidget);
      expect(find.text(kBmTruncatedFolder), findsNothing);
    });

    testWidgets(
        'an empty AND truncated folder renders the truncation line, never '
        '"empty" (that would be a lie)', (t) async {
      const truncatedEmpty = BmNode(
        id: '10',
        parentId: '1',
        title: 'Empty',
        folder: true,
        count: 0,
        truncated: true,
      );
      await _pump(
        t,
        _state(
          const [_bar, truncatedEmpty, _docs],
          currentFolderId: '10',
          backStack: const ['0', '1'],
        ),
        _Rec(),
      );

      expect(find.text(kBmTruncatedFolder), findsOneWidget);
      expect(find.text(kBmEmptyFolder), findsNothing);
    });

    testWidgets('snapshot truncation renders kBmTruncatedSnapshot', (t) async {
      await _pump(t, _state(_tree, truncated: true), _Rec());

      expect(find.text(kBmTruncatedSnapshot), findsOneWidget);
    });
  });

  group('row anatomy', () {
    testWidgets(
        'a folder row shows the folder glyph, a separate count Text and a '
        'chevron; a link row shows the bookmark glyph and neither', (t) async {
      await _pump(
        t,
        _state(_tree, currentFolderId: '1', backStack: const ['0']),
        _Rec(),
      );

      // One folder ('Empty') + one link ('Docs') in this folder.
      expect(find.byIcon(Symbols.folder_rounded), findsOneWidget);
      expect(find.byIcon(Symbols.bookmark_rounded), findsOneWidget);
      // Only the folder carries a chevron and a count.
      expect(find.byIcon(Symbols.chevron_right_rounded), findsOneWidget);
      expect(find.text('· 0'), findsOneWidget);
      // The count is NEVER concatenated into the title.
      expect(find.text('Empty'), findsOneWidget);
      expect(find.text('Docs'), findsOneWidget);
    });
  });

  group('tap routing', () {
    testWidgets('tapping a folder fires onEnterFolder once, onOpen never',
        (t) async {
      final rec = _Rec();
      await _pump(
        t,
        _state(_tree, currentFolderId: '1', backStack: const ['0']),
        rec,
      );

      await t.tap(find.text('Empty'));
      await _settleFlash(t);

      expect(rec.entered, ['10']);
      expect(rec.opened, isEmpty);
    });

    testWidgets('tapping a link fires onOpen once, onEnterFolder never',
        (t) async {
      final rec = _Rec();
      await _pump(
        t,
        _state(_tree, currentFolderId: '1', backStack: const ['0']),
        rec,
      );

      await t.tap(find.text('Docs'));
      await _settleFlash(t);

      expect(rec.opened, ['11']);
      expect(rec.entered, isEmpty);
    });
  });

  // Failure B (11-UAT.md). `tester.longPress` already pumps a REAL timed press
  // — `longPressAt` does startGesture -> pump(kLongPressTimeout + kPressTimeout)
  // = 600ms -> up — so the pre-existing suite DID cross the 100ms tap-down
  // deadline. What it never did was assert that the navigation/open callback
  // stayed SILENT. That single missing assertion is why every test here was
  // green while D-14's delete was unreachable on real hardware.
  group('gesture arena — a long press must never fire the tap action', () {
    testWidgets(
        'long-pressing an EMPTY folder opens the folder confirm and never enters the folder',
        (t) async {
      final rec = _Rec();
      await _pump(
        t,
        _state(_tree, currentFolderId: '1', backStack: const ['0']),
        rec,
      );

      await t.longPress(find.text('Empty'));
      await t.pumpAndSettle();

      expect(
        rec.entered,
        isEmpty,
        reason: 'Failure B: the action used to hang off onTapDown, which fires '
            'at kPressTimeout (100ms) on a long press too — 400ms before '
            'LongPressGestureRecognizer resolves at kLongPressTimeout (500ms). '
            'On a folder that drill-in replaced the list, destroying the row '
            'before the long press could land, so D-14 was unreachable.',
      );
      expect(find.text(kBmDeleteFolderTitle), findsOneWidget);
      expect(rec.opened, isEmpty);
    });

    testWidgets(
        'long-pressing a LINK opens the bookmark confirm and never opens the bookmark',
        (t) async {
      final rec = _Rec();
      await _pump(
        t,
        _state(_tree, currentFolderId: '1', backStack: const ['0']),
        rec,
      );

      await t.longPress(find.text('Docs'));
      await t.pumpAndSettle();

      expect(
        rec.opened,
        isEmpty,
        reason: 'deleting a bookmark must not force-open it first',
      );
      expect(find.text(kBmDeleteBookmarkTitle), findsOneWidget);
      expect(rec.entered, isEmpty);
    });

    testWidgets('a quick tap fires the action and opens NO confirm dialog',
        (t) async {
      final rec = _Rec();
      await _pump(
        t,
        _state(_tree, currentFolderId: '1', backStack: const ['0']),
        rec,
      );

      await t.tap(find.text('Empty'));
      await _settleFlash(t);

      expect(rec.entered, ['10']);
      expect(find.text(kBmDeleteFolderTitle), findsNothing);

      await t.tap(find.text('Docs'));
      await _settleFlash(t);

      expect(rec.opened, ['11']);
      expect(find.text(kBmDeleteBookmarkTitle), findsNothing);
    });

    // The executable twin of UAT check B1. The existing
    // 'a non-empty folder offers no long-press: no dialog, no delete' test also
    // long-presses 'Sub', but asserts only the dialog and rec.deleted —
    // rec.entered is ['21'] BOTH before and after this fix (fired at the 100ms
    // deadline before, on release after), so it survives a real change in WHEN
    // the navigation happens and pins nothing. Pin the semantics here instead.
    testWidgets(
        'holding a NON-deletable folder opens no confirm and drills in on release',
        (t) async {
      final rec = _Rec();
      await _pump(
        t,
        _state(_tree, currentFolderId: '20', backStack: const ['0']),
        rec,
      );

      await t.longPress(find.text('Sub'));
      await t.pumpAndSettle();

      expect(find.text(kBmDeleteFolderTitle), findsNothing);
      expect(
        rec.entered,
        ['21'],
        reason: 'a row with onLongPress: null registers no '
            'LongPressGestureRecognizer at all, so the tap recognizer is '
            'unopposed, has no upper time bound, and fires on release however '
            'long the hold was. The D-14 gate withholds the DELETE, never the '
            'navigation — documented semantics, not a leak.',
      );
    });
  });

  group('folder bar', () {
    testWidgets('depth 0 renders no back button', (t) async {
      await _pump(t, _state(_tree), _Rec());

      expect(find.byIcon(Symbols.arrow_back_rounded), findsNothing);
    });

    testWidgets(
        'depth > 0 renders the back button with its semantic label, fires '
        'onBack once, and titles the folder at 16/600', (t) async {
      final rec = _Rec();
      // Disposed inside the test body: the framework verifies semantics
      // handles BEFORE tearDowns run, so addTearDown is too late.
      final handle = t.ensureSemantics();
      await _pump(
        t,
        _state(_tree, currentFolderId: '1', backStack: const ['0']),
        rec,
      );

      expect(find.byIcon(Symbols.arrow_back_rounded), findsOneWidget);
      expect(find.bySemanticsLabel(kBmBackSemantic), findsOneWidget);

      final title = t.widget<Text>(find.text('Bookmarks bar'));
      expect(title.style!.fontSize, 16);
      expect(title.style!.fontWeight, FontWeight.w600);

      await t.tap(find.byIcon(Symbols.arrow_back_rounded));
      await _settleFlash(t);
      expect(rec.backs, 1);

      handle.dispose();
    });
  });

  group('delete affordance gate (D-14)', () {
    testWidgets('a non-empty folder offers no long-press: no dialog, no delete',
        (t) async {
      final rec = _Rec();
      await _pump(
        t,
        _state(_tree, currentFolderId: '20', backStack: const ['0']),
        rec,
      );

      await t.longPress(find.text('Sub'));
      await t.pumpAndSettle();

      expect(find.text(kBmDeleteFolderTitle), findsNothing);
      expect(find.text(kBmDeleteBookmarkTitle), findsNothing);
      expect(rec.deleted, isEmpty);
    });

    testWidgets('a locked node offers no long-press: no dialog, no delete',
        (t) async {
      final rec = _Rec();
      await _pump(t, _state(_tree), rec);

      // 'Managed' is an EMPTY folder — only `locked` withholds the affordance.
      await t.longPress(find.text('Managed'));
      await t.pumpAndSettle();

      expect(find.text(kBmDeleteFolderTitle), findsNothing);
      expect(rec.deleted, isEmpty);
    });

    testWidgets('an empty unlocked folder opens the folder confirm', (t) async {
      final rec = _Rec();
      await _pump(
        t,
        _state(_tree, currentFolderId: '1', backStack: const ['0']),
        rec,
      );

      await t.longPress(find.text('Empty'));
      await t.pumpAndSettle();

      expect(find.text(kBmDeleteFolderTitle), findsOneWidget);
      expect(find.text(kBmDeleteFolderBody), findsOneWidget);
      expect(rec.deleted, isEmpty, reason: 'the dialog has not resolved yet');
    });
  });

  group('confirm gate (D-13)', () {
    testWidgets('long-pressing a link opens the bookmark confirm; Cancel '
        'deletes nothing', (t) async {
      final rec = _Rec();
      await _pump(
        t,
        _state(_tree, currentFolderId: '1', backStack: const ['0']),
        rec,
      );

      await t.longPress(find.text('Docs'));
      await t.pumpAndSettle();
      expect(find.text(kBmDeleteBookmarkTitle), findsOneWidget);

      await t.tap(find.text(kBmConfirmCancel));
      await t.pumpAndSettle();

      expect(find.text(kBmDeleteBookmarkTitle), findsNothing);
      expect(rec.deleted, isEmpty);
    });

    testWidgets('confirming deletes exactly that node id once', (t) async {
      final rec = _Rec();
      await _pump(
        t,
        _state(_tree, currentFolderId: '1', backStack: const ['0']),
        rec,
      );

      await t.longPress(find.text('Docs'));
      await t.pumpAndSettle();
      await t.tap(find.text(kBmDeleteBookmarkConfirm));
      await t.pumpAndSettle();

      expect(rec.deleted, ['11']);
    });
  });

  group('gated state', () {
    testWidgets(
        'not enabled: a link tap sends nothing and a long-press opens no '
        'dialog, but the back button STILL navigates', (t) async {
      final rec = _Rec();
      await _pump(
        t,
        _state(_tree, currentFolderId: '1', backStack: const ['0']),
        rec,
        enabled: false,
      );

      await t.tap(find.text('Docs'));
      await _settleFlash(t);
      expect(rec.opened, isEmpty);

      await t.longPress(find.text('Docs'));
      await t.pumpAndSettle();
      expect(find.text(kBmDeleteBookmarkTitle), findsNothing);
      expect(rec.deleted, isEmpty);

      // Navigation is not a send — it stays live while gated.
      await t.tap(find.byIcon(Symbols.arrow_back_rounded));
      await _settleFlash(t);
      expect(rec.backs, 1);
    });
  });

  group('delete hint', () {
    testWidgets('a folder holding a deletable child renders kBmDeleteHint',
        (t) async {
      await _pump(
        t,
        _state(_tree, currentFolderId: '1', backStack: const ['0']),
        _Rec(),
      );

      expect(find.text(kBmDeleteHint), findsOneWidget);
    });

    testWidgets('a folder holding only a non-empty subfolder renders no hint',
        (t) async {
      await _pump(
        t,
        _state(_tree, currentFolderId: '20', backStack: const ['0']),
        _Rec(),
      );

      expect(find.text(kBmDeleteHint), findsNothing);
    });
  });
}
