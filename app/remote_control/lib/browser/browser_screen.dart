/// The Browser tool screen (BROW-01, 05-02, 260716-oi2, 260716-sme,
/// 260729-58x) — the
/// live PC tab list (Tab Bridge extension, proto 1.4; tab groups proto 1.5)
/// above a 2-column macro grid that drives the focused PC browser via the
/// reliable path.
///
/// Segmented layout (phase 11, D-01/D-02): a hand-rolled
/// [BrowserSegmentBar] pins `Tabs | Bookmarks` above ONE swapped scroll
/// region, and the macro grid moved OUT of that scroll into a pinned footer
/// with a 1px [kHairline] top edge. D-02 is read as pixel-pinned — the grid
/// must occupy the SAME rect in both segments — and under the previous single
/// `SingleChildScrollView` it would have shifted vertically whenever the list
/// region's height changed. The segment control replaced the old
/// `Tabs` section header; there is no new hub tile, no new route, no new
/// screen.
///
/// Lazy prime (D-03): screen open still primes `tabs.list` ONLY. `bm.list` is
/// sent the first time the Bookmarks segment is DISPLAYED in a mount — by tap
/// or restored from prefs — guarded by a single `_bmPrimed` flag, so a second
/// switch sends nothing and a phone that never opens the segment never asks
/// the PC for bookmark titles at all.
///
/// Tab section (260716-oi2): renders from the value-equal [TabsViewState] —
/// the install hint when the extension is not connected (regardless of
/// phone-auth state — locked fallback), "No tabs open." when connected and
/// empty, else tab rows in extension order. Tap-down activates, swipe or
/// long-press closes; all three gated on `ChipStatus.connected`. The screen
/// sends `tabs.list` once on open to prime (tabs.changed has no after-auth
/// snapshot — the apps pull-on-open contract).
///
/// Tab groups (260716-sme, proto 1.5; containment 260729-58x): the strip is
/// chunked into consecutive same-group runs ([_TabRun]) and each GROUPED run
/// renders inside one [_GroupBlock] — a group-tinted, group-bordered
/// container holding its [_GroupHeader] (dot + tinted title + muted `· N`
/// count) and its nested radius-10 rows. Ungrouped runs emit flat radius-16
/// rows exactly as before, and a 16px gap separates runs.
///
/// The container is the point: the original floating-label design gave a
/// group a visible START but no visible END, so a tab inside a group looked
/// identical to the tab after it. A box has an end.
///
/// VIEW-ONLY — neither the header nor the block has any gesture handler or
/// callback; collapsed groups dim the header (display metadata; the phone
/// still lists the tabs the PC shows collapsed — accepted).
///
/// [kBrowserActions] is the single source of truth for the macro vocabulary:
/// each action string MUST byte-match the server router's `browser_macro`
/// table (`server-core/src/dispatch/router.rs` — back, forward, newtab,
/// closetab, refresh, zoomin, zoomout). Unknown actions are silently dropped
/// server-side, so drift here would be an invisible production no-op — the
/// vocabulary is pinned by test/browser/browser_screen_test.dart.
///
/// [BrowserMacroGrid] is widget-only and service-agnostic (the
/// MouseButtonsBar pattern): presses surface through the injected `onAction`
/// callback on tap-DOWN, so widget tests need no service fake. The screen
/// wires `onAction` to `sendReliable(BrowserMsg(...))` + the haptic tick and
/// gates `enabled` on the transition-only status watch (gated-muted
/// `#6B7280` when not connected — never red).
///
/// Chrome contract (05-UI-SPEC): app bar "Browser" + header chip;
/// reconnecting banner under the app bar (D-02); key-cap buttons — `#16181D`
/// fill, `#2A2D34` 1px border, 8px radius, ≥48px tall, icon + label 16/600
/// `#E6E8EB`; pressed = `#4C8DFF` border + accent icon/label flash
/// (momentary, no easing). Grid: md (16px) edge padding, sm (8px) gaps,
/// xl (32px) top padding. Rows: Back/Forward, New tab/Close tab, Refresh
/// (full-width), Zoom out/Zoom in.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:remote_protocol/remote_protocol.dart';

import '../net/connection_providers.dart';
import '../net/connection_service.dart' show ChipStatus, ConnectionService;
import '../settings/haptics.dart';
import '../theme/tokens.dart';
import '../widgets/connection_header.dart';
import 'bookmarks_section.dart';
import 'bookmarks_store.dart';
import 'browser_segment.dart';
import 'install_hint_card.dart';
import 'tabs_store.dart';

