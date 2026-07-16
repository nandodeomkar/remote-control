/// The Browser tool screen (BROW-01, 05-02, 260716-oi2) — the live PC tab
/// list (Tab Bridge extension, proto 1.4) above a 2-column macro grid that
/// drives the focused PC browser via the reliable path.
///
/// Tab section (260716-oi2): renders from the value-equal [TabsViewState] —
/// the install hint when the extension is not connected (regardless of
/// phone-auth state — locked fallback), "No tabs open." when connected and
/// empty, else tab rows in extension order. Tap-down activates, swipe or
/// long-press closes; all three gated on `ChipStatus.connected`. The screen
/// sends `tabs.list` once on open to prime (tabs.changed has no after-auth
/// snapshot — the apps pull-on-open contract).
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
import 'tabs_store.dart';

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

  @override
  Widget build(BuildContext context) {
    // Transition-only snapshot — never pinged by the hot path.
    final status = ref.watch(connectionStatusProvider);
    final authed = status.chip == ChipStatus.connected;
    // Value-equal tab view (260716-oi2) — rebuilds only on real tab changes.
    final tabs = ref.watch(tabsStateProvider);

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
      body: SafeArea(
        child: Column(
          children: [
            // D-02: the non-blocking drop strip under the app bar.
            ReconnectingBannerSlot(
              visible: status.chip == ChipStatus.reconnecting,
              onRetry: _service.retryNow,
            ),
            Expanded(
              child: SingleChildScrollView(
                // md edge padding, xl top padding (UI-SPEC grid contract).
                padding: const EdgeInsets.fromLTRB(16, 32, 16, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Tab section (260716-oi2): the new primary content —
                    // macros stay reachable by scroll below.
                    const _SectionHeader('Tabs'),
                    const SizedBox(height: 8),
                    _TabsSection(
                      tabs: tabs,
                      enabled: authed,
                      onActivate: _onActivateTab,
                      onClose: _onCloseTab,
                    ),
                    const SizedBox(height: 24),
                    // The EXISTING macro grid, byte-untouched (the 7-action
                    // vocabulary is pinned by test and locked by CONTEXT).
                    BrowserMacroGrid(
                      onAction: _onAction,
                      enabled: authed,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A 16/600 section header (the apps-screen `_SectionHeader` clone —
/// UI-SPEC typography role: Title).
class _SectionHeader extends StatelessWidget {
  final String label;
  const _SectionHeader(this.label);

  @override
  Widget build(BuildContext context) => Align(
        alignment: Alignment.centerLeft,
        child: Text(
          label,
          style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: kText,
          ),
        ),
      );
}

/// The tab section body (260716-oi2), keyed off [TabsViewState]:
///
/// - `connected == false` (regardless of phone-auth state — locked
///   fallback): the install-hint card.
/// - connected + zero tabs: a small muted one-liner.
/// - connected + tabs: swipe-to-close rows in extension order (no client
///   sort).
class _TabsSection extends StatelessWidget {
  final TabsViewState tabs;
  final bool enabled;
  final void Function(int id) onActivate;
  final void Function(int id) onClose;

  const _TabsSection({
    required this.tabs,
    required this.enabled,
    required this.onActivate,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    if (!tabs.connected) return const _InstallHintCard();
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
    final list = tabs.tabs;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < list.length; i++) ...[
          if (i > 0) const SizedBox(height: 8),
          Dismissible(
            key: ValueKey(list[i].id),
            direction: DismissDirection.horizontal,
            // A kSurface panel with the muted close glyph revealed under the
            // swiping row.
            background: Container(
              decoration: BoxDecoration(
                color: kSurface,
                borderRadius: BorderRadius.circular(16),
              ),
              alignment: Alignment.center,
              child: const Icon(
                Symbols.close_rounded,
                size: 20,
                color: kMuted,
              ),
            ),
            confirmDismiss: (_) async => _confirmSwipe(list[i].id),
            child: _TabRow(
              tab: list[i],
              enabled: enabled,
              onActivate: onActivate,
              onClose: onClose,
            ),
          ),
        ],
      ],
    );
  }

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

/// The extension-missing hint card: kSurface fill, kHairline border, radius
/// 16, padding 16, with a muted leading extension glyph. Plain [Text] only —
/// url_launcher is NOT a dependency and none is added.
class _InstallHintCard extends StatelessWidget {
  const _InstallHintCard();

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: kSurface,
          border: Border.all(color: kHairline),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Symbols.extension_rounded, size: 24, color: kMuted),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: const [
                  Text(
                    'Install the browser extension',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: kText,
                    ),
                  ),
                  SizedBox(height: 4),
                  Text(
                    'See tabs here by loading the free Tab Bridge extension '
                    'on your PC — the extension/README.md file in the '
                    'Remote Control download walks through it.',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w400,
                      color: kMuted,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
}

/// One tab row: chrome byte-matches the apps screen's `_WindowRow` (kSurface
/// fill, radius 16, minHeight 56, kHairline border) EXCEPT the active tab,
/// which carries a kAccent border (the armed-chip visual language — locked
/// "active tab visually marked").
///
/// Tap-DOWN → activate + the 100ms accent press-flash (house press-down
/// pattern); long-press → close (locked "swipe or long-press = close").
/// NOTE: on the Apps screen a row long-press means PIN — per-screen
/// semantics differ, accepted (a tab has no path to pin).
class _TabRow extends StatefulWidget {
  final TabInfo tab;
  final bool enabled;
  final void Function(int id) onActivate;
  final void Function(int id) onClose;

  const _TabRow({
    required this.tab,
    required this.enabled,
    required this.onActivate,
    required this.onClose,
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
        onLongPress:
            widget.enabled ? () => widget.onClose(widget.tab.id) : null,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 56),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
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