/// Chrome's named group colors mapped to their dark-theme swatches —
/// readable on kBg `#0E0F12` (Chrome dark-UI group palette). These are NEW
/// local consts, NOT theme tokens (the D-12 guard only pins the 7 locked
/// token literals; theme/tokens.dart stays untouched). Unknown color names
/// fall back to [kMuted] via [groupColor] — the SPEC §7 pass-through rule.
const Map<String, Color> kGroupColors = {
  'grey': Color(0xFF8E918F),
  'blue': Color(0xFF8AB4F8),
  'red': Color(0xFFF28B82),
  'yellow': Color(0xFFFDD663),
  'green': Color(0xFF81C995),
  'pink': Color(0xFFFF8BCB),
  'purple': Color(0xFFC58AF9),
  'cyan': Color(0xFF78D9EC),
  'orange': Color(0xFFFCAD70),
};

/// Map a Chrome named group color to its swatch; unknown names render
/// neutrally as [kMuted].
Color groupColor(String name) => kGroupColors[name] ?? kMuted;

/// The left segment's label (11-UI-SPEC §Copywriting Contract).
const String kSegmentTabsLabel = 'Tabs';

/// The right segment's label.
const String kSegmentBookmarksLabel = 'Bookmarks';

/// The tab-row star's semantic label while the tab is NOT bookmarked
/// (11-UI-SPEC §Accessibility Labels, D-09/D-11).
///
/// The star is icon-only and encodes its state in the FILL axis alone, which a
/// screen reader cannot infer — so the label, not the glyph, is the only
/// channel that carries the bookmarked/not-bookmarked distinction to a
/// non-visual user. It therefore FLIPS with the state (see [kUnstarSemantic]).
const String kStarSemantic = 'Bookmark this tab';

/// The tab-row star's semantic label while the tab IS bookmarked — the flipped
/// half of [kStarSemantic].
const String kUnstarSemantic = 'Remove bookmark';

/// The `Tabs | Bookmarks` selector above the swapped list region (D-01) — a
/// clone of the settings screen's scroll-direction segment: two [Expanded]
/// children with an 8px gap, `Material(kBg)` + [InkWell], radius 8,
/// `minHeight 40`, an accent border + accent label when selected and
/// hairline/muted otherwise.
///
/// # Always interactive — there is deliberately no `enabled` parameter
///
/// The segment is NAVIGATION, not a send: it must work offline and unauthed so
/// the user can still read the other list while the socket is down. The rows
/// and the macro grid carry the gating. Do not add a gated variant.
///
/// # Selection only — no haptics, no animation
///
/// The bar reports the tap and nothing else; the screen owner runs
/// `hapticTick()` and swaps the region on [onSelect]. The swap is instant
/// (0 ms) by contract — D-02 wants a list swap, not a navigation — so there is
/// no cross-fade, no slide and no paged transition anywhere on this screen.
///
/// Hand-rolled on purpose: the app owns three segment/tab affordances of its
/// own and `lib/` contains no Material segment widget at all.
class BrowserSegmentBar extends StatelessWidget {
  /// The selected segment — accent border + accent label.
  final BrowserSegment current;

  /// Fired with the tapped segment (including a re-tap of [current] — the
  /// screen owner decides what a same-segment select means).
  final void Function(BrowserSegment segment) onSelect;

  /// Creates the segment bar.
  const BrowserSegmentBar({
    super.key,
    required this.current,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: _SegmentButton(
            label: kSegmentTabsLabel,
            selected: current == BrowserSegment.tabs,
            onTap: () => onSelect(BrowserSegment.tabs),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _SegmentButton(
            label: kSegmentBookmarksLabel,
            selected: current == BrowserSegment.bookmarks,
            onTap: () => onSelect(BrowserSegment.bookmarks),
          ),
        ),
      ],
    );
  }
}

/// One segment: accent border + accent label when selected, hairline/muted
/// otherwise (the settings-screen `_SegmentButton` contract, verbatim).
class _SegmentButton extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _SegmentButton({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = selected ? kAccent : kMuted;
    return Material(
      color: kBg,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          constraints: const BoxConstraints(minHeight: 40),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            border: Border.all(color: selected ? kAccent : kHairline),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w400,
              color: color,
            ),
          ),
        ),
      ),
    );
  }
}

/// One browser macro: UI label + icon + the router-vocabulary action string.
class BrowserActionSpec {
  /// Button label (UI-SPEC copy: "Back", "New tab", …).
  final String label;

  /// Button icon (UI-SPEC icon table).
  final IconData icon;

  /// The wire action string — MUST byte-match router.rs `browser_macro`.
  final String action;

  /// Creates a macro spec.
  const BrowserActionSpec({
    required this.label,
    required this.icon,
    required this.action,
  });
}

/// The 7 browser macros in grid reading order (UI-SPEC rows: Back/Forward,
/// New tab/Close tab, Refresh, Zoom out/Zoom in). Action strings are the
/// exact server vocabulary — see the library doc.
const List<BrowserActionSpec> kBrowserActions = [
  BrowserActionSpec(label: 'Back', icon: Symbols.arrow_back_rounded, action: 'back'),
  BrowserActionSpec(
    label: 'Forward',
    icon: Symbols.arrow_forward_rounded,
    action: 'forward',
  ),
  BrowserActionSpec(label: 'New tab', icon: Symbols.add_rounded, action: 'newtab'),
  BrowserActionSpec(label: 'Close tab', icon: Symbols.close_rounded, action: 'closetab'),
  BrowserActionSpec(label: 'Refresh', icon: Symbols.refresh_rounded, action: 'refresh'),
  BrowserActionSpec(label: 'Zoom out', icon: Symbols.zoom_out_rounded, action: 'zoomout'),
  BrowserActionSpec(label: 'Zoom in', icon: Symbols.zoom_in_rounded, action: 'zoomin'),
];

/// The 2-column macro grid. Widget-only: fires [onAction] with the spec's
/// action string on tap-down; [enabled] false renders the gated all-muted,
/// non-interactive state ("muted, not red").
class BrowserMacroGrid extends StatelessWidget {
  /// Fired on tap-down with the router action string.
  final void Function(String action) onAction;

  /// False renders the gated muted state; taps are inert.
  final bool enabled;

  /// Creates the grid over [kBrowserActions].
  const BrowserMacroGrid({
    super.key,
    required this.onAction,
    required this.enabled,
  });

  @override
  Widget build(BuildContext context) {
    // UI-SPEC rows: pairs in reading order, Refresh full-width on its own
    // row. Built from the spec list — no per-button hardcoding.
    final rows = <Widget>[];
    var i = 0;
    while (i < kBrowserActions.length) {
      final spec = kBrowserActions[i];
      if (spec.action == 'refresh' || i + 1 >= kBrowserActions.length) {
        rows.add(_key(spec));
        i += 1;
      } else {
        final next = kBrowserActions[i + 1];
        rows.add(
          Row(
            children: [
              Expanded(child: _key(spec)),
              const SizedBox(width: 8),
              Expanded(child: _key(next)),
            ],
          ),
        );
        i += 2;
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var r = 0; r < rows.length; r++) ...[
          if (r > 0) const SizedBox(height: 8),
          rows[r],
        ],
      ],
    );
  }

  Widget _key(BrowserActionSpec spec) =>
      _BrowserKey(spec: spec, enabled: enabled, onAction: onAction);
}

/// One key-cap macro button: tap-down accent flash (momentary, no easing) +
/// onAction — the Phase-4 MouseButtonsBar press pattern.
class _BrowserKey extends StatefulWidget {
  final BrowserActionSpec spec;
  final bool enabled;
  final void Function(String action) onAction;

  const _BrowserKey({
    required this.spec,
    required this.enabled,
    required this.onAction,
  });

  @override
  State<_BrowserKey> createState() => _BrowserKeyState();
}

class _BrowserKeyState extends State<_BrowserKey> {
  bool _pressed = false;

  void _onTapDown(TapDownDetails _) {
    setState(() => _pressed = true);
    // Act on press-down (benchmark feel; haptic fires in the screen's
    // callback, so tick and send share the press instant).
    widget.onAction(widget.spec.action);
  }

  void _release() {
    if (_pressed) setState(() => _pressed = false);
  }

  @override
  Widget build(BuildContext context) {
    final active = widget.enabled && _pressed;
    final borderColor = active ? kAccent : kHairline;
    final contentColor =
        active ? kAccent : (widget.enabled ? kText : kMuted);

    return GestureDetector(
      onTapDown: widget.enabled ? _onTapDown : null,
      onTapUp: widget.enabled ? (_) => _release() : null,
      onTapCancel: widget.enabled ? _release : null,
      child: Container(
        constraints: const BoxConstraints(minHeight: 56),
        decoration: BoxDecoration(
          color: kSurface,
          border: Border.all(color: borderColor),
          borderRadius: BorderRadius.circular(8),
        ),
        alignment: Alignment.center,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(widget.spec.icon, size: 20, color: contentColor),
            const SizedBox(width: 4),
            Text(
              widget.spec.label,
              style: TextStyle(
                color: contentColor,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The Browser screen: header chrome + the macro grid wired to the reliable
/// path. Every macro rides `sendReliable(BrowserMsg(...))` — nothing here
/// touches the volatile move path or the hot-path invariant.
class BrowserScreen extends ConsumerStatefulWidget {
  /// Creates the browser screen.
  const BrowserScreen({super.key});

  @override
  ConsumerState<BrowserScreen> createState() => _BrowserScreenState();
}

class _BrowserScreenState extends ConsumerState<BrowserScreen> {
  /// Cached once — app-lifetime singleton (house pattern).
  late final ConnectionService _service;

  /// D-03: whether this MOUNT has already asked for the bookmark tree. Set the
  /// first time the Bookmarks segment is displayed — by tap or restored from
  /// prefs — so a second switch sends nothing and the list is kept live by
  /// `bm.changed` pushes from then on.
  bool _bmPrimed = false;

  @override
  void initState() {
    super.initState();
    _service = ref.read(connectionServiceProvider);
    // Prime the tab list once on open (tabs.changed has NO after-auth
    // snapshot — the same pull-on-open contract as apps; the reply also
    // returns the connected:false hint state when the extension was never
    // up). Apps-screen clone.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.read(tabsStateProvider.notifier).primeList();
    });
  }

  /// Press-down: reliable macro + haptic tick (Phase-4 rule — on press,
  /// not release; SendPolicy owns the auth gating downstream).
  void _onAction(String action) {
    _service.sendReliable(BrowserMsg(action: action));
    hapticTick();
  }

  /// Tab row tap-down: switch the PC browser to that tab (`tabs.activate`,
  /// fire-and-forget — a stale id self-heals on the next tabs.changed) +
  /// haptic tick on the press instant.
  void _onActivateTab(int id) {
    ref.read(tabsStateProvider.notifier).activate(id);
    hapticTick();
  }

  /// Tab row swipe or long-press: close that tab (`tabs.close`,
  /// fire-and-forget) + haptic tick.
  void _onCloseTab(int id) {
    ref.read(tabsStateProvider.notifier).close(id);
    hapticTick();
  }

  /// Segment tap: the haptic + the persisted selection. The bar itself owns
  /// no effect (see [BrowserSegmentBar]).
  void _onSelectSegment(BrowserSegment segment) {
    hapticTick();
    ref.read(browserSegmentProvider.notifier).set(segment);
  }

  /// D-03 lazy prime, called from `build` with the segment about to render:
  /// the FIRST time Bookmarks is actually displayed in this mount, ask for the
  /// tree once. The send rides a post-frame callback so it can never fire
  /// during a build, and the flag flips before the frame so two builds in the
  /// same frame cannot double-send.
  void _maybePrimeBookmarks(BrowserSegment segment) {
    if (segment != BrowserSegment.bookmarks || _bmPrimed) return;
    _bmPrimed = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.read(bookmarksStateProvider.notifier).primeList();
    });
  }

  /// Bookmark row tap-down: open it in a new PC tab (`bm.open`,
  /// fire-and-forget) + haptic tick. Deliberately touches NEITHER the segment
  /// NOR the folder position, so several bookmarks can be opened in a row
  /// (D-04).
  void _onOpenBookmark(String nodeId) {
    ref.read(bookmarksStateProvider.notifier).open(nodeId);
    hapticTick();
  }

  /// Folder row tap-down: drill in. Local navigation (D-06) — nothing crosses
  /// the wire, so this stays a pure state move plus the tick.
  void _onEnterFolder(String folderId) {
    ref.read(bookmarksStateProvider.notifier).enterFolder(folderId);
    hapticTick();
  }

  /// Pop one folder level — the folder bar's back button AND the Android
  /// system back button both land here.
  void _onBookmarksBack() {
    ref.read(bookmarksStateProvider.notifier).goBack();
    hapticTick();
  }

  /// Delete one bookmark or one empty folder (`bm.remove`) + haptic tick. Only
  /// ever reached AFTER the section's confirm dialog resolved true (D-13) —
  /// the screen adds no second entry point.
  void _onDeleteBookmark(String nodeId) {
    ref.read(bookmarksStateProvider.notifier).remove(nodeId);
    hapticTick();
  }

  @override
  Widget build(BuildContext context) {
    // Transition-only snapshot — never pinged by the hot path.
    final status = ref.watch(connectionStatusProvider);
    final authed = status.chip == ChipStatus.connected;
    // Value-equal tab view (260716-oi2) — rebuilds only on real tab changes.
    final tabs = ref.watch(tabsStateProvider);
    // Value-equal bookmarks view — also read on the Tabs segment because the
    // system-back interception below needs the current folder depth.
    final bookmarks = ref.watch(bookmarksStateProvider);
    final segment = ref.watch(browserSegmentProvider);
    _maybePrimeBookmarks(segment);
    // Android system back walks the folder stack first, then leaves the
    // screen: blocked only while the Bookmarks segment is showing a subfolder.
    final inFolder =
        segment == BrowserSegment.bookmarks && bookmarks.depth > 0;

    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        backgroundColor: kBg,
        title: const Text(
          'Browser',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: kText,
          ),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Center(child: ConnectionHeaderChip.forService(_service)),
          ),
        ],
      ),
      body: PopScope(
        canPop: !inFolder,
        onPopInvokedWithResult: (didPop, result) {
          if (!didPop) _onBookmarksBack();
        },
        child: SafeArea(
          child: Column(
            children: [
              // D-02 (phase 8): the non-blocking drop strip under the app bar.
              ReconnectingBannerSlot(
                visible: status.chip == ChipStatus.reconnecting,
                onRetry: _service.retryNow,
              ),
              // Fixed header: md edge padding, xl top padding (UI-SPEC grid
              // contract). The segment control IS the section header now.
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 32, 16, 0),
                child: BrowserSegmentBar(
                  current: segment,
                  onSelect: _onSelectSegment,
                ),
              ),
              // The ONLY swapped region (D-01). Everything above and below it
              // is identical in both segments, which is what makes the switch
              // read as a list swap instead of a navigation.
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                  child: segment == BrowserSegment.tabs
                      ? _TabsSection(
                          tabs: tabs,
                          enabled: authed,
                          onActivate: _onActivateTab,
                          onClose: _onCloseTab,
                          bookmarkedFor: tabs.bookmarkedFor,
                          // Rendering-only for now: the star/unstar handler
                          // (instant add, confirm-gated remove) lands in the
                          // next commit, and a no-op is the honest stub —
                          // better than an unconfirmed destructive path
                          // existing even briefly.
                          onStar: (_, _) {},
                        )
                      : BookmarksSection(
                          bookmarks: bookmarks,
                          enabled: authed,
                          onOpen: _onOpenBookmark,
                          onEnterFolder: _onEnterFolder,
                          onBack: _onBookmarksBack,
                          onDelete: _onDeleteBookmark,
                        ),
                ),
              ),
              // The EXISTING macro grid, byte-untouched (the 7-action
              // vocabulary is pinned by test and locked by CONTEXT) — it only
              // MOVED in the tree, out of the scroll region into a pinned
              // footer, so D-02's identical rect holds by construction. Its
              // 1px hairline top edge is the new boundary signal now that
              // content scrolls above it.
              Container(
                decoration: const BoxDecoration(
                  color: kBg,
                  border: Border(top: BorderSide(color: kHairline)),
                ),
                padding: const EdgeInsets.all(16),
                child: BrowserMacroGrid(
                  onAction: _onAction,
                  enabled: authed,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One consecutive run of tabs sharing the same resolved group (260729-58x).
///
/// [group] is null for a FLAT run — both genuinely ungrouped tabs and tabs
/// whose groupId resolves to nothing (the group fell past the 16-group cap),
/// which is why an unresolved id silently joins the surrounding flat run
/// instead of opening a headerless block.
class _TabRun {
  /// The run's group, or null for a flat (ungrouped) run.
  final GroupInfo? group;

  /// The tabs in this run, in extension order.
  final List<TabInfo> tabs;

  /// Creates a run. [tabs] is grown in place by the chunker.
  _TabRun({required this.group, required this.tabs});
}

/// The tab section body (260716-oi2, groups 260716-sme + 260729-58x), keyed
/// off [TabsViewState]:
///
/// - `connected == false` (regardless of phone-auth state — locked
///   fallback): the install-hint card.
/// - connected + zero tabs: a small muted one-liner.
/// - connected + tabs: swipe-to-close rows in extension order (no client
///   sort), chunked into consecutive `(GroupInfo?, List<TabInfo>)` runs.
///
/// Run rendering (260729-58x). The original design put a floating
/// [_GroupHeader] label above otherwise-flat rows, which gave a group a
/// visible START but no visible END — a tab inside a group was
/// indistinguishable from the tab after it. A container has an end, so each
/// grouped run now renders as ONE [_GroupBlock]; a flat run emits its rows
/// directly, byte-identical to the pre-260729-58x look.
///
/// Spacing contract: 16px between runs (never before the first) — the gap
/// that puts the next tab unmistakably OUTSIDE the block; 8px between rows
/// of a flat run (unchanged); 6px between rows nested in a block (see
/// [_GroupBlock]).
///
/// Chrome keeps a group's tabs contiguous in the strip, so consecutive-run
/// detection is correct; a non-contiguous edge case would just render the
/// group as two blocks (harmless — no dedupe machinery).
class _TabsSection extends StatelessWidget {
  final TabsViewState tabs;
  final bool enabled;
  final void Function(int id) onActivate;
  final void Function(int id) onClose;

  /// The tri-state bookmark resolver ([TabsViewState.bookmarkedFor]): true
  /// bookmarked, false not, and `null` UNKNOWN — which renders NO star slot at
  /// all (D-11 truthfulness).
  final bool? Function(TabInfo tab) bookmarkedFor;

  /// Star tap: `(tabId, currentlyBookmarked)`. The row reports the state it
  /// RENDERED, so the screen never has to re-resolve it and the add/remove
  /// split can never disagree with the glyph the user tapped.
  final void Function(int tabId, bool bookmarked) onStar;

  const _TabsSection({
    required this.tabs,
    required this.enabled,
    required this.onActivate,
    required this.onClose,
    required this.bookmarkedFor,
    required this.onStar,
  });

  @override
  Widget build(BuildContext context) {
    if (!tabs.connected) return const InstallHintCard();
    if (tabs.tabs.isEmpty) {
      return const Align(
        alignment: Alignment.centerLeft,
        child: Text(
          'No tabs open.',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w400,
            color: kMuted,
          ),
        ),
      );
    }
    // Resolve group ids once (proto 1.5): a tab whose groupId misses this
    // map (group fell past the cap) resolves to null and therefore joins the
    // surrounding FLAT run — no header, no block, no exception.
    final groupById = {for (final g in tabs.groups) g.id: g};

    // Chunk the strip into consecutive same-group runs.
    final runs = <_TabRun>[];
    for (final tab in tabs.tabs) {
      final group = tab.groupId != null ? groupById[tab.groupId] : null;
      if (runs.isNotEmpty && runs.last.group?.id == group?.id) {
        runs.last.tabs.add(tab);
      } else {
        runs.add(_TabRun(group: group, tabs: [tab]));
      }
    }

    final children = <Widget>[];
    for (var r = 0; r < runs.length; r++) {
      // 16px run gap — the signal that the next tab is OUTSIDE the block.
      if (r > 0) children.add(const SizedBox(height: 16));
      final run = runs[r];
      final group = run.group;
      if (group == null) {
        // Flat run: rows at radius 16 with 8px gaps — unchanged from before.
        for (var i = 0; i < run.tabs.length; i++) {
          if (i > 0) children.add(const SizedBox(height: 8));
          children.add(_row(run.tabs[i], radius: 16));
        }
      } else {
        // Grouped run: one contained block of nested-radius rows.
        children.add(
          _GroupBlock(
            group: group,
            rows: [for (final tab in run.tabs) _row(tab, radius: 10)],
          ),
        );
      }
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
  }

  /// One swipe-to-close tab row at [radius] — 16 flat, 10 nested inside a
  /// [_GroupBlock]. The radius is shared with the Dismissible's revealed
  /// background so the panel under a swiping row matches the row's corners.
  Widget _row(TabInfo tab, {required double radius}) => Dismissible(
        key: ValueKey(tab.id),
        direction: DismissDirection.horizontal,
        // A kSurface panel with the muted close glyph revealed under the
        // swiping row.
        background: Container(
          decoration: BoxDecoration(
            color: kSurface,
            borderRadius: BorderRadius.circular(radius),
          ),
          alignment: Alignment.center,
          child: const Icon(
            Symbols.close_rounded,
            size: 20,
            color: kMuted,
          ),
        ),
        confirmDismiss: (_) async => _confirmSwipe(tab.id),
        child: _TabRow(
          tab: tab,
          enabled: enabled,
          onActivate: onActivate,
          onClose: onClose,
          // Resolved HERE (not inside the row) so the row stays a dumb
          // renderer of the tri-state value, exactly like `enabled`.
          bookmarked: bookmarkedFor(tab),
          onStar: onStar,
          radius: radius,
        ),
      );

  /// Swipe-close gate + fire. Returns false when not [enabled] so a swipe
  /// cannot fire unauthed (ChipStatus.connected gating, existing pattern).
  ///
  /// When enabled, `tabs.close` fires HERE and the row springs back instead
  /// of dismissing: the row's lifetime is server-driven (it disappears on
  /// the next tabs.changed once the PC actually closed the tab), and letting
  /// the Dismissible remove a row the state list still contains would trip
  /// Flutter's dismissed-but-still-in-tree assertion on the next rebuild.
  bool _confirmSwipe(int id) {
    if (!enabled) return false;
    onClose(id);
    return false;
  }
}

/// The containment shell for one consecutive grouped run (260729-58x): a
/// tinted, bordered box holding the run's [_GroupHeader] and its [rows].
///
/// Fill and border are BOTH derived with `Color.withValues(alpha:)` on the
/// mapped group swatch — 6% fill for a tint that stays readable on kBg
/// `#0E0F12`, 40% border for the visible edge. Never an [Opacity] wrapper:
/// Opacity would dim the rows inside as well, and the tab section keeps
/// EXACTLY ONE Opacity (the collapsed-header dim), which a widget test
/// looks up unambiguously.
///
/// Concentric-radius rule: the block's outer radius 16 minus its 6px padding
/// leaves 10 for the nested rows, so the corners stay visually parallel
/// instead of the inner rows looking too round. Rows are separated by 6px
/// (tighter than the 8px flat spacing) because containment already does the
/// separating work; the 16px run gap outside the block is what marks the
/// group's END.
///
/// VIEW-ONLY IS STRUCTURAL, same rule as [_GroupHeader]: this widget holds
/// only a [GroupInfo] and pre-built row widgets, and declares zero callbacks
/// and zero gesture handlers, so the block can never become a new action
/// surface (the phone still cannot create/collapse/move groups).
class _GroupBlock extends StatelessWidget {
  final GroupInfo group;
  final List<Widget> rows;

  const _GroupBlock({required this.group, required this.rows});

  @override
  Widget build(BuildContext context) {
    final color = groupColor(group.color);
    return Container(
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.06),
        border: Border.all(color: color.withValues(alpha: 0.40)),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _GroupHeader(group: group, count: rows.length),
          for (var i = 0; i < rows.length; i++) ...[
            if (i > 0) const SizedBox(height: 6),
            rows[i],
          ],
        ],
      ),
    );
  }
}

/// A view-only tab-group header (proto 1.5, 260716-sme; count 260729-58x):
/// an 8px dot in the mapped Chrome group color, the group title at 12/600
/// tinted the SAME color, then a muted `· N` tab count. Collapsed groups
/// wrap the content in Opacity(0.5) and append a small muted unfold-less
/// glyph — display metadata ONLY.
///
/// The count is a SEPARATE [Text], never concatenated into the title: the
/// title must stay a lone `Text(group.title)` carrying exactly the group
/// tint so `find.text('Work')` resolves to one widget with a known style
/// (pinned by test). An untitled group therefore falls back to dot + count
/// alone, which still reads as a group rather than an anonymous box.
///
/// VIEW-ONLY IS STRUCTURAL: this widget has NO gesture handlers and no
/// callbacks — the phone cannot create/collapse/move groups (SPEC §7
/// GroupEl). Grouped tab rows below it render at full strength even when
/// the PC shows the group collapsed (the phone lists what exists —
/// accepted).
class _GroupHeader extends StatelessWidget {
  final GroupInfo group;

  /// How many tabs the run holds — rendered as the `· N` suffix.
  final int count;

  const _GroupHeader({required this.group, required this.count});

  @override
  Widget build(BuildContext context) {
    final color = groupColor(group.color);
    final content = Row(
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        if (group.title.isNotEmpty) ...[
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              group.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: color,
              ),
            ),
          ),
        ],
        const SizedBox(width: 6),
        Text(
          '· $count',
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w400,
            color: kMuted,
          ),
        ),
        if (group.collapsed) ...[
          const SizedBox(width: 6),
          const Icon(Symbols.unfold_less_rounded, size: 14, color: kMuted),
        ],
      ],
    );
    return Padding(
      padding: const EdgeInsets.only(left: 6, top: 2, bottom: 6),
      child: group.collapsed ? Opacity(opacity: 0.5, child: content) : content,
    );
  }
}

/// One tab row: chrome byte-matches the apps screen's `_WindowRow` (kSurface
/// fill, minHeight 56, kHairline border) EXCEPT the active tab, which
/// carries a kAccent border (the armed-chip visual language — locked
/// "active tab visually marked").
///
/// [radius] is 16 for a flat row and 10 when nested inside a [_GroupBlock]
/// (260729-58x concentric-radius rule); it drives both the Material shape
/// and the InkWell splash clip so the ink never bleeds past the corners.
///
/// Tap-DOWN → activate + the 100ms accent press-flash (house press-down
/// pattern); long-press → close (locked "swipe or long-press = close").
/// NOTE: on the Apps screen a row long-press means PIN — per-screen
/// semantics differ, accepted (a tab has no path to pin).
///
/// # The trailing star slot (phase 11, D-09/D-11/D-12)
///
/// The row's gesture budget was already spent — tap-down activates, long-press
/// closes and a horizontal drag closes — so bookmarking had to become a
/// trailing BUTTON rather than a fourth gesture (D-09). Its `InkWell` is a
/// nested recognizer inside the row's: a star tap must fire [onStar] and
/// produce ZERO `tabs.activate`, which is pinned by a widget test rather than
/// by reasoning about `TapGestureRecognizer` deadlines (RESEARCH Pitfall 8 /
/// assumption A6).
///
/// [bookmarked] is TRI-STATE and the rendering is the D-11 truthfulness rule:
///
/// - `true` → 48x48 slot, the rounded star glyph at `fill: 1`, [kAccent]
///   (or [kMuted] when gated)
/// - `false` → the same slot at `fill: 0`, [kMuted]
/// - `null` (UNKNOWN) → NO slot at all, so both the layout and the
///   accessibility tree stay byte-identical to the pre-phase row. An empty
///   star on a tab whose bookmark state could not be read would be a
///   misreport, and a misreport is worse than no star.
///
/// The fill change is deliberately unanimated (0 ms) so the D-12 optimistic
/// flip reads as immediate.
class _TabRow extends StatefulWidget {
  final TabInfo tab;
  final bool enabled;
  final void Function(int id) onActivate;
  final void Function(int id) onClose;

  /// Tri-state bookmark state to RENDER — `null` means unknown and renders no
  /// star slot at all (see the class doc).
  final bool? bookmarked;

  /// Star tap: `(tabId, currentlyBookmarked)`.
  final void Function(int tabId, bool bookmarked) onStar;

  /// Corner radius: 16 flat, 10 nested in a group block.
  final double radius;

  const _TabRow({
    required this.tab,
    required this.enabled,
    required this.onActivate,
    required this.onClose,
    required this.bookmarked,
    required this.onStar,
    required this.radius,
  });

  @override
  State<_TabRow> createState() => _TabRowState();
}

class _TabRowState extends State<_TabRow> {
  bool _pressed = false;

  void _fire() {
    widget.onActivate(widget.tab.id);
    setState(() => _pressed = true);
    Future.delayed(const Duration(milliseconds: 100), () {
      if (mounted) setState(() => _pressed = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final borderColor =
        (_pressed || widget.tab.active) ? kAccent : kHairline;
    final titleColor = !widget.enabled
        ? kMuted
        : _pressed
            ? kAccent
            : kText;
    // Tri-state: null renders no slot (D-11), so every use below is inside the
    // `bookmarked != null` guard and the local is non-null there.
    final bookmarked = widget.bookmarked;
    // Accent ONLY for a live, filled star. Everything else rendered — the
    // gated filled star and the outline star in any state — is kMuted.
    // The destructive red never appears on a star (11-UI-SPEC §Palette).
    final starColor =
        (bookmarked == true && widget.enabled) ? kAccent : kMuted;
    return Material(
      color: kSurface,
      shape: RoundedRectangleBorder(
        side: BorderSide(color: borderColor),
        borderRadius: BorderRadius.circular(widget.radius),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(widget.radius),
        onTap: widget.enabled ? () {} : null,
        onTapDown: widget.enabled ? (_) => _fire() : null,
        onLongPress:
            widget.enabled ? () => widget.onClose(widget.tab.id) : null,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 56),
          child: Padding(
            // Right padding drops 12 -> 4 whenever a star slot renders: the
            // 48x48 star box supplies the remaining optical inset (11-UI-SPEC
            // §Spacing exceptions). A row with no slot keeps 12 and is
            // byte-identical to the pre-phase row.
            padding: EdgeInsets.only(
              left: 12,
              right: bookmarked == null ? 12 : 4,
            ),
            child: Row(
              children: [
                _TabIcon(iconB64: widget.tab.icon, size: 24),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    widget.tab.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w400,
                      color: titleColor,
                    ),
                  ),
                ),
                // The D-09 star slot — the last child, and present ONLY when
                // the bookmark state is actually known. Gated keeps the
                // geometry AND the Semantics node (Flutter marks the node
                // disabled via the null callback), so the layout never shifts
                // and the control reads as disabled rather than absent.
                if (bookmarked != null) ...[
                  const SizedBox(width: 4),
                  SizedBox(
                    width: 48,
                    height: 48,
                    child: Semantics(
                      button: true,
                      label: bookmarked ? kUnstarSemantic : kStarSemantic,
                      child: InkWell(
                        customBorder: const CircleBorder(),
                        onTap: widget.enabled
                            ? () => widget.onStar(widget.tab.id, bookmarked)
                            : null,
                        child: Icon(
                          Symbols.star_rounded,
                          // The FILL axis is the whole state signal, and this
                          // per-Icon override intentionally beats the app-wide
                          // FILL 0 pin from buildAppTheme.
                          fill: bookmarked ? 1 : 0,
                          size: 20,
                          color: starColor,
                        ),
                      ),
                    ),
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

/// A decoded base64-PNG favicon, or the muted [Symbols.language_rounded]
/// fallback (null icon OR a decode failure — never throws into the UI; the
/// apps `_AppIcon` clone with the tab fallback glyph).
class _TabIcon extends StatelessWidget {
  final String? iconB64;
  final double size;

  const _TabIcon({required this.iconB64, required this.size});

  @override
  Widget build(BuildContext context) {
    final b64 = iconB64;
    if (b64 != null && b64.isNotEmpty) {
      try {
        final bytes = base64Decode(b64);
        return Image.memory(
          bytes,
          width: size,
          height: size,
          gaplessPlayback: true,
          errorBuilder: (_, _, _) => _fallback(),
        );
      } on FormatException {
        return _fallback();
      }
    }
    return _fallback();
  }

  Widget _fallback() =>
      Icon(Symbols.language_rounded, size: size, color: kMuted);
}
